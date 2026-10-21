#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# autostart-disable.sh — stop the fixture from starting at boot without
# removing anything. Boot-time start is skipped; manual scripts/start.sh keeps
# working. Reverse with scripts/autostart-enable.sh.
set -u

D=$(cd "$(dirname "$0")/.." && pwd)
touch "$D/autostart.disabled"
echo "autostart disabled: $D/autostart.disabled"
echo "the currently running instance is NOT stopped; use scripts/stop.sh for that"
