#!/bin/sh
# C2: heapprofd native allocation. Runs on the X5 board.
# Usage: remote_c2.sh APP_DIR APP_CMD [APP_ARGS]
#   APP_DIR   directory containing the test binary
#   APP_CMD   binary path or wrapper script (dynamic executable)
#   APP_ARGS  optional single string, split on whitespace
#
# Lifecycle:
#   1. start trace (90 s safety cap)
#   2. wait for tracing service to answer
#   3. start the test process under LD_PRELOAD
#   4. wait until the heapprofd producer/data source is visible
#   5. observe for OBSERVE_S seconds
#   6. stop the test process and let heapprofd flush
#   7. SIGINT tracebox, wait for exit, require non-empty output
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/remote_lib.sh"

APP_DIR=${1:?usage: remote_c2.sh APP_DIR APP_CMD [APP_ARGS]}
APP_CMD=${2:?usage: remote_c2.sh APP_DIR APP_CMD [APP_ARGS]}
APP_ARGS=${3:-}
OBSERVE_S=${OBSERVE_S:-30}

cd "$WORK"
TPID=""
APID=""
STOPPED=0
cleanup() {
  if [ -n "$APID" ] && kill -0 "$APID" 2>/dev/null; then
    kill -TERM "$APID" 2>/dev/null || true
    sleep 1
    kill -KILL "$APID" 2>/dev/null || true
  fi
  if [ -n "$TPID" ] && [ "$STOPPED" -eq 0 ]; then
    stop_tracebox "$TPID" || true
  fi
}
trap cleanup EXIT INT TERM
rm -f C2.pftrace C2.pid C2.start.log C2.query.txt C2.status app.pid app.log

# --system-sockets is required for the preload child to find the traced
# producer. If the caller provides explicit PERFETTO_*_SOCK_NAME paths, use
# those instead (e.g. when /tmp is not writable).
SOCK_ARG="--system-sockets"
if [ -n "${PERFETTO_PRODUCER_SOCK_NAME:-}" ] || [ -n "${PERFETTO_CONSUMER_SOCK_NAME:-}" ]; then
  SOCK_ARG=""
fi

echo "C2 start $(date)" > C2.start.log
"$TRACEBOX" $SOCK_ARG --txt -c C2-worker-native-alloc.pbtxt -o C2.pftrace \
  --background > C2.pid 2>> C2.start.log
TPID=$(cat C2.pid)
echo "C2 started tracebox_pid=$TPID"

# 2. Wait until the tracing service answers. This proves the service is up,
# not that heapprofd is already registered (the preload child registers it).
_i=0
while [ "$_i" -lt 50 ]; do
  if "$TRACEBOX" perfetto --query >/dev/null 2>&1; then
    break
  fi
  _i=$((_i + 1))
  sleep 0.2
done
if ! "$TRACEBOX" perfetto --query >/dev/null 2>&1; then
  echo "C2 FAIL: tracing service not queryable" >&2
  stop_tracebox "$TPID" || true
  exit 2
fi
"$TRACEBOX" perfetto --query --long > C2.query.txt 2>&1 || true

# 3. Start the test process. LD_PRELOAD must be present at process start.
if [ ! -f "$WORK/libheapprofd_glibc_preload.so" ]; then
  echo "C2 FAIL: missing $WORK/libheapprofd_glibc_preload.so" >&2
  stop_tracebox "$TPID" || true
  exit 2
fi
cd "$APP_DIR"
echo "C2 app start $(date)" > "$WORK/app.log"
set -f
env LD_PRELOAD="$WORK/libheapprofd_glibc_preload.so" \
    PERFETTO_HEAPPROFD_BLOCKING_INIT=1 \
    "$APP_CMD" $APP_ARGS >> "$WORK/app.log" 2>&1 &
APID=$!
set +f
echo "$APID" > "$WORK/app.pid"
echo "C2 started app_pid=$APID"

sleep 2
if ! kill -0 "$APID" 2>/dev/null; then
  echo "C2 FAIL: test process exited during startup" >&2
  tail -50 "$WORK/app.log" >&2 || true
  stop_tracebox "$TPID" || true
  exit 5
fi

# 4. The preload child registers android.heapprofd after the process starts.
# Wait for it before observation; if it never appears, the session would have
# no target data, so fail instead of pretending capture succeeded.
# Visibility proves registration/connection, not that samples exist; the host
# must still verify heap_profile_allocation after pull.
_i=0
while [ "$_i" -lt 50 ]; do
  "$TRACEBOX" perfetto --query --long > C2.query.txt 2>&1 || true
  if grep -Eqi 'heapprofd' C2.query.txt; then
    break
  fi
  _i=$((_i + 1))
  sleep 0.2
done
if ! grep -Eqi 'heapprofd' C2.query.txt; then
  echo "C2 FAIL: heapprofd producer/data source not visible after 10 s" >&2
  kill -TERM "$APID" 2>/dev/null || true
  stop_tracebox "$TPID" || true
  exit 6
fi
echo "C2 heapprofd producer visible"

# 5. Observe multiple jitter cycles.
sleep "$OBSERVE_S"
if ! kill -0 "$TPID" 2>/dev/null; then
  echo "C2 FAIL: tracebox exited before the observation window ended" >&2
  kill -TERM "$APID" 2>/dev/null || true
  exit 7
fi

# 6. Stop the test process, then allow heapprofd to flush.
kill -TERM "$APID" 2>/dev/null || true
_i=0
while kill -0 "$APID" 2>/dev/null; do
  _i=$((_i + 1))
  if [ "$_i" -ge 20 ]; then
    kill -KILL "$APID" 2>/dev/null || true
    break
  fi
  sleep 0.5
done
sleep 2
# App was launched from APP_DIR; return to WORK before touching trace files.
cd "$WORK"

# 7. Stop the trace session and require a non-empty file.
if ! stop_tracebox "$TPID"; then
  echo "C2 FAIL: tracebox did not exit after SIGINT/SIGTERM" >&2
  exit 8
fi
STOPPED=1
# The file may become visible slightly after the PID disappears. Do not
# declare failure on a single stat immediately after exit.
if ! wait_nonempty_file C2.pftrace 5; then
  echo "C2 FAIL: C2.pftrace missing or empty" >&2
  exit 9
fi

echo "C2 DONE size_bytes=$(wc -c < C2.pftrace)" > C2.status
cat C2.status
