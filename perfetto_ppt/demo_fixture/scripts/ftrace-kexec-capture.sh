#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# ftrace-kexec-capture.sh — one-shot, supervised kernel-scheduling capture.
#
# Boots the tracing kernel via kexec (no flash writes), lets the initramfs run
# pf-demo-x5 + tracebox for N seconds, writes the trace to
# /userdata/pf-kernel-test/logs/, and reboots back to the stock kernel.
#
# This mode writes NOTHING to the board's partitions, but it takes the board
# offline for ~2 minutes and requires physical access for recovery in the worst
# case. Treat it as supervised: run one capture, verify the board is back on the
# stock kernel, then decide whether to run another. See kernel_ftrace/README.md.
set -u

D=/userdata/pf-kernel-test
SECS=${1:-52}

case "$SECS" in
    ''|*[!0-9]*) echo "usage: $0 [seconds 5..240]" >&2; exit 2 ;;
esac
[ "$SECS" -ge 5 ] && [ "$SECS" -le 240 ] || { echo "seconds must be in [5,240]" >&2; exit 2; }

for f in Image-ftrace initramfs-pf.cpio.gz kexec_pf; do
    [ -f "$D/$f" ] || { echo "ERROR: missing $D/$f (see kernel_ftrace/README.md)" >&2; exit 1; }
done

if [ ! -f "$D/ENABLE-KEXEC" ]; then
    echo "Refusing to reboot into the tracing kernel without $D/ENABLE-KEXEC." >&2
    echo "This is a deliberate speed bump: the board goes offline for ~2 min and" >&2
    echo "may need a physical power cycle. Create the marker after reading" >&2
    echo "kernel_ftrace/README.md, then re-run." >&2
    exit 1
fi

echo "kexec tracing kernel for a ${SECS}s capture."
echo "SSH will drop; results appear in $D/logs after ~$((SECS + 75))s."
echo "Verify the board is back on the stock kernel (uname -r) before another run."

cd "$D" || exit 1
./kexec_pf Image-ftrace initramfs-pf.cpio.gz \
    "console=ttyS0,921600n8 pf.mode=trace pf.duration=$((SECS * 1000))"
rc=$?
echo "kexec_pf returned rc=$rc (non-zero means the reboot did not happen)" >&2
exit "$rc"
