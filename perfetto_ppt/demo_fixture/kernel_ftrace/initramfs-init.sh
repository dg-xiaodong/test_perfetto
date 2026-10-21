#!/bin/sh
# pf-demo-x5 kernel-ftrace test initramfs (kexec, disk untouched).
# modes: pf.mode=dry  -> write a marker to /userdata and reboot back
#        pf.mode=trace-> run pf-demo-x5 + tracebox on the kexec'd kernel,
#                        write trace/logs to /userdata, then reboot back
/bin/mount -t devtmpfs devtmpfs /dev 2>/dev/null
/bin/mount -t proc proc /proc 2>/dev/null
/bin/mount -t sysfs sysfs /sys 2>/dev/null
mkdir -p /tmp /mnt
/bin/mount -t tmpfs tmpfs /tmp 2>/dev/null

MODE=$(sed 's/ /\n/g' /proc/cmdline | sed -n 's/^pf\.mode=//p')
DUR_MS=$(sed 's/ /\n/g' /proc/cmdline | sed -n 's/^pf\.duration=//p')
case "$DUR_MS" in ''|*[!0-9]*) DUR_MS=52000 ;; esac
[ "$DUR_MS" -lt 5000 ] && DUR_MS=5000
[ "$DUR_MS" -gt 240000 ] && DUR_MS=240000
APP_SECS=$((DUR_MS / 1000 + 15))

# MMC partitions appear asynchronously; the stock initramfs waits for its
# system partition for the same reason. Retry both the device node and mount,
# otherwise the marker/trace would silently land in the initramfs tmpfs.
i=0
while [ "$i" -lt 100 ]; do
    [ -b /dev/mmcblk0p13 ] && break
    sleep 0.1
    i=$((i + 1))
done
RES=""
i=0
while [ "$i" -lt 10 ]; do
    if /bin/mount -t ext4 -o rw /dev/mmcblk0p13 /mnt 2>/dev/null; then
        RES=/mnt/pf-kernel-test
        break
    fi
    sleep 1
    i=$((i + 1))
done
[ -n "$RES" ] || RES=/tmp/pf-kernel-test
mkdir -p "$RES/logs"
echo "PF_INIT mode=$MODE res=$RES uname=$(uname -r)" > "$RES/logs/init-marker.txt" 2>/dev/null

# Keep the hardware watchdog from resetting us while the test runs. The stock
# kernel's kexec loader armed it; handle_boot_enabled keeps pinging until we
# open it, then we pet until the very end.
PET=""
if [ -e /dev/watchdog ]; then
    (
        exec 3>/dev/watchdog
        echo 120 >&3 2>/dev/null
        while :; do echo 1 >&3 2>/dev/null; sleep 10; done
    ) &
    PET=$!
fi

finish() {
    sync
    if [ -n "$PET" ]; then
        kill "$PET" 2>/dev/null
        sleep 1
        echo V > /dev/watchdog 2>/dev/null
    fi
    sleep 1
    exec /sbin/reboot -f
}

if [ "$MODE" = "dry" ]; then
    {
        echo "PF_DRY_OK"
        echo "uname: $(uname -a)"
        echo "cmdline: $(cat /proc/cmdline)"
        echo "date: $(date -u)"
        echo "userdata mount: $RES"
    } > "$RES/logs/dry-run.txt" 2>&1
    finish
fi

export LD_LIBRARY_PATH=/usr/lib:/lib
export PATH=/pf:/bin:/sbin:/usr/bin:/usr/sbin
STAMP=$(date +%Y%m%d-%H%M%S)

# Perfetto's FtraceController only *detects* an existing tracefs mount; it
# never mounts it. Mount tracefs (and debugfs) before starting traced_probes.
mkdir -p /sys/kernel/tracing /sys/kernel/debug
DIAG="$RES/logs/platform-$STAMP.txt"
mkdir -p /sys/kernel/tracing
{
    echo "--- mount tracefs"
    /bin/mount -t tracefs tracefs /sys/kernel/tracing 2>&1
    echo "rc=$?"
    echo "--- mount debugfs"
    /bin/mount -t debugfs debugfs /sys/kernel/debug 2>&1
    echo "rc=$?"
    echo "--- tracefs root"; ls /sys/kernel/tracing | head -20
    echo "--- available_tracers"; cat /sys/kernel/tracing/available_tracers 2>&1
    echo "--- sched events"; ls /sys/kernel/tracing/events/sched 2>&1 | head -20
    echo "--- block events"; ls /sys/kernel/tracing/events/block 2>&1 | head -8
    echo "--- power events"; ls /sys/kernel/tracing/events/power 2>&1 | grep -E "cpu_frequency|cpu_idle" | head -4
    echo "--- raw_syscalls events"; ls /sys/kernel/tracing/events/raw_syscalls 2>&1 | head -4
    echo "--- uname"; uname -a
    echo "--- cmdline"; cat /proc/cmdline
} > "$DIAG" 2>&1
/pf/pf-demo-x5 --data-dir "$RES" --phase-seconds 8 --run-seconds "$APP_SECS" --no-frame-log \
    > "$RES/logs/app-$STAMP.log" 2>&1 &
APP=$!
sleep 3

# Try the rich config first (sched + block + power + syscalls). If any event is
# missing the ftrace data source fails; fall back to the proven sched-only set.
CFG=/tmp/trace.cfg
TRC=1
for attempt in full min; do
    sed "s/^duration_ms:.*/duration_ms: $DUR_MS/" "/pf/trace_$attempt.cfg" > "$CFG"
    /pf/tracebox --system-sockets --txt -c "$CFG" \
        -o "$RES/logs/ftrace-$attempt-$STAMP.pftrace" \
        > "$RES/logs/tracebox-$attempt-$STAMP.log" 2>&1
    rc=$?
    sz=$(wc -c < "$RES/logs/ftrace-$attempt-$STAMP.pftrace" 2>/dev/null || echo 0)
    echo "attempt=$attempt rc=$rc size=$sz" >> "$DIAG"
    if [ "$rc" -eq 0 ] && [ "$sz" -gt 1000000 ] && \
       ! grep -q "Failed to create FtraceController" "$RES/logs/tracebox-$attempt-$STAMP.log"; then
        TRC=0
        cp -f "$RES/logs/ftrace-$attempt-$STAMP.pftrace" "$RES/logs/ftrace-$STAMP.pftrace"
        echo "result=OK attempt=$attempt" >> "$DIAG"
        break
    fi
    echo "result=FALLBACK attempt=$attempt" >> "$DIAG"
done
kill -TERM "$APP" 2>/dev/null
wait "$APP" 2>/dev/null
{
    echo "PF_TRACE_DONE rc=$TRC stamp=$STAMP"
    echo "uname: $(uname -a)"
    echo "--- /proc/version"; cat /proc/version
    echo "--- files"; ls -l "$RES/logs/"
    echo "--- tracebox log"; tail -30 "$RES/logs/tracebox-full-$STAMP.log" 2>/dev/null
    echo "--- tracebox min log"; tail -10 "$RES/logs/tracebox-min-$STAMP.log" 2>/dev/null
    echo "--- platform diag"; head -30 "$RES/logs/platform-$STAMP.txt" 2>/dev/null
} > "$RES/logs/ftrace-$STAMP.txt" 2>&1
finish
