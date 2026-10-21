#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# autostart-enable.sh — install the boot hook into the board's existing
# /userdata/startup.sh (executed by /etc/init.d/S99auto_startup in the
# background).
#
# The block is inserted *right after the shebang*, not appended at the end:
# the existing startup script (from other fixtures) ends with an unconditional
# "exit 0", so anything appended after it never runs. This was caught during
# the on-board test and is the reason for the insertion point. Other entries are
# kept byte-for-byte. Idempotent.
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

BLOCK_FILE=$(mktemp)
{
    echo "$BEGIN_MARK"
    echo "if [ -x \"$D/scripts/autostart.sh\" ]; then"
    echo "    mkdir -p \"$D/logs\" 2>/dev/null"
    echo "    \"$D/scripts/autostart.sh\" >>\"$D/logs/autostart.log\" 2>&1"
    echo "fi"
    echo "$END_MARK"
} > "$BLOCK_FILE"

# Insert after the shebang (line 1 if it is not a shebang). The rest of the
# existing file is preserved unchanged.
NEW_FILE=$(mktemp)
FIRST=$(head -n 1 "$STARTUP")
if echo "$FIRST" | grep -q '^#!'; then
    {
        echo "$FIRST"
        cat "$BLOCK_FILE"
        tail -n +2 "$STARTUP"
    } > "$NEW_FILE"
else
    {
        cat "$BLOCK_FILE"
        cat "$STARTUP"
    } > "$NEW_FILE"
fi
cat "$NEW_FILE" > "$STARTUP"
rm -f "$NEW_FILE" "$BLOCK_FILE"

echo "inserted pf-demo-x5 autostart block after the shebang in $STARTUP"
head -n 12 "$STARTUP"
