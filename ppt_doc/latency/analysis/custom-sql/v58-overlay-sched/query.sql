WITH st AS (
  SELECT s.id sid, s.ts, s.dur, tt.utid, CAST(EXTRACT_ARG(s.arg_set_id,'debug.stage_id') AS TEXT) stg
  FROM slice s JOIN thread_track tt ON tt.id=s.track_id
  WHERE s.category='rdk.latency' AND s.name='lat.stage' AND s.dur>0
), ov AS (
  SELECT st.sid, st.stg, st.dur, ts.state,
         CASE WHEN MIN(st.ts+st.dur, ts.ts+ts.dur) - MAX(st.ts, ts.ts) < 0 THEN 0
              ELSE MIN(st.ts+st.dur, ts.ts+ts.dur) - MAX(st.ts, ts.ts) END AS ovl
  FROM st JOIN thread_state ts ON ts.utid=st.utid AND ts.ts < st.ts+st.dur AND ts.ts+ts.dur > st.ts
), cls AS (
  SELECT sid, stg, dur,
    CASE WHEN stg='work' AND dur>15000000 THEN 'work_slow'
         WHEN stg='work' THEN 'work_fast'
         WHEN stg='output' AND dur>50000000 THEN 'output_slow'
         WHEN stg='output' THEN 'output_fast'
         ELSE stg||'_fast' END AS klass
  FROM st
)
SELECT c.klass AS klass, c.stg AS stage, o.state AS state,
       COUNT(DISTINCT c.sid) AS slices, COUNT(*) AS intervals,
       ROUND(SUM(o.ovl)/1e6,1) AS total_overlap_ms,
       ROUND(SUM(o.ovl)/1e6/COUNT(DISTINCT c.sid),2) AS avg_overlap_ms_per_slice
FROM cls c JOIN ov o ON o.sid=c.sid
GROUP BY klass, stage, state ORDER BY klass, total_overlap_ms DESC;
