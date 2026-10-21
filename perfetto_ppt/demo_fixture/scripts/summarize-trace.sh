#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# summarize-trace.sh — host-side sanity summary of a pf-demo-x5 trace.
#
#   TRACE_PROCESSOR=/path/to/trace_processor_shell \
#     ./scripts/summarize-trace.sh trace.pftrace [unstripped-binary]
#
# Requires the Perfetto `trace_processor_shell` (v58 recommended) and, for
# function-level CPU hot spots, the unstripped aarch64 binary (symbolisation is
# done with PERFETTO_BINARY_PATH + PERFETTO_SYMBOLIZER_MODE=index; the binary
# is *read*, never executed).
#
# Prints counts for slices, flows, counters, perf samples and (optionally) the
# top leaf functions per thread. This is the same evidence window A used in
# SELF_TEST_REPORT.md.
set -euo pipefail

TRACE="${1:-}"
BINARY="${2:-}"
TP="${TRACE_PROCESSOR:-}"
if [ -z "$TRACE" ] || [ ! -f "$TRACE" ]; then
  echo "usage: TRACE_PROCESSOR=/path/trace_processor_shell $0 <trace.pftrace> [binary]" >&2
  exit 2
fi
if [ -z "$TP" ] || [ ! -x "$TP" ]; then
  echo "ERROR: set TRACE_PROCESSOR to trace_processor_shell" >&2
  exit 2
fi

q() {
  "$TP" query "$1" "$2" 2>/dev/null | grep -v '^\[' || true
}

echo "== trace: $TRACE"
echo "-- slices by name (top 12)"
q "$TRACE" "select name, count(*) c, round(avg(dur)/1e6,2) avg_ms from slice group by name order by c desc limit 12"
echo "-- flow count"
q "$TRACE" "select count(*) flows from flow"
echo "-- required counters"
q "$TRACE" "select ct.name, count(*) samples, round(min(c.value),2) mn, round(max(c.value),2) mx from counter c join counter_track ct on c.track_id=ct.id where ct.name in ('QueueDepth','InflightFrames','CompletedFrames','EndToEndLatencyMs','LiveAllocatedBytes') group by ct.name order by ct.name"
echo "-- perf samples / thread"
q "$TRACE" "select t.name, count(*) c from perf_sample p join thread t on p.utid=t.utid group by t.name order by c desc limit 8"
echo "-- infer stage duration by phase"
q "$TRACE" "select a.string_value phase, count(*) n, round(avg(s.dur)/1e6,2) avg_ms, round(max(s.dur)/1e6,2) max_ms from slice s join args a on a.arg_set_id=s.arg_set_id where s.name='InferenceStub' and a.key='debug.phase' group by phase order by phase"
echo "-- cpu frequency range (sys_stats)"
q "$TRACE" "select count(*) samples, min(value) min_khz, max(value) max_khz from counter c join counter_track ct on c.track_id=ct.id where ct.name='cpufreq'"

if [ -n "$BINARY" ] && [ -f "$BINARY" ]; then
  SYMDIR="$(mktemp -d)"
  mkdir -p "$SYMDIR/userdata/perfetto-training-demo/bin"
  cp "$BINARY" "$SYMDIR/userdata/perfetto-training-demo/bin/pf-demo-x5"
  SYMPB="$(mktemp)"
  echo "-- symbolising with $BINARY"
  if PERFETTO_BINARY_PATH="$SYMDIR" PERFETTO_SYMBOLIZER_MODE=index \
      "$TP" util symbolize "$TRACE" > "$SYMPB" 2>/dev/null; then
    cat "$TRACE" "$SYMPB" > "$SYMDIR/symbolized.pftrace"
    q "$SYMDIR/symbolized.pftrace" "select s.name, count(*) c from perf_sample p join stack_profile_callsite c on p.callsite_id=c.id join stack_profile_frame f on c.frame_id=f.id left join stack_profile_symbol s on f.symbol_set_id=s.symbol_set_id group by s.name order by c desc limit 10"
  else
    echo "  (symbolisation failed)"
  fi
  rm -rf "$SYMDIR" "$SYMPB"
fi
