-- Whole-trace wake edges (process context only) touching the target process 197 / helper 199.
SELECT w.pid AS waker_pid,w.name AS waker_name,wt.tid AS waker_tid,
       n.pid AS woken_pid,n.name AS woken_name,nt.tid AS woken_tid,
       COUNT(*) AS n
FROM thread_state st
JOIN thread nt ON nt.utid=st.utid
JOIN thread wt ON wt.utid=st.waker_utid
LEFT JOIN process w ON w.upid=wt.upid
LEFT JOIN process n ON n.upid=nt.upid
WHERE st.state IN ('R','R+') AND st.dur>=0 AND st.irq_context=0
AND (nt.upid IN (197,199) OR wt.upid IN (197,199))
GROUP BY 1,2,3,4,5,6 ORDER BY n DESC LIMIT 40;
