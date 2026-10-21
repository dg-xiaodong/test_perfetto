# 与窗口 A Ground Truth 的逐项对照

前置：本文件在 `results/ROUND1_DIAGNOSIS.md`（sha256 `496b211b…b33b`）冻结之后才撰写，
第一轮结论未被修改。Ground Truth 来源：`perfetto_ppt/demo_fixture/PRIVATE_GROUND_TRUTH.md`
（192 行，读完于 2026-10-21 本机时间）。

判定符号：✅ 一致；🟡 方向一致但数值不同；❌ 不一致；❔ GT 有、本轮无法验证。

## 1. 身份与时间基

| GT 陈述 | 本轮实测 | 判定 |
|---|---|---|
| 程序 `pf-demo-x5` v1.0.0，sha256 `f89d9ed5…` | 板上 sha256 = `f89d9ed5…c9b5` | ✅ |
| SDK v58.2 system backend，`/tmp/perfetto-producer` | producer 注册 `track_event`，5 个 category；`tracebox --query` 显示 v58.2 | ✅ |
| 12 worker + 1 TracingMuxer | 14 线程 = main + 12 worker + TracingMuxer（`TracingMuxer` 的 comm 首扫为 NULL） | ✅ |
| trace 用 CLOCK_BOOTTIME，与日志差 0–10 µs | `PhaseChange` ts=343.100693580 s vs 日志 `boot_ns=343.100682121` → 差 **11.5 µs** | ✅ |
| 48 s 周期，6×8 s 阶段 | 实测 8.008 s/阶段、47.94–48.0 s/周期；120 s 内 15 个 PhaseChange | ✅ |
| 阶段顺序 BASELINE→CPU_BURST→SCHED_CONTENTION→MEMORY_PULSE→SYNC_IO→MIXED_PIPELINE | `c17` 完全一致 | ✅ |

## 2. 逐阶段

### BASELINE
| GT | 本轮 | 判定 |
|---|---|---|
| 干净时 e2e≈30 ms；RSS≈4 MB；队列 0–1 | 本实例 BASELINE avg 190 ms / max 1333 ms，队列 max 21 | 🟡 |
| 紧跟 MIXED 的头 1–3 s 仍在排空（e2e 可达 1.3 s，队列到 19） | max 1333 ms、队列 max 21–22；`c20` 显示 BASELINE 起点即高峰、随后下降 | ✅ 机制一致 |

### CPU_BURST
| GT | 本轮 | 判定 |
|---|---|---|
| inference 42 ms avg / 136 ms max 墙钟 | `InferenceStub` avg **40.4 ms** / max 82.8 ms | ✅（量级一致） |
| e2e ≈56 ms | **56.1 ms** avg / 81.8 max | ✅ |
| 频率升到 1.5 GHz | 阶段均值 **1,369–1,500 MHz**（BASELINE 413–488） | ✅ |
| 热点 conv3x3 / gemm；`cpu.pf-infer` ≈63% | perf 叶子 conv3x3/gemm 居首；`cpu.pf-infer` max **60.9%** | ✅ |
| 队列近空 | qdepth avg 0、max 0 | ✅ |

### SCHED_CONTENTION
| GT | 本轮 | 判定 |
|---|---|---|
| 两个 spinner 与 pf-infer 同核；`contend.spin1/2` 100 ms、95% duty | slice 存在，avg 115 ms / max 200 ms（slice 跨两次 spin 时会 >100 ms）；**同核无法验证**（无 sched） | 🟡 / ❔ |
| `ThreadsRunning` 3–4 | avg **3.63–3.75** | ✅ |
| `cpu.pf-contend1/2` ≈34% | max **32.9%** each | ✅ |
| 墙钟膨胀 65 ms avg / 82 ms max（≈2.6× CPU 工作） | `InferenceStub` avg **85.5 ms** / max 180.7 ms | 🟡 偏高 |
| e2e ≈194 ms；队列 ~1.9 avg | e2e avg **981 ms**（max 1630）；队列 avg **9.4–9.6**、max 16 | ❌ 明显更高 |
| `SchedWakeupOvershootMs` ≤0.85 ms，不应期待大尖峰 | 主众数 **0.07 ms**（2,276/2,400），avg 0.56 ms；但存在 **83 条 >10 ms、最大 21.4 ms** 的次众数，其中 54 条落在 SCHED_CONTENTION（均值 12.8 ms）、6 条在 MEMORY_PULSE | 🟡 典型值一致，**尖峰与 GT 相反** |

