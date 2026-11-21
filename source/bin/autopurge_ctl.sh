#!/system/bin/sh
# AutoPurge Pro 核心控制与统计归档引擎 (v4.4.0 重构版)
# Author: liancan
#
# 设计要点：
# - 所有命令输出 JSON 或简短文本，供 WebUI / action.sh / Main.sh 消费；
# - 清理任务通过状态文件 + PID 文件后台执行，支持重复触发保护；
# - run_cleanup 使用目录锁避免 cron 与手动清理并发导致的计数竞争。

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/autopurge_ctl.sh"
MODDIR="${AUTOPURGE_MODDIR:-$(dirname -- "$SCRIPT_DIR")}"
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/Clear_Rubbish"
[ -d "$MODDIR" ] || MODDIR="/data/adb/ksu/modules/Clear_Rubbish"
CONFIG_DIR="${AUTOPURGE_CONFIG_DIR:-/data/media/0/Android/Clear/清理垃圾}"
LIST_DIR="$CONFIG_DIR/名单配置"
TIMING_DIR="$CONFIG_DIR/自定义定时设置"

MAIN_CONF="$CONFIG_DIR/配置.conf"
TIMING_CONF="$TIMING_DIR/定时设置.conf"
BLACKLIST="$LIST_DIR/黑名单.conf"
WHITELIST="$LIST_DIR/白名单.conf"
MTLIST="$LIST_DIR/MT.conf"

CLEAR_LOG="$CONFIG_DIR/Clear.log"
HISTORY_LOG="$CONFIG_DIR/History_Files.log"
FILE_PATHS_CONF="$CONFIG_DIR/FilePaths.conf"
COUNTER_FILE="$CONFIG_DIR/Counter"
STATS_JSON="$CONFIG_DIR/Stats.json"
CLEAN_STATE="$CONFIG_DIR/Cleanup.state"
CLEAN_PID="$CONFIG_DIR/Cleanup.pid"
CLEAN_WORKER_LOG="$CONFIG_DIR/Cleanup_worker.log"
CLEAN_LOCK="$CONFIG_DIR/.cleanup.lock"
CLEAN_TASK_LOCK="$CONFIG_DIR/.cleanup-task.lock"
FILE_TASK_LOCK="$CONFIG_DIR/.file-task.lock"
FILE_TASK_STATE="$CONFIG_DIR/FileTask.state"
FILE_TASK_PID="$CONFIG_DIR/FileTask.pid"
FILE_TASK_RESULT="$CONFIG_DIR/FileTask.result"
FILE_TASK_LOG="$CONFIG_DIR/FileTask.log"

export LD_LIBRARY_PATH="$MODDIR/lib:$LD_LIBRARY_PATH"

# ---------------------------------------------------------------- 基础工具

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

get_conf_val() {
    # $1=key $2=file $3=default
    local val
    val=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$2" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d ' \r\t')
    [ -z "$val" ] && val="$3"
    printf '%s' "$val"
}

