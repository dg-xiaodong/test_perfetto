import csv,json,os,subprocess,sys,tempfile,unittest
from pathlib import Path
R=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(R/'scripts'))

class Utilities(unittest.TestCase):
    def test_latency_includes_queue(self):
        from request_latency import measure
        r=measure({'request_id':'a','utid':'1','enq_ns':'0','start_ns':'150000000','end_ns':'180000000'})
        self.assertEqual(r['queue_ns'],150000000)
        self.assertEqual(r['processing_ns'],30000000)
        self.assertEqual(r['total_ns'],180000000)
    def test_latency_invalid_order(self):
        from request_latency import measure
        with self.assertRaises(ValueError):measure({'request_id':'a','utid':'1','enq_ns':'10','start_ns':'5','end_ns':'20'})
    def test_latency_clock_ack_required(self):
        p=subprocess.run([sys.executable,str(R/'scripts/request_latency.py'),'x.csv'],capture_output=True,text=True)
        self.assertNotEqual(p.returncode,0)
    def test_resource_missing_detected(self):
        from validate_config import check_resources
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'RESOURCE_LIST.json').write_text('["sql/05-event-pair.sql"]')
            with self.assertRaises(ValueError):check_resources(root)
    def test_descriptor_identity_before_parse(self):
        from validate_config import validate_schema
        with tempfile.TemporaryDirectory() as d:
            d=Path(d);(d/'p').write_bytes(b'x');(d/'m').write_text('{"sha256":"wrong","collector_version":"v58.2"}')
            with self.assertRaisesRegex(ValueError,'hash mismatch'):validate_schema('',d/'p',d/'m','v58.2')
    def test_render_injection_rejected(self):
        from render_sql import render
        with self.assertRaises(ValueError):render(R/'sql/03-cpu-competitors.sql',{'cpu':'0; DROP TABLE thread'})
    def test_all_shell_syntax(self):
        for f in (R/'scripts').glob('*.sh'):
            p=subprocess.run(['sh','-n',str(f)],capture_output=True,text=True)
            self.assertEqual(p.returncode,0,str(f)+p.stderr)

class Lifecycle(unittest.TestCase):
    def run_case(self,mode):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d);fake=d/'tracebox'
            fake.write_text('#!'+sys.executable+'\n'+r'''
import os,sys,time,signal
if '--help' in sys.argv:
    print('--txt --notify-fd');sys.exit(0)
mode=os.environ['FAKE_MODE']
if mode=='early': sys.exit(7)
fd=int(sys.argv[sys.argv.index('--notify-fd')+1])
if mode!='no-notify': os.write(fd,b'\x01' if mode=='bad-notify' else b'\x00')
out=sys.argv[sys.argv.index('-o')+1]
if mode!='empty': open(out,'wb').write(b'mock trace, not actual perfetto data')
if mode in ('timeout','no-notify'):time.sleep(60)
if mode=='error':sys.exit(7)
'''.replace("b'\\x01'", "b'\x01'").replace("b'\\x00'", "b'\x00'"))
            # Above literal conversion is kept textual in the generated Python script.
            fake.write_text(fake.read_text().replace('\x00','\\x00').replace('\x01','\\x01'))
            fake.chmod(0o755)
            env=os.environ.copy();env.update(TRACEBOX=str(fake),FAKE_MODE=mode,READY_TIMEOUT_S='1',STOP_TIMEOUT_S='1',SKIP_TRACEFS_CHECK='1')
            p=subprocess.run(['sh',str(R/'scripts/record.sh'),str(R/'configs/overview.pbtxt'),str(d/'out'),'2'],env=env,text=True,capture_output=True,timeout=12)
            status=(d/'out/status.txt').read_text() if (d/'out/status.txt').exists() else ''
            return p,status
    def test_capture_ok(self):
        p,s=self.run_case('ok');self.assertEqual(p.returncode,0,p.stdout+p.stderr);self.assertIn('DATA_UNCHECKED',s)
    def test_capture_nonzero(self):
        p,s=self.run_case('error');self.assertNotEqual(p.returncode,0);self.assertNotIn('RECORDED_',s)
    def test_capture_empty(self):
        p,s=self.run_case('empty');self.assertNotEqual(p.returncode,0);self.assertIn('EMPTY',s)
    def test_capture_timeout_not_success(self):
        p,s=self.run_case('timeout');self.assertEqual(p.returncode,10,p.stdout+p.stderr);self.assertIn('TIMEOUT',s)
    def test_capture_early_failure(self):
        p,s=self.run_case('early');self.assertNotEqual(p.returncode,0);self.assertNotIn('RECORDED_',s)
    def test_no_notify_timeout(self):
        p,s=self.run_case('no-notify');self.assertNotEqual(p.returncode,0);self.assertIn('NOT_READY',s)
    def test_failure_notify(self):
        p,s=self.run_case('bad-notify');self.assertNotEqual(p.returncode,0);self.assertIn('NOT_READY',s)

if __name__=='__main__':unittest.main()
