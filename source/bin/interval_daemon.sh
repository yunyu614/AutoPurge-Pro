#!/system/bin/sh
# AutoPurge Pro 间隔调度守护（v4.4.2）
# Author: liancan
#
# 为什么不用 crond 的 */N：
#   crond 的分钟/小时步进在跨小时、跨天时会截断，例如 "每 5 小时" 实际会出现
#   5/5/5/5/4 小时的间隔。本守护进程按“上一次计划时间 + 间隔”计算下一次执行，
#   任意分钟/小时/天都能保持等间隔；状态写入配置文件目录，重启后继续原计划。
#
# 用法：
#   interval_daemon.sh run     前台运行（由 Timing_Settings.sh 后台拉起）
#   interval_daemon.sh stop    停止（只在命令行校验通过时结束进程）
#   interval_daemon.sh status  输出 JSON 状态（供控制脚本读取）

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
MODDIR="${AUTOPURGE_MODDIR:-$(dirname -- "$SCRIPT_DIR")}"
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/Clear_Rubbish"
[ -d "$MODDIR" ] || MODDIR="/data/adb/ksu/modules/Clear_Rubbish"
CONFIG_DIR="${AUTOPURGE_CONFIG_DIR:-/data/media/0/Android/Clear/清理垃圾}"
TIMING_DIR="$CONFIG_DIR/自定义定时设置"
CONFIG_FILE="$TIMING_DIR/定时设置.conf"
MAIN_CONF="$CONFIG_DIR/配置.conf"
STATE_FILE="$TIMING_DIR/interval.state"
SCHED_VERSION=2
PID_FILE="$MODDIR/interval.pid"
LOCK_DIR="$MODDIR/.interval_daemon.lock"
LOG_FILE="$MODDIR/interval.log"
SCRIPT_PATH="$SCRIPT_DIR/interval_daemon.sh"

getv() {
    # $1=键 $2=文件；与控制脚本统一取最后一次定义，兼容旧配置重复键。
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" 2>/dev/null | tail -n1 | tr -d ' \r\t'
}

state_get() {
    # $1=字段名
    sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n1 | tr -d ' \r\t'
}

state_save() {
    # $1=签名 $2=下次执行的 epoch 秒
    mkdir -p "$TIMING_DIR" 2>/dev/null
    {
        printf 'sig=%s\n' "$1"
        printf 'next=%s\n' "$2"
    } > "$STATE_FILE.tmp" 2>/dev/null && mv -f "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null
    chmod 600 "$STATE_FILE" 2>/dev/null
}

interval_seconds() {
    # $1=数值 $2=单位；输出秒数，非法返回 1
    local n="$1" unit="$2"
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    case "$unit" in
        minute)
            [ "$n" -ge 10 ] && [ "$n" -le 1440 ] || return 1
            echo $((n * 60))
            ;;
        hour)
            [ "$n" -ge 1 ] && [ "$n" -le 720 ] || return 1
            echo $((n * 3600))
            ;;
        day)
            [ "$n" -ge 1 ] && [ "$n" -le 30 ] || return 1
            echo $((n * 86400))
            ;;
        *) return 1 ;;
    esac
}

unit_cn() {
    case "$1" in
        minute) echo "分钟" ;;
        hour) echo "小时" ;;
        day) echo "天" ;;
        *) echo "$1" ;;
    esac
}

pid_is_daemon() {
    local pid="$1" cmd=""
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    cmd="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    case "$cmd" in
        *"$SCRIPT_PATH"*) ;;
        *) return 1 ;;
    esac
    [ "$pid" != "$$" ] || return 1
    return 0
}

read_pid() {
    [ -f "$PID_FILE" ] || return 1
    cat "$PID_FILE" 2>/dev/null | tr -d ' \r\n'
}

