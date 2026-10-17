"""Host-only contract tests. Not a Perfetto parser or target-device test."""
import pathlib
import importlib.util
from types import SimpleNamespace
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts' / 'make_config.py'
EVENTS = '''kmem:rss_stat
sched:sched_switch
sched:sched_process_exit
sched:sched_process_free
vmscan:mm_vmscan_direct_reclaim_begin
vmscan:mm_vmscan_direct_reclaim_end
compaction:mm_compaction_begin
compaction:mm_compaction_end
cma:cma_alloc_start
cma:cma_alloc_finish
cma:cma_alloc_busy_retry
cma:cma_release
oom:mark_victim
oom:oom_score_adj_update
raw_syscalls:sys_enter
raw_syscalls:sys_exit
lowmemorykiller:lowmemory_kill
'''

class ConfigTests(unittest.TestCase):
    def run_config(self, *args, events=None):
        spec = importlib.util.spec_from_file_location('make_config', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as td:
            args = list(args)
            if events is not None:
                p = pathlib.Path(td) / 'events.txt'
                p.write_text(events)
                args += ['--events', str(p)]
            try:
                a = module.parser().parse_args(args)
                text = module.build(a)
                return SimpleNamespace(returncode=0, stdout=text, stderr='')
            except (ValueError, OSError) as e:
                return SimpleNamespace(returncode=2, stdout='', stderr=str(e))

    def ok(self, *args, events=None):
        r = self.run_config(*args, events=events)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def bad(self, *args, events=None):
        r = self.run_config(*args, events=events)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(r.stdout.strip(), 'Invalid request must not emit a partial config')
        return r.stderr

    def test_generator_exists(self):
        self.assertTrue(SCRIPT.is_file(), 'Config generator is not implemented yet')

    def test_overview(self):
        t = self.ok('overview', '--platform', 'linux')
        self.assertIn('MEMINFO_CACHED', t)
        self.assertNotIn('MEMINFO_MEM_CACHED', t)
        self.assertIn('scan_all_processes_on_start: true', t)
        self.assertIn('proc_stats_poll_ms: 1000', t)
        self.assertNotIn('linux.ftrace', t)

    def test_spike_requires_events(self):
        self.bad('rss-spike', '--platform', 'linux')
        self.bad('rss-spike', '--platform', 'linux', events='sched:sched_switch\n')
        t = self.ok('rss-spike', '--platform', 'linux', events=EVENTS)
        self.assertIn('ftrace_events: "kmem/rss_stat"', t)
        self.assertNotIn('cma/', t)

    def test_event_normalization(self):
        t = self.ok('rss-spike', '--platform', 'linux', events='kmem/rss_stat\n')
        self.assertIn('"kmem/rss_stat"', t)

    def test_native_requires_target(self):
        self.bad('native', '--platform', 'linux')

    def test_native_sampling_and_buffers(self):
        t = self.ok('native', '--platform', 'linux', '--process', 'memprobe')
        self.assertIn('sampling_interval_bytes: 4096', t)
        self.assertIn('block_client: false', t)
        self.assertIn('dump_interval_ms: 5000', t)
        self.assertIn('target_buffer: 1', t)
        self.assertNotIn('idle_allocations', t)
        self.assertNotIn('all: true', t)

    def test_peak_not_continuous(self):
        t = self.ok('native-peak', '--platform', 'linux', '--process', 'memprobe')
        self.assertIn('dump_at_max: true', t)
        self.assertNotIn('continuous_dump_config', t)

    def test_android_version_gates(self):
        for scenario, api in [('native', 28), ('native-peak', 29), ('java-alloc', 30), ('java-graph', 29), ('java-oom', 33)]:
            self.bad(scenario, '--platform', 'android', '--api', str(api), '--process', 'com.example.app')
        self.bad('java-graph', '--platform', 'android', '--process', 'com.example.app')

    def test_art_only_android(self):
        for s in ['java-alloc', 'java-graph', 'java-oom', 'android-lmk']:
            self.bad(s, '--platform', 'linux', '--process', 'example')

    def test_art_alloc_heap(self):
        t = self.ok('java-alloc', '--platform', 'android', '--api', '31', '--process', 'com.example.app')
        self.assertIn('heaps: "com.android.art"', t)
        self.assertNotIn('dump_at_max', t)

    def test_graph_periodic(self):
        t = self.ok('java-graph', '--platform', 'android', '--api', '30', '--process', 'com.example.app')
        self.assertIn('android.java_hprof', t)
        self.assertNotIn('android.java_hprof.oom', t)
        self.assertIn('dump_smaps: true', t)

    def test_oome_trigger_not_duration(self):
        t = self.ok('java-oom', '--platform', 'android', '--api', '34', '--process', 'com.example.app')
        self.assertIn('com.android.telemetry.art-outofmemory', t)
        self.assertIn('START_TRACING', t)
        self.assertNotIn('duration_ms:', t)
        self.assertIn('trigger_timeout_ms: 60000', t)

    def test_cma_is_ftrace_not_datasource(self):
        t = self.ok('kernel-pressure', '--platform', 'linux', events=EVENTS)
        self.assertIn('"cma/cma_alloc_busy_retry"', t)
        self.assertIn('"vmscan/mm_vmscan_direct_reclaim_begin"', t)
        self.assertNotIn('name: "cma"', t)
        self.assertNotIn('"cma/*"', t)
        self.assertNotIn('raw_syscalls', t)

    def test_kernel_empty_events_rejected(self):
        self.bad('kernel-pressure', '--platform', 'linux', events='kmem:rss_stat\n')

    def test_lmk_selects_available_events(self):
        t = self.ok('android-lmk', '--platform', 'android', '--api', '34', events=EVENTS)
        self.assertIn('atrace_apps: "lmkd"', t)
        self.assertIn('lowmemorykiller/lowmemory_kill', t)

    def test_mmap_gates_and_arch(self):
        self.bad('mmap', '--platform', 'linux', '--process', 'memprobe', events=EVENTS)
        t = self.ok('mmap', '--platform', 'linux', '--process', 'memprobe', '--arch', 'aarch64', '--perf-confirmed', events=EVENTS)
        self.assertIn('filter: "id == 222"', t)
        self.assertIn('kernel_frames: false', t)
        self.assertIn('syscall_events: "sys_munmap"', t)
        t = self.ok('mmap', '--platform', 'linux', '--process', 'memprobe', '--arch', 'x86_64', '--perf-confirmed', events=EVENTS)
        self.assertIn('filter: "id == 9"', t)
        self.bad('mmap', '--platform', 'android', '--api', '33', '--process', 'example', '--arch', 'aarch64', '--perf-confirmed', events=EVENTS)

    def test_bad_values_and_injection(self):
        for extra in [('--sampling', '0'), ('--duration-ms', '-1'), ('--poll-ms', '1'), ('--shmem-kb', '9000'), ('--dump-ms', '0')]:
            self.bad('native', '--platform', 'linux', '--process', 'x', *extra)
        for name in ['x\nname: "evil"', 'x*', '']:
            self.bad('native', '--platform', 'linux', '--process', name)
        self.bad('overview', '--platform', 'linux', '--duration-ms', '10000000000000')

    def test_all_recipes_generate_balanced_configs(self):
        cases = [
            ('overview','linux',None),('rss-spike','linux',None),
            ('native','linux','memprobe'),('native-peak','linux','memprobe'),
            ('java-alloc','android','com.example.app'),('java-graph','android','com.example.app'),
            ('java-oom','android','com.example.app'),('kernel-pressure','linux',None),
            ('android-lmk','android',None),('mmap','linux','memprobe')]
        for scenario, platform, target in cases:
            args = [scenario, '--platform', platform, '--api', '34']
            if target: args += ['--process', target]
            if scenario == 'mmap': args += ['--arch', 'aarch64', '--perf-confirmed']
            t = self.ok(*args, events=EVENTS)
            self.assertEqual(t.count('{'), t.count('}'))
            self.assertNotIn('TODO', t)

if __name__ == '__main__': unittest.main()
