#!/usr/bin/env python3
"""Summarise Perfetto meminfo/process data for the X5 /data tmpfs test runs."""
import json, subprocess, sys, statistics, pathlib

TP = '/root/.cache/perfetto-skill/trace_processor_shell'
COLS = ['MemFree','MemAvailable','Cached','Shmem','Dirty','Writeback','AnonPages',
        'Slab','SlabReclaimable','SlabUnreclaimable','KernelStack','PageTables','Mapped','CmaFree']

def q(trace, sql):
    out = subprocess.run([TP, 'query', trace, sql], capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr[-2000:], file=sys.stderr); raise SystemExit(1)
    lines = [l for l in out.stdout.splitlines() if l.startswith('"')]
    if not lines: return []
    hdr = json.loads('[' + lines[0] + ']')
    return [dict(zip(hdr, json.loads('[' + l + ']'))) for l in lines[1:]]

def meminfo_series(trace):
    rows = q(trace, "select ct.name, c.ts, c.value from counter c join counter_track ct on ct.id=c.track_id "
                    "where ct.name in ('MemFree','MemAvailable','Cached','Shmem','Dirty','Writeback','AnonPages',"
                    "'Slab','SlabReclaimable','SlabUnreclaimable','KernelStack','PageTables','Mapped','CmaFree') order by c.ts")
    byts = {}
    for r in rows:
        byts.setdefault(r['ts'], {})[r['name']] = r['value']
    return [(ts, d) for ts, d in sorted(byts.items())]

def summarise(name, trace, logfile):
    s = meminfo_series(trace)
    if not s: return None
    MiB = 1048576.0
    t0 = s[0][0]
    u = lambda ts: (ts - t0)/1e9
    def win(lo, hi):
        sel = [d for ts,d in s if lo <= u(ts) < hi]
        return {k: statistics.mean([d.get(k,0) for d in sel])/MiB for k in COLS} if sel else {}
    log = pathlib.Path(logfile).read_text() if pathlib.Path(logfile).exists() else ''
    out = {'name': name, 'trace': trace, 'n_samples': len(s), 'span_s': round(u(s[-1][0]),1)}
    out['series'] = [dict(t=round(u(ts),2), **{k: round(d.get(k,0)/MiB,3) for k in COLS}) for ts,d in s]
    anchor = None
    for line in log.splitlines():
        if line.startswith('workload_start_uptime='):
            anchor = float(line.split('=')[1])
    if anchor:
        a = (anchor*1e9 - t0)/1e9
        out['anchor_s'] = round(a,2)
        out['pre'] = win(0, a)
        out['hold'] = win(a+12, a+30)
        out['recovery'] = win(out['span_s']-15, out['span_s']+1)
        out['peak_shmem'] = max(d.get('Shmem',0) for ts,d in s)/MiB
        out['min_avail'] = min(d.get('MemAvailable',0) for ts,d in s)/MiB
        out['min_avail_at'] = round(min(((d.get('MemAvailable',0), u(ts)) for ts,d in s))[1],2)
        out['max_anon'] = max(d.get('AnonPages',0) for ts,d in s)/MiB
    return out

if __name__ == '__main__':
    res = []
    for name in sys.argv[1:]:
        r = summarise(name, f'{name}.pftrace', f'{name}.run.log')
        if r: res.append(r)
        print('#'*70); print(name)
        if not r: print('NO DATA'); continue
        print(f"samples={r['n_samples']} span={r['span_s']}s anchor={r.get('anchor_s')}")
        for k in ('pre','hold','recovery'):
            d = r.get(k)
            if d: print(f"  {k:9s} " + ' '.join(f"{c}={d.get(c,0):.1f}" for c in ('MemAvailable','MemFree','Shmem','Cached','AnonPages','Slab')))
        if 'min_avail' in r:
            print(f"  min_avail={r['min_avail']:.1f} at t={r['min_avail_at']}s  peak_shmem={r['peak_shmem']:.1f}  max_anon={r['max_anon']:.1f}")
    pathlib.Path('analysis.json').write_text(json.dumps(res, indent=1))
