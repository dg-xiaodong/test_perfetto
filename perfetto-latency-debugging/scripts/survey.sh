#!/bin/sh
# Target, read only; no mounting, sysctl, signal, or tracefs writes.
set -eu
TF=''
for t in /sys/kernel/debug/tracing /sys/kernel/tracing; do
 if [ -r "$t/available_events" ] && [ -s "$t/available_events" ]; then TF=$t;break;fi
 # procfs/debugfs virtual files can report size zero; test actual content.
 if [ -r "$t/available_events" ] && [ -n "$(head -c 1 "$t/available_events")" ]; then TF=$t;break;fi
done
if [ "${1:-}" = --events ]; then
 [ -n "$TF" ] || { echo 'BLOCKED: no readable populated tracefs' >&2;exit 2; }
 sed 's|:|/|' "$TF/available_events";exit 0
fi
uname -a
printf 'TRACEFS=%s\n' "$TF"
getconf PAGESIZE 2>/dev/null || true
cat /sys/devices/system/cpu/online 2>/dev/null || true
if [ -n "$TF" ]; then
 for f in tracing_on current_tracer trace_clock events/enable; do printf '%s=' "$f";cat "$TF/$f" 2>/dev/null || true;done
fi
for f in /tmp/perfetto-producer /run/perfetto/traced-producer.sock;do [ ! -S "$f" ] || ls -l "$f";done
printf 'PERFETTO_PRODUCER_SOCK_NAME=%s\n' "${PERFETTO_PRODUCER_SOCK_NAME:-<unset>}"
command -v tracebox || true;command -v perfetto || true
mount;df -k /data /userdata /tmp 2>/dev/null || true
