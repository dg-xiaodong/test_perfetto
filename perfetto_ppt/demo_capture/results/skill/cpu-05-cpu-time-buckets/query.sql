-- 05-cpu-time-buckets.sql
-- Provenance: perfetto-memory-debugging v1.0.2 sql/11-cpu-time-buckets.sql
-- Frozen commit 0fa17e08eb8b93a9944232e380c7ddb39666fcf2.
-- Generic per-thread CPU time in fixed-size buckets.
-- Edit params target_upid, start_ts/end_ts, bucket_ns (ns) before use.
-- -1 target_upid deliberately returns no rows; -1 times mean trace_bounds.
-- Interval intersection splits sched slices correctly across bucket boundaries.
-- UI Counter: Timestamp=ts Value=cpu_ms Pivot=utid (thread_name is not unique).
WITH RECURSIVE
params AS (
  SELECT 179 AS target_upid, -1 AS start_ts, -1 AS end_ts, 100000000 AS bucket_ns
),
bounds AS (
  SELECT p.target_upid,
         CASE WHEN p.start_ts >= 0 THEN p.start_ts ELSE t.start_ts END AS start_ts,
         CASE WHEN p.end_ts >= 0 THEN p.end_ts ELSE t.end_ts END AS end_ts,
         p.bucket_ns
  FROM params p CROSS JOIN trace_bounds t
  WHERE p.bucket_ns > 0
),
buckets(bucket) AS (
  SELECT 0
  UNION ALL
  SELECT bucket + 1 FROM buckets
  WHERE bucket + 1 <
        (SELECT CAST((end_ts - start_ts + bucket_ns - 1) / bucket_ns AS INTEGER)
         FROM bounds)
)
SELECT th.utid, th.tid, th.name AS thread_name, b.target_upid,
       b.start_ts + bk.bucket * b.bucket_ns AS ts,
       bk.bucket AS bucket_index,
       SUM(MIN(s.ts + s.dur, b.start_ts + (bk.bucket + 1) * b.bucket_ns)
         - MAX(s.ts, b.start_ts + bk.bucket * b.bucket_ns)) / 1000000.0 AS cpu_ms,
       COUNT(*) AS overlapping_slices
FROM sched_slice s JOIN thread th USING (utid)
CROSS JOIN bounds b JOIN buckets bk
  ON s.ts < b.start_ts + (bk.bucket + 1) * b.bucket_ns
 AND s.ts + s.dur > b.start_ts + bk.bucket * b.bucket_ns
WHERE th.upid = b.target_upid AND s.dur > 0
  AND s.ts < b.end_ts AND s.ts + s.dur > b.start_ts
GROUP BY th.utid, th.tid, th.name, b.start_ts, b.bucket_ns, bk.bucket
ORDER BY ts, cpu_ms DESC;
