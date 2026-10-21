#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# verify.sh — on-board evidence collector for the pf-demo-x5 fixture.
#
#   verify.sh [duration_seconds] [sample_interval_seconds]
#
# Samples the *running* program (it does not change its configuration) and
# writes a self-contained evidence bundle under logs/verify-<timestamp>/:
#   rss.csv       1 Hz RSS / thread-count
#   cpu.csv       per-CPU busy jiffies (two columns per sample for deltas)
#   threads.csv   per-thread state + utime/stime
#   phases.txt    phase-transition lines from the service log
#   summary.txt   PASS/FAIL summary
#
# The duration defaults to 100 s so that at least two 48 s cycle are covered.
set -u

D=$(cd "$(dirname "$0")/.." && pwd)
DURATION=${1:-100}
INTERVAL=${2:-1}

case "$DURATION" in ''|*[!0-9]*) echo "usage: $0 [duration_s] [interval_s]" >&2; exit 2 ;; esac
[ "$DURATION" -ge 10 ] || { echo "duration must be >= 10s" >&2; exit 2; }

PID=""
[ -f "$D/run/app.pid" ] && PID=$(cat "$D/run/app.pid" 2>/dev/null)
if [ -z "${PID:-}" ] || ! kill -0 "$PID" 2>/dev/null; then
    echo "ERROR: pf-demo-x5 is not running (start it first)" >&2
    exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$D/logs/verify-$STAMP"
mkdir -p "$OUT"
RSS_CSV="$OUT/rss.csv"
CPU_CSV="$OUT/cpu.csv"
THREAD_CSV="$OUT/threads.csv"

START_EPOCH=$(date +%s)
echo "verifying pid=$PID for ${DURATION}s (interval ${INTERVAL}s), output $OUT"

frames_before=0
[ -f "$D/logs/frames.log" ] && frames_before=$(wc -l < "$D/logs/frames.log")
mon_before=$(grep -c '^MON ' "$D/logs/pf-demo-x5.log" 2>/dev/null || echo 0)
tail -n 2000 "$D/logs/pf-demo-x5.log" 2>/dev/null | grep '^PHASE ' > "$OUT/phases.txt"

echo "ts rss_kb threads" > "$RSS_CSV"
echo "ts cpu0_busy cpu0_total cpu1_busy cpu1_total cpu2_busy cpu2_total cpu3_busy cpu3_total cpu4_busy cpu4_total cpu5_busy cpu5_total cpu6_busy cpu6_total cpu7_busy cpu7_total" > "$CPU_CSV"
echo "ts tid comm state cpu_ticks" > "$THREAD_CSV"

