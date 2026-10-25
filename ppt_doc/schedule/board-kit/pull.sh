#!/bin/sh
# Host-side explicit failure propagation; use SSH keys/agent or interactive auth.
# No embedded credentials. Usage: pull.sh HOST REMOTE_DIR NEW_LOCAL_DIR FILE...
set -eu
HOST=${1:?}; REMOTE=${2:?}; DEST=${3:?}; shift 3
[ "$#" -gt 0 ] || { echo 'ERROR: specify filenames' >&2;exit 2; }
case "$HOST" in -*|*' '*|*';'*|*'`'*|*'$'*) echo 'ERROR: invalid host' >&2;exit 2;;esac
case "$REMOTE" in /*) ;; *) echo 'ERROR: absolute remote directory required' >&2;exit 2;;esac
case "$REMOTE" in *[!a-zA-Z0-9_./-]*) echo 'ERROR: unsafe remote directory' >&2;exit 2;;esac
mkdir "$DEST" || exit 2
for f in "$@"; do
 case "$f" in ''|.|..|*[!a-zA-Z0-9_.-]*) echo 'ERROR: basename required' >&2;exit 2;;esac
 scp -q "$HOST:$REMOTE/$f" "$DEST/$f.partial" || { echo 'PULL_FAILED' >&2;exit 1; }
 [ -s "$DEST/$f.partial" ] || { echo 'EMPTY_FILE' >&2;exit 1; }
 mv "$DEST/$f.partial" "$DEST/$f"
 if command -v sha256sum >/dev/null 2>&1; then sha256sum "$DEST/$f";fi
done
