#!/system/bin/sh
# AutoPurge Pro - 定时调度（每天固定时间 / 每 N 分钟·小时·天）
# 每天模式使用 BusyBox crond；间隔模式使用 interval_daemon.sh，
# 以避免 crond 步进在跨小时/跨天时被截断。

if [ -n "$AUTOPURGE_MODDIR" ]; then
  MODDIR="$AUTOPURGE_MODDIR"
else
  MODDIR="/data/adb/modules/Clear_Rubbish"
  [ -d "$MODDIR" ] || MODDIR="/data/adb/ksu/modules/Clear_Rubbish"
fi
CONFIG_DIR="${AUTOPURGE_CONFIG_DIR:-/data/media/0/Android/Clear/清理垃圾}"
CONFIG_FILE="$CONFIG_DIR/自定义定时设置/定时设置.conf"
STATE_FILE="$CONFIG_DIR/自定义定时设置/interval.state"
MAIN_CONF="$CONFIG_DIR/配置.conf"
CRON_DIR="$MODDIR/cron.d"
CRON_FILE="$CRON_DIR/root"
TMP_FILE="$CRON_FILE.tmp"
PID_FILE="$MODDIR/cron.pid"
LOG_FILE="$MODDIR/cron.log"
INTERVAL_DAEMON="$MODDIR/bin/interval_daemon.sh"
SCHED_VERSION=2

getv() {
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$2" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d ' \r\t'
}

interval_seconds() {
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

find_busybox() {
  for candidate in \
    /data/adb/ksu/bin/busybox \
    /data/adb/ap/bin/busybox \
    /data/adb/magisk/busybox \
    /system/bin/busybox; do
    if [ -x "$candidate" ] && "$candidate" --list 2>/dev/null | grep -qx crond; then
      echo "$candidate"
      return 0
    fi
  done
  if command -v busybox >/dev/null 2>&1; then
    local path_busybox
    path_busybox="$(command -v busybox)"
    if [ -x "$path_busybox" ] && "$path_busybox" --list 2>/dev/null | grep -qx crond; then
      echo "$path_busybox"
      return 0
    fi
  fi
  if command -v magisk >/dev/null 2>&1; then
    local magisk_bb
    magisk_bb="$(magisk --path 2>/dev/null)/.magisk/busybox"
    if [ -x "$magisk_bb" ] && "$magisk_bb" --list 2>/dev/null | grep -qx crond; then
      echo "$magisk_bb"
      return 0
    fi
  fi
  return 1
}

pid_is_ours() {
  local pid="$1" cmdline=""
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    cmdline="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    case "$cmdline" in *crond*"$CRON_DIR"*) return 0 ;; esac
    return 1
  fi
  # Never signal or report an unverified PID; a stale PID may have been reused.
  return 1
}

stop_crond() {
  local pid="" proc="" candidate="" cmdline="" firstarg="" n=0
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null | tr -d ' \r\n')"
  if pid_is_ours "$pid"; then
    kill "$pid" 2>/dev/null
    n=0
    while [ "$n" -lt 5 ] && kill -0 "$pid" 2>/dev/null; do
      sleep 1
      n=$((n + 1))
    done
    kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$PID_FILE"

  # Upgrade compatibility: v2.4.1 and earlier started daemonized crond
  # without a PID file. Stop only processes whose command line names this
  # module's dedicated cron directory; never stop the system-wide crond.
  for proc in /proc/[0-9]*; do
    [ -r "$proc/cmdline" ] || continue
    candidate="${proc##*/}"
    case "$candidate" in ''|*[!0-9]*) continue ;; esac
    firstarg="$(tr '\000' '\n' < "$proc/cmdline" 2>/dev/null | head -n 1)"
    # Only inspect actual BusyBox/crond executables; never match a shell whose
    # -c command text happens to contain the module cron path.
    case "$firstarg" in */busybox|busybox|crond) ;; *) continue ;; esac
    cmdline="$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null)"
    case "$cmdline" in
      *crond*"$CRON_DIR"*)
        [ "$candidate" = "$$" ] && continue
        kill "$candidate" 2>/dev/null
        ;;
    esac
  done
}

interval_running() {
  [ -f "$INTERVAL_DAEMON" ] || return 1
  AUTOPURGE_MODDIR="$MODDIR" AUTOPURGE_CONFIG_DIR="$CONFIG_DIR" \
    /system/bin/sh "$INTERVAL_DAEMON" status 2>/dev/null | grep -q '"running":true'
}

stop_interval() {
  [ -f "$INTERVAL_DAEMON" ] || return 0
  AUTOPURGE_MODDIR="$MODDIR" AUTOPURGE_CONFIG_DIR="$CONFIG_DIR" \
    /system/bin/sh "$INTERVAL_DAEMON" stop >/dev/null 2>&1
}

state_sig() {
  sed -n 's/^sig=//p' "$STATE_FILE" 2>/dev/null | head -n1 | tr -d ' \r\t'
}

# ---------------------------------------------------------------- 停止

if [ "$1" = "stop" ]; then
  stop_crond
  stop_interval
  echo "定时服务已停止"
  exit 0
fi

# ---------------------------------------------------------------- 读取与校验

[ -f "$CONFIG_FILE" ] || { echo "错误：定时配置文件不存在"; exit 1; }

MODE="$(getv Set_Mode "$CONFIG_FILE")"
[ -n "$MODE" ] || MODE="daily"
case "$MODE" in daily|interval) ;; *) MODE="daily" ;; esac

