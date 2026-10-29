"""Dump capability SQL: visible dumps, zero-width windows, v57.1 fallback."""
import pathlib
import sqlite3
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
FILE = ROOT / 'sql' / '10-native-dump-capability.sql'


def statements():
    text = FILE.read_text(encoding='utf-8')
    lines = [l for l in text.splitlines() if not l.lstrip().startswith('--')]
    out, buf, inq = [], [], False
    nl = chr(10)
    for ch in nl.join(lines):
        if ch == "'":
            inq = not inq
        if ch == ';' and not inq:
            p = ''.join(buf).strip()
            if p:
                out.append(p)
            buf = []
        else:
            buf.append(ch)
    p = ''.join(buf).strip()
    if p:
        out.append(p)
    return out


class CapabilityTests(unittest.TestCase):
    def _db(self, with_heap_profile=True):
        db = sqlite3.connect(':memory:')
        db.execute('CREATE TABLE heap_profile_allocation(ts INT,upid INT,heap_name TEXT,callsite_id INT,count INT,size INT)')
        if with_heap_profile:
            db.execute('CREATE TABLE heap_profile(ts INT,ts_end INT,dur INT,upid INT,heap_name TEXT)')
            for t in (3, 5, 7, 9, 11, 13):
                db.execute('INSERT INTO heap_profile VALUES (?,?,?,?,?)', (t - 2, t, 0, 1, 'libc.malloc'))
        for t in (3, 5, 7, 9, 11, 13):
            db.execute('INSERT INTO heap_profile_allocation VALUES (?,?,?,?,?,?)', (t, 1, 'libc.malloc', 10, 1, 4096))
            db.execute('INSERT INTO heap_profile_allocation VALUES (?,?,?,?,?,?)', (t, 1, 'libc.malloc', 10, -1, -4096))
        return db

    def test_v582_axis_reports_zero_width(self):
        db = self._db(); st = statements()
        rows = db.execute(st[2].replace('-1 AS target_upid', '1 AS target_upid')).fetchall()
        self.assertEqual(rows[0][0], 6)   # dumps
        self.assertEqual(rows[0][1], 6)   # distinct ts_end
        self.assertEqual(rows[0][2], 6)   # zero-width dumps
        db.close()

    def test_axis_rows(self):
        db = self._db(); st = statements()
        rows = db.execute(st[1].replace('-1 AS target_upid', '1 AS target_upid')).fetchall()
        self.assertEqual(len(rows), 6)
        self.assertEqual(rows[0][2], 0)   # dur
        self.assertEqual(rows[0][5], 2)   # alloc_rows per dump
        db.close()

    def test_v571_fallback_without_heap_profile(self):
        db = self._db(with_heap_profile=False); st = statements()
        rows = db.execute(st[3].replace('-1 AS target_upid', '1 AS target_upid')).fetchall()
        self.assertEqual(rows[0][0], 6)        # activity_dumps
        self.assertEqual(rows[0][3], 4096 * 6)  # alloc_bytes (col 2 is MAX(ts))
        db.close()


if __name__ == '__main__':
    unittest.main()
