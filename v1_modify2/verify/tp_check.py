#!/usr/bin/env python3
"""真实 TP 回归：候选版 sql/00 [CANDIDATES] + sql/03 + sql/10，跑 X5 A/B 两条真实 trace。

每条查询都检查：returncode、结果结构（列数/行数）、关键能力值（dump 数、零宽窗口、
alloc/free 字节、live 序列）。任何一项不符即 SUMMARY: FAIL。

路径均可参数化：
  --tp          trace_processor_shell（或 $PERFETTO_TP / PATH）
  --skill-dir   候选 Skill（默认 <本目录>/candidate-v1.0.1）
  --traces-dir  两份真实 trace（默认 <仓库根>/x5_heapprofd_traces）

不改 trace、不放宽判据。故障注入测试见 verify/test_tp_check_faults.py。
"""
import argparse, csv, io, os, pathlib, shutil, subprocess, sys

EXPECT = {
    'A': {'dumps': 1, 'alloc_bytes': 29360128, 'live': [0.0]},
    'B': {'dumps': 6, 'alloc_bytes': 29605888, 'live': [8.0, 8.0, 8.0, 0.0, 0.0, 0.0]},
}
CAND_COLS = 9


def split_sql(text):
    lines = [l for l in text.splitlines() if not l.lstrip().startswith('--')]
    out, buf, inq = [], [], False
    for ch in '\n'.join(lines):
        if ch == "'":
            inq = not inq
        if ch == ';' and not inq:
            p = ''.join(buf).strip()
            if p:
                out.append(p)
            buf = []
        else:
            buf.append(ch)
    p = ''.join(buf).strip()
    if p:
        out.append(p)
    return out


def run(tp, trace, sql):
    p = subprocess.run([str(tp), 'query', str(trace), sql], capture_output=True, text=True)
    rows = list(csv.reader(io.StringIO(p.stdout)))[1:] if p.stdout.strip() else []
    return rows, p.returncode, p.stderr


def _query(runner, tp, trace, sql, what):
    """执行并校验 returncode；返回 rows 或 None（失败已计数由调用方处理）。"""
    rows, rc, err = runner(tp, trace, sql)
    if rc != 0:
        last = (err.strip().splitlines() or [''])[-1]
        print(f'  FAIL {what}: rc={rc} {last}')
        return None
    return rows


def _num(row, idx):
    """把第 idx 列解析成 int；失败返回 None（name 列是字符串，不能整体转换）。"""
    try:
        return int(row[idx])
    except (IndexError, TypeError, ValueError):
        return None


