#!/bin/sh
# Manual early stop for C1/C2/C3 tracebox session. Runs on the X5.
# Usage: remote_stop.sh C1|C2|C3
# Sends SIGINT, waits for flush, then checks the trace file is non-empty.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/remote_lib.sh"

NAME=${1:?usage: remote_stop.sh C1|C2|C3}
PIDFILE="$WORK/$NAME.pid"
TRACEFILE="$WORK/$NAME.pftrace"
if [ ! -f "$PIDFILE" ]; then
  echo "STOP FAIL: missing $PIDFILE" >&2
  exit 1
fi
TPID=$(cat "$PIDFILE")
if ! stop_tracebox "$TPID"; then
  echo "STOP FAIL: tracebox did not exit" >&2
  exit 2
fi
if ! wait_nonempty_file "$TRACEFILE" 5; then
  echo "STOP FAIL: $TRACEFILE missing or empty" >&2
  exit 3
fi
echo "STOP OK: $NAME size_bytes=$(wc -c < "$TRACEFILE")"