path_is_child_of() {
    # $1=候选路径 $2=允许的根目录；不接受根目录本身或根目录之外的路径。
    case "$1" in "$2"/*) return 0 ;; *) return 1 ;; esac
}

is_protected_system_path() {
    case "$1" in
        /data/media/0|/data/media/0/*)
            return 1 ;;
        /|/data|/data/*|/system|/system/*|/vendor|/vendor/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/apex|/apex/*|/metadata|/metadata/*)
            return 0 ;;
        *) return 1 ;;
    esac
}

get_path_val() {
    # 读取 FilePaths.conf 中的路径并做安全校验，非法值回退默认。
    local key="$1" default_val="$2" val
    val=$(sed -n "s/^${key}=//p" "$FILE_PATHS_CONF" 2>/dev/null | tail -n1 | tr -d '\r')
    [ -z "$val" ] && val="$default_val"
    case "$val" in
        /*) ;;
        *) val="$default_val" ;;
    esac
    case "$val" in
        *..*|*'"'*|*"'"*|*'$'*|*'`'*|*'|'*|*';'*|*'&'*|*'<'*|*'>'*|*'\'*) val="$default_val" ;;
    esac
    # 输出带换行：既支持 $( ) 取值（自动去尾换行），也支持逐行收集来源目录
    printf '%s\n' "$val"
}

set_conf_val() {
    # $1=key $2=value $3=file；仅允许白名单键和值，临时文件替换避免半写入。
    local key="$1" value="$2" file="$3" tmp
    case "$key" in
        master_switch|timed_cleaning|mt_cleaning|log_cleaning|apk_cleaning|module_residue_cleaning|file_organize|blacklist_cleaning)
            case "$value" in true|false) ;; *) return 1 ;; esac
            ;;
        log_purge_size)
            case "$value" in 512K|1M|2M|5M|10M) ;; *) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac
    tmp="$file.tmp.$"
    awk -v key="$key" -v value="$value" '
        BEGIN { updated = 0 }
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            if (!updated) { print key "=" value; updated = 1 }
            next
        }
        { print }
        END { if (!updated) print key "=" value }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 644 "$tmp" 2>/dev/null
    mv -f "$tmp" "$file"
}

set_config_cmd() {
    init_env
    local tmp key value changed=0
    [ "$#" -ge 3 ] || { echo '{"status":"error","message":"missing key/value"}'; return 2; }
    shift
    tmp="$MAIN_CONF.batch.$"
    cp "$MAIN_CONF" "$tmp" 2>/dev/null || { echo '{"status":"error","message":"cannot stage config"}'; return 1; }
    while [ "$#" -ge 2 ]; do
        key="$1"
        value="$2"
        shift 2
        set_conf_val "$key" "$value" "$tmp" || {
            rm -f "$tmp"
            echo '{"status":"error","message":"invalid config key/value"}'
            return 2
        }
        changed=1
    done
    [ "$#" -eq 0 ] && [ "$changed" -eq 1 ] || {
        rm -f "$tmp"
        echo '{"status":"error","message":"invalid config arguments"}'
        return 2
    }
    chmod 644 "$tmp" 2>/dev/null
    mv -f "$tmp" "$MAIN_CONF" || {
        rm -f "$tmp"
        echo '{"status":"error","message":"config replace failed"}'
        return 1
    }
    sync_module_prop
    echo '{"status":"ok"}'
}

counter_get() {
    # $1=目录|文件，输出计数值（缺省 0）
    local v
    v=$(grep -E "^$1=" "$COUNTER_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2 | tr -d ' \r')
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    printf '%s' "$v"
}

counter_set() {
    local tmp="$COUNTER_FILE.tmp.$$"
    printf '目录=%d\n文件=%d\n' "$1" "$2" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 644 "$tmp" 2>/dev/null
    mv -f "$tmp" "$COUNTER_FILE"
}

stats_field() {
    # $1=Stats.json 数字字段名 $2=默认值
    local v
    v=$(grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9]*" "$STATS_JSON" 2>/dev/null | tail -n1 | tr -d ' ":' | sed "s/^$1//")
    case "$v" in ''|*[!0-9]*) v="$2" ;; esac
    printf '%s' "$v"
}

stats_time_field() {
    local v
    v=$(grep -o '"last_clean_time"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATS_JSON" 2>/dev/null | tail -n1 | cut -d'"' -f4)
    [ -z "$v" ] && v="$1"
    printf '%s' "$v"
}

log_event() {
    # $1=日志文件 $2=行内容
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$2" >> "$1"
}

task_owner_alive() {
    local pid="$1" marker="$2" cmd=""
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    [ -r "/proc/$pid/cmdline" ] || return 0
    cmd=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    case "$cmd" in *"$SCRIPT_PATH"*"$marker"*) return 0 ;; *) return 1 ;; esac
}

reclaim_stale_task_lock() {
    # $1=锁目录 $2=进程命令行标记；用独立恢复锁串行化陈旧锁回收。
    local lock="$1" marker="$2" recovery="${1}.recover" owner current stale_dir
    mkdir "$recovery" 2>/dev/null || return 1
    owner=$(cat "$lock/pid" 2>/dev/null | tr -d ' \r\n')
    case "$owner" in ''|*[!0-9]*) rmdir "$recovery" 2>/dev/null; return 1 ;; esac
    if task_owner_alive "$owner" "$marker"; then
        rmdir "$recovery" 2>/dev/null
        return 1
    fi
    current=$(cat "$lock/pid" 2>/dev/null | tr -d ' \r\n')
    if [ "$current" != "$owner" ]; then
        rmdir "$recovery" 2>/dev/null
        return 1
    fi
    stale_dir="$lock.stale.$$"
    if [ -e "$stale_dir" ] || ! mv "$lock" "$stale_dir" 2>/dev/null; then
        rmdir "$recovery" 2>/dev/null
        return 1
    fi
    rm -f "$stale_dir/pid" 2>/dev/null
    rmdir "$stale_dir" 2>/dev/null
    rmdir "$recovery" 2>/dev/null
    return 0
}

rotate_log_file() {
    # $1=日志路径 $2=最大字节数；仅保留一个轮转副本，限制长期增长。
    local file="$1" limit="$2" size
    [ -f "$file" ] || return 0
    size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) return 0 ;; esac
    [ "$size" -gt "$limit" ] || return 0
    mv -f "$file" "$file.1" 2>/dev/null || return 1
    : > "$file"
    chmod 644 "$file" 2>/dev/null
}


# ---------------------------------------------------------------- 环境初始化

ensure_timing_conf() {
    # 旧版本只有每天时间；升级后补齐“执行方式 / 间隔”字段。
    if [ ! -f "$TIMING_CONF" ]; then
        cat > "$TIMING_CONF" <<'EOF_TIMING'
# AutoPurge Pro 定时清理配置 (Author: liancan)
# 【Set_Mode】执行方式：daily=每天固定时间，interval=按间隔执行
# 【Set_Interval】间隔数值；【Set_Interval_Unit】单位 minute/hour/day
#   分钟 10-1440，小时 1-720，天 1-30
# 每天时间：【Set_Time1】0-23，【Set_minute1】0-59，【Set_weekday1】1-7 或 *
# 可通过 WebUI 直接修改并立即生效，也可手动修改后执行 Timing_Settings.sh

Set_Mode=daily
Set_Interval=6
Set_Interval_Unit=hour

Set_Time1=0
Set_minute1=00
Set_weekday1=*

# 兼容旧版字段
Set_Time2=12
Set_minute2=00
Set_weekday2=*
EOF_TIMING
        chmod 644 "$TIMING_CONF" 2>/dev/null
        return 0
    fi
    if ! grep -qE "^[[:space:]]*Set_Mode[[:space:]]*=" "$TIMING_CONF" 2>/dev/null; then
        printf '\n# 执行方式：daily=每天固定时间；interval=按间隔\nSet_Mode=daily\n' >> "$TIMING_CONF"
    fi
    if ! grep -qE "^[[:space:]]*Set_Interval[[:space:]]*=" "$TIMING_CONF" 2>/dev/null; then
        printf 'Set_Interval=6\n' >> "$TIMING_CONF"
    fi
    if ! grep -qE "^[[:space:]]*Set_Interval_Unit[[:space:]]*=" "$TIMING_CONF" 2>/dev/null; then
        printf 'Set_Interval_Unit=hour\n' >> "$TIMING_CONF"
    fi
}

init_env() {
    local init_tmp
    mkdir -p "$LIST_DIR" "$TIMING_DIR" "$MODDIR/cron.d"

    # 缺失配置通过临时文件初始化，避免断电留下半截文件。
    if [ ! -f "$MAIN_CONF" ]; then
        init_tmp="$MAIN_CONF.init.$$"
        cat > "$init_tmp" <<'EOF_MAINCONF'
// AutoPurge Pro 全局配置文件 (Author: liancan)
master_switch=true
timed_cleaning=true
mt_cleaning=true
log_cleaning=true
log_purge_size=2M
apk_cleaning=false
module_residue_cleaning=false
file_organize=false
blacklist_cleaning=true
EOF_MAINCONF
        chmod 644 "$init_tmp" 2>/dev/null
        mv -f "$init_tmp" "$MAIN_CONF" || rm -f "$init_tmp"
    fi
    if ! grep -qE "^[[:space:]]*master_switch[[:space:]]*=" "$MAIN_CONF" 2>/dev/null; then
        set_conf_val master_switch true "$MAIN_CONF" || echo "master_switch=true" >> "$MAIN_CONF"
    fi

    if [ ! -f "$COUNTER_FILE" ]; then
        init_tmp="$COUNTER_FILE.init.$$"
        printf "目录=0\n文件=0\n" > "$init_tmp" && mv -f "$init_tmp" "$COUNTER_FILE" || rm -f "$init_tmp"
    fi
    [ -f "$CLEAR_LOG" ] || : > "$CLEAR_LOG"
    [ -f "$HISTORY_LOG" ] || : > "$HISTORY_LOG"

    if [ ! -f "$FILE_PATHS_CONF" ]; then
        init_tmp="$FILE_PATHS_CONF.init.$$"
        cat > "$init_tmp" <<'EOF_PATHS'
storage_root=/storage/emulated/0
download=/storage/emulated/0/Download
qq=/storage/emulated/0/QQfile_recv
wechat=/storage/emulated/0/WeChat
telegram=/storage/emulated/0/Telegram
bluetooth=/storage/emulated/0/Bluetooth
images=/storage/emulated/0/Pictures/AutoPurge
videos=/storage/emulated/0/Movies/AutoPurge
audio=/storage/emulated/0/Music/AutoPurge
apks=/storage/emulated/0/安装包/AutoPurge
modules=/storage/emulated/0/模块安装包/AutoPurge
EOF_PATHS
        chmod 600 "$init_tmp" 2>/dev/null
        mv -f "$init_tmp" "$FILE_PATHS_CONF" || rm -f "$init_tmp"
    fi

    ensure_timing_conf

    if [ ! -f "$STATS_JSON" ]; then
        init_tmp="$STATS_JSON.init.$$"
        cat > "$init_tmp" <<'EOF_STATS'
{
  "total_files": 0,
  "total_dirs": 0,
  "total_runs": 0,
  "total_freed_kb": 0,
  "observed_space_increase_kb": 0,
  "last_run_files": 0,
  "last_run_dirs": 0,
  "last_run_freed_kb": 0,
  "last_clean_time": "尚未执行"
}
EOF_STATS
        chmod 644 "$init_tmp" 2>/dev/null
        mv -f "$init_tmp" "$STATS_JSON" || rm -f "$init_tmp"
    fi
}

sync_module_prop() {
    local prop="$MODDIR/module.prop"
    [ -f "$prop" ] || return 0
    local master dirs files last_time status_tag
    master=$(get_conf_val "master_switch" "$MAIN_CONF" "true")
    dirs=$(counter_get "目录")
    files=$(counter_get "文件")
    last_time=$(stats_time_field "等待首次清理")
    status_tag="🟢运行中"
    [ "$master" = "false" ] && status_tag="⏸️已暂停"
    sed -i "s|^author=.*|author=liancan|g" "$prop"
    sed -i "s#^description=.*#description=[$status_tag] 累计清理: ${files}个文件 / ${dirs}个目录 | 上次清理: ${last_time} | 作者: liancan#g" "$prop"
}

# ---------------------------------------------------------------- 文件整理 helpers

organize_target_get() {
    # 设置 organize 目标目录到全局变量（供 move/scan 使用）
    ORG_ROOT=$(get_path_val storage_root /storage/emulated/0)
    [ -d "$ORG_ROOT" ] || ORG_ROOT="/sdcard"
    if is_protected_system_path "$ORG_ROOT"; then ORG_ROOT="/storage/emulated/0"; fi
    ORG_IMG=$(get_path_val images "$ORG_ROOT/Pictures/AutoPurge")
    ORG_VID=$(get_path_val videos "$ORG_ROOT/Movies/AutoPurge")
    ORG_AUD=$(get_path_val audio "$ORG_ROOT/Music/AutoPurge")
    ORG_APK=$(get_path_val apks "$ORG_ROOT/安装包/AutoPurge")
    ORG_MOD=$(get_path_val modules "$ORG_ROOT/模块安装包/AutoPurge")
    path_is_child_of "$ORG_IMG" "$ORG_ROOT" || ORG_IMG="$ORG_ROOT/Pictures/AutoPurge"
    path_is_child_of "$ORG_VID" "$ORG_ROOT" || ORG_VID="$ORG_ROOT/Movies/AutoPurge"
    path_is_child_of "$ORG_AUD" "$ORG_ROOT" || ORG_AUD="$ORG_ROOT/Music/AutoPurge"
    path_is_child_of "$ORG_APK" "$ORG_ROOT" || ORG_APK="$ORG_ROOT/安装包/AutoPurge"
    path_is_child_of "$ORG_MOD" "$ORG_ROOT" || ORG_MOD="$ORG_ROOT/模块安装包/AutoPurge"
}

move_one_file() {
    local f="$1" dest="$2" name base ext n target
    [ -f "$f" ] || return 0
    name="$(basename "$f")"
    target="$dest/$name"
    if [ -e "$target" ]; then
        base="${name%.*}"
        ext=""
        case "$name" in *.*) ext=".${name##*.}" ;; esac
        n=1
        while [ -e "$dest/${base} (${n})${ext}" ]; do n=$((n+1)); done
        target="$dest/${base} (${n})${ext}"
    fi
    if mv "$f" "$target" 2>/dev/null; then
        ORG_MOVED_COUNT=$((ORG_MOVED_COUNT + 1))
        log_event "$CLEAR_LOG" "[文件归位] $f -> $target"
        log_event "$HISTORY_LOG" "| 文件归位 | $f -> $target"
        return 0
    fi
    ORG_FAILED_COUNT=$((ORG_FAILED_COUNT + 1))
    log_event "$CLEAR_LOG" "[文件归位失败] $f -> $target"
    return 1
}

classify_file() {
    # $1=文件路径，按扩展名/文件名分类归档
    local f="$1" ext name_lc
    case "$f" in "$ORG_IMG"/*|"$ORG_VID"/*|"$ORG_AUD"/*|"$ORG_APK"/*|"$ORG_MOD"/*) return 0 ;; esac
    ext=$(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]')
    name_lc=$(basename "$f" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        jpg|jpeg|png|webp|gif|bmp|heic|dng|tif|tiff) move_one_file "$f" "$ORG_IMG" ;;
        mp4|mkv|mov|avi|flv|webm|3gp|mpeg|mpg|m4v) move_one_file "$f" "$ORG_VID" ;;
        mp3|flac|wav|aac|ogg|m4a|wma|opus) move_one_file "$f" "$ORG_AUD" ;;
        apk|xapk|apks) move_one_file "$f" "$ORG_APK" ;;
        *) case "$name_lc" in
               *module*.zip|*magisk*.zip|*ksu*.zip|*apatch*.zip|*kernelsu*.zip) move_one_file "$f" "$ORG_MOD" ;;
           esac ;;
    esac
}

organize_source_dirs() {
    # 输出全部扫描来源目录（每行一个）
    local root
    root=$(get_path_val storage_root /storage/emulated/0)
    [ -d "$root" ] || root="/sdcard"
    if is_protected_system_path "$root"; then root="/storage/emulated/0"; fi
    local p
    p=$(get_path_val download "$root/Download"); path_is_child_of "$p" "$root" || p="$root/Download"; printf '%s\n' "$p"
    p=$(get_path_val qq "$root/QQfile_recv"); path_is_child_of "$p" "$root" || p="$root/QQfile_recv"; printf '%s\n' "$p"
    p=$(get_path_val wechat "$root/WeChat"); path_is_child_of "$p" "$root" || p="$root/WeChat"; printf '%s\n' "$p"
    p=$(get_path_val telegram "$root/Telegram"); path_is_child_of "$p" "$root" || p="$root/Telegram"; printf '%s\n' "$p"
    p=$(get_path_val bluetooth "$root/Bluetooth"); path_is_child_of "$p" "$root" || p="$root/Bluetooth"; printf '%s\n' "$p"
    printf '%s\n' \
        "$root/Tencent/QQfile_recv" \
        "$root/Android/data/com.tencent.mobileqq/Tencent/QQfile_recv" \
        "$root/Android/data/com.tencent.mm/MicroMsg/Download" \
        "$root/Android/data/org.telegram.messenger/files/Telegram" \
        "$root/Telegram/Telegram Documents" \
        "$root/Telegram/Telegram Images" \
        "$root/Telegram/Telegram Video"
}

# ---------------------------------------------------------------- 清理子任务

clean_apk_packages() {
    local sw now_str p download_path storage_root
    sw=$(get_conf_val "apk_cleaning" "$MAIN_CONF" "false")
    [ "$sw" = "true" ] || return 0

    # 仅清理用户明确配置的下载目录；不扫描其他应用私有缓存/数据目录。
    storage_root=$(get_path_val storage_root "/storage/emulated/0")
    [ -d "$storage_root" ] || storage_root="/sdcard"
    if is_protected_system_path "$storage_root"; then
        log_event "$CLEAR_LOG" "[APK清理] 跳过受保护的存储根目录: $storage_root"
        return 0
    fi
    download_path=$(get_path_val download "$storage_root/Download")
    if ! path_is_child_of "$download_path" "$storage_root"; then
        log_event "$CLEAR_LOG" "[APK清理] 跳过不在存储根目录内的下载路径: $download_path"
        return 0
    fi
    [ -d "$download_path" ] || return 0
    [ ! -L "$download_path" ] || {
        log_event "$CLEAR_LOG" "[APK清理] 跳过符号链接目录: $download_path"
        return 0
    }

    now_str=$(date '+%Y-%m-%d %H:%M:%S')
    find "$download_path" -maxdepth 2 -type f -name "*.apk" -print 2>/dev/null |
    while IFS= read -r apk; do
        [ -f "$apk" ] && [ ! -L "$apk" ] || continue
        case "$apk" in "$download_path"/*) ;; *) continue ;; esac
        if rm -f "$apk" 2>/dev/null; then
            printf '%s %s\n' "$now_str" "[APK清理] 删除安装包: $apk" >> "$CLEAR_LOG"
            printf '%s | APK清理 | %s\n' "$now_str" "$apk" >> "$HISTORY_LOG"
        fi
    done
}

clean_module_residues() {
    local sw now_str stale
    sw=$(get_conf_val "module_residue_cleaning" "$MAIN_CONF" "false")
    [ "$sw" = "true" ] || return 0

    # 安全边界：只处理当前 AutoPurge-Pro 模块自身目录。
    # 不扫描其他模块目录，也不触碰 modules_update / service.d / post-fs-data.d。
    [ -n "$MODDIR" ] && [ -d "$MODDIR" ] && [ ! -L "$MODDIR" ] || {
        log_event "$CLEAR_LOG" "[模块残留] 跳过：模块目录无效或为符号链接"
        return 0
    }

    now_str=$(date '+%Y-%m-%d %H:%M:%S')
    find "$MODDIR" -type f \( -name "*.bak" -o -name "*.backup" \) -print 2>/dev/null |
    while IFS= read -r stale; do
        [ -f "$stale" ] && [ ! -L "$stale" ] || continue
        case "$stale" in
            "$MODDIR"/*) ;;
            *) continue ;;
        esac
        if rm -f "$stale" 2>/dev/null; then
            printf '%s %s\n' "$now_str" "[模块残留] 删除本模块备份文件: $stale" >> "$CLEAR_LOG"
            printf '%s | 模块残留 | %s\n' "$now_str" "$stale" >> "$HISTORY_LOG"
        fi
    done
}

log_mt_output() {
    # 解析 MTClear 输出中 "已清理:" 的行并写入日志；$2=是否同时写 CLEAR_LOG
    local mt_out="$1" with_clear="$2" now_str cleaned_path
    [ -n "$mt_out" ] || return 0
    now_str=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s\n' "$mt_out" | while IFS= read -r line; do
        case "$line" in
            *"已清理:"*)
                cleaned_path=$(printf '%s' "$line" | sed 's/.*已清理:[[:space:]]*//')
                if [ "$with_clear" = "1" ]; then
                    printf '%s [MT清理] 删除路径: %s\n' "$now_str" "$cleaned_path" >> "$CLEAR_LOG"
                fi
                printf '%s | MT清理 | %s\n' "$now_str" "$cleaned_path" >> "$HISTORY_LOG"
                ;;
        esac
    done
}

