# 第一轮独立诊断（冻结稿 · 未读取 Ground Truth 前）

生成时间：2026-10-21（本机时区）
冻结方式：本文件先写入并计算 SHA256，之后才读取
`perfetto_ppt/demo_fixture/PRIVATE_GROUND_TRUTH.md`。后续对照意见另写在
`GROUND_TRUTH_COMPARISON.md`，不修改本文件。

## 0. 数据基线（全部来自真实采集）

| 项 | 值 |
|---|---|
| 综合 Trace | `traces/overview_system_app.pftrace`，sha256 `250b95cc…9a225a`，6,854,816 B |
| 采集方式 | `perfetto` CLI → 板上常驻 `traced`（system sockets），`--background-wait` |
| 采集时长 | 120 s（trace_bounds 697.754 s → 817.749 s，CLOCK_BOOTTIME 域） |
| 目标进程 | `pf-demo-x5` pid **1090**（UPID 179），14 线程 |
| 应用数据 | slice 42,917；flow 7,463；counter 163,659；TrackEvent category: pipeline/memory/sync/io/demo |
| CPU 采样 | `linux.perf`（SW_CPU_CLOCK 99 Hz，`target_pid: 1090`）→ 92,271 样本，1 个 perf session |
| 内核 ftrace | **0 行 `sched_slice` / `thread_state` / `ftrace_event`**（tracefs 不存在） |
| 平台 | RDK X5，Linux 6.1.83-DR-PL5.1_V1.1.1，8 核，`perf_event_paranoid=2`，`perf_event_mlock_kb=516` |
| 数据完整性 | 应用缓冲 `data_loss_*` 全 0；`perf_cpu_lost_records` 合计 **2,761**（约 3.0% 采样丢失，TP 自身 Trace health 也报此项） |

采集窗口覆盖 **cycle 14/15/16 共 2.5 个 48 s 周期**（每周期 6 个 8.01 s 阶段，阶段序号由
`PhaseChange` 的 `debug.cycle/debug.phase` 给出，实测与板上 `pf-demo-x5.log` 的 `PHASE` 行
`boot_ns` 相差 11 µs，证明 trace ts 与日志同为 CLOCK_BOOTTIME）。

## 1. 程序行为画像（Trace 直接可证）

- 5 级流水线，5 个线程各跑一级：`SyntheticCapture`(pf-capture) → `Preprocess`(pf-preproc)
  → `InferenceStub`(pf-infer) → `Postprocess`(pf-postproc) → `Output`(pf-output)。
  级间用 **真实 TrackEvent Flow** 连接：实测 4 种边、各约 1,866 条
  （`c05-flow-shape`），跨线程（`c04-cross-thread-flows` 显示 from_thread ≠ to_thread）。
- 线程内嵌套：`InferenceStub`(depth 0) 内含 `infer.kernel_conv3x3`、
  `infer.kernel_gemm`(depth 1，parent_id 指向父 slice)；`Preprocess` 内含
  `preproc.resize`/`preproc.normalize`；`Postprocess` 内含 `postproc.filter_stub`
  （`c03-slice-nesting`）。
- 帧维度：`FramePipeline` 是 **custom/async TrackEvent 轨道**（无 thread_track、无
  process_track 绑定，`c06b-track-binding`），带 `debug.frame_id`、`debug.e2e_ms`。
  全窗口 233 帧：avg 341.7 ms，min 7 ms，max **1630 ms**。
- 周期结构（`c17`/`c20`）：BASELINE → CPU_BURST → SCHED_CONTENTION → MEMORY_PULSE →
  SYNC_IO → MIXED_PIPELINE，每段 8.01 s，整周期 48 s。

## 2. 构造出的异常（Trace 中被捕获的部分）

