#!/bin/sh
# Generic Linux tracebox capture without LD_PRELOAD.
# Runs on the target. Usage:
#   WORK=/writable/dir TRACEBOX=/path/tracebox \
#     linux_trace_session.sh CONFIG OUTPUT_PREFIX [TIMEOUT_S]
#
# Produces OUTPUT_PREFIX.pftrace, .pid, .log, .status. Exits non-zero if the
# session times out, tracebox cannot stop, or the output is empty.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/linux_session_lib.sh"

CONFIG=${1:?usage: linux_trace_session.sh CONFIG OUTPUT_PREFIX [TIMEOUT_S]}
OUT=${2:?usage: linux_trace_session.sh CONFIG OUTPUT_PREFIX [TIMEOUT_S]}
TIMEOUT_S=${3:-60}
[ -r "$CONFIG" ] || { echo "ERROR: config not readable: $CONFIG" >&2; exit 2; }
case "$OUT" in /*) ;; *) OUT="$WORK/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT.pftrace" "$OUT.pid" "$OUT.log" "$OUT.status"
echo "capture start $(date)" > "$OUT.log"

TPID=""
cleanup() { [ -n "$TPID" ] && stop_tracebox "$TPID" || true; }
trap cleanup EXIT INT TERM

"$TRACEBOX" --txt -c "$CONFIG" -o "$OUT.pftrace" \
  --background > "$OUT.pid" 2>> "$OUT.log"
TPID=$(cat "$OUT.pid")
echo "tracebox_pid=$TPID"

TIMED_OUT=0
if ! wait_pid_exit "$TPID" "$TIMEOUT_S"; then
  TIMED_OUT=1
  echo "timeout; sending SIGINT for flush" >&2
  if ! stop_tracebox "$TPID"; then
    echo "TIMEOUT_STOP_FAILED" > "$OUT.status"
    echo "FAIL: tracebox did not exit after SIGINT/SIGTERM; partial file kept" >&2
    exit 3
  fi
fi
TPID=""
if ! wait_nonempty_file "$OUT.pftrace" 5; then
  echo "EMPTY" > "$OUT.status"
  echo "FAIL: $OUT.pftrace missing or empty" >&2
  exit 4
fi
SIZE=$(wc -c < "$OUT.pftrace")
if [ "$TIMED_OUT" -eq 1 ]; then
  # A timeout is not a normal completion. Keep the partial trace for forensics,
  # mark it incomplete, and return non-zero.
  echo "TIMEOUT_STOPPED size_bytes=$SIZE" > "$OUT.status"
  cat "$OUT.status"
  exit 10
fi
echo "DONE size_bytes=$SIZE" > "$OUT.status"
cat "$OUT.status"