# ---------------------------------------------------------------- 文件整理主流程

organize_user_files() {
    local sw src f list_tmp source_tmp rc=0
    ORG_MOVED_COUNT=0
    ORG_FAILED_COUNT=0
    sw=$(get_conf_val "file_organize" "$MAIN_CONF" "false")
    [ "$sw" != "true" ] && [ "$1" != "force" ] && return 0
    organize_target_get
    mkdir -p "$ORG_IMG" "$ORG_VID" "$ORG_AUD" "$ORG_APK" "$ORG_MOD" 2>/dev/null || return 1

    # 每个任务使用独立临时文件，避免并发扫描/整理互相覆盖。
    list_tmp="$CONFIG_DIR/.organize_list.$$"
    source_tmp="$CONFIG_DIR/.organize_sources.$$"
    : > "$list_tmp" || return 1
    organize_source_dirs > "$source_tmp" || { rm -f "$list_tmp" "$source_tmp"; return 1; }
    while IFS= read -r src; do
        [ -d "$src" ] || continue
        find "$src" -maxdepth 2 -type f 2>/dev/null >> "$list_tmp" || rc=1
    done < "$source_tmp"
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        classify_file "$f" || :
    done < "$list_tmp"
    rm -f "$list_tmp" "$source_tmp"
    [ "$ORG_FAILED_COUNT" -eq 0 ] || rc=1
    return "$rc"
}

