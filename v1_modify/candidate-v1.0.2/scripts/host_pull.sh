#!/bin/sh
# Host-side pull with explicit failure propagation.
# Usage: host_pull.sh BOARD REMOTE_DIR DEST FILE [FILE ...]
# Exits non-zero on the first scp failure or empty local file.
set -eu
BOARD=${1:?usage: host_pull.sh BOARD REMOTE_DIR DEST FILE [FILE ...]}
REMOTE_DIR=${2:?usage: host_pull.sh BOARD REMOTE_DIR DEST FILE [FILE ...]}
DEST=${3:?usage: host_pull.sh BOARD REMOTE_DIR DEST FILE [FILE ...]}
shift 3
mkdir -p "$DEST"

for f in "$@"; do
  out="$DEST/$f"
  if ! scp -q "$BOARD:$REMOTE_DIR/$f" "$out"; then
    echo "PULL FAIL: scp $BOARD:$REMOTE_DIR/$f" >&2
    exit 1
  fi
  if [ ! -s "$out" ]; then
    echo "PULL FAIL: $out missing or empty" >&2
    exit 1
  fi
  echo "PULL OK: $f size=$(wc -c < "$out") sha256=$(sha256sum "$out" | awk '{print $1}')"
done
