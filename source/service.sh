#!/system/bin/sh
# AutoPurge Pro 开机自启守护服务
# Author: liancan

while [ "$(getprop 'sys.boot_completed')" != '1' ]; do sleep 2; done
while [ "$(getprop 'init.svc.bootanim')" != 'stopped' ]; do sleep 2; done

# 等待存储挂载完成
until [ -d "/sdcard/Android" ] && [ -w "/sdcard" ]; do
    sleep 2
done

MODDIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/Clear_Rubbish"
[ -d "$MODDIR" ] || MODDIR="/data/adb/ksu/modules/Clear_Rubbish"
CONFIG_DIR="/data/media/0/Android/Clear/清理垃圾"

chmod -R 755 "$MODDIR/bin" "$MODDIR/Service_Config" "$MODDIR/Main.sh" "$MODDIR/action.sh" 2>/dev/null
chmod 755 "$CONFIG_DIR/自定义定时设置/Timing_Settings.sh" 2>/dev/null
find "$CONFIG_DIR" -type f -name "*.conf" -exec chmod 644 {} + 2>/dev/null

# 初始化环境并按配置启动对应守护服务与crond
/system/bin/sh "$MODDIR/bin/autopurge_ctl.sh" apply >/dev/null 2>&1

rm -rf "$MODDIR/Configuration_File" 2>/dev/null
