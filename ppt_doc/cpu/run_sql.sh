#!/bin/sh
set -eu
TP=/root/.cache/perfetto-skill/trace_processor_shell
TRACE=${TRACE:-captures/cpu_firstpass.pftrace}
"$TP" query "$TRACE" "$2" 2> "sqlout/$1.stderr" | tr '\r' '\n' | grep -vE '^$' > "sqlout/$1.csv" || true
echo "== $1 rows=$(( $(wc -l < sqlout/$1.csv) )) =="; head -40 "sqlout/$1.csv"
