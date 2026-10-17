-- 00-inventory.sql — step 1/5: find the target process and its UPID.
--
-- One SELECT per file on purpose: Trace Processor v57.1 and v58.2 reject a
-- multi-result-set file passed to `query -f`, so the old combined inventory is
-- split into 00 (this file) + 00a..00d. Execute each file separately:
--   trace_processor_shell query -f sql/00-inventory.sql <trace>.pftrace
--
-- Capability is unchanged: 00 process ranking, 00a bounds, 00b thread states,
-- 00c counter/data-source presence, 00d stats/data-loss.
SELECT p.upid, p.pid, p.name AS process_name,
       COUNT(DISTINCT th.utid) AS threads,
       COUNT(s.id) AS running_slices,
       ROUND(SUM(CASE WHEN s.dur > 0 THEN s.dur ELSE 0 END) / 1e6, 2) AS cpu_ms
FROM process p
JOIN thread th ON th.upid = p.upid
LEFT JOIN sched_slice s ON s.utid = th.utid
GROUP BY p.upid, p.pid, p.name
HAVING COUNT(s.id) > 0
ORDER BY cpu_ms DESC
LIMIT 30;
