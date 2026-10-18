-- Direct scheduling edges; repeat on an evidenced related UTID/window as needed.
-- waker_id is an observed thread_state link, NOT a lock owner/critical-path proof.
-- Automated arbitrary dependency reconstruction is intentionally not attempted.
WITH p AS (SELECT {{utid}} AS utid,{{start_ns}} AS a,{{end_ns}} AS b),
w AS (SELECT utid,CASE WHEN a>=0 THEN a ELSE start_ts END AS a,
 CASE WHEN b>=0 THEN b ELSE end_ts END AS b FROM p CROSS JOIN trace_bounds)
SELECT r.id AS runnable_state_id,r.ts AS wake_boundary_ts,r.utid AS target_utid,
 r.waker_utid,tw.upid AS waker_upid,tw.tid AS waker_tid,tw.name AS waker_name,
 r.waker_id AS waker_state_id,ws.ts AS waker_state_ts,ws.dur AS waker_state_dur,
 r.irq_context,
 CASE WHEN r.irq_context=0 AND r.waker_utid>0 THEN 'PROCESS_CONTEXT_RECORDED'
 WHEN r.irq_context=1 THEN 'IRQ_CONTEXT' ELSE 'CONTEXT_UNKNOWN' END AS context_status,
 'SCHEDULING_WAKE_EDGE_NOT_LOCK_OWNERSHIP' AS relation
FROM thread_state r CROSS JOIN w
LEFT JOIN thread tw ON tw.utid=r.waker_utid LEFT JOIN thread_state ws ON ws.id=r.waker_id
WHERE r.utid=w.utid AND r.state IN ('R','R+') AND r.ts>=w.a AND r.ts<w.b
AND r.dur>=0 AND w.b>w.a ORDER BY r.ts,r.id;
