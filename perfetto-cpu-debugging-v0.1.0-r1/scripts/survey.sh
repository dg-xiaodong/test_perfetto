#!/bin/sh
# Read-only Linux/Android CPU tracing survey. No mounts, sysctl writes or tracing started.
set -eu
mode=${1:-report}
case "$mode" in report|--events) ;; *) echo 'usage: sh survey.sh [--events]' >&2; exit 2;; esac
tracefs=''
for p in "${PERFETTO_TRACEFS:-/nonexistent}" /sys/kernel/debug/tracing /sys/kernel/tracing; do
  if [ -d "$p/events" ] && [ -r "$p/available_events" ]; then
    first=$(head -n 1 "$p/available_events" 2>/dev/null || true)
    if [ -n "$first" ]; then tracefs=$p; break; fi
  fi
done
if [ "$mode" = '--events' ]; then
  [ -n "$tracefs" ] || { echo 'No readable tracefs events' >&2; exit 3; }
  cat "$tracefs/available_events"; exit 0
fi
printf '== Platform ==\n'; uname -a
getconf GNU_LIBC_VERSION 2>/dev/null || true
printf '\n== Tracefs ==\n%s\n' "${tracefs:-NOT AVAILABLE}"
if [ -n "$tracefs" ]; then
  for f in current_tracer tracing_on trace_clock; do
    if [ -r "$tracefs/$f" ]; then printf '%s=' "$f"; cat "$tracefs/$f"; fi
  done
  grep -E '^(sched:(sched_switch|sched_waking|sched_wakeup_new|sched_wakeup)|power:(cpu_frequency|cpu_idle))$' "$tracefs/available_events" || true
fi
printf '\n== CPU policy / sysfs ==\n'
for c in /sys/devices/system/cpu/cpu[0-9]*; do
  [ -d "$c" ] || continue
  if [ -r "$c/cpufreq/scaling_cur_freq" ]; then
    printf '%s ' "${c##*/}="; cat "$c/cpufreq/scaling_cur_freq"
  fi
done
for f in /proc/sys/kernel/perf_event_paranoid /proc/sys/kernel/kptr_restrict; do
  if [ -r "$f" ]; then printf '%s=' "$f"; cat "$f"; fi
done
printf '\n== Mounts / free space ==\n'
awk '$2=="/" || $2=="/data" || $2=="/userdata" || $2=="/tmp" {print}' /proc/mounts
for p in /data /userdata /tmp; do [ ! -d "$p" ] || df -k "$p" 2>/dev/null || true; done
printf '\n== Executables ==\n'; for x in tracebox perfetto perf; do command -v "$x" || true; done
printf 'Survey finished (read-only).\n'
