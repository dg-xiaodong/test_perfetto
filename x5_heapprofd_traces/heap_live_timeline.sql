-- ============================================================================
-- heap_live_timeline.sql (v58.2-only) — Native heap 保留量（Unreleased 估计）
-- 用途：Perfetto UI → Query(SQL) → 结果 → Add debug track → Counter Track
--       字段映射：Timestamp=ts, Value=value, Pivot on=series
--
-- 版本前提：分析端为 Trace Processor **v58.2**（`heap_profile` 表存在）。
--   板端采集可用 v57.1；v57.1 采集的 raw trace 由 v58.2 TP 解析。
--
-- 口径：
--   * heap_profile：每份 dump 一行；ts=窗口开始，ts_end=窗口结束，dur=ts_end-ts
--   * heap_profile_allocation.ts == heap_profile.ts_end
--   * size：正=分配、负=释放（字节，采样估计）
--   * live = 按 dump 结束时刻累加正负增量（前缀和）
--   * **无活动的 dump 也会出现在时间轴**（左连接，delta=0，继承上一 live）
--   * 不是逐次 malloc 的实时 RSS；不能与 RSS 逐点相减
--
-- 注意（实测）：heapprofd 在 Linux 子进程模式下，长时间无分配时可能不产 dump；
--   此时曲线点数会少于 duration/interval 的理论值，属采集侧现象，不是 SQL 丢数据。
-- ============================================================================
WITH name_cands AS (
  SELECT COUNT(*) AS n_name FROM process WHERE (name = 'memprobe' OR name GLOB '*/memprobe')
),
data_cands AS (
  SELECT COUNT(DISTINCT h.upid) AS n_data
  FROM heap_profile h JOIN process p ON p.upid = h.upid
  WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc'
),
target AS (
  -- 仅当恰好一个同名进程带 heap 数据时解析（不静默取第一个）
  SELECT CASE WHEN (SELECT n_data FROM data_cands) = 1 THEN
    (SELECT MIN(h.upid) FROM heap_profile h JOIN process p ON p.upid = h.upid
      WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc') END AS upid
),
dumps AS (
  SELECT h.ts, h.ts_end, h.dur
  FROM heap_profile h, target t
  WHERE h.upid = t.upid AND h.heap_name = 'libc.malloc'
),
deltas AS (
  SELECT a.ts, SUM(a.size) AS delta
  FROM heap_profile_allocation a, target t
  WHERE a.upid = t.upid AND a.heap_name = 'libc.malloc'
  GROUP BY a.ts
),
-- 完整 dump 轴：即使某 dump 没有分配/释放，也保留该时刻
axis AS (
  -- dump 时刻统一用 ts_end（= allocation.ts）
  SELECT ts_end AS ts FROM dumps
  UNION
  SELECT ts FROM deltas
),
joined AS (
  SELECT ax.ts, COALESCE(d.delta, 0) AS delta
  FROM axis ax LEFT JOIN deltas d ON d.ts = ax.ts
),
live AS (
  SELECT ts,
         SUM(delta) OVER (ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           AS live_bytes
  FROM joined
)
SELECT
  ts,
  live_bytes / 1048576.0 AS value,
  'UPID ' || COALESCE(CAST((SELECT upid FROM target) AS TEXT), 'unresolved') ||
  ' | libc.malloc live est (MiB)' AS series
FROM live
ORDER BY ts;

-- 判读：
--   * 期望形状：0 → 8 MiB 平台（持有期）→ 0（释放后）
--   * 平台上每个点对应一份 dump（含无活动的 dump，继承上一 live）
--   * value 单位 MiB；ts 为纳秒，直接喂 UI，不要转秒
--   * 采样估计，不要求与程序日志 alloc_bytes 逐字节相等
