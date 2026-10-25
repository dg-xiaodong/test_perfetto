#!/usr/bin/env python3
"""Offline correlation of public a_latency.csv with the captured Perfetto trace.

Inputs (all produced in ../):
  analysis/pf_t0_states.csv   thread_state dump for UTID 210 (sql from report)
  analysis/cpu5_slices.csv    sched_slice dump for CPU 5
  a_latency_after.csv         public latency file pulled right after capture

Clock: trace timestamps are BOOTTIME. The trace ClockSnapshot at session start
reports MONOTONIC = BOOTTIME + 291 ns, so a public CLOCK_MONOTONIC timestamp t
maps to trace ts = t - 291 ns.  Residual of matched Running intervals is
reported so the mapping can be audited independently.
"""
import bisect
import csv
import statistics
from collections import Counter, defaultdict

OFF = 291  # MONOTONIC - BOOTTIME, ns (start ClockSnapshot)
TRACE_START = 4554475669046
TRACE_END = 4584181768269


def num(x):
    return None if x in ("[NULL]", "", "NULL") else int(x)


def load_states(path):
    st = []
    with open(path) as f:
        for r in csv.DictReader(f):
            st.append((int(r["ts"]), int(r["dur"]), r["state"], r["cpu"],
                       num(r["waker_utid"]), num(r["irq_context"])))
    st.sort()
    return st


def load_latency(path):
    rows = []
    with open(path) as f:
        for x in csv.DictReader(f):
            rows.append(tuple(int(x[k]) for k in
                              ("seq", "scheduled_ns", "start_ns", "finish_ns", "latency_ns")))
    return rows


