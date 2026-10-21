-- Source S23. Replace -1 with the real UPID from 00-inventory.sql.
-- Empty output with -1 is intentional, not evidence that RSS is zero.
-- UI: Counter Track; Timestamp=ts; Value=value; Pivot=series. Values in MiB.
INCLUDE PERFETTO MODULE linux.memory.process;
WITH params AS (SELECT 179 AS target_upid), selected AS (
  SELECT m.* FROM memory_rss_and_swap_per_process m, params
  WHERE m.upid = params.target_upid
), series_data AS (
  SELECT ts, upid, 'anon' AS category, anon_rss AS bytes FROM selected
  UNION ALL SELECT ts, upid, 'file', file_rss FROM selected
  UNION ALL SELECT ts, upid, 'shmem', shmem_rss FROM selected
  UNION ALL SELECT ts, upid, 'total RSS', rss FROM selected
)
SELECT ts, bytes / 1048576.0 AS value,
       'UPID ' || upid || ' | ' || category || ' (MiB)' AS series
FROM series_data WHERE bytes IS NOT NULL ORDER BY series, ts;
-- The standard library may coalesce absent shmem/swap to zero; inspect source
-- coverage before claiming a category was actually measured as zero.
