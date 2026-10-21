#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# uninstall.sh — remove the pf-demo-x5 fixture from the board.
#
#   uninstall.sh            stop + remove the boot hook, keep logs/ for inspection
#   uninstall.sh --purge    also delete the whole deployment directory
#   uninstall.sh --purge --perfetto-service
#                           additionally stop a traced service this fixture did
#                           not necessarily start (only if you are sure no other
#                           test needs it)
#
# The existing /userdata/startup.sh is edited by removing exactly the marked
# block; every other line is preserved.
set -u

D=$(cd "$(dirname "$0")/.." && pwd)
STARTUP=/userdata/startup.sh
PURGE=0
STOP_SERVICE=0

for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        --perfetto-service) STOP_SERVICE=1 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

echo "stopping service"
"$D/scripts/stop.sh" >/dev/null 2>&1 || true

if [ -f "$STARTUP" ] && grep -q "pf-demo-x5 fixture begin" "$STARTUP"; then
    tmp="$STARTUP.uninstall.$$"
    awk '
        /pf-demo-x5 fixture begin/ {skip = 1; next}
        /pf-demo-x5 fixture end/   {skip = 0; next}
        skip != 1
    ' "$STARTUP" > "$tmp" && cat "$tmp" > "$STARTUP"
    rm -f "$tmp"
    echo "removed pf-demo-x5 block from $STARTUP"
else
    echo "no pf-demo-x5 block found in $STARTUP"
fi

if [ "$STOP_SERVICE" -eq 1 ]; then
    "$D/scripts/perfetto-service.sh" stop 2>/dev/null || true
fi

if [ "$PURGE" -eq 1 ]; then
    cd /
    rm -rf "$D"
    echo "removed $D (--purge)"
else
    echo "kept $D (logs preserved). Re-run with --purge to delete it completely."
fi
