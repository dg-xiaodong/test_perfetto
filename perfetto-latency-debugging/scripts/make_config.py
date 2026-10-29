#!/usr/bin/env python3
"""Bounded TrackEvent-only recipe; --with-sched adds system correlation, not another entry."""
import argparse,json,re,sys
from pathlib import Path

def generate_config(duration_ms=15000,buffer_kib=8192,category='rdk.latency',with_sched=False,events=None):
    if not 1000<=duration_ms<=120000:raise ValueError('duration-ms must be 1000..120000')
    if not 1024<=buffer_kib<=65536:raise ValueError('buffer-kib must be 1024..65536')
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,63}',category):raise ValueError('invalid exact category')
    if with_sched and not {'sched/sched_switch','sched/sched_waking'}<=set(events or []):raise ValueError('joint capture requires surveyed sched_switch and sched_waking')
    out=f'''# perfetto-latency-debugging 0.1.1 Candidate; collector-specific schema/runtime still need validation.
duration_ms: {duration_ms}
buffers {{ size_kb: {buffer_kib} fill_policy: DISCARD }}
data_sources {{ config {{
  name: "track_event"
  track_event_config {{
    disabled_categories: "*"
    enabled_categories: "{category}"
  }}
}} }}
'''
    if with_sched:
        out+='''data_sources { config {
  name: "linux.ftrace"
  ftrace_config {
    buffer_size_kb: 512
    drain_period_ms: 100
    ftrace_events: "sched/sched_switch"
    ftrace_events: "sched/sched_waking"
  }
} }
data_sources { config {
  name: "linux.process_stats"
  process_stats_config { scan_all_processes_on_start: true proc_stats_poll_ms: 1000 }
} }
'''
    return out

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--duration-ms',type=int,default=15000);p.add_argument('--buffer-kib',type=int,default=8192)
    p.add_argument('--category',default='rdk.latency');p.add_argument('--with-sched',action='store_true')
    p.add_argument('--events',type=Path);p.add_argument('--output',type=Path)
    a=p.parse_args()
    try:
        events={line.strip().replace(':','/',1) for line in a.events.read_text().splitlines()} if a.events else None
        text=generate_config(a.duration_ms,a.buffer_kib,a.category,a.with_sched,events)
        if a.output:
            with a.output.open('x') as f:f.write(text)
        else:sys.stdout.write(text)
        print('PLAN: traced buffer=%d KiB; ftrace extra=512 KiB/online-CPU if enabled; SDK producer buffers and service overhead are additional.'%a.buffer_kib,file=sys.stderr)
        return 0
    except (ValueError,OSError) as e:print('ERROR:',e,file=sys.stderr);return 2
if __name__=='__main__':raise SystemExit(main())
