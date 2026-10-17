#!/bin/sh
# Host-side pull with explicit failure propagation.
# Usage: host_pull.sh BOARD DEST FILE [FILE ...]
# Exits non-zero on the first scp failure or empty local file.
set -eu
BOARD=${1:?usage: host_pull.sh BOARD DEST FILE [FILE ...]}
DEST=${2:?usage: host_pull.sh BOARD DEST FILE [FILE ...]}
shift 2
WORK=${WORK:-/data/perfetto-worker}
mkdir -p "$DEST"

for f in "$@"; do
  out="$DEST/$f"
  if ! scp -q "$BOARD:$WORK/$f" "$out"; then
    echo "PULL FAIL: scp $BOARD:$WORK/$f" >&2
    exit 1
  fi
  if [ ! -s "$out" ]; then
    echo "PULL FAIL: $out is missing or empty" >&2
    exit 1
  fi
  echo "PULL OK: $f size=$(wc -c < "$out") sha256=$(sha256sum "$out" | awk '{print $1}')"
done
