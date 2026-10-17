#!/usr/bin/env python3
"""真实 TP 回归：候选版 sql/00 [CANDIDATES] + sql/03 + sql/10，跑 X5 A/B 两条真实 trace。

路径均可参数化，默认值按本仓库布局推导：
  skill:  <repo>/v1_modify/candidate-v1.0.1
  traces: <repo>/x5_heapprofd_traces
  tp:     --tp，或 $PERFETTO_TP，或 PATH 里的 trace_processor_shell
不改 trace、不放宽判据；只断言 SQL 在真实 TP v58.2 上的行为。
"""
import argparse, csv, io, os, pathlib, shutil, subprocess, sys

def split_sql(text):
    lines = [l for l in text.splitlines() if not l.lstrip().startswith('--')]
    out, buf, inq = [], [], False
    for ch in '\n'.join(lines):
        if ch == "'": inq = not inq
        if ch == ';' and not inq:
            p = ''.join(buf).strip()
            if p: out.append(p)
            buf = []
        else: buf.append(ch)
    p = ''.join(buf).strip()
    if p: out.append(p)
    return out

def run(tp, trace, sql):
    p = subprocess.run([str(tp), 'query', str(trace), sql], capture_output=True, text=True)
    rows = list(csv.reader(io.StringIO(p.stdout)))[1:] if p.stdout.strip() else []
    return rows, p.returncode, p.stderr

def main() -> int:
    here = pathlib.Path(__file__).resolve()
    ap = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tp', help='path to trace_processor_shell (or set $PERFETTO_TP)')
    ap.add_argument('--skill-dir', type=pathlib.Path,
                    default=here.parent.parent / 'candidate-v1.0.1')
    ap.add_argument('--traces-dir', type=pathlib.Path,
                    default=here.parent.parent.parent / 'x5_heapprofd_traces')
    a = ap.parse_args()

    tp = a.tp or os.environ.get('PERFETTO_TP') or shutil.which('trace_processor_shell')
    if not tp:
        print('ERROR: pass --tp / set PERFETTO_TP / put trace_processor_shell on PATH', file=sys.stderr)
        return 2
    sk, traces = a.skill_dir.resolve(), a.traces_dir.resolve()
    pairs = {'A': traces/'x5_heapprofd_A_no_tick.pftrace',
             'B': traces/'x5_heapprofd_B_tick_200ms.pftrace'}
    missing = [str(p) for p in pairs.values() if not p.is_file()]
    if missing:
        print('ERROR: missing traces: ' + ', '.join(missing), file=sys.stderr); return 2
    print(f'tp={tp}\nskill={sk}\ntraces={traces}')

    fails = 0
    for tag, trace in pairs.items():
        print(f'########## {tag}: {trace.name}')
        inv = (sk/'sql/00-inventory.sql').read_text(encoding='utf-8').split('[CANDIDATES]', 1)[1]
        inv_lines = inv.splitlines()[1:]
        cand, rc, err = run(tp, trace, '\n'.join(l for l in inv_lines if not l.lstrip().startswith('--')))
        print(' candidates:', cand)
        data = [r for r in cand if r and r[7] == '1']
        if len(data) != 1:
            print(f'  FAIL: expected exactly one data-bearing candidate, got {data}'); fails += 1; continue
        upid = data[0][0]
        for stmt in split_sql((sk/'sql/10-native-dump-capability.sql').read_text(encoding='utf-8')):
            rows, rc, err = run(tp, trace, stmt.replace('-1 AS target_upid', f'{upid} AS target_upid'))
            print(f'  sql10 -> {rows[:2]} rc={rc}')
            if rc != 0: fails += 1; print('   ERR:', (err.strip().splitlines() or [''])[-1:])
        live = split_sql((sk/'sql/03-native-live.sql').read_text(encoding='utf-8'))[0]
        rows, rc, err = run(tp, trace, live.replace('-1 AS target_upid', f'{upid} AS target_upid'))
        vals = [round(float(r[1]), 2) for r in rows]
        ok = ([0.0] >= vals) if tag == 'A' else (vals == [8.0, 8.0, 8.0, 0.0, 0.0, 0.0])
        print('  live values (MiB):', vals, '->', 'PASS' if ok else 'FAIL')
        if not ok: fails += 1
    print('SUMMARY:', 'PASS' if fails == 0 else f'{fails} failure(s)')
    return 0 if fails == 0 else 1

if __name__ == '__main__':
    raise SystemExit(main())