scan_user_files() {
    # 独立临时文件避免并发任务互相覆盖；文件名含换行符不在当前格式支持范围内。
    local list_tmp source_tmp src f ext
    list_tmp="$CONFIG_DIR/.scan_list.$$"
    source_tmp="$CONFIG_DIR/.scan_sources.$$"
    : > "$list_tmp" || return 1
    organize_source_dirs > "$source_tmp" || { rm -f "$list_tmp" "$source_tmp"; return 1; }
    while IFS= read -r src; do
        [ -d "$src" ] || continue
        find "$src" -maxdepth 2 -type f 2>/dev/null >> "$list_tmp" || :
    done < "$source_tmp"

    local total=0 images=0 videos=0 audio=0 apks=0 archives=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        total=$((total+1))
        ext=$(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]')
        case "$ext" in
            jpg|jpeg|png|webp|gif|bmp|heic|dng|tif|tiff) images=$((images+1)) ;;
            mp4|mkv|mov|avi|flv|webm|3gp|mpeg|mpg|m4v) videos=$((videos+1)) ;;
            mp3|flac|wav|aac|ogg|m4a|wma|opus) audio=$((audio+1)) ;;
            apk|xapk|apks) apks=$((apks+1)) ;;
            zip|7z|rar|tar|gz|bz2|xz) archives=$((archives+1)) ;;
        esac
    done < "$list_tmp"
    rm -f "$list_tmp" "$source_tmp"
    printf '{"status":"ok","total":%s,"images":%s,"videos":%s,"audio":%s,"apks":%s,"archives":%s}\n' "$total" "$images" "$videos" "$audio" "$apks" "$archives"
}

# ---------------------------------------------------------------- 清理主流程
# ---------------------------------------------------------------- 清理主流程

clean_lock_owner_alive() {
    local owner="$1" cmd=""
    case "$owner" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$owner" 2>/dev/null || return 1
    # PID 存活但无法确认进程身份时，按“仍在运行”处理，避免误回收锁。
    [ -r "/proc/$owner/cmdline" ] || return 0
    cmd=$(tr '\000' ' ' < "/proc/$owner/cmdline" 2>/dev/null)
    case "$cmd" in
        *"$SCRIPT_PATH"*clean*) return 0 ;;
        *) return 1 ;;
    esac
}

acquire_clean_lock() {
    local owner stale_dir
    if mkdir "$CLEAN_LOCK" 2>/dev/null; then
        printf '%s\n' "$$" > "$CLEAN_LOCK/pid" 2>/dev/null || {
            rmdir "$CLEAN_LOCK" 2>/dev/null
            return 1
        }
        return 0
    fi

    owner=$(cat "$CLEAN_LOCK/pid" 2>/dev/null | tr -d ' \r\n')
    # 空锁目录可能正处于初始化窗口；必须保守拒绝回收。
    case "$owner" in ''|*[!0-9]*) return 1 ;; esac
    if reclaim_stale_task_lock "$CLEAN_LOCK" "clean"; then
        if mkdir "$CLEAN_LOCK" 2>/dev/null; then
            printf '%s\n' "$$" > "$CLEAN_LOCK/pid" 2>/dev/null || {
                rmdir "$CLEAN_LOCK" 2>/dev/null
                return 1
            }
            return 0
        fi
    fi
    return 1
}

release_clean_lock() {
    local owner
    owner=$(cat "$CLEAN_LOCK/pid" 2>/dev/null | tr -d ' \r\n')
    [ "$owner" = "$$" ] || return 0
    rm -f "$CLEAN_LOCK/pid" 2>/dev/null
    rmdir "$CLEAN_LOCK" 2>/dev/null
}

