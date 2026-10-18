-- Observed wake edges among target process + helper threads inside a window.
-- Edge = runnable-state waker_utid -> utid. Counts only; not lock ownership.
WITH tg AS (SELECT utid,tid,name FROM thread WHERE upid IN (197,199)),
e AS (SELECT st.utid AS woken_utid, st.waker_utid AS waker_utid, st.irq_context
      FROM thread_state st WHERE st.utid IN (SELECT utid FROM tg)
      AND st.state IN ('R','R+') AND st.dur>=0
      AND st.ts>=195500000000 AND st.ts<197500000000)
SELECT w.tid AS waker_tid,w.name AS waker_name,n.tid AS woken_tid,n.name AS woken_name,
       COUNT(*) AS n,SUM(e.irq_context=1) AS irq_wakes
FROM e LEFT JOIN tg w ON w.utid=e.waker_utid JOIN tg n ON n.utid=e.woken_utid
GROUP BY w.tid,w.name,n.tid,n.name ORDER BY n DESC;
