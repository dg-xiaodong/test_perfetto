import copy
import importlib
import math
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))

def event(kind, ts=0, **kw):
    e = dict(contract_version='latency.v1',slice_id=0, kind=kind, ts=ts, dur=0, run_id='r1', stream_id='cam0',
             request_id='100', process_instance_id='p1', stage_id='', stage_instance_id='',
             queue_id='', queue_visit_id='', link_id='', status='', track_id=1,
             thread_utid=None, thread_dur=None, frame_seq=100, object_type='frame')
    e.update(kw)
    return e

def request(r='100', stream='cam0', run='r1', outcome='SUCCESS'):
    es = [event('lat.request.begin', 10),
          event('lat.stage', 20, dur=30, stage_id='infer', stage_instance_id='s1'),
          event('lat.stage.result', 50, stage_id='infer', stage_instance_id='s1', status='SUCCESS'),
          event('lat.request.end', 60, status=outcome, expected_stage_count=1,
                expected_queue_count=0, expected_link_count=0)]
    for i,e in enumerate(es):
        e.update(request_id=r, stream_id=stream, run_id=run, slice_id=i+1)
    return es

class CoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.core = importlib.import_module('latency_core')

    def analyze(self, es, flows=None, **kw):
        return self.core.analyze_records(es, flows or [], trace_bounds=(0,10000), **kw)

    def one(self, es, **kw):
        return self.analyze(es, **kw)['requests'][0]

    def test_complete(self):
        r=self.one(request()); self.assertEqual(r['integrity_status'],'COMPLETE'); self.assertEqual(r['e2e_ns'],50)
    def test_different_streams(self):
        self.assertEqual(len(self.analyze(request()+request(stream='cam1'))['requests']),2)
    def test_restart_namespace(self):
        self.assertEqual(len(self.analyze(request()+request(run='r2'))['requests']),2)
    def test_id_text_not_lossy_float(self):
        self.assertNotEqual(self.core.identity(event('x',request_id='9007199254740993')),
                            self.core.identity(event('x',request_id='9007199254740992')))
    def test_missing_namespace(self):
        es=request(); es[0]['run_id']=''; self.assertGreater(self.analyze(es)['orphan_events'],0)
    def test_duplicate_begin(self):
        es=request(); es.append(copy.deepcopy(es[0])); self.assertEqual(self.one(es)['integrity_status'],'INVALID')
    def test_duplicate_terminal(self):
        es=request(); es.append(copy.deepcopy(es[-1])); self.assertEqual(self.one(es)['integrity_status'],'INVALID')
    def test_no_end_is_not_timeout(self):
        r=self.one(request()[:-1]); self.assertEqual(r['integrity_status'],'INCOMPLETE'); self.assertEqual(r['outcome_status'],'UNKNOWN'); self.assertIsNone(r['e2e_ns'])
    def test_no_begin_not_automatically_censored(self):
        self.assertEqual(self.one(request()[1:])['integrity_status'],'INCOMPLETE')
    def test_censored_requires_witness(self):
        es=request()[1:]+[event('lat.request.boundary',1,boundary='capture_start_in_flight')]
        r=self.one(es); self.assertEqual(r['integrity_status'],'CENSORED'); self.assertFalse(r['eligible'])
    def test_inverse_time(self):
        es=request(); es[-1]['ts']=5; self.assertEqual(self.one(es)['integrity_status'],'INVALID')
    def test_open_stage(self):
        es=request(); es[1]['dur']=-1; self.assertEqual(self.one(es)['integrity_status'],'INCOMPLETE')
    def test_missing_stage_result(self):
        es=request(); del es[2]; self.assertEqual(self.one(es)['integrity_status'],'INCOMPLETE')
    def test_same_stage_multiple_instances(self):
        es=request(); es[-1]['expected_stage_count']=2
        es.extend([event('lat.stage',25,dur=10,stage_id='infer',stage_instance_id='s2',attempt_id=2),event('lat.stage.result',35,stage_id='infer',stage_instance_id='s2',status='SUCCESS')])
        self.assertEqual(self.one(es)['integrity_status'],'COMPLETE')
    def test_duplicate_stage_instance(self):
        es=request(); es.append(copy.deepcopy(es[1])); self.assertEqual(self.one(es)['integrity_status'],'INVALID')
    def test_stage_name_mismatch(self):
        es=request(); es[2]['stage_id']='post'; self.assertEqual(self.one(es)['integrity_status'],'INVALID')
    def test_drop_is_complete_business_outcome(self):
        r=self.one(request(outcome='DROP')); self.assertEqual(r['integrity_status'],'COMPLETE');self.assertFalse(r['eligible']);self.assertEqual(r['outcome_status'],'DROP')
    def test_explicit_timeout(self):
        r=self.one(request(outcome='TIMEOUT'));self.assertEqual(r['outcome_status'],'TIMEOUT');self.assertFalse(r['eligible'])
    def test_quality_loss_no_strict_metrics(self):
        r=self.one(request(),quality_loss=True);self.assertFalse(r['eligible']);self.assertTrue(r['quality_loss'])
    def test_declarations_missing(self):
        es=request();del es[-1]['expected_stage_count'];self.assertEqual(self.one(es)['integrity_status'],'INCOMPLETE')
    def test_declared_missing_stage(self):
        es=request();es[-1]['expected_stage_count']=2;self.assertEqual(self.one(es)['integrity_status'],'INCOMPLETE')
    def test_stage_outside_lifecycle(self):
        es=request();es[1]['ts']=0;self.assertEqual(self.one(es)['integrity_status'],'INVALID')
    def test_negative_nonopen_duration(self):
        es=request();es[1]['dur']=-2;self.assertEqual(self.one(es)['integrity_status'],'INVALID')
    def test_parallel_is_union_not_sum(self):
        self.assertEqual(self.core.union_duration([(0,12),(0,7)]),12)
        self.assertEqual(self.core.union_duration([(0,12),(8,15)]),15)
    def test_clip_crossing_window(self):
        self.assertEqual(self.core.overlap(90,30,100,200),20)
    def test_gap_not_filled(self):
        self.assertEqual(self.core.union_duration([(0,5),(7,10)]),8)
    def test_quantile_definition(self):
        self.assertEqual(self.core.nearest_rank([1,2,3,4],.5),2); self.assertEqual(self.core.nearest_rank([1,2,3,4],.99),4)
    def test_empty_quantile(self):
        self.assertIsNone(self.core.nearest_rank([],.99))
    def test_small_sample_caution(self):
        s=self.analyze(request())['summary'];self.assertEqual(s['success_samples'],1);self.assertTrue(s['tail_sample_warning'])
    def test_no_automatic_critical_path(self):
        self.assertEqual(self.one(request())['critical_path_status'],'NOT_COMPUTED')
    def test_flow_real_edges_only(self):
        es=request(); es[-1]['expected_link_count']=1
        es += [event('lat.send',15,slice_id=10,link_id='L',from_instance='input',to_instance='s1'),event('lat.receive',18,slice_id=11,link_id='L',from_instance='input',to_instance='s1')]
        self.assertEqual(self.one(es)['integrity_status'],'INCOMPLETE')
        r=self.analyze(es,[dict(flow_id=1,slice_out=10,slice_in=11)])['requests'][0]
        self.assertEqual(r['integrity_status'],'COMPLETE')
    def test_flow_different_request_rejected(self):
        es=request()+request(r='101'); es[3]['expected_link_count']=1
        es += [event('lat.send',30,slice_id=10,link_id='L'),event('lat.receive',35,slice_id=11,link_id='L',request_id='101')]
        a=self.analyze(es,[dict(flow_id=1,slice_out=10,slice_in=11)])
        self.assertEqual(a['flows'][0]['status'],'INVALID_IDENTITY')
    def test_flow_time_reversed(self):
        es=request()+[event('lat.send',40,slice_id=10,link_id='L'),event('lat.receive',30,slice_id=11,link_id='L')]
        a=self.analyze(es,[dict(flow_id=1,slice_out=10,slice_in=11)])
        self.assertEqual(a['flows'][0]['status'],'INVALID_TIME')
    def test_flow_wrong_link(self):
        es=request()+[event('lat.send',30,slice_id=10,link_id='A'),event('lat.receive',40,slice_id=11,link_id='B')]
        self.assertEqual(self.analyze(es,[dict(flow_id=1,slice_out=10,slice_in=11)])['flows'][0]['status'],'INVALID_LINK')
    def test_frames_separate_streams(self):
        a=self.analyze(request()+request(stream='cam1')); self.assertEqual(len(a['frame_summary']),2)
    def test_unknown_thread_time_not_zero(self):
        a=self.analyze(request());self.assertIsNone(a['stages'][0]['thread_cpu_ns'])
    def test_no_fps_single_frame(self):
        a=self.analyze(request());self.assertIsNone(a['frame_summary'][0]['output_interval_fps'])
    def test_queue_open(self):
        es=request()+[event('lat.queue',15,dur=-1,queue_id='q',queue_visit_id='q1')];es[3]['expected_queue_count']=1
        self.assertEqual(self.one(es)['integrity_status'],'INCOMPLETE')
    def test_duplicate_queue_id(self):
        es=request()+[event('lat.queue',15,dur=3,queue_id='q',queue_visit_id='q1'),event('lat.queue',19,dur=1,queue_id='q',queue_visit_id='q1')];es[3]['expected_queue_count']=2
        self.assertEqual(self.one(es)['integrity_status'],'INVALID')

class ConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cfg=importlib.import_module('make_config');cls.val=importlib.import_module('validate_config')
    def test_minimal_track_only(self):
        s=self.cfg.generate_config(); self.assertIn('track_event',s);self.assertNotIn('linux.ftrace',s);self.val.check_policy(s)
    def test_sched_requires_events(self):
        with self.assertRaises(ValueError):self.cfg.generate_config(with_sched=True)
    def test_sched_supported(self):
        s=self.cfg.generate_config(with_sched=True,events={'sched/sched_switch','sched/sched_waking'});self.val.check_policy(s)
    def test_bound_duration(self):
        for n in (0,1000000,-1):
            with self.assertRaises(ValueError):self.cfg.generate_config(duration_ms=n)
    def test_memory_bound(self):
        with self.assertRaises(ValueError):self.cfg.generate_config(buffer_kib=1048576)
    def test_duplicate_scalar(self):
        with self.assertRaises(ValueError):self.val.check_policy(self.cfg.generate_config()+'\nduration_ms: 20000')
    def test_unknown_config_field(self):
        with self.assertRaises(ValueError):self.val.check_policy(self.cfg.generate_config()+'\nmade_up: 1')
    def test_category_enable_exact(self):
        self.assertIn('enabled_categories: "rdk.latency"',self.cfg.generate_config())
    def test_category_injection(self):
        with self.assertRaises(ValueError):self.cfg.generate_config(category='a" }')
    def test_no_perf_heap(self):
        for n in ('linux.perf','android.heapprofd'):self.assertNotIn(n,self.cfg.generate_config())

if __name__=='__main__': unittest.main()