do_cleanup() {
    local mode="${1:-all}"

    if [ "$mode" = "auto" ]; then
        local master
        master=$(get_conf_val "master_switch" "$MAIN_CONF" "true")
        if [ "$master" = "false" ]; then
            echo "模块总开关已关闭，跳过本次自动清理"
            return 0
        fi
    fi

    local blacklist_sw mt_sw
    blacklist_sw=$(get_conf_val "blacklist_cleaning" "$MAIN_CONF" "true")
    mt_sw=$(get_conf_val "mt_cleaning" "$MAIN_CONF" "true")

    local before_dirs before_files before_lines before_avail
    before_dirs=$(counter_get "目录")
    before_files=$(counter_get "文件")
    before_lines=$(wc -l < "$CLEAR_LOG" 2>/dev/null | tr -d ' ')
    case "$before_lines" in ''|*[!0-9]*) before_lines=0 ;; esac
    before_avail=$(df -k /data 2>/dev/null | tail -n1 | awk '{print $4}')
    case "$before_avail" in ''|*[!0-9]*) before_avail=0 ;; esac

    local run_files=0 run_dirs=0

    chmod 755 "$MODDIR/bin/TimingClear" "$MODDIR/bin/MTClear" 2>/dev/null

    if [ "$mode" = "mt" ]; then
        local mt_out
        mt_out=$("$MODDIR/bin/MTClear" 2>&1)
        log_mt_output "$mt_out" 1
        local mt_hits
        mt_hits=$(printf '%s\n' "$mt_out" | grep -c "已清理:")
        case "$mt_hits" in ''|*[!0-9]*) mt_hits=0 ;; esac
        if [ "$mt_hits" -gt 0 ]; then
            counter_set "$before_dirs" "$((before_files + mt_hits))"
        fi
    else
        [ "$blacklist_sw" = "true" ] && [ -x "$MODDIR/bin/TimingClear" ] && "$MODDIR/bin/TimingClear" >/dev/null 2>&1
        if [ "$mode" = "manual" ] || [ "$mt_sw" = "true" ]; then
            if [ -x "$MODDIR/bin/MTClear" ]; then
                local mt_out_all
                mt_out_all=$("$MODDIR/bin/MTClear" 2>&1)
                log_mt_output "$mt_out_all" 0
            fi
        fi
    fi

    clean_apk_packages
    clean_module_residues
    organize_user_files

    local after_dirs after_files
    after_dirs=$(counter_get "目录")
    after_files=$(counter_get "文件")
    # Counter 文件缺失/损坏时保留清理前的值，避免统计回退
    if [ ! -s "$COUNTER_FILE" ]; then
        after_dirs="$before_dirs"
        after_files="$before_files"
    fi

    run_dirs=$((after_dirs - before_dirs))
    run_files=$((after_files - before_files))
    [ "$run_dirs" -lt 0 ] && run_dirs=0
    [ "$run_files" -lt 0 ] && run_files=0

    # 把本轮 Clear.log 新增的删除记录同步到历史明细
    local after_lines
    after_lines=$(wc -l < "$CLEAR_LOG" 2>/dev/null | tr -d ' ')
    case "$after_lines" in ''|*[!0-9]*) after_lines=0 ;; esac
    if [ "$after_lines" -gt "$before_lines" ]; then
        local diff_lines=$((after_lines - before_lines))
        tail -n "$diff_lines" "$CLEAR_LOG" 2>/dev/null | while IFS= read -r logline; do
            case "$logline" in
                *"删除文件"*|*"删除目录"*)
                    local ts action_type target_p
                    ts=$(printf '%s' "$logline" | awk '{print $1, $2}')
                    action_type="删除文件"
                    case "$logline" in *"删除目录"*) action_type="删除目录" ;; esac
                    target_p=$(printf '%s' "$logline" | sed -E 's/^[0-9-]+ [0-9:]+ 删除(文件|目录):?[[:space:]]*//')
                    printf '%s | %s | %s\n' "$ts" "$action_type" "$target_p" >> "$HISTORY_LOG"
                    ;;
            esac
        done
    fi

    # 历史日志不再硬截断行数；统一在本轮历史同步完成后按字节轮转。

    local after_avail freed_kb
    after_avail=$(df -k /data 2>/dev/null | tail -n1 | awk '{print $4}')
    case "$after_avail" in ''|*[!0-9]*) after_avail="$before_avail" ;; esac
    # df 差值只能表示 /data 可用空间变化，不能归因于本模块。
    # 不再用文件数估算释放空间；异常/负值统一记为 0，避免制造虚假释放量。
    freed_kb=$((after_avail - before_avail))
    [ "$freed_kb" -lt 0 ] && freed_kb=0

    local prev_runs prev_freed prev_observed total_runs total_freed_kb total_observed now_str
    prev_runs=$(stats_field "total_runs" 0)
    prev_freed=$(stats_field "total_freed_kb" 0)
    prev_observed=$(stats_field "observed_space_increase_kb" 0)
    total_runs=$((prev_runs + 1))
    # total_freed_kb 保留旧版兼容；新 UI 使用独立字段，避免继承旧版估算历史。
    total_freed_kb=$((prev_freed + freed_kb))
    total_observed=$((prev_observed + freed_kb))
    now_str=$(date '+%Y-%m-%d %H:%M:%S')

    local stats_tmp="$STATS_JSON.tmp.$$"
    cat > "$stats_tmp" <<EOF_STATS2
{
  "total_files": $after_files,
  "total_dirs": $after_dirs,
  "total_runs": $total_runs,
  "total_freed_kb": $total_freed_kb,
  "observed_space_increase_kb": $total_observed,
  "last_run_files": $run_files,
  "last_run_dirs": $run_dirs,
  "last_run_freed_kb": $freed_kb,
  "last_run_space_delta_kb": $freed_kb,
  "space_metric": "filesystem_available_delta",
  "last_clean_time": "$now_str"
}
EOF_STATS2
    if [ -s "$stats_tmp" ]; then
        chmod 644 "$stats_tmp" 2>/dev/null
        mv -f "$stats_tmp" "$STATS_JSON" || rm -f "$stats_tmp"
    else
        rm -f "$stats_tmp"
    fi
    chmod 644 "$HISTORY_LOG" "$COUNTER_FILE" "$CLEAR_LOG" 2>/dev/null
    # 清理完成并同步历史明细后再轮转，避免影响本轮日志差量解析。
    rotate_log_file "$CLEAR_LOG" 1048576
    rotate_log_file "$HISTORY_LOG" 1048576
    sync_module_prop
    printf '{"status":"ok","run_files":%s,"run_dirs":%s,"freed_kb":%s,"time":"%s"}\n' "$run_files" "$run_dirs" "$freed_kb" "$now_str"
}

run_cleanup() {
    if ! acquire_clean_lock; then
        echo '{"status":"already_running"}'
        return 0
    fi
    do_cleanup "${1:-all}"
    local rc=$?
    release_clean_lock
    return $rc
}

# ---------------------------------------------------------------- 服务编排

apply_services() {
    init_env
    local master timed mt logc
    master=$(get_conf_val "master_switch" "$MAIN_CONF" "true")
    timed=$(get_conf_val "timed_cleaning" "$MAIN_CONF" "true")
    mt=$(get_conf_val "mt_cleaning" "$MAIN_CONF" "true")
    logc=$(get_conf_val "log_cleaning" "$MAIN_CONF" "true")

    if [ "$master" = "false" ]; then
        pkill -f "$MODDIR/bin/MainControl" 2>/dev/null
        pkill -f "$MODDIR/bin/SmartClear" 2>/dev/null
        pkill -f "$MODDIR/bin/LogClear" 2>/dev/null
        AUTOPURGE_MODDIR="$MODDIR" /system/bin/sh "$TIMING_DIR/Timing_Settings.sh" stop >/dev/null 2>&1
        chmod 644 "$MODDIR/bin/TimingClear" 2>/dev/null
    else
        if [ -x "$MODDIR/bin/MainControl" ] && ! pgrep -f "$MODDIR/bin/MainControl" >/dev/null 2>&1; then
            /system/bin/sh "$MODDIR/Service_Config/Service_Main"
        fi
        if [ "$timed" = "true" ]; then
            chmod 755 "$MODDIR/bin/TimingClear" 2>/dev/null
            AUTOPURGE_MODDIR="$MODDIR" /system/bin/sh "$TIMING_DIR/Timing_Settings.sh" >/dev/null 2>&1
        else
            chmod 644 "$MODDIR/bin/TimingClear" 2>/dev/null
            AUTOPURGE_MODDIR="$MODDIR" /system/bin/sh "$TIMING_DIR/Timing_Settings.sh" stop >/dev/null 2>&1
        fi
        if [ "$mt" = "true" ]; then
            if [ -x "$MODDIR/bin/SmartClear" ] && ! pgrep -f "$MODDIR/bin/SmartClear" >/dev/null 2>&1; then
                /system/bin/sh "$MODDIR/Service_Config/Service_Smart"
            fi
        else
            pkill -f "$MODDIR/bin/SmartClear" 2>/dev/null
        fi
        if [ "$logc" = "true" ]; then
            if [ -x "$MODDIR/bin/LogClear" ] && ! pgrep -f "$MODDIR/bin/LogClear" >/dev/null 2>&1; then
                /system/bin/sh "$MODDIR/Service_Config/Service_Log"
            fi
        else
            pkill -f "$MODDIR/bin/LogClear" 2>/dev/null
        fi
    fi
    sync_module_prop
    echo '{"status":"ok"}'
}

# ---------------------------------------------------------------- 状态查询

# 一次扫描完成三个守护进程检测，避免多次 pgrep 全表扫描拖慢状态读取。
daemons_scan() {
    DAEMON_MAIN=false
    DAEMON_SMART=false
    DAEMON_LOG=false
    local pids="" p cmd
    if command -v pgrep >/dev/null 2>&1; then
        pids=$(pgrep -f "$MODDIR/bin/" 2>/dev/null)
        for p in $pids; do
            [ -r "/proc/$p/cmdline" ] || continue
            cmd=$(tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null)
            case "$cmd" in
                *"$MODDIR/bin/MainControl"*) DAEMON_MAIN=true ;;
                *"$MODDIR/bin/SmartClear"*) DAEMON_SMART=true ;;
                *"$MODDIR/bin/LogClear"*) DAEMON_LOG=true ;;
            esac
        done
    else
        for p in /proc/[0-9]*; do
            [ -r "$p/cmdline" ] || continue
            cmd=$(tr '\000' ' ' < "$p/cmdline" 2>/dev/null)
            case "$cmd" in
                *"$MODDIR/bin/MainControl"*) DAEMON_MAIN=true ;;
                *"$MODDIR/bin/SmartClear"*) DAEMON_SMART=true ;;
                *"$MODDIR/bin/LogClear"*) DAEMON_LOG=true ;;
            esac
        done
    fi
}

interval_running() {
    local pid_file="$MODDIR/interval.pid" pid cmd
    [ -f "$pid_file" ] || { echo false; return; }
    pid=$(cat "$pid_file" 2>/dev/null | tr -d ' \r\n')
    case "$pid" in ''|*[!0-9]*) echo false; return ;; esac
    kill -0 "$pid" 2>/dev/null || { echo false; return; }
    [ -r "/proc/$pid/cmdline" ] || { echo false; return; }
    cmd=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    case "$cmd" in
        *interval_daemon.sh*) echo true ;;
        *) echo false ;;
    esac
}

