#!/usr/bin/env python3
"""v58.2 TP 对 A/B trace 执行 accept.sql + heap_live_timeline.sql，输出结果与 CSV。"""
import csv, io, os, subprocess

TP = "/root/code_1.0.20/tmp/perfetto582/linux-amd64/trace_processor_shell"
BASE = "/root/code_1.0.20/tmp/heapprofd-minimal"
V = os.path.dirname(os.path.abspath(__file__))

def split_sql(text):
    out, buf, inq = [], [], False
    for ch in text:
        if ch == "'":
            inq = not inq
        if ch == ";" and not inq:
            p = "".join(buf).strip()
            if p:
                out.append(p)
            buf = []
        else:
            buf.append(ch)
    p = "".join(buf).strip()
    if p:
        out.append(p)
    return out

def stmts(path):
    lines = [l for l in open(path, encoding="utf-8").read().splitlines()
             if not l.lstrip().startswith("--")]
    return split_sql("\n".join(lines))

def run(trace, sql):
    p = subprocess.run([TP, "query", trace, sql], capture_output=True, text=True)
    return p.stdout, p.returncode

def rows(out):
    if not out.strip():
        return []
    r = list(csv.reader(io.StringIO(out)))
    return r[1:] if r else []

acc = stmts(os.path.join(BASE, "accept.sql"))
tl = stmts(os.path.join(BASE, "heap_live_timeline.sql"))[0]

def q(trace, sql):
    return rows(run(trace, sql)[0])

summary_path = os.path.join(V, "SUMMARY.txt")
with open(summary_path, "w", encoding="utf-8") as sf:
    for tag, fname in (("A", "x5_heapprofd_A_no_tick.pftrace"),
                       ("B", "x5_heapprofd_B_tick_200ms.pftrace")):
        trace = os.path.join(V, fname)
        sections = ["S1 目标候选", "S2 LEVEL1", "S3 LEVEL2", "S4 状态",
                    "S5 调用栈 self/cum", "S6 符号/映射", "S7 严重 stats", "S8 数值明细"]
        with open(os.path.join(V, f"{tag}_accept_results.txt"), "w", encoding="utf-8") as f:
            f.write(f"# accept.sql（trace={fname}, TP=Perfetto v58.2-add693d8b）\n")
            for name, s in zip(sections, acc):
                out, rc = run(trace, s)
                f.write(f"\n===== {name} (rc={rc}) =====\n{out}\n")
        out, _ = run(trace, tl)
        with open(os.path.join(V, f"{tag}_heap_live.csv"), "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f); w.writerow(["ts", "value_mib", "series"])
            for r in rows(out):
                if len(r) >= 3: w.writerow(r[:3])
        # 控制台/摘要
        L = [f"########## {tag} ({fname}) ##########"]
        bounds = q(trace, "select start_ts,end_ts,(end_ts-start_ts)/1e9 dur_s from trace_bounds")
        targets = q(trace, "select upid,pid,name from process where name glob '*memprobe*'")
        dumps = q(trace, "select count(*) dumps from heap_profile")
        axis = q(trace, "select h.ts_end, round(h.dur/1e6,1) dur_ms, (select count(*) from heap_profile_allocation a where a.ts=h.ts_end) rows from heap_profile h order by h.ts_end")
        totals = q(trace, "select count(*) rows, round(sum(case when size>0 then size else 0 end)/1048576.0,2) alloc_mib, round(sum(case when size<0 then -size else 0 end)/1048576.0,2) free_mib from heap_profile_allocation")
        live = q(trace, "with d as (select ts,sum(size) delta from heap_profile_allocation group by ts) select ts, round(sum(delta) over (order by ts rows unbounded preceding)/1048576.0,2) live_mib from d order by ts")
        frames = q(trace, "select count(*) frames, count(f.name) named, count(distinct m.build_id) bids from stack_profile_frame f left join stack_profile_mapping m on f.mapping=m.id")
        probe = q(trace, "select f.name, count(*) n from stack_profile_frame f where f.name glob '*probe_*' group by 1")
        stats = q(trace, "select name,value from stats where value>0 and name glob 'heapprofd*' order by name")
        tops = q(trace, "select f.name, round(sum(a.size)/1048576.0,2) cum_mib from heap_profile_allocation a join stack_profile_callsite c on a.callsite_id=c.id join stack_profile_frame f on c.frame_id=f.id where a.size>0 group by 1 order by 2 desc limit 8")
        st = q(trace, [x for x in acc if 'AS status,' in x][0])
        L.append("trace_bounds: " + repr(bounds))
        L.append("targets: " + repr(targets))
        L.append("dumps: " + repr(dumps))
        L.append("dump_axis(ts_end,dur_ms,rows): " + repr(axis))
        L.append("totals(rows,alloc_mib,free_mib): " + repr(totals))
        L.append("live_curve(ts,live_mib): " + repr(live))
        L.append("frames(frames,named,bids): " + repr(frames))
        L.append("probe_frames: " + repr(probe))
        L.append("stats: " + repr(stats))
        L.append("top_alloc_frames: " + repr(tops))
        L.append("S4: " + repr(st))
        txt = "\n".join(L) + "\n"
        print(txt)
        sf.write(txt + "\n")
print("done:", summary_path)
