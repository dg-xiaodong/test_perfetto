#!/usr/bin/env python3
"""Generate bounded scheduling configs; stdout=pbtxt, stderr=budget/limitations.
No network, no target changes. --help is the interface contract.
"""
import argparse
import json
import re
import sys
from pathlib import Path


def parser():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('route',choices=['overview','block-wake'])
    p.add_argument('--cpu-count',type=int,required=True,help='Target online CPU count, not host count')
    p.add_argument('--duration-ms',type=int,default=15000)
    p.add_argument('--tid',type=int,action='append',default=[],help='Actual Linux TID; repeat for <=8 related threads')
    p.add_argument('--events',type=Path,help='Target available_events; required for block-wake')
    p.add_argument('--formats',type=Path,help='Directory containing sched_switch.format and sched_waking.format')
    p.add_argument('--ring-pages',type=int,default=64,help='Per-CPU, per-perf-stream pages (power of 2)')
    p.add_argument('--page-size',type=int,default=4096,help='Target getconf PAGESIZE; block-wake v0.1.0 supports 4096 only')
    p.add_argument('--trace-buffer-kib',type=int,default=8192)
    p.add_argument('--ftrace-buffer-kib',type=int,default=512,help='Per CPU')
    p.add_argument('--queue-kib',type=int,default=8192,help='Shared unwinder queue limit, not per stream')
    p.add_argument('--reserve-kib',type=int,default=16384,help='Planning reserve, not a runtime guarantee')
    p.add_argument('--budget-mib',type=int,default=64)
    p.add_argument('--with-migration',action='store_true')
    p.add_argument('--with-futex',action='store_true',help='Opt-in sys_futex syscall tracing; needs target raw syscall events')
    p.add_argument('--kernel-frames',action='store_true',help='Requires target permissions; never changes sysctls')
    p.add_argument('--output',type=Path,help='New file only; no overwrite')
    return p


