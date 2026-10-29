import copy,io,json,os,subprocess,sys,tempfile,unittest
from pathlib import Path
from test_core import event,request
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'scripts'))
from run_query import run
from latency_core import analyze_records
from validate_config import check_policy

class Failures(unittest.TestCase):
    def test_wrong_business_endpoint_rejected(self):
        es=request();es[3]['expected_link_count']=1
        es += [event('lat.send',15,slice_id=10,link_id='L',from_instance='input',to_instance='nonexistent'),event('lat.receive',18,slice_id=11,link_id='L',from_instance='input',to_instance='nonexistent')]
        r=analyze_records(es,[dict(flow_id=1,slice_out=10,slice_in=11)])['requests'][0]
        self.assertEqual(r['integrity_status'],'INVALID')
    def test_no_business_endpoint_does_not_prove_chain(self):
        es=request();es[3]['expected_link_count']=1
        es += [event('lat.send',15,slice_id=10,link_id='L'),event('lat.receive',18,slice_id=11,link_id='L')]
        r=analyze_records(es,[dict(flow_id=1,slice_out=10,slice_in=11)])['requests'][0]
        self.assertEqual(r['integrity_status'],'INCOMPLETE')
    def test_broken_process_flow_scope(self):
        es=request()+[event('lat.send',15,slice_id=10,link_id='L',flow_scope='process',process_instance_id='p1'),event('lat.receive',18,slice_id=11,link_id='L',flow_scope='process',process_instance_id='p2')]
        self.assertEqual(analyze_records(es,[dict(flow_id=1,slice_out=10,slice_in=11)])['flows'][0]['status'],'INVALID_SCOPE')
    def test_mock_tp_failure_has_run_record(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);tp=p/'tp';tp.write_text('#!/bin/sh\nif [ "$1" = --version ];then echo fake-fixture;exit 0;fi\necho ERROR >&2\nexit 7\n');tp.chmod(0o755)
            tr=p/'input';tr.write_text('fixture not trace')
            with self.assertRaises(RuntimeError):run(tp,tr,ROOT/'sql/00-inventory.sql',p/'out')
            r=json.loads((p/'out/run.json').read_text());self.assertEqual(r['returncode'],7);self.assertEqual(len(r['trace_sha256']),64)
    def test_unknown_thread_never_assigned_cpu(self):
        es=request();es[1]['thread_utid']=None;es[1]['thread_dur']=5
        self.assertIsNone(analyze_records(es,[])['stages'][0]['thread_cpu_ns'])
    def test_function_only_workflow(self):
        e=event('slow_function',10,dur=20);e['run_id']=''
        r=analyze_records([e],[]);self.assertEqual(r['summary']['observed_requests'],0);self.assertEqual(r['function_summary'][0]['max_wall_ns'],20)
    def test_small_integer_timeout_not_inferred(self):
        es=request();es[-1]['ts']=9000
        self.assertEqual(analyze_records(es,[])['requests'][0]['outcome_status'],'SUCCESS')
    def test_sql_parser_rejects_duplicate_category_message(self):
        from make_config import generate_config
        s=generate_config().replace('name: "track_event"','name: "track_event"\nname: "track_event"')
        with self.assertRaises(ValueError):check_policy(s)
    def test_explicit_cancel_is_terminal_not_missing(self):
        r=analyze_records(request(outcome='CANCELLED'),[])['requests'][0]
        self.assertEqual(r['integrity_status'],'COMPLETE');self.assertFalse(r['eligible'])
    def test_unknown_outcome_is_invalid_contract(self):
        r=analyze_records(request(outcome='MADE_UP'),[])['requests'][0]
        self.assertEqual(r['integrity_status'],'INVALID')
    def test_quality_suppresses_valid_outputs_not_explicit_drop(self):
        r=analyze_records(request()+request(r='101',outcome='DROP'),[],quality_loss=True)
        self.assertEqual(r['frame_summary'][0]['valid_outputs'],0);self.assertEqual(r['frame_summary'][0]['explicit_drops'],1)
    def test_future_trace_boundary_not_assumed(self):
        es=request()[:-1];es[1]['dur']=-1
        r=analyze_records(es,[],trace_bounds=(0,25))['requests'][0]
        self.assertEqual(r['integrity_status'],'INCOMPLETE')

if __name__=='__main__':unittest.main()

class AnalysisCLITest(unittest.TestCase):
    def test_whole_analysis_mock_transport(self):
        import csv
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);events=request();fields=list(dict.fromkeys(k for e in events for k in e))
            def csvfile(name,cols,rows):
                with (p/name).open('w',newline='') as f:
                    w=csv.DictWriter(f,fieldnames=cols);w.writeheader();w.writerows(rows)
            csvfile('events.csv',fields,events)
            csvfile('inv.csv',['start_ts','end_ts','app_slices'],[dict(start_ts=0,end_ts=10000,app_slices=4)])
            csvfile('flows.csv',['flow_id','slice_out','slice_in'],[])
            csvfile('stats.csv',['name','severity','value'],[])
            csvfile('counters.csv',['ts','value','track_id','name'],[])
            tp=p/'tp'
            tp.write_text('#!'+sys.executable+'''\nimport sys,pathlib
p=pathlib.Path(__file__).parent
if '--version' in sys.argv: print('MOCK_TRANSPORT_NOT_REAL_TP');sys.exit(0)
s=pathlib.Path(sys.argv[sys.argv.index('-f')+1]).read_text()
n='inv.csv' if 'app_slices' in s else 'events.csv' if 'AS slice_id' in s else 'flows.csv' if 'AS flow_id' in s else 'stats.csv' if 'FROM stats' in s else 'counters.csv'
print((p/n).read_text(),end='')
''');tp.chmod(0o755)
            tr=p/'fixture.input';tr.write_text('MOCK transport, not a trace')
            r=subprocess.run([sys.executable,str(ROOT/'scripts/analyze.py'),'--tp',str(tp),'--trace',str(tr),'--out',str(p/'out')],capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
            a=json.loads((p/'out/analysis.json').read_text());self.assertEqual(a['summary']['success_samples'],1)
            self.assertIn('SELECT 10 AS ts,50 AS dur',(p/'out/ui-request-track.sql').read_text())
