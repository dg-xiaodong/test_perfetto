#!/usr/bin/env python3
"""Generate sql_out/ artifacts for v4_test from the real traces (trace_processor_shell)."""
import csv, json, re, subprocess, sys, pathlib

TP = '/root/.cache/perfetto-skill/trace_processor_shell'
SRC = pathlib.Path('/root/code_1.0.20/tmp')
OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'v4_test/sql_out')
OUT.mkdir(parents=True, exist_ok=True)
RUNS = ['run0', 'run1', 'run2', 'run3', 'run4', 'run5']
MODE = {'run0': 'idle baseline', 'run1': 'script on /data tmpfs', 'run2': 'control: same bytes on /data ext4',
        'run3': '20 fast write/rm cycles (tmpfs)', 'run4': 'SIGKILL -> orphan tmpfs file',
        'run5': '10 write/hold/rm cycles (tmpfs)'}
MiB = 1048576.0

def q(run, sql):
    out = subprocess.run([TP, 'query', str(SRC / f'{run}.pftrace'), sql], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f'{run}: {out.stderr[-800:]}')
    lines = [l for l in out.stdout.splitlines()
             if l and not l.startswith(('[', 'column ', 'query:', 'Loading', 'Trace '))]
    if not lines:
        return []
    hdr = json.loads('[' + lines[0] + ']')
    return [dict(zip(hdr, json.loads('[' + l + ']'))) for l in lines[1:]]

def anchor(run):
    log = (SRC / f'{run}.run.log').read_text()
    m = re.search(r'workload_start_uptime=([0-9.]+)', log)
    return float(m.group(1)) if m else None

(OUT / 'trace_processor_version.txt').write_text(
    subprocess.run([TP, '--version'], capture_output=True, text=True).stdout)

quality = []
summary = []
rss_counts = []
for run in RUNS:
    b = q(run, 'select * from trace_bounds')[0]
    span = (b['end_ts'] - b['start_ts']) / 1e9
    counts = {r['name']: r['n'] for r in q(run, "select ct.name, count(*) n from counter c join counter_track ct on ct.id=c.track_id where ct.name in ('MemAvailable','Shmem','Cached') group by ct.name")}
    bad = q(run, "select name, severity, value from stats where value<>0 and severity<>'info'")
    n_rss = q(run, "select count(*) n from ftrace_event where name='rss_stat'")[0]['n']
    quality.append(f'{run}: bounds=[{b["start_ts"]},{b["end_ts"]}] span={span:.1f}s '
                   f'counter_samples={counts} rss_stat_events={n_rss} non_info_stats={len(bad)}'
                   + ('' if not bad else f' -> {bad}'))
    rss_counts.append(f'{run}\t{n_rss}')
    rows = q(run, "select ct.name, c.ts, c.value from counter c join counter_track ct on ct.id=c.track_id "
                   "where ct.name in ('MemAvailable','MemFree','Shmem','Cached','AnonPages','Slab','PageTables') order by c.ts")
    per_ts = {}
    for r in rows:
        per_ts.setdefault(r['ts'], {})[r['name']] = r['value']
    a = anchor(run)
    t0 = min(per_ts)
    with open(OUT / f'meminfo_{run}.csv', 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['t_rel_workload_s', 'MemAvailable_MiB', 'MemFree_MiB', 'Shmem_MiB', 'Cached_MiB', 'AnonPages_MiB', 'Slab_MiB', 'PageTables_MiB'])
        for ts in sorted(per_ts):
            d = per_ts[ts]
            rel = round((ts - (a * 1e9 if a else t0)) / 1e9, 3)
            w.writerow([rel] + [round(d.get(k, 0) / MiB, 3) for k in ('MemAvailable', 'MemFree', 'Shmem', 'Cached', 'AnonPages', 'Slab', 'PageTables')])
    ser = [(ts - (a * 1e9 if a else t0)) / 1e9 for ts in sorted(per_ts)]
    def at(t, key, tol=0.45):
        best = None
        for ts in sorted(per_ts):
            rel = (ts - (a * 1e9 if a else t0)) / 1e9
            if abs(rel - t) < tol and (best is None or abs(rel - t) < abs(best - t)):
                best = rel
        return per_ts[(a * 1e9 if a else t0) + best * 1e9].get(key, 0) / MiB if best is not None else None
    vals = sorted(per_ts.items())
    first = vals[0][1].get('MemAvailable', 0) / MiB
    last = vals[-1][1].get('MemAvailable', 0) / MiB
    min_avail = min(d.get('MemAvailable', 0) for d in per_ts.values()) / MiB
    peak_shmem = max(d.get('Shmem', 0) for d in per_ts.values()) / MiB
    end_shmem = vals[-1][1].get('Shmem', 0) / MiB
    summary.append({'run': run, 'mode': MODE[run], 'span_s': round(span, 1),
                    'meminfo_samples': len(per_ts),
                    'first_avail_MiB': round(first, 1),
                    'min_avail_MiB': round(min_avail, 1),
                    'max_shmem_MiB': round(peak_shmem, 1),
                    'end_avail_MiB': round(last, 1),
                    'end_shmem_MiB': round(end_shmem, 2)})
