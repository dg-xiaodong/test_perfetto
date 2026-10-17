#!/bin/sh
# Re-export the analysis tables from cpu.pftrace with Trace Processor v57.1.
# Requires: out/ exists, q-*.sql next to this script.
set -eu
TP=${TP:-/root/.cache/perfetto-skill/trace_processor_shell}
for q in q-slices q-states q-cpufreq q-cpuidle q-pf q-cs q-fr; do
  $TP query -f "$q.sql" cpu.pftrace 2>/dev/null \
    | grep -vE '^(column [0-9]+ = |\[.*\] +(query|common_flags))' > "out/$q.csv"
  echo "$q -> out/$q.csv ($(wc -l < out/$q.csv) lines)"
done
