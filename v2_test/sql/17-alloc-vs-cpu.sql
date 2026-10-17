-- 17-alloc-vs-cpu.sql
-- Join native allocation snapshots to CPU buckets, then split callsites into
-- "snapshot landed in a high-CPU bucket" vs "low-CPU bucket".
--
-- LIMITS TO STATE IN THE ANSWER:
--   * heap_profile_allocation.ts is the dump END, not each malloc;
--   * v57.1 collector may publish no window start (dur=0);
--   * 1 s CPU bucket and 2 s dump interval are different resolutions.
-- Therefore this is a screen for follow-up, not by itself proof of causation.
WITH params AS (
  SELECT
    -1 AS target_upid,
    'libc.malloc' AS target_heap,
    100.0 AS spike_cpu_ms          -- per 1 s bucket; adjust to C1 baseline
), bounds AS (
  SELECT start_ts FROM trace_bounds
), cpu AS (
  SELECT
    CAST((s.ts - b.start_ts) / 1000000000 AS INTEGER) AS bucket_s,
    SUM(s.dur) / 1000000.0 AS cpu_ms
  FROM sched_slice s
  JOIN thread th USING (utid)
  JOIN process p USING (upid), bounds b, params q
  WHERE p.upid = q.target_upid
    AND s.ts >= b.start_ts
  GROUP BY bucket_s
), alloc AS (
  SELECT
    CAST((a.ts - b.start_ts) / 1000000000 AS INTEGER) AS bucket_s,
    a.callsite_id,
    SUM(CASE WHEN a.size > 0 THEN a.size ELSE 0 END) AS alloc_bytes,
    SUM(CASE WHEN a.size > 0 THEN a.count ELSE 0 END) AS alloc_count
  FROM heap_profile_allocation a, bounds b, params p
  WHERE a.upid = p.target_upid
    AND a.heap_name = p.target_heap
  GROUP BY bucket_s, a.callsite_id
), tagged AS (
  SELECT
    x.callsite_id,
    x.alloc_bytes,
    x.alloc_count,
    CASE WHEN c.cpu_ms >= (SELECT spike_cpu_ms FROM params) THEN 'spike' ELSE 'quiet' END AS phase
  FROM alloc x
  JOIN cpu c USING (bucket_s)
)
SELECT
  t.phase,
  t.callsite_id,
  COALESCE(f.name, '<unknown>') AS frame_name,
  COALESCE(m.name, '<unknown>') AS mapping_name,
  SUM(t.alloc_bytes) AS alloc_bytes,
  SUM(t.alloc_count) AS alloc_count
FROM tagged t
LEFT JOIN stack_profile_callsite c ON c.id = t.callsite_id
LEFT JOIN stack_profile_frame f ON f.id = c.frame_id
LEFT JOIN stack_profile_mapping m ON m.id = f.mapping
GROUP BY t.phase, t.callsite_id, frame_name, mapping_name
ORDER BY t.phase, alloc_bytes DESC;
