import json,shutil,subprocess,sys,tempfile,unittest
from pathlib import Path
R=Path(__file__).resolve().parents[1]
@unittest.skipUnless(sys.platform.startswith('linux') and shutil.which('g++'), 'Linux + g++ required')
class Probe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory();cls.exe=Path(cls.tmp.name)/'schedprobe'
        p=subprocess.run(['g++','-std=c++17','-O1','-g','-pthread','-Wall','-Wextra','-Werror',str(R/'examples/schedprobe.cpp'),'-o',str(cls.exe)],capture_output=True,text=True)
        if p.returncode:raise AssertionError(p.stderr)
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()
    def run_probe(self,mode):
        p=subprocess.run([str(self.exe),mode,'0','30','1'],capture_output=True,text=True,timeout=8)
        self.assertEqual(p.returncode,0,p.stderr+p.stdout)
        rows=[json.loads(l) for l in p.stdout.splitlines()]
        self.assertTrue(any(r['event']=='WAIT_END' for r in rows))
        self.assertTrue(any(r['event']=='WAKE' for r in rows))
        return rows
    def test_condvar_program(self): self.run_probe('c1')
    def test_bounded_competition_program_runs(self):
        self.run_probe('c2')
    def test_cross_process_program(self):
        r=self.run_probe('c3');pids={x['pid'] for x in r}
        self.assertEqual(len(pids),2)
    def test_invalid_args(self):
        p=subprocess.run([str(self.exe),'c1','0','-1','1'],capture_output=True,text=True)
        self.assertNotEqual(p.returncode,0)
