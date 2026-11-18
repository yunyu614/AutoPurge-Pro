#!/system/bin/sh
# AutoPurge Pro 定时清理入口脚本
# Author: liancan

MODDIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/Clear_Rubbish"
[ -d "$MODDIR" ] || MODDIR="/data/adb/ksu/modules/Clear_Rubbish"

/system/bin/sh "$MODDIR/bin/autopurge_ctl.sh" clean auto >/dev/null 2>&1
