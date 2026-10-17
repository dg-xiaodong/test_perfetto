-- Task Q3: is the spike caused by scheduler delay / contention? Adapted from skill
-- sql/03-runnable-latency.sql; low threshold (0.05 ms) so tiny waits still show up.
WITH p AS (SELECT 185 AS target_upid, 0.05 AS threshold_ms),
rows AS (
  SELECT th.utid, th.tid, th.name AS thread_name, st.ts, st.dur, st.state
  FROM thread_state st JOIN thread th USING(utid) CROSS JOIN p
  WHERE th.upid=p.target_upid AND st.state IN ('R','R+') AND st.dur>0
    AND st.dur>=p.threshold_ms*1e6
)
SELECT utid, tid, thread_name, ts, ROUND(dur/1e6,3) AS runnable_wait_ms, state
FROM rows ORDER BY dur DESC LIMIT 20;
