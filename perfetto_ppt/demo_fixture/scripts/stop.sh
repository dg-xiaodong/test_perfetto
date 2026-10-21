#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# stop.sh — gracefully stop pf-demo-x5 and its supervisor.
#
# SIGTERM is handled by the program (it joins all threads and flushes logs);
# the supervisor exits without restarting because run/stop.requested exists.
set -u

D=$(cd "$(dirname "$0")/.." && pwd)
SUPFILE="$D/run/supervisor.pid"
APPFILE="$D/run/app.pid"
STOPFILE="$D/run/stop.requested"

mkdir -p "$D/run"
touch "$STOPFILE"

wait_gone() {
    pid="$1"
    limit="$2"
    i=0
    while [ "$i" -lt "$limit" ]; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

if [ -f "$SUPFILE" ]; then
    sup=$(cat "$SUPFILE" 2>/dev/null)
    if [ -n "$sup" ] && kill -0 "$sup" 2>/dev/null; then
        kill -TERM "$sup" 2>/dev/null
        wait_gone "$sup" 20 || kill -KILL "$sup" 2>/dev/null
        echo "stopped supervisor pid=$sup"
    fi
fi

if [ -f "$APPFILE" ]; then
    app=$(cat "$APPFILE" 2>/dev/null)
    if [ -n "$app" ] && kill -0 "$app" 2>/dev/null; then
        kill -TERM "$app" 2>/dev/null
        wait_gone "$app" 20 || kill -KILL "$app" 2>/dev/null
        echo "stopped app pid=$app"
    fi
fi

# Belt and braces: any orphan of our binary started from this deployment.
for pid in $(ps -o pid,args 2>/dev/null | grep -F "$D/bin/pf-demo-x5" | grep -v grep | awk '{print $1}'); do
    kill -TERM "$pid" 2>/dev/null
done

rm -f "$APPFILE" "$SUPFILE"
echo "stopped (stop.requested kept; scripts/start.sh clears it)"
