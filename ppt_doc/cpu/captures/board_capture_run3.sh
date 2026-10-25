#!/bin/sh
# Board-side capture (instance pid 8143, busy shared board).
# Non-destructive: only starts this session's own tracebox; the documented
# pf-cpu-case instance is already running and is NOT restarted or stopped.
# Other workloads (pf-lat-case, pf-sched-case) are left untouched.
set -eu
WORK=/userdata/perfetto-cpu-session
CFG=$WORK/cpu_run3.pbtxt
APPDIR=/userdata/perfetto-skill-lab/cpu
PIN=0,4            # keep the observer off cpu1/cpu2 (workload) and cpu5/6/7 (other cases)

cat > "$WORK/tracebox_pinned2.sh" <<EOF
#!/bin/sh
exec /usr/bin/taskset -c $PIN $WORK/tracebox "\$@"
EOF
chmod +x "$WORK/tracebox_pinned2.sh"

echo "=== pre: subject ==="
PID=$(pgrep -x pf-cpu-case | head -1)
[ -n "$PID" ] || { echo "APP_NOT_RUNNING"; exit 22; }
echo "app pid=$PID uptime=$(ps -o etime= -p $PID | tr -d ' ')"
for t in /proc/$PID/task/*; do printf "%s %-14s cpus=%s\n" "${t##*/}" "$(cat $t/comm)" "$(awk '/Cpus_allowed_list/{print $2}' $t/status)"; done

echo "=== pre: other workloads (NOT touched) ==="
for p in $(pgrep -f pf-lat-case) $(pgrep -f pf-sched-case); do
  [ -d /proc/$p ] && echo "  foreign pid=$p comm=$(cat /proc/$p/comm) cpus=$(awk '/Cpus_allowed_list/{print $2}' /proc/$p/status)"
done
echo "=== pre: tracing must be free ==="
pgrep -x tracebox && { echo "OTHER_TRACEBOX refuse"; exit 21; } || echo "no_other_tracebox"
printf "tracing_on="; cat /sys/kernel/debug/tracing/tracing_on
printf "current_tracer="; cat /sys/kernel/debug/tracing/current_tracer
printf "loadavg="; cat /proc/loadavg

echo "=== capture start $(date +%s%N) ==="
RC=0
WORK=$WORK TRACEBOX=$WORK/tracebox_pinned2.sh \
  sh "$WORK/linux_trace_session.sh" "$CFG" cpu_run3 60 || RC=$?
echo "=== capture rc=$RC end $(date +%s%N) ==="

cp -f "$APPDIR/heartbeat_latency.csv" "$WORK/heartbeat_latency.run3.csv"
{
  echo "## post $(date +%s%N)"
  echo "## subject"; ps -o pid,stat,etime,rss,comm -p $(pgrep -x pf-cpu-case | head -1) 2>/dev/null
  echo "## foreign"; for p in $(pgrep -f pf-lat-case) $(pgrep -f pf-sched-case); do [ -d /proc/$p ] && echo "  $p $(cat /proc/$p/comm)"; done
  echo "## loadavg"; cat /proc/loadavg
  echo "## cpufreq"; for c in /sys/devices/system/cpu/cpu[0-7]; do printf "%s=%s " "${c##*/}" "$(cat $c/cpufreq/scaling_cur_freq)"; done; echo
  echo "## tracing after"; printf "tracing_on="; cat /sys/kernel/debug/tracing/tracing_on
} > "$WORK/post_capture_run3.txt" 2>&1

ls -l "$WORK"/cpu_run3.* "$WORK"/heartbeat_latency.run3.csv
cat "$WORK"/cpu_run3.status 2>/dev/null || true
cat "$WORK"/cpu_run3.log 2>/dev/null || true
exit 0
