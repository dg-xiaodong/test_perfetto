-- Set --slice-id to a closed THREAD-TRACK slice, not a generic async track.
-- A custom request/queue track returns NO_THREAD_BINDING, never fabricated CPU 0.
WITH target AS (
 SELECT s.id,s.ts,s.dur,tt.utid FROM slice s
 LEFT JOIN thread_track tt ON tt.id=s.track_id WHERE s.id=${SLICE_ID}
), states AS (
 SELECT st.state,MAX(0,MIN(st.ts+st.dur,t.ts+t.dur)-MAX(st.ts,t.ts)) AS overlap_ns
 FROM thread_state st JOIN target t ON st.utid=t.utid
 WHERE t.dur>=0 AND st.dur>=0 AND st.ts<t.ts+t.dur AND st.ts+st.dur>t.ts
)
SELECT 'STATE_OVERLAP' AS status,state,SUM(overlap_ns) AS duration_ns FROM states GROUP BY state
UNION ALL SELECT 'NO_THREAD_BINDING',NULL,NULL FROM target WHERE utid IS NULL
UNION ALL SELECT 'OPEN_SLICE',NULL,NULL FROM target WHERE dur<0
UNION ALL SELECT 'NO_SCHED_DATA',NULL,NULL FROM target WHERE utid IS NOT NULL AND dur>=0 AND NOT EXISTS(SELECT 1 FROM states)
UNION ALL SELECT 'TARGET_NOT_FOUND',NULL,NULL WHERE NOT EXISTS(SELECT 1 FROM target);
