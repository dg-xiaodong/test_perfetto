#!/usr/bin/env python3
"""Generate small, version-conscious Linux Perfetto CPU TraceConfig textproto.

Host-only stdlib. Runtime event presence and collector schema are separate checks.
"""
from __future__ import annotations
import argparse
from pathlib import Path
import sys


def available_events(path):
    if not path:
        return None
    text = Path(path).read_text(encoding='utf-8')
    result = set()
    for line in text.splitlines():
        line = line.strip().split('#', 1)[0].strip()
        if not line:
            continue
        if ':' in line and '/' not in line:
            group, event = line.split(':', 1)
            line = f'{group}/{event}'
        result.add(line)
    return result


def check_event(name, events, required=False):
    if events is None:
        if required:
            print(f'NOTE: event {name} not verified (no --events); board check REQUIRED', file=sys.stderr)
        return True
    if name in events:
        return True
    if required:
        raise ValueError(f'required tracefs event missing: {name}')
    print(f'NOTE: optional event unavailable, omitted: {name}', file=sys.stderr)
    return False


def quoted(value):
    if not value or any(ch in value for ch in '\n\r\x00"\\'):
        raise ValueError('target name must be a nonempty single-line cmdline without quotes/backslash')
    return '"' + value + '"'


def render(args):
    if args.duration_ms < 1000 or args.duration_ms > 1800000:
        raise ValueError('duration must be between 1000 and 1800000 ms')
    if not 20 <= args.poll_ms <= 60000:
        raise ValueError('poll_ms must be 20..60000 (Perfetto sys_stats requires >10ms)')
    if not 1 <= args.frequency_hz <= 200:
        raise ValueError('frequency_hz must be 1..200 per CPU (initial safety ceiling)')
    if not 1024 <= args.buffer_kb <= 131072:
        raise ValueError('buffer_kb must be 1024..131072 KiB')
    if args.no_sched and args.route in ('overview', 'scheduling'):
        raise ValueError('--no-sched only applies to frequency or profiling routes')
    if args.no_sched and args.with_sched:
        raise ValueError('--no-sched and --with-sched are mutually exclusive')
    if args.with_sched and args.route not in ('frequency', 'profiling'):
        raise ValueError('--with-sched only applies to frequency or profiling routes')
    events = available_events(args.events)
    pieces = [f'duration_ms: {args.duration_ms}',
              f'buffers {{ size_kb: {args.buffer_kb} fill_policy: RING_BUFFER }}',
              'data_sources { config { name: "linux.process_stats" '
              'process_stats_config { scan_all_processes_on_start: true proc_stats_poll_ms: 1000 } } }']
    # Route intent (v0.1.0-r1): frequency is a LIGHT route. It polls cpufreq via
    # sysfs and only adds ftrace power events; sched events are opt-in there.
    # overview stays the comprehensive route (sched + power + polling).
    wants_sched = args.route in ('overview', 'scheduling') or (
        args.route == 'profiling' and not args.no_sched) or (
        args.route == 'frequency' and args.with_sched)
    if wants_sched:
        ev = ['sched/sched_switch']
        check_event(ev[0], events, required=True)
        if not args.no_waking:
            for opt in ('sched/sched_waking', 'sched/sched_wakeup_new'):
                if check_event(opt, events): ev.append(opt)
        if args.route in ('frequency', 'overview'):
            for opt in ('power/cpu_frequency', 'power/cpu_idle'):
                if check_event(opt, events): ev.append(opt)
        strings = '\n'.join(f'      ftrace_events: {quoted(x)}' for x in ev)
        pieces.append('data_sources { config { name: "linux.ftrace"\n'
                      f'    ftrace_config {{ buffer_size_kb: {args.ftrace_kb} '
                      f'drain_period_ms: {args.drain_ms}\n{strings}\n    }}\n  }} }}')
        if args.route == 'frequency' and args.with_sched:
            print('NOTE: frequency route with --with-sched adds sched events '
                  '(larger trace; use it only for on-CPU/Runnable attribution)', file=sys.stderr)
    elif args.route == 'frequency':
        # No sched: still collect frequency/idle *change* events when the board
        # actually exposes them; polling below covers the initial value.
        ev = []
        for opt in ('power/cpu_frequency', 'power/cpu_idle'):
            if check_event(opt, events): ev.append(opt)
        if ev:
            strings = '\n'.join(f'      ftrace_events: {quoted(x)}' for x in ev)
            pieces.append('data_sources { config { name: "linux.ftrace"\n'
                          f'    ftrace_config {{ buffer_size_kb: {args.ftrace_kb} '
                          f'drain_period_ms: {args.drain_ms}\n{strings}\n    }}\n  }} }}')
        if events is None:
            print('NOTE: frequency route: power event support not verified (no --events); '
                  'run survey.sh --events on the target first', file=sys.stderr)
        elif not ev:
            print('NOTE: frequency route: no power/cpu_frequency or power/cpu_idle on target; '
                  'polling-only config (no frequency-change events)', file=sys.stderr)
        if args.with_sched:
            print('NOTE: frequency route with --with-sched adds sched events '
                  '(larger trace; use it only for on-CPU/Runnable attribution)', file=sys.stderr)
        else:
            print('NOTE: frequency route omits sched events by default (light capture); '
                  'add --with-sched only if you need on-CPU/Runnable attribution', file=sys.stderr)
    if args.route in ('overview', 'frequency'):
        # Initial values via sysfs poll; changes via optional ftrace above.
        pieces.append('data_sources { config { name: "linux.sys_stats" '
                      f'sys_stats_config {{ cpufreq_period_ms: {args.poll_ms} }} }} }}')
    if args.route == 'profiling':
        if not args.target:
            raise ValueError('profiling route needs --target ACTUAL_PROCESS_BASENAME')
        target = quoted(args.target)
        pieces.append('data_sources { config { name: "linux.perf"\n'
                      '  perf_event_config {\n'
                      '    timebase { counter: SW_CPU_CLOCK '
                      f'frequency: {args.frequency_hz} timestamp_clock: PERF_CLOCK_MONOTONIC }}\n'
                      f'    callstack_sampling {{ scope {{ target_cmdline: {target} }} kernel_frames: true }}\n'
                      '  }\n} }')
        print('NOTE: linux.perf is CONDITIONAL; verify perf_event_open permissions, producer, '
              'stack samples and symbolization on target. No sysctl changes.', file=sys.stderr)
    return '\n\n'.join(pieces) + '\n'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('route', choices=('overview', 'scheduling', 'frequency', 'profiling'))
    p.add_argument('--platform', choices=('linux', 'android'), default='linux')
    p.add_argument('--events', help='read-only board survey.sh --events output')
    p.add_argument('--target', help='actual target cmdline basename for linux.perf route')
    p.add_argument('--duration-ms', type=int, default=15000)
    p.add_argument('--poll-ms', type=int, default=500)
    p.add_argument('--frequency-hz', type=int, default=100)
    p.add_argument('--buffer-kb', type=int, default=16384)
    p.add_argument('--ftrace-kb', type=int, default=1024)
    p.add_argument('--drain-ms', type=int, default=250)
    p.add_argument('--no-waking', action='store_true')
    p.add_argument('--no-sched', action='store_true',
                   help='frequency/profiling only: omit sched events (frequency is already light by default)')
    p.add_argument('--with-sched', action='store_true',
                   help='frequency only: also collect sched events for on-CPU attribution')
    a = p.parse_args()
    if a.platform == 'android':
        print('NOTE: Android variant is a recipe, not API-level tested; check actual permissions and tool build.', file=sys.stderr)
    try:
        if a.ftrace_kb < 128 or a.ftrace_kb > 16384:
            raise ValueError('ftrace_kb must be 128..16384')
        if not 50 <= a.drain_ms <= 60000:
            raise ValueError('drain_ms must be 50..60000')
        text = render(a)
    except (ValueError, OSError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 2
    sys.stdout.write(text)
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
