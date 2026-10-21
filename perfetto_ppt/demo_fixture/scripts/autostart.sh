#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# autostart.sh — boot hook for the pf-demo-x5 fixture.
#
# /etc/init.d/S99auto_startup (the board's existing hook) executes
# /userdata/startup.sh in the background; scripts/autostart-enable.sh appends a
# guarded call to this script there. It never overwrites other boot configs.
set -u

D=$(cd "$(dirname "$0")/.." && pwd)
LOG="$D/logs/autostart.log"
mkdir -p "$D/logs"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"
}

if [ -f "$D/autostart.disabled" ]; then
    log "AUTOSTART_SKIP marker $D/autostart.disabled present"
    exit 0
fi

log "AUTOSTART_BEGIN"

# Bring up the tracing service (idempotent: reuses an already running traced).
"$D/scripts/perfetto-service.sh" ensure >> "$LOG" 2>&1 || \
    log "PERFETTO_SERVICE_WARN ensure failed (program still starts)"

# Start the workload. start.sh is idempotent.
"$D/scripts/start.sh" >> "$LOG" 2>&1
log "AUTOSTART_END rc=$?"
