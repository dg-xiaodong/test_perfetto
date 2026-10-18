-- Test 2 aggregate distribution across all ISP instances.
WITH q AS (
    SELECT dur FROM slice WHERE name = 'camsys.isp.user' AND dur >= 0
), r AS (
    SELECT dur,
           ROW_NUMBER() OVER (ORDER BY dur) AS rn,
           COUNT(*) OVER () AS n
    FROM q
)
SELECT (SELECT n FROM r LIMIT 1)                                   AS samples,
       AVG(dur) / 1000.0                                           AS avg_us,
       MIN(dur) / 1000.0                                           AS min_us,
       MAX(CASE WHEN rn = (n + 1) / 2 THEN dur END) / 1000.0       AS p50_us,
       MAX(CASE WHEN rn = MAX(1, CAST(n * 0.90 AS INTEGER)) THEN dur END) / 1000.0 AS p90_us,
       MAX(CASE WHEN rn = MAX(1, CAST(n * 0.99 AS INTEGER)) THEN dur END) / 1000.0 AS p99_us,
       MAX(dur) / 1000.0                                           AS max_us,
       (SELECT COUNT(*) FROM slice
         WHERE name = 'camsys.isp.user' AND dur = -1)              AS open_slices
FROM r;
