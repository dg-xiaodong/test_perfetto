#!/usr/bin/env python3
"""FIRST_PASS analysis driver for the pf-cpu-case trace.

Deterministic: every number in FIRST_PASS_REPORT.md comes from this script
running PerfettoSQL through trace_processor_shell v57.1 on the real .pftrace.
Usage: analyze.py <trace.pftrace> <heartbeat.csv> <outdir> <label>
"""
import csv, json, os, subprocess, sys, statistics as st

TP = "/root/.cache/perfetto-skill/trace_processor_shell"

def q(trace, sql):
    p = subprocess.run([TP, "query", trace, sql], capture_output=True, text=True)
    out = p.stdout.replace("\r", "\n").splitlines()
    rows = [l for l in out if l.strip() and not l.startswith("column ")]
    return [r for r in csv.reader(rows)]


def qd(trace, sql):
    rows = q(trace, sql)
    if not rows:
        return []
    hdr = rows[0]
    return [dict(zip(hdr, r)) for r in rows[1:] if len(r) == len(hdr)]


def episodes(sl, gap):
    out = []
    for ts, dur in sorted(sl):
        if out and ts - out[-1][1] <= gap:
            out[-1][1] = ts + dur
        else:
            out.append([ts, ts + dur])
    return out


def overlap(a, b, iv):
    return any(a < y and b > x for x, y in iv)