acquire_daemon_lock() {
    local owner stale_dir
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || {
            rmdir "$LOCK_DIR" 2>/dev/null
            return 1
        }
        return 0
    fi
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null | tr -d ' \r\n')
    # 锁初始化窗口或损坏锁一律保守拒绝，不冒险启动第二个调度器。
    case "$owner" in ''|*[!0-9]*) return 1 ;; esac
    if pid_is_daemon "$owner"; then return 1; fi
    stale_dir="$LOCK_DIR.stale.$$"
    [ ! -e "$stale_dir" ] || return 1
    if mv "$LOCK_DIR" "$stale_dir" 2>/dev/null; then
        rm -f "$stale_dir/pid" 2>/dev/null
        rmdir "$stale_dir" 2>/dev/null
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || {
                rmdir "$LOCK_DIR" 2>/dev/null
                return 1
            }
            return 0
        fi
    fi
    return 1
}

release_daemon_lock() {
    local owner current
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null | tr -d ' \r\n')
    [ "$owner" = "$" ] || return 0
    rm -f "$LOCK_DIR/pid" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null
    current=$(read_pid)
    [ "$current" = "$" ] && rm -f "$PID_FILE"
}

stop_daemon() {
    local pid child cmd stopped=0
    pid="$(read_pid)"
    if pid_is_daemon "$pid"; then
        # 先结束 sleep 子进程，让守护进程从 sleep 中立即返回；正在执行的
        # Main.sh 不在这里结束，避免打断真实清理任务。
        for child in $(cat "/proc/$pid/task/$pid/children" 2>/dev/null); do
            case "$child" in ''|*[!0-9]*) continue ;; esac
            cmd="$(tr '\000' ' ' < "/proc/$child/cmdline" 2>/dev/null)"
            case "$cmd" in
                *sleep*) kill "$child" 2>/dev/null ;;
            esac
        done
        kill "$pid" 2>/dev/null
        while [ "$stopped" -lt 5 ] && kill -0 "$pid" 2>/dev/null; do
            sleep 1
            stopped=$((stopped + 1))
        done
        kill -9 "$pid" 2>/dev/null
    fi
    # 仅清理仍指向本次停止目标的 PID 文件，避免覆盖并发启动的新实例。
    [ "$(read_pid)" = "$pid" ] && rm -f "$PID_FILE"
}

write_pid() {
    printf '%s\n' "$$" > "$PID_FILE" 2>/dev/null || return 1
    chmod 600 "$PID_FILE" 2>/dev/null
    return 0
}

log_line() {
    [ -f "$LOG_FILE" ] || : > "$LOG_FILE" 2>/dev/null
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null
    # 日志超过约 64KB 时只保留最后 200 行
    local size
    size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$size" -gt 65536 ]; then
        tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv -f "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
    fi
}

enabled_now() {
    local master timed
    master="$(getv master_switch "$MAIN_CONF")"
    timed="$(getv timed_cleaning "$MAIN_CONF")"
    [ "$master" != "false" ] && [ "$timed" != "false" ]
}