(OUT / 'quality.txt').write_text('\n'.join(quality) + '\n')
(OUT / 'rss_stat_counts.txt').write_text('run\trss_stat_events\n' + '\n'.join(rss_counts) + '\n')
with open(OUT / 'summary.csv', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=list(summary[0].keys()))
    w.writeheader(); w.writerows(summary)

# process-side anon RSS (run1)
rows = q('run1', "select p.name, MAX(c.value)/1048576.0 mx, COUNT(*) n from counter c "
                 "join process_counter_track pct on pct.id=c.track_id join process p using(upid) "
                 "where pct.name='mem.rss.anon' group by pct.upid order by mx desc limit 12")
(OUT / 'process_anon_run1.txt').write_text(
    'run1: per-process max mem.rss.anon (MiB), from process_stats @250ms\n'
    + ''.join(f"{r['name'] or '(kernel thread)'}\t{r['mx']:.3f}\t({r['n']} samples)\n" for r in rows))

# run5 per-cycle table
log = (SRC / 'run5.run.log').read_text()
a5 = float(re.search(r'workload_start_uptime=([0-9.]+)', log).group(1))
per = {}
for row in q('run5', "select ct.name, c.ts, c.value from counter c join counter_track ct on ct.id=c.track_id where ct.name in ('MemAvailable','Shmem') order by c.ts"):
    per.setdefault(row['ts'], {})[row['name']] = row['value']
def r5at(t, key):
    c = [(abs((ts - a5 * 1e9) / 1e9 - t), d.get(key)) for ts, d in per.items() if abs((ts - a5 * 1e9) / 1e9 - t) < 0.4]
    return min(c)[1] / MiB if c else ''
with open(OUT / 'cycles_run5.csv', 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['cycle', 'pre_avail_MiB', 'hold_avail_MiB', 'hold_shmem_MiB', 'post_rm_avail_MiB', 'post_rm_shmem_MiB', 'file_bytes'])
    for m in re.finditer(r'cycle (\d+) written uptime=([0-9.]+) bytes=(\d+)', log):
        n, u, b = int(m.group(1)), float(m.group(2)), int(m.group(3))
        rm = float(re.search(rf'cycle {n} removed uptime=([0-9.]+)', log).group(1))
        t_w, t_rm = u - a5, rm - a5
        hold_sh = max([d.get('Shmem', 0) for ts, d in per.items() if t_w + 0.5 <= (ts - a5 * 1e9) / 1e9 <= t_w + 2.9] or [0]) / MiB
        w.writerow([n, round(r5at(t_w - 0.6, 'MemAvailable'), 1), round(r5at(t_w + 2.5, 'MemAvailable'), 1),
                    round(hold_sh, 1), round(r5at(t_rm + 0.5, 'MemAvailable'), 1), round(r5at(t_rm + 0.5, 'Shmem'), 2), b])
# trace sha256 manifest
import hashlib
sha = []
for run in RUNS:
    h = hashlib.sha256((SRC / f'{run}.pftrace').read_bytes()).hexdigest()
    sha.append(f'{h}  traces/{run}.pftrace')
(OUT / 'trace_sha256.txt').write_text('\n'.join(sha) + '\n')
print('wrote', len(list(OUT.iterdir())), 'files to', OUT)