def main():
    trace, csv_path, outdir, label = sys.argv[1:5]
    os.makedirs(outdir, exist_ok=True)
    res = {"label": label, "trace": trace, "heartbeat_csv": csv_path}

    b = qd(trace, "SELECT start_ts,end_ts,(end_ts-start_ts)/1e9 dur_s FROM trace_bounds")[0]
    T0, T1 = int(b["start_ts"]), int(b["end_ts"])
    res["trace_bounds"] = {"start_ts": T0, "end_ts": T1, "dur_s": float(b["dur_s"])}

    # --- clock relation CLOCK_MONOTONIC -> trace ts (Perfetto BOOTTIME clock domain)
    cs = qd(trace, "SELECT ts,clock_name,clock_value FROM clock_snapshot "
                   "WHERE clock_name IN ('MONOTONIC','BOOTTIME') ORDER BY snapshot_id")
    mono = [(int(r["ts"]), int(r["clock_value"])) for r in cs if r["clock_name"] == "MONOTONIC"]
    res["monotonic_offset_ns"] = [{"trace_ts": a, "mono_ns": v, "offset_ns": v - a} for a, v in mono]

    # --- process / thread inventory
    tgt = qd(trace, "SELECT p.upid,p.pid,p.name FROM process p JOIN thread th ON th.upid=p.upid "
                    "LEFT JOIN sched_slice s ON s.utid=th.utid "
                    "WHERE p.name LIKE '%pf-cpu-case%' GROUP BY p.upid ORDER BY COUNT(s.id) DESC LIMIT 1")
    if tgt:
        upid = int(tgt[0]["upid"])
        res["target"] = {"upid": upid, "pid": int(tgt[0]["pid"]), "name": tgt[0]["name"]}
        threads = qd(trace, "SELECT th.utid,th.tid,th.name,COUNT(s.id) slices,"
                            "ROUND(SUM(CASE WHEN s.dur>0 THEN s.dur ELSE 0 END)/1e6,3) cpu_ms,"
                            "GROUP_CONCAT(DISTINCT s.cpu) cpus FROM thread th "
                            "LEFT JOIN sched_slice s ON s.utid=th.utid AND s.dur>0 "
                            "WHERE th.upid=%d GROUP BY th.utid,th.tid,th.name ORDER BY cpu_ms DESC" % upid)
        res["threads"] = threads
    else:
        upid = -1
        res["target"] = None

    # --- whole-system per-CPU busy (skill sql/08)
    res["core_busy"] = qd(trace, open("/root/.dsh/skills/perfetto-cpu-debugging/sql/08-core-busy.sql").read()
                          .replace("WITH p AS (SELECT -1 AS start_ts,-1 AS end_ts)",
                                   "WITH p AS (SELECT %d AS start_ts,%d AS end_ts)" % (T0, T1)))

    # --- data loss
    res["data_loss_nonzero"] = [r for r in qd(trace, "SELECT name,value,severity FROM stats "
                                                     "WHERE value<>0 AND severity IN ('data_loss','error') LIMIT 100")]

    # --- perf samples
    res["perf"] = {}
    try:
        ps = qd(trace, "SELECT COUNT(*) n FROM perf_sample")
        res["perf"]["total_samples"] = int(ps[0]["n"]) if ps else None
        if upid >= 0:
            ph = qd(trace, "SELECT p.pid,p.name,COUNT(*) samples FROM perf_sample ps "
                           "JOIN thread th USING(utid) JOIN process p USING(upid) "
                           "GROUP BY p.upid ORDER BY samples DESC LIMIT 6")
            res["perf"]["by_upid"] = ph
            leaves = qd(trace, "SELECT th.name thread_name, COALESCE(NULLIF(f.name,''),'[unsymbolized]') leaf_frame,"
                               "COALESCE(m.name,'[unknown mapping]') mapping, COUNT(*) samples "
                               "FROM perf_sample ps JOIN thread th USING(utid) "
                               "LEFT JOIN stack_profile_callsite cs ON cs.id=ps.callsite_id "
                               "LEFT JOIN stack_profile_frame f ON f.id=cs.frame_id "
                               "LEFT JOIN stack_profile_mapping m ON m.id=f.mapping "
                               "WHERE th.upid=%d GROUP BY th.name,leaf_frame,mapping ORDER BY samples DESC" % upid)
            res["perf"]["leaf_frames"] = leaves
            res["perf"]["callsite_depth"] = qd(trace,
                "SELECT MAX(depth) max_depth,COUNT(*) callsites FROM ("
                "SELECT cs.id, (SELECT COUNT(*) FROM stack_profile_callsite c2 WHERE c2.id=cs.id) depth "
                "FROM stack_profile_callsite cs)")
        res["perf"]["counters"] = qd(trace, "SELECT COUNT(*) cpu_clock_counters FROM cpu_counter_track WHERE name='cpu-clock'")
    except Exception as e:
        res["perf"]["error"] = str(e)

    # --- thread states (skill 02) and runnable waits (skill 03)
    if upid >= 0:
        res["thread_states"] = qd(trace,
            "SELECT th.name thread_name, st.state, COUNT(*) intervals,"
            "ROUND(SUM(MIN(st.ts+st.dur,%d)-MAX(st.ts,%d))/1e6,3) duration_ms,"
            "ROUND(MAX(st.dur)/1e6,3) max_single_ms FROM thread_state st JOIN thread th USING(utid) "
            "WHERE th.upid=%d AND st.dur>0 AND st.ts<%d AND st.ts+st.dur>%d "
            "GROUP BY th.name,st.state ORDER BY th.name,duration_ms DESC" % (T1, T0, upid, T1, T0))
        res["runnable_long"] = qd(trace,
            "SELECT th.name thread_name, st.ts-%d rel_ns, ROUND(st.dur/1e6,3) wait_ms, st.waker_utid "
            "FROM thread_state st JOIN thread th USING(utid) WHERE th.upid=%d AND st.state IN ('R','R+') "
            "AND st.dur>2000000 ORDER BY st.ts" % (T0, upid))

    # --- workload bursts + observer activity per core
    slices1 = qd(trace, "SELECT s.ts,s.dur,th.tid,th.name tn,p.name pn FROM sched_slice s "
                        "JOIN thread th USING(utid) JOIN process p USING(upid) WHERE s.cpu=1 AND s.dur>0 ORDER BY s.ts")
    slices2 = qd(trace, "SELECT s.ts,s.dur,th.tid,th.name tn,p.name pn FROM sched_slice s "
                        "JOIN thread th USING(utid) JOIN process p USING(upid) WHERE s.cpu=2 AND s.dur>0 ORDER BY s.ts")
    res["cpu1_top"] = sorted(
        [{"tid": r["tid"], "name": r["tn"], "proc": r["pn"], "ms": round(int(r["dur"]) / 1e6, 1)}
         for r in slices1], key=lambda x: -x["ms"])[:12]
    tid_p = tid_q = tid_svc = None
    if upid >= 0:
        for t in res["threads"]:
            if t["name"] == "pf-worker-p": tid_p = t["tid"]
            if t["name"] == "pf-worker-q": tid_q = t["tid"]
            if t["name"] == "pf-svc-tick": tid_svc = t["tid"]

    P = episodes([(int(r["ts"]), int(r["dur"])) for r in slices1 if r["tid"] == tid_p], 3_000_000)
    Q = episodes([(int(r["ts"]), int(r["dur"])) for r in slices2 if r["tid"] == tid_q], 5_000_000)
    TB = episodes([(int(r["ts"]), int(r["dur"])) for r in slices1 if "tracebox" in (r["pn"] or "")], 2_000_000)
    OB2 = episodes([(int(r["ts"]), int(r["dur"])) for r in slices2 if "tracebox" in (r["pn"] or "")], 2_000_000)
    res["p_episodes"] = [{"start_s": round((a - T0) / 1e9, 3), "end_s": round((b - T0) / 1e9, 3),
                          "dur_ms": round((b - a) / 1e6, 1)} for a, b in P if b - a >= 20_000_000]
    res["q_episodes"] = [{"start_s": round((a - T0) / 1e9, 3), "end_s": round((b - T0) / 1e9, 3),
                          "dur_ms": round((b - a) / 1e6, 1)} for a, b in Q if b - a >= 20_000_000]
    res["observer_cpu1_episodes"] = [{"start_s": round((a - T0) / 1e9, 3), "end_s": round((b - T0) / 1e9, 3),
                                      "dur_ms": round((b - a) / 1e6, 1)} for a, b in TB if b - a >= 3_000_000]
    res["observer_cpu2_episodes"] = [{"start_s": round((a - T0) / 1e9, 3), "end_s": round((b - T0) / 1e9, 3),
                                      "dur_ms": round((b - a) / 1e6, 1)} for a, b in OB2 if b - a >= 3_000_000]

    # --- heartbeat latency vs windows
    rows = list(csv.DictReader(open(csv_path)))
    mono_off = mono[0][1] - mono[0][0] if mono else 0
    hb = [{"seq": int(r["seq"]), "mono": int(r["mono_ns"]), "lat": int(r["latency_ns"])} for r in rows]
    res["heartbeat_file"] = {"rows": len(hb),
                             "span_s": round((hb[-1]["mono"] - hb[0]["mono"]) / 1e9, 3) if hb else 0}
    inw = [h for h in hb if T0 <= h["mono"] + mono_off <= T1]
    cls = {"p_only": [], "q_only": [], "observer_cpu1": [], "p_and_observer": [], "none": []}
    for h in inw:
        a, b2 = h["mono"] + mono_off - h["lat"], h["mono"] + mono_off
        ip, iq = overlap(a, b2, P), overlap(a, b2, Q)
        it = overlap(a, b2, TB) or overlap(a, b2, OB2)
        k = "p_and_observer" if (ip and it) else "p_only" if ip else "observer_cpu1" if it else "q_only" if iq else "none"
        cls[k].append(h["lat"] / 1e6)

    def s(v):
        if not v:
            return {"n": 0}
        v2 = sorted(v)
        return {"n": len(v), "mean_ms": round(st.mean(v), 3), "p50_ms": round(st.median(v), 3),
                "p90_ms": round(v2[min(len(v2) - 1, int(.9 * len(v2)))], 3), "max_ms": round(max(v), 3)}

    res["heartbeat_in_window"] = len(inw)
    res["latency_overall_window"] = s([h["lat"] / 1e6 for h in inw])
    res["latency_by_class"] = {k: s(v) for k, v in cls.items()}
    allv = sorted(h["lat"] / 1e6 for h in hb)
    res["latency_overall_file"] = {"n": len(allv), "min_ms": round(min(allv), 3),
                                   "p50_ms": round(st.median(allv), 3),
                                   "p90_ms": round(allv[int(.9 * len(allv))], 3),
                                   "p99_ms": round(allv[int(.99 * len(allv))], 3),
                                   "max_ms": round(max(allv), 3), "mean_ms": round(st.mean(allv), 3)}
    res["slowest_heartbeats"] = sorted(
        [{"seq": h["seq"], "rel_s": round((h["mono"] + mono_off - T0) / 1e9, 3), "lat_ms": round(h["lat"] / 1e6, 3)}
         for h in inw], key=lambda x: -x["lat_ms"])[:12]

    # --- cpu frequency behaviour on the two workload cores
    res["freq"] = qd(trace, "SELECT ct.cpu, COUNT(*) pts, MIN(c.value)/1000.0 min_mhz, MAX(c.value)/1000.0 max_mhz "
                            "FROM counter c JOIN cpu_counter_track ct ON ct.id=c.track_id "
                            "WHERE ct.name='cpufreq' GROUP BY ct.cpu")

    json.dump(res, open(os.path.join(outdir, "analysis.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in res.items() if k not in
                      ("threads", "core_busy", "p_episodes", "q_episodes")}, indent=1)[:9000])


if __name__ == "__main__":
    main()
