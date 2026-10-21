#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# run-supervisor.sh — keeps pf-demo-x5 alive with a bounded restart rate.
#
# Started by scripts/start.sh (and by autostart.sh at boot). The supervisor:
#   * starts the program in the foreground of its own child slot,
#   * restarts it when it exits unexpectedly,
#   * applies exponential back-off (2s..60s) and gives up after 10 consecutive
#     fast failures (< 30 s uptime), so a crash loop cannot spin forever or
#     flood the persistent partition with logs,
#   * exits cleanly when scripts/stop.sh drops run/stop.requested.
set -u

D=$(cd "$(dirname "$0")/.." && pwd)
LOG="$D/logs/supervisor.log"
APP="$D/bin/pf-demo-x5"
PIDFILE="$D/run/app.pid"
STOPFILE="$D/run/stop.requested"
SUPFILE="$D/run/supervisor.pid"

mkdir -p "$D/logs" "$D/run"
rm -f "$STOPFILE"
echo "$$" > "$SUPFILE"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"
}

log "SUPERVISOR_START pid=$$ app=$APP"

fast_failures=0
while [ ! -f "$STOPFILE" ]; do
    start_epoch=$(date +%s)
    log "APP_START epoch=$start_epoch"

    # Heap-profiling preload is opt-in only: a broken/absent preload library
    # must never take the main program down with it.
    if [ "${PF_DEMO_PRELOAD:-0}" = "1" ] && \
       [ -f "$D/lib/libheapprofd_glibc_preload.so" ]; then
        LD_PRELOAD="$D/lib/libheapprofd_glibc_preload.so"
        export LD_PRELOAD
        log "APP_PRELOAD libheapprofd_glibc_preload.so"
    else
        unset LD_PRELOAD 2>/dev/null || true
    fi

    "$APP" --data-dir "$D" >> "$D/logs/service.log" 2>&1 &
    child=$!
    echo "$child" > "$PIDFILE"
    log "APP_PID pid=$child"

    wait "$child"
    rc=$?
    rm -f "$PIDFILE"
    log "APP_EXIT rc=$rc epoch=$(date +%s)"

    [ -f "$STOPFILE" ] && break

    ran=$(( $(date +%s) - start_epoch ))
    if [ "$ran" -lt 30 ]; then
        fast_failures=$((fast_failures + 1))
    else
        fast_failures=0
    fi
    if [ "$fast_failures" -ge 10 ]; then
        log "SUPERVISOR_GIVE_UP fast_failures=$fast_failures last_rc=$rc"
        break
    fi

    sleep_s=$((fast_failures * 5))
    [ "$sleep_s" -gt 60 ] && sleep_s=60
    [ "$sleep_s" -lt 2 ] && sleep_s=2
    log "RESTART_BACKOFF sleep_s=$sleep_s fast_failures=$fast_failures"
    i=0
    while [ "$i" -lt "$sleep_s" ] && [ ! -f "$STOPFILE" ]; do
        sleep 1
        i=$((i + 1))
    done
done

rm -f "$PIDFILE" "$SUPFILE"
log "SUPERVISOR_STOP"