i=0
while [ "$i" -lt "$DURATION" ]; do
    now=$(date +%s)
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "ERROR: process disappeared during verification" >&2
        break
    fi
    rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$PID/status" 2>/dev/null)
    thr=$(awk '/^Threads:/ {print $2}' "/proc/$PID/status" 2>/dev/null)
    echo "$now ${rss:-0} ${thr:-0}" >> "$RSS_CSV"

    # Per-CPU busy = total - idle - iowait, in jiffies.
    cpu_line=$(awk '/^cpu[0-7] / {
        total=0; idle=$5+$6;
        for (j=2; j<=9; j++) total+=$j;
        printf "%d %d ", (total-idle), total
    } END {print ""}' /proc/stat)
    echo "$now $cpu_line" >> "$CPU_CSV"

    for taskdir in /proc/"$PID"/task/*; do
        [ -d "$taskdir" ] || continue
        tid=$(basename "$taskdir")
        comm=$(cat "$taskdir/comm" 2>/dev/null)
        statline=$(cat "$taskdir/stat" 2>/dev/null)
        [ -n "$statline" ] || continue
        state=$(printf '%s' "$statline" | sed 's/.*) //' | awk '{print $1}')
        ticks=$(printf '%s' "$statline" | sed 's/.*) //' | awk '{print $12+$13}')
        echo "$now $tid $comm $state $ticks" >> "$THREAD_CSV"
    done

    i=$((i + INTERVAL))
    sleep "$INTERVAL"
done

frames_after=0
[ -f "$D/logs/frames.log" ] && frames_after=$(wc -l < "$D/logs/frames.log")
tail -n 2000 "$D/logs/pf-demo-x5.log" 2>/dev/null | grep '^MON ' > "$OUT/mon.txt"
tail -n 2000 "$D/logs/pf-demo-x5.log" 2>/dev/null | grep '^PHASE ' >> "$OUT/phases.txt"

# ---- summary ---------------------------------------------------------------
{
    END_EPOCH=$(date +%s)
    ACTUAL=$((END_EPOCH - START_EPOCH))
    echo "pf-demo-x5 verification $STAMP"
    echo "pid=$PID requested_duration_s=$DURATION actual_duration_s=$ACTUAL interval_s=$INTERVAL"
    echo ""

    echo "== memory =="
    awk 'NR>1 {if (min=="" || $2<min) min=$2; if ($2>max) max=$2; n++}
         END {printf "rss_kb min=%s max=%s delta=%s samples=%d\n", min, max, max-min, n}' "$RSS_CSV"
    awk 'NR>1 {if ($3>tmax) tmax=$3} END {printf "threads max=%s\n", tmax}' "$RSS_CSV"
    echo ""

    echo "== per-CPU utilisation (worst interval per core) =="
    awk 'NR==1 {next}
         {for (c=0; c<8; c++) {
             b=$((2+c*2)); t=$((2+c*2+1));
             if (pt[c] != "" && t>pt[c]) {
                 d=(t-pt[c])>0 ? (t-pt[c]) : 0;
                 pct=(b-pb[c])*100/d;
                 if (pct>mx[c]) mx[c]=pct;
             }
             pb[c]=b; pt[c]=t;
         }}
         END {for (c=0; c<8; c++) printf "cpu%d peak_busy_pct=%.0f\n", c, mx[c]+0}' "$CPU_CSV"
    echo ""

    echo "== thread states (share of samples in R = running-or-runnable) =="
    awk 'NR>1 {key=$3" "$4; total[key]++; if ($4=="R") r[key]++}
         END {for (k in total) printf "%-16s samples=%4d R_pct=%.0f\n", k, total[k], 100*r[k]/total[k]}' "$THREAD_CSV" |
        sort
    echo ""

    echo "== frames =="
    WINDOW_FRAMES=$((frames_after - frames_before))
    echo "frames_logged_in_window=$WINDOW_FRAMES total=$frames_after actual_fps=$((WINDOW_FRAMES / (ACTUAL > 0 ? ACTUAL : 1)))"
    if [ -f "$D/logs/frames.log" ]; then
        awk '{for (i=1;i<=NF;i++) if ($i ~ /^id=/) {sub("id=","",$i); print $i}}' "$D/logs/frames.log" 2>/dev/null |
            sort -n | awk 'BEGIN{prev=-1; dup=0} {if ($1==prev) dup++; prev=$1} END{printf "unique_frame_ids=%d duplicates=%d\n", NR-dup, dup}'
        awk '{for (i=1;i<=NF;i++) if ($i ~ /^e2e_ms=/) {split($i,a,"="); if (a[2]>mx) mx=a[2]}}
             END {printf "e2e_latency_max_ms=%.2f\n", mx}' "$D/logs/frames.log"
        awk '{for (i=1;i<=NF;i++) {
                 if ($i ~ /^phase=/) p=$i;
                 if ($i ~ /^inf_dur_ms=/) {split($i,a,"="); d=a[2]}
              }
              if (d>mx[p]) mx[p]=d; sum[p]+=d; n[p]++}
             END {for (k in n) printf "infer %s frames=%d avg_ms=%.2f max_ms=%.2f\n", k, n[k], sum[k]/n[k], mx[k]}' "$D/logs/frames.log"
        awk '{for (i=1;i<=NF;i++) if ($i ~ /^phase=/) p=$i}
             {c[p]++} END {for (k in c) printf "frames %s = %d\n", k, c[k]}' "$D/logs/frames.log"
    fi
    echo ""

    echo "== wakeup latency proxy (pf-schedprobe, from MON lines) =="
    awk '{for (i=1;i<=NF;i++) if ($i ~ /^wakeup_over_ms=/) {split($i,a,"="); if (a[2]>mx) mx=a[2]}}
         END {printf "wakeup_overshoot_max_ms=%.3f\n", mx}' "$OUT/mon.txt"
    awk '{for (i=1;i<=NF;i++) if ($i ~ /^cv_wakeups=/) {split($i,a,"="); v=a[2]}}
         BEGIN{first=""} {if (first=="") first=v; last=v}
         END {printf "cv_wakeups_first=%s last=%s delta=%d\n", first, last, last-first}' "$OUT/mon.txt"
    echo ""

    echo "== phase transitions observed =="
    cat "$OUT/phases.txt"
} | tee "$OUT/summary.txt"

# PASS/FAIL heuristics. These are evidence checks, not a proof of correctness.
fail=0
check() {
    label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        fail=$((fail + 1))
    fi
}

{
    echo ""
    echo "== checks =="
} >> "$OUT/summary.txt"

rss_delta=$(awk 'NR>1 {if (min=="" || $2<min) min=$2; if ($2>max) max=$2} END {print max-min}' "$RSS_CSV")
frame_delta=$((frames_after - frames_before))
phase_kinds=$(awk '{print $4}' "$OUT/phases.txt" | sort -u | wc -l)
wake_max=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^wakeup_over_ms=/) {split($i,a,"="); if (a[2]>mx) mx=a[2]}} END {print mx+0}' "$OUT/mon.txt")
cv_delta=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^cv_wakeups=/) {split($i,a,"="); v=a[2]}}
             BEGIN{first=""} {if (first=="") first=v; last=v}
             END {print last-first}' "$OUT/mon.txt")

[ "$rss_delta" -ge 4096 ] && echo "PASS rss_pulse_delta_kb=$rss_delta" >> "$OUT/summary.txt" || { echo "FAIL rss_pulse_delta_kb=$rss_delta" >> "$OUT/summary.txt"; fail=$((fail+1)); }
[ "$frame_delta" -ge 30 ] && echo "PASS frames_in_window=$frame_delta" >> "$OUT/summary.txt" || { echo "FAIL frames_in_window=$frame_delta" >> "$OUT/summary.txt"; fail=$((fail+1)); }
[ "$phase_kinds" -ge 4 ] && echo "PASS phases_seen=$phase_kinds" >> "$OUT/summary.txt" || { echo "FAIL phases_seen=$phase_kinds" >> "$OUT/summary.txt"; fail=$((fail+1)); }
[ "$cv_delta" -ge 10 ] && echo "PASS cv_wakeups_in_window=$cv_delta" >> "$OUT/summary.txt" || { echo "FAIL cv_wakeups_in_window=$cv_delta" >> "$OUT/summary.txt"; fail=$((fail+1)); }
echo "wakeup_overshoot_max_ms=$wake_max (contention evidence; no threshold)" >> "$OUT/summary.txt"
echo "" >> "$OUT/summary.txt"
echo "RESULT=$([ "$fail" -eq 0 ] && echo PASS || echo "FAIL($fail)")" >> "$OUT/summary.txt"

tail -n 20 "$OUT/summary.txt"
echo ""
echo "evidence: $OUT"
[ "$fail" -eq 0 ] || exit 1
