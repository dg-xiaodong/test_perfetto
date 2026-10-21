# Perfetto UI 演示指南（P2–P12，全部基于本次真实 Trace）

> **截图状态：待执行。** 本机没有可用的 Perfetto UI 渲染环境（详见 §0）。本文件给出**精确到
> 轨道名/时间戳/点击位置**的手工操作步骤，数值全部来自本次真实 Trace 与本目录 SQL 输出。
> 已有 3 张真实界面截图（`screenshots/ui_real_openstate_*.png`），仅能证明 UI 打开与 trace 打开
> 动作，**不能**作为 P2–P12 的轨道图。

## 0. 截图与 UI 环境说明（真实情况）

| 项 | 结果 |
|---|---|
| 是否有图形界面 | 无 DISPLAY；但有 `/usr/bin/google-chrome`（Chrome for Testing 155）+ Playwright 1.64 |
| 能否打开 https://ui.perfetto.dev | **能**（HTTP 200，UI 主界面成功渲染并进入 `Open trace file` 状态） |
| 能否加载 Trace | **不能完成**。UI 前端 bundle 13.6 MB，实测下载速率约 44 KB/s 且连接被重置（`net::ERR_NETWORK_CHANGED`）；上传 trace 后 UI 一直停在 "Opening trace"，内置 WASM 引擎未能就绪（`canvas` 数量 0） |
| 已留证截图 | `screenshots/ui_real_openstate_1_home.png`（UI 主界面）、`ui_real_openstate_2_opening_trace_stuck.png`（已选中真实 `.pftrace` 后停在 Opening trace） |
| 结论 | 截图任务标记 **待执行**；下文步骤可在任意有 UI 的机器上按图操作，数据与时间戳均为真实值 |

打开方式（每页通用）：`ui.perfetto.dev` → **Open trace file** → 选择 `traces/<文件名>`；
载入后 `Ctrl+P` 打开 **Commands**，输入 `Find tracks` 可按关键字定位轨道；
`W`/`S` 缩放，`A`/`D` 平移；拖动时间轴可做 Area selection；右侧 **Current selection** 面板显示所选事件的完整字段。

---

## P2 · 多种轨道共存的 Perfetto UI 总览

| 项 | 内容 |
|---|---|
| 文件 | `traces/overview_system_app.pftrace` |
| 搜索 | 不搜索，直接看默认轨道列表 |
| 时间窗口 | **727.0 s – 759.0 s**（trace 绝对时间，下同；= 4 个 8 s 阶段：BASELINE→CPU_BURST→SCHED_CONTENTION→MEMORY_PULSE） |
| 点击 | 左侧轨道折叠栏保留全部组；点开 `CPU 0..7`、`Process: pf-demo-x5`、`Memory`、`Counters` |
| 能看到什么 | 轨道共存：①8 条 CPU 轨道（`cpufreq` 频率线 + `cpu-clock` 采样计数）；②进程/14 条线程轨道；③应用 5 类 slice；④应用 counter（QueueDepth/InflightFrames/EndToEndLatencyMs/RssKb/LiveAllocatedBytes/ThreadsRunning/SchedWakeupOvershootMs）；⑤系统 meminfo/vmstat counter 轨道 |
| 能解释什么 | 一次采集里同时看到「CPU 频率/负载」「线程在做什么」「业务阶段」「队列与内存」「系统内存」五类信号，且它们在**同一时钟域**对齐 |
| SQL/证据 | `results/custom/c01-app-slices-by-category/stdout.csv`、`c07-app-counters`、`c14-cpufreq`、`c13-meminfo-system` |

---

## P3 · 时间轴、CPU、Process、Thread、Slice、Counter、详情区

