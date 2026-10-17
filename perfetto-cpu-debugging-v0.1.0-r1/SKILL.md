---
name: perfetto-cpu-debugging
description: "Use for Linux/Android/RDK CPU performance diagnostics with Perfetto: high CPU usage, periodic CPU spikes, slow or blocked threads, runnable scheduling latency, CPU frequency changes, native CPU callstack hotspots, profiling configurations, PerfettoSQL and trace validation."
---

# Perfetto CPU 调试（v0.1.0-r1 Candidate）

目标：把“CPU 高 / 线程没及时执行 / 频率异常 / 哪个函数耗时”转成**最小必要采集 → 实际证据 → 有界结论**。默认中文。

## 1. 场景路由

| 用户症状 | 首选路线 | 读取 |
|---|---|---|
| CPU 占用高、某核满载、周期性尖峰 | `overview` / `scheduling`：sched_switch → CPU 时间桶、线程、spike | [调度](references/01-scheduling.md) |
| CPU 不高但任务延迟、疑似调度不及时 | `scheduling`：sched_switch + sched_waking，thread_state 中 Runnable/阻塞分开 | [调度](references/01-scheduling.md) |
| 怀疑降频、DVFS、大小核或 idle | `frequency`（**轻量**）：cpufreq 轮询 + `power/cpu_frequency`/`cpu_idle`（有则采），默认**不含 sched**；需要调度归属时显式 `--with-sched` | [频率](references/02-frequency.md) |
| 想定位 CPU 热点函数、采样调用栈 | `profiling`：linux.perf（条件可用），必要时加 sched | [Profiling](references/03-profiling.md) |

所有路线都读取 [平台执行](references/04-platforms.md)、[验收和停止条件](references/05-quality.md)、[UI](references/06-ui.md)。官方来源见 [索引](references/sources.md)。

## 2. 最小探测与执行

- 优先沿用已知、已验证的环境。只读探测：目标机 `sh scripts/survey.sh` 和 `sh scripts/survey.sh --events`。核实内核事件、`tracebox` / 主机 TP 版本、目标进程与线程、可写输出目录及容量。
- 主机：`python3 scripts/make_config.py <route> --events available_events.txt --duration-ms 15000 > cpu.pbtxt`；profile 路线需 `--target ACTUAL_CMDLINE_BASENAME`。
- 主机：`python3 scripts/validate_config.py --check-resources`；`python3 scripts/validate_config.py cpu.pbtxt`。若有**对应板端采集器版本**的 descriptor，增加 `--descriptor-set /abs/trace_config.desc`。静态 PASS 不等于运行条件、实际数据 PASS。
- Linux/X5 板端按 [04-platforms](references/04-platforms.md) 使用完整的采集启动、结束、Flush、SCP 流程。不要改变全局 `perf_event_paranoid` / `kptr_restrict`、其他 tracing 会话或生产业务。
- 从 Trace 先做清点，每个文件一条 SQL、单独执行（v57.1/v58.2 的 `query -f` 不支持一次多结果集）：
  `00-inventory.sql`（找 UPID）→ `00a-trace-bounds.sql`（范围）→ `00b-thread-states.sql`（实际 state 码）
  → `00c-counter-tracks.sql`（采到哪些 counter）→ `00d-stats.sql`（非零非 info，即 data loss/错误）。
  替换 SQL 中 `target_upid=-1`；只按**真实 trace**的纳秒时间轴解释结果。

## 3. 关键口径

- CPU on-CPU 时间来自 `sched_slice` 的区间，**不是**进程 CPU 百分比或墙钟时长；多核下总 CPU 时间可大于观测时间。
- `Running` 才消耗 CPU；`R`/`R+` 为 **Runnable 等待**（不等于真正运行）；`S`/`D` 为等待/阻塞，不可全归责为调度器。
- 使用桶与 sched 区间**求交集**，不能把整段 `dur` 计入开始桶；长间隔和跨桶窗口须正确裁剪。
- `power/cpu_frequency` 是**变化事件**，短 trace 无事件不等于频率为零；优先结合 `cpufreq_period_ms` 轮询。频率与慢同窗不直接构成降频因果。
- 频率结论前先跑 `sql/04a-frequency-inventory.sql`：无 `cpufreq` 轨道或无样本 → **UNKNOWN**（scheduling 路由不采频率属正常），不得读成 0 MHz；`cpufreq` 原始值是 kHz，展示 MHz 需 /1000。
- `linux.perf` 是**采样**，必须检查运行权限、数据源、`perf_sample`、符号。样本数不是某函数精确执行次数或 CPU 毫秒；Profiler 本身可能影响性能。
- 没有业务打点/日志，不能用 Runnable 时间直接当业务延迟，也不能仅凭 CPU 高就断言卡顿根因。

## 4. 交付与停止

给出：**假设与路由、实际配置、主机/目标命令、Trace 验收、SQL 和 UI 操作、证据结论、局限与最小下一步**。证据标记 `PASS` / `FAIL` / `UNKNOWN`，无真实数据不编造运行结果。

**最小充分证据原则：**一次受控采集已足以回答问题则及时交付，不自行延伸为多轮压力、故障注入或 UI 截图自动化。只有关键证据缺失/矛盾才提出下一次补采并说明目的；影响生产业务或破坏性操作须先获授权。已有 `.pftrace` 时优先分析，不重复上板。

本版是离线候选，未承诺已在 X5 上验证 CPU 频率/`linux.perf`/UI 全流程。验证边界见 [TEST_REPORT.md](TEST_REPORT.md)。