def main():
    st = load_states("analysis/pf_t0_states.csv")
    tl = [s[0] for s in st]

    def containing(t):
        i = bisect.bisect_right(tl, t) - 1
        while i >= 0:
            ts, dur, state, cpu, wk, irq = st[i]
            if dur == -1 or ts <= t < ts + dur:
                return i
            i -= 1
        return None

    rows = load_latency("a_latency_after.csv")
    inwin = [r for r in rows if TRACE_START <= r[2] <= TRACE_END]

    late_rows = [r for r in inwin if r[4] > 5_000_000]
    clusters = []
    for r in late_rows:
        if not clusters or r[1] - clusters[-1][-1][1] > 100_000_000:
            clusters.append([r])
        else:
            clusters[-1].append(r)

    print("== public CSV rows whose start falls inside the trace ==")
    print("rows=%d late(>5ms)=%d clusters=%d" % (len(inwin), len(late_rows), len(clusters)))
    for c in clusters:
        print("  seq %d..%d  scheduled_mono %d..%d  span_ms=%.0f n=%d maxlat_ms=%.1f meanlat_ms=%.1f"
              % (c[0][0], c[-1][0], c[0][1], c[-1][1],
                 (c[-1][1] - c[0][1]) / 1e6, len(c),
                 max(x[4] for x in c) / 1e6, sum(x[4] for x in c) / len(c) / 1e6))

    # identity + clock audit: every CSV start should sit inside a pf-t0 Running interval
    matched, resid, unmatched = [], [], []
    for r in inwin:
        i = containing(r[2])
        if i is None or st[i][2] != "Running":
            unmatched.append(r)
            continue
        resid.append(r[2] - st[i][0])
        matched.append((r, i))
    resid.sort()
    print("\n== identity / clock audit ==")
    print("matched %d/%d; residual (csv_start - trace_running_ts) us: min %.1f p50 %.1f p90 %.1f max %.1f"
          % (len(matched), len(inwin), resid[0] / 1e3, statistics.median(resid) / 1e3,
             resid[int(len(resid) * .9)] / 1e3, resid[-1] / 1e3))
    for r in unmatched:
        print("  UNMATCHED:", r, "(trace lead edge)" if r[2] - TRACE_START < 5e6 else "")

    # decomposition: scheduled -> S/R boundary (wake) -> Running (CPU granted)
    dec = []
    for r, i in matched:
        j = i - 1
        if j < 0 or st[j][2] != "R":
            continue
        run_ts = st[i][0]
        wake_ts = st[j][0]
        dec.append((r, wake_ts - (r[1] - OFF), run_ts - wake_ts, st[j][4], st[j][3], st[j][5]))
    print("\n== decomposition of matched episodes ==")
    print("episodes with direct S/D->R->Running adjacency: %d" % len(dec))
    waits = sorted(d[2] for d in dec)
    print("runnable wait ms: p50 %.3f p90 %.3f p99 %.3f max %.3f"
          % (statistics.median(waits) / 1e6, waits[int(len(waits) * .9)] / 1e6,
             waits[int(len(waits) * .99)] / 1e6, waits[-1] / 1e6))
    late_dec = [d for d in dec if d[0][4] > 5_000_000]
    print("late episodes=%d  total runnable wait=%.1f ms" % (len(late_dec), sum(d[2] for d in late_dec) / 1e6))
    if late_dec:
        wd = sorted(d[1] for d in late_dec)
        rw = sorted(d[2] for d in late_dec)
        print("  wake_delay us: min %.1f p50 %.1f max %.1f"
              % (wd[0] / 1e3, statistics.median(wd) / 1e3, wd[-1] / 1e3))
        print("  runnable_wait ms: min %.2f p50 %.2f max %.2f"
              % (rw[0] / 1e6, statistics.median(rw) / 1e6, rw[-1] / 1e6))
        print("  runnable share of latency: p50 %.4f" % statistics.median(d[2] / d[0][4] for d in late_dec))
        print("  late wake irq_context=1: %d/%d; waker_utid distribution: %s"
              % (sum(1 for d in late_dec if d[5] == 1), len(late_dec),
                 dict(Counter(d[3] for d in late_dec))))

    # CPU5 occupancy during runnable waits (all processes, never target-scoped)
    cs = []
    with open("analysis/cpu5_slices.csv") as f:
        for r in csv.DictReader(f):
            if int(r["dur"]) > 0:
                cs.append((int(r["ts"]), int(r["dur"]), int(r["utid"]), r["name"]))
    cs.sort()
    cts = [c[0] for c in cs]
    names = {0: "swapper(idle)", 210: "pf-t0", 211: "pf-t1", 212: "pf-t2", 174: "pf-sched-case"}

    def overlap(a, b):
        i = max(0, bisect.bisect_right(cts, a) - 1)
        out = defaultdict(int)
        while i < len(cs) and cs[i][0] < b:
            s, d, u, n = cs[i]
            if s + d > a:
                ov = min(s + d, b) - max(s, a)
                if ov > 0:
                    out[names.get(u, "%s(%d)" % (n, u))] += ov
            i += 1
        return out

    agg_late = defaultdict(int)
    agg_all = defaultdict(int)
    for r, i in matched:
        j = i - 1
        if j < 0 or st[j][2] != "R":
            continue
        ov = overlap(st[j][0], st[i][0])
        for k, v in ov.items():
            agg_all[k] += v
        if r[4] > 5_000_000:
            for k, v in ov.items():
                agg_late[k] += v
    for label, agg in (("LATE", agg_late), ("ALL", agg_all)):
        s = sum(agg.values())
        print("\n== CPU5 occupancy during %s runnable waits (total %.1f ms, all processes) ==" % (label, s / 1e6))
        for k, v in sorted(agg.items(), key=lambda x: -x[1]):
            print("  %-18s %9.2f ms  %5.1f%%" % (k, v / 1e6, 100 * v / s))

    # deadline spacing inside one late episode: skipped deadlines are visible
    sel = [r for r in rows if 40084 <= r[0] <= 40097]
    print("\n== scheduled_ns increment inside first late episode ==")
    prev = None
    for r in sel:
        d = "%.0f" % ((r[1] - prev) / 1e6) if prev else "-"
        print("  seq %d sched=%d delta_ms=%s lat_ms=%.1f" % (r[0], r[1], d, r[4] / 1e6))
        prev = r[1]


if __name__ == "__main__":
    main()
