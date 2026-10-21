#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# install.sh — deploy pf-demo-x5 to the RDK X5 board.
#
# Run from the host (this directory tree). Examples:
#   ./install.sh                                   # deploy + enable autostart + start
#   ./install.sh --no-start                        # deploy but do not start now
#   ./install.sh --no-autostart                    # deploy + start, no boot hook
#   SSHPASS=root ./install.sh                      # password auth via sshpass
#   ./install.sh --host root@192.168.1.10 --dest /userdata/perfetto-training-demo
#
# What it does:
#   * creates /userdata/perfetto-training-demo/{bin,lib,scripts,configs,logs,run}
#   * installs the cross-compiled binary + build identity (VERSION.txt/build_info.txt)
#   * installs the optional heapprofd glibc preload library
#   * installs the tracing tools (from build/third_party/perfetto-bin if present,
#     otherwise it reuses the board's /userdata/bin/{traced,tracebox,...})
#   * appends a guarded block to the existing /userdata/startup.sh (the board's
#     S99auto_startup hook) — nothing else is modified
#   * starts the service through the crash-limited supervisor
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$FIXTURE/../.." && pwd)"

BOARD="${BOARD:-root@192.168.1.10}"
DEST="${DEST:-/userdata/perfetto-training-demo}"
DO_START=1
DO_AUTOSTART=1
BINARY="$FIXTURE/build/out/pf-demo-x5"
PRELOAD=""
PERFETTO_BIN_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --host) BOARD="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --preload) PRELOAD="$2"; shift 2 ;;
    --perfetto-bin-dir) PERFETTO_BIN_DIR="$2"; shift 2 ;;
    --no-start) DO_START=0; shift ;;
    --no-autostart) DO_AUTOSTART=0; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
if [ -n "${SSHPASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
  SSH=(sshpass -e ssh "${SSH_OPTS[@]}")
  SCP=(sshpass -e scp "${SSH_OPTS[@]}")
else
  SSH=(ssh "${SSH_OPTS[@]}")
  SCP=(scp "${SSH_OPTS[@]}")
fi

remote() { "${SSH[@]}" "$BOARD" "$@"; }
push() { "${SCP[@]}" "$@" "$BOARD:$DEST/"; }

[ -f "$BINARY" ] || { echo "ERROR: binary not found: $BINARY (run build/build.sh first)" >&2; exit 1; }
if ! file -b "$BINARY" | grep -q "ARM aarch64"; then
  echo "ERROR: $BINARY is not an aarch64 executable" >&2
  exit 1
fi
if [ -z "$PRELOAD" ] && [ -f "$FIXTURE/build/out/libheapprofd_glibc_preload.so" ]; then
  PRELOAD="$FIXTURE/build/out/libheapprofd_glibc_preload.so"
fi

echo "[install] board=$BOARD dest=$DEST"
echo "[install] binary=$BINARY ($(sha256sum "$BINARY" | cut -c1-16)...)"

remote "mkdir -p '$DEST/bin' '$DEST/bin/perfetto' '$DEST/lib' '$DEST/scripts' '$DEST/configs' '$DEST/logs' '$DEST/run'"

echo "[install] copying binary, scripts, configs"
push "$BINARY"
remote "mv '$DEST/$(basename "$BINARY")' '$DEST/bin/pf-demo-x5'"
"${SCP[@]}" "$FIXTURE"/scripts/*.sh "$BOARD:$DEST/scripts/"
"${SCP[@]}" "$FIXTURE"/configs/*.cfg "$BOARD:$DEST/configs/"
remote "chmod 755 '$DEST/bin/pf-demo-x5' '$DEST'/scripts/*.sh"

if [ -n "$PRELOAD" ]; then
  echo "[install] installing heapprofd preload library: $PRELOAD"
  push "$PRELOAD"
  remote "mv '$DEST/$(basename "$PRELOAD")' '$DEST/lib/libheapprofd_glibc_preload.so'; chmod 644 '$DEST/lib/libheapprofd_glibc_preload.so'"
fi

# Build identity as seen from the board.
{
  echo "program=pf-demo-x5"
  echo "installed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "deployed_from=$BINARY"
  echo "deployed_sha256=$(sha256sum "$BINARY" | awk '{print $1}')"
  sed 's/^/build_/' "$FIXTURE/build/out/VERSION.txt" 2>/dev/null || true
} > "$FIXTURE/build/out/deploy-identity.txt"
push "$FIXTURE/build/out/deploy-identity.txt"
remote "mv '$DEST/deploy-identity.txt' '$DEST/build_info.txt'"

# Tracing tools: prefer a local directory, else reuse the board's existing set.
if [ -n "$PERFETTO_BIN_DIR" ]; then
  echo "[install] installing perfetto tools from $PERFETTO_BIN_DIR"
  for tool in traced traced_probes tracebox perfetto; do
    if [ -f "$PERFETTO_BIN_DIR/$tool" ]; then
      "${SCP[@]}" "$PERFETTO_BIN_DIR/$tool" "$BOARD:$DEST/bin/perfetto/"
    fi
  done
fi
remote "for t in traced traced_probes tracebox perfetto; do \
          if [ ! -x '$DEST/bin/perfetto/'\$t ] && [ -x '/userdata/bin/'\$t ]; then \
            cp -f '/userdata/bin/'\$t '$DEST/bin/perfetto/'\$t; \
          fi; \
        done; chmod 755 '$DEST/bin/perfetto/'* 2>/dev/null || true; \
        ls -l '$DEST/bin/perfetto/' 2>/dev/null | sed 's/^/  /'"
remote "if [ -x '$DEST/bin/perfetto/tracebox' ]; then '$DEST/bin/perfetto/tracebox' --version 2>&1 | head -1; fi" \
  > "$FIXTURE/build/out/tracebox-version.txt" || true
cat "$FIXTURE/build/out/tracebox-version.txt" 2>/dev/null | sed 's/^/[install] /'

if [ "$DO_AUTOSTART" -eq 1 ]; then
  echo "[install] enabling autostart (appends a marked block to /userdata/startup.sh)"
  remote "'$DEST/scripts/autostart-enable.sh'"
else
  echo "[install] autostart not enabled (--no-autostart)"
fi

if [ "$DO_START" -eq 1 ]; then
  echo "[install] starting service"
  remote "'$DEST/scripts/start.sh'"
else
  echo "[install] not started (--no-start); run $DEST/scripts/start.sh on the board"
fi

echo "[install] status:"
remote "'$DEST/scripts/status.sh'" | sed 's/^/  /'