### A. SCHED_CONTENTION：CPU 竞争（最强异常）
| 证据 | 数值 | 出处 |
|---|---|---|
| 帧端到端均值 | **981 ms**（max 1630 ms）vs SYNC_IO 26 ms | `c20`/e2e by phase |
| `InferenceStub` 墙钟均值 | **85.5 ms**（max 180.7）vs BASELINE 16.4 / SYNC_IO 11.5 | per-phase stage |
| `contend.spin1/2` slice | 170/173 条，avg 115 ms，max 200 ms，且 **只在 SCHED_CONTENTION 出现**（每阶段 128–129 条） | `c01`,`c20` |
| 应用自报 `ThreadsRunning` | 平均 **3.63–3.75**（其它阶段 1.1–2.0） | `c20` |
| 应用自报 `SchedWakeupOvershootMs` | 峰值 **20.0–21.4 ms**（其它阶段 ~0.07–1.1 ms） | `c20`,`c15` |
| 目标进程 perf 样本 | 该阶段 293–295（CPU_BURST 413–436），说明 pf-infer 拿到 CPU 更少 | `c20` |
| 阻塞栈 | pf-contend1/2 以 `hrtimer_nanosleep` 为主，pf-infer 同时段出现 `futex_wait` | `c22` |

判读：两个 spinner 线程与该阶段的延迟抬升**同窗口出现**；`pf-infer` 的 in-slice 时间
被拉长、采样数下降是 CPU 被抢的典型表现。但**没有 sched_switch/thread_state**，
无法证明"同一 CPU""Runnable 占比""抢占次数"，故只能到 **E2（事件关联）**，
不能宣称为 E3（机制根因）。

### B. MIXED_PIPELINE：队列积压（次强异常）
| 证据 | 数值 |
|---|---|
| `QueueDepth` | 均值 11.3–11.8，最大 **22** |
| `InflightFrames` | 最大 **25** |
| 帧端到端 | 均值 **719 ms**，max 1459 ms |
| `CvWait`/`QueueWait.output` | 该阶段 CvWait 均值 48.7 ms（其他 31.8–53.6）；QueueWait.output 58.9 ms |

判读：生产快于消费造成积压（Inflight 25 > 深度 22），端到端被排队拉长。
这是**队列/反压**问题，不是 CPU 问题（该阶段 ThreadsRunning 只有 1.75）。

### C. MEMORY_PULSE：RSS 脉冲（真实，但未致延迟）
| 证据 | 数值 |
|---|---|
| 进程 `mem.rss` | 5.6 MB → **17.3 MB** 周期性抬升（`c12`） |
| `mem.rss.anon` | 1.03 MB → **12.57 MB**（脉冲部分为 anon） |
| 应用 `LiveAllocatedBytes` | 0 → **12,582,912 B**，`MemoryPulse.alloc/hold/free` 各 6 次，hold 每次 4.0 s |
| 该阶段帧延迟 | 均值 **46 ms**（max 249），**低于** BASELINE 190 ms |

判读：内存脉冲与尾延迟**不同窗**（此阶段帧反而更快），不能把 RSS 尖峰当作延迟根因。
另外 `mem.rss.watermark`=17.75 MB 与 RSS 同步，`LiveAllocatedBytes` 是应用自报，
heapprofd 缺失（见 §4），因此**无法**给出分配调用栈与 live heap 归属。

### D. CPU_BURST / SYNC_IO
- CPU_BURST：`cpufreq` 阶段均值 **1369–1500 MHz**（BASELINE 413–488 MHz），帧延迟 56 ms，
  perf 样本最多（413–436）。CPU 忙但延迟反而低 → 说明该阶段是**有效计算**。
- SYNC_IO：`IoFsync` 125 条、max **31.7 ms**（`IoWrite` 212 / `IoRead` 116），
  帧延迟最低 26 ms → IO 不是本窗口瓶颈。

## 3. 线程级画像（perf 采样 + 阻塞栈）

