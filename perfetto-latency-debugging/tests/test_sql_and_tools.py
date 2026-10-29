"""SQL compatibility against a small SQLite schema is NOT real TP compatibility."""
import csv,hashlib,io,json,os,sqlite3,subprocess,sys,tempfile,unittest,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'scripts'))
from render_sql import render
from prepare_sdk import extract_sdk
from latency_core import analyze_records
from test_core import event,request

class SQLTests(unittest.TestCase):
    def db(self):
        d=sqlite3.connect(':memory:')
        d.create_function('EXTRACT_ARG',2,lambda a,k: json.loads(a or '{}').get(k))
        d.executescript('''CREATE TABLE slice(id INTEGER,name TEXT,category TEXT,ts INTEGER,dur INTEGER,track_id INTEGER,arg_set_id TEXT,thread_dur INTEGER);
CREATE TABLE flow(id INTEGER,slice_out INTEGER,slice_in INTEGER);
CREATE TABLE thread_track(id INTEGER,utid INTEGER);
CREATE TABLE thread_state(utid INTEGER,ts INTEGER,dur INTEGER,state TEXT);
CREATE TABLE trace_bounds(start_ts INTEGER,end_ts INTEGER);
CREATE TABLE sched_slice(ts INTEGER,dur INTEGER,utid INTEGER,cpu INTEGER);
CREATE TABLE counter(ts INTEGER,value REAL,track_id INTEGER);
CREATE TABLE counter_track(id INTEGER,name TEXT,unit TEXT);
CREATE TABLE stats(name TEXT,idx INTEGER,source TEXT,severity TEXT,value INTEGER);
INSERT INTO trace_bounds VALUES(0,10000);
INSERT INTO thread_track VALUES(7,10);
''')
        return d
    def test_all_single_result_sql_accepted_by_fixture_schema(self):
        with self.db() as d:
            for f in sorted((ROOT/'sql').glob('*.sql')):
                with self.subTest(sql=f.name):d.execute(render(f,slice_id=1)).fetchall()
    def test_export_integer_string_ids(self):
        with self.db() as d:
            args={'debug.run_id':'r','debug.stream_id':'camera-1','debug.request_id':'9007199254740993'}
            d.execute('INSERT INTO slice VALUES(1,?,?,?,?,?,?,?)',('lat.request.begin','rdk.latency',10,0,7,json.dumps(args),None))
            c=d.execute(render(ROOT/'sql/01-events.sql'));row=dict(zip([x[0] for x in c.description],c.fetchone()))
            self.assertEqual(row['request_id'],'9007199254740993');self.assertEqual(row['thread_utid'],10)
    def test_overlay_clips(self):
        with self.db() as d:
            d.execute("INSERT INTO slice VALUES(1,'x','rdk.latency',100,100,7,'{}',NULL)")
            d.execute("INSERT INTO thread_state VALUES(10,90,30,'Running')")
            rows=d.execute(render(ROOT/'sql/14-thread-overlay.sql',slice_id=1)).fetchall()
            self.assertIn(('STATE_OVERLAP','Running',20),rows)
    def test_custom_track_has_no_cpu_binding(self):
        with self.db() as d:
            d.execute("INSERT INTO slice VALUES(1,'lat.queue','rdk.latency',100,100,9,'{}',NULL)")
            rows=d.execute(render(ROOT/'sql/14-thread-overlay.sql',slice_id=1)).fetchall()
            self.assertEqual(rows,[('NO_THREAD_BINDING',None,None)])
    def test_render_rejects_injection(self):
        with self.assertRaises(ValueError):render(ROOT/'sql/00-inventory.sql',category="x';DROP TABLE slice;--")
    def test_render_rejects_bool_id(self):
        with self.assertRaises(ValueError):render(ROOT/'sql/14-thread-overlay.sql',slice_id=True)
    def test_no_runtime_overwrite(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)/'existing.sql';p.write_text('sentinel')
            r=subprocess.run([sys.executable,str(ROOT/'scripts/render_sql.py'),str(ROOT/'sql/00-inventory.sql'),'--output',str(p)],capture_output=True)
            self.assertNotEqual(r.returncode,0);self.assertEqual(p.read_text(),'sentinel')