interval_next_epoch() {
    local v
    v=$(sed -n 's/^next=//p' "$TIMING_DIR/interval.state" 2>/dev/null | head -n1 | tr -d ' \r')
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    printf '%s' "$v"
}

crond_running() {
    local pid_file="$MODDIR/cron.pid" pid cmd
    [ -f "$pid_file" ] || { echo false; return; }
    pid=$(cat "$pid_file" 2>/dev/null | tr -d ' \r\n')
    case "$pid" in ''|*[!0-9]*) echo false; return ;; esac
    kill -0 "$pid" 2>/dev/null || { echo false; return; }
    [ -r "/proc/$pid/cmdline" ] || { echo false; return; }
    cmd=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    case "$cmd" in
        *crond*"$MODDIR/cron.d"*) echo true ;;
        *) echo false ;;
    esac
}

get_status_json() {
    init_env
    local master timed mt logc logsize apkc modres fileorg blacklistc
    master=$(get_conf_val "master_switch" "$MAIN_CONF" "true")
    timed=$(get_conf_val "timed_cleaning" "$MAIN_CONF" "true")
    mt=$(get_conf_val "mt_cleaning" "$MAIN_CONF" "true")
    logc=$(get_conf_val "log_cleaning" "$MAIN_CONF" "true")
    logsize=$(get_conf_val "log_purge_size" "$MAIN_CONF" "2M")
    apkc=$(get_conf_val "apk_cleaning" "$MAIN_CONF" "false")
    modres=$(get_conf_val "module_residue_cleaning" "$MAIN_CONF" "false")
    fileorg=$(get_conf_val "file_organize" "$MAIN_CONF" "false")
    blacklistc=$(get_conf_val "blacklist_cleaning" "$MAIN_CONF" "true")

    # 布尔值规范化，保证 JSON 合法
    norm_bool() { case "$1" in true) echo true ;; false) echo false ;; *) echo "$2" ;; esac }
    master=$(norm_bool "$master" true)
    timed=$(norm_bool "$timed" true)
    mt=$(norm_bool "$mt" true)
    logc=$(norm_bool "$logc" true)
    apkc=$(norm_bool "$apkc" false)
    modres=$(norm_bool "$modres" false)
    fileorg=$(norm_bool "$fileorg" false)
    blacklistc=$(norm_bool "$blacklistc" true)
    case "$logsize" in 512K|1M|2M|5M|10M) ;; *) logsize=2M ;; esac

    local t1 m1 w1 t2 m2 w2
    t1=$(get_conf_val "Set_Time1" "$TIMING_CONF" "0")
    m1=$(get_conf_val "Set_minute1" "$TIMING_CONF" "00")
    w1=$(get_conf_val "Set_weekday1" "$TIMING_CONF" "*")
    t2=$(get_conf_val "Set_Time2" "$TIMING_CONF" "12")
    m2=$(get_conf_val "Set_minute2" "$TIMING_CONF" "00")
    w2=$(get_conf_val "Set_weekday2" "$TIMING_CONF" "*")

    # 配置值进入 JSON 前统一做白名单校验，避免手工配置破坏 JSON。
    case "$t1" in ''|*[!0-9]*) t1=0 ;; esac
    [ "$t1" -le 23 ] 2>/dev/null || t1=0
    case "$m1" in ''|*[!0-9]*) m1=0 ;; esac
    [ "$m1" -le 59 ] 2>/dev/null || m1=0
    case "$w1" in 1|2|3|4|5|6|7|'*') ;; *) w1='*' ;; esac
    case "$t2" in ''|*[!0-9]*) t2=12 ;; esac
    [ "$t2" -le 23 ] 2>/dev/null || t2=12
    case "$m2" in ''|*[!0-9]*) m2=0 ;; esac
    [ "$m2" -le 59 ] 2>/dev/null || m2=0
    case "$w2" in 1|2|3|4|5|6|7|'*') ;; *) w2='*' ;; esac

    local dirs files
    dirs=$(counter_get "目录")
    files=$(counter_get "文件")

    local total_runs total_freed_kb observed_space_increase_kb last_run_files last_run_dirs last_clean_time
    total_runs=$(stats_field "total_runs" 0)
    total_freed_kb=$(stats_field "total_freed_kb" 0)
    observed_space_increase_kb=$(stats_field "observed_space_increase_kb" 0)
    last_run_files=$(stats_field "last_run_files" 0)
    last_run_dirs=$(stats_field "last_run_dirs" 0)
    last_clean_time=$(json_escape "$(stats_time_field "尚未执行")")

    local pid_main pid_smart pid_log pid_cron pid_interval scheduler
    daemons_scan
    pid_main=$DAEMON_MAIN
    pid_smart=$DAEMON_SMART
    pid_log=$DAEMON_LOG
    pid_cron=$(crond_running)
    pid_interval=$(interval_running)
    if [ "$pid_cron" = "true" ] || [ "$pid_interval" = "true" ]; then
        scheduler=true
    else
        scheduler=false
    fi

    local s_mode s_interval s_unit s_next
    s_mode=$(get_conf_val "Set_Mode" "$TIMING_CONF" "daily")
    case "$s_mode" in daily|interval) ;; *) s_mode=daily ;; esac
    s_interval=$(get_conf_val "Set_Interval" "$TIMING_CONF" "6")
    case "$s_interval" in ''|*[!0-9]*) s_interval=6 ;; esac
    s_unit=$(get_conf_val "Set_Interval_Unit" "$TIMING_CONF" "hour")
    case "$s_unit" in minute|hour|day) ;; *) s_unit=hour ;; esac
    s_next=$(interval_next_epoch)
    [ "$s_mode" = "interval" ] || s_next=0

    local disk_info disk_total_kb disk_used_kb disk_avail_kb
    disk_info=$(df -k /data 2>/dev/null | tail -n1)
    disk_total_kb=$(printf '%s\n' "$disk_info" | awk '{print $2}')
    disk_used_kb=$(printf '%s\n' "$disk_info" | awk '{print $3}')
    disk_avail_kb=$(printf '%s\n' "$disk_info" | awk '{print $4}')
    case "$disk_total_kb" in ''|*[!0-9]*) disk_total_kb=104857600 ;; esac
    case "$disk_used_kb" in ''|*[!0-9]*) disk_used_kb=52428800 ;; esac
    case "$disk_avail_kb" in ''|*[!0-9]*) disk_avail_kb=52428800 ;; esac

    local bl_count wl_count mt_count log_size_bytes
    bl_count=$(grep -vE '^[[:space:]]*(#|$)' "$BLACKLIST" 2>/dev/null | wc -l | tr -d ' ')
    wl_count=$(grep -vE '^[[:space:]]*(#|$)' "$WHITELIST" 2>/dev/null | wc -l | tr -d ' ')
    mt_count=$(grep -vE '^[[:space:]]*(#|$)' "$MTLIST" 2>/dev/null | wc -l | tr -d ' ')
    case "$bl_count" in ''|*[!0-9]*) bl_count=0 ;; esac
    case "$wl_count" in ''|*[!0-9]*) wl_count=0 ;; esac
    case "$mt_count" in ''|*[!0-9]*) mt_count=0 ;; esac
    log_size_bytes=$(wc -c < "$CLEAR_LOG" 2>/dev/null | tr -d ' ')
    case "$log_size_bytes" in ''|*[!0-9]*) log_size_bytes=0 ;; esac

    cat <<EOF_STATUS
{
  "config": {
    "master_switch": $master,
    "timed_cleaning": $timed,
    "mt_cleaning": $mt,
    "log_cleaning": $logc,
    "log_purge_size": "$logsize",
    "apk_cleaning": $apkc,
    "module_residue_cleaning": $modres,
    "file_organize": $fileorg,
    "blacklist_cleaning": $blacklistc
  },
  "schedule": {
    "mode": "$s_mode",
    "interval": "$s_interval",
    "interval_unit": "$s_unit",
    "next_run_epoch": $s_next,
    "scheduler_running": $scheduler,
    "t1": "$t1",
    "m1": "$m1",
    "w1": "$w1",
    "t2": "$t2",
    "m2": "$m2",
    "w2": "$w2"
  },
  "stats": {
    "total_files": $files,
    "total_dirs": $dirs,
    "total_runs": $total_runs,
    "total_freed_kb": $total_freed_kb,
    "observed_space_increase_kb": $observed_space_increase_kb,
    "last_run_files": $last_run_files,
    "last_run_dirs": $last_run_dirs,
    "last_clean_time": "$last_clean_time",
    "bl_count": $bl_count,
    "wl_count": $wl_count,
    "mt_count": $mt_count,
    "log_size_bytes": $log_size_bytes
  },
  "daemons": {
    "main_control": $pid_main,
    "smart_clear": $pid_smart,
    "log_clear": $pid_log,
    "crond": $scheduler,
    "interval": $pid_interval
  },
  "storage": {
    "total_kb": $disk_total_kb,
    "used_kb": $disk_used_kb,
    "avail_kb": $disk_avail_kb
  }
}
EOF_STATUS
}

