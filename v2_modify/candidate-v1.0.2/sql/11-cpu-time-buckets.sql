-- 11-cpu-time-buckets.sql
-- Generic per-thread CPU time in fixed-size buckets.
-- Params (replace the -1 / 0 defaults):
--   target_upid : UPID from sql/00-inventory.sql; -1 returns no rows
--   start_ts    : window start in ns; -1 = trace_bounds.start_ts
--   end_ts      : window end in ns; -1 = trace_bounds.end_ts
--   bucket_ns   : bucket width in ns (100000000 = 100 ms)
--
-- An interval is split by INTERSECTION with each bucket:
--   min(ts+dur, bucket_end) - max(ts, bucket_start)
-- A 900-1100 ms slice with dur=200 ms contributes 100 ms to each 1 s bucket;
-- it is not charged entirely to the bucket containing ts.
--
-- UI: Counter Track; Timestamp=ts; Value=cpu_ms; Pivot=thread_name/utid.
WITH RECURSIVE
params AS (
  SELECT -1 AS target_upid, -1 AS start_ts, -1 AS end_ts, 100000000 AS bucket_ns
),
bounds AS (
  SELECT
    p.target_upid,
    CASE WHEN p.start_ts >= 0 THEN p.start_ts ELSE t.start_ts END AS start_ts,
    CASE WHEN p.end_ts   >= 0 THEN p.end_ts   ELSE t.end_ts   END AS end_ts,
    p.bucket_ns
  FROM params p CROSS JOIN trace_bounds t
  WHERE p.bucket_ns > 0
),
buckets(bucket) AS (
  SELECT 0
  UNION ALL
  SELECT bucket + 1
  FROM buckets
  WHERE bucket + 1 <
        (SELECT CAST((end_ts - start_ts + bucket_ns - 1) / bucket_ns AS INTEGER)
         FROM bounds)
)
SELECT
  th.utid,
  th.tid,
  th.name AS thread_name,
  b.target_upid,
  b.start_ts + bk.bucket * b.bucket_ns AS ts,
  bk.bucket AS bucket_index,
  SUM(
    MIN(s.ts + s.dur, b.start_ts + (bk.bucket + 1) * b.bucket_ns)
    - MAX(s.ts, b.start_ts + bk.bucket * b.bucket_ns)
  ) / 1000000.0 AS cpu_ms,
  COUNT(*) AS overlapping_slices
FROM sched_slice s
JOIN thread th USING (utid)
CROSS JOIN bounds b
JOIN buckets bk
  ON s.ts < b.start_ts + (bk.bucket + 1) * b.bucket_ns
 AND s.ts + s.dur > b.start_ts + bk.bucket * b.bucket_ns
WHERE th.upid = b.target_upid
  AND s.dur > 0
  AND s.ts < b.end_ts
  AND s.ts + s.dur > b.start_ts
GROUP BY th.utid, th.tid, th.name, b.start_ts, b.bucket_ns, bk.bucket
ORDER BY ts, cpu_ms DESC;