**为什么会有 ❌/🟡（以实测数据推断，不是猜）**：
- 本实例 inference 墙钟 85.5 ms 已**超过 66 ms 帧周期**（GT 自身也点明"wall time is just below the 66 ms
  frame period"是临界态），一旦越过，队列必然持续增长 → e2e 从 ~200 ms 抬到 ~1.6 s。这是**临界系统**的
  双稳态，不是测量错误。
- 本实例除两个 spinner 外还并存 3 个常驻 fixture（`sched-case-daemon` cpu1/2、`task-service` cpu6/7、
  `cam-service`）与 `traced/traced_probes`；且 GT 记录的最终实例是 `cpu_a=5 cpu_b=0`，而证据运行是
  `cpu_a=5 cpu_b=4` —— 竞争者数量与核位不同。
- 为排除"perf 采集把系统压慢了"，做了**无 perf 60 s 对照**（`traces/light_noperf_60s.pftrace`）：
  SCHED_CONTENTION e2e avg **883.8 ms**（有 perf 为 981 ms）、max 1587.7 ms；overshoot max **20.135 ms**。
  → **perf 采样不是原因**，本实例本身就在高延迟分支上。

### MEMORY_PULSE
| GT | 本轮 | 判定 |
|---|---|---|
| 12 MiB malloc+memset，hold 4 s，free + malloc_trim 后 1.5 s 重复 | `MemoryPulse.alloc/hold/free` 各 6 次/120 s，hold 每次 **4.004 s**；`LiveAllocatedBytes` 0→**12,582,912**→0 | ✅ |
| RSS 3 984→16 412 kB（Δ12 328） | 5 884→**17 708** kB（Δ11 824）；回落 5 392 kB | ✅（基线 RSS 略高） |
| 分配调用栈应为 MemoryThread→MemoryPulse.alloc→malloc | **无法给出**：无 heapprofd（GT §8 自己也写明常驻实例不能事后 profile） | ❔ |
| 与延迟无关 | 本实例该阶段帧 avg 46 ms（最低之一）；但 overshoot 有 6 条 >10 ms 尖峰 | ✅ 主体一致 |

### SYNC_IO
| GT | 本轮 | 判定 |
|---|---|---|
| CvWait ≈1 360/52 s；CvTimeout ≈540/52 s | CvWait **3 016/120 s（1 307/52 s）**；CvTimeout **1 150/120 s（498/52 s）** | ✅ |
| pf-ioworker 每 200 ms write+fsync+pread | `IoWrite` 212、`IoFsync` 125（max **31.7 ms**）、`IoRead` 116 /120 s | ✅ |
| 文件上限 512 KiB | `IoFileBytes` 320,000→366,080 B | ✅ |

### MIXED_PIPELINE
| GT | 本轮 | 判定 |
|---|---|---|
| 20 FPS；inference 2M+2M（≈25 ms）；postprocess 是瓶颈（40–70 ms） | `Postprocess` 该阶段 avg **57.18 ms** / max 74.3 ms（全 trace 最高）→ **确认 postprocess 是瓶颈**；`InferenceStub` 26.5 ms | ✅ |
| e2e 602 avg / 1 122 max；QueueDepth 9.7/18；Inflight 22 | e2e **719/1459**；QueueDepth **11.8/22**；Inflight **25** | 🟡 同方向偏高 |
| 积压排入后续 BASELINE | BASELINE 起点 qdepth 21、e2e 1333 ms | ✅ |

## 3. 帧与计数口径

