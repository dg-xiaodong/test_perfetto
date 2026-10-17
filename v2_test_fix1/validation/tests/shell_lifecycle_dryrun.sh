#!/bin/sh
# Host-side dry run for the remote lifecycle scripts. No board, no real
# tracebox, no worker_app: it uses mock binaries to verify PID handling,
# observation time, stop/flush ordering, and pull failure propagation.
set -eu

FIX=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/perfetto-lifecycle.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/bin" "$ROOT/work" "$ROOT/app" "$ROOT/pull"

cat > "$ROOT/bin/tracebox" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then echo "v57.1-mock"; exit 0; fi
if [ "${1:-}" = "perfetto" ]; then echo "PRODUCERS: heapprofd"; exit 0; fi
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out=$a; fi
  prev=$a
done
[ -n "$out" ] || { echo "mock tracebox: no -o" >&2; exit 2; }
case "$*" in
  *C1-worker-timeline*|*C3-worker-cpu-profile*)
    ( sleep 2; printf "mock-scheduled-trace\n" > "$out"; exit 0 ) &
    echo $!
    exit 0
    ;;
esac
(
  trap 'printf "mock-trace\n" > "$out"; exit 0' INT TERM
  while :; do sleep 0.1; done
) &
echo $!
EOF
chmod +x "$ROOT/bin/tracebox"

cat > "$ROOT/app/worker_app" <<'EOF'
#!/bin/sh
echo "mock app started"
trap 'echo "mock app term"; exit 0' TERM INT
while :; do sleep 0.2; done
EOF
chmod +x "$ROOT/app/worker_app"

: > "$ROOT/work/libheapprofd_glibc_preload.so"
: > "$ROOT/work/C2-worker-native-alloc.pbtxt"
: > "$ROOT/work/C1-worker-timeline.pbtxt"
: > "$ROOT/work/C3-worker-cpu-profile.pbtxt"
printf "mock C1 trace\n" > "$ROOT/work/C1.pftrace"

echo "== C2 lifecycle dry run =="
WORK="$ROOT/work" TRACEBOX="$ROOT/bin/tracebox" OBSERVE_S=2 \
  sh "$FIX/scripts/remote_c2.sh" "$ROOT/app" "$ROOT/app/worker_app" ""
[ -s "$ROOT/work/C2.pftrace" ] || { echo "FAIL: C2 trace empty"; exit 1; }
grep -q "C2 DONE" "$ROOT/work/C2.status" || { echo "FAIL: no DONE"; exit 1; }
echo "PASS: C2 lifecycle, trace non-empty"

echo "== C1/C3 completion dry run =="
WORK="$ROOT/work" TRACEBOX="$ROOT/bin/tracebox" sh "$FIX/scripts/remote_c1.sh"
WORK="$ROOT/work" TRACEBOX="$ROOT/bin/tracebox" sh "$FIX/scripts/remote_c3.sh"
[ -s "$ROOT/work/C1.pftrace" ] || { echo "FAIL: C1 empty"; exit 1; }
[ -s "$ROOT/work/C3.pftrace" ] || { echo "FAIL: C3 empty"; exit 1; }
grep -q "C1 DONE" "$ROOT/work/C1.status" || { echo "FAIL: C1 no DONE"; exit 1; }
grep -q "C3 DONE" "$ROOT/work/C3.status" || { echo "FAIL: C3 no DONE"; exit 1; }
echo "PASS: C1/C3 completion, non-empty outputs"

echo "== remote_stop dry run =="
WORK="$ROOT/work" TRACEBOX="$ROOT/bin/tracebox" sh "$FIX/scripts/remote_stop.sh" C1
if WORK="$ROOT/work" TRACEBOX="$ROOT/bin/tracebox" sh "$FIX/scripts/remote_stop.sh" MISSING; then
  echo "FAIL: stop of missing pid returned success"; exit 1
else
  echo "PASS: missing pid propagated"
fi

cat > "$ROOT/bin/scp" <<'EOF'
#!/bin/sh
# fake scp: -q SRC DST
src=$2; dst=$3
case "$src" in
  *MISSING*) echo "fake scp: no such file" >&2; exit 1;;
esac
cp "${FAKE_SCP_SRC:?}" "$dst"
EOF
chmod +x "$ROOT/bin/scp"

echo "== host_pull success =="
PATH="$ROOT/bin:$PATH" WORK="$ROOT/work" FAKE_SCP_SRC="$ROOT/work/C1.pftrace" \
  sh "$FIX/scripts/host_pull.sh" fakeboard "$ROOT/pull" C1.pftrace
echo "PASS: pull success"

echo "== host_pull missing file =="
if PATH="$ROOT/bin:$PATH" WORK="$ROOT/work" FAKE_SCP_SRC="$ROOT/work/C1.pftrace" \
  sh "$FIX/scripts/host_pull.sh" fakeboard "$ROOT/pull" MISSING.pftrace; then
  echo "FAIL: pull of missing file returned success"; exit 1
else
  echo "PASS: pull failure propagated"
fi

echo "== host_pull empty file =="
: > "$ROOT/work/EMPTY.pftrace"
if PATH="$ROOT/bin:$PATH" WORK="$ROOT/work" FAKE_SCP_SRC="$ROOT/work/EMPTY.pftrace" \
  sh "$FIX/scripts/host_pull.sh" fakeboard "$ROOT/pull" EMPTY.pftrace; then
  echo "FAIL: pull of empty file returned success"; exit 1
else
  echo "PASS: empty file rejected"
fi
