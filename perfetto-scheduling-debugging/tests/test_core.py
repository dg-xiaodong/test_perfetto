import importlib.util
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'
sys.path.insert(0, str(SCRIPTS))

class ImplementationPresent(unittest.TestCase):
    def test_required_implementation_exists(self):
        for name in ['make_config.py','validate_config.py','render_sql.py', 'request_latency.py', 'record.sh']:
            with self.subTest(name=name):
                self.assertTrue((SCRIPTS/name).is_file(), name+' is not implemented')

class ConfigTests(unittest.TestCase):
    def run_gen(self, *args):
        return subprocess.run([sys.executable, str(SCRIPTS/'make_config.py'), *args], text=True, capture_output=True)
    def test_overview_no_perf(self):
        p=self.run_gen('overview','--cpu-count','8')
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertIn('sched/sched_switch',p.stdout)
        self.assertNotIn('linux.perf',p.stdout)
    def test_block_requires_target(self):
        p=self.run_gen('block-wake','--cpu-count','8')
        self.assertNotEqual(p.returncode,0)
    def test_invalid_ring_power_rejected(self):
        p=self.run_gen('block-wake','--cpu-count','8','--tid','123','--ring-pages','63')
        self.assertNotEqual(p.returncode,0)
    def test_events_absent_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            f=Path(d)/'events'; f.write_text('power:cpu_idle\n')
            p=self.run_gen('overview','--cpu-count','8','--events',str(f))
            self.assertNotEqual(p.returncode,0)
    def test_deterministic_small_filtered_config(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d)
            (d/'sched_switch.format').write_text('field:pid_t prev_pid; offset:24; size:4; signed:1;\n')
            (d/'sched_waking.format').write_text('field:pid_t pid; offset:24; size:4; signed:1;\n')
            (d/'events').write_text('sched:sched_switch\nsched:sched_waking\n')
            args=['block-wake','--cpu-count','8','--tid','123','--events',str(d/'events'),'--formats',str(d)]
            p=self.run_gen(*args)
            self.assertEqual(p.returncode,0,p.stderr)
            self.assertEqual(p.stdout.count('name: "linux.perf"'),2)
            self.assertIn('prev_pid == 123',p.stdout)
            self.assertIn('pid == 123',p.stdout)
            self.assertNotIn('next_pid ==',p.stdout)
            self.assertNotIn('target_cmdline',p.stdout)
            self.assertNotIn('scope {',p.stdout)
            self.assertIn('scheduling.switch',p.stdout)
            self.assertIn('scheduling.waking',p.stdout)
            self.assertEqual(p.stdout,self.run_gen(*args).stdout)
            from validate_config import check_policy
            check_policy(p.stdout)
    def test_budget_overflow_rejected(self):
        p=self.run_gen('overview','--cpu-count','8','--budget-mib','1')
        self.assertNotEqual(p.returncode,0)
    def test_futex_opt_in_requires_events(self):
        p=self.run_gen('overview','--cpu-count','8','--with-futex')
        self.assertNotEqual(p.returncode,0)
    def test_futex_opt_in_config(self):
        with tempfile.TemporaryDirectory() as d:
            f=Path(d)/'e';f.write_text('sched:sched_switch\nsched:sched_waking\nraw_syscalls:sys_enter\nraw_syscalls:sys_exit\n')
            p=self.run_gen('overview','--cpu-count','8','--with-futex','--events',str(f))
            self.assertEqual(p.returncode,0,p.stderr)
            self.assertIn('syscall_events: "sys_futex"',p.stdout)
    def test_zero_duration_rejected(self):
        p=self.run_gen('overview','--cpu-count','8','--duration-ms','0')
        self.assertNotEqual(p.returncode,0)
    def test_non_4k_block_rejected(self):
        p=self.run_gen('block-wake','--cpu-count','8','--tid','123','--page-size','65536')
        self.assertNotEqual(p.returncode,0)

