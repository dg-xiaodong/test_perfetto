#!/bin/sh
# Host-side mock regression for the generic Linux session scripts.
# No board, no real tracebox, no target application.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
M=$(mktemp -d "${TMPDIR:-/tmp}/skill-linux-sessions.XXXXXX")
trap 'rm -rf "$M"' EXIT
mkdir -p "$M/bin" "$M/work" "$M/app" "$M/pull"

: > "$M/trace.pbtxt"
: > "$M/heap.pbtxt"
: > "$M/preload.so"

cat > "$M/bin/tracebox" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then echo "v57.1-mock"; exit 0; fi
if [ "${1:-}" = "perfetto" ]; then echo "PRODUCERS: heapprofd"; exit 0; fi
out=""; cfg=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out=$a
  [ "$prev" = "-c" ] && cfg=$a
  prev=$a
done
[ -n "$out" ] || { echo "mock tracebox: no -o" >&2; exit 2; }
case "$cfg" in
  *heap.pbtxt*)
    ( trap 'printf "mock-heap\n" > "$out"; exit 0' INT TERM
      while :; do sleep 0.1; done ) &
    ;;
  *)
    ( sleep 1; printf "mock-trace\n" > "$out"; exit 0 ) &
    ;;
esac
echo $!
EOF
chmod +x "$M/bin/tracebox"

cat > "$M/app/app" <<'EOF'
#!/bin/sh
echo "mock app started"
trap 'echo "mock app term"; exit 0' TERM INT
while :; do sleep 0.2; done
EOF
chmod +x "$M/app/app"

echo "== generic trace session =="
WORK="$M/work" TRACEBOX="$M/bin/tracebox" \
  sh "$ROOT/scripts/linux_trace_session.sh" "$M/trace.pbtxt" trace 10
[ -s "$M/work/trace.pftrace" ] || { echo "FAIL: trace empty"; exit 1; }
grep -q "DONE" "$M/work/trace.status" || { echo "FAIL: no trace status"; exit 1; }
echo "PASS: linux_trace_session"

echo "== generic heapprofd session =="
WORK="$M/work" TRACEBOX="$M/bin/tracebox" OBSERVE_S=2 \
  sh "$ROOT/scripts/linux_heapprofd_session.sh" \
  "$M/heap.pbtxt" "$M/preload.so" "$M/app" ./app
[ -s "$M/work/heap.pftrace" ] || { echo "FAIL: heap trace empty"; exit 1; }
grep -q "DONE" "$M/work/heap.status" || { echo "FAIL: no heap status"; exit 1; }
echo "PASS: linux_heapprofd_session"

cat > "$M/bin/scp" <<'EOF'
#!/bin/sh
# fake scp: -q SRC DST
src=$2; dst=$3
base=$(basename "$src")
cp "${FAKE_SCP_ROOT:?}/$base" "$dst"
EOF
chmod +x "$M/bin/scp"

echo "== host_pull success =="
PATH="$M/bin:$PATH" FAKE_SCP_ROOT="$M/work" \
  sh "$ROOT/scripts/host_pull.sh" fakeboard "$M/work" "$M/pull" trace.pftrace trace.status
echo "PASS: host_pull success"

echo "== host_pull missing =="
if PATH="$M/bin:$PATH" FAKE_SCP_ROOT="$M/work" \
  sh "$ROOT/scripts/host_pull.sh" fakeboard "$M/work" "$M/pull" MISSING.pftrace; then
  echo "FAIL: missing pull returned success"; exit 1
else
  echo "PASS: host_pull failure propagated"
fi