class ExtraInvariantTests(unittest.TestCase):
    def a(self,es,flows=None):return analyze_records(es,flows or [],trace_bounds=(0,10000))
    def test_reject_contract_version(self):
        e=request();e[0]['contract_version']='bad';self.assertEqual(self.a(e)['requests'][0]['integrity_status'],'INVALID')
    def test_invalid_stage_result_before_end(self):
        e=request();e[2]['ts']=30;self.assertEqual(self.a(e)['requests'][0]['integrity_status'],'INVALID')
    def test_queue_outside_request(self):
        e=request()+[event('lat.queue',1,dur=3,queue_id='q',queue_visit_id='1')];e[3]['expected_queue_count']=1
        self.assertEqual(self.a(e)['requests'][0]['integrity_status'],'INVALID')
    def test_positive_thread_cpu_requires_thread_binding(self):
        e=request();e[1]['thread_dur']=8;e[1]['thread_utid']=None
        self.assertIsNone(self.a(e)['stages'][0]['thread_cpu_ns'])
    def test_two_frames_correct_interval_fps(self):
        a=request(r='1');b=request(r='2')
        for e in b:e['ts']+=100;e['frame_seq']=2
        r=self.a(a+b)['frame_summary'][0]
        self.assertEqual(r['output_interval_fps'],10000000.)
    def test_frame_order_reversal_separate_from_drop(self):
        a=request(r='1');b=request(r='2')
        for e in a:e['frame_seq']=2
        for e in b:e['frame_seq']=1;e['ts']+=100
        r=self.a(a+b)['frame_summary'][0]
        self.assertEqual(r['adjacent_order_reversals'],1);self.assertEqual(r['explicit_drops'],0)
    def test_parallel_stage_total_not_e2e(self):
        es=request();es[3]['expected_stage_count']=2
        es += [event('lat.stage',25,dur=10,stage_id='post',stage_instance_id='s2'),event('lat.stage.result',35,stage_id='post',stage_instance_id='s2',status='SUCCESS')]
        r=self.a(es)['requests'][0];self.assertEqual(r['stage_work_wall_sum_ns'],40);self.assertEqual(r['stage_wall_union_ns'],30);self.assertEqual(r['e2e_ns'],50)
    def test_same_stage_attempt_parallel_ids(self):
        es=request();es[3]['expected_stage_count']=2
        es += [event('lat.stage',25,dur=10,stage_id='infer',stage_instance_id='branchB',attempt_id=1),event('lat.stage.result',35,stage_id='infer',stage_instance_id='branchB',status='SUCCESS')]
        self.assertEqual(self.a(es)['requests'][0]['integrity_status'],'COMPLETE')

class DependencyTests(unittest.TestCase):
    def raw(self,names):
        b=io.BytesIO()
        with zipfile.ZipFile(b,'w') as z:
            for n in names:z.writestr(n,b'not a real SDK; extraction fixture only')
        return b.getvalue()
    def test_checksum_rejected_before_extract(self):
        raw=self.raw(['perfetto.h','perfetto.cc'])
        with tempfile.TemporaryDirectory() as t:
            with self.assertRaises(ValueError):extract_sdk(raw,'0'*64,Path(t)/'sdk')
    def test_flat_safe_extraction(self):
        raw=self.raw(['../../perfetto.h','nested/perfetto.cc'])
        with tempfile.TemporaryDirectory() as t:
            dest=Path(t)/'sdk';extract_sdk(raw,hashlib.sha256(raw).hexdigest(),dest)
            self.assertEqual(sorted(p.name for p in dest.iterdir()),['perfetto.cc','perfetto.h'])
    def test_ambiguous_sdk_rejected(self):
        raw=self.raw(['a/perfetto.h','b/perfetto.h','perfetto.cc'])
        with tempfile.TemporaryDirectory() as t:
            with self.assertRaises(ValueError):extract_sdk(raw,hashlib.sha256(raw).hexdigest(),Path(t)/'sdk')
    def test_cmake_missing_sdk_fails(self):
        with tempfile.TemporaryDirectory() as t:
            r=subprocess.run(['cmake','-S',str(ROOT/'examples/cpp'),'-B',t],capture_output=True,text=True)
            self.assertNotEqual(r.returncode,0);self.assertIn('Real Perfetto SDK missing',r.stdout+r.stderr)