run_loop() {
    local master timed mode n unit secs sig old_sig old_next now next remaining chunk
    local cur_mode cur_n cur_unit old_daemon

    if [ ! -f "$CONFIG_FILE" ]; then
        log_line "定时配置文件不存在，守护进程退出"
        return 1
    fi
    if ! acquire_daemon_lock; then
        log_line "已有间隔守护或锁状态异常，本次启动忽略"
        return 0
    fi
    write_pid || {
        release_daemon_lock
        log_line "无法写入 PID 文件"
        return 1
    }

    # 信号只置标志位，等待中的 sleep 子进程会被 stop_daemon 结束
    RUNNING=1
    trap 'RUNNING=0' TERM INT HUP

    log_line "间隔守护已启动（PID $$）"
    while [ "$RUNNING" = 1 ]; do
        if ! enabled_now; then
            log_line "总开关或定时开关已关闭，守护进程退出"
            break
        fi
        mode="$(getv Set_Mode "$CONFIG_FILE")"
        [ -n "$mode" ] || mode="daily"
        [ "$mode" = "interval" ] || { log_line "当前不是间隔模式，守护进程退出"; break; }
        n="$(getv Set_Interval "$CONFIG_FILE")"
        unit="$(getv Set_Interval_Unit "$CONFIG_FILE")"
        [ -n "$n" ] || n=6
        [ -n "$unit" ] || unit=hour
        secs="$(interval_seconds "$n" "$unit")" || {
            log_line "间隔配置无效（$n $unit），60 秒后重试"
            sleep 60
            continue
        }
        sig="$mode:v$SCHED_VERSION:$n:$unit"
        now="$(date +%s)"
        old_sig="$(state_get sig)"
        old_next="$(state_get next)"
        case "$old_next" in ''|*[!0-9]*) old_next=0 ;; esac
        if [ "$old_sig" != "$sig" ] || [ "$old_next" -le 0 ]; then
            next=$((now + secs))
            state_save "$sig" "$next"
            log_line "已按新计划排期：每 $n $(unit_cn "$unit")，下次执行时间戳 $next"
        else
            next="$old_next"
        fi

        # 等待到下一次执行；每 120 秒复核一次配置，界面保存后可及时生效
        while [ "$RUNNING" = 1 ]; do
            now="$(date +%s)"
            remaining=$((next - now))
            [ "$remaining" -le 0 ] && break
            chunk=120
            [ "$remaining" -lt "$chunk" ] && chunk="$remaining"
            sleep "$chunk"
            [ "$RUNNING" = 1 ] || break
            cur_mode="$(getv Set_Mode "$CONFIG_FILE")"
            cur_n="$(getv Set_Interval "$CONFIG_FILE")"
            cur_unit="$(getv Set_Interval_Unit "$CONFIG_FILE")"
            if ! enabled_now; then
                RUNNING=0
                break
            fi
            if [ "$cur_mode" != "$mode" ] || [ "$cur_n" != "$n" ] || [ "$cur_unit" != "$unit" ]; then
                log_line "检测到间隔配置变化，重新排期"
                break
            fi
        done
        [ "$RUNNING" = 1 ] || break

        now="$(date +%s)"
        [ "$now" -lt "$next" ] && continue

        # 先写入下一次计划再执行，避免清理途中重启导致开机后立即重复执行。
        now="$(date +%s)"
        next_after=$((next + secs))
        [ "$next_after" -le "$now" ] && next_after=$((now + secs))
        state_save "$sig" "$next_after"

        if enabled_now; then
            log_line "到达计划时间，开始执行自动清理"
            AUTOPURGE_MODDIR="$MODDIR" AUTOPURGE_CONFIG_DIR="$CONFIG_DIR" \
                /system/bin/sh "$MODDIR/Main.sh" >> "$LOG_FILE" 2>&1
            log_line "本轮自动清理结束"
        fi

        # 单次清理耗时超过间隔时，从结束时间重新起算，避免连续补跑。
        now="$(date +%s)"
        [ "$now" -ge "$next_after" ] && {
            next_after=$((now + secs))
            state_save "$sig" "$next_after"
        }
        next="$next_after"
    done

    release_daemon_lock
    log_line "间隔守护已退出"
}

show_status() {
    local pid next running=false
    pid="$(read_pid)"
    if pid_is_daemon "$pid"; then running=true; else pid=""; fi
    next="$(state_get next)"
    case "$next" in ''|*[!0-9]*) next=0 ;; esac
    printf '{"running":%s,"pid":"%s","next_epoch":%s,"mode":"%s","interval":"%s","unit":"%s"}\n' \
        "$running" "$pid" "$next" \
        "$(getv Set_Mode "$CONFIG_FILE")" \
        "$(getv Set_Interval "$CONFIG_FILE")" \
        "$(getv Set_Interval_Unit "$CONFIG_FILE")"
}

case "$1" in
    run) run_loop ;;
    stop) stop_daemon; echo '{"status":"stopped"}' ;;
    status) show_status ;;
    *)
        echo "Usage: $0 {run|stop|status}"
        exit 2
        ;;
esac
