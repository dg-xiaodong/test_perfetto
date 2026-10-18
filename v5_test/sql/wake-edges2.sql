-- Process-context wake edges touching daemon(upid 1) / helper(upid 2); cross-process highlighted.
SELECT st.ts, w.pid waker_pid, wt.tid waker_tid, w.name waker_proc, wt.name waker,
       n.pid woken_pid, nt.tid woken_tid, n.name woken_proc, nt.name woken,
       CASE WHEN wt.upid!=nt.upid THEN 'CROSS_PROCESS' ELSE 'same_process' END kind
FROM thread_state st
JOIN thread nt ON nt.utid=st.utid JOIN process n ON n.upid=nt.upid
JOIN thread wt ON wt.utid=st.waker_utid JOIN process w ON w.upid=wt.upid
WHERE st.state IN ('R','R+') AND st.dur>=0 AND st.irq_context=0
AND (nt.upid IN (1,2) OR wt.upid IN (1,2)) AND st.ts>436000000000 AND st.ts<436200000000
ORDER BY st.ts;
