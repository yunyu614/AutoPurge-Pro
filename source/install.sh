##########################################################################################
# AutoPurge Pro v4.4.2 安装脚本
# Author: liancan
##########################################################################################
SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=false
LATESTARTSERVICE=true

# ---------------------------------------------------------------- 音量键向导
# 修复：旧实现 getevent -c 1 只读一条事件即返回，而一次物理按压会产生
# DOWN/SYN/UP/SYN 多条事件；同一次按压的残留事件会被下一个问题立即消费，
# 造成"按一次键，前两个问题同时被作答"。
# 新实现：等待一次完整按压（按下 -> 消费到松开事件）才返回一次选择。

read_key_event() {
    # 读取一条输入事件，仅输出 EV_KEY 行（形如 "KEY_VOLUMEUP DOWN"），其余行为空
    local line
    line=$(getevent -qlc 1 2>/dev/null) || return 1
    set -- $line
    [ "$2" = "EV_KEY" ] || return 0
    printf '%s %s\n' "$3" "$4"
}

wait_volume_key() {
    # 阻塞直到一次完整的音量键按压结束；音量+ 返回 0，音量- 返回 1
    local pressed="" ev fails=0
    while [ -z "$pressed" ]; do
        ev=$(read_key_event) || {
            fails=$((fails + 1))
            if [ "$fails" -ge 10 ]; then
                ui_print " - 音量键读取失败，采用模板默认配置"
                return 1
            fi
            sleep 1
            continue
        }
        set -- $ev
        case "$1" in
            KEY_VOLUMEUP)   pressed="up" ;;
            KEY_VOLUMEDOWN) pressed="down" ;;
        esac
    done
    # 消费本次按压剩余事件（含松开/REPEAT），保证一次按压只回答一个问题
    while :; do
        ev=$(read_key_event) || break
        set -- $ev
        [ -n "$1" ] || continue
        case "$2" in
            UP)
                case "$1" in KEY_VOLUMEUP|KEY_VOLUMEDOWN) break ;; esac
                ;;
            DOWN)
                # 按住期间另一枚音量键按下（极少见），以最后按下的为准
                case "$1" in
                    KEY_VOLUMEUP)   pressed="up" ;;
                    KEY_VOLUMEDOWN) pressed="down" ;;
                esac
                ;;
        esac
    done
    [ "$pressed" = "up" ] && return 0
    return 1
}

choose_key() {
    # 环境不支持 getevent 时直接采用模板默认值，避免安装卡死
    if ! command -v getevent >/dev/null 2>&1; then
        ui_print " - 当前环境不支持音量键选择，采用默认配置"
        return 1
    fi
    wait_volume_key
}

ask_feature() {
    # $1=序号 $2=功能名 $3=说明；输出到全局 ASK_RESULT
    ui_print ""
    ui_print ">> [$1] 是否开启【$2】？"
    ui_print "      $3"
    if choose_key; then
        ui_print "      -> 状态: [开启]"
        ASK_RESULT="true"
    else
        ui_print "      -> 状态: [关闭]"
        ASK_RESULT="false"
    fi
}

print_modname() {
    ui_print "===================================================="
    ui_print "   AutoPurge Pro v4.4.2"
    ui_print "   模块作者: liancan"
    ui_print "===================================================="
    ui_print " - 修复: WebUI 桥接探测，区分无桥接/无权限/文件缺失/超时"
    ui_print " - 优化: Root 命令统一注入 PATH，兼容 KernelSU/APatch/MMRL"
    ui_print " - 新增: 定时可按 分钟/小时/天 自定义间隔，等间隔执行"
    ui_print " - 优化: 状态读取单次扫描进程，减少 WebUI 首次加载压力"
    ui_print " - 保留: 原有清理规则、配置文件与模块 ID"
    ui_print "===================================================="
}

