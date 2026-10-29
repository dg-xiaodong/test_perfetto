"""Release preflight: generated heapprofd config must match the launched name."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAKE = ROOT / 'scripts/make_config.py'
VALIDATE = ROOT / 'scripts/validate_config.py'


class ReleasePreflightTests(unittest.TestCase):
    def _config(self, name):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        cfg = pathlib.Path(td.name) / 'native.pbtxt'
        r = subprocess.run([sys.executable, str(MAKE), 'native', '--platform', 'linux',
                            '--process', name, '--duration-ms', '90000',
                            '--dump-ms', '2000'],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        cfg.write_text(r.stdout)
        return cfg

    def test_generated_target_and_duration_match(self):
        cfg = self._config('test-app')
        text = cfg.read_text()
        self.assertIn('process_cmdline: "test-app"', text)
        self.assertIn('duration_ms: 90000', text)
        r = subprocess.run([sys.executable, str(VALIDATE), str(cfg),
                            '--deploy-name', 'test-app'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('[PASS] deploy-name', r.stdout)

    def test_target_mismatch_is_rejected(self):
        cfg = self._config('test-app')
        r = subprocess.run([sys.executable, str(VALIDATE), str(cfg),
                            '--deploy-name', 'other-app'], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('[FAIL] deploy-name', r.stdout)
        self.assertIn('test-app', r.stdout)


if __name__ == '__main__':
    unittest.main()
