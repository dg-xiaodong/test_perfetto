#!/bin/sh
# Temp supplement (not a Skill file): robust remote capture via the resident
# system traced, with traced_perf started as an extra producer if missing.
CFG=$1; OUT=$2; D=/userdata/perfetto-training-demo; TB=$D/bin/perfetto/tracebox
pidof traced_perf >/dev/null 2>&1 || { $TB traced_perf --background >/dev/null 2>&1; sleep 2; }
rm -rf "$OUT"; mkdir -p "$OUT" || exit 2
cp "$CFG" "$OUT/config.pbtxt"
{ date; echo "uptime: $(cat /proc/uptime)"; echo "app_pid: $(cat $D/run/app.pid 2>/dev/null)"; echo "traced_perf: $(pidof traced_perf)"; } > "$OUT/env.txt"
"$D/bin/perfetto/perfetto" --txt -c "$OUT/config.pbtxt" -o "$OUT/trace.pftrace" \
   --background-wait > "$OUT/start.log" 2>&1
echo "start_rc=$?" >> "$OUT/env.txt"
PID=$(tail -1 "$OUT/start.log" | tr -d ' \n')
echo "session_pid=$PID" >> "$OUT/env.txt"
i=0
while [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 1; i=$((i+1)); done
wait $PID 2>/dev/null
echo "waited_s=$i" >> "$OUT/env.txt"
{ echo "end: $(date)"; echo "uptime: $(cat /proc/uptime)"; echo "app_pid_now: $(cat $D/run/app.pid 2>/dev/null)"; } >> "$OUT/env.txt"
ls -l "$OUT/trace.pftrace" >> "$OUT/env.txt" 2>&1
sha256sum "$OUT/trace.pftrace" >> "$OUT/env.txt" 2>&1
tail -3 "$OUT/env.txt"
