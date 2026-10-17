"""CPU bucket/episode SQL: interval intersection and spike grouping."""
import pathlib
import sqlite3
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load(name, *, upid=7, start=0, end=3000000000, bucket_ns=None, threshold=None):
    text = (ROOT / 'sql' / name).read_text(encoding='utf-8')
    text = text.replace('-1 AS target_upid', f'{upid} AS target_upid')
    text = text.replace('-1 AS start_ts', f'{start} AS start_ts')
    text = text.replace('-1 AS end_ts', f'{end} AS end_ts')
    if bucket_ns is not None:
        text = text.replace('100000000 AS bucket_ns', f'{bucket_ns} AS bucket_ns')
        text = text.replace('1000000000 AS bucket_ns', f'{bucket_ns} AS bucket_ns')
    if threshold is not None:
        text = text.replace('100.0 AS threshold_ms', f'{threshold} AS threshold_ms')
    return text


class CpuSqlTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.executescript('''
          CREATE TABLE trace_bounds(start_ts INT,end_ts INT);
          INSERT INTO trace_bounds VALUES(0,3000000000);
          CREATE TABLE thread(utid INT,tid INT,name TEXT,upid INT);
          INSERT INTO thread VALUES(1,100,'worker',7),(2,101,'other',8);
          CREATE TABLE sched_slice(ts INT,dur INT,utid INT);
        ''')

    def tearDown(self):
        self.db.close()

    def insert(self, ts, dur, utid=1):
        self.db.execute('INSERT INTO sched_slice VALUES(?,?,?)', (ts, dur, utid))

    def test_cross_bucket_200ms_is_100_plus_100(self):
        self.insert(900000000, 200000000)
        self.insert(0, 2500000000, utid=2)  # other UPID must be ignored
        rows = self.db.execute(load('11-cpu-time-buckets.sql', bucket_ns=1000000000)).fetchall()
        # utid, tid, name, upid, ts, bucket, cpu_ms, slices
        self.assertEqual([(r[5], round(r[6])) for r in rows], [(0, 100), (1, 100)])

    def test_200ms_does_not_spike_at_150ms(self):
        self.insert(900000000, 200000000)
        rows = self.db.execute(load('12-cpu-spike-episodes.sql', bucket_ns=1000000000,
                                    threshold=150.0)).fetchall()
        self.assertEqual(rows, [])

    def test_350ms_spikes_in_correct_bucket(self):
        self.insert(1900000000, 350000000)  # 1.9-2.25s: 100ms bucket1 + 250ms bucket2
        rows = self.db.execute(load('12-cpu-spike-episodes.sql', bucket_ns=1000000000,
                                    threshold=150.0)).fetchall()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][2:5], (2, 2, 1))  # first_bucket, last_bucket, count
        self.assertEqual(round(rows[0][5]), 250)    # peak_cpu_ms

    def test_quiet_gap_keeps_two_episodes(self):
        self.insert(0, 200000000)          # bucket 0 high
        self.insert(1100000000, 200000000) # bucket 1 high
        self.insert(3100000000, 200000000) # bucket 3 high; bucket 2 quiet/missing
        rows = self.db.execute(load('12-cpu-spike-episodes.sql', end=4000000000,
                                    bucket_ns=1000000000, threshold=150.0)).fetchall()
        self.assertEqual([(r[2], r[3]) for r in rows], [(0, 1), (3, 3)])

    def test_window_clips_interval(self):
        self.insert(500000000, 1000000000)  # 0.5-1.5s
        rows = self.db.execute(load('11-cpu-time-buckets.sql', start=800000000,
                                    end=1200000000, bucket_ns=100000000)).fetchall()
        self.assertEqual([(r[4], round(r[6])) for r in rows],
                         [(800000000, 100), (900000000, 100), (1000000000, 100), (1100000000, 100)])

    def test_negative_upid_returns_nothing(self):
        self.insert(900000000, 200000000)
        rows = self.db.execute(load('11-cpu-time-buckets.sql', upid=-1,
                                    bucket_ns=1000000000)).fetchall()
        self.assertEqual(rows, [])


if __name__ == '__main__':
    unittest.main()
