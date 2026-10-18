"""Optional real Trace Processor check. Never substitute a fixture for real TP.
TP_BINARY=/abs/trace_processor_shell TP_TRACE=/abs/trace.pftrace python3 -m unittest discover -s tests
Existing trace is read-only; queries are inventory only. Event pairing needs C1-C3 traces.
"""
import os,subprocess,unittest
from pathlib import Path
R=Path(__file__).resolve().parents[1]
@unittest.skipUnless(os.environ.get('TP_BINARY') and os.environ.get('TP_TRACE'), 'real TP_BINARY and TP_TRACE not supplied')
class RealTP(unittest.TestCase):
    def test_real_inventory_queries(self):
        for name in ('00-threads.sql','00a-bounds.sql','00b-quality.sql','00c-schema.sql','08-perf-streams.sql'):
            with self.subTest(query=name):
                p=subprocess.run([os.environ['TP_BINARY'],'query','-f',str(R/'sql'/name),os.environ['TP_TRACE']],capture_output=True,text=True,timeout=60)
                self.assertEqual(p.returncode,0,p.stderr)
