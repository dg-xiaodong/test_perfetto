#!/bin/sh
# Shared target-side helpers for Linux tracebox sessions.
# Generic: no application-specific target names or fixed board paths.
set -eu

WORK=${WORK:-/data/perfetto-session}
mkdir -p "$WORK"

if [ -z "${TRACEBOX:-}" ]; then
  if command -v tracebox >/dev/null 2>&1; then
    TRACEBOX=$(command -v tracebox)
  else
    echo "ERROR: tracebox not found; set TRACEBOX=/path/to/tracebox" >&2
    exit 127
  fi
fi
[ -x "$TRACEBOX" ] || { echo "ERROR: tracebox not executable: $TRACEBOX" >&2; exit 127; }

wait_pid_exit() {
  _pid=$1; _timeout=$2; _i=0
  while kill -0 "$_pid" 2>/dev/null; do
    _i=$((_i + 1))
    [ "$_i" -ge "$_timeout" ] && return 1
    sleep 1
  done
  return 0
}

wait_nonempty_file() {
  _f=$1; _timeout=$2; _i=0
  while [ ! -s "$_f" ]; do
    _i=$((_i + 1))
    [ "$_i" -ge "$_timeout" ] && return 1
    sleep 1
  done
  return 0
}

stop_tracebox() {
  _pid=$1
  kill -0 "$_pid" 2>/dev/null || return 0
  kill -INT "$_pid" 2>/dev/null || true
  wait_pid_exit "$_pid" 10 && return 0
  kill -TERM "$_pid" 2>/dev/null || true
  wait_pid_exit "$_pid" 10
}