class PolicyTests(unittest.TestCase):
    def test_duplicate_duration_rejected(self):
        from validate_config import check_policy
        with self.assertRaises(ValueError):
            check_policy('duration_ms: 1000 duration_ms: 2000')
    def test_unknown_field_rejected(self):
        from validate_config import check_policy
        with self.assertRaises(ValueError):
            check_policy('duration_ms: 1000 typo_field: 2')
    def test_missing_descriptor_is_not_schema_pass(self):
        p=subprocess.run([sys.executable,str(SCRIPTS/'validate_config.py'),str(ROOT/'configs/overview.pbtxt')],capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertIn('SCHEMA_UNKNOWN',p.stdout)
        self.assertNotIn('SCHEMA_PASS',p.stdout)

class SqlTests(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:'); self.db.row_factory=sqlite3.Row
        self.db.create_function('EXTRACT_ARG',2,lambda a,k:json.loads(a).get(k) if a else None)
        self.db.executescript('''
        CREATE TABLE trace_bounds(start_ts INTEGER,end_ts INTEGER);
        INSERT INTO trace_bounds VALUES(0,1000);
        CREATE TABLE process(upid INTEGER PRIMARY KEY,pid INTEGER,name TEXT);
        INSERT INTO process VALUES(1,100,'P'),(2,200,'Q');
        CREATE TABLE thread(utid INTEGER PRIMARY KEY,tid INTEGER,upid INTEGER,name TEXT,start_ts INTEGER,end_ts INTEGER);
        INSERT INTO thread VALUES(1,101,1,'worker',0,1000),(2,201,2,'waker',0,1000),(0,0,NULL,'idle',0,NULL);
        CREATE TABLE thread_state(id INTEGER PRIMARY KEY,ts INTEGER,dur INTEGER,cpu INTEGER,utid INTEGER,state TEXT,waker_utid INTEGER,waker_id INTEGER,irq_context INTEGER);
        INSERT INTO thread_state VALUES(1,0,100,0,1,'Running',NULL,NULL,NULL),(2,100,200,NULL,1,'S',NULL,NULL,NULL),(3,300,50,NULL,1,'R',2,6,0),(4,350,50,1,1,'Running',NULL,NULL,NULL),(5,400,600,NULL,1,'S',NULL,NULL,NULL),(6,250,100,1,2,'Running',NULL,NULL,NULL);
        CREATE TABLE sched_slice(id INTEGER PRIMARY KEY,ts INTEGER,dur INTEGER,cpu INTEGER,utid INTEGER,end_state TEXT);
        INSERT INTO sched_slice VALUES(1,0,100,0,1,'S'),(2,250,100,1,2,'R'),(3,350,50,1,1,'S');
        CREATE TABLE perf_sample(id INTEGER PRIMARY KEY,ts INTEGER,utid INTEGER,cpu INTEGER,callsite_id INTEGER,perf_session_id INTEGER,unwind_error TEXT);
        INSERT INTO perf_sample VALUES(10,100,1,0,10,7,NULL),(11,300,2,1,11,8,NULL);
        CREATE TABLE ftrace_event(id INTEGER PRIMARY KEY,ts INTEGER,name TEXT,cpu INTEGER,utid INTEGER,arg_set_id TEXT);
        INSERT INTO ftrace_event VALUES(20,300,'sched_waking',1,2,'{"pid":101}');
        CREATE TABLE stack_profile_callsite(id INTEGER PRIMARY KEY,parent_id INTEGER,frame_id INTEGER);
        INSERT INTO stack_profile_callsite VALUES(10,12,1),(12,NULL,2),(11,NULL,3);
        CREATE TABLE stack_profile_frame(id INTEGER PRIMARY KEY,name TEXT,mapping INTEGER,rel_pc INTEGER);
        INSERT INTO stack_profile_frame VALUES(1,'wait',1,1),(2,'work',1,2),(3,'wake',2,3);
        CREATE TABLE stack_profile_mapping(id INTEGER PRIMARY KEY,name TEXT,build_id TEXT);
        INSERT INTO stack_profile_mapping VALUES(1,'P','abc'),(2,'Q','def');
        CREATE TABLE stats(name TEXT,severity TEXT,value INTEGER);
        ''')
    def tearDown(self):
        self.db.close()
    def query(self,name,**params):
        from render_sql import render
        return [dict(r) for r in self.db.execute(render(ROOT/'sql'/name,params))]
    def pair(self,**params):
        defaults=dict(utid=1,wait_id=2,switch_session=7,waking_session=8,clock_verified=1,streams_verified=1,tolerance_ns=0)
        defaults.update(params)
        return self.query('05-event-pair.sql',**defaults)[0]
    def test_wait_two_durations_and_cross_cpu(self):
        r=self.query('02-wait-episodes.sql',utid=1,start_ns=0,end_ns=1000)[0]
        self.assertEqual((r['sleep_ns'],r['runnable_ns']),(200,50))
        self.assertEqual((r['switch_cpu'],r['run_cpu']),(0,1))
    def test_incomplete_wait_not_filled(self):
        r=self.query('02-wait-episodes.sql',utid=1,start_ns=0,end_ns=1000)[1]
        self.assertIsNone(r['run_ts']); self.assertNotEqual(r['boundary_status'],'COMPLETE')
    def test_interval_clips_both_ends(self):
        rows=self.query('01-state-window.sql',utid=1,start_ns=90,end_ns=120)
        total={r['state']:r['duration_ns'] for r in rows}
        self.assertEqual(total['Running'],10); self.assertEqual(total['S'],20)
    def test_unknown_duration_not_counted_as_zero(self):
        self.db.execute('UPDATE thread_state SET dur=-1 WHERE id=5')
        r=self.query('01-state-window.sql',utid=1,start_ns=400,end_ns=1000)
        self.assertEqual(r[-1]['state'],'UNKNOWN_COVERAGE')
        self.assertEqual(r[-1]['duration_ns'],600)
    def test_invalid_window_rejected(self):
        with self.assertRaises(ValueError): self.query('01-state-window.sql',utid=1,start_ns=20,end_ns=10)
    def test_competitors_include_other_process(self):
        r=self.query('03-cpu-competitors.sql',cpu=1,start_ns=300,end_ns=400)
        by={v['upid']:v['cpu_ns'] for v in r}
        self.assertEqual(by,{2:50,1:50})
    def test_cross_process_waking_matches(self):
        r=self.pair()
        self.assertEqual(r['switch_status'],'MATCH_UNIQUE')
        self.assertEqual(r['wake_status'],'MATCH_UNIQUE')
        self.assertEqual(r['waker_utid'],2)
    def test_missing_clock_proof(self):
        self.assertEqual(self.pair(clock_verified=0)['switch_status'],'CLOCK_UNVERIFIED')
    def test_missing_stream_proof(self):
        self.assertEqual(self.pair(streams_verified=0)['wake_status'],'SOURCE_UNVERIFIED')
    def test_same_stream_ids_rejected(self):
        self.assertEqual(self.pair(waking_session=7)['wake_status'],'SOURCE_UNVERIFIED')
    def test_wrong_switch_sample_thread(self):
        self.db.execute('UPDATE perf_sample SET utid=2 WHERE id=10')
        self.assertEqual(self.pair()['switch_status'],'SAMPLE_MISSING')
    def test_wrong_sample_cpu(self):
        self.db.execute('UPDATE perf_sample SET cpu=0 WHERE id=11')
        self.assertEqual(self.pair()['wake_status'],'SAMPLE_MISSING')
    def test_wrong_source_not_cpu_sample(self):
        self.db.execute('UPDATE perf_sample SET perf_session_id=9 WHERE id=11')
        self.assertEqual(self.pair()['wake_status'],'SAMPLE_MISSING')
    def test_ambiguous_sample_no_arbitrary_callsite(self):
        self.db.execute('INSERT INTO perf_sample VALUES(12,300,2,1,20,8,NULL)')
        r=self.pair();self.assertEqual(r['wake_status'],'SAMPLE_AMBIGUOUS');self.assertIsNone(r['wake_callsite_id']);self.assertIsNone(r['wake_sample_id'])
    def test_waking_pid_filter(self):
        self.db.execute('UPDATE ftrace_event SET arg_set_id=?',(json.dumps({'pid':999}),))
        self.assertEqual(self.pair()['wake_status'],'WAKE_EVENT_MISSING')
    def test_ambiguous_wake_event(self):
        self.db.execute('INSERT INTO ftrace_event SELECT 21,ts,name,cpu,utid,arg_set_id FROM ftrace_event')
        self.assertEqual(self.pair()['wake_status'],'WAKE_EVENT_AMBIGUOUS')
    def test_irq_context_not_lock_owner(self):
        self.db.execute('UPDATE thread_state SET irq_context=1 WHERE id=3')
        self.assertEqual(self.pair()['wake_status'],'IRQ_CONTEXT')
    def test_unknown_irq_context_not_exact_waker(self):
        self.db.execute('UPDATE thread_state SET irq_context=NULL WHERE id=3')
        self.assertEqual(self.pair()['wake_status'],'CONTEXT_UNKNOWN')
    def test_unwind_error_partial(self):
        self.db.execute("UPDATE perf_sample SET unwind_error='FAILED' WHERE id=10")
        self.assertEqual(self.pair()['switch_status'],'STACK_PARTIAL')
    def test_missing_stack_is_missing(self):
        self.db.execute('UPDATE perf_sample SET callsite_id=NULL WHERE id=11')
        self.assertEqual(self.pair()['wake_status'],'STACK_MISSING')
    def test_no_future_time_reuse(self):
        self.db.execute('UPDATE perf_sample SET ts=301 WHERE id=11')
        self.assertEqual(self.pair()['wake_status'],'SAMPLE_MISSING')
    def test_tolerance_explicit(self):
        self.db.execute('UPDATE perf_sample SET ts=301 WHERE id=11')
        self.assertEqual(self.pair(tolerance_ns=1)['wake_status'],'MATCH_UNIQUE')
    def test_waking_after_resumption_rejected(self):
        self.db.execute('UPDATE ftrace_event SET ts=360')
        self.db.execute('UPDATE perf_sample SET ts=360 WHERE id=11')
        self.assertEqual(self.pair(tolerance_ns=60)['wake_status'],'WAKE_EVENT_MISSING')
    def test_state_boundary_missing_no_pair(self):
        self.db.execute('UPDATE thread_state SET ts=301 WHERE id=3')
        self.assertEqual(self.pair()['wake_status'],'BOUNDARY_INCOMPLETE')
    def test_callstack_walk_includes_ancestor(self):
        r=self.query('06-callstack.sql',callsite_id=10)
        self.assertEqual([v['function_name'] for v in r],['wait','work'])
    def test_chain_does_not_guess_lock_owner(self):
        r=self.query('07-wakeup-links.sql',utid=1,start_ns=0,end_ns=1000)
        self.assertEqual(r[0]['waker_utid'],2)
        self.assertEqual(r[0]['relation'],'SCHEDULING_WAKE_EDGE_NOT_LOCK_OWNERSHIP')

if __name__=='__main__': unittest.main()
