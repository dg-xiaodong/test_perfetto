#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# trace.sh — record a Perfetto trace of the running pf-demo-x5.
#
#   trace.sh [seconds] [output.pftrace] [--ftrace]
#
# Why tracebox and not `perfetto`:
#   * tracebox bundles traced_probes *including traced_perf* (CPU callstack
#     sampling). The traced_probes built into this deployment does not include
#     the perf producer, so `perfetto` alone cannot record CPU samples here.
#   * `--system-sockets` is mandatory: in its default (private-socket) mode
#     tracebox cannot see producers started with the Perfetto system backend,
#     i.e. the pf-demo-x5 TrackEvent stream.
#
# The trace is written to the board; pull it with scp and open it in
# https://ui.perfetto.dev . Load the unstripped binary from bin/ for symbols.
set -u

D=$(cd "$(dirname "$0")/.." && pwd)
SECS=15
OUT=""
CFG=""

for arg in "$@"; do
    case "$arg" in
        --ftrace) CFG="$D/configs/trace_ftrace.cfg" ;;
        --help|-h)
            sed -n '2,10p' "$0"
            exit 0
            ;;
        *[!0-9]*) OUT="$arg" ;;
        *) SECS="$arg" ;;
    esac
done

if [ "$SECS" -lt 2 ] || [ "$SECS" -gt 300 ]; then
    echo "seconds must be in [2,300]" >&2
    exit 2
fi

if [ -z "$CFG" ]; then
    CFG="$D/configs/trace_smoke.cfg"
fi
[ -f "$CFG" ] || { echo "missing config $CFG" >&2; exit 1; }

if [ -z "$OUT" ]; then
    OUT="$D/logs/pf-demo-$(date +%Y%m%d-%H%M%S).pftrace"
fi
mkdir -p "$(dirname "$OUT")" "$D/run"

TRACEBOX=""
for candidate in "$D/bin/perfetto/tracebox" /userdata/bin/tracebox; do
    if [ -x "$candidate" ]; then
        TRACEBOX="$candidate"
        break
    fi
done
[ -n "$TRACEBOX" ] || { echo "tracebox not found (deploy bin/perfetto/ or /userdata/bin)" >&2; exit 1; }

# Make sure the system tracing service is up: tracebox --system-sockets uses it
# as the consumer endpoint and the SDK producer connects to the same service.
"$D/scripts/perfetto-service.sh" ensure >/dev/null 2>&1 || \
    echo "WARN: could not ensure traced service; trace may contain no data" >&2

TMP_CFG="$D/run/trace-$$.cfg"
sed "s/^duration_ms:.*/duration_ms: $((SECS * 1000))/" "$CFG" > "$TMP_CFG"

APP_PID=""
[ -f "$D/run/app.pid" ] && APP_PID=$(cat "$D/run/app.pid" 2>/dev/null)
if [ -z "${APP_PID:-}" ] || ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: pf-demo-x5 does not look running; trace_event will be empty" >&2
fi

echo "recording ${SECS}s -> $OUT"
echo "config: $CFG  (tracebox: $TRACEBOX)"

"$TRACEBOX" --system-sockets --txt -c "$TMP_CFG" -o "$OUT"
rc=$?
rm -f "$TMP_CFG"

if [ "$rc" -ne 0 ] || [ ! -s "$OUT" ]; then
    echo "ERROR: trace capture failed (rc=$rc)" >&2
    exit 1
fi
ls -l "$OUT"
echo "pull it with:  scp <user>@<board>:${OUT} ."
echo "then open it at https://ui.perfetto.dev and load bin/pf-demo-x5 for symbols"
