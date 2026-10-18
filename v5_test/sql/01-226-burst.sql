-- Sum known state intervals in a half-open window. dur=-1 is unknown, not zero.
-- UNKNOWN_COVERAGE is unobserved time, not necessarily sleeping time.
WITH p AS (SELECT 226 AS utid,196039000000 AS a,196171000000 AS b),
w AS (SELECT p.utid,CASE WHEN a>=0 THEN a ELSE start_ts END AS a,
  CASE WHEN b>=0 THEN b ELSE end_ts END AS b FROM p CROSS JOIN trace_bounds),
x AS (SELECT st.state,MIN(st.ts+st.dur,w.b)-MAX(st.ts,w.a) AS n
  FROM thread_state st CROSS JOIN w WHERE st.utid=w.utid AND st.dur>0
  AND w.b>w.a AND st.ts<w.b AND st.ts+st.dur>w.a),
g AS (SELECT state,SUM(n) AS duration_ns,COUNT(*) AS intervals FROM x GROUP BY state),
c AS (SELECT COALESCE(SUM(duration_ns),0) AS known FROM g)
SELECT state,duration_ns,duration_ns/1e6 AS duration_ms,intervals,
  CASE WHEN known>w.b-w.a THEN 'OVERLAP_ERROR' ELSE 'KNOWN_INTERVALS' END AS coverage_status
FROM g CROSS JOIN w CROSS JOIN c
UNION ALL
SELECT 'UNKNOWN_COVERAGE',MAX(0,w.b-w.a-c.known),MAX(0,w.b-w.a-c.known)/1e6,0,
  CASE WHEN c.known>w.b-w.a THEN 'OVERLAP_ERROR' ELSE 'UNOBSERVED_NOT_ZERO' END
FROM w CROSS JOIN c WHERE w.b>w.a AND (c.known!=w.b-w.a)
AND EXISTS(SELECT 1 FROM thread WHERE utid=w.utid);