| GT | 本轮 | 判定 |
|---|---|---|
| frame id 自增、重启归 1；frames.log 一行一帧 | `FramePipeline` 有 `debug.frame_id` 10784…12638；`CompletedFrames` 同窗 10 773→12 638 | ✅ |
| 52 s trace 含 820 帧（≈15.8 fps） | 120 s 采样 233 个 FramePipeline × 每 8 帧一次 → ≈1 864 帧/120 s ≈ **15.5 fps** | ✅ |
| `FramePipeline` 每 8 帧采样、16 条轮转轨道 | track_id 多次变化（531…638），确为轮转 | ✅ |
| 5 stage 每帧 4 条 flow | `c05`：4 种边、各 1 865–1 866 条 | ✅ |
| 推理是 CPU 模拟，不是 BPU | perf 叶子在 `pf-demo-x5` 用户态（conv3x3/gemm）；无 BPU/NPU 事件 | ✅ |

## 4. 本轮**没有**验证到的 GT 结论（诚实列出）

1. **同核争抢**（GT：spinner 与 pf-infer 同 cpu）：无 sched_switch，无法验证 CPU 归属与迁移。
2. **`R` 状态占比**（GT：`/proc` 采样 21/110、19/110 为 R）：无 thread_state，本轮只能用 `ThreadsRunning` 3.6 间接印证。
3. **分配调用栈** `MemoryThread→MemoryPulse.alloc→malloc`：无 heapprofd。
4. **`cpu_a` 实际核号与 `CPU_SELECT ... reserved`**：日志未在采集窗口内获取（本轮只读 trace 与 /proc 允许列表 0-7）。

## 5. 第一轮诊断的正确性评分

| 诊断点 | 本轮结论 | GT | 结果 |
|---|---|---|---|
| 周期结构/阶段顺序 | 48 s，6×8 s，顺序一致 | 同 | ✅ 正确 |
| CPU 竞争是主要异常 | SCHED_CONTENTION 延迟最高 + ThreadsRunning 3.6 + 2 个 spinner | 同 | ✅ 正确 |
| 队列积压是次强异常 | MIXED_PIPELINE 积压、inflight 25 | 同 | ✅ 正确 |
| 内存脉冲与延迟无关 | 该阶段帧 46 ms（最低组） | 同 | ✅ 正确 |
| 瓶颈阶段 | 第一轮只写"生产快于消费"，**未点名 postprocess** | postprocess 是瓶颈 | 🟡 定位不完整（补查 `c02/per-phase` 后可确认） |
| 推理性质 | CPU 模拟，非 BPU | 同 | ✅ 正确 |
| 阻塞归因 | 四段流水线 futex、contention nanosleep | 同（GT 未展开） | ✅ 正确（E2） |
| 唤醒延迟 | 记录到 20–21 ms 峰值 | ≤0.85 ms | ❌ 与 GT 冲突（已用无 perf 对照证明不是采集开销导致；判定为实例/临界态差异） |
| SCHED_CONTENTION e2e/队列 | 981 ms / avg 9.6 | 194 ms / 1.9 | ❌ 同上，且已解释双稳态机制 |
| heapprofd 缺失原因 | 数据源未注册（逐层排除） | GT §8 说 preload 只在启动时生效 | ✅ 一致且更具体 |

**错误推断自查**：第一轮**没有**把 futex 当锁持有者、没有把 perf 样本数当调用次数、
没有把频率缺失当 0 MHz、没有把 RSS 当 heap live、没有把推理写成 BPU —— 这 5 条红线均未触碰。
唯一"过度乐观"之处：把 `SchedWakeupOvershootMs` 峰值当作与 GT 一致的证据；对照后确认这是**本实例
的真实差异**，不是 GT 的错也不是采集错误。

## 6. 对窗口 A 的建议（最小改动）

1. 若培训要讲"稳定的 194 ms 竞争延迟"，建议把 SCHED_CONTENTION 的 inference 迭代量下调 ~25%，
   或把帧周期从 66 ms 放宽，使系统**离开临界点**；否则不同实例会在 200 ms 与 1.6 s 两个分支间跳。
2. 若要讲 Runnable/Waker，必须换有 `CONFIG_FTRACE` 的内核镜像（或提供其它板卡的 ftrace trace）；
   本镜像上四个 Skill 的 sched 配方均不可用。
3. 若要讲 heapprofd/Flamegraph，需补 `heapprofd` producer（Linux 目标）并按 preload 启动专用实例。
4. `SchedWakeupOvershootMs` 建议在 GT 里写成"分布"（主众数 0.07 ms、竞争期 3.5% 样本 10–21 ms），
   而不是单值上限，否则与实测不符。
