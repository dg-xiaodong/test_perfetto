#!/bin/sh
# Common board-side helpers. Runs on the X5, not on the Ubuntu host.
# All variables used by the remote scripts are resolved here, on the board.
set -eu

WORK=${WORK:-/data/perfetto-worker}
mkdir -p "$WORK"

if [ -z "${TRACEBOX:-}" ]; then
  if command -v tracebox >/dev/null 2>&1; then
    TRACEBOX=$(command -v tracebox)
  else
    TRACEBOX=/data/tracebox
  fi
fi
if [ ! -x "$TRACEBOX" ]; then
  echo "ERROR: tracebox is not executable: $TRACEBOX" >&2
  exit 127
fi

# Wait for a PID to disappear. Returns 1 on timeout.
wait_pid_exit() {
  _pid=$1
  _timeout_s=$2
  _i=0
  while kill -0 "$_pid" 2>/dev/null; do
    _i=$((_i + 1))
    if [ "$_i" -ge "$_timeout_s" ]; then
      return 1
    fi
    sleep 1
  done
  return 0
}

# Wait until a regular file exists and is non-empty. Returns 1 on timeout.
wait_nonempty_file() {
  _f=$1
  _timeout_s=$2
  _i=0
  while [ ! -s "$_f" ]; do
    _i=$((_i + 1))
    if [ "$_i" -ge "$_timeout_s" ]; then
      return 1
    fi
    sleep 1
  done
  return 0
}

# Stop a tracebox background PID gracefully and wait for flush/exit.
stop_tracebox() {
  _pid=$1
  if ! kill -0 "$_pid" 2>/dev/null; then
    return 0
  fi
  kill -INT "$_pid" 2>/dev/null || true
  if wait_pid_exit "$_pid" 10; then
    return 0
  fi
  kill -TERM "$_pid" 2>/dev/null || true
  wait_pid_exit "$_pid" 10 || return 1
  return 0
}
