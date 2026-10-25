#!/bin/sh
# Board-side single capture driver (FIRST_PASS, run 1). Non-destructive:
# starts only the documented pf-cpu-case default mode and this session's own
# tracebox; does not touch sysctl, other tracing sessions or other programs.
set -eu
WORK=/userdata/perfetto-cpu-session
CFG=$WORK/cpu_firstpass.pbtxt
APP=/userdata/perfetto-skill-lab/cpu/pf-cpu-case
APPDIR=/userdata/perfetto-skill-lab/cpu
PREFIX=$WORK/cpu_firstpass

echo "=== pre: pgrep ==="
pgrep -x pf-cpu-case && { echo "ALREADY_RUNNING refuse"; exit 20; } || echo "not_running"
pgrep -x tracebox && { echo "OTHER_TRACEBOX refuse"; exit 21; } || echo "no_other_tracebox"
echo "=== pre: loadavg / stat ==="
cat /proc/loadavg
head -1 /proc/stat

echo "=== start app ($(date +%s%N)) ==="
setsid nohup "$APP" > "$APPDIR/run.log" 2>&1 < /dev/null &
sleep 4
pgrep -x pf-cpu-case >/dev/null || { echo "APP_NOT_STARTED"; exit 22; }
echo "app pids: $(pgrep -x pf-cpu-case | tr '\n' ' ')"
echo "csv head at capture start:"; head -1 "$APPDIR/heartbeat_latency.csv"

echo "=== capture start $(date +%s%N) ==="
RC=0
WORK=$WORK TRACEBOX=$WORK/tracebox \
  sh "$WORK/linux_trace_session.sh" "$CFG" cpu_firstpass 45 || RC=$?
echo "=== capture rc=$RC end $(date +%s%N) ==="

# Snapshot the PUBLIC latency record and observable program state only.
cp -f "$APPDIR/heartbeat_latency.csv" "$WORK/heartbeat_latency.public.csv" || true
{
  echo "# post-capture public state  $(date +%s%N)"
  echo "## pgrep -x pf-cpu-case"; pgrep -x pf-cpu-case | tr '\n' ' '; echo
  echo "## ps -o pid,stat,etime,rss,comm"
  ps -o pid,stat,etime,rss,comm $(pgrep -x pf-cpu-case | tr '\n' ' ') 2>/dev/null || true
  echo "## /proc/loadavg"; cat /proc/loadavg
  echo "## run.log (program stdout, public)"; cat "$APPDIR/run.log"
  echo "## cpufreq now"; for c in /sys/devices/system/cpu/cpu[0-7]; do printf "%s=%s " "${c##*/}" "$(cat $c/cpufreq/scaling_cur_freq 2>/dev/null)"; done; echo
  echo "## governor"; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo none
} > "$WORK/post_capture_state.txt" 2>&1

ls -l "$WORK"/cpu_firstpass.* "$WORK"/heartbeat_latency.public.csv "$WORK"/post_capture_state.txt
cat "$WORK"/cpu_firstpass.status 2>/dev/null || true
cat "$WORK"/cpu_firstpass.log 2>/dev/null || true
exit 0