| 线程 | 采样占比 | 主要阻塞点（cs 样本，depth-3 帧） | 主要热点帧 |
|---|---|---|---|
| pf-infer | 44.6% | `futex_wait` 64 + 中断 131 | `InferenceConv3x3` 1139、`InferenceGemm` 979 |
| pf-preproc | 23.9% | `futex_wait` 257 | `CpuWork` |
| pf-postproc | 10.0% | `futex_wait` 338 | `CpuWork` |
| pf-syncwait | 9.2% | `futex_wait` 450 | （几乎全阻塞：CvWait 112.6 s） |
| pf-contend1/2 | 3.7%/3.6% | `hrtimer_nanosleep` 108/152 | `ContendSpin` 168 |
| pf-capture | 2.9% | `hrtimer_nanosleep` 356 | `CaptureThread` |
| pf-output | 0.8% | `futex_wait` 568 | `OutputThread` |
| pf-memheap / ioworker / monitor | <1% | `hrtimer_nanosleep` | — |

结论：流水线四段用条件变量（futex）等待上游，属**正常流水线阻塞**；
`pf-syncwait` 是 CvWait 的主持有者；两个 contender 用「spin + 定时 sleep」制造 CPU 竞争。

## 4. 未获得的能力（本轮判定）

| 能力 | 判定 | 原因 |
|---|---|---|
| sched_switch / sched_waking / sched_wakeup_new | **FAIL** | 内核无 tracefs（`/sys/kernel/tracing` 不存在，kallsyms 无 `__tracepoint_sched_switch`） |
| Running/Runnable/Sleeping（thread_state） | **FAIL** | 同上；只有应用自报 `ThreadsRunning/Blocked` 与 CvWait 可作代理 |
| Waker / block-wake 事件调用栈 | **部分**（E2 代理） | 用 `SW_CONTEXT_SWITCHES` 采到真实阻塞栈（`sched_blockwake.pftrace`），但无 waker/runnable |
| CPU frequency | **PASS** | `linux.sys_stats` cpufreq 轮询，300–1500 MHz |
| cpuidle | **FAIL** | 无 `power/cpu_idle` tracepoint（ftrace 缺失） |
| Native Heap Profile | **FAIL** | 板上无 heapprofd producer（见下） |
| CPU sampling callstack | **PASS** | 92,271 样本，函数名可读（板上 unwind + 符号化） |
| 应用 Slice / Counter / Flow / Frame ID | **PASS** | 见 §1 |

heapprofd 缺失的定位（逐层排除）：
1. `libheapprofd_glibc_preload.so` 存在，但常驻进程 `environ` 无 `LD_PRELOAD`；
2. 板上 `traced_probes`/`tracebox` 二进制中**没有** `android.heapprofd` 数据源；
3. 用 tracebox autostart + `android.heapprofd` 配置采集 8 s，退出码 0、文件仅 **658 B**，
   TP 查询 `heap_profile_allocation` 为 0 行 → **采集源未注册**，非「无 dump」也非「无符号」；
4. glibc heapprofd 不能 attach 已运行进程，必须带 preload 重启实例。

## 5. 本轮结论（限定）

- 已经用真实数据完整刻画：流水线阶段/嵌套/跨线程 Flow/帧 ID/端到端时延、队列与 inflight、
  内存 RSS 与 live 分配、CPU 频率与热点函数、阻塞原因（futex vs nanosleep）。
- 两个可复核的异常窗口：**SCHED_CONTENTION（CPU 竞争，E2）**、
  **MIXED_PIPELINE（队列积压，E2）**；MEMORY_PULSE 有内存脉冲但与延迟不同窗。
- 不能证明：谁抢了哪个 CPU、Runnable 时长、锁持有者、heapprofd 分配调用栈。
- "推理"阶段是 **CPU 模拟**（`InferenceConv3x3`/`InferenceGemm` 出现在 pf-demo-x5 的
  用户栈与 perf 热点），**不是 BPU/NPU 真实推理**，不得写成 BPU 时延。
