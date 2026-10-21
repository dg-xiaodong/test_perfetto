# 综合采集配置的组合说明（本目录所有 cfg 的来源与差异）

原则：**只复用四个 Skill 中"已验证存在"的数据源块**，逐块注明来源与改动；不把 Skill 配置当黑盒。
本目录同时保留四个 Skill 的原样 configs（`*.pbtxt` 拷贝），便于逐字段对照。

## 1. `overview_120s.cfg`（= 最终交付 `overview_system_app.pftrace` 的配置）

| 数据源块 | 来源 | 本机改动 | 理由 |
|---|---|---|---|
| `buffers { size_kb: 65536 RING_BUFFER }` | memory Skill `configs/overview.pbtxt`（8192 KiB）→ 放大 | 64 MiB | 120 s + perf 采样；`traced_buf_bytes_written` 实测 12.4 MB，无 overwrite（`traced_buf_bytes_overwritten=0`） |
| `linux.process_stats`（scan_all + 1000 ms） | CPU / Memory / Scheduling 三家一致 | 无 | RSS、进程/线程发现 |
| `linux.sys_stats`（meminfo/vmstat 1000 ms + `STAT_CPU_TIMES` + `cpufreq_period_ms 500`） | Memory `overview.pbtxt` + CPU `make_config.py frequency`（`cpufreq_period_ms`） | 合并两块字段 | 同一 Trace 内同时拿到系统内存与 CPU 时间/频率；本板无 `power/cpu_frequency` tracepoint，必须用轮询 |
| `linux.system_info` | 官方数据源（Skill 未用） | 新增 | 记录 uname/版本，便于交付自证；`**本次临时补充**` |
| `track_event`（disabled "*"，enable pipeline/memory/sync/io/demo） | Latency `configs/track-event.pbtxt` | 仅改 category 列表 | 应用的 5 个 category 来自 RUNNING_BRIEF；关掉其余避免噪声 |
| `linux.perf`（SW_CPU_CLOCK 99 Hz + callstack + `scope.target_pid` + `ring_buffer_pages: 64`） | CPU `make_config.py profiling`（`target_cmdline` + `kernel_frames: true`） | `target_cmdline` → `target_pid`；`kernel_frames: false`；新增 ring pages/max_daemon_memory | 实测 `target_cmdline` 不减少系统级采样（G2）；`target_pid` 由采集脚本按 `run/app.pid` 注入 |
| **未包含** `linux.ftrace` | CPU/Scheduling/Memory 三家 overview 都含 | **删除** | 本板 tracefs 不存在（`survey.sh` = TRACEFS UNKNOWN），加上会导致数据源启动失败 |

## 2. `blockwake.cfg`（= `sched_blockwake.pftrace` 的配置）

| 块 | 来源 | 改动 |
|---|---|---|
| `linux.process_stats` / `track_event` | 同上 | 无 |
| `linux.perf` timebase `SW_CONTEXT_SWITCHES period: 1` + `kernel_frames: true` + `target_pid` | **Skill 未提供**（CPU Skill 只有 SW_CPU_CLOCK 频率配方） | 本次临时补充，属于"官方 Perfetto 能力 + 自行验证"，非 Skill 已实现 |

目的：在无 `sched_switch` 的板卡上取得"每次上下文切换"的事件级调用栈（阻塞点归因）。
代价：per-CPU 每切换一次采样一次，本板 `perf_cpu_lost_records` 合计 28,688（采样丢失明显，
见 `results/custom-blockwake/` 与 `traces/sched_blockwake.pftrace` 的 stats），结论只能作 E2。

## 3. `light_60s.cfg`（开销对照）

与 `overview_120s.cfg` 完全相同但**去掉 `linux.perf`**。用途：验证 perf 采样是否扰动了
应用自身的时延/队列指标。结论：没有显著差异（见 `GROUND_TRUTH_COMPARISON.md` §开销对照）。

## 4. 与四个 Skill 原配置的兼容性结论

- 四个 Skill 的 `buffers` 都只写 1–3 个 buffer 且部分用 `target_buffer: 0/1/2` 下标；
  本次只用 1 个 buffer、不写 `target_buffer`，所有数据源落默认 buffer 0 —— 语义等价、更省内存。
- `linux.sys_stats` 的 `meminfo_counters` 枚举在 4 家配置中不一致（Memory 列了 13 个，CPU 配置不列），
  本机实测 `meminfo` 类型 counter 默认就会产出全部字段（`MemTotal/MemFree/...` 121 点），
  因此**不写枚举**也能拿到数据；这与 Memory Skill"必须列枚举"的写法不同，已在本报告中标注差异。
- 版本：所有配置按 v58.2 collector 语法书写；主机 TP v57.1 可解析（未逐字段校验 schema，
  `SCHEMA_UNKNOWN`），已在质量表中标注。
