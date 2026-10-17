"""Target-candidate SQL: path names, same-name helper process, ambiguity."""
import pathlib
import sqlite3
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MARK = '[CANDIDATES]'


def sql(path, marker=None, name=None):
    text = (ROOT / 'sql' / path).read_text(encoding='utf-8')
    if marker:
        block = text.split(marker, 1)[1]
        text = '-- ' + block
    if name:
        text = text.replace("'memprobe' AS target_name", f"'{name}' AS target_name")
    return text


SCHEMA = """
CREATE TABLE process(upid INT,pid INT,name TEXT,start_ts INT,end_ts INT);
CREATE TABLE heap_profile(ts INT,ts_end INT,dur INT,upid INT,heap_name TEXT);
CREATE TABLE heap_profile_allocation(ts INT,upid INT,heap_name TEXT,callsite_id INT,count INT,size INT);
"""


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.executescript(SCHEMA)
        self.db.executescript("""
          INSERT INTO process VALUES
            (1,100,'/data/memprobe',0,10),(2,101,'./memprobe',0,10),(3,200,'other',0,10);
          INSERT INTO heap_profile VALUES (1,3,2,1,'libc.malloc');
          INSERT INTO heap_profile_allocation VALUES
            (1,1,'libc.malloc',10,1,100),(2,1,'libc.malloc',10,1,50),(3,1,'libc.malloc',10,1,-50);
          INSERT INTO heap_profile_allocation VALUES (2,3,'libc.malloc',10,1,9999);
        """)

    def tearDown(self): self.db.close()

    def test_path_name_matches_and_counts(self):
        rows = self.db.execute(sql('00-inventory.sql', MARK)).fetchall()
        by = {r[0]: r for r in rows}
        self.assertIn(1, by)                    # '/data/memprobe' matched via basename
        self.assertIn(2, by)                    # helper process with same cmdline
        self.assertEqual(by[1][3], 3)           # alloc_rows
        self.assertEqual(by[1][5], 3)           # activity_dumps
        self.assertEqual(by[1][7], 1)           # data_bearing
        self.assertEqual(by[2][7], 0)           # helper not data-bearing
        self.assertEqual(by[1][8], 0)           # ambiguous: only one data-bearing

    def test_ambiguity_flag(self):
        self.db.execute("INSERT INTO process VALUES (4,102,'/tmp/memprobe',0,10)")
        self.db.execute("INSERT INTO heap_profile_allocation VALUES (2,4,'libc.malloc',10,1,777)")
        rows = self.db.execute(sql('00-inventory.sql', MARK, 'memprobe')).fetchall()
        self.assertEqual({r[0] for r in rows}, {1, 2, 4})
        self.assertEqual(rows[0][8], 1)         # two data-bearing candidates -> ambiguous

    def test_unresolved_placeholder_is_not_no_allocation(self):
        rows = self.db.execute(sql('03-native-live.sql')).fetchall()
        self.assertEqual(rows, [])              # -1 placeholder returns nothing
        self.assertIn('不代表', (ROOT / 'sql' / '03-native-live.sql').read_text(encoding='utf-8'))

    def test_user_specified_upid_is_kept(self):
        text = sql('03-native-live.sql').replace('-1 AS target_upid', '1 AS target_upid')
        rows = self.db.execute(text).fetchall()
        self.assertEqual(rows[-1][1], 100 / 1048576.0)


if __name__ == '__main__':
    unittest.main()
