#!/usr/bin/env python3
"""Build bounded Perfetto pbtxt recipes. Runs on host; no target dependencies.

Construction is not validation against a particular Perfetto release. Run
validate_config.py with a descriptor set from the collector's matching source.
"""
from __future__ import annotations
import argparse
import json
import pathlib
import re
import sys

SCENARIOS = ('overview', 'rss-spike', 'native', 'native-peak', 'java-alloc',
             'java-graph', 'java-oom', 'kernel-pressure', 'android-lmk', 'mmap')
MIN_API = {'native': 29, 'native-peak': 30, 'java-alloc': 31,
           'java-graph': 30, 'java-oom': 34, 'mmap': 34}
ANDROID_ONLY = {'java-alloc', 'java-graph', 'java-oom', 'android-lmk'}
TARGETED = {'native', 'native-peak', 'java-alloc', 'java-graph', 'java-oom', 'mmap'}
HEAPS = {'native', 'native-peak', 'java-alloc'}
EVENT_REQUIRED = {'rss-spike', 'kernel-pressure', 'android-lmk', 'mmap'}


def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def available_events(path: pathlib.Path | None) -> set[str]:
    if path is None:
        return set()
    events = set()
    for line in path.read_text(encoding='utf-8').splitlines():
        token = line.strip().split('#', 1)[0].strip().replace(':', '/')
        if re.fullmatch(r'[A-Za-z0-9_]+/[A-Za-z0-9_]+', token):
            events.add(token)
    return events


def source(name: str, body: str, buffer: int) -> str:
    return ('data_sources {\n  config {\n    name: ' + quote(name) + '\n'
            f'    target_buffer: {buffer}\n' +
            '\n'.join('    ' + line for line in body.splitlines()) +
            '\n  }\n}\n')


def check(a: argparse.Namespace, events: set[str]) -> None:
    if a.scenario in ANDROID_ONLY and a.platform != 'android':
        raise ValueError(f'{a.scenario} requires Android/ART, not ordinary Linux')
    if a.platform == 'android' and a.scenario in MIN_API:
        floor = MIN_API[a.scenario]
        if a.api is None or a.api < floor:
            raise ValueError(f'{a.scenario} requires confirmed Android API >= {floor}')
    if a.scenario in TARGETED:
        if not a.process or any(ord(c) < 32 for c in a.process):
            raise ValueError('An exact, nonempty process command name is required')
        if any(c in a.process for c in '*?[]'):
            raise ValueError('This startup-capable recipe requires an exact name, not a glob')
    for field in ('duration_ms', 'sampling', 'dump_ms', 'oom_wait_ms'):
        if not 1 <= getattr(a, field) <= 4294967295:
            raise ValueError(f'{field} must be in 1..4294967295')
    if not 100 <= a.poll_ms <= 4294967295:
        raise ValueError('poll_ms must be >= 100 ms; use rss-spike for short events')
    if not 8 <= a.shmem_kb <= 1048576 or a.shmem_kb & (a.shmem_kb - 1):
        raise ValueError('shmem_kb must be a power of two, 8..1048576 KiB')
    if a.scenario in EVENT_REQUIRED and (a.events is None or not events):
        raise ValueError('Supply a nonempty --events file from the target tracefs available_events')
    if a.scenario == 'rss-spike' and 'kmem/rss_stat' not in events:
        raise ValueError('Target lacks kmem/rss_stat; use overview with stated polling blind spots')
    if a.sched and 'sched/sched_switch' not in events:
        raise ValueError('--sched requires a target events file containing sched/sched_switch')
    if a.scenario == 'mmap':
        if not a.arch or not a.perf_confirmed:
            raise ValueError('mmap requires --arch and --perf-confirmed after a real linux.perf tracepoint preflight')
        required = {'raw_syscalls/sys_enter', 'raw_syscalls/sys_exit', 'sched/sched_switch'}
        if not required <= events:
            raise ValueError('mmap requires raw_syscalls enter/exit and sched_switch on the target')


