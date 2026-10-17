-- ============================================================================
-- accept.sql (v4 · v58.2-only) — heapprofd 最小实验验收
--
-- 分析基线：Perfetto Trace Processor **v58.2**（主机）。
-- 采集基线：X5 板端 tracebox v57.1（不变）；v57.1 采集的 raw trace 由 v58.2 TP 解析。
--
-- 实验：memprobe both 8 8000 512 40 20 4000
--   churn 40×512KiB=20MiB（随后释放）；live 8MiB 持有 8s 后释放；释放后 4s；
--   总申请/释放 28MiB；最终保留 0。dump phase 3000ms / interval 2000ms。
--
-- v58.2 关键事实（已用真实 TP 核对）：
--   * heap_profile(ts, ts_end, dur, upid, heap_name)：每份 dump 一行；ts=窗口开始，
--     ts_end=窗口结束；heap_profile_allocation.ts == heap_profile.ts_end。
--   * stack_profile_frame 无 build_id（在 stack_profile_mapping）。
--   * heapprofd 在 Linux 子进程模式下，空闲期可能不产 dump（实测：连续 churn 6 份，
--     长时间无分配只有 1 份）→ 不能把"没有 dump"当成"live 没变"。
--   * process.name 可能是带路径的 cmdline 首参（实测 "./memprobe_x86"）→ 按 basename 匹配。
--   * heapprofd_client_disconnected 是会话结束的正常事件，**不算**严重采集错误。
--   * preload 客户端会 fork 一个继承 cmdline 的 heapprofd 子进程 → 同名进程可能出现
--     两个 UPID，但只有被 profile 的有 heap 数据（实测 upid 33 有、34 无）。
--
-- 逐条执行。[S4] 是唯一状态行（五类）：
--   CAPTURE_FAILED / CAPTURE_OK_SYMBOLS_MISSING / CAPTURE_OK_SYMBOLS_UNCERTAIN /
--   CAPTURE_OK_BEHAVIOR_INCOMPLETE / PASS
-- ============================================================================


-- [S1] 目标进程候选（诊断）：同名进程 + 是否带 heap 数据
SELECT p.upid, p.pid, p.name,
       (SELECT COUNT(*) FROM heap_profile h
         WHERE h.upid = p.upid AND h.heap_name = 'libc.malloc') AS dumps,
       (SELECT COUNT(*) FROM heap_profile_allocation a
         WHERE a.upid = p.upid AND a.heap_name = 'libc.malloc') AS alloc_rows
FROM process p
WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe')
ORDER BY p.upid;


