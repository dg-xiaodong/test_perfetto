#!/usr/bin/env python3
"""Emit a memory-classified sys_stats config (base = skill rss-spike output, extended meminfo)."""
import sys
dur = sys.argv[1]
mem = ['MEMINFO_MEM_TOTAL','MEMINFO_MEM_FREE','MEMINFO_MEM_AVAILABLE','MEMINFO_BUFFERS',
       'MEMINFO_CACHED','MEMINFO_SWAP_CACHED','MEMINFO_DIRTY','MEMINFO_WRITEBACK',
       'MEMINFO_ANON_PAGES','MEMINFO_MAPPED','MEMINFO_SHMEM','MEMINFO_SLAB',
       'MEMINFO_SLAB_RECLAIMABLE','MEMINFO_SLAB_UNRECLAIMABLE','MEMINFO_KERNEL_STACK',
       'MEMINFO_PAGE_TABLES','MEMINFO_SWAP_TOTAL','MEMINFO_SWAP_FREE',
       'MEMINFO_CMA_TOTAL','MEMINFO_CMA_FREE']
vm = ['VMSTAT_NR_FREE_PAGES','VMSTAT_PGFAULT','VMSTAT_PGMAJFAULT','VMSTAT_PSWPIN','VMSTAT_PSWPOUT']
print(f'''# Memory-classification config for X5 (base: skill rss-spike recipe, meminfo extended)
buffers {{ size_kb: 8192 fill_policy: RING_BUFFER }}
buffers {{ size_kb: 4096 fill_policy: DISCARD }}
duration_ms: {dur}
data_sources {{
  config {{
    name: "linux.process_stats"
    target_buffer: 1
    process_stats_config {{
      scan_all_processes_on_start: true
      proc_stats_poll_ms: 250
    }}
  }}
}}
data_sources {{
  config {{
    name: "linux.sys_stats"
    target_buffer: 0
    sys_stats_config {{
      meminfo_period_ms: 250
{chr(10).join(f"      meminfo_counters: {x}" for x in mem)}
      vmstat_period_ms: 1000
{chr(10).join(f"      vmstat_counters: {x}" for x in vm)}
    }}
  }}
}}
data_sources {{
  config {{
    name: "linux.ftrace"
    target_buffer: 1
    ftrace_config {{
      buffer_size_kb: 1024
      drain_period_ms: 250
      ftrace_events: "kmem/rss_stat"
    }}
  }}
}}
''')
