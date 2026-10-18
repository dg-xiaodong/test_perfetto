"""SQLite synthetic regressions; do not represent real TP execution."""
import pathlib
import sqlite3
import unittest

ROOT=pathlib.Path(__file__).resolve().parents[1]

def sql(name, upid=7, start=0,end=4000000000,bucket=1000000000,threshold=150):
    s=(ROOT/'sql'/name).read_text()
    s=s.replace('-1 AS target_upid',f'{upid} AS target_upid')
    s=s.replace('-1 AS start_ts',f'{start} AS start_ts')
    s=s.replace('-1 AS end_ts',f'{end} AS end_ts')
    s=s.replace('1000000000 AS bucket_ns',f'{bucket} AS bucket_ns')
    s=s.replace('100000000 AS bucket_ns',f'{bucket} AS bucket_ns')
    s=s.replace('100.0 AS threshold_ms',f'{threshold} AS threshold_ms')
    return s

class CpuSQLTests(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:')
        self.db.executescript('''
          CREATE TABLE trace_bounds(start_ts INT,end_ts INT);
          INSERT INTO trace_bounds VALUES(0,4000000000);
          CREATE TABLE thread(utid INT,tid INT,name TEXT,upid INT);
          INSERT INTO thread VALUES(1,21,'worker',7),(2,22,'other',8);
          CREATE TABLE sched_slice(id INTEGER PRIMARY KEY,ts INT,dur INT,utid INT,cpu INT);
          CREATE TABLE thread_state(utid INT,ts INT,dur INT,state TEXT,io_wait INT,blocked_function TEXT,waker_utid INT,irq_context INT);
          CREATE TABLE cpu_counter_track(id INT,name TEXT,cpu INT,unit TEXT);
          CREATE TABLE counter(track_id INT,ts INT,value REAL);
          CREATE TABLE process(upid INT,pid INT,name TEXT);
          CREATE TABLE stats(name TEXT,value INT,severity TEXT);
        ''')
    def tearDown(self):self.db.close()
    def add(self,ts,dur,utid=1):
        self.db.execute('INSERT INTO sched_slice(ts,dur,utid,cpu) VALUES(?,?,?,0)',(ts,dur,utid))

    def test_bucket_splits_across_boundary(self):
        self.add(900000000,200000000)
        self.add(0,3500000000,2)
        rows=self.db.execute(sql('05-cpu-time-buckets.sql')).fetchall()
        self.assertEqual([(r[5],round(r[6])) for r in rows],[(0,100),(1,100)])

    def test_200ms_not_false_spike_at_150(self):
        self.add(900000000,200000000)
        self.assertEqual(self.db.execute(sql('06-cpu-spike-episodes.sql')).fetchall(),[])

    def test_350ms_crossing_only_right_bucket_spikes(self):
        self.add(1900000000,350000000)
        rows=self.db.execute(sql('06-cpu-spike-episodes.sql')).fetchall()
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0][2:5],(2,2,1))
        self.assertEqual(round(rows[0][5]),250)

    def test_quiet_gap_separates_episodes(self):
        self.add(0,200000000);self.add(1100000000,200000000);self.add(3100000000,200000000)
        rows=self.db.execute(sql('06-cpu-spike-episodes.sql')).fetchall()
        self.assertEqual([(r[2],r[3]) for r in rows],[(0,1),(3,3)])

    def test_window_clipping(self):
        self.add(500000000,1000000000)
        rows=self.db.execute(sql('01-cpu-usage.sql',start=800000000,end=1200000000)).fetchall()
        self.assertEqual(round(rows[0][3]),400)

    def test_thread_states_running_vs_runnable(self):
        self.db.execute("INSERT INTO thread_state VALUES(1,0,100000000,'Running',NULL,NULL,NULL,NULL)")
        self.db.execute("INSERT INTO thread_state VALUES(1,100000000,400000000,'R',NULL,NULL,NULL,NULL)")
        self.db.execute("INSERT INTO thread_state VALUES(1,500000000,500000000,'S',NULL,NULL,NULL,NULL)")
        rows=self.db.execute(sql('02-thread-states.sql')).fetchall()
        by={r[3]:r[5] for r in rows}
        self.assertEqual(by,{'Running':100,'R':400,'S':500})

    def test_runnable_longest(self):
        self.db.execute("INSERT INTO thread_state VALUES(1,0,100000000,'S',NULL,NULL,NULL,NULL)")
        self.db.execute("INSERT INTO thread_state VALUES(1,100000000,20000000,'R',NULL,NULL,2,NULL)")
        self.db.execute("INSERT INTO thread_state VALUES(2,0,500000000,'R',NULL,NULL,1,NULL)")
        rows=self.db.execute(sql('03-runnable-latency.sql')).fetchall()
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0][5],20)

    def test_freq_state_semantics(self):
        self.db.execute("INSERT INTO cpu_counter_track VALUES(1,'cpufreq',0,'kHz')")
        self.db.execute("INSERT INTO cpu_counter_track VALUES(2,'cpuidle',0,'')")
        self.db.execute('INSERT INTO counter VALUES(1,100,1200000)')
        self.db.execute('INSERT INTO counter VALUES(2,200,4294967295)')
        rows=self.db.execute((ROOT/'sql/04-cpu-frequency.sql').read_text()).fetchall()
        self.assertEqual(rows[0][5],1200.0)          # kHz -> MHz
        self.assertEqual(rows[0][6],'frequency')
        self.assertEqual(rows[1][6],'not-idle')
        self.assertEqual(rows[0][2],'kHz')           # raw unit exposed

    def test_per_core_busy_filters_idle(self):
        self.add(0,1000000000)
        self.db.execute("INSERT INTO thread VALUES(3,0,'swapper/0',NULL)")
        self.add(0,1000000000,3)
        rows=self.db.execute((ROOT/'sql/08-core-busy.sql').read_text()).fetchall()
        self.assertEqual(rows,[(0,1000.0,25.0)])

    def test_no_upid_no_rows(self):
        self.add(100000000,200000000)
        self.assertEqual(self.db.execute(sql('01-cpu-usage.sql',upid=-1)).fetchall(),[])