-- [S2] LEVEL 1：采集链路验收
WITH name_cands AS (SELECT COUNT(*) AS n_name FROM process WHERE (name = 'memprobe' OR name GLOB '*/memprobe')),
data_cands AS (
  SELECT COUNT(DISTINCT h.upid) AS n_data FROM heap_profile h
  JOIN process p ON p.upid = h.upid
  WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc'
),
target AS (
  SELECT CASE WHEN (SELECT n_data FROM data_cands) = 1 THEN
    (SELECT MIN(h.upid) FROM heap_profile h JOIN process p ON p.upid = h.upid
      WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc') END AS upid
),
schema_cols AS (
  SELECT
    (SELECT COUNT(*) FROM pragma_table_info('heap_profile')
      WHERE name IN ('ts','ts_end','dur','upid','heap_name')) AS hp_cols,
    (SELECT COUNT(*) FROM pragma_table_info('heap_profile_allocation')
      WHERE name IN ('ts','upid','heap_name','callsite_id','count','size')) AS alloc_cols
),
heap_rows AS (
  SELECT (SELECT COUNT(*) FROM heap_profile_allocation a, target t
           WHERE a.upid = t.upid AND a.heap_name = 'libc.malloc') AS n_rows,
         (SELECT COUNT(*) FROM heap_profile h, target t
           WHERE h.upid = t.upid AND h.heap_name = 'libc.malloc') AS n_dumps
),
severe AS (
  SELECT COUNT(*) AS n FROM stats
  WHERE value > 0 AND (name GLOB '*buffer_overrun*' OR name GLOB '*data_loss*'
                       OR name GLOB 'heapprofd_*error*')
)
SELECT 'L1' AS level, check_name, ok, detail FROM (
  SELECT 'target_upid_resolved' AS check_name,
         CASE WHEN (SELECT n_data FROM data_cands) = 1 THEN 1 ELSE 0 END AS ok,
         'name_candidates=' || (SELECT n_name FROM name_cands) ||
         ', data_bearing=' || (SELECT n_data FROM data_cands) ||
         ', resolved=' || COALESCE(CAST((SELECT upid FROM target) AS TEXT), 'NULL') ||
         CASE WHEN (SELECT n_data FROM data_cands) > 1
              THEN ' (多个同名进程都有 heap 数据：拒绝静默选择)' ELSE '' END AS detail
  UNION ALL SELECT 'schema_heap_profile_columns',
         CASE WHEN (SELECT hp_cols FROM schema_cols) = 5 THEN 1 ELSE 0 END,
         'heap_profile=' || (SELECT hp_cols FROM schema_cols) || '/5'
  UNION ALL SELECT 'schema_allocation_columns',
         CASE WHEN (SELECT alloc_cols FROM schema_cols) = 6 THEN 1 ELSE 0 END,
         'heap_profile_allocation=' || (SELECT alloc_cols FROM schema_cols) || '/6'
  UNION ALL SELECT 'target_dumps_exist',
         CASE WHEN (SELECT n_dumps FROM heap_rows) >= 1 THEN 1 ELSE 0 END,
         'dumps=' || (SELECT n_dumps FROM heap_rows)
  UNION ALL SELECT 'target_alloc_rows_exist',
         CASE WHEN (SELECT n_rows FROM heap_rows) > 0 THEN 1 ELSE 0 END,
         'rows=' || (SELECT n_rows FROM heap_rows)
  UNION ALL SELECT 'no_severe_capture_errors',
         CASE WHEN (SELECT n FROM severe) = 0 THEN 1 ELSE 0 END,
         'severe_stats=' || (SELECT n FROM severe)
) ORDER BY check_name;


-- [S3] LEVEL 2：实验行为验收（三层：栈结构 / 帧名称 / 业务函数识别）
--      持有区间：alloc ∈ [ts_A, ts_end_A]，free ∈ [ts_F, ts_end_F]
--      ⇒ hold ∈ [ts_F - ts_end_A, ts_end_F - ts_A]；检查 8000ms 是否落入该区间。
WITH RECURSIVE name_cands AS (SELECT COUNT(*) AS n_name FROM process WHERE (name = 'memprobe' OR name GLOB '*/memprobe')),
data_cands AS (
  SELECT COUNT(DISTINCT h.upid) AS n_data FROM heap_profile h
  JOIN process p ON p.upid = h.upid
  WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc'
),
target AS (
  SELECT CASE WHEN (SELECT n_data FROM data_cands) = 1 THEN
    (SELECT MIN(h.upid) FROM heap_profile h JOIN process p ON p.upid = h.upid
      WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc') END AS upid
),
dumps AS (
  SELECT h.ts, h.ts_end, h.dur FROM heap_profile h, target t
  WHERE h.upid = t.upid AND h.heap_name = 'libc.malloc'
),
alloc AS (
  SELECT a.ts, a.callsite_id, a.size FROM heap_profile_allocation a, target t
  WHERE a.upid = t.upid AND a.heap_name = 'libc.malloc'
),
deltas AS (SELECT ts, SUM(size) AS delta FROM alloc GROUP BY ts),
axis AS (SELECT ts_end AS ts FROM dumps UNION SELECT ts FROM deltas),
live AS (SELECT ax.ts, COALESCE(d.delta,0) AS delta FROM axis ax LEFT JOIN deltas d ON d.ts=ax.ts),
cum AS (
  SELECT ts, SUM(delta) OVER (ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS live_bytes
  FROM live
),
nums AS (
  SELECT
    (SELECT COALESCE(SUM(size),0) FROM alloc WHERE size > 0) AS alloc_bytes,
    (SELECT COALESCE(-SUM(size),0) FROM alloc WHERE size < 0) AS free_bytes,
    (SELECT COALESCE(MAX(live_bytes),0) FROM cum) AS max_live,
    (SELECT COALESCE((SELECT live_bytes FROM cum ORDER BY ts DESC LIMIT 1),0)) AS last_live,
    (SELECT COUNT(*) FROM alloc WHERE size < 0 AND -size >= 1048576) AS free_rows_live,
    (SELECT COUNT(*) FROM dumps) AS n_dumps
),
chain(alloc_callsite_id, node_id, depth) AS (
  SELECT DISTINCT callsite_id, callsite_id, 0 FROM alloc WHERE callsite_id IS NOT NULL
  UNION ALL
  SELECT ch.alloc_callsite_id, c.parent_id, ch.depth + 1
  FROM chain ch JOIN stack_profile_callsite c ON c.id = ch.node_id
  WHERE c.parent_id IS NOT NULL AND ch.depth < 64
),
nf AS (
  SELECT ch.alloc_callsite_id, ch.depth, f.name AS frame_name
  FROM chain ch
  LEFT JOIN stack_profile_callsite c ON c.id = ch.node_id
  LEFT JOIN stack_profile_frame f ON f.id = c.frame_id
),
pc AS (
  SELECT alloc_callsite_id,
         MAX(CASE WHEN frame_name GLOB '*probe_live_block*' THEN 1 ELSE 0 END) AS live_cum,
         MAX(CASE WHEN frame_name GLOB '*probe_churn_cycle*' THEN 1 ELSE 0 END) AS churn_cum,
         MAX(CASE WHEN frame_name IS NULL THEN 1 ELSE 0 END) AS has_null_frame
  FROM nf GROUP BY alloc_callsite_id
),
tagged AS (
  SELECT a.ts, a.size, COALESCE(p.live_cum,0) AS live_cum, COALESCE(p.churn_cum,0) AS churn_cum,
         CASE WHEN a.callsite_id IS NULL OR p.alloc_callsite_id IS NULL OR p.has_null_frame = 1
              THEN 1 ELSE 0 END AS unresolved
  FROM alloc a LEFT JOIN pc p ON p.alloc_callsite_id = a.callsite_id
),
sym AS (
  SELECT COALESCE(SUM(CASE WHEN live_cum = 1 THEN size ELSE 0 END),0) AS live_cum_bytes,
         COALESCE(SUM(CASE WHEN churn_cum = 1 THEN size ELSE 0 END),0) AS churn_cum_bytes,
         COALESCE(SUM(CASE WHEN unresolved = 1 THEN size ELSE 0 END),0) AS unresolved_bytes,
         COALESCE(SUM(size),0) AS positive_bytes
  FROM tagged WHERE size > 0
),
chainstat AS (SELECT COUNT(*) AS n_nodes FROM chain),
frames AS (
  SELECT DISTINCT c.frame_id FROM chain ch
  JOIN stack_profile_callsite c ON c.id = ch.node_id WHERE c.frame_id IS NOT NULL
),
framestat AS (
  SELECT COUNT(*) AS n_frames,
         COALESCE(SUM(CASE WHEN f.name IS NOT NULL THEN 1 ELSE 0 END),0) AS n_named
  FROM frames fr LEFT JOIN stack_profile_frame f ON f.id = fr.frame_id
),
live_dumps AS (
  SELECT
    (SELECT MIN(a.ts) FROM alloc a JOIN pc p ON p.alloc_callsite_id = a.callsite_id
      WHERE p.live_cum = 1 AND a.size >= 1048576) AS path_alloc_ts,
    (SELECT MAX(a.ts) FROM alloc a JOIN pc p ON p.alloc_callsite_id = a.callsite_id
      WHERE p.live_cum = 1 AND a.size <= -1048576) AS path_free_ts,
    (SELECT MIN(ts) FROM alloc WHERE size >= 1048576) AS proxy_alloc_ts,
    (SELECT MAX(ts) FROM alloc WHERE size <= -1048576) AS proxy_free_ts
),
pick_a AS (SELECT x.ts, x.src FROM (
   SELECT path_alloc_ts AS ts, 'probe_live_block' AS src FROM live_dumps WHERE path_alloc_ts IS NOT NULL
   UNION ALL SELECT proxy_alloc_ts, 'size_proxy' FROM live_dumps
     WHERE (SELECT path_alloc_ts FROM live_dumps) IS NULL AND proxy_alloc_ts IS NOT NULL) x LIMIT 1),
pick_f AS (SELECT x.ts, x.src FROM (
   SELECT path_free_ts AS ts, 'probe_live_block' AS src FROM live_dumps WHERE path_free_ts IS NOT NULL
   UNION ALL SELECT proxy_free_ts, 'size_proxy' FROM live_dumps
     WHERE (SELECT path_free_ts FROM live_dumps) IS NULL AND proxy_free_ts IS NOT NULL) x LIMIT 1),
win AS (
  SELECT
    (SELECT d.ts FROM dumps d WHERE d.ts_end = (SELECT ts FROM pick_a)) AS a_ts,
    (SELECT ts FROM pick_a) AS a_ts_end,
    (SELECT d.ts FROM dumps d WHERE d.ts_end = (SELECT ts FROM pick_f)) AS f_ts,
    (SELECT ts FROM pick_f) AS f_ts_end
),
hold AS (
  SELECT
    CASE WHEN a_ts IS NOT NULL AND f_ts IS NOT NULL THEN f_ts - a_ts_end END AS lower_ns,
    CASE WHEN a_ts IS NOT NULL AND f_ts IS NOT NULL THEN f_ts_end - a_ts END AS upper_ns,
    CASE WHEN a_ts IS NOT NULL AND a_ts = f_ts THEN 1 ELSE 0 END AS same_dump,
    COALESCE((SELECT src FROM pick_a),'unknown') AS src
  FROM win
),
post AS (
  -- 释放后的 dump：窗口**结束**严格晚于释放 dump 的结束（dur=0 时同一份不算）
  SELECT COUNT(*) AS n_post FROM dumps d
  WHERE (SELECT f_ts_end FROM win) IS NOT NULL AND d.ts_end > (SELECT f_ts_end FROM win)
),
ck AS (
  SELECT 'callstack_structure_present' AS check_name, 'symbol' AS kind,
         CASE WHEN (SELECT n_nodes FROM chainstat) > 0 THEN 1 ELSE 0 END AS ok,
         'chain_nodes=' || (SELECT n_nodes FROM chainstat) AS detail
  UNION ALL SELECT 'frames_have_names', 'symbol',
         CASE WHEN (SELECT n_frames FROM framestat) > 0
                   AND (SELECT n_named FROM framestat) * 2 >= (SELECT n_frames FROM framestat)
              THEN 1 ELSE 0 END,
         'named=' || (SELECT n_named FROM framestat) || '/' || (SELECT n_frames FROM framestat)
  UNION ALL SELECT 'probe_live_block_identified', 'identify',
         CASE WHEN (SELECT live_cum_bytes FROM sym) > 0 THEN 1 ELSE 0 END,
         'cum_bytes=' || (SELECT live_cum_bytes FROM sym)
  UNION ALL SELECT 'probe_churn_cycle_identified', 'identify',
         CASE WHEN (SELECT churn_cum_bytes FROM sym) > 0 THEN 1 ELSE 0 END,
         'cum_bytes=' || (SELECT churn_cum_bytes FROM sym)
  UNION ALL SELECT 'total_alloc_28MiB_within_40pct', 'behavior',
         CASE WHEN (SELECT alloc_bytes FROM nums) BETWEEN 28*1048576*0.6 AND 28*1048576*1.4
              THEN 1 ELSE 0 END,
         'alloc_mib=' || ROUND((SELECT alloc_bytes FROM nums)/1048576.0, 2)
  UNION ALL SELECT 'total_free_matches_alloc_within_20pct', 'behavior',
         CASE WHEN (SELECT alloc_bytes FROM nums) > 0
                   AND (SELECT free_bytes FROM nums) BETWEEN (SELECT alloc_bytes FROM nums)*0.8
                                                          AND (SELECT alloc_bytes FROM nums)*1.2
              THEN 1 ELSE 0 END,
         'free_mib=' || ROUND((SELECT free_bytes FROM nums)/1048576.0, 2)
  UNION ALL SELECT 'live_hold_phase_at_least_6MiB', 'behavior',
         CASE WHEN (SELECT max_live FROM nums) >= 6*1048576 THEN 1 ELSE 0 END,
         'max_live_mib=' || ROUND((SELECT max_live FROM nums)/1048576.0, 2)
  UNION ALL SELECT 'release_observed_in_dump', 'behavior',
         CASE WHEN (SELECT free_rows_live FROM nums) > 0 THEN 1 ELSE 0 END,
         'free_rows_ge_1MiB=' || (SELECT free_rows_live FROM nums)
  UNION ALL SELECT 'hold_within_dump_window_bounds', 'behavior',
         CASE WHEN (SELECT lower_ns FROM hold) IS NOT NULL
                   AND 8000000000 BETWEEN (SELECT lower_ns FROM hold) AND (SELECT upper_ns FROM hold)
              THEN 1 ELSE 0 END,
         'window_lower_s=' || COALESCE(CAST(ROUND((SELECT lower_ns FROM hold)/1e9,2) AS TEXT),'NULL') ||
         ', window_upper_s=' || COALESCE(CAST(ROUND((SELECT upper_ns FROM hold)/1e9,2) AS TEXT),'NULL') ||
         ', same_dump=' || COALESCE(CAST((SELECT same_dump FROM hold) AS TEXT),'NULL') ||
         ', source=' || (SELECT src FROM hold)
  UNION ALL SELECT 'post_release_dump_exists', 'behavior',
         CASE WHEN (SELECT n_post FROM post) >= 1 THEN 1 ELSE 0 END,
         'post_release_dumps=' || (SELECT n_post FROM post) ||
         ' (窗口结束严格晚于释放 dump 结束；空闲期 heapprofd 可能不产 dump)'
  UNION ALL SELECT 'last_axis_dump_live_is_zero', 'behavior',
         CASE WHEN (SELECT last_live FROM nums) <= 1048576 THEN 1 ELSE 0 END,
         'last_live_mib=' || ROUND((SELECT last_live FROM nums)/1048576.0, 2) ||
         ', dumps=' || (SELECT n_dumps FROM nums)
)
SELECT 'L2' AS level, check_name, kind, ok, detail FROM ck ORDER BY kind, check_name;


-- [S4] 最终状态（五类）
WITH RECURSIVE name_cands AS (SELECT COUNT(*) AS n_name FROM process WHERE (name = 'memprobe' OR name GLOB '*/memprobe')),
data_cands AS (
  SELECT COUNT(DISTINCT h.upid) AS n_data FROM heap_profile h
  JOIN process p ON p.upid = h.upid
  WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc'
),
target AS (
  SELECT CASE WHEN (SELECT n_data FROM data_cands) = 1 THEN
    (SELECT MIN(h.upid) FROM heap_profile h JOIN process p ON p.upid = h.upid
      WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc') END AS upid
),
dumps AS (
  SELECT h.ts, h.ts_end, h.dur FROM heap_profile h, target t
  WHERE h.upid = t.upid AND h.heap_name = 'libc.malloc'
),
alloc AS (
  SELECT a.ts, a.callsite_id, a.size FROM heap_profile_allocation a, target t
  WHERE a.upid = t.upid AND a.heap_name = 'libc.malloc'
),
deltas AS (SELECT ts, SUM(size) AS delta FROM alloc GROUP BY ts),
axis AS (SELECT ts_end AS ts FROM dumps UNION SELECT ts FROM deltas),
live AS (SELECT ax.ts, COALESCE(d.delta,0) AS delta FROM axis ax LEFT JOIN deltas d ON d.ts=ax.ts),
cum AS (
  SELECT ts, SUM(delta) OVER (ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS live_bytes
  FROM live
),
agg AS (
  SELECT
    (SELECT n_name FROM name_cands) AS n_name,
    (SELECT n_data FROM data_cands) AS n_data,
    (SELECT COUNT(*) FROM alloc) AS n_rows,
    (SELECT COUNT(*) FROM dumps) AS n_dumps,
    (SELECT COALESCE(SUM(size),0) FROM alloc WHERE size > 0) AS alloc_bytes,
    (SELECT COALESCE(-SUM(size),0) FROM alloc WHERE size < 0) AS free_bytes,
    (SELECT COALESCE(MAX(live_bytes),0) FROM cum) AS max_live,
    (SELECT COALESCE((SELECT live_bytes FROM cum ORDER BY ts DESC LIMIT 1),0)) AS last_live,
    (SELECT COUNT(*) FROM alloc WHERE size < 0 AND -size >= 1048576) AS free_rows_live,
    (SELECT COUNT(*) FROM stats WHERE value > 0 AND (name GLOB '*buffer_overrun*'
       OR name GLOB '*data_loss*' OR name GLOB 'heapprofd_*error*')) AS severe,
    (SELECT COUNT(*) FROM pragma_table_info('heap_profile')
       WHERE name IN ('ts','ts_end','dur','upid','heap_name')) AS hp_cols,
    (SELECT COUNT(*) FROM pragma_table_info('heap_profile_allocation')
       WHERE name IN ('ts','upid','heap_name','callsite_id','count','size')) AS alloc_cols
),
chain(alloc_callsite_id, node_id, depth) AS (
  SELECT DISTINCT callsite_id, callsite_id, 0 FROM alloc WHERE callsite_id IS NOT NULL
  UNION ALL
  SELECT ch.alloc_callsite_id, c.parent_id, ch.depth + 1
  FROM chain ch JOIN stack_profile_callsite c ON c.id = ch.node_id
  WHERE c.parent_id IS NOT NULL AND ch.depth < 64
),
nf AS (
  SELECT ch.alloc_callsite_id, ch.depth, f.name AS frame_name
  FROM chain ch
  LEFT JOIN stack_profile_callsite c ON c.id = ch.node_id
  LEFT JOIN stack_profile_frame f ON f.id = c.frame_id
),
pc AS (
  SELECT alloc_callsite_id,
         MAX(CASE WHEN frame_name GLOB '*probe_live_block*' THEN 1 ELSE 0 END) AS live_cum,
         MAX(CASE WHEN frame_name GLOB '*probe_churn_cycle*' THEN 1 ELSE 0 END) AS churn_cum,
         MAX(CASE WHEN frame_name IS NULL THEN 1 ELSE 0 END) AS has_null_frame
  FROM nf GROUP BY alloc_callsite_id
),
sym AS (
  SELECT COALESCE(SUM(CASE WHEN p.live_cum = 1 THEN a.size ELSE 0 END),0) AS live_cum_bytes,
         COALESCE(SUM(CASE WHEN p.churn_cum = 1 THEN a.size ELSE 0 END),0) AS churn_cum_bytes
  FROM alloc a LEFT JOIN pc p ON p.alloc_callsite_id = a.callsite_id WHERE a.size > 0
),
chainstat AS (SELECT COUNT(*) AS n_nodes FROM chain),
frames AS (
  SELECT DISTINCT c.frame_id FROM chain ch
  JOIN stack_profile_callsite c ON c.id = ch.node_id WHERE c.frame_id IS NOT NULL
),
framestat AS (
  SELECT COUNT(*) AS n_frames,
         COALESCE(SUM(CASE WHEN f.name IS NOT NULL THEN 1 ELSE 0 END),0) AS n_named
  FROM frames fr LEFT JOIN stack_profile_frame f ON f.id = fr.frame_id
),
live_dumps AS (
  SELECT
    (SELECT MIN(a.ts) FROM alloc a JOIN pc p ON p.alloc_callsite_id = a.callsite_id
      WHERE p.live_cum = 1 AND a.size >= 1048576) AS path_alloc_ts,
    (SELECT MAX(a.ts) FROM alloc a JOIN pc p ON p.alloc_callsite_id = a.callsite_id
      WHERE p.live_cum = 1 AND a.size <= -1048576) AS path_free_ts,
    (SELECT MIN(ts) FROM alloc WHERE size >= 1048576) AS proxy_alloc_ts,
    (SELECT MAX(ts) FROM alloc WHERE size <= -1048576) AS proxy_free_ts
),
pick_a AS (SELECT x.ts, x.src FROM (
   SELECT path_alloc_ts AS ts, 'probe_live_block' AS src FROM live_dumps WHERE path_alloc_ts IS NOT NULL
   UNION ALL SELECT proxy_alloc_ts, 'size_proxy' FROM live_dumps
     WHERE (SELECT path_alloc_ts FROM live_dumps) IS NULL AND proxy_alloc_ts IS NOT NULL) x LIMIT 1),
pick_f AS (SELECT x.ts, x.src FROM (
   SELECT path_free_ts AS ts, 'probe_live_block' AS src FROM live_dumps WHERE path_free_ts IS NOT NULL
   UNION ALL SELECT proxy_free_ts, 'size_proxy' FROM live_dumps
     WHERE (SELECT path_free_ts FROM live_dumps) IS NULL AND proxy_free_ts IS NOT NULL) x LIMIT 1),
win AS (
  SELECT
    (SELECT d.ts FROM dumps d WHERE d.ts_end = (SELECT ts FROM pick_a)) AS a_ts,
    (SELECT ts FROM pick_a) AS a_ts_end,
    (SELECT d.ts FROM dumps d WHERE d.ts_end = (SELECT ts FROM pick_f)) AS f_ts,
    (SELECT ts FROM pick_f) AS f_ts_end
),
hold AS (
  SELECT
    CASE WHEN a_ts IS NOT NULL AND f_ts IS NOT NULL THEN f_ts - a_ts_end END AS lower_ns,
    CASE WHEN a_ts IS NOT NULL AND f_ts IS NOT NULL THEN f_ts_end - a_ts END AS upper_ns,
    COALESCE((SELECT src FROM pick_a),'unknown') AS src
  FROM win
),
post AS (
  -- 释放后的 dump：窗口**结束**严格晚于释放 dump 的结束（dur=0 时同一份不算）
  SELECT COUNT(*) AS n_post FROM dumps d
  WHERE (SELECT f_ts_end FROM win) IS NOT NULL AND d.ts_end > (SELECT f_ts_end FROM win)
),
l1 AS (
  SELECT COUNT(*) AS failed FROM (
    SELECT CASE WHEN n_data = 1 THEN 1 ELSE 0 END AS ok FROM agg
    UNION ALL SELECT CASE WHEN hp_cols = 5 THEN 1 ELSE 0 END FROM agg
    UNION ALL SELECT CASE WHEN alloc_cols = 6 THEN 1 ELSE 0 END FROM agg
    UNION ALL SELECT CASE WHEN n_dumps >= 1 THEN 1 ELSE 0 END FROM agg
    UNION ALL SELECT CASE WHEN n_rows > 0 THEN 1 ELSE 0 END FROM agg
    UNION ALL SELECT CASE WHEN severe = 0 THEN 1 ELSE 0 END FROM agg
  ) WHERE ok = 0
),
sym_missing AS (
  SELECT COUNT(*) AS failed FROM (
    SELECT CASE WHEN (SELECT n_nodes FROM chainstat) > 0 THEN 1 ELSE 0 END AS ok
    UNION ALL SELECT CASE WHEN (SELECT n_frames FROM framestat) > 0
                                AND (SELECT n_named FROM framestat) * 2
                                    >= (SELECT n_frames FROM framestat) THEN 1 ELSE 0 END
  ) WHERE ok = 0
),
uncertain AS (
  SELECT COUNT(*) AS u FROM (
    SELECT CASE WHEN live_cum_bytes = 0 AND (SELECT max_live FROM agg) >= 6*1048576
                THEN 1 ELSE 0 END AS x FROM sym
    UNION ALL SELECT CASE WHEN churn_cum_bytes = 0 AND (SELECT alloc_bytes FROM agg) >= 15*1048576
                THEN 1 ELSE 0 END FROM sym
  ) WHERE x = 1
),
l2beh AS (
  SELECT COUNT(*) AS failed FROM (
    SELECT CASE WHEN alloc_bytes BETWEEN 28*1048576*0.6 AND 28*1048576*1.4 THEN 1 ELSE 0 END AS ok FROM agg
    UNION ALL SELECT CASE WHEN alloc_bytes > 0 AND free_bytes BETWEEN alloc_bytes*0.8 AND alloc_bytes*1.2 THEN 1 ELSE 0 END FROM agg
    UNION ALL SELECT CASE WHEN max_live >= 6*1048576 THEN 1 ELSE 0 END FROM agg
    UNION ALL SELECT CASE WHEN free_rows_live > 0 THEN 1 ELSE 0 END FROM agg
    UNION ALL SELECT CASE WHEN (SELECT lower_ns FROM hold) IS NOT NULL
                              AND 8000000000 BETWEEN (SELECT lower_ns FROM hold)
                                                 AND (SELECT upper_ns FROM hold)
                         THEN 1 ELSE 0 END
    UNION ALL SELECT CASE WHEN (SELECT n_post FROM post) >= 1 THEN 1 ELSE 0 END
    UNION ALL SELECT CASE WHEN last_live <= 1048576 THEN 1 ELSE 0 END FROM agg
  ) WHERE ok = 0
)
SELECT
  CASE
    WHEN (SELECT failed FROM l1) > 0 THEN 'CAPTURE_FAILED'
    WHEN (SELECT failed FROM sym_missing) > 0 THEN 'CAPTURE_OK_SYMBOLS_MISSING'
    WHEN (SELECT u FROM uncertain) > 0 THEN 'CAPTURE_OK_SYMBOLS_UNCERTAIN'
    WHEN (SELECT failed FROM l2beh) > 0 THEN 'CAPTURE_OK_BEHAVIOR_INCOMPLETE'
    ELSE 'PASS'
  END AS status,
  (SELECT failed FROM l1) AS l1_failed,
  (SELECT failed FROM sym_missing) AS symbol_missing_failed,
  (SELECT u FROM uncertain) AS symbol_uncertain_count,
  (SELECT failed FROM l2beh) AS l2_behavior_failed,
  'name_candidates=' || (SELECT n_name FROM agg) ||
  ', data_bearing=' || (SELECT n_data FROM agg) ||
  ', dumps=' || (SELECT n_dumps FROM agg) ||
  ', rows=' || (SELECT n_rows FROM agg) ||
  ', alloc_mib=' || ROUND((SELECT alloc_bytes FROM agg)/1048576.0, 2) ||
  ', free_mib=' || ROUND((SELECT free_bytes FROM agg)/1048576.0, 2) ||
  ', max_live_mib=' || ROUND((SELECT max_live FROM agg)/1048576.0, 2) ||
  ', last_live_mib=' || ROUND((SELECT last_live FROM agg)/1048576.0, 2) ||
  ', hold_src=' || (SELECT src FROM hold) ||
  ', hold_bounds_s=[' || COALESCE(CAST(ROUND((SELECT lower_ns FROM hold)/1e9,2) AS TEXT),'?') ||
  ',' || COALESCE(CAST(ROUND((SELECT upper_ns FROM hold)/1e9,2) AS TEXT),'?') || ']' ||
  ', post_release_dumps=' || (SELECT n_post FROM post) ||
  ', severe_stats=' || (SELECT severe FROM agg) AS detail;


-- [S5] 调用栈：self vs cumulative（递归 parent_id）+ 未解析部分
WITH RECURSIVE name_cands AS (SELECT COUNT(*) AS n_name FROM process WHERE (name = 'memprobe' OR name GLOB '*/memprobe')),
data_cands AS (
  SELECT COUNT(DISTINCT h.upid) AS n_data FROM heap_profile h
  JOIN process p ON p.upid = h.upid
  WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc'
),
target AS (
  SELECT CASE WHEN (SELECT n_data FROM data_cands) = 1 THEN
    (SELECT MIN(h.upid) FROM heap_profile h JOIN process p ON p.upid = h.upid
      WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc') END AS upid
),
alloc AS (
  SELECT a.callsite_id, a.size FROM heap_profile_allocation a, target t
  WHERE a.upid = t.upid AND a.heap_name = 'libc.malloc'
),
chain(alloc_callsite_id, node_id, depth) AS (
  SELECT DISTINCT callsite_id, callsite_id, 0 FROM alloc WHERE callsite_id IS NOT NULL
  UNION ALL
  SELECT ch.alloc_callsite_id, c.parent_id, ch.depth + 1
  FROM chain ch JOIN stack_profile_callsite c ON c.id = ch.node_id
  WHERE c.parent_id IS NOT NULL AND ch.depth < 64
),
nf AS (
  SELECT ch.alloc_callsite_id, ch.depth, f.name AS frame_name
  FROM chain ch
  LEFT JOIN stack_profile_callsite c ON c.id = ch.node_id
  LEFT JOIN stack_profile_frame f ON f.id = c.frame_id
),
flags AS (
  SELECT alloc_callsite_id,
         MAX(CASE WHEN frame_name GLOB '*probe_live_block*' AND depth = 0 THEN 1 ELSE 0 END) AS live_self,
         MAX(CASE WHEN frame_name GLOB '*probe_live_block*' THEN 1 ELSE 0 END) AS live_cum,
         MAX(CASE WHEN frame_name GLOB '*probe_churn_cycle*' AND depth = 0 THEN 1 ELSE 0 END) AS churn_self,
         MAX(CASE WHEN frame_name GLOB '*probe_churn_cycle*' THEN 1 ELSE 0 END) AS churn_cum,
         MAX(CASE WHEN frame_name IS NULL THEN 1 ELSE 0 END) AS has_null_frame
  FROM nf GROUP BY alloc_callsite_id
)
SELECT 'probe_live_block' AS function_name,
       COALESCE(SUM(CASE WHEN f.live_self = 1 THEN a.size ELSE 0 END),0) AS self_bytes,
       COALESCE(SUM(CASE WHEN f.live_cum = 1 THEN a.size ELSE 0 END),0) AS cumulative_bytes
FROM alloc a LEFT JOIN flags f ON f.alloc_callsite_id = a.callsite_id
WHERE a.size > 0 AND f.live_cum = 1
UNION ALL
SELECT 'probe_churn_cycle',
       COALESCE(SUM(CASE WHEN f.churn_self = 1 THEN a.size ELSE 0 END),0),
       COALESCE(SUM(CASE WHEN f.churn_cum = 1 THEN a.size ELSE 0 END),0)
FROM alloc a LEFT JOIN flags f ON f.alloc_callsite_id = a.callsite_id
WHERE a.size > 0 AND f.churn_cum = 1
UNION ALL
SELECT '(unresolved)', COALESCE(SUM(a.size),0), COALESCE(SUM(a.size),0)
FROM alloc a LEFT JOIN flags f ON f.alloc_callsite_id = a.callsite_id
WHERE a.size > 0 AND (a.callsite_id IS NULL OR f.alloc_callsite_id IS NULL OR f.has_null_frame = 1);


-- [S6] 符号/映射：build_id 在 stack_profile_mapping；只统计目标调用栈帧
WITH RECURSIVE name_cands AS (SELECT COUNT(*) AS n_name FROM process WHERE (name = 'memprobe' OR name GLOB '*/memprobe')),
data_cands AS (
  SELECT COUNT(DISTINCT h.upid) AS n_data FROM heap_profile h
  JOIN process p ON p.upid = h.upid
  WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc'
),
target AS (
  SELECT CASE WHEN (SELECT n_data FROM data_cands) = 1 THEN
    (SELECT MIN(h.upid) FROM heap_profile h JOIN process p ON p.upid = h.upid
      WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc') END AS upid
),
alloc AS (
  SELECT a.callsite_id FROM heap_profile_allocation a, target t
  WHERE a.upid = t.upid AND a.heap_name = 'libc.malloc' AND a.size > 0
),
chain(node_id, depth) AS (
  SELECT DISTINCT callsite_id, 0 FROM alloc WHERE callsite_id IS NOT NULL
  UNION ALL
  SELECT c.parent_id, ch.depth + 1
  FROM chain ch JOIN stack_profile_callsite c ON c.id = ch.node_id
  WHERE c.parent_id IS NOT NULL AND ch.depth < 64
),
frames AS (
  SELECT DISTINCT c.frame_id FROM chain ch
  JOIN stack_profile_callsite c ON c.id = ch.node_id WHERE c.frame_id IS NOT NULL
)
SELECT
  (SELECT COUNT(*) FROM frames) AS frames_in_target_chains,
  (SELECT COUNT(*) FROM frames fr JOIN stack_profile_frame f ON f.id = fr.frame_id
     WHERE f.name IS NOT NULL) AS named_frames,
  (SELECT COUNT(*) FROM frames fr JOIN stack_profile_frame f ON f.id = fr.frame_id
     WHERE f.name IS NULL) AS unnamed_frames,
  (SELECT COUNT(DISTINCT m.build_id) FROM frames fr
     JOIN stack_profile_frame f ON f.id = fr.frame_id
     JOIN stack_profile_mapping m ON f.mapping = m.id
     WHERE m.build_id IS NOT NULL AND m.build_id <> '') AS distinct_build_ids,
  (SELECT COUNT(*) FROM frames fr
     JOIN stack_profile_frame f ON f.id = fr.frame_id
     LEFT JOIN stack_profile_mapping m ON f.mapping = m.id
     WHERE m.id IS NULL) AS frames_without_mapping;


-- [S7] 严重采集错误明细
SELECT name, severity, source, value, description
FROM stats
WHERE value > 0 AND (name GLOB '*buffer_overrun*' OR name GLOB '*data_loss*'
                     OR name GLOB 'heapprofd_*error*')
ORDER BY name;


-- [S8] 数值与 dump 时间轴证据
WITH RECURSIVE name_cands AS (SELECT COUNT(*) AS n_name FROM process WHERE (name = 'memprobe' OR name GLOB '*/memprobe')),
data_cands AS (
  SELECT COUNT(DISTINCT h.upid) AS n_data FROM heap_profile h
  JOIN process p ON p.upid = h.upid
  WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc'
),
target AS (
  SELECT CASE WHEN (SELECT n_data FROM data_cands) = 1 THEN
    (SELECT MIN(h.upid) FROM heap_profile h JOIN process p ON p.upid = h.upid
      WHERE (p.name = 'memprobe' OR p.name GLOB '*/memprobe') AND h.heap_name = 'libc.malloc') END AS upid
),
dumps AS (
  SELECT h.ts, h.ts_end, h.dur FROM heap_profile h, target t
  WHERE h.upid = t.upid AND h.heap_name = 'libc.malloc'
),
alloc AS (
  SELECT a.ts, a.size FROM heap_profile_allocation a, target t
  WHERE a.upid = t.upid AND a.heap_name = 'libc.malloc'
),
deltas AS (SELECT ts, SUM(size) AS delta FROM alloc GROUP BY ts),
axis AS (SELECT ts_end AS ts FROM dumps UNION SELECT ts FROM deltas),
live AS (SELECT ax.ts, COALESCE(d.delta,0) AS delta FROM axis ax LEFT JOIN deltas d ON d.ts=ax.ts),
cum AS (
  SELECT ts, SUM(delta) OVER (ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS live_bytes
  FROM live
)
SELECT
  (SELECT n_name FROM name_cands) AS name_candidates,
  (SELECT n_data FROM data_cands) AS data_bearing_upids,
  (SELECT COUNT(*) FROM dumps) AS dumps,
  (SELECT COALESCE(MIN(dur),0) FROM dumps) AS min_dump_dur_ns,
  (SELECT COALESCE(MAX(dur),0) FROM dumps) AS max_dump_dur_ns,
  (SELECT COUNT(*) FROM alloc) AS alloc_rows,
  (SELECT COALESCE(SUM(size),0) FROM alloc WHERE size > 0) AS alloc_bytes,
  (SELECT COALESCE(-SUM(size),0) FROM alloc WHERE size < 0) AS free_bytes,
  (SELECT COALESCE(MAX(live_bytes),0) FROM cum) AS max_live_bytes,
  (SELECT COALESCE((SELECT live_bytes FROM cum ORDER BY ts DESC LIMIT 1),0)) AS last_live_bytes,
  (SELECT COUNT(*) FROM alloc WHERE size <= -1048576) AS free_rows_live;

-- 判读边界（v58.2）：
--   * 数据存在 = S2 全 1 且 S8.alloc_rows>0；实验通过 = S4.status='PASS'。
--   * 持有时间只能给区间：alloc/free 只知道落在哪个 dump 窗口，不是调用时刻。
--   * post_release_dumps=0 表示**未捕获释放后的完整观察窗口**（不是"内存没降"）。
--   * 空闲期 heapprofd 可能不产 dump（实测），dump 数少于 duration/interval 是预期现象。
