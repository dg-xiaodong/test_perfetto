#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# start.sh — start pf-demo-x5 (through the crash-limited supervisor).
# Safe to run twice: an already running supervisor is reported and left alone.
set -u

D=$(cd "$(dirname "$0")/.." && pwd)
SUPFILE="$D/run/supervisor.pid"
APPFILE="$D/run/app.pid"
STOPFILE="$D/run/stop.requested"

mkdir -p "$D/logs" "$D/run" "$D/bin"

if [ ! -x "$D/bin/pf-demo-x5" ]; then
    echo "ERROR: $D/bin/pf-demo-x5 not found (run install.sh from the host)" >&2
    exit 1
fi

if [ -f "$SUPFILE" ]; then
    sup=$(cat "$SUPFILE" 2>/dev/null)
    if [ -n "$sup" ] && kill -0 "$sup" 2>/dev/null; then
        echo "already running: supervisor pid=$sup app pid=$(cat "$APPFILE" 2>/dev/null)"
        exit 0
    fi
    rm -f "$SUPFILE"
fi

rm -f "$STOPFILE"
if command -v setsid >/dev/null 2>&1; then
    setsid sh "$D/scripts/run-supervisor.sh" >> "$D/logs/supervisor.log" 2>&1 &
else
    nohup sh "$D/scripts/run-supervisor.sh" >> "$D/logs/supervisor.log" 2>&1 &
fi
echo $! > "$SUPFILE"

# Give the program a moment to create threads and write its BOOT line.
i=0
while [ "$i" -lt 20 ]; do
    if [ -f "$APPFILE" ] && kill -0 "$(cat "$APPFILE" 2>/dev/null)" 2>/dev/null; then
        break
    fi
    sleep 0.2
    i=$((i + 1))
done

sup=$(cat "$SUPFILE" 2>/dev/null)
app=$(cat "$APPFILE" 2>/dev/null)
if [ -n "${sup:-}" ] && kill -0 "$sup" 2>/dev/null; then
    echo "started: supervisor pid=$sup app pid=${app:-starting}"
    sleep 1
    tail -n 3 "$D/logs/service.log" 2>/dev/null
    exit 0
fi
echo "ERROR: supervisor failed to start; see $D/logs/supervisor.log" >&2
tail -n 20 "$D/logs/supervisor.log" 2>/dev/null >&2
exit 1
