#!/bin/sh
# Read-only target survey. --formats DIR saves event descriptions into NEW DIR.
# Never mounts tracefs, changes security settings, or starts tracing.
set -eu
MODE=${1:-report}; TF=''
for p in "${PERFETTO_TRACEFS:-/nonexistent}" /sys/kernel/debug/tracing /sys/kernel/tracing; do
 if [ -r "$p/available_events" ] && [ -d "$p/events" ]; then
  first=$(head -n 1 "$p/available_events" 2>/dev/null || true)
  if [ -n "$first" ]; then TF=$p;break;fi
 fi
done
case "$MODE" in
 --events) [ -n "$TF" ] || { echo 'UNKNOWN: no populated readable tracefs' >&2;exit 3; };cat "$TF/available_events";exit 0;;
 --formats)
  [ -n "$TF" ] || exit 3
  D=${2:?usage: survey.sh --formats NEW_DIR}
  mkdir "$D" || exit 2
  for ev in sched_switch sched_waking; do
   cat "$TF/events/sched/$ev/format" >"$D/$ev.format" || exit 3
  done
  echo "formats saved in $D";exit 0;;
 report) ;;
 *) echo 'usage: survey.sh [--events | --formats NEW_DIR]' >&2;exit 2;;
esac
uname -a
printf 'TRACEFS=%s\n' "${TF:-UNKNOWN}"
getconf PAGESIZE 2>/dev/null || true
getconf _NPROCESSORS_ONLN 2>/dev/null || true
getconf GNU_LIBC_VERSION 2>/dev/null || true
cat /sys/devices/system/cpu/online 2>/dev/null || true
for x in perf_event_paranoid kptr_restrict perf_event_mlock_kb; do
 [ ! -r "/proc/sys/kernel/$x" ] || { printf '%s=' "$x";cat "/proc/sys/kernel/$x"; }
done
if [ -n "$TF" ]; then
 for x in trace_clock tracing_on current_tracer buffer_size_kb events/enable; do
  [ ! -r "$TF/$x" ] || { printf '%s=' "$x";cat "$TF/$x"; }
 done
 grep -E '^(sched:|raw_syscalls:)' "$TF/available_events" || true
fi
grep -E '^(MemAvailable|MemFree|SwapFree):' /proc/meminfo || true
awk '$2=="/" || $2=="/data" || $2=="/userdata" || $2=="/tmp" {print}' /proc/mounts
for t in tracebox perfetto traced traced_probes perf; do command -v "$t" || true;done
printf '%s\n' 'No settings changed. Tool presence is NOT data-source registration or perf permission.'