HOUR="$(getv Set_Time1 "$CONFIG_FILE")"
MINUTE="$(getv Set_minute1 "$CONFIG_FILE")"
[ -n "$HOUR" ] || HOUR=3
[ -n "$MINUTE" ] || MINUTE=0
if [ "$MODE" = "daily" ]; then
  case "$HOUR" in *[!0-9]*|'') echo "错误：小时必须为 0-23"; exit 1 ;; esac
  case "$MINUTE" in *[!0-9]*|'') echo "错误：分钟必须为 0-59"; exit 1 ;; esac
  [ "$HOUR" -ge 0 ] 2>/dev/null && [ "$HOUR" -le 23 ] 2>/dev/null || { echo "错误：小时超出范围"; exit 1; }
  [ "$MINUTE" -ge 0 ] 2>/dev/null && [ "$MINUTE" -le 59 ] 2>/dev/null || { echo "错误：分钟超出范围"; exit 1; }
  HOUR="$(echo "$HOUR" | sed 's/^0*//')"
  MINUTE="$(echo "$MINUTE" | sed 's/^0*//')"
  [ -n "$HOUR" ] || HOUR=0
  [ -n "$MINUTE" ] || MINUTE=0
else
  # 间隔模式不使用每天时间，坏值不影响调度
  case "$HOUR" in ''|*[!0-9]*) HOUR=0 ;; esac
  case "$MINUTE" in ''|*[!0-9]*) MINUTE=0 ;; esac
fi

INTERVAL_N="$(getv Set_Interval "$CONFIG_FILE")"
INTERVAL_UNIT="$(getv Set_Interval_Unit "$CONFIG_FILE")"
[ -n "$INTERVAL_N" ] || INTERVAL_N=6
[ -n "$INTERVAL_UNIT" ] || INTERVAL_UNIT=hour
case "$INTERVAL_UNIT" in minute|hour|day) ;; *) INTERVAL_UNIT="hour" ;; esac

MASTER="$(getv master_switch "$MAIN_CONF")"
TIMED="$(getv timed_cleaning "$MAIN_CONF")"
if [ "$MASTER" = "false" ] || [ "$TIMED" = "false" ]; then
  stop_crond
  stop_interval
  echo "定时配置已保存；总开关或定时开关关闭，后台任务未启动"
  exit 0
fi

# ---------------------------------------------------------------- 间隔模式

if [ "$MODE" = "interval" ]; then
  interval_seconds "$INTERVAL_N" "$INTERVAL_UNIT" >/dev/null || {
    echo "错误：间隔无效（分钟 10-1440 / 小时 1-720 / 天 1-30）"
    exit 1
  }
  SIG="interval:v$SCHED_VERSION:$INTERVAL_N:$INTERVAL_UNIT"
  # 配置没变化且守护已运行时不重启，避免打断正在执行的清理。
  if interval_running && [ "$(state_sig)" = "$SIG" ]; then
    echo "定时服务已运行：每 $INTERVAL_N $(unit_cn "$INTERVAL_UNIT")，配置未变化"
    exit 0
  fi
  stop_crond
  stop_interval
  mkdir -p "$MODDIR" || { echo "错误：无法写入模块目录"; exit 1; }
  AUTOPURGE_MODDIR="$MODDIR" AUTOPURGE_CONFIG_DIR="$CONFIG_DIR" \
    /system/bin/sh "$INTERVAL_DAEMON" run </dev/null >/dev/null 2>&1 &
  sleep 1
  if interval_running; then
    echo "定时任务已启动并确认运行：每 $INTERVAL_N $(unit_cn "$INTERVAL_UNIT")（间隔模式）"
    exit 0
  fi
  echo "错误：间隔守护启动失败；请检查 $MODDIR/interval.log"
  exit 1
fi

# ---------------------------------------------------------------- 每天模式

stop_interval
mkdir -p "$CRON_DIR" || { echo "错误：无法创建定时目录"; exit 1; }
printf '%s %s * * * /system/bin/sh %s/Main.sh\n' "$MINUTE" "$HOUR" "$MODDIR" > "$TMP_FILE" || { echo "错误：写入 Cron 文件失败"; exit 1; }
chmod 600 "$TMP_FILE" 2>/dev/null
mv -f "$TMP_FILE" "$CRON_FILE" || { echo "错误：更新 Cron 文件失败"; exit 1; }

# Reuse a verified instance; otherwise stop only the PID recorded by this module.
if [ -f "$PID_FILE" ]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null | tr -d ' \r\n')"
  if pid_is_ours "$OLD_PID"; then
    echo "定时服务已运行，配置已更新：每天 $(printf '%02d:%02d' "$HOUR" "$MINUTE")"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

BB="$(find_busybox)" || { echo "错误：未找到包含 crond applet 的 BusyBox；Cron 配置已保存但未启动"; exit 1; }
: >> "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null
# Keep crond in foreground so its exact PID can be tracked. Redirect all
# standard streams before backgrounding; this avoids relying on an optional
# nohup applet in minimal Android/KernelSU environments.
"$BB" crond -f -c "$CRON_DIR" -L "$LOG_FILE" </dev/null >/dev/null 2>&1 &
CROND_PID=$!
if ! printf '%s\n' "$CROND_PID" > "$PID_FILE"; then
  kill "$CROND_PID" 2>/dev/null
  echo "错误：无法写入 Cron PID 文件；定时服务已停止"
  exit 1
fi
chmod 600 "$PID_FILE" 2>/dev/null
sleep 1
if pid_is_ours "$CROND_PID"; then
  echo "定时任务已启动并确认运行：每天 $(printf '%02d:%02d' "$HOUR" "$MINUTE")（PID $CROND_PID）"
  exit 0
fi
rm -f "$PID_FILE"
echo "错误：crond 启动后立即退出；请检查 BusyBox 版本及 $LOG_FILE"
exit 1
