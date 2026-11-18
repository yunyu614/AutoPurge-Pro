#!/system/bin/sh
# AutoPurge Pro uninstall cleanup. Preserve unrelated user data.
for base in /data/adb/modules/Clear_Rubbish /data/adb/ksu/modules/Clear_Rubbish; do
  [ -d "$base/cron.d" ] || continue
  pid_file="$base/cron.pid"
  pid=""
  [ -f "$pid_file" ] && pid="$(cat "$pid_file" 2>/dev/null | tr -d ' \r\n')"
  case "$pid" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "$pid" 2>/dev/null; then
        cmd="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
        case "$cmd" in *crond*"$base/cron.d"*) kill "$pid" 2>/dev/null ;; esac
      fi
      ;;
  esac
done
# Stop the interval scheduler if this module started one.
for base in /data/adb/modules/Clear_Rubbish /data/adb/ksu/modules/Clear_Rubbish; do
  pid_file="$base/interval.pid"
  [ -f "$pid_file" ] || continue
  pid="$(cat "$pid_file" 2>/dev/null | tr -d ' \r\n')"
  case "$pid" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "$pid" 2>/dev/null; then
        cmd="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
        case "$cmd" in *interval_daemon.sh*) kill "$pid" 2>/dev/null ;; esac
      fi
      ;;
  esac
done

# Stop only this module's own resident workers; retain user rules, logs and statistics.
for base in /data/adb/modules/Clear_Rubbish /data/adb/ksu/modules/Clear_Rubbish; do
  pkill -f "$base/bin/MainControl" 2>/dev/null
  pkill -f "$base/bin/SmartClear" 2>/dev/null
  pkill -f "$base/bin/LogClear" 2>/dev/null
done
