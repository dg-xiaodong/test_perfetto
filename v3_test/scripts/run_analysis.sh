#!/bin/sh
# Run the analysis SQL for x5_memory_visual_test against the captured trace.
# Host analyzer: Perfetto Trace Processor v58.2; trace: traces/heap.pftrace.
# Every query result is written verbatim; a failing query is recorded and the
# rest still run (the exit code is non-zero if any query failed).
# Usage: sh scripts/run_analysis.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TP=${TP:-/root/code_1.0.20/tmp/perfetto582/linux-amd64/trace_processor_shell}
TRACE=${TRACE:-$HERE/traces/heap.pftrace}
OUT=${OUT:-$HERE/sql_out}
mkdir -p "$OUT"

"$TP" --version > "$OUT/trace_processor_version.txt" 2>&1
sha256sum "$TRACE" > "$OUT/trace_sha256.txt"

rc=0
: > "$OUT/_summary.txt"
for f in "$HERE"/sql/*.sql; do
  b=$(basename "$f" .sql)
  if "$TP" query "$TRACE" -f "$f" > "$OUT/$b.txt" 2>&1; then
    echo "$b rc=0" >> "$OUT/_summary.txt"
  else
    echo "$b rc=FAIL" >> "$OUT/_summary.txt"
    rc=1
  fi
done
cat "$OUT/_summary.txt"
exit "$rc"
