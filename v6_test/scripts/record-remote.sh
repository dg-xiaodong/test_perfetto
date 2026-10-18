#!/bin/sh
# Convenience wrapper: push the trace config + the Skill's record.sh to the
# board and run ONE bounded capture. It never starts or stops the camera stream.
#
# NOT EXECUTED in this round (methodology + patches only).
#
# Usage:
#   ./record-remote.sh config/isp-latency-kernel.pbtxt /userdata/trace/isp-run1 [TIMEOUT_S]
#
# Env:
#   BOARD       default root@192.168.1.10
#   BOARD_PASS  default root (test lab only; do not use in production)
#   TRACEBOX    default /userdata/cpu-lab/perfetto-session/tracebox
#   SKILL_DIR   default /root/.dsh/skills/perfetto-latency-debugging
set -eu

CFG=${1:-}
OUT=${2:-}
TIMEOUT=${3:-75}
BOARD=${BOARD:-root@192.168.1.10}
BOARD_PASS=${BOARD_PASS:-root}
TRACEBOX=${TRACEBOX:-/userdata/cpu-lab/perfetto-session/tracebox}
SKILL_DIR=${SKILL_DIR:-/root/.dsh/skills/perfetto-latency-debugging}

[ -r "$CFG" ] || { echo "usage: $0 CONFIG NEW_ABSOLUTE_OUTPUT_DIR [TIMEOUT_S]" >&2; exit 2; }
case "$OUT" in /*) ;; *) echo "output must be a new absolute directory on the board" >&2; exit 2;; esac
[ -r "$SKILL_DIR/scripts/record.sh" ] || { echo "record.sh not found under $SKILL_DIR" >&2; exit 2; }
command -v sshpass >/dev/null 2>&1 || { echo "sshpass required" >&2; exit 2; }

SSH="sshpass -p $BOARD_PASS ssh -o StrictHostKeyChecking=no"
SCP="sshpass -p $BOARD_PASS scp -o StrictHostKeyChecking=no"

# Fail before touching the board if its tracing session is already active.
$SSH "$BOARD" '
  for tf in /sys/kernel/debug/tracing /sys/kernel/tracing; do
    if [ -r "$tf/tracing_on" ] && [ -r "$tf/events/enable" ]; then
      on=$(cat "$tf/tracing_on"); ev=$(cat "$tf/events/enable")
      if [ "$on" = 1 ] && [ "$ev" != 0 ]; then
        echo "BLOCKED: tracing already enabled on the board; do not steal another session" >&2
        exit 3
      fi
    fi
  done' || exit $?

$SSH "$BOARD" "mkdir -p /userdata/isp-latency" || exit 2
$SCP "$CFG" "$BOARD:/userdata/isp-latency/config.pbtxt" || exit 2
$SCP "$SKILL_DIR/scripts/record.sh" "$BOARD:/userdata/isp-latency/record.sh" || exit 2

# record.sh: bounded duration, new output dir, direct child identity, explicit
# status codes. Out must not exist yet on the board.
exec $SSH "$BOARD" "TRACEBOX='$TRACEBOX' sh /userdata/isp-latency/record.sh \
    /userdata/isp-latency/config.pbtxt '$OUT' '$TIMEOUT'"
