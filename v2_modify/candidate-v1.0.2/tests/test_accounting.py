"""SQLite fixtures test arithmetic/scope, NOT Perfetto's parser or stdlib."""
import pathlib
import sqlite3
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]

class AccountingTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.executescript('''
          CREATE TABLE heap_profile_allocation(ts INT,upid INT,heap_name TEXT,callsite_id INT,size INT,count INT);
          CREATE TABLE stack_profile_callsite(id INT,parent_id INT,frame_id INT);
          CREATE TABLE stack_profile_frame(id INT,name TEXT,mapping INT);
          CREATE TABLE stack_profile_mapping(id INT,name TEXT);
          INSERT INTO stack_profile_callsite VALUES(1,NULL,1),(2,1,2),(3,1,3);
          INSERT INTO stack_profile_frame VALUES(1,'main',1),(2,'pool',1),(3,'churn',1);
          INSERT INTO stack_profile_mapping VALUES(1,'memprobe');
          INSERT INTO heap_profile_allocation VALUES
            (100,10,'libc.malloc',2,100,1),
            (200,10,'libc.malloc',2,50,1),
            (200,10,'libc.malloc',3,40,1),
            (200,10,'libc.malloc',3,-40,-1),
            (300,10,'libc.malloc',2,-80,-1),
            (150,20,'libc.malloc',2,9999,1),
            (200,10,'other.heap',2,8888,1);
        ''')

    def tearDown(self): self.db.close()

    def sql(self, name, start=0, end=1000):
        text=(ROOT/'sql'/name).read_text()
        return text.replace('-1 AS target_upid','10 AS target_upid').replace('0 AS start_ts',f'{start} AS start_ts').replace('9223372036854775807 AS end_ts',f'{end} AS end_ts')

    def test_native_live_signed_and_scoped(self):
        rows=self.db.execute(self.sql('03-native-live.sql')).fetchall()
        self.assertEqual([r[0] for r in rows],[100,200,300])
        self.assertEqual([round(r[1]*1048576) for r in rows],[100,150,70])

    def test_display_window_keeps_prefix_baseline(self):
        rows=self.db.execute(self.sql('03-native-live.sql',start=200)).fetchall()
        self.assertEqual(round(rows[0][1]*1048576),150)

    def test_native_callstacks_scope_and_window(self):
        rows=self.db.execute(self.sql('04-native-callstacks.sql',start=200,end=300)).fetchall()
        values={r[2]:r[-2:] for r in rows}
        self.assertEqual(values['main'],(70,90))
        self.assertEqual(values['pool'],(70,50))
        self.assertEqual(values['churn'],(0,40))

    def test_negative_upid_template_does_not_analyze_wrong_process(self):
        q=(ROOT/'sql/03-native-live.sql').read_text()
        self.assertEqual(self.db.execute(q).fetchall(),[])

    def test_rss_absolute_counter_not_sum(self):
        self.db.executescript('CREATE TABLE rss(ts INT,size INT); INSERT INTO rss VALUES(1,4096),(2,1000000),(3,4096);')
        self.assertEqual(self.db.execute('SELECT MAX(size) FROM rss').fetchone()[0],1000000)
        self.assertNotEqual(self.db.execute('SELECT SUM(size) FROM rss').fetchone()[0],1000000)

    def test_art_snapshot_scope(self):
        self.db.executescript('''CREATE TABLE android_heap_graph_class_aggregation(
          upid INT,graph_sample_ts INT,type_name TEXT,size_bytes INT,
          obj_count INT,reachable_obj_count INT,native_size_bytes INT);
          INSERT INTO android_heap_graph_class_aggregation VALUES
          (10,100,'com.example.app.MainActivity',1000,1,1,0),
          (10,200,'com.example.app.MainActivity',2000,2,2,0),
          (20,200,'com.example.app.MainActivity',9000,9,9,0);''')
        q=self.sql('06-art-snapshots.sql')
        q='\n'.join(l for l in q.splitlines() if not l.startswith('INCLUDE PERFETTO MODULE'))
        rows=self.db.execute(q).fetchall()
        self.assertEqual([round(r[1]*1048576) for r in rows],[1000,2000])
        self.assertEqual([r[3] for r in rows],[1,2])

if __name__ == '__main__': unittest.main()