def build_config(a):
    if not 1 <= a.cpu_count <= 256: raise ValueError('cpu-count must be 1..256')
    if not 1000 <= a.duration_ms <= 60000: raise ValueError('duration-ms must be 1000..60000')
    for name in ('trace_buffer_kib','ftrace_buffer_kib','queue_kib','reserve_kib','budget_mib'):
        if getattr(a,name)<=0: raise ValueError(name+' must be positive')
    if a.ring_pages<=0 or a.ring_pages & (a.ring_pages-1): raise ValueError('ring-pages must be a power of two')
    if a.ring_pages>2048: raise ValueError('ring-pages >2048 outside this bounded recipe')
    tids=sorted(set(a.tid))
    if any(t<=0 or t>2147483647 for t in tids) or len(tids)>8: raise ValueError('use 1..8 positive target TIDs')
    needed=['sched/sched_switch','sched/sched_waking']
    events=None
    if a.events:
        events={line.strip().replace(':','/',1) for line in a.events.read_text().splitlines() if line.strip()}
        missing=set(needed)-events
        if missing: raise ValueError('required target events missing: '+','.join(sorted(missing)))
    if a.route=='block-wake':
        if not tids: raise ValueError('block-wake requires actual --tid; unfiltered systemwide stacks are refused')
        if a.page_size!=4096: raise ValueError('non-4KiB target page size needs separate validation; not supported by this recipe')
        if not a.events or not a.formats: raise ValueError('block-wake requires --events and --formats from the target')
        for event,field in [('sched_switch','prev_pid'),('sched_waking','pid')]:
            text=(a.formats/(event+'.format')).read_text()
            if not re.search(r'field:[^;]*\b'+field+r'\s*;',text):
                raise ValueError(event+' format has no field '+field)
    selected=needed[:]
    for optional in ['sched/sched_wakeup_new','sched/sched_process_exit']:
        if events is not None and optional in events: selected.append(optional)
    if a.with_futex:
        if events is None or not {'raw_syscalls/sys_enter','raw_syscalls/sys_exit'} <= events:
            raise ValueError('--with-futex requires verified raw_syscalls enter/exit support')
        selected += ['raw_syscalls/sys_enter','raw_syscalls/sys_exit']
    if a.with_migration:
        if events is None or 'sched/sched_migrate_task' not in events:
            raise ValueError('--with-migration requires confirmed sched/sched_migrate_task')
        selected.append('sched/sched_migrate_task')
    streams=2 if a.route=='block-wake' else 0
    # Budget is an estimate, not a promise of peak RSS. Include one metadata page
    # per perf ring; unwinder queue is shared and counted ONCE.
    perf_kib=streams*a.cpu_count*(a.ring_pages+1)*a.page_size//1024
    budget={'cpu_count':a.cpu_count,'perf_streams':streams,'perf_rings_with_metadata_kib':perf_kib,
            'ftrace_kib':a.cpu_count*a.ftrace_buffer_kib,'traced_kib':a.trace_buffer_kib,
            'shared_unwinder_queue_kib':a.queue_kib if streams else 0,'reserve_kib':a.reserve_kib}
    budget['planned_kib']=sum(budget[k] for k in ('perf_rings_with_metadata_kib','ftrace_kib','traced_kib','shared_unwinder_queue_kib','reserve_kib'))
    if budget['planned_kib']>a.budget_mib*1024: raise ValueError('planned memory exceeds --budget-mib: '+json.dumps(budget))
    lines=['# Generated by perfetto-scheduling-debugging 0.1.0 Candidate.',
           '# Source-level configuration basis: Perfetto v57.1/v58.2; runtime must be checked.',
           '# No heapprofd/LD_PRELOAD. No perf scope: preserve cross-process wakers.',
           f'duration_ms: {a.duration_ms}',
           f'buffers {{ size_kb: {a.trace_buffer_kib} fill_policy: RING_BUFFER }}',
           'data_sources { config { name: "linux.process_stats"',
           '  process_stats_config { scan_all_processes_on_start: true proc_stats_poll_ms: 1000 }',
           '} }',
           'data_sources { config { name: "linux.ftrace"',
           f'  ftrace_config {{ buffer_size_kb: {a.ftrace_buffer_kib} drain_period_ms: 100']
    lines += ['    ftrace_events: '+json.dumps(e) for e in selected]
    if a.with_futex: lines.append('    syscall_events: "sys_futex"')
    lines += ['  }','} }']
    if streams:
        for event,field,label in [('sched_switch','prev_pid','scheduling.switch'),('sched_waking','pid','scheduling.waking')]:
            filt=' || '.join(f'{field} == {tid}' for tid in tids)
            lines += ['data_sources { config { name: "linux.perf"',
              '  perf_event_config {',
              '    timebase {',
              '      period: 1',
              f'      name: "{label}"',
              '      timestamp_clock: PERF_CLOCK_MONOTONIC',
              f'      tracepoint {{ name: "sched/{event}" filter: {json.dumps(filt)} }}',
              '    }',
              '    callstack_sampling { kernel_frames: '+str(a.kernel_frames).lower()+' }',
              f'    ring_buffer_pages: {a.ring_pages}',
              '    ring_buffer_read_period_ms: 50',
              f'    max_enqueued_footprint_kb: {a.queue_kib}',
              '  }','} }']
    return '\n'.join(lines)+'\n',budget


def main():
    a=parser().parse_args()
    try:
        text,b=build_config(a)
        from validate_config import check_policy
        check_policy(text)
        if a.output:
            with a.output.open('x') as f: f.write(text)
        else: sys.stdout.write(text)
        print('BUDGET_ESTIMATE '+json.dumps(b,sort_keys=True),file=sys.stderr)
        print('SCHEMA/RUNTIME: not verified here; missing event stacks must remain UNKNOWN.',file=sys.stderr)
        if not a.events: print('EVENT_SUPPORT_UNKNOWN: no target event list supplied.',file=sys.stderr)
    except (ValueError,OSError) as e:
        print('ERROR: '+str(e),file=sys.stderr);return 2
    return 0
if __name__=='__main__': raise SystemExit(main())