| 项 | 内容 |
|---|---|
| 文件 | `traces/overview_system_app.pftrace` |
| 搜索 | `Find tracks` → `pf-infer`（1 条线程轨道）、`pf-demo-x5`（进程轨道）、`cpufreq`（CPU counter） |
| 时间窗口 | **743.16 s – 751.17 s**（SCHED_CONTENTION） |
| 点击 | ①点顶部时间轴任意处 → 底部显示时间游标；②点 `pf-infer` 轨道上一段 `InferenceStub`（如 ts=743.4 s 附近）；③点 `cpufreq` 曲线 → 右侧 Current selection 显示该时刻 `value`（MHz） |
| 能看到什么 | 详情区（Current selection）字段：`InferenceStub` 的 `Duration`（该窗口实测 avg 85.5 ms / max 180.7 ms）、`Category=pipeline`、`debug.phase=SCHED_CONTENTION`、`debug.frame_id`；线程轨道名即 `comm`（pf-infer/pf-postproc/…）；CPU 轨道频率 1.5 GHz |
| 能解释什么 | 时间轴=统一时钟；CPU 轨道=核级信号；Process/Thread=归属；Slice=区间；Counter=采样序列；详情区=所有 debug annotation |
| SQL/证据 | `results/custom/c02-thread-stage-durations`、`c20-phase-metrics`、`c21-phase-cpufreq` |

---

## P4 · 搜索、固定轨道、缩放、选择事件、SQL、Add Debug Track

| 项 | 内容 |
|---|---|
| 文件 | `traces/overview_system_app.pftrace` |
| 搜索 | `Find tracks` → 输入 `FramePipeline` 或 `QueueDepth`；`Ctrl+F` 搜索 slice 名（如 `CvWait`） |
| 时间窗口 | **703.0 s – 709.0 s**（MEMORY_PULSE，counter 变化明显） |
| 点击 | ①右键轨道标题 → **Pin**（固定到顶部，便于跨页对比）；②`W/S` 缩放、`A/D` 平移；③左键拖动做 Area selection；④切到 **Query (SQL)** 页，粘贴 `sql/custom/c08-queue-depth-debug-track.sql` 运行；⑤结果表右上角点 **Add debug track**（源码 `ui/src/plugins/dev.perfetto.QueryPage/results_table.ts` 确认该按钮存在），即可把 `QueueDepth` 画成调试轨道 |
| 能看到什么 | 搜索结果跳到真实时间戳；pin 后轨道常驻；SQL 返回 240 行 `(ts, queue_depth)`；Add debug track 后出现新轨道并与原时间轴对齐 |
| 能解释什么 | UI 的四种高频操作（查找/固定/缩放/选区）与「SQL → 轨道」的闭环，是后续所有页面的基础 |
| SQL/证据 | `results/custom/c08-queue-depth-debug-track/stdout.csv`（240 行） |

---

## P5 · Memory Counter

| 项 | 内容 |
|---|---|
| 文件 | `traces/overview_system_app.pftrace` |
| 搜索 | `Find tracks` → `Memory`（系统 meminfo）、`pf-demo-x5`（进程 counter：RssKb / LiveAllocatedBytes / mem.rss*） |
| 时间窗口 | **703.0 s – 709.0 s**（一个完整内存脉冲：alloc 703.515 s → hold 到 707.5 s → free） |
| 点击 | 点 `RssKb` 轨道在 704.1 s 的台阶（5,884 → 17,708 kB）；再点 `LiveAllocatedBytes` 在 703.515 s 的尖峰（12,582,912 B）；展开 `mem.rss.anon`/`mem.rss.file`/`mem.rss.shmem`/`mem.rss.watermark` |
| 能看到什么 | 真实数值：`RssKb` 5,884→17,708→5,392 kB；`LiveAllocatedBytes` 0→12,582,912→0；`mem.rss.anon` 1,027→13,185 kB；`mem.rss.watermark` 17.75 MB；系统 `MemAvailable` 同步下降 |
| 能解释什么 | RSS 阶跃 vs 应用自报 live 分配 vs 系统内存三者同窗对照；说明"RSS 上升≠泄漏"，且 `malloc_trim` 后 RSS 能回落 |
| SQL/证据 | `results/custom/c12-rss-target`（606 行）、`c13-meminfo-system`、`results/skill/mem-01-rss-timeline`（注意单位口径差异，见 `SKILL_GAPS.md` G10） |

