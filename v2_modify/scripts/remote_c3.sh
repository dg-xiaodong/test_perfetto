#!/bin/sh
# C3: linux.perf CPU profile. Runs on the X5 board.
# Completion: tracebox exits, output file non-empty, else exit non-zero.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/remote_lib.sh"

cd "$WORK"
TPID=""
cleanup() { [ -n "$TPID" ] && stop_tracebox "$TPID" || true; }
trap cleanup EXIT INT TERM
rm -f C3.pftrace C3.pid C3.log C3.status

# C3 duration_ms is 30000; allow 45 s wall clock, then SIGINT + 15 s flush.
echo "C3 start $(date)" > C3.log
"$TRACEBOX" --txt -c C3-worker-cpu-profile.pbtxt -o C3.pftrace \
  --background > C3.pid 2>> C3.log
TPID=$(cat C3.pid)
echo "C3 started tracebox_pid=$TPID"

if ! wait_pid_exit "$TPID" 45; then
  echo "C3 TIMEOUT: sending SIGINT for flush" >&2
  if ! stop_tracebox "$TPID"; then
    echo "C3 FAIL: tracebox did not exit after SIGINT/SIGTERM" >&2
    exit 3
  fi
fi
TPID=""   # tracebox has exited; avoid signaling a reused PID in cleanup

# The output file may become visible slightly after the PID disappears.
if ! wait_nonempty_file C3.pftrace 5; then
  echo "C3 FAIL: C3.pftrace missing or empty" >&2
  exit 4
fi

echo "C3 DONE size_bytes=$(wc -c < C3.pftrace)" > C3.status
cat C3.status
