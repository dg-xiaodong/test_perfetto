#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# status.sh — one-shot status of the pf-demo-x5 deployment.
set -u

D=$(cd "$(dirname "$0")/.." && pwd)

echo "== deployment =="
echo "dir          : $D"
if [ -f "$D/build_info.txt" ]; then
    sed 's/^/  /' "$D/build_info.txt"
fi
echo "autostart    : $([ -f "$D/autostart.disabled" ] && echo disabled || echo enabled)"

sup=""
app=""
[ -f "$D/run/supervisor.pid" ] && sup=$(cat "$D/run/supervisor.pid" 2>/dev/null)
[ -f "$D/run/app.pid" ] && app=$(cat "$D/run/app.pid" 2>/dev/null)

echo "== process =="
if [ -n "${sup:-}" ] && kill -0 "$sup" 2>/dev/null; then
    echo "supervisor   : pid=$sup RUNNING"
else
    echo "supervisor   : not running"
fi
if [ -n "${app:-}" ] && kill -0 "$app" 2>/dev/null; then
    echo "app          : pid=$app RUNNING"
    ps -o pid,ppid,etime,time,pcpu,pmem,rss,stat,args -p "$app" 2>/dev/null
else
    echo "app          : not running"
fi

echo "== threads (comm) =="
if [ -n "${app:-}" ] && [ -d "/proc/$app/task" ]; then
    for taskdir in /proc/"$app"/task/*; do
        tid=$(basename "$taskdir")
        comm=$(cat "$taskdir/comm" 2>/dev/null)
        state=$(awk '{print $3}' "$taskdir/stat" 2>/dev/null)
        printf '  tid=%-6s comm=%-16s state=%s\n' "$tid" "$comm" "$state"
    done
else
    echo "  (process not running)"
fi

echo "== last log lines =="
tail -n 4 "$D/logs/service.log" 2>/dev/null | sed 's/^/  /'

echo "== frame accounting =="
if [ -f "$D/logs/frames.log" ]; then
    lines=$(wc -l < "$D/logs/frames.log")
    first=$(head -n 1 "$D/logs/frames.log" | sed -n 's/.* id=\([0-9]*\) .*/\1/p')
    last=$(tail -n 1 "$D/logs/frames.log" | sed -n 's/.* id=\([0-9]*\) .*/\1/p')
    echo "  frames.log lines=$lines first_id=${first:-?} last_id=${last:-?}"
fi

echo "== tracing service =="
if [ -S /tmp/perfetto-consumer ]; then
    echo "  sockets      : /tmp/perfetto-consumer + /tmp/perfetto-producer present"
else
    echo "  sockets      : MISSING (no traced service; SDK events are dropped)"
fi
procs=$(ps -o pid,comm 2>/dev/null | grep -E '(^| )(traced|traced_probes)$' | awk '{print $1":"$2}' | tr '\n' ' ')
echo "  traced procs : ${procs:-none}"

echo "== heap profiling prerequisites =="
if [ -f "$D/lib/libheapprofd_glibc_preload.so" ]; then
    echo "  preload lib  : present ($(sha256sum "$D/lib/libheapprofd_glibc_preload.so" 2>/dev/null | cut -c1-16)...)"
    echo "  service mode : $([ "${PF_DEMO_PRELOAD:-0}" = "1" ] && echo preload-enabled || echo "started without preload (use scripts/heap-profile.sh)")"
else
    echo "  preload lib  : absent (native heap profiling via preload unavailable)"
fi
