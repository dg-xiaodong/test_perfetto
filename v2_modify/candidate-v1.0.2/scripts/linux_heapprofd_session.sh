#!/bin/sh
# Generic Linux heapprofd session with LD_PRELOAD. Runs on the target.
# Usage:
#   WORK=/writable/dir TRACEBOX=/path/tracebox OBSERVE_S=30 \
#     linux_heapprofd_session.sh CONFIG PRELOAD APP_DIR APP_CMD [APP_ARGS]
#
# The caller must put the target process name in the heapprofd config.
# This script does not assume any application name.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/linux_session_lib.sh"

CONFIG=${1:?usage: linux_heapprofd_session.sh CONFIG PRELOAD APP_DIR APP_CMD [APP_ARGS]}
PRELOAD=${2:?usage: linux_heapprofd_session.sh CONFIG PRELOAD APP_DIR APP_CMD [APP_ARGS]}
APP_DIR=${3:?usage: linux_heapprofd_session.sh CONFIG PRELOAD APP_DIR APP_CMD [APP_ARGS]}
APP_CMD=${4:?usage: linux_heapprofd_session.sh CONFIG PRELOAD APP_DIR APP_CMD [APP_ARGS]}
APP_ARGS=${5:-}
OBSERVE_S=${OBSERVE_S:-30}
OUT=${OUT:-$WORK/heap}

[ -r "$CONFIG" ] || { echo "ERROR: config not readable: $CONFIG" >&2; exit 2; }
[ -r "$PRELOAD" ] || { echo "ERROR: preload library not readable: $PRELOAD" >&2; exit 2; }
[ -d "$APP_DIR" ] || { echo "ERROR: app dir not found: $APP_DIR" >&2; exit 2; }

case "$OUT" in /*) ;; *) OUT="$WORK/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT.pftrace" "$OUT.pid" "$OUT.log" "$OUT.status" "$OUT.app.log" "$OUT.app.pid" "$OUT.query.txt"

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

SOCK_ARG="--system-sockets"
if [ -n "${PERFETTO_PRODUCER_SOCK_NAME:-}" ] || [ -n "${PERFETTO_CONSUMER_SOCK_NAME:-}" ]; then
  SOCK_ARG=""
fi

echo "capture start $(date)" > "$OUT.log"
"$TRACEBOX" $SOCK_ARG --txt -c "$CONFIG" -o "$OUT.pftrace" \
  --background > "$OUT.pid" 2>> "$OUT.log"
TPID=$(cat "$OUT.pid")
echo "tracebox_pid=$TPID"

_i=0
while [ "$_i" -lt 100 ]; do
  "$TRACEBOX" perfetto --query >/dev/null 2>&1 && break
  _i=$((_i + 1)); sleep 0.2
done
if ! "$TRACEBOX" perfetto --query >/dev/null 2>&1; then
  echo "FAIL: tracing service not queryable" >&2
  exit 3
fi
"$TRACEBOX" perfetto --query --long > "$OUT.query.txt" 2>&1 || true

cd "$APP_DIR"
echo "app start $(date)" > "$OUT.app.log"
set -f
env LD_PRELOAD="$PRELOAD" PERFETTO_HEAPPROFD_BLOCKING_INIT=1 \
  "$APP_CMD" $APP_ARGS >> "$OUT.app.log" 2>&1 &
APID=$!
set +f
echo "$APID" > "$OUT.app.pid"

sleep 2
if ! kill -0 "$APID" 2>/dev/null; then
  echo "FAIL: test process died during startup" >&2
  tail -30 "$OUT.app.log" >&2 || true
  exit 4
fi

_i=0
while [ "$_i" -lt 50 ]; do
  "$TRACEBOX" perfetto --query --long > "$OUT.query.txt" 2>&1 || true
  grep -qi 'heapprofd' "$OUT.query.txt" && break
  _i=$((_i + 1)); sleep 0.2
done
if ! grep -qi 'heapprofd' "$OUT.query.txt"; then
  echo "FAIL: heapprofd producer/data source not visible" >&2
  exit 5
fi

sleep "$OBSERVE_S"
if ! kill -0 "$APID" 2>/dev/null; then
  echo "FAIL: test process exited during observation; window incomplete" >&2
  exit 6
fi
if ! kill -0 "$TPID" 2>/dev/null; then
  echo "FAIL: tracebox exited before observation ended" >&2
  exit 6
fi

kill -TERM "$APID" 2>/dev/null || true
_i=0
while kill -0 "$APID" 2>/dev/null; do
  _i=$((_i + 1))
  [ "$_i" -ge 20 ] && { kill -KILL "$APID" 2>/dev/null || true; break; }
  sleep 0.5
done
APID=""
sleep 2

cd "$WORK"
if ! stop_tracebox "$TPID"; then
  echo "FAIL: tracebox did not exit" >&2
  exit 7
fi
STOPPED=1
if ! wait_nonempty_file "$OUT.pftrace" 5; then
  echo "FAIL: $OUT.pftrace missing or empty" >&2
  exit 8
fi
echo "DONE size_bytes=$(wc -c < "$OUT.pftrace")" > "$OUT.status"
cat "$OUT.status"
