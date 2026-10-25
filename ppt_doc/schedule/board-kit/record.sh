#!/bin/sh
# Target-side Linux tracebox runner. Fixed-duration config, direct child PID,
# official notify byte, bounded stop, explicit exit code. NEVER starts/stops app.
# Usage: TRACEBOX=/absolute/tracebox sh record.sh CONFIG NEW_OUTPUT_DIR [TIMEOUT_S]
# Requires POSIX sh + cp/mkdir/cat/awk/sleep/od/wc. No Python on target.
set -u
CFG=${1:-}; OUT=${2:-}; TIMEOUT=${3:-75}
READY_LIMIT=${READY_TIMEOUT_S:-15}; STOP_LIMIT=${STOP_TIMEOUT_S:-10}
TB=${TRACEBOX:-}
case "$OUT" in /*) ;; *) echo 'ERROR: output must be a NEW absolute directory' >&2;exit 2;; esac
for n in "$TIMEOUT" "$READY_LIMIT" "$STOP_LIMIT"; do
 case "$n" in ''|*[!0-9]*|0) echo 'ERROR: positive integer timeouts required' >&2;exit 2;; esac
done
[ -r "$CFG" ] && [ -x "$TB" ] || { echo 'ERROR: readable config and executable TRACEBOX required' >&2;exit 2; }
command -v od >/dev/null 2>&1 || { echo 'ERROR: od required to verify notify byte' >&2;exit 2; }
if [ "${SKIP_TRACEFS_CHECK:-0}" != 1 ]; then
 for tf in /sys/kernel/debug/tracing /sys/kernel/tracing; do
  if [ -r "$tf/tracing_on" ] && [ -r "$tf/events/enable" ]; then
   on=$(cat "$tf/tracing_on"); ev=$(cat "$tf/events/enable")
   if [ "$on" = 1 ] && [ "$ev" != 0 ]; then
    echo 'BLOCKED: tracing already enabled; do not stop another session' >&2;exit 3
   fi
  fi
 done
fi
# mkdir without -p prevents clobbering a previous run or concurrent run.
mkdir "$OUT" || { echo 'ERROR: output exists or parent missing' >&2;exit 2; }
cp "$CFG" "$OUT/config.pbtxt" || exit 2
if grep -q 'scheduling.switch' "$CFG"; then
 tids=$(grep -oE '(prev_pid|pid) == [0-9]+' "$CFG" | awk '{print $3}' | sort -u)
 [ -n "$tids" ] || { echo TARGET_FILTER_MISSING >"$OUT/status.txt";exit 2; }
 for t in $tids; do
  [ -r "/proc/$t/stat" ] || { echo "TARGET_NOT_RUNNING tid=$t" >"$OUT/status.txt";exit 2; }
  printf 'tid=%s ' "$t" >>"$OUT/targets-before.txt"
  cat "/proc/$t/stat" >>"$OUT/targets-before.txt"
 done
fi
"$TB" --help >"$OUT/help.txt" 2>&1
if ! grep -q -- '--notify-fd' "$OUT/help.txt"; then
 echo NOT_READY_UNSUPPORTED_NOTIFY >"$OUT/status.txt";exit 3
fi
PID=''; START=''
proc_identity() {
 [ -n "$PID" ] && [ -r "/proc/$PID/stat" ] || return 1
 _stat=$(cat "/proc/$PID/stat" 2>/dev/null) || return 1
 _rest=${_stat##*) }
 set -- $_rest
 [ "$#" -ge 20 ] || return 1
 _state=$1
 [ "$_state" != Z ] && [ "$_state" != X ] || return 1
 shift 19
 printf '%s\n' "$1"
}
alive() {
 [ -n "$PID" ] && [ -n "$START" ] || return 1
 _id=$(proc_identity) || return 1
 [ "$_id" = "$START" ]
}
stop_child() {
 alive || return 0
 kill -TERM "$PID" 2>/dev/null || true
 _i=0
 while alive && [ "$_i" -lt "$STOP_LIMIT" ]; do sleep 1;_i=$((_i+1));done
 if alive; then kill -KILL "$PID" 2>/dev/null || true;return 1;fi
 return 0
}
cleanup() {
 rc=$?
 trap - EXIT INT TERM
 if [ -n "$PID" ]; then stop_child || true;wait "$PID" 2>/dev/null || true;fi
 exit "$rc"
}
trap cleanup EXIT
trap 'echo INTERRUPTED >"$OUT/status.txt";exit 130' INT
trap 'echo INTERRUPTED >"$OUT/status.txt";exit 143' TERM
"$TB" --txt -c "$OUT/config.pbtxt" -o "$OUT/trace.pftrace" --notify-fd 3 \
  3>"$OUT/notify.byte" >"$OUT/collector.log" 2>&1 &
PID=$!
START=$(proc_identity 2>/dev/null || true)
printf '%s\n' "$PID" >"$OUT/collector.pid"
n=0
while [ ! -s "$OUT/notify.byte" ]; do
 if ! alive || [ "$n" -ge "$READY_LIMIT" ]; then
  echo NOT_READY >"$OUT/status.txt";echo 'ERROR: no successful notify byte; see collector.log' >&2;exit 3
 fi
 sleep 1;n=$((n+1))
done
val=$(od -An -tu1 -N1 "$OUT/notify.byte" | tr -d ' \n')
if [ "$val" != 0 ]; then echo NOT_READY >"$OUT/status.txt";exit 3;fi
: >"$OUT/READY"
echo "READY pid=$PID output=$OUT"
timed=0;killed=0
while alive; do
 if [ "$n" -ge "$TIMEOUT" ]; then timed=1;stop_child || killed=1;break;fi
 sleep 1;n=$((n+1))
done
wait "$PID";rc=$?;PID=''
printf 'collector_rc=%s timeout=%s forced_kill=%s\n' "$rc" "$timed" "$killed" >"$OUT/exit.txt"
if [ "$timed" = 1 ]; then echo TIMEOUT_DATA_UNTRUSTED >"$OUT/status.txt";exit 10;fi
if [ "$rc" != 0 ]; then echo CAPTURE_FAILED >"$OUT/status.txt";exit 7;fi
if [ ! -s "$OUT/trace.pftrace" ]; then echo EMPTY >"$OUT/status.txt";exit 4;fi
size=$(wc -c <"$OUT/trace.pftrace")
echo "RECORDED_DATA_UNCHECKED size_bytes=$size" >"$OUT/status.txt"
cat "$OUT/status.txt"
# Normal exit/wait confirms this CLI child ended, NOT that events/stacks exist.
# TP data-quality/coverage checks remain mandatory. SIGKILL output is never PASS.
exit 0
