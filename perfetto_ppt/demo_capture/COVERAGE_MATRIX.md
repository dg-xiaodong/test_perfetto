# 能力覆盖与质量验收（逐项 PASS / FAIL / UNKNOWN）

判定规则：只有**真实数据行存在且含义正确**才算 PASS；查询能跑但返回 0 行一律不算 PASS；
平台不具备该能力时写 FAIL 并给出真实原因；无法判定写 UNKNOWN。

- 主证据 Trace：`traces/overview_system_app.pftrace`（120 s，sha256 `250b95cc…`）
- 补采 Trace：`traces/sched_blockwake.pftrace`（30 s，`beadb4f2…`）、`traces/light_noperf_60s.pftrace`（60 s）
- 查询原文与原始输出：`results/skill/*/`、`results/custom/*/`（每个目录含 query.sql / stdout.csv / stderr.txt / rc.txt）
- 采集配置：`configs/`；采集日志：`logs/captures/*/`；工具版本：`logs/ENVIRONMENT.md`

## 1. 任务要求的 14 项能力

| # | 能力 | 判定 | 真实数据（行数/数值） | 证据文件 | 说明 |
|---|---|---|---|---|---|
| 1 | CPU scheduling slices | **FAIL** | `sched_slice` = 0 行 | `results/skill/cpu-01-cpu-usage/stdout.csv`、`results/custom/c19-slice-counts` | 内核无 tracefs/`CONFIG_FTRACE`，无 sched_switch；`/sys/kernel/tracing` 不存在，kallsyms 无 `__tracepoint_sched_switch` |
| 2 | Process / Thread 信息 | **PASS** | 358 process / 409 thread；目标 pid 1090、UPID 179、14 线程 | `results/skill/sched-00-threads`、`results/overview/03-target` | 含 comm 名；TracingMuxer 为 SDK 线程 |
| 3 | RSS / 系统 Memory Counter | **PASS** | 目标 `mem.rss` 5,620→17,708 kB，`mem.rss.anon` 1,027→13,185 kB；系统 meminfo 10 类各 121 点 | `results/custom/c12-rss-target`、`c13-meminfo-system`、`results/skill/mem-01-rss-timeline` | 系统 meminfo 值单位 kB，与 /proc/meminfo 口径一致 |
| 4 | Native Heap Profile | **FAIL** | `heap_profile_allocation` = 0 行；heapprofd 探针 Trace 仅 658 B | `results/skill/mem-03-native-live`、`traces/native_heap_heapprofd_unavailable.pftrace` | 见 §3：Linux 版 traced_probes/tracebox 未含 `android.heapprofd` 数据源 |
| 5 | Heap Callstack / Flamegraph | **FAIL** | 同上（无 heap 分配栈） | 同上 | 仅有 **CPU 采样**调用栈，不等价于分配调用栈 |
| 6 | CPU frequency / idle | **频率 PASS / idle FAIL** | cpufreq 8 核 × 241 点，300–1500 MHz | `results/skill/cpu-04-cpu-frequency`、`results/custom/c14-cpufreq`、`c21-phase-cpufreq` | idle 需 `power/cpu_idle` tracepoint（缺失）；`cpu.times.idle_ns` 为累计时间，非 idle 状态机 |
| 7 | CPU Profiling Callstack | **PASS** | 92,271 样本；叶子函数可读（`InferenceConv3x3`/`InferenceGemm`/`CpuWork`/`ContendSpin`） | `results/skill/cpu-07-perf-samples`、`results/custom/c09-perf-hotspots`、`c10-perf-per-thread` | 采样≠调用次数；有 2,761 条 perf 记录被内核丢弃（约 3.0%） |
| 8 | Runnable / Sleeping | **FAIL（仅代理）** | `thread_state` = 0 行；应用自报 `ThreadsRunning` 1–4、`ThreadsBlocked` 恒 0；`CvWait` 3,016 条 / 112.6 s | `results/skill/cpu-02-thread-states`、`results/custom/c15-sched-proxy-counters`、`c16-cv-wait-wake` | 应用层计数不是调度器事实 |
| 9 | Waker / Block-Wake | **FAIL（E2 代理可得）** | 事件级：`SW_CONTEXT_SWITCHES` 样本 37,507 条，含 kernel+user 栈；唤醒者/`waker_utid` 无数据 | `results/skill/sched-07-wakeup-links`（0 行）、`results/custom-blockwake/c22-blocking-callstacks.csv` | 有"在哪里阻塞"的真实栈；无"谁唤醒"（需 sched_waking） |
| 10 | Application Slice | **PASS** | 42,917 条，5 个 category，含嵌套 depth 0/1 | `results/custom/c01`、`c02`、`c03` | |
| 11 | Application Counter | **PASS** | 163,659 点；14 个应用 counter（QueueDepth/InflightFrames/E2E/LiveAllocatedBytes/RssKb/ThreadsRunning/…） | `results/custom/c07-app-counters` | |
| 12 | Cross-thread Flow | **PASS** | `flow` = 7,463 行；4 种跨线程边各 ~1,866 条 | `results/custom/c04`、`c05`、`results/skill/latency-02-flow` | 5 个阶段线程互不相同，UI 可画跨轨箭头 |
| 13 | Frame ID / E2E Latency | **PASS** | 233 个带 `debug.frame_id`+`debug.e2e_ms` 的 `FramePipeline`；avg 341.7 / max 1630 ms | `results/custom/c06-frame-e2e` | frame_id 为自增 u64，重启归 1（本轮 pid 1090 未重启） |
| 14 | SQL / Debug Track 所需数据 | **PASS** | 见 `results/custom/c08-queue-depth-debug-track`（240 点） | 同左 | 可直接粘贴到 UI Query 页 / Add Debug Track |

