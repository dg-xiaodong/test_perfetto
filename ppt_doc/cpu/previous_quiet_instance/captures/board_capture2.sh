#!/bin/sh
# Board-side capture 2 (FIRST_PASS, supplementary): identical workload instance,
# identical TraceConfig, ONLY the observer's CPU placement differs (tracebox
# pinned away from the workload cores) -> separates observer effect from workload effect.
set -eu
WORK=/userdata/perfetto-cpu-session
CFG=$WORK/cpu_firstpass.pbtxt
APPDIR=/userdata/perfetto-skill-lab/cpu
PIN=0,4,5,6,7

cat > "$WORK/tracebox_pinned.sh" <<EOF
#!/bin/sh
exec /usr/bin/taskset -c $PIN $WORK/tracebox "\$@"
EOF
chmod +x "$WORK/tracebox_pinned.sh"

echo "=== pre ==="
PID=$(pgrep -x pf-cpu-case | head -1)
[ -n "$PID" ] || { echo "APP_NOT_RUNNING"; exit 22; }
echo "app pid=$PID"
for t in /proc/$PID/task/*; do tid=${t##*/}; printf "%s %s cpus=%s\n" "$tid" "$(cat $t/comm)" "$(grep Cpus_allowed_list $t/status | awk '{print $2}')"; done
pgrep -x tracebox && { echo "OTHER_TRACEBOX refuse"; exit 21; } || echo "no_other_tracebox"

echo "=== capture2 start $(date +%s%N) ==="
RC=0
WORK=$WORK TRACEBOX=$WORK/tracebox_pinned.sh \
  sh "$WORK/linux_trace_session.sh" "$CFG" cpu_firstpass2 45 || RC=$?
echo "=== capture2 rc=$RC end $(date +%s%N) ==="

cp -f "$APPDIR/heartbeat_latency.csv" "$WORK/heartbeat_latency.run2.csv"
{
  echo "## capture2 post state $(date +%s%N)"
  echo "## app pid/tids"; for t in /proc/$PID/task/*; do echo "  ${t##*/} $(cat $t/comm)"; done
  echo "## pgrep"; pgrep -x pf-cpu-case | tr '\n' ' '; echo
  echo "## loadavg"; cat /proc/loadavg
  echo "## cpufreq"; for c in /sys/devices/system/cpu/cpu[0-7]; do printf "%s=%s " "${c##*/}" "$(cat $c/cpufreq/scaling_cur_freq 2>/dev/null)"; done; echo
} > "$WORK/post_capture2_state.txt" 2>&1

ls -l "$WORK"/cpu_firstpass2.* "$WORK"/heartbeat_latency.run2.csv
cat "$WORK"/cpu_firstpass2.status 2>/dev/null || true
exit 0
