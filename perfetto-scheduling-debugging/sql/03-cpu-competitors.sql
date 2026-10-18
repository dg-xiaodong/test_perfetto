-- ALL processes on this CPU, never prefilter to the target process.
-- This is scheduled non-idle time, not exclusive CPU cycles (IRQ may run inside a slice).
WITH p AS (SELECT {{cpu}} AS cpu,{{start_ns}} AS a,{{end_ns}} AS b),
x AS (SELECT s.cpu,t.upid,t.utid,t.tid,t.name AS thread_name,
 MIN(s.ts+s.dur,p.b)-MAX(s.ts,p.a) AS n,p.b-p.a AS window_ns
 FROM sched_slice s JOIN thread t USING(utid) CROSS JOIN p
 WHERE s.cpu=p.cpu AND t.tid!=0 AND s.dur>0 AND p.a>=0 AND p.b>p.a
 AND s.ts<p.b AND s.ts+s.dur>p.a)
SELECT cpu,upid,utid,tid,thread_name,SUM(n) AS cpu_ns,SUM(n)/1e6 AS cpu_ms,
 100.0*SUM(n)/window_ns AS pct_one_cpu FROM x
GROUP BY cpu,upid,utid,tid,thread_name,window_ns ORDER BY cpu_ns DESC;