preview_cleanup() {
    init_env
    local list_tmp path size count=0 bytes=0 shown=0 first=1 kind download_path storage_root apk_sw residue_sw
    list_tmp="$CONFIG_DIR/.preview_list.$$"
    : > "$list_tmp" || { echo '{"status":"error","message":"cannot create preview list"}'; return 1; }

    apk_sw=$(get_conf_val "apk_cleaning" "$MAIN_CONF" "false")
    residue_sw=$(get_conf_val "module_residue_cleaning" "$MAIN_CONF" "false")

    if [ "$apk_sw" = "true" ]; then
        storage_root=$(get_path_val storage_root "/storage/emulated/0")
        [ -d "$storage_root" ] || storage_root="/sdcard"
        if is_protected_system_path "$storage_root"; then
            storage_root="/storage/emulated/0"
        fi
        download_path=$(get_path_val download "$storage_root/Download")
        if path_is_child_of "$download_path" "$storage_root" && [ -d "$download_path" ] && [ ! -L "$download_path" ]; then
            find "$download_path" -maxdepth 2 -type f -name "*.apk" -print 2>/dev/null >> "$list_tmp"
        fi
    fi

    if [ "$residue_sw" = "true" ] && [ -n "$MODDIR" ] && [ -d "$MODDIR" ] && [ ! -L "$MODDIR" ]; then
        find "$MODDIR" -type f \( -name "*.bak" -o -name "*.backup" \) -print 2>/dev/null >> "$list_tmp"
    fi

    printf '{"status":"ok","scope":"shell_managed_only","count":'
    count=$(wc -l < "$list_tmp" 2>/dev/null | tr -d ' ')
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    printf '%s,"bytes":' "$count"

    # 逐项统计真实逻辑大小；JSON 明细最多返回 100 条，防止大目录撑爆 WebView。
    while IFS= read -r path; do
        [ -f "$path" ] && [ ! -L "$path" ] || continue
        size=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
        case "$size" in ''|*[!0-9]*) size=0 ;; esac
        bytes=$((bytes + size))
    done < "$list_tmp"
    printf '%s,"items":[' "$bytes"

    while IFS= read -r path; do
        [ -f "$path" ] && [ ! -L "$path" ] || continue
        [ "$shown" -lt 100 ] || continue
        size=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
        case "$size" in ''|*[!0-9]*) size=0 ;; esac
        kind=apk
        case "$path" in "$MODDIR"/*) kind=module_backup ;; esac
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"type":"%s","path":"%s","size":%s}' "$kind" "$(json_escape "$path")" "$size"
        shown=$((shown + 1))
    done < "$list_tmp"
    rm -f "$list_tmp"
    printf '],"shown":%s,"truncated":' "$shown"
    if [ "$count" -gt 100 ]; then printf 'true'; else printf 'false'; fi
    printf ',"note":"仅预览 Shell 可识别的 APK 与本模块备份文件；TimingClear/MTClear 等闭源程序的清理目标不在预览范围内，且本命令不会删除文件。"}\n'
}

get_version_json() {
    local ver code
    ver=$(get_conf_val "version" "$MODDIR/module.prop" "unknown")
    code=$(get_conf_val "versionCode" "$MODDIR/module.prop" "0")
    case "$code" in ''|*[!0-9]*) code=0 ;; esac
    printf '{"version":"%s","versionCode":%s}\n' "$(json_escape "$ver")" "$code"
}

# ---------------------------------------------------------------- 清理任务入口

start_cleanup() {
    local mode="${2:-manual}" owner stale_dir pid
    init_env
    if ! mkdir "$CLEAN_TASK_LOCK" 2>/dev/null; then
        owner=$(cat "$CLEAN_TASK_LOCK/pid" 2>/dev/null | tr -d ' \r\n')
        case "$owner" in ''|*[!0-9]*) echo '{"status":"already_running"}'; return 0 ;; esac
        if ! reclaim_stale_task_lock "$CLEAN_TASK_LOCK" "__cleanup_worker"; then
            echo '{"status":"already_running"}'
            return 0
        fi
        mkdir "$CLEAN_TASK_LOCK" 2>/dev/null || { echo '{"status":"already_running"}'; return 0; }
    fi

    rm -f "$CLEAN_PID"
    echo running > "$CLEAN_STATE"
    sh "$SCRIPT_PATH" __cleanup_worker "$mode" </dev/null >/dev/null 2>&1 &
    pid=$!
    printf '%s\n' "$pid" > "$CLEAN_PID" || {
        kill "$pid" 2>/dev/null
        rm -f "$CLEAN_STATE" "$CLEAN_PID"
        rmdir "$CLEAN_TASK_LOCK" 2>/dev/null
        echo '{"status":"error","message":"cannot record worker PID"}'
        return 1
    }
    printf '%s\n' "$pid" > "$CLEAN_TASK_LOCK/pid" || {
        kill "$pid" 2>/dev/null
        rm -f "$CLEAN_STATE" "$CLEAN_PID"
        rmdir "$CLEAN_TASK_LOCK" 2>/dev/null
        echo '{"status":"error","message":"cannot record task lock owner"}'
        return 1
    }
    echo '{"status":"started"}'
}

cleanup_worker() {
    local mode="${2:-manual}" n=0 owner rc
    while [ "$n" -lt 10 ]; do
        owner=$(cat "$CLEAN_TASK_LOCK/pid" 2>/dev/null | tr -d ' \r\n')
        [ "$owner" = "$$" ] && break
        sleep 1
        n=$((n+1))
    done
    [ "$owner" = "$$" ] || return 1
    init_env
    run_cleanup "$mode" > "$CLEAN_WORKER_LOG" 2>&1
    rc=$?
    echo "done:$rc" > "$CLEAN_STATE"
    [ "$(cat "$CLEAN_PID" 2>/dev/null | tr -d ' \r\n')" = "$$" ] && rm -f "$CLEAN_PID"
    rm -f "$CLEAN_TASK_LOCK/pid" 2>/dev/null
    rmdir "$CLEAN_TASK_LOCK" 2>/dev/null
    return "$rc"
}

cleanup_status() {
    init_env
    local state="idle" pid="" owner
    [ -f "$CLEAN_STATE" ] && state=$(cat "$CLEAN_STATE" 2>/dev/null | tr -d ' \r\n')
    if [ "$state" = "running" ]; then
        [ -f "$CLEAN_PID" ] && pid=$(cat "$CLEAN_PID" 2>/dev/null | tr -d ' \r\n')
        if ! task_owner_alive "$pid" "__cleanup_worker"; then
            state="done:1"
            echo "$state" > "$CLEAN_STATE"
            [ "$(cat "$CLEAN_PID" 2>/dev/null | tr -d ' \r\n')" = "$pid" ] && rm -f "$CLEAN_PID"
            owner=$(cat "$CLEAN_TASK_LOCK/pid" 2>/dev/null | tr -d ' \r\n')
            [ "$owner" = "$pid" ] && { rm -f "$CLEAN_TASK_LOCK/pid"; rmdir "$CLEAN_TASK_LOCK" 2>/dev/null; }
        fi
    fi
    case "$state" in
        running) echo '{"status":"running"}' ;;
        done:0) echo '{"status":"done","success":true}' ;;
        done:*) echo '{"status":"done","success":false}' ;;
        *) echo '{"status":"idle"}' ;;
    esac
}

# ---------------------------------------------------------------- 文件任务入口

start_file_task() {
    local task="${2:-scan}" owner stale_dir pid
    init_env
    case "$task" in scan|organize) ;; *) echo '{"status":"error","message":"unknown task"}'; return 2 ;; esac
    if ! mkdir "$FILE_TASK_LOCK" 2>/dev/null; then
        owner=$(cat "$FILE_TASK_LOCK/pid" 2>/dev/null | tr -d ' \r\n')
        case "$owner" in ''|*[!0-9]*) echo '{"status":"already_running"}'; return 0 ;; esac
        if ! reclaim_stale_task_lock "$FILE_TASK_LOCK" "__file_worker"; then
            echo '{"status":"already_running"}'
            return 0
        fi
        mkdir "$FILE_TASK_LOCK" 2>/dev/null || { echo '{"status":"already_running"}'; return 0; }
    fi

    rm -f "$FILE_TASK_PID" "$FILE_TASK_RESULT"
    echo "running:$task" > "$FILE_TASK_STATE"
    sh "$SCRIPT_PATH" __file_worker "$task" </dev/null >/dev/null 2>&1 &
    pid=$!
    printf '%s\n' "$pid" > "$FILE_TASK_PID" || {
        kill "$pid" 2>/dev/null
        rm -f "$FILE_TASK_STATE" "$FILE_TASK_PID"
        rmdir "$FILE_TASK_LOCK" 2>/dev/null
        echo '{"status":"error","message":"cannot record worker PID"}'
        return 1
    }
    printf '%s\n' "$pid" > "$FILE_TASK_LOCK/pid" || {
        kill "$pid" 2>/dev/null
        rm -f "$FILE_TASK_STATE" "$FILE_TASK_PID"
        rmdir "$FILE_TASK_LOCK" 2>/dev/null
        echo '{"status":"error","message":"cannot record task lock owner"}'
        return 1
    }
    echo '{"status":"started"}'
}

file_task_worker() {
    local task="${2:-scan}" n=0 owner rc=0
    while [ "$n" -lt 10 ]; do
        owner=$(cat "$FILE_TASK_LOCK/pid" 2>/dev/null | tr -d ' \r\n')
        [ "$owner" = "$$" ] && break
        sleep 1
        n=$((n+1))
    done
    [ "$owner" = "$$" ] || return 1
    init_env
    if [ "$task" = "scan" ]; then
        scan_user_files > "$FILE_TASK_RESULT" 2> "$FILE_TASK_LOG"
        rc=$?
    else
        organize_user_files force > "$FILE_TASK_LOG" 2>&1
        rc=$?
        printf '{"status":"%s","message":"文件归位任务结束","moved":%s,"failed":%s}\n' "$([ "$rc" -eq 0 ] && echo ok || echo error)" "$ORG_MOVED_COUNT" "$ORG_FAILED_COUNT" > "$FILE_TASK_RESULT"
    fi
    echo "done:$task:$rc" > "$FILE_TASK_STATE"
    [ "$(cat "$FILE_TASK_PID" 2>/dev/null | tr -d ' \r\n')" = "$$" ] && rm -f "$FILE_TASK_PID"
    rm -f "$FILE_TASK_LOCK/pid" 2>/dev/null
    rmdir "$FILE_TASK_LOCK" 2>/dev/null
    return "$rc"
}

file_task_status() {
    init_env
    local state="idle" pid="" task="" result="" owner
    [ -f "$FILE_TASK_STATE" ] && state=$(cat "$FILE_TASK_STATE" 2>/dev/null | tr -d ' \r\n')
    case "$state" in
        running:*)
            task=${state#running:}
            [ -f "$FILE_TASK_PID" ] && pid=$(cat "$FILE_TASK_PID" 2>/dev/null | tr -d ' \r\n')
            if task_owner_alive "$pid" "__file_worker"; then
                printf '{"status":"running","task":"%s"}\n' "$task"
                return 0
            fi
            state="done:$task:1"
            echo "$state" > "$FILE_TASK_STATE"
            [ "$(cat "$FILE_TASK_PID" 2>/dev/null | tr -d ' \r\n')" = "$pid" ] && rm -f "$FILE_TASK_PID"
            owner=$(cat "$FILE_TASK_LOCK/pid" 2>/dev/null | tr -d ' \r\n')
            [ "$owner" = "$pid" ] && { rm -f "$FILE_TASK_LOCK/pid"; rmdir "$FILE_TASK_LOCK" 2>/dev/null; }
            ;;
    esac
    case "$state" in
        done:scan:0)
            result=$(cat "$FILE_TASK_RESULT" 2>/dev/null)
            if [ -n "$result" ]; then
                printf '{"status":"done","task":"scan","result":%s}\n' "$result"
            else
                echo '{"status":"error","task":"scan"}'
            fi
            ;;
        done:organize:0)
            result=$(cat "$FILE_TASK_RESULT" 2>/dev/null)
            [ -n "$result" ] && printf '{"status":"done","task":"organize","result":%s}\n' "$result" || echo '{"status":"error","task":"organize"}'
            ;;
        done:*) echo '{"status":"error","task":"unknown","message":"后台任务异常结束，请查看 FileTask.log"}' ;;
        *) echo '{"status":"idle"}' ;;
    esac
}

# ---------------------------------------------------------------- 统计维护
# ---------------------------------------------------------------- 统计维护

reset_stats() {
    init_env
    local counter_tmp="$COUNTER_FILE.tmp.$$" stats_tmp="$STATS_JSON.tmp.$$"
    printf "目录=0\n文件=0\n" > "$counter_tmp" || {
        rm -f "$counter_tmp"
        echo '{"status":"error","message":"counter write failed"}'
        return 1
    }
    cat > "$stats_tmp" <<'EOF_RST'
{
  "total_files": 0,
  "total_dirs": 0,
  "total_runs": 0,
  "total_freed_kb": 0,
  "observed_space_increase_kb": 0,
  "last_run_files": 0,
  "last_run_dirs": 0,
  "last_run_freed_kb": 0,
  "last_run_space_delta_kb": 0,
  "space_metric": "filesystem_available_delta",
  "last_clean_time": "已重置"
}
EOF_RST
    if [ ! -s "$stats_tmp" ]; then
        rm -f "$counter_tmp" "$stats_tmp"
        echo '{"status":"error","message":"stats write failed"}'
        return 1
    fi
    chmod 644 "$counter_tmp" "$stats_tmp" 2>/dev/null
    mv -f "$counter_tmp" "$COUNTER_FILE" || {
        rm -f "$counter_tmp" "$stats_tmp"
        echo '{"status":"error","message":"counter replace failed"}'
        return 1
    }
    mv -f "$stats_tmp" "$STATS_JSON" || {
        rm -f "$stats_tmp"
        echo '{"status":"error","message":"stats replace failed"}'
        return 1
    }
    sync_module_prop
    echo '{"status":"ok"}'
}

# ---------------------------------------------------------------- 命令分发

case "$1" in
    status)
        get_status_json
        ;;
    clean)
        run_cleanup "${2:-manual}"
        ;;
    start_clean)
        start_cleanup "$@"
        ;;
    clean_status)
        cleanup_status
        ;;
    scan_files)
        start_file_task "$@" scan
        ;;
    organize_files)
        start_file_task "$@" organize
        ;;
    file_task_status)
        file_task_status
        ;;
    apply)
        apply_services
        ;;
    set_config)
        set_config_cmd "$@"
        ;;
    preview_cleanup)
        preview_cleanup
        ;;
    version)
        get_version_json
        ;;
    __cleanup_worker)
        cleanup_worker "$@"
        ;;
    __file_worker)
        file_task_worker "$@"
        ;;
    reset_stats)
        reset_stats
        ;;
    clear_logs)
        init_env
        : > "$CLEAR_LOG"
        : > "$HISTORY_LOG"
        rm -f "$CLEAR_LOG.1" "$HISTORY_LOG.1"
        echo '{"status":"ok"}'
        ;;
    *)
        echo "Usage: $0 {status|clean [auto|manual|mt]|start_clean [mode]|clean_status|scan_files|organize_files|file_task_status|set_config|preview_cleanup|apply|version|reset_stats|clear_logs}"
        ;;
esac
