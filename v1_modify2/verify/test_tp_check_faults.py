#!/usr/bin/env python3
"""tp_check.py 的故障注入测试：不接真实 TP，用假 runner 验证"异常不得 PASS"。

覆盖：
  - A 候选查询返回空
  - A live 返回负值
  - A dump 数错误（summary/axis 与真实不符）
  - 某条查询 returncode != 0
  - sql/10 关键值错误（zero_dur_dumps 不是全零宽）
  - 同名辅助进程被误算成有数据
  - 正常 A/B 正例仍然 PASS
"""
import contextlib, io, pathlib, tempfile, unittest

HERE = pathlib.Path(__file__).resolve().parent
SKILL = HERE.parent / 'candidate-v1.0.1'
import importlib.util
spec = importlib.util.spec_from_file_location('tp_check', HERE / 'tp_check.py')
tp_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tp_check)

A, B = 'A', 'B'

def base_rows(tag):
    upid, pid = ('191', '1062') if tag == A else ('192', '1123')
    n = 1 if tag == A else 6
    rows = {
        'candidates': [[upid, pid, '/data/memprobe', str(n * 4), str(n * 2), str(n), str(n), '1', '0'],
                       ['193' if tag == A else '194', '1065', '/data/memprobe', '0', '0', '0', '0', '0', '0']],
        'tables': [['heap_profile'], ['heap_profile_allocation']],
        'axis': [[str(100 + i), str(100 + i), '0', upid, 'libc.malloc', '4'] for i in range(n)],
        'summary': [[str(n), str(n), str(n), '100', str(100 + n)]],
        'fallback': [[str(n), '100', str(100 + n),
                      '29360128' if tag == A else '29605888',
                      '29360128' if tag == A else '29605888']],
        'live': [['100', '0.0', 'series']] if tag == A else
                [[str(100 + i), v, 'series'] for i, v in enumerate(['8.0', '8.0', '8.0', '0.0', '0.0', '0.0'])],
    }
    return rows

def make_runner(overrides=None, rc_fail=None):
    overrides = overrides or {}
    def runner(tp, trace, sql):
        tag = A if 'A_no_tick' in str(trace) else B
        key = None
        for k, marker in (('candidates', 'data_bearing'), ('tables', 'sqlite_master'),
                          ('summary', 'zero_dur_dumps'), ('fallback', 'activity_dumps'),
                          ('axis', 'alloc_rows'), ('live', 'live estimate')):
            if marker in sql:
                key = k
                break
        if rc_fail == (tag, key):
            return [], 1, 'injected failure'
        if key is None:
            return [], 1, 'unexpected sql in fake runner'
        return overrides.get((tag, key), base_rows(tag)[key]), 0, ''
    return runner

class FaultTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = pathlib.Path(self.tmp.name)
        for name in ('x5_heapprofd_A_no_tick.pftrace', 'x5_heapprofd_B_tick_200ms.pftrace'):
            (d / name).write_bytes(b'')

    def tearDown(self):
        self.tmp.cleanup()

    def _run(self, runner):
        with contextlib.redirect_stdout(io.StringIO()):
            return tp_check.evaluate('tp', SKILL, self.tmp.name, runner=runner)

    def test_normal_passes(self):
        self.assertEqual(self._run(make_runner()), 0)

    def test_a_candidates_empty_fails(self):
        self.assertGreater(self._run(make_runner({(A, 'candidates'): []})), 0)

    def test_a_negative_live_fails(self):
        self.assertGreater(self._run(make_runner({(A, 'live'): [['100', '-1.0', 's']]})), 0)

    def test_a_wrong_dump_count_fails(self):
        self.assertGreater(self._run(make_runner({(A, 'summary'): [['2', '2', '2', '100', '200']]})), 0)

    def test_a_wrong_axis_count_fails(self):
        self.assertGreater(self._run(make_runner({(A, 'axis'): [['1', '1', '0', '191', 'libc.malloc', '4'],
                                                          ['2', '2', '0', '191', 'libc.malloc', '4']]})), 0)

    def test_rc_error_fails(self):
        self.assertGreater(self._run(make_runner(rc_fail=(A, 'live'))), 0)

    def test_zero_dur_wrong_fails(self):
        self.assertGreater(self._run(make_runner({(B, 'summary'): [['6', '6', '0', '100', '600']]})), 0)

    def test_bad_ts_fails(self):
        self.assertGreater(self._run(make_runner({(A, 'live'): [['not-a-timestamp', '0.0', 's']]})), 0)

    def test_missing_series_column_fails(self):
        self.assertGreater(self._run(make_runner({(A, 'live'): [['100', '0.0']]})), 0)

    def test_unsorted_ts_fails(self):
        self.assertGreater(self._run(make_runner(
            {(B, 'live'): [['101', '8.0', 's'], ['100', '8.0', 's'], ['102', '8.0', 's'],
                           ['103', '0.0', 's'], ['104', '0.0', 's'], ['105', '0.0', 's']]})), 0)

    def test_ts_not_matching_axis_fails(self):
        self.assertGreater(self._run(make_runner({(A, 'live'): [['999', '0.0', 's']]})), 0)

    def test_empty_series_fails(self):
        self.assertGreater(self._run(make_runner({(A, 'live'): [['100', '0.0', '  ']]})), 0)

    def test_helper_with_data_fails(self):
        cand = base_rows(A)['candidates']
        cand[1][3] = '9'
        self.assertGreater(self._run(make_runner({(A, 'candidates'): cand})), 0)

if __name__ == '__main__':
    unittest.main()
