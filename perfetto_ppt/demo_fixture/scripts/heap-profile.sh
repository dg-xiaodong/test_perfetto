#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# heap-profile.sh — collect a native-heap profile of pf-demo-x5 on Linux.
#
#   heap-profile.sh [seconds]
#
# heapprofd on Linux uses an LD_PRELOAD client that must be present in the
# process from its very first malloc: an already-running process CANNOT be
# injected. The script therefore:
#   1. stops the resident service instance (if any),
#   2. starts a tracebox session with the android.heapprofd data source,
#   3. launches a dedicated pf-demo-x5 with LD_PRELOAD=libheapprofd_glibc_preload.so,
#   4. stops the session and restarts the resident service.
#
# Blocking init is OPT-IN only:
#   PF_HEAPPROF_BLOCKING_INIT=1 ./heap-profile.sh 20
# sets PERFETTO_HEAPPROFD_BLOCKING_INIT=1, which makes the first malloc wait for
# heapprofd. Never enable it for an always-on service: a not-yet-ready tracing
# service would stall the program at startup.
set -u

D=$(cd "$(dirname "$0")/.." && pwd)
SECS=${1:-20}
LIB="$D/lib/libheapprofd_glibc_preload.so"
CFG_SRC="$D/configs/heap_profile.cfg"

case "$SECS" in
    ''|*[!0-9]*) echo "usage: $0 [seconds]" >&2; exit 2 ;;
esac
[ "$SECS" -ge 5 ] && [ "$SECS" -le 300 ] || { echo "seconds must be in [5,300]" >&2; exit 2; }
[ -f "$LIB" ] || { echo "ERROR: missing $LIB" >&2; exit 1; }
[ -f "$CFG_SRC" ] || { echo "ERROR: missing $CFG_SRC" >&2; exit 1; }

TRACEBOX=""
for candidate in "$D/bin/perfetto/tracebox" /userdata/bin/tracebox; do
    if [ -x "$candidate" ]; then TRACEBOX="$candidate"; break; fi
done
[ -n "$TRACEBOX" ] || { echo "ERROR: tracebox not found" >&2; exit 1; }

mkdir -p "$D/logs" "$D/run"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$D/logs/heap-profile-$STAMP.pftrace"
SESS_LOG="$D/logs/heap-session-$STAMP.log"
APP_LOG="$D/logs/heap-app-$STAMP.log"
TMP_CFG="$D/run/heap-$$.cfg"
SESSION_PID="$D/run/heap-session.pid"

SVC_WAS_RUNNING=0
if [ -f "$D/run/app.pid" ] && kill -0 "$(cat "$D/run/app.pid" 2>/dev/null)" 2>/dev/null; then
    SVC_WAS_RUNNING=1
    echo "stopping resident service for the profile run"
    "$D/scripts/stop.sh" >/dev/null 2>&1
fi

cleanup() {
    if [ -f "$SESSION_PID" ]; then
        pid=$(cat "$SESSION_PID" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null
        fi
        rm -f "$SESSION_PID"
    fi
    rm -f "$TMP_CFG"
    if [ "$SVC_WAS_RUNNING" -eq 1 ] && [ "${KEEP_STOPPED:-0}" != "1" ]; then
        "$D/scripts/start.sh" >/dev/null 2>&1
    fi
}
trap cleanup EXIT INT TERM

"$D/scripts/perfetto-service.sh" ensure >/dev/null 2>&1 || true

sed "s/^duration_ms:.*/duration_ms: $(( (SECS + 8) * 1000 ))/" "$CFG_SRC" > "$TMP_CFG"

echo "starting heapprofd session"
: > "$SESS_LOG"
"$TRACEBOX" --system-sockets --txt -c "$TMP_CFG" -o "$OUT" \
    --background-wait >> "$SESSION_PID" 2>> "$SESS_LOG"
rc=$?
SPID=$(cat "$SESSION_PID" 2>/dev/null)
if [ "$rc" -ne 0 ] || [ -z "${SPID:-}" ]; then
    echo "ERROR: heapprofd session failed to start (rc=$rc)" >&2
    tail -n 20 "$SESS_LOG" >&2
    exit 1
fi
echo "session pid=$SPID"

BLOCKING="${PF_HEAPPROF_BLOCKING_INIT:-0}"
echo "launching pf-demo-x5 for ${SECS}s with LD_PRELOAD (blocking_init=$BLOCKING)"
LD_PRELOAD="$LIB" \
PERFETTO_HEAPPROFD_BLOCKING_INIT="$BLOCKING" \
    "$D/bin/pf-demo-x5" --data-dir "$D" --log-dir "$D/logs" \
    --run-seconds "$SECS" --phase-seconds 8 --no-frame-log \
    >> "$APP_LOG" 2>&1
app_rc=$?
echo "target exited rc=$app_rc"

kill -TERM "$SPID" 2>/dev/null
i=0
while [ "$i" -lt 60 ] && kill -0 "$SPID" 2>/dev/null; do
    sleep 0.5
    i=$((i + 1))
done
rm -f "$SESSION_PID"

if [ ! -s "$OUT" ]; then
    echo "ERROR: no trace written" >&2
    exit 1
fi
ls -l "$OUT"
echo "heap profile trace: $OUT"
echo "verify with trace_processor:"
echo "  SELECT count(*) FROM heap_profile_allocation;"
echo "  SELECT count(*) FROM stack_profile_callsite;"