---

## P6 · Native Heap Profile 与 Flamegraph

| 项 | 内容 |
|---|---|
| 文件 | **没有可用的 heap Trace**。只能用 `traces/native_heap_heapprofd_unavailable.pftrace`（658 B）演示"配置成功但数据源不存在"的失败态 |
| 搜索 | 无（该文件没有任何 heap 轨道） |
| 时间窗口 | 8 s（空的） |
| 点击 | 打开后 UI 只有 clock snapshot；`Query (SQL)` 运行 `results/skill/mem-03-native-live/query.sql` → 0 行 |
| 能看到什么 | 空；`perfetto --query` 的数据源清单里没有 `android.heapprofd`；`strings traced_probes/tracebox \| grep android.heapprofd` = 0 |
| 能解释什么 | 这是**平台能力缺失**，不是"trace 太大没看到"。要讲 P6 必须换有 heapprofd 的镜像/设备（最小修复见 `COVERAGE_MATRIX.md` §3） |
| SQL/证据 | `traces/native_heap_heapprofd_unavailable.pftrace`、`results/skill/mem-03-native-live/`、`results/skill/mem-04-native-callstacks/`（均 0 行） |
| 替代（标注为替代） | 可用 `perf_sample` 里的 `malloc`/`free` 热点栈讲"分配热点"，但**不是** live heap / 调用栈归因，不能放在 P6 标题下冒充 heapprofd |

---

## P7 · CPU 调度时间线（本平台为"频率 + 采样 + 每核时间"）

| 项 | 内容 |
|---|---|
| 文件 | `traces/overview_system_app.pftrace` |
| 搜索 | `Find tracks` → `cpufreq`、`cpu-clock`、`cpu.times` |
| 时间窗口 | **735.15 s – 751.17 s**（CPU_BURST → SCHED_CONTENTION） |
| 点击 | 展开 8 条 `cpufreq` 轨道，看 735 s 后从 ~400 MHz 抬到 **1,500 MHz**；点 `CPU 5` 的 `cpu-clock` 轨道（perf 采样计数）看该核采样密度；对照 `cpu.times.user_ns` 的累计斜率 |
| 能看到什么 | 频率阶跃真实存在：CPU_BURST 阶段均值 **1,369–1,500 MHz**、BASELINE 413–488 MHz、MEMORY_PULSE 375–431 MHz、MIXED_PIPELINE 1,008–1,260 MHz；`cpu-clock` 每核约 11.6k–11.9k 采样（120 s） |
| 能解释什么 | CPU 负载与频率的时序关系；**必须说明**：本板没有 `sched_switch`，所以这里**没有**"线程在哪个核上运行的连续切片"，不能把频率线当调度时间线讲 |
| SQL/证据 | `results/skill/cpu-04-cpu-frequency`（1,929 行）、`results/custom/c14-cpufreq`、`results/custom/c21-phase-cpufreq`、`results/skill/cpu-08-core-busy`（**0 行，无 sched**） |

---

## P8 · CPU Profiling / Callstack

| 项 | 内容 |
|---|---|
| 文件 | `traces/overview_system_app.pftrace` |
| 搜索 | `Find tracks` → `Callstack samples` / `pf-infer`；或用 `Find slices` 搜 `InferenceConv3x3` |
| 时间窗口 | **735.15 s – 743.16 s**（CPU_BURST，热点最集中） |
| 点击 | 展开 `pf-infer` 的 callstack 采样轨道 → 点任一采样样本 → 详情区看 `Stack`（完整调用链）；切到 **Query (SQL)** 运行 `sql/custom/c09-perf-hotspots.sql`，结果表点 **Add debug track** 可把采样分布画出来 |
| 能看到什么 | 92,271 个样本（全 trace），热门叶子函数（已 demangle）：`pfdemo::InferenceConv3x3` 1,322、`pfdemo::InferenceGemm` 979、`pfdemo::CpuWork` 1,691（按调用点聚合，`c09`）；线程分布 pf-infer 44.6% / pf-preproc 23.9% / pf-postproc 10.0% |
| 能解释什么 | "哪个函数在烧 CPU"；**口径**：样本数≠调用次数、≠CPU 毫秒；本次有 2,761 条 perf 记录被内核丢弃（约 3.0%），UI 顶部 Trace health 会提示 |
| SQL/证据 | `results/skill/cpu-07-perf-samples`（100 行）、`results/custom/c09-perf-hotspots`、`c10-perf-per-thread`、`c11-perf-buckets-1s`（664 行，1 s 桶） |