## 2. 附加验收（任务第一步/第三步要求）

| 项 | 判定 | 证据 |
|---|---|---|
| tracebox 版本 | PASS | v58.2-add693d8b（`logs/ENVIRONMENT.md`） |
| Trace Processor 版本 | **PASS（版本不匹配已记录）** | 主机 v57.1-c59f57dd4 < 采集器 v58.2 → 版本差在报告中明示 |
| tracefs 挂载与事件清单 | PASS（探测结论：不存在） | `logs/captures/*/env.txt`、`logs/STEP1_PLATFORM.md` |
| perf_event 权限与能力 | PASS | root + paranoid=2；`perf stat/record` 实测可用；`perf_event_mlock_kb=516` |
| 目标 basename/PID/TID | PASS | pid 1090，14 tid（`results/skill/sched-00-threads`） |
| SDK System Backend 接入 | PASS | `perfetto --query` 显示 producer `pf-demo-x5` 注册 `track_event`（categories 全 5 个） |
| heapprofd preload 生效 | **FAIL** | 常驻进程 `environ` 无 `LD_PRELOAD`；见 §3 |
| tracing socket 冲突 | **PASS（已定位并规避）** | 系统 sockets 由常驻 `traced` 持有；`tracebox --system-sockets` 会抢占/替换（实测导致 CLI 失去连接）；改用 `perfetto` CLI + 额外 `tracebox traced_perf` producer |
| Trace 正常退出 | PASS | `start_rc=0`、`env.txt` 记录起止 uptime，无重启 |
| 文件存在且非空 | PASS | 6,854,816 B |
| duration 与预期相符 | PASS | 119.995 s（配置 120 s） |
| 目标进程在 Trace 中 | PASS | UPID 179 / pid 1090 |
| stats 无未解释严重错误 | **PASS（有一处已解释的丢样）** | `perf_cpu_lost_records` 合计 2,761（3.0%），应用 buffer `data_loss_*`=0 |
| 板端/主机 SHA256 一致 | PASS | `logs/captures/overview_120s_v4/env.txt` 与 `logs/TRACE_SHA256SUMS.txt` 一致 |

## 3. Native Heap 为什么是 FAIL（逐层排除，不是"没采到"含糊结论）

1. `libheapprofd_glibc_preload.so` 存在于 `/userdata/perfetto-training-demo/lib/`；
2. 但常驻进程 `pf-demo-x5` 的 `/proc/<pid>/environ` **没有** `LD_PRELOAD`，`maps` 里也没有该库；
3. 常驻 `traced_probes` 的注册数据源清单（`perfetto --query`）**没有** `android.heapprofd`；
4. 板上 `traced_probes`、`tracebox` 二进制内 `strings | grep android.heapprofd` = 0 —— 该数据源
   只在 Android in-tree 构建的 traced builtin producer 中存在（Perfetto 源码
   `src/traced/service/builtin_producer.cc` 注释明确 "only ever used in Android in-tree builds"）；
5. 用 `tracebox` autostart + `android.heapprofd` 配置实采 8 s：退出码 0、文件 658 B、
   `heap_profile_allocation` 0 行 → **采集源未注册**（不是 preload 未生效、不是进程名不匹配、
   不是无 dump、也不是无符号）。

最小修复（给窗口 A）：
- 部署 Linux 版 **`heapprofd` 可执行文件**（Perfetto `src/profiling/memory` 目标，v58.2），
  以 `heapprofd --background` 作为独立 producer 连到同一 `traced`；或改造 `traced` 的 builtin
  producer 使 `android.heapprofd` 在 Linux 注册；
- 用 `LD_PRELOAD=/userdata/.../libheapprofd_glibc_preload.so` **启动**专用实例
  （不能对已运行进程 attach）；
- 采集配置加 `sampling_interval_bytes`、`continuous_dump_config`，并用未 strip 的
  `pf-demo-x5`（自带 `.symtab`）做符号化。

## 4. 结论

- 14 项能力：**PASS 9 项**（#2、#3、#6-频率、#7、#10、#11、#12、#13、#14）、
  **FAIL 5 项**（#1、#4、#5、#8、#9）；其中 #6 拆为 freq PASS + idle FAIL。
- 失败项全部有平台级真实原因与可执行的最小修复方向，**没有用 0 行结果冒充 PASS**。
