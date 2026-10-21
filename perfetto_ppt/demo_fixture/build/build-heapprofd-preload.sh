#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# build-heapprofd-preload.sh — build libheapprofd_glibc_preload.so for aarch64
# from a Perfetto source checkout.
#
#   PERFETTO_SRC=~/perfetto ./build-heapprofd-preload.sh
#
# This is only needed when the official linux-arm64 release does not ship the
# preload library (or when the library must match the *exact* Perfetto version
# of the traced/tracebox service). The glibc preload client is the only
# supported way to get heapprofd data on non-Android Linux.
#
# Requirements: Perfetto source tree, gn + ninja (the checkout's buildtools are
# used automatically), a clang that can target aarch64, and a glibc sysroot that
# matches the board (RDK X5: glibc 2.35).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$(cd "$HERE/.." && pwd)"
OUT="$HERE/out"
PERFETTO_SRC="${PERFETTO_SRC:-}"

if [ -z "$PERFETTO_SRC" ] || [ ! -f "$PERFETTO_SRC/BUILD.gn" ]; then
  cat >&2 <<'EOF'
ERROR: set PERFETTO_SRC to a Perfetto checkout, e.g.

  git clone https://github.com/google/perfetto ~/perfetto
  cd ~/perfetto && git checkout v58.2
  tools/install-build-deps --linux-arm
  PERFETTO_SRC=~/perfetto perfetto_ppt/demo_fixture/build/build-heapprofd-preload.sh
EOF
  exit 1
fi

VERSION="$(git -C "$PERFETTO_SRC" describe --tags 2>/dev/null || echo unknown)"
COMMIT="$(git -C "$PERFETTO_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"

cd "$PERFETTO_SRC"
if [ ! -f out/arm64/build.ninja ]; then
  gn gen out/arm64 --args='is_debug=false target_cpu="arm64"'
fi
tools/ninja -C out/arm64 heapprofd_glibc_preload

mkdir -p "$OUT"
cp "out/arm64/libheapprofd_glibc_preload.so" "$OUT/libheapprofd_glibc_preload.so"
strip --strip-debug "$OUT/libheapprofd_glibc_preload.so" 2>/dev/null || true

{
  echo "artifact=libheapprofd_glibc_preload.so"
  echo "built_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "perfetto_version=${VERSION}"
  echo "perfetto_commit=${COMMIT}"
  echo "sha256=$(sha256sum "$OUT/libheapprofd_glibc_preload.so" | awk '{print $1}')"
  echo "file=$(file -b "$OUT/libheapprofd_glibc_preload.so")"
} | tee "$OUT/heapprofd-preload.txt"

echo "[build] $OUT/libheapprofd_glibc_preload.so"
