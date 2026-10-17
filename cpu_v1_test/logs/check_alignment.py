#!/usr/bin/env python3
"""Recompute the fixture-marker vs trace-slice alignment from ARCHIVED files only.

Inputs (both committed in this directory, nothing is regenerated):
  logs/fixture.log             - the fixture's own CLOCK_MONOTONIC tick_start stamps
  sql_out/04-spike-episodes.txt - spike episodes read from the archived cpu.pftrace

Output: for each episode, the delta (trace_episode_start - fixture_tick_start) and
the episode spacing. A small negative delta (tens of microseconds) is expected:
the thread is scheduled onto the CPU first, then executes printf and flushes it.
"""
import pathlib, re, sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent

def fixture_ticks():
    ticks = []
    for line in (ROOT / 'logs/fixture.log').read_text().splitlines():
        m = re.search(r'EVENT tick_start idx=(\d+) mono_ns=(\d+)', line)
        if m:
            ticks.append((int(m.group(1)), int(m.group(2))))
    return ticks

def episodes():
    eps = []
    for line in (ROOT / 'sql_out/04-spike-episodes.txt').read_text().splitlines():
        if not line.startswith(('0', '1', '2', '3', '4', '5', '6', '7', '8', '9')):
            continue
        f = line.split(',')
        if len(f) < 4:
            continue
        eps.append((int(f[1]), float(f[3]), float(f[4])))  # start_ts, span_ms, cpu_ms
    return eps

def main():
    ticks, eps = fixture_ticks(), episodes()
    if not ticks or not eps:
        print('FAIL: archived inputs missing or empty', file=sys.stderr)
        return 1
    print(f'fixture ticks archived : {len(ticks)} (idx {ticks[0][0]}..{ticks[-1][0]})')
    print(f'trace episodes archived: {len(eps)}')
    print()
    print(f"{'ep':>2} {'fixture_tick_start_ns':>22} {'trace_episode_start_ns':>23} {'delta_us':>9} {'span_ms':>8} {'cpu_ms':>8}")
    deltas = []
    for i, (start, span, cpu) in enumerate(eps):
        idx, tick_ns = ticks[i]
        d_us = (start - tick_ns) / 1000.0
        deltas.append(d_us)
        print(f'{i:>2} {tick_ns:>22} {start:>23} {d_us:>9.1f} {span:>8.1f} {cpu:>8.1f}')
    gaps = [(b[0] - a[0]) / 1e6 for a, b in zip(eps, eps[1:])]
    print()
    print('episode gaps (ms) :', ', '.join(f'{g:.1f}' for g in gaps))
    print(f'delta range (us)  : {min(deltas):.1f} .. {max(deltas):.1f}')
    print('interpretation    : negative delta = slice started before the fixture printed its marker;')
    print('                    magnitude is the wake->printf->flush cost, not clock skew.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
