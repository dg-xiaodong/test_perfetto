-- 21-phase-coverage.sql
-- heapprofd 覆盖范围对照：把 Heap profile 分配记录按程序记录的两个阶段窗口切分。
-- 阶段窗口（CLOCK_BOOTTIME，来自 traces/memphase.log）：
--   A malloc: [30389709933199, 30395817772035]  (A_MALLOC_START .. A_FREE_DONE)
--   B mmap  : [30400822147912, 30406938280165]  (B_MMAP_START .. B_MUNMAP_DONE)
-- 判读：A 有 1 正 1 负记录；B 若为 0 行，说明直接 mmap 没有被 heapprofd 覆盖，
-- 不是“没有分配”（RSS/anon 在同一窗口明确上涨 32 MiB）。
WITH win(name, start_ts, end_ts) AS (VALUES
  ('A malloc 32MiB', 30389709933199, 30395817772035),
  ('B mmap   32MiB', 30400822147912, 30406938280165)
),
p AS (
  SELECT w.name, a.id, a.ts, a.count, a.size
  FROM win w LEFT JOIN heap_profile_allocation a
    ON a.upid = 186 AND a.heap_name = 'libc.malloc'
   AND a.ts BETWEEN w.start_ts AND w.end_ts
)
SELECT name AS phase,
       COUNT(id) AS alloc_rows,
       COALESCE(SUM(CASE WHEN size > 0 THEN size ELSE 0 END), 0) AS positive_bytes,
       COALESCE(SUM(CASE WHEN size < 0 THEN -size ELSE 0 END), 0) AS negative_bytes,
       COALESCE(SUM(size), 0) AS net_bytes
FROM p GROUP BY name ORDER BY name;

-- 记录明细（同一 ts 上 +32MiB 与 -32MiB：窗口塌缩成一点，见 10/22）。
-- 每个分配行的叶子帧是 preload 内部帧；带函数名的祖先栈见 04-native-callstacks.sql，
-- 该次 malloc 的路径为 phase_a -> main -> __libc_start_main -> _start。