class ShellTests(unittest.TestCase):
    def test_shell_syntax(self):
        for f in (ROOT/'scripts').glob('*.sh'):
            self.assertEqual(subprocess.run(['sh','-n',str(f)]).returncode,0)
    def mock(self,mode):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);tb=p/'tracebox';cfg=p/'c.pbtxt';cfg.write_text('duration_ms: 1000')
            tb.write_text('''#!/bin/sh
if [ "$1" = --help ];then echo '--notify-fd --system-sockets --txt';exit 0;fi
out=''
while [ "$#" -gt 0 ];do if [ "$1" = -o ];then out=$2;shift;fi;shift;done
'''+({'ok':"printf '\\000' >&3\nsleep 1\nprintf 'fixture-not-a-trace' > \"$out\"\nexit 0\n",'fail':"exit 3\n",'hang':"trap '' TERM\nsleep 15\n"}[mode]))
            tb.chmod(0o755)
            env=dict(os.environ,TRACEBOX=str(tb),SKIP_TRACEFS_CHECK='1',READY_TIMEOUT_S='2',STOP_TIMEOUT_S='1')
            r=subprocess.run(['sh',str(ROOT/'scripts/record.sh'),str(cfg),str(p/'out'),'4'],env=env,capture_output=True,text=True,timeout=10)
            return r,(p/'out/status.txt').read_text() if (p/'out/status.txt').exists() else ''
    def test_mock_recorder_control_flow(self):
        r,s=self.mock('ok');self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertIn('RECORDED_DATA_UNCHECKED',s)
    def test_mock_recorder_early_exit(self):
        r,s=self.mock('fail');self.assertNotEqual(r.returncode,0)
    def test_pull_rejects_unsafe_host(self):
        r=subprocess.run(['sh',str(ROOT/'scripts/pull.sh'),'-bad','/data','/tmp/no','x'],capture_output=True)
        self.assertNotEqual(r.returncode,0)

class RealIntegrationTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('PERFETTO_SDK_DIR') and os.environ.get('PERFETTO_TP'),'real SDK and Trace Processor not provided; not a board test')
    def test_real_sdk_inprocess_and_tp(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);build=p/'build';tr=p/'app.pftrace';out=p/'analysis'
            subprocess.run(['cmake','-S',str(ROOT/'examples/cpp'),'-B',str(build),'-DPERFETTO_SDK_DIR='+os.environ['PERFETTO_SDK_DIR']],check=True,timeout=60)
            subprocess.run(['cmake','--build',str(build),'--parallel','2'],check=True,timeout=300)
            subprocess.run([str(build/'latency_demo'),'--backend','inprocess','--output',str(tr),'--frames','24','--interval-ms','1'],check=True,timeout=30)
            subprocess.run([sys.executable,str(ROOT/'scripts/analyze.py'),'--tp',os.environ['PERFETTO_TP'],'--trace',str(tr),'--out',str(out)],check=True,timeout=90)
            a=json.loads((out/'analysis.json').read_text());self.assertEqual(a['summary']['observed_requests'],24)
            self.assertEqual(a['summary']['integrity_counts'],{'COMPLETE':24})

if __name__=='__main__':unittest.main()
