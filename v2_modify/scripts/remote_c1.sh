#!/bin/sh
# C1: low-overhead timeline. Runs on the X5 board.
# Completion: tracebox exits, output file non-empty, else exit non-zero.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/remote_lib.sh"

cd "$WORK"
TPID=""
cleanup() { [ -n "$TPID" ] && stop_tracebox "$TPID" || true; }
trap cleanup EXIT INT TERM
rm -f C1.pftrace C1.pid C1.log C1.status

# C1 duration_ms is 30000; allow 45 s wall clock, then SIGINT + 15 s flush.
echo "C1 start $(date)" > C1.log
"$TRACEBOX" --txt -c C1-worker-timeline.pbtxt -o C1.pftrace \
  --background > C1.pid 2>> C1.log
TPID=$(cat C1.pid)
echo "C1 started tracebox_pid=$TPID"

if ! wait_pid_exit "$TPID" 45; then
  echo "C1 TIMEOUT: sending SIGINT for flush" >&2
  if ! stop_tracebox "$TPID"; then
    echo "C1 FAIL: tracebox did not exit after SIGINT/SIGTERM" >&2
    exit 3
  fi
fi
TPID=""   # tracebox has exited; avoid signaling a reused PID in cleanup

# The output file may become visible slightly after the PID disappears.
if ! wait_nonempty_file C1.pftrace 5; then
  echo "C1 FAIL: C1.pftrace missing or empty" >&2
  exit 4
fi

echo "C1 DONE size_bytes=$(wc -c < C1.pftrace)" > C1.status
cat C1.status
