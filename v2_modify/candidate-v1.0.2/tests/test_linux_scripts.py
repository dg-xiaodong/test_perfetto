"""Contract tests for generic Linux session scripts (mock tracebox)."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = [
    ROOT / 'scripts/linux_session_lib.sh',
    ROOT / 'scripts/linux_trace_session.sh',
    ROOT / 'scripts/linux_heapprofd_session.sh',
    ROOT / 'scripts/host_pull.sh',
]


class LinuxScriptTests(unittest.TestCase):
    def test_shell_syntax(self):
        for p in SCRIPTS:
            r = subprocess.run(['sh', '-n', str(p)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, f'{p}: {r.stderr}')

    def test_mock_lifecycle_and_pull(self):
        r = subprocess.run(['sh', str(ROOT / 'tests/mock_linux_sessions.sh')],
                           cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn('PASS: linux_trace_session normal', r.stdout)
        self.assertIn('PASS: linux_trace_session timeout kept + non-zero', r.stdout)
        self.assertIn('PASS: linux_heapprofd_session', r.stdout)
        self.assertIn('PASS: short duration rejected', r.stdout)
        self.assertIn('PASS: host_pull failure propagated', r.stdout)


if __name__ == '__main__':
    unittest.main()