---

## P9 · 线程 Running / Runnable / Sleeping

| 项 | 内容 |
|---|---|
| 文件 | `traces/overview_system_app.pftrace` |
| 搜索 | `Find tracks` → `ThreadsRunning`、`ThreadsBlocked`、`CvWait` |
| 时间窗口 | **743.16 s – 751.17 s**（SCHED_CONTENTION）与 **703.0–711.0**（MEMORY_PULSE）对照 |
| 点击 | ①点 `ThreadsRunning` counter 在 743–751 的抬升段（平均 3.63–3.75，其余阶段 1.1–2.0）；②点 `pf-syncwait` 轨道上的 `CvWait` slice（如 ts=703.026 s、dur 60.07 ms）→ 详情区看 `Duration`；③`ThreadsBlocked` 恒 0 |
| 能看到什么 | 应用自报的"运行线程数"与真实条件变量等待 slice；**没有** `thread_state` 轨道（Running/Runnable/Sleeping 三色条） |
| 能解释什么 | 只能讲"应用层可观测的线程活跃度与等待"，**不能**讲调度器状态；`ThreadsRunning` 升高 + `CvWait` 并存，说明"有线程在抢 CPU、有线程在等条件变量" |
| SQL/证据 | `results/custom/c15-sched-proxy-counters`（300 行）、`c16-cv-wait-wake`、`results/skill/cpu-02-thread-states`（**0 行**）、`results/skill/sched-01-state-window`（**0 行**） |

---

## P10 · Blocking / Waking 与调用栈

| 项 | 内容 |
|---|---|
| 文件 | `traces/sched_blockwake.pftrace`（30 s，`beadb4f2…`） |
| 搜索 | `Find tracks` → `pf-output`、`pf-syncwait`、`pf-contend1`；callstack 采样轨道 |
| 时间窗口 | **1559.19 s – 1567.19 s**（该 trace 内的 SCHED_CONTENTION；trace 起点 1544.091 s） |
| 点击 | 展开 `pf-output` 的 callstack 采样 → 点任一采样 → 详情区 `Stack` 应显示：`schedule → futex_wait → do_futex → __arm64_sys_futex → pthread_cond_wait → OutputThread`；再点 `pf-capture` 的采样 → `schedule → do_nanosleep → hrtimer_nanosleep → CaptureThread` |
| 能看到什么 | 真实阻塞归因（样本数）：pf-output `futex_wait` 568、pf-syncwait 450、pf-postproc 338、pf-preproc 257、pf-infer 64；pf-capture `hrtimer_nanosleep` 356、pf-contend2 152、pf-memheap 134、pf-monitor 271；内核栈映射 `/kernel`，用户栈映射 `pf-demo-x5`/`libc` |
| 能解释什么 | "阻塞在哪里"（事件级 E2）。**没有** `sched_waking`，所以**没有**"谁唤醒了我"；不能把 futex 出现推断成锁持有者 |
| SQL/证据 | `results/custom-blockwake/c22-blocking-callstacks.csv`（96 行，thread/depth/frame/mapping/samples）、`traces/sched_blockwake.cs.perfdata`（原始 perf.data，6,023 样本） |
| 采集口径 | `SW_CONTEXT_SWITCHES period:1` + `kernel_frames:true`；perf 记录丢失 28,688 条（采样口径，非 100% 完整） |

---

## P11 · 嵌套应用 Slice

