#!/bin/sh
# Temp supplement (not a Skill file): capture via resident traced, substituting
# the live app TGID into the perf scope, and starting traced_perf if missing.
CFG=$1; OUT=$2; D=/userdata/perfetto-training-demo; TB=$D/bin/perfetto/tracebox
pidof traced_perf >/dev/null 2>&1 || { $TB traced_perf --background >/dev/null 2>&1; sleep 2; }
APPPID=$(cat $D/run/app.pid)
rm -rf "$OUT"; mkdir -p "$OUT" || exit 2
sed "s/TARGET_PID_HERE/$APPPID/" "$CFG" > "$OUT/config.pbtxt"
{ date; echo "uptime: $(cat /proc/uptime)"; echo "app_pid: $APPPID"; echo "traced_perf: $(pidof traced_perf)"; } > "$OUT/env.txt"
"$D/bin/perfetto/perfetto" --txt -c "$OUT/config.pbtxt" -o "$OUT/trace.pftrace" \
   --background-wait > "$OUT/start.log" 2>&1
echo "start_rc=$?" >> "$OUT/env.txt"
PID=$(tail -1 "$OUT/start.log" | tr -d ' \n')
i=0
while [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 1; i=$((i+1)); done
echo "waited_s=$i" >> "$OUT/env.txt"
{ echo "end: $(date)"; echo "uptime: $(cat /proc/uptime)"; echo "app_pid_now: $(cat $D/run/app.pid)"; } >> "$OUT/env.txt"
ls -l "$OUT/trace.pftrace" >> "$OUT/env.txt" 2>&1
sha256sum "$OUT/trace.pftrace" >> "$OUT/env.txt" 2>&1
cat "$OUT/env.txt"
