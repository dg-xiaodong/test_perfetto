#!/bin/sh
# Capture only; producer lifecycle handled explicitly by the caller.
CFG=$1; OUT=$2; D=/userdata/perfetto-training-demo
APPPID=$(cat $D/run/app.pid)
rm -rf "$OUT"; mkdir -p "$OUT" || exit 2
sed "s/TARGET_PID_HERE/$APPPID/" "$CFG" > "$OUT/config.pbtxt"
{ date; echo "uptime: $(cat /proc/uptime)"; echo "app_pid: $APPPID";
  echo "traced_perf_count: $(ps -ef | grep 'tracebox traced_perf' | grep -v grep | wc -l)"; } > "$OUT/env.txt"
"$D/bin/perfetto/perfetto" --txt -c "$OUT/config.pbtxt" -o "$OUT/trace.pftrace" \
   --background-wait > "$OUT/start.log" 2>&1
echo "start_rc=$?" >> "$OUT/env.txt"
PID=$(tail -1 "$OUT/start.log" | tr -d ' \n')
i=0
while [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 1; i=$((i+1)); done
{ echo "waited_s=$i"; echo "end: $(date)"; echo "uptime: $(cat /proc/uptime)";
  echo "app_pid_now: $(cat $D/run/app.pid)"; } >> "$OUT/env.txt"
ls -l "$OUT/trace.pftrace" >> "$OUT/env.txt" 2>&1
sha256sum "$OUT/trace.pftrace" >> "$OUT/env.txt" 2>&1
cat "$OUT/env.txt"
