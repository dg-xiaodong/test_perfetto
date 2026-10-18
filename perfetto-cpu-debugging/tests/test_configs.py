import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAKE = ROOT/'scripts/make_config.py'
VAL = ROOT/'scripts/validate_config.py'


def cmd(*args):
    return subprocess.run([sys.executable, str(MAKE), *args], capture_output=True, text=True)


class ConfigTests(unittest.TestCase):
    def test_all_four_templates_nonempty(self):
        self.assertEqual(len(list((ROOT/'configs').glob('*.pbtxt'))), 4)
        for p in (ROOT/'configs').glob('*.pbtxt'):
            self.assertGreater(p.stat().st_size, 100)
            v=subprocess.run([sys.executable, str(VAL), str(p)], capture_output=True, text=True)
            self.assertEqual(v.returncode, 0, f'{p}: {v.stdout} {v.stderr}')

    def test_generation_four_routes(self):
        for route in ('overview','scheduling','frequency','profiling'):
            with self.subTest(route=route):
                args=[route,'--duration-ms','16000']
                if route=='profiling':args+=['--target','worker_app']
                r=cmd(*args)
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertIn('duration_ms: 16000',r.stdout)
                self.assertIn('linux.process_stats',r.stdout)
                if route=='profiling':
                    self.assertIn('name: "linux.perf"',r.stdout)
                    self.assertIn('target_cmdline: "worker_app"',r.stdout)
                if route=='frequency':
                    self.assertIn('cpufreq_period_ms: 500',r.stdout)

    def test_no_unknown_events_in_static_aware_config(self):
        # frequency --with-sched: only events the board actually reports may appear.
        with tempfile.TemporaryDirectory() as t:
            event=pathlib.Path(t)/'events.txt'
            event.write_text('sched:sched_switch\npower:cpu_frequency\n')
            r=cmd('frequency','--events',str(event),'--with-sched')
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertIn('sched/sched_switch',r.stdout)
            self.assertIn('power/cpu_frequency',r.stdout)
            self.assertNotIn('"sched/sched_waking"',r.stdout)
            self.assertNotIn('"power/cpu_idle"',r.stdout)

    def test_missing_required_sched_fails_without_partial_stdout(self):
        with tempfile.TemporaryDirectory() as t:
            e=pathlib.Path(t)/'events.txt';e.write_text('power:cpu_frequency\n')
            r=cmd('scheduling','--events',str(e))
            self.assertNotEqual(r.returncode,0)
            self.assertIn('required tracefs event missing',r.stderr)
            self.assertEqual(r.stdout,'')

    def test_name_required_and_injection_rejected(self):
        self.assertNotEqual(cmd('profiling').returncode,0)
        self.assertNotEqual(cmd('profiling','--target','abc"bad').returncode,0)
        self.assertNotEqual(cmd('profiling','--target','bad\nfoo').returncode,0)

    def test_frequency_bounds(self):
        self.assertNotEqual(cmd('profiling','--target','p','--frequency-hz','1000').returncode,0)
        self.assertNotEqual(cmd('overview','--duration-ms','0').returncode,0)
        self.assertNotEqual(cmd('frequency','--poll-ms','5').returncode,0)

    def test_no_sched_frequency_keeps_polling(self):
        # --no-sched drops sched only; frequency/idle change events + polling stay.
        r=cmd('frequency','--no-sched')
        self.assertEqual(r.returncode,0)
        self.assertNotIn('sched/sched_switch',r.stdout)
        self.assertIn('power/cpu_frequency',r.stdout)
        self.assertIn('cpufreq_period_ms',r.stdout)

    def test_required_sched_route_cannot_silently_omit_sched(self):
        self.assertNotEqual(cmd('scheduling','--no-sched').returncode,0)
        self.assertNotEqual(cmd('overview','--no-sched').returncode,0)
        self.assertNotEqual(cmd('overview','--with-sched').returncode,0)
        self.assertNotEqual(cmd('scheduling','--with-sched').returncode,0)
        self.assertNotEqual(cmd('frequency','--no-sched','--with-sched').returncode,0)

    def test_frequency_route_is_light_and_differs_from_overview(self):
        with tempfile.TemporaryDirectory() as t:
            e=pathlib.Path(t)/'events.txt'
            e.write_text('sched:sched_switch\nsched:sched_waking\n'
                         'power:cpu_frequency\npower:cpu_idle\n')
            freq=cmd('frequency','--events',str(e),'--duration-ms','15000')
            over=cmd('overview','--events',str(e),'--duration-ms','15000')
            self.assertEqual((freq.returncode,over.returncode),(0,0))
            self.assertNotEqual(freq.stdout,over.stdout,
                                'frequency and overview must not generate identical configs')
            # light route: no sched events, still polls cpufreq, keeps power change events
            self.assertNotIn('sched/sched_switch',freq.stdout)
            self.assertNotIn('sched/sched_waking',freq.stdout)
            self.assertIn('power/cpu_frequency',freq.stdout)
            self.assertIn('power/cpu_idle',freq.stdout)
            self.assertIn('cpufreq_period_ms: 500',freq.stdout)
            # comprehensive route keeps sched
            self.assertIn('sched/sched_switch',over.stdout)

    def test_frequency_with_sched_is_opt_in(self):
        r=cmd('frequency','--with-sched')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('sched/sched_switch',r.stdout)
        self.assertIn('cpufreq_period_ms',r.stdout)
        self.assertIn('--with-sched',r.stderr)  # user is told sched was added

    def test_frequency_polling_only_when_power_events_absent(self):
        with tempfile.TemporaryDirectory() as t:
            e=pathlib.Path(t)/'events.txt'; e.write_text('sched:sched_switch\n')
            r=cmd('frequency','--events',str(e))
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertNotIn('linux.ftrace',r.stdout)
            self.assertIn('cpufreq_period_ms: 500',r.stdout)
            self.assertIn('polling-only',r.stderr)

    def test_static_frequency_config_differs_from_overview(self):
        freq=(ROOT/'configs/cpu-frequency.pbtxt').read_text()
        over=(ROOT/'configs/cpu-overview.pbtxt').read_text()
        self.assertNotEqual(freq,over)
        self.assertNotIn('sched/sched_switch',freq)
        self.assertIn('power/cpu_frequency',freq)
        self.assertIn('cpufreq_period_ms',freq)
        self.assertIn('sched/sched_switch',over)

    def test_validation_and_missing_resource(self):
        r=subprocess.run([sys.executable,str(VAL),'--check-resources'],capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn('PASS',r.stdout)

    def test_structural_validator(self):
        with tempfile.TemporaryDirectory() as t:
            f=pathlib.Path(t)/'test.pbtxt'
            f.write_text('duration_ms: 10000\ndata_sources { config { name: "linux.ftrace" } }\n')
            r=subprocess.run([sys.executable,str(VAL),str(f)],capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stdout)
            self.assertIn('UNKNOWN',r.stdout)  # schema remains unverified
            f.write_text('duration_ms: 10000\ndata_sources { config { name: "bad" }\n')
            r=subprocess.run([sys.executable,str(VAL),str(f)],capture_output=True,text=True)
            self.assertNotEqual(r.returncode,0)


if __name__=='__main__':unittest.main()