def evaluate(tp, skill_dir, traces_dir, runner=run):
    """返回失败计数（0 = PASS）。runner 可注入，用于故障测试。"""
    sk, traces = pathlib.Path(skill_dir), pathlib.Path(traces_dir)
    fails = 0
    pairs = {'A': traces / 'x5_heapprofd_A_no_tick.pftrace',
             'B': traces / 'x5_heapprofd_B_tick_200ms.pftrace'}

    for tag, trace in pairs.items():
        exp = EXPECT[tag]
        print(f'########## {tag}: {trace.name}')

        # ---- 候选查询 ----
        inv = (sk / 'sql/00-inventory.sql').read_text(encoding='utf-8').split('[CANDIDATES]', 1)[1]
        inv_sql = '\n'.join(l for l in inv.splitlines()[1:] if not l.lstrip().startswith('--'))
        cand = _query(runner, tp, trace, inv_sql, 'candidates')
        if cand is None:
            fails += 1
            continue
        print(' candidates:', cand)
        bad_cols = [r for r in cand if len(r) != CAND_COLS]
        if bad_cols:
            print(f'  FAIL candidates: expected {CAND_COLS} columns, got {[len(r) for r in bad_cols]}')
            fails += 1
            continue
        data = [r for r in cand if _num(r, 7) == 1]
        if len(data) != 1:
            print(f'  FAIL candidates: expected exactly one data_bearing=1, got {len(data)}')
            fails += 1
            continue
        helper = [r for r in cand if _num(r, 7) == 0]
        if not helper or any(_num(r, 3) != 0 or _num(r, 5) != 0 for r in helper):
            print('  FAIL candidates: same-name helper should have 0 alloc_rows/0 activity_dumps')
            fails += 1
        upid = _num(data[0], 0)

        # ---- sql/10：四项能力 ----
        stmts = split_sql((sk / 'sql/10-native-dump-capability.sql').read_text(encoding='utf-8'))
        if len(stmts) != 4:
            print(f'  FAIL sql10: expected 4 statements, got {len(stmts)}')
            fails += 1
            continue
        fixed = [s.replace('-1 AS target_upid', f'{upid} AS target_upid') for s in stmts]
        tables = _query(runner, tp, trace, fixed[0], 'sql10.tables')
        axis = _query(runner, tp, trace, fixed[1], 'sql10.axis')
        summary = _query(runner, tp, trace, fixed[2], 'sql10.summary')
        fallback = _query(runner, tp, trace, fixed[3], 'sql10.fallback')

        if tables is not None:
            names = {r[0] for r in tables if r}
            need = {'heap_profile', 'heap_profile_allocation'}
            if not need <= names:
                print(f'  FAIL sql10.tables: missing {sorted(need - names)}')
                fails += 1
        else:
            fails += 1

        if axis is not None:
            if len(axis) != exp['dumps']:
                print(f"  FAIL sql10.axis: dumps={len(axis)} expected {exp['dumps']}")
                fails += 1
            for r in axis:
                if len(r) != 6:
                    print(f'  FAIL sql10.axis: expected 6 columns, got {len(r)}'); fails += 1; break
                if _num(r, 2) != 0:
                    print(f'  FAIL sql10.axis: v57.1 trace should have dur=0, got {r[2]}'); fails += 1; break
                if _num(r, 5) is None or _num(r, 5) < 1:
                    print(f'  FAIL sql10.axis: alloc_rows should be >=1, got {r[5]}'); fails += 1; break
        else:
            fails += 1

        if summary is not None:
            if len(summary) != 1 or len(summary[0]) != 5:
                print(f'  FAIL sql10.summary: expected 1x5 row, got {summary[:2]}'); fails += 1
            else:
                d, distinct, zero, first, last = (_num(summary[0], i) for i in range(5))
                if d != exp['dumps'] or distinct != exp['dumps'] or zero != exp['dumps']:
                    print(f'  FAIL sql10.summary: dumps/distinct/zero={d}/{distinct}/{zero} '
                          f"expected {exp['dumps']}/{exp['dumps']}/{exp['dumps']}")
                    fails += 1
                if None in (first, last) or first > last:
                    print(f'  FAIL sql10.summary: bad ts range {first}..{last}'); fails += 1
        else:
            fails += 1

        if fallback is not None:
            if len(fallback) != 1 or len(fallback[0]) != 5:
                print(f'  FAIL sql10.fallback: expected 1x5 row, got {fallback[:2]}'); fails += 1
            else:
                act, first, last, alloc, free = (_num(fallback[0], i) for i in range(5))
                if act != exp['dumps']:
                    print(f"  FAIL sql10.fallback: activity_dumps={act} expected {exp['dumps']}"); fails += 1
                if alloc != exp['alloc_bytes'] or free != exp['alloc_bytes']:
                    print(f'  FAIL sql10.fallback: alloc/free={alloc}/{free} '
                          f"expected {exp['alloc_bytes']}"); fails += 1
        else:
            fails += 1

        # ---- sql/03 live ----
        live_sql = split_sql((sk / 'sql/03-native-live.sql').read_text(encoding='utf-8'))[0]
        live = _query(runner, tp, trace, live_sql.replace('-1 AS target_upid', f'{upid} AS target_upid'), 'live')
        if live is None:
            fails += 1
            continue
        if len(live) != exp['dumps']:
            print(f"  FAIL live: rows={len(live)} expected {exp['dumps']}"); fails += 1
        try:
            vals = [round(float(r[1]), 2) for r in live]
        except (TypeError, ValueError, IndexError):
            print(f'  FAIL live: unparsable rows {live[:2]}'); fails += 1
            vals = None
        if vals is not None:
            if any(v < 0 for v in vals):
                print(f'  FAIL live: negative live estimate {vals}'); fails += 1
            if vals != exp['live']:
                print(f"  FAIL live: {vals} expected {exp['live']}"); fails += 1
            else:
                print('  live values (MiB):', vals, '-> PASS')

    return fails


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
    missing = [str(p) for p in (traces / 'x5_heapprofd_A_no_tick.pftrace',
                                traces / 'x5_heapprofd_B_tick_200ms.pftrace') if not p.is_file()]
    if missing:
        print('ERROR: missing traces: ' + ', '.join(missing), file=sys.stderr)
        return 2
    print(f'tp={tp}\nskill={sk}\ntraces={traces}')

    fails = evaluate(tp, sk, traces)
    print('SUMMARY:', 'PASS' if fails == 0 else f'{fails} failure(s)')
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
