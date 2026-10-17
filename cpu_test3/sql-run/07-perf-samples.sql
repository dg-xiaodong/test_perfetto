-- CPU sampling distribution, NOT deterministic per-function CPU duration.
-- Requires a Trace Processor with perf_sample and callsite tables.
-- Set target_upid. If perf_sample table is unavailable: status UNKNOWN, not 0 hotspots.
-- Callsite leaf frame = sampled stack leaf only; use Perfetto flamegraph/stdlib for ancestry.
WITH p AS (SELECT 3 AS target_upid)
SELECT th.utid,th.tid,th.name AS thread_name,ps.callsite_id,
       COALESCE(NULLIF(f.name,''),'[unsymbolized]') AS leaf_frame,
       COALESCE(m.name,'[unknown mapping]') AS mapping_name,
       COUNT(*) AS samples
FROM perf_sample ps JOIN thread th USING (utid)
LEFT JOIN stack_profile_callsite cs ON cs.id=ps.callsite_id
LEFT JOIN stack_profile_frame f ON f.id=cs.frame_id
LEFT JOIN stack_profile_mapping m ON m.id=f.mapping
CROSS JOIN p WHERE th.upid=p.target_upid
GROUP BY th.utid,th.tid,th.name,ps.callsite_id,leaf_frame,mapping_name
ORDER BY samples DESC LIMIT 100;
