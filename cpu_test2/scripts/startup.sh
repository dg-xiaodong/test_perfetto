#!/bin/sh
# Custom startup hook, executed by the existing /etc/init.d/S99auto_startup
# (rootfs is read-only; /userdata is a separate persistent ext4 partition).
# It starts the resident task-service instance unless autostart is disabled.
#
# Bounded wait so we never block the boot sequence even if the persistent
# partition is not writable yet. S99auto_startup runs this script in the
# background, so boot does not wait for the service.
CTL=/userdata/cpu-lab/task-servicectl
[ -x "$CTL" ] || exit 0
if [ -f /userdata/cpu-lab/autostart.disabled ]; then
    echo "task-service autostart disabled by /userdata/cpu-lab/autostart.disabled"
    exit 0
fi
i=0
while [ "$i" -lt 20 ] && [ ! -w /userdata/cpu-lab/run ]; do
    sleep 0.5
    i=$((i + 1))
done
"$CTL" start >>/userdata/cpu-lab/logs/autostart.log 2>&1
exit 0
