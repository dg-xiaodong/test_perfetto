#!/bin/sh
# Read-only Linux/Android survey. Never mounts, changes sysctls or starts tracing.
set -eu
mode=${1:-report}
case "$mode" in report|--events) ;; *) echo 'usage: sh survey.sh [--events]' >&2; exit 2;; esac
tracefs=''
for p in "${PERFETTO_TRACEFS:-/nonexistent}" /sys/kernel/debug/tracing /sys/kernel/tracing; do
    # tracefs pseudo-files may have st_size=0 despite containing records.
    if [ -d "$p/events" ] && [ -r "$p/available_events" ]; then
        first=$(head -n 1 "$p/available_events" 2>/dev/null || true)
        if [ -n "$first" ]; then tracefs=$p; break; fi
    fi
done
if [ "$mode" = '--events' ]; then
    if [ -z "$tracefs" ]; then echo 'No readable, populated tracefs found' >&2; exit 3; fi
    cat "$tracefs/available_events"
    exit 0
fi
printf '== Platform ==\n'
uname -a
getconf PAGESIZE 2>/dev/null || true
getconf GNU_LIBC_VERSION 2>/dev/null || true
if command -v getprop >/dev/null 2>&1; then getprop ro.build.version.sdk; getprop ro.build.type; fi
printf '\n== Mounts and capture locations ==\n'
awk '$2=="/" || $2=="/data" || $2=="/tmp" || $2=="/dev/shm" {print}' /proc/mounts
for p in /data /tmp /dev/shm; do if [ -d "$p" ]; then df -k "$p" 2>/dev/null || true; fi; done
printf '\n== Tracefs ==\n%s\n' "${tracefs:-not accessible}"
if [ -n "$tracefs" ]; then
    for n in current_tracer tracing_on buffer_size_kb trace_clock; do
        if [ -r "$tracefs/$n" ]; then printf '%s=' "$n"; cat "$tracefs/$n"; fi
    done
    grep -E '^(kmem:rss_stat|cma:|vmscan:.*direct_reclaim|compaction:|oom:|raw_syscalls:|lowmemorykiller:)' "$tracefs/available_events" || true
fi
printf '\n== Memory ==\n'
grep -E '^(MemTotal|MemAvailable|MemFree|AnonPages|Shmem|Slab|SwapTotal|SwapFree|CmaTotal|CmaFree):' /proc/meminfo || true
printf '\n== Perf policy (reading only) ==\n'
for n in perf_event_paranoid kptr_restrict; do
    p=/proc/sys/kernel/$n
    if [ -r "$p" ]; then printf '%s=' "$n"; cat "$p"; fi
done
printf '\n== Tool presence, NOT data-source registration ==\n'
for t in perfetto tracebox heapprofd traced traced_probes; do command -v "$t" || true; done
for p in /data/tracebox /data/libheapprofd_glibc_preload.so; do if [ -e "$p" ]; then ls -l "$p"; fi; done
printf '\nSurvey finished. No runtime settings were changed.\n'