| 项 | 内容 |
|---|---|
| 文件 | `traces/overview_system_app.pftrace` |
| 搜索 | `Find slices` → `InferenceStub`；或 `Find tracks` → `pf-infer` |
| 时间窗口 | **705.005 s – 705.022 s**（一帧的推理阶段，可直接放大到 20 ms 内） |
| 点击 | 点 `InferenceStub`（ts=705.005297502、dur=15.959 ms）→ 其下两层子 slice：`infer.kernel_conv3x3`（8.647 ms）、`infer.kernel_gemm`（7.271 ms）；再点 `Preprocess`（同窗口）看 `preproc.resize`/`preproc.normalize` |
| 能看到什么 | 真实父子关系（`slice.parent_id`/`depth=1`，`results/custom/c03`）；同级还有 `QueuePush.*`/`QueueWait.*` 平级 slice |
| 能解释什么 | 嵌套 slice 的时间归属：父 slice 时长≈子 slice 之和 + 自身开销（15.96 ≈ 8.65+7.27+0.04） |
| SQL/证据 | `results/custom/c03-slice-nesting`（depth 0/1）、`results/custom/c02-thread-stage-durations` |

---

## P12 · 跨线程 Flow、Queue Counter、端到端链路

| 项 | 内容 |
|---|---|
| 文件 | `traces/overview_system_app.pftrace` |
| 搜索 | `Find tracks` → `pf-capture`/`pf-preproc`/`pf-infer`/`pf-postproc`/`pf-output`；counter 轨道 `QueueDepth`/`InflightFrames`/`EndToEndLatencyMs`；async 轨道 `FramePipeline` |
| 时间窗口 | **743.16 s – 751.17 s**（积压最明显）或 **747.65 s – 751.17 s**（单帧 1.3–1.6 s 的完整链路） |
| 点击 | ①在 `SyntheticCapture` 上点 flow 箭头（或 `Flow events` 开关）→ 高亮到 `Preprocess` 的跨线程箭头；②点 `FramePipeline` 上 id=18392 的 async slice（ts=749.478 s、dur=1,630.1 ms、`debug.frame_id=11584`、`debug.e2e_ms=1630`）；③点 `QueueDepth` 在 749 s 附近峰值 22、`InflightFrames` 峰值 25 |
| 能看到什么 | 真实 flow：4 种边 × ~1,866 条（capture→pre→infer→post→output），每条边两端线程不同（`c04`）；`FramePipeline` 是 custom/async 轨道（无 thread 绑定）；端到端 = 232 帧的 `debug.e2e_ms`（avg 341.7 / max 1630 ms） |
| 能解释什么 | 跨线程流水线的排队-处理-输出链路；端到端时延由「队列等待 + 各阶段墙钟」构成，`QueueWait.*` 与 `EndToEndLatencyMs` 可交叉验证；**推理阶段是 CPU 模拟**，不是 BPU |
| SQL/证据 | `results/custom/c04-cross-thread-flows`（40 行）、`c05-flow-shape`、`c06-frame-e2e`（40 行）、`c20-phase-metrics`（16 阶段）、`results/skill/latency-02-flow` |

---

## 附：每页对应的原始证据文件

| 页 | Trace | 主要 SQL 结果目录 |
|---|---|---|
| P2/P3/P4 | overview_system_app.pftrace | `results/custom/c01,c07,c14,c13` |
| P5 | overview_system_app.pftrace | `results/custom/c12,c13`、`results/skill/mem-01-rss-timeline` |
| P6 | native_heap_heapprofd_unavailable.pftrace | `results/skill/mem-03,mem-04`（0 行） |
| P7/P8 | overview_system_app.pftrace | `results/skill/cpu-04,cpu-07`、`results/custom/c09,c10,c11,c21` |
| P9 | overview_system_app.pftrace | `results/custom/c15,c16`、`results/skill/cpu-02`（0 行） |
| P10 | sched_blockwake.pftrace | `results/custom-blockwake/c22` |
| P11 | overview_system_app.pftrace | `results/custom/c02,c03` |
| P12 | overview_system_app.pftrace | `results/custom/c04,c05,c06,c08,c20` |
