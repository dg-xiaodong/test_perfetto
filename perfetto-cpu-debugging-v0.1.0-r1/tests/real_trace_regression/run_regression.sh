#!/bin/sh
# Run the inventory / frequency-gate SQL against a real trace with the given TP.
# Usage: run_regression.sh TRACE TP_BINARY OUTDIR [ORIGIN_LABEL]
# ORIGIN_LABEL is recorded in the output (defaults to the TRACE argument, which may be
# an absolute host path); the trace itself is not bundled.
set -eu
TRACE=${1:?trace path}
TP=${2:?trace_processor_shell path}
OUT=${3:?output dir}
ORIGIN=${4:-$TRACE}
SQLDIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../sql" && pwd)
mkdir -p "$OUT"
"$TP" --version > "$OUT/tp_version.txt" 2>&1
{ echo "trace: $ORIGIN"; sha256sum "$TRACE" | sed "s|$TRACE|$ORIGIN|"; } > "$OUT/trace_identity.txt"
for f in 00-inventory 00a-trace-bounds 00b-thread-states 00c-counter-tracks 00d-stats 04a-frequency-inventory 04-cpu-frequency; do
  out="$OUT/$f.txt"
  if "$TP" query -f "$SQLDIR/$f.sql" "$TRACE" > "$out" 2> "$out.err"; then
    rows=$(awk '/^"/{p=1} p' "$out" | tail -n +2 | wc -l)
    echo "PASS $f rows=$rows" >> "$OUT/summary.txt"
  else
    echo "FAIL $f exit=$? $(tail -1 "$out.err")" >> "$OUT/summary.txt"
  fi
  rm -f "$out.err"
done
cat "$OUT/summary.txt"