def build(a: argparse.Namespace) -> str:
    events = available_events(a.events)
    check(a, events)
    graph = a.scenario in {'java-graph', 'java-oom'}
    heap = a.scenario in HEAPS
    parts = [
        '# Generated recipe; validate with the COLLECTOR version before deployment.\n'
        '# Durations/polling: ms. Buffers: KiB. Heap sampling: bytes.\n'
        '# Budget includes buffers + per-CPU ftrace + heapprofd shmem + output files.\n',
        'buffers { size_kb: 8192 fill_policy: RING_BUFFER }\n',
        'buffers { size_kb: 4096 fill_policy: DISCARD }\n'
    ]
    if heap or graph:
        parts.append(f'buffers {{ size_kb: {65536 if graph else 32768} fill_policy: DISCARD }}\n')
    if a.scenario != 'java-oom':
        parts.append(f'duration_ms: {a.duration_ms}\n')
    else:
        parts.append('data_source_stop_timeout_ms: 100000\n'
                     'trigger_config {\n  trigger_mode: START_TRACING\n'
                     f'  trigger_timeout_ms: {a.oom_wait_ms}\n'
                     '  triggers {\n    name: "com.android.telemetry.art-outofmemory"\n'
                     '    stop_delay_ms: 500\n  }\n}\n')
    parts.append(source('linux.process_stats',
                        'process_stats_config {\n  scan_all_processes_on_start: true\n'
                        f'  proc_stats_poll_ms: {a.poll_ms}\n}}', 1))
    mem = ('MEMINFO_MEM_TOTAL', 'MEMINFO_MEM_FREE', 'MEMINFO_MEM_AVAILABLE',
           'MEMINFO_BUFFERS', 'MEMINFO_CACHED', 'MEMINFO_ANON_PAGES',
           'MEMINFO_SHMEM', 'MEMINFO_SLAB', 'MEMINFO_SWAP_TOTAL',
           'MEMINFO_SWAP_FREE', 'MEMINFO_CMA_TOTAL', 'MEMINFO_CMA_FREE')
    vm = ('VMSTAT_NR_FREE_PAGES', 'VMSTAT_PGFAULT', 'VMSTAT_PGMAJFAULT',
          'VMSTAT_PSWPIN', 'VMSTAT_PSWPOUT')
    sys_body = 'sys_stats_config {\n' + f'  meminfo_period_ms: {a.poll_ms}\n'
    sys_body += ''.join(f'  meminfo_counters: {x}\n' for x in mem)
    sys_body += f'  vmstat_period_ms: {a.poll_ms}\n'
    sys_body += ''.join(f'  vmstat_counters: {x}\n' for x in vm) + '}'
    parts.append(source('linux.sys_stats', sys_body, 0))

    chosen = set()
    if a.scenario == 'rss-spike':
        chosen.add('kmem/rss_stat')
    if a.scenario == 'kernel-pressure':
        vmscan = {
            'vmscan/mm_vmscan_direct_reclaim_begin', 'vmscan/mm_vmscan_direct_reclaim_end',
            'vmscan/mm_vmscan_kswapd_wake', 'vmscan/mm_vmscan_kswapd_sleep',
            'vmscan/mm_vmscan_memcg_reclaim_begin', 'vmscan/mm_vmscan_memcg_reclaim_end'}
        compaction = {'compaction/mm_compaction_begin', 'compaction/mm_compaction_end',
                      'compaction/mm_compaction_migratepages'}
        chosen = {e for e in events if e.startswith(('cma/', 'oom/')) or e in vmscan | compaction}
        if not chosen:
            raise ValueError('No supported pressure/CMA events found; use overview + filesystem snapshots')
        if 'kmem/rss_stat' in events:
            chosen.add('kmem/rss_stat')
    if a.scenario == 'android-lmk':
        chosen = {'lowmemorykiller/lowmemory_kill', 'oom/oom_score_adj_update'} & events
    if a.sched or a.scenario == 'mmap':
        chosen.add('sched/sched_switch')
    if chosen or a.scenario in {'android-lmk', 'mmap'}:
        fbody = 'ftrace_config {\n  buffer_size_kb: 1024\n  drain_period_ms: 250\n'
        fbody += ''.join(f'  ftrace_events: {quote(e)}\n' for e in sorted(chosen))
        if a.scenario == 'android-lmk':
            fbody += '  atrace_apps: "lmkd"\n'
        if a.scenario == 'mmap':
            fbody += ''.join(f'  syscall_events: "sys_{x}"\n' for x in ('mmap','munmap','madvise'))
        parts.append(source('linux.ftrace', fbody + '}', 0))

    if heap:
        h = 'heapprofd_config {\n'
        h += f'  sampling_interval_bytes: {a.sampling}\n  process_cmdline: {quote(a.process)}\n'
        h += f'  shmem_size_bytes: {a.shmem_kb * 1024}\n  block_client: false\n'
        if a.scenario == 'native-peak':
            h += '  dump_at_max: true\n'
        else:
            h += f'  continuous_dump_config {{ dump_interval_ms: {a.dump_ms} }}\n'
        if a.scenario == 'java-alloc':
            h += '  heaps: "com.android.art"\n'
        parts.append(source('android.heapprofd', h + '}', 2))
    if graph:
        name = 'android.java_hprof.oom' if a.scenario == 'java-oom' else 'android.java_hprof'
        g = 'java_hprof_config {\n' + f'  process_cmdline: {quote(a.process)}\n  dump_smaps: true\n'
        if a.scenario == 'java-graph':
            g += f'  continuous_dump_config {{ dump_interval_ms: {a.dump_ms} }}\n'
        parts.append(source(name, g + '}', 2))
        parts.append(source('android.packages_list', '', 1))
    if a.scenario == 'mmap':
        syscall = 222 if a.arch == 'aarch64' else 9
        p = ('perf_event_config {\n  timebase {\n    period: 1\n    tracepoint {\n'
             '      name: "raw_syscalls:sys_enter"\n' + f'      filter: "id == {syscall}"\n'
             '    }\n  }\n  callstack_sampling {\n    scope {\n' +
             f'      target_cmdline: {quote(a.process)}\n' +
             '    }\n    kernel_frames: false\n  }\n}')
        parts.append(source('linux.perf', p, 0))
    return '\n'.join(parts)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('scenario', choices=SCENARIOS)
    p.add_argument('--platform', choices=('linux', 'android'), required=True)
    p.add_argument('--api', type=int, help='Confirmed Android API level')
    p.add_argument('--process', help='Exact cmdline match; no PID reuse ambiguity or startup glob')
    p.add_argument('--events', type=pathlib.Path, help='Target available_events, not a guessed list')
    p.add_argument('--duration-ms', type=int, default=30000)
    p.add_argument('--poll-ms', type=int, default=1000)
    p.add_argument('--sampling', type=int, default=4096)
    p.add_argument('--dump-ms', type=int, default=5000)
    p.add_argument('--shmem-kb', type=int, default=8192)
    p.add_argument('--oom-wait-ms', type=int, default=60000)
    p.add_argument('--sched', action='store_true', help='Add sched_switch; extra trace overhead')
    p.add_argument('--arch', choices=('aarch64', 'x86_64'))
    p.add_argument('--perf-confirmed', action='store_true', help='Attest actual perf tracepoint permission/producer preflight succeeded')
    return p


def main() -> int:
    p = parser()
    a = p.parse_args()
    try:
        config = build(a)
    except (ValueError, OSError) as e:
        p.error(str(e))
    print(config, end='')
    print('Generated only; verify matching-version schema, source registration and trace data.', file=sys.stderr)
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
