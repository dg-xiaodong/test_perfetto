#!/bin/sh
# runq.sh FILE.sql TRACE -> out/$(basename FILE).txt
set -eu
TP=${TP:-/root/.cache/perfetto-skill/trace_processor_shell}
f=$1; tr=$2
b=$(basename "$f" .sql)
$TP query -f "$f" "$tr" > "out/$b.txt" 2>"out/$b.err" || { echo "QUERY FAIL: $f"; tail -5 "out/$b.err"; exit 1; }
echo "== $b =="; cat "out/$b.txt"