on_install() {
    ui_print "- 正在解压模块核心文件..."
    unzip -o "$ZIPFILE" -x "META-INF/*" -x "install.sh" -d "$MODPATH" >/dev/null 2>&1
    if [ ! -f "$MODPATH/webroot/index.html" ] || [ ! -f "$MODPATH/bin/autopurge_ctl.sh" ] || [ ! -f "$MODPATH/bin/interval_daemon.sh" ]; then
        abort "- 模块文件解压失败，请重新下载完整的 ZIP 安装包"
    fi

    TARGET_DIR="/data/media/0/Android/Clear/清理垃圾"
    mkdir -p "$TARGET_DIR/名单配置" "$TARGET_DIR/自定义定时设置"

    ui_print ""
    ui_print "------------- [ 功能定制向导 ] -------------"
    ui_print "  按 [音量+] = 开启，按 [音量-] = 关闭"
    ui_print "  每按一次对应一个问题，请逐个选择"
    ui_print "--------------------------------------------"

    ask_feature "1/3" "文件智能分类整理" \
        "自动把图片/视频/音频/安装包归档到独立目录"
    SET_ORGANIZE="$ASK_RESULT"

    ask_feature "2/3" "APK 安装包独立清理" \
        "删除下载与缓存目录中的安装包，请谨慎开启"
    SET_APK="$ASK_RESULT"

    ask_feature "3/3" "卸载模块残留清理" \
        "仅清理模块目录内明确的 .bak / .backup 备份"
    SET_MOD_RESIDUE="$ASK_RESULT"

    ui_print "--------------------------------------------"
    ui_print "  向导完成，安装后可在 WebUI 中随时修改"
    ui_print ""

    if [ ! -f "$TARGET_DIR/配置.conf" ]; then
        cp -f "$MODPATH/Configuration_File/配置.conf" "$TARGET_DIR/配置.conf"
    fi

    set_conf() {
        local k="$1" v="$2" f="$3"
        if grep -q "^[[:space:]]*${k}[[:space:]]*=" "$f" 2>/dev/null; then
            sed -i "s|^[[:space:]]*${k}[[:space:]]*=.*|${k}=${v}|g" "$f"
        else
            echo "${k}=${v}" >> "$f"
        fi
    }

    set_conf "file_organize" "$SET_ORGANIZE" "$TARGET_DIR/配置.conf"
    set_conf "apk_cleaning" "$SET_APK" "$TARGET_DIR/配置.conf"
    set_conf "module_residue_cleaning" "$SET_MOD_RESIDUE" "$TARGET_DIR/配置.conf"

    if [ ! -f "$TARGET_DIR/名单配置/黑名单.conf" ]; then
        cp -f "$MODPATH/Configuration_File/名单配置/黑名单.conf" "$TARGET_DIR/名单配置/黑名单.conf"
    fi
    if [ ! -f "$TARGET_DIR/名单配置/白名单.conf" ]; then
        cp -f "$MODPATH/Configuration_File/名单配置/白名单.conf" "$TARGET_DIR/名单配置/白名单.conf"
    fi
    if [ ! -f "$TARGET_DIR/名单配置/MT.conf" ]; then
        cp -f "$MODPATH/Configuration_File/名单配置/MT.conf" "$TARGET_DIR/名单配置/MT.conf"
    fi
    if [ ! -f "$TARGET_DIR/自定义定时设置/定时设置.conf" ]; then
        cp -f "$MODPATH/Configuration_File/自定义定时设置/定时设置.conf" "$TARGET_DIR/自定义定时设置/定时设置.conf"
    fi

    cp -f "$MODPATH/Configuration_File/自定义定时设置/Timing_Settings.sh" "$TARGET_DIR/自定义定时设置/Timing_Settings.sh"

    # 升级旧版配置：补齐间隔调度字段，不覆盖用户已设置的每天时间
    TIMING_CONF="$TARGET_DIR/自定义定时设置/定时设置.conf"
    if [ -f "$TIMING_CONF" ]; then
        if ! grep -qE "^[[:space:]]*Set_Mode[[:space:]]*=" "$TIMING_CONF" 2>/dev/null; then
            printf '\n# 执行方式：daily=每天固定时间；interval=按间隔\nSet_Mode=daily\n' >> "$TIMING_CONF"
        fi
        if ! grep -qE "^[[:space:]]*Set_Interval[[:space:]]*=" "$TIMING_CONF" 2>/dev/null; then
            printf 'Set_Interval=6\n' >> "$TIMING_CONF"
        fi
        if ! grep -qE "^[[:space:]]*Set_Interval_Unit[[:space:]]*=" "$TIMING_CONF" 2>/dev/null; then
            printf 'Set_Interval_Unit=hour\n' >> "$TIMING_CONF"
        fi
    fi

    [ -f "$TARGET_DIR/Counter" ] || printf "目录=0\n文件=0\n" > "$TARGET_DIR/Counter"
    [ -f "$TARGET_DIR/Clear.log" ] || : > "$TARGET_DIR/Clear.log"
    [ -f "$TARGET_DIR/History_Files.log" ] || : > "$TARGET_DIR/History_Files.log"

    rm -rf "$MODPATH/Configuration_File"
    ui_print "- 正在配置执行权限..."
}

set_permissions() {
    set_perm_recursive "$MODPATH" 0 0 0755 0644
    set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
    set_perm_recursive "$MODPATH/Service_Config" 0 0 0755 0755
    set_perm "$MODPATH/Main.sh" 0 0 0755
    set_perm "$MODPATH/bin/interval_daemon.sh" 0 0 0755
    set_perm "$MODPATH/action.sh" 0 0 0755
    set_perm "$MODPATH/service.sh" 0 0 0755
    set_perm "$MODPATH/uninstall.sh" 0 0 0755
    chmod 2770 "$TARGET_DIR/名单配置" 2>/dev/null
    chmod 2770 "$TARGET_DIR/自定义定时设置" 2>/dev/null
    chmod 0755 "$TARGET_DIR/自定义定时设置/Timing_Settings.sh" 2>/dev/null
    find "$TARGET_DIR/" -type f -name "*.conf" -exec chmod 644 {} + 2>/dev/null
    ui_print "- 安装完成！请在 KernelSU / APatch / MMRL 中打开 WebUI 使用。"
}