class InventoryAndFrequencyGateTests(unittest.TestCase):
    """Regression for v0.1.0-r1 fixes 1 (single-statement inventory) and 3 (freq gate)."""

    FULL_SCHEMA = """
      CREATE TABLE trace_bounds(start_ts INT,end_ts INT);
      INSERT INTO trace_bounds VALUES(0,4000000000);
      CREATE TABLE process(upid INT,pid INT,name TEXT);
      INSERT INTO process VALUES(7,700,'worker_app'),(8,800,'other_app');
      CREATE TABLE thread(utid INT,tid INT,name TEXT,upid INT);
      INSERT INTO thread VALUES(1,21,'worker',7),(2,22,'other',8);
      CREATE TABLE sched_slice(id INTEGER PRIMARY KEY,ts INT,dur INT,utid INT,cpu INT);
      INSERT INTO sched_slice VALUES(1,0,300000000,1,1),(2,1000000000,50000000,2,2);
      CREATE TABLE thread_state(utid INT,ts INT,dur INT,state TEXT,io_wait INT,blocked_function TEXT,waker_utid INT,irq_context INT);
      INSERT INTO thread_state VALUES(1,0,300000000,'Running',NULL,NULL,NULL,NULL);
      INSERT INTO thread_state VALUES(1,300000000,700000000,'S',NULL,NULL,NULL,NULL);
      CREATE TABLE cpu_counter_track(id INT,name TEXT,cpu INT,unit TEXT);
      CREATE TABLE counter(track_id INT,ts INT,value REAL);
      CREATE TABLE stats(name TEXT,value INT,severity TEXT);
    """

    def db(self):
        d=sqlite3.connect(':memory:'); d.executescript(self.FULL_SCHEMA); return d

    def run_sql(self, d, name):
        return d.execute((ROOT/'sql'/name).read_text()).fetchall()

    def test_inventory_files_are_single_statement(self):
        import re
        for p in sorted((ROOT/'sql').glob('*.sql')):
            with self.subTest(sql=p.name):
                t=p.read_text()
                t=re.sub(r'--[^\n]*','',t)                 # line comments
                t=re.sub(r'/\*.*?\*/','',t,flags=re.S)     # block comments
                t=re.sub(r"'(?:[^']|'')*'","''",t)           # string literals
                body=t.strip().rstrip(';').strip()
                self.assertEqual(body.count(';'),0,
                                 f'{p.name}: multi-statement file breaks query -f on TP v57.1/v58.2')
                self.assertNotEqual(body,'',f'{p.name}: empty SQL')

    def test_inventory_process_ranking(self):
        d=self.db()
        rows=self.run_sql(d,'00-inventory.sql')
        self.assertEqual(len(rows),2)
        self.assertEqual(rows[0][0],7)          # upid
        self.assertEqual(rows[0][5],300.0)      # cpu_ms
        d.close()

    def test_inventory_companion_files(self):
        d=self.db()
        self.assertEqual(self.run_sql(d,'00a-trace-bounds.sql')[0][2],4.0)
        self.assertIn(('Running',1),self.run_sql(d,'00b-thread-states.sql'))
        self.assertEqual(self.run_sql(d,'00c-counter-tracks.sql'),[])
        d.execute("INSERT INTO stats VALUES('traced_buf_dropped',5,'error')")
        d.execute("INSERT INTO stats VALUES('traced_buf_abi_violations',0,'error')")
        d.execute("INSERT INTO stats VALUES('x',7,'info')")
        rows=self.run_sql(d,'00d-stats.sql')
        self.assertEqual(rows,[('traced_buf_dropped',5,'error')])
        d.close()

    def test_frequency_gate_unknown_without_track(self):
        d=self.db()
        row=self.run_sql(d,'04a-frequency-inventory.sql')[0]
        self.assertEqual(row[0],0)                 # freq_tracks
        self.assertTrue(row[7].startswith('UNKNOWN'),row[7])
        self.assertIn('0 MHz',row[7])              # explicitly forbids the misread
        d.close()

    def test_frequency_gate_unknown_track_without_samples(self):
        d=self.db()
        d.execute("INSERT INTO cpu_counter_track VALUES(1,'cpufreq',0,'kHz')")
        row=self.run_sql(d,'04a-frequency-inventory.sql')[0]
        self.assertEqual((row[0],row[3]),(1,0))
        self.assertTrue(row[7].startswith('UNKNOWN'),row[7])
        d.close()

    def test_frequency_gate_ok_and_weak(self):
        d=self.db()
        d.execute("INSERT INTO cpu_counter_track VALUES(1,'cpufreq',0,'kHz')")
        d.execute('INSERT INTO counter VALUES(1,100,1200000)')
        row=self.run_sql(d,'04a-frequency-inventory.sql')[0]
        self.assertTrue(row[7].startswith('WEAK'),row[7])
        d.execute('INSERT INTO counter VALUES(1,600,1800000)')
        row=self.run_sql(d,'04a-frequency-inventory.sql')[0]
        self.assertEqual((row[0],row[1],row[2],row[3]),(1,1,'kHz',2))
        self.assertTrue(row[7].startswith('OK'),row[7])
        self.assertEqual((row[4],row[5]),(100,600))   # first/last sample ts
        d.close()

    def test_frequency_timeline_empty_without_track(self):
        d=self.db()
        self.assertEqual(self.run_sql(d,'04-cpu-frequency.sql'),[])
        d.close()


if __name__=='__main__':unittest.main()
