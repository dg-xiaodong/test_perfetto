#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# autostart-enable.sh — install the boot hook into the board's existing
# /userdata/startup.sh (executed by /etc/init.d/S99auto_startup in the
# background). Only a clearly marked block is appended; other entries are kept
# byte-for-byte. Idempotent.
set -u

D=$(cd "$(dirname "$0")/.." && pwd)
STARTUP=/userdata/startup.sh
BEGIN_MARK="# --- pf-demo-x5 fixture begin (perfetto_ppt/demo_fixture) ---"
END_MARK="# --- pf-demo-x5 fixture end ---"

rm -f "$D/autostart.disabled"

if [ -f "$STARTUP" ] && grep -q "pf-demo-x5 fixture begin" "$STARTUP"; then
    echo "autostart block already present in $STARTUP"
    exit 0
fi

if [ ! -f "$STARTUP" ]; then
    printf '#!/bin/sh\n' > "$STARTUP"
    chmod 755 "$STARTUP"
    echo "created $STARTUP"
fi

{
    echo ""
    echo "$BEGIN_MARK"
    echo "if [ -x \"$D/autostart.sh\" ]; then"
    echo "    mkdir -p \"$D/logs\" 2>/dev/null"
    echo "    \"$D/autostart.sh\" >>\"$D/logs/autostart.log\" 2>&1"
    echo "fi"
    echo "$END_MARK"
} >> "$STARTUP"

echo "appended pf-demo-x5 autostart block to $STARTUP"
tail -n 8 "$STARTUP"
