#!/bin/sh
# Host-side dry run for the repo-root execution paths used by PLAN.md.
# No board, no real tracebox, no worker_app. It verifies that the root-relative
# config/script/skill paths exist and that C1 + host_pull work from the clone root.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
cd "$ROOT"

for f in \
  v2_modify/configs/C1-worker-timeline.pbtxt \
  v2_modify/configs/C2-worker-native-alloc.pbtxt \
  v2_modify/configs/C3-worker-cpu-profile.pbtxt \
  v2_modify/scripts/remote_lib.sh \
  v2_modify/scripts/remote_c1.sh \
  v2_modify/scripts/remote_c2.sh \
  v2_modify/scripts/remote_c3.sh \
  v2_modify/scripts/remote_stop.sh \
  v2_modify/scripts/host_pull.sh \
  v1_modify/candidate-v1.0.1/scripts/survey.sh \
  v1_modify/candidate-v1.0.1/scripts/validate_config.py \
  v2_modify2/sql/20-jitter-cycles.sql
do
  [ -f "$f" ] || { echo "PATH FAIL: missing $f"; exit 1; }
done
echo "PASS: repo-root paths exist"

M=$(mktemp -d "${TMPDIR:-/tmp}/v2modify2-path.XXXXXX")
trap 'rm -rf "$M"' EXIT
mkdir -p "$M/bin" "$M/work" "$M/pull"
cp v2_modify/configs/C1-worker-timeline.pbtxt "$M/work/"

cat > "$M/bin/tracebox" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then echo "v57.1-mock"; exit 0; fi
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out=$a
  prev=$a
done
[ -n "$out" ] || { echo "mock tracebox: no -o" >&2; exit 2; }
( sleep 2; printf "mock C1 trace\n" > "$out"; exit 0 ) &
echo $!
EOF
chmod +x "$M/bin/tracebox"

echo "== C1 via v2_modify/scripts from repo root =="
WORK="$M/work" TRACEBOX="$M/bin/tracebox" sh v2_modify/scripts/remote_c1.sh
[ -s "$M/work/C1.pftrace" ] || { echo "PATH FAIL: C1 empty"; exit 1; }
grep -q "C1 DONE" "$M/work/C1.status" || { echo "PATH FAIL: no C1.status"; exit 1; }
echo "PASS: C1 root-relative script/config"

cat > "$M/bin/scp" <<'EOF'
#!/bin/sh
# fake scp: -q SRC DST; copy by basename from FAKE_SCP_ROOT
src=$2; dst=$3
base=$(basename "$src")
cp "${FAKE_SCP_ROOT:?}/$base" "$dst"
EOF
chmod +x "$M/bin/scp"

echo "== host_pull via v2_modify/scripts from repo root =="
PATH="$M/bin:$PATH" WORK="$M/work" FAKE_SCP_ROOT="$M/work" \
  sh v2_modify/scripts/host_pull.sh fakeboard "$M/pull" C1.pftrace C1.log C1.status
echo "PASS: host_pull root-relative script"
