#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# build.sh — cross-compile pf-demo-x5 for RDK X5 (aarch64, glibc).
#
#   ./build.sh                 cross build (default)
#   ./build.sh --host          native build (syntax / logic checks on the dev host)
#   ./build.sh --clean         remove build/out and build/third_party first
#
# The official Perfetto C++ SDK amalgamation (perfetto.h + perfetto.cc) is
# downloaded once into build/third_party/ and pinned by SHA256. The SDK is
# compiled into the binary; the binary stays dynamically linked (libc, libstdc++
# libgcc_s) and keeps debug info + build id for perf/heapprofd symbolisation.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SDK_VERSION="v58.2"
SDK_URL="https://github.com/google/perfetto/releases/download/${SDK_VERSION}/perfetto-cpp-sdk-src.zip"
SDK_SHA256="e56126ff81f0f914d35fe03c72419d147acf2890f36fbda7d4558fd5b84c4b09"

TOOLCHAIN="${AARCH64_TOOLCHAIN:-/opt/arm-gnu-toolchain-11.3.rel1-x86_64-aarch64-none-linux-gnu}"
TARGET_CXX="${CXX:-$TOOLCHAIN/bin/aarch64-none-linux-gnu-g++}"
HOST_CXX="${HOST_CXX:-g++}"

OUT_DIR="$HERE/out"
THIRD_PARTY="$HERE/third_party"
SDK_DIR="$THIRD_PARTY/perfetto-sdk"
SDK_ZIP="$THIRD_PARTY/perfetto-cpp-sdk-src-${SDK_VERSION}.zip"

MODE=cross
JOBS="$(nproc 2>/dev/null || echo 4)"
for arg in "$@"; do
  case "$arg" in
    --host) MODE=host ;;
    --clean) rm -rf "$OUT_DIR" "$THIRD_PARTY" ;;
    --jobs=*) JOBS="${arg#--jobs=}" ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$THIRD_PARTY" "$OUT_DIR"

# --- Perfetto C++ SDK -------------------------------------------------------
if [ ! -f "$SDK_DIR/perfetto.h" ] || [ ! -f "$SDK_DIR/perfetto.cc" ]; then
  echo "[build] fetching Perfetto C++ SDK ${SDK_VERSION}"
  rm -rf "$SDK_DIR"
  mkdir -p "$SDK_DIR"
  if [ ! -s "$SDK_ZIP" ]; then
    curl -fL --retry 5 --retry-delay 2 -o "$SDK_ZIP.part" "$SDK_URL"
    mv "$SDK_ZIP.part" "$SDK_ZIP"
  fi
  echo "${SDK_SHA256}  ${SDK_ZIP}" | sha256sum -c -
  unzip -o -q "$SDK_ZIP" -d "$SDK_DIR"
fi
if [ ! -f "$SDK_DIR/perfetto.h" ] || [ ! -f "$SDK_DIR/perfetto.cc" ]; then
  echo "[build] ERROR: SDK archive did not contain perfetto.h/perfetto.cc" >&2
  exit 1
fi

# --- build identity ---------------------------------------------------------
BUILD_ID="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
DIRTY=""
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null | head -1)" ]; then
  DIRTY="-dirty"
fi
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_TAG="${BUILD_ID}${DIRTY}"

COMMON_FLAGS=(
  -std=c++17 -O2 -g -fno-omit-frame-pointer -rdynamic -pthread
  -ffunction-sections -fdata-sections
  -I "$SDK_DIR" -I "$ROOT/src"
  -DPF_DEMO_BUILD_ID="\"${BUILD_TAG}\""
  -DPF_DEMO_PERFETTO_SDK="\"${SDK_VERSION}\""
)

if [ "$MODE" = host ]; then
  CXX="$HOST_CXX"
  BIN="$OUT_DIR/pf-demo-x5-host"
  echo "[build] native build with $($CXX --version | head -1)"
else
  CXX="$TARGET_CXX"
  BIN="$OUT_DIR/pf-demo-x5"
  if [ ! -x "$CXX" ]; then
    echo "[build] ERROR: cross compiler not found: $CXX" >&2
    echo "[build] set AARCH64_TOOLCHAIN or CXX" >&2
    exit 1
  fi
  echo "[build] cross build with $($CXX --version | head -1)"
fi

OBJ_DIR="$OUT_DIR/obj"
mkdir -p "$OBJ_DIR"

echo "[build] compiling src/pf_demo.cpp"
"$CXX" "${COMMON_FLAGS[@]}" -Wall -Wextra \
  -c "$ROOT/src/pf_demo.cpp" -o "$OBJ_DIR/pf_demo.o"

echo "[build] compiling Perfetto SDK (perfetto.cc) — this takes a while"
"$CXX" "${COMMON_FLAGS[@]}" \
  -c "$SDK_DIR/perfetto.cc" -o "$OBJ_DIR/perfetto.o"

echo "[build] linking $BIN"
# --build-id is mandatory for Perfetto symbolisation: perf callstack mappings
# carry the build id, and the UI/trace_processor resolve symbols by it.
"$CXX" "${COMMON_FLAGS[@]}" -Wl,--gc-sections -Wl,--build-id=sha1 \
  "$OBJ_DIR/pf_demo.o" "$OBJ_DIR/perfetto.o" -o "$BIN" -ldl

BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
FILE_DESC="$(file -b "$BIN")"
cat > "$OUT_DIR/VERSION.txt" <<EOF
program=pf-demo-x5
program_version=1.0.0
git_build_id=${BUILD_TAG}
build_time_utc=${BUILD_TIME}
build_host=$(uname -a)
compiler=$("$CXX" --version | head -1)
perfetto_sdk=${SDK_VERSION}
perfetto_sdk_sha256=${SDK_SHA256}
binary=$(basename "$BIN")
binary_sha256=${BIN_SHA}
binary_file=${FILE_DESC}
EOF

echo "[build] done: $BIN"
echo "[build] sha256: $BIN_SHA"
echo "[build] $(cat "$OUT_DIR/VERSION.txt" | tr '\n' ' ')"
