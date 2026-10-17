import pathlib,subprocess,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class ShellTests(unittest.TestCase):
    def test_shell_syntax(self):
        for name in ['host_pull.sh','linux_session_lib.sh','linux_trace_session.sh','survey.sh']:
            r=subprocess.run(['sh','-n',str(ROOT/'scripts'/name)],capture_output=True,text=True)
            self.assertEqual(r.returncode,0,f'{name}: {r.stderr}')
    def test_legacy_script_hashes_match_frozen_memory_release(self):
        # SHA-256 for exact copied scripts in Memory Skill v1.0.2 commit 0fa17e08...
        import hashlib
        expected={'linux_trace_session.sh':'e5d959ad9ebde94abc0f0029fc4da789b8fa81bfefa1c2d8e830f0a122a9b0e7',
                  'linux_session_lib.sh':'09e32bb47439efbf4f0c03d329841a3bf4c1e2005429d5d6183c27650e6a778c',
                  'host_pull.sh':'220a641784a6c101db38823080893b96ef93801230c046b346a3bb16d213205b'}
        for name,sha in expected.items():
            self.assertEqual(hashlib.sha256((ROOT/'scripts'/name).read_bytes()).hexdigest(),sha,name)
if __name__=='__main__':unittest.main()
