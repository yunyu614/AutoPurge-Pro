#!/system/bin/sh
# AutoPurge Pro 快捷清理操作脚本 (KernelSU / Magisk Action Button)
# Author: liancan

MODDIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/Clear_Rubbish"
[ -d "$MODDIR" ] || MODDIR="/data/adb/ksu/modules/Clear_Rubbish"

echo "=========================================="
echo "   AutoPurge Pro - 立即清理 (by liancan)  "
echo "=========================================="
echo "- 正在扫描并清理黑名单与MT垃圾目录..."
res=$(/system/bin/sh "$MODDIR/bin/autopurge_ctl.sh" clean manual)
echo "- 清理完成！"
echo "- 结果摘要: $res"
echo "=========================================="
