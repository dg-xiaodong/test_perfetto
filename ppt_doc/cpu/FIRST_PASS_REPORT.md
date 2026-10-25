# FIRST_PASS_REPORT — pf-cpu-case 周期 CPU 尖峰与心跳时延（X5 真实采集，共享板环境）

- 报告类型：首轮盲测（FIRST_PASS），由 `perfetto-cpu-debugging` Skill v0.1.0-candidate 驱动
- 本次测量对象：`pf-cpu-case` **pid 8143**（板端 `/userdata/perfetto-skill-lab/cpu/`），采集时 uptime 3:59
- 采集：1 次真实上板采集（tracebox 全程绑核在 cpu0/4，未触碰工作核，也未触碰板上其他实验）
- 报告性质：本报告是对**当前运行实例**的独立实测；会话内另有一份针对**已被重启的旧实例（pid 1762）**的冻结报告，作为跨实例对照引用（§7.6），两者不混用
- 结论强度：异常窗口、主要贡献者、机制链、观察者位置 = **有实测证据**；窗口外归因、采样热点的时间语义、内核对量机制 = **UNKNOWN**

---

## 0. 结论摘要

1. **心跳尾部异常存在**：本实例 262.9 s / 5259 次心跳，p50 = 1.180 ms，p99 = **15.124 ms**，max = **34.185 ms**；**56 次 ≥10 ms**（1.07%），幅度集中在 **≈15.14 ms（40 次）** 与 **≈24–25 ms（7 次）** 两个离散簇。
2. **主要贡献者是同核的 `pf-worker-p`，且是逐段证明的，不是猜的**。对 trace 内全部 482 段 tick runnable 等待做"等待期间谁占着 cpu1"的逐段归属：**227.018 ms / 240.168 ms = 94.5% 由 `pf-worker-p` 持有**；空闲[NULL] 12.952 ms；**外来负载总共只有 0.144 ms（0.06%）**。
3. **幅度不等于因果**：本次板上同时跑着两个别的实验负载——`pf-lat-case`（7697.8 ms，**32.1%** 单核）与 `pf-sched-case`（6510.4 ms，**27.1%**），都远大于被测进程自身（4020.0 ms，16.8%）。**但它们在心跳延迟上的占比只有 0.06%**。决定因素是"是否与心跳线程同核"，不是"谁烧的 CPU 多"。
4. **可比对照（`pf-worker-q` 峰期）**：q 的峰值（642 / 678 ms）比 p（499–582 ms）更大，但 q 在 cpu2；q 峰期心跳 p50 = **1.082 / 1.087 ms**，**低于**基线 1.148–1.208 ms。q 峰期 cpu1 只有 2.3% 占用。
5. **机制是"等"不是"算"**：tick 自身 on-CPU 在 p-burst 内 **0.9436 ms/slice**，低于基线的 1.1845 ms/slice。延迟全部来自 runnable 等待，逐条对账：**等待 14.064 ms（15.7293→15.7434 s）+ 运行 1.0592 ms = 15.1236 ms ≈ 心跳 15.124 ms**；另一条 **12.722 + 1.06 ≈ 13.78 ms ≈ 心跳 13.785 ms**。
6. **延迟量级由 worker-p 的 slice 结构决定，而非外来负载**：本实例 tick 的等待高度量化在 **4.065 ms** 与 **14.064 ms**（差 10.0 ms），对应心跳 **≈5.13 ms** 与 **≈15.14 ms**；旧实例（更空闲环境）对应簇是 **12.5 / 22.6 / 31.6 ms**。同一程序、同一配置、不同同核竞争形态 → 不同量化值。
7. **观察者未污染工作核**：tracebox 全程只在 cpu0(680.5 ms)/cpu4(241.3 ms+62.5+54.5)，cpu1/cpu2 上占用为 0（与旧会话那次未绑核、造成 19.8–21.4 ms 干扰形成对照）。
8. **采样热点不可当根因**：`linux.perf` 的叶帧第一名是 `svc_compute_until`（435 样本），但该线程 24 s 内 only 559.1 ms on-CPU（按 100 Hz/CPU 应为 ~56 样本），实测 **778 样本/CPU-s** 且样本严格落在它每 50 ms 的运行窗口内 → 这是**采样相位锁定的伪影**，不能当 CPU 时间；同一配置在旧会话给了该线程 **0 个样本**，排名不稳定。
9. **频率不是原因**：300–1500 MHz、schedutil；`1175 MHz` 的秒是本次**最快**的一秒（均值 1.087 ms），`450 MHz` 的秒 1.220 ms，`796 MHz` 的秒 3.875 ms（在 burst 中）。无单调关系。

---

## 1. 输入来源与合规声明

### 1.1 `PUBLIC_BRIEF.md` 仍然不存在（与上一轮相同）

```
ls perfetto_skill_lab/cpu/   → Makefile README.md RUN_INFO.md SELFTEST.md pf-cpu-case pf_cpu_case.cpp
find / -iname "*PUBLIC_BRIEF*" → 仅命中 perfetto_skill_lab/{scheduling,latency}/PUBLIC_BRIEF.md
```

`perfetto_skill_lab/cpu/PUBLIC_BRIEF.md` **不存在**。新增的 `scheduling/`、`latency/` 目录里确有 brief，但它们对应 **另外两个程序**（`pf-sched-case`、`pf-lat-case`），**不是本任务对象**，因此**没有读取**（读它们等于用了别的用例的信息，也违反"仅从 cpu/PUBLIC_BRIEF.md 获取"）。

本报告实际使用的公开信息：

| 来源 | 用途 |
|---|---|
| `perfetto_skill_lab/cpu/RUN_INFO.md` (sha256 `e7fcb3a6…`) | 程序路径、启停查命令、版本/Build ID、**公共**心跳 CSV 路径与字段语义 |
| `perfetto_skill_lab/cpu/README.md` (sha256 `3c28f7e3…`) | 程序公共描述、"只有单一默认模式、无关闭线程开关" |
| `/root/agent.md` | 板卡连接（**当前平台信息**） |
| 板端 `/proc`、tracefs 只读探测 | 线程亲和性、频率、负载、tracing 占用状态 |
| 板端 `/userdata/perfetto-skill-lab/cpu/heartbeat_latency.csv` | 公共业务时延（`seq,mono_ns,latency_ns`） |
| 本次真实 Trace | 全部 CPU/调度/频率/采样数字 |

**未读取**：`pf_cpu_case.cpp`、`SELFTEST.md`、`/userdata/perfetto-skill-lab/cpu/private/`、`scheduling|latency` 下的 `PRIVATE_GROUND_TRUTH.md` / `PUBLIC_BRIEF.md` / 源码；未反编译、未搜索历史答案。

### 1.2 未做的事

- 未执行预设 A/B 对照、未 `pkill`/重启被测进程、未关闭任何计算线程。
- **未触碰其他实验**：`pf-lat-case`(6692)、`pf-sched-case`(4703) 全程在跑，未停止、未改亲和性、未读其日志/数据。
- 未改 `perf_event_paranoid`/`kptr_restrict`/governor/内核；未改任何程序的亲和性（只对本会话自己的 tracebox 用 `taskset`）。
- 采集前后确认 tracing 资源空闲：`pgrep traced/tracebox` 无、`tracing_on=0`、`current_tracer=nop`；采集后 `tracing_on` 仍为 0。**没有抢占系统 tracing service**。

---

## 2. 当前环境（与上一轮的关键差异）

| 项 | 值 |
|---|---|
| 内核 | `6.1.83-DR-PL5.1_V1.1.1 #1 SMP PREEMPT aarch64` |
| CPU | 8 核同构（capacity 全 1024），300–1500 MHz，governor `schedutil` |
| 权限 | root；`perf_event_paranoid=2`，`kptr_restrict=0`；`traced_perf` 可用 |
| 负载 | **loadavg 1.11 → 1.20**（上一轮空闲时 0.04） |
| 被测实例 | **pid 8143**（上一轮的 1762 已退出；`heartbeat_latency.csv` 已重建） |
| 线程亲和（`/proc/<tid>/status`，非仅日志） | 8143 `pf-cpu-case` → cpu6；8146 `pf-svc-tick` → **cpu1**；8147 `pf-worker-p` → **cpu1**；8148 `pf-worker-q` → **cpu2** |
| 板上其他实验（**未触碰**） | 6692 `pf-lat-case`（6 线程，未绑核 0–7）；4703 `pf-sched-case`（线程在 cpu5/6/7） |
| 工具链 | tracebox `v57.1-c59f57dd4`；主机 trace_processor `v57.1-c59f57dd4`（**同版本**） |

> 因为被测进程已被重启，旧 Trace 属于已退出实例（不同 pid、不同 main 核），**无法与当前 `heartbeat_latency.csv` 对齐**，故本次重新上板采集（Skill §4"已有 trace 优先分析"不适用于实例已变更的情形）。

---

## 3. 采集配置与执行

### 3.1 配置（由 Skill 脚本生成，`cfg/cpu_run3.pbtxt`, sha256 `a940af07…`）

```bash
python3 $SKILL/scripts/make_config.py frequency --platform linux \
  --events captures/available_events.txt --duration-ms 24000 \
  --poll-ms 200 --buffer-kb 32768 --ftrace-kb 4096 --drain-ms 100 > cfg/base_freq.pbtxt
# 追加 linux.perf 段（字段逐项等同 configs/cpu-profiling.pbtxt）
```

```
duration_ms: 24000
buffers { size_kb: 32768 fill_policy: RING_BUFFER }
data_sources { config { name: "linux.process_stats" process_stats_config { scan_all_processes_on_start: true proc_stats_poll_ms: 1000 } } }
data_sources { config { name: "linux.ftrace"
    ftrace_config { buffer_size_kb: 4096 drain_period_ms: 100
      ftrace_events: "sched/sched_switch"
      ftrace_events: "sched/sched_waking"
      ftrace_events: "sched/sched_wakeup_new"
      ftrace_events: "power/cpu_frequency"
      ftrace_events: "power/cpu_idle"
    } } }
data_sources { config { name: "linux.sys_stats" sys_stats_config { cpufreq_period_ms: 200 } } }
data_sources { config { name: "linux.perf"
  perf_event_config {
    timebase { counter: SW_CPU_CLOCK frequency: 100 timestamp_clock: PERF_CLOCK_MONOTONIC }
    callstack_sampling { scope { target_cmdline: "pf-cpu-case" } kernel_frames: true }
  } } }
```

静态校验：`--check-resources` → `[PASS] 25 files + 4 configs`；`validate_config.py cfg/cpu_run3.pbtxt` → `[PASS] structural` + `[UNKNOWN] official schema: no --descriptor-set`。

### 3.2 观察者位置（吸取上一轮教训）

tracebox 通过 `taskset -c 0,4` 绑定（**避开 cpu1/cpu2 工作核，也避开其他实验用的 cpu5/6/7**），壳脚本 `tracebox_pinned2.sh`。实测结果（trace 内）：

| tracebox 线程 | 运行核 | cpu_ms |
|---|---|---|
| pid 9127 | **cpu0 only** | 680.5 |
| pid 9131 | **cpu4 only** | 241.3 |
| pid 9131 `stack-unwinding` | cpu4,0 | 62.5 |
| pid 9123 | cpu4,0 | 54.5 |

cpu1 / cpu2 上 tracebox 占用 **0 ms**。

### 3.3 执行

```sh
# 板端（captures/board_capture_run3.sh）：只启动本会话自己的 tracebox，不动被测进程与其他实验
WORK=/userdata/perfetto-cpu-session TRACEBOX=$WORK/tracebox_pinned2.sh \
  sh $WORK/linux_trace_session.sh $WORK/cpu_run3.pbtxt cpu_run3 60
```

| 项 | 值 |
|---|---|
| Trace | `captures/cpu_run3.pftrace`（sha256 `02046b5c…`），2 310 298 B |
| 窗口 | ts `14378596598731` – `14402583053700`，**23.986 s** |
| 状态 | `DONE size_bytes=2310298`；`traced_flushes_requested=1 / succeeded=1`、`traced_final_flush_succeeded=1` |
| 公共时延快照 | `captures/heartbeat_latency.run3.csv`（5259 行，sha256 `810652e1…`） |

---

## 4. 四级验收

| 级别 | 判定 | 依据 |
|---|---|---|
| **Schema** | **UNKNOWN** | Skill 未随包提供板端 collector 的 `trace_config.desc`；仅结构检查 PASS |
| **Runtime** | **PASS** | tracebox v57.1 = host TP v57.1；正常自然结束；flush 成功；采集前后 `tracing_on=0`、无其他 tracebox/traced |
| **Data** | **PASS（一项受限）** | 见下 |
| **Analysis / UI** | **SQL PASS；UI UNKNOWN** | 全部数字来自真实 `.pftrace`；本会话无 GUI，未伪造截图 |

Data 明细：

| 检查 | 结果 |
|---|---|
| `stats` 中 severity∈{data_loss,error} 且 value≠0 | **0 条** |
| `ftrace_cpu_dropped_events_delta` / `commit_overrun_delta` | 8 核全 0 |
| `traced_buf_data_loss_*` | 全 0 |
| 目标 | upid=4, pid=8143, `./pf-cpu-case`；1213 slice / 4020.0 ms |
| `thread_state` 含 R/R+ | 有（tick R 482 段 / 240.168 ms，max 14.064 ms） |
| `perf_sample` | 总数 19192；目标进程 784 |
| cpufreq | 8 核 × 25 秒级点，实测 300–1500 MHz |
| `clock_snapshot` | MONOTONIC 偏移 **+458 / +208 ns**（`mono_ns ≈ ts`，误差 <1 µs） |
| **受限** | `stack_profile_callsite` **max depth = 1**（28 callsite）：只有叶帧，无祖先链、无内核帧 |

---

## 5. 结果

### 5.1 谁在烧 CPU（系统级，24 s 窗口）

| 进程 | cpu_ms | 占单核 |
|---|---|---|
| `/userdata/perfetto-skill-lab/latency/pf-lat-case`（**外来实验**） | 7697.8 | **32.09%** |
| `/userdata/perfetto-skill-lab/scheduling/pf-sched-case`（**外来实验**） | 6510.4 | **27.14%** |
| `./pf-cpu-case`（**被测**） | 4020.0 | 16.76% |
| `tracebox`（观察者） | 1038.8 | 4.33% |

被测进程只是板上**第三大** CPU 消耗者。

### 5.2 被测进程内部：线程与亲和

| 线程 | tid | utid | 运行核 | slices | on-CPU ms | Running | R（等待） | R 最大单段 |
|---|---|---|---|---|---|---|---|---|
| `pf-worker-p` | 8147 | 219 | cpu1 | 269 | 2126.331 | 2126.331 | 52.942 ms | 1.298 ms |
| `pf-worker-q` | 8148 | 220 | cpu2 | 227 | 1327.852 | 1327.852 | 7.049 ms | 0.076 ms |
| `pf-svc-tick` | 8146 | 8 | cpu1 | 482 | 559.115 | 559.115 | **240.168 ms** | **14.064 ms** |
| `pf-cpu-case`(main) | 8143 | 7 | cpu6 | 235 | 6.729 | 6.729 | 7.623 ms | 0.192 ms |

`pf-worker-p` 的 slice 结构（>1 ms）：52 段，均值 **40.747 ms**，min 3.623，max 48.953，合计 2118.8 ms。

### 5.3 异常窗口（p / q 峰期）

| 事件 | 窗口（相对 trace 起点，s） | 时长 |
|---|---|---|
| p-burst #1 | 3.897 – 4.442 | 545.3 ms |
| p-burst #2 | 9.713 – 10.252 | 539.2 ms |
| p-burst #3 | 15.601 – 16.183 | 581.7 ms |
| p-burst #4 | 21.639 – 22.138 | 498.8 ms |
| q-burst #1 | 7.097 – 7.739 | 642.3 ms |
| q-burst #2 | 15.890 – 16.568 | 678.5 ms |

q-burst #1 期间各核占用：**cpu2 53.8%、cpu1 仅 2.3%**（cpu0 18.1%、cpu7 14.4% 来自外来实验）。

### 5.4 心跳时延：窗口内分类（480 次心跳）

判定方式：把每次心跳的 `[完成时刻 − latency, 完成时刻]` 与 p-burst / q-burst 窗口求交（`mono_ns ≈ ts`）。

| 分类 | n | p50 | mean | max |
|---|---|---|---|---|
| 与 **p-burst 重叠** | 44 | **5.130 ms** | 6.231 ms | **15.127 ms** |
| 与 **q-burst 重叠** | 20 | **1.082 ms** | 1.090 ms | 1.226 ms |
| 都不重叠（基线） | 416 | **1.148 ms** | 1.166 ms | 4.608 ms\* |
| 与 tracebox 重叠（cpu1/2） | **0** | — | — | — |

\* 该 4.608 ms 出现在 trace 起点 sec 0，恰好是不完整窗口的边界；不作为独立机制结论。

逐 burst：

| burst | 心跳数 | p50 | max |
|---|---|---|---|
| p#1 | 10 | 5.128 ms | 15.125 ms |
| p#2 | 11 | 5.128 ms | 15.127 ms |
| p#3 | 11 | 5.133 ms | 15.124 ms |
| p#4 | 10 | 5.132 ms | 5.231 ms |
| q#1 | 13 | 1.082 ms | 1.226 ms |
| q#2 | 13 | 1.087 ms | 15.124 ms\*\* |

\*\* q#2 的 15.124 ms 来自与 p-burst #3 的时间重叠（该心跳在 16.144 s），不是 q 造成；q 本身的最大影响仍是 1.2 ms 级。

### 5.5 主要贡献者：逐段归属（核心证据，非相关性推断）

对 trace 内 tick 的**全部** 482 段 runnable 等待，逐段查"同一时刻 cpu1 上是谁在运行"，并按进程汇总重叠时长：

| cpu1 上的持有者 | 涉及的等待段 | 持有 ms | 占比 |
|---|---|---|---|
| **`./pf-cpu-case`（`pf-worker-p`）** | 44 | **227.018** | **94.5%** |
| `[NULL]`（swapper/空闲） | 426 | 12.952 | 5.4% |
| `pf-lat-case`（**外来实验**） | 6 | **0.144** | **0.06%** |
| `kworker/1:0` | 7 | 0.056 | 0.02% |
| **合计** | — | **240.170** | 100% |

与 `thread_state` 独立统计的 tick R 总量 240.168 ms **精确闭合**（差 2 µs）。

> 说明：`[NULL]` 的 12.952 ms 分布在 426 段上（平均 ~30 µs），就是空闲核上"唤醒→被调度"的基本延迟，属正常基线。

**所有 >3 ms 的 44 段等待，全部由 `pf-worker-p` 持有；其中仅 1 段另有 10 µs 的 kworker 抖动，外来实验 0 段。**

### 5.6 机制链（逐条对账）

| 事件 | 心跳 latency | 之前的 R 等待 | 之后 tick 运行 | 合计 |
|---|---|---|---|---|
| 15.7293 s 起的等待 | 15.124 ms | **14.064 ms**（15.7293→15.7434） | **1.0592 ms** | **15.124 ms** |
| 4.4294 s 起的等待 | 13.785 ms | **12.722 ms** | ~1.06 ms | 13.78 ms |

且 tick 自身工作量**没有变重**：

| | slice 数 | 平均 on-CPU/slice | 最大 |
|---|---|---|---|
| 基线（p-burst 外） | 433 | **1.1845 ms** | 1.3986 ms |
| p-burst 内 | 49 | **0.9436 ms** | 1.2984 ms |

→ 增量 **100% 在"成为 runnable 之后、拿到 CPU 之前"**。

### 5.7 为什么量级是 5.13 / 15.14 ms

本实例 tick 的等待高度量化：**4.065 ms**（占绝大多数）与 **14.064 ms**，两者相差正好 10.0 ms；对应心跳 = 等待 + ≈1.06 ms 计算 → **≈5.13 ms** 与 **≈15.14 ms**，与 CSV 的 3–6 ms 箱（412 次）和 15.14 ms 簇（40 次）吻合。

对照组（会话内旧实例、更空闲的板子、同一程序同一配置）：等待量为 **0–1.4 ms / 11.4 ms / 21.5 ms**，对应心跳簇 **12.5 / 22.6 / 31.6 ms**。

→ **同一程序的延迟量级随"同核竞争形态"变化**，不随外来负载的绝对 CPU 量变化。

### 5.8 频率：不构成因果

| 秒 | cpu1 平均 MHz | 该秒心跳均值 | 最大 |
|---|---|---|---|
| 14 | **1175** | **1.087 ms**（全程最快） | 1.123 ms |
| 19 | **450** | 1.220 ms | 1.243 ms |
| 0 | 615 | 1.317 ms | 4.608 ms |
| 4 | 796 | **3.875 ms**（p-burst） | 15.125 ms |
| 9 | 653 | 2.857 ms（p-burst） | 15.127 ms |

高频秒可以是最快的秒，低频秒可以是平稳的秒；变慢的秒都与 burst 对齐。**无单调关系，不支持降频致因。**

### 5.9 采样热点：不可当根因（重要反例）

目标进程 784 个样本的叶帧分布：

| 线程 | 叶帧 | 样本 | on-CPU | 样本/CPU-s |
|---|---|---|---|---|
| `pf-svc-tick` | `svc_compute_until(long)`（`_Z17svc_compute_untillm`） | **435** | 559.1 ms | **778.0** |
| `pf-worker-p` | `pfp::p_kernel_hot`（`_ZN3pfp12p_kernel_hotEml`） | 217 | 2126.3 ms | 102.1 |
| `pf-worker-q` | `pfq::q_kernel_hot`（`_ZN3pfq12q_kernel_hotEml`） | 132 | 1327.9 ms | 99.4 |

两条硬证据说明 tick 的 435 个样本**不是 CPU 时间**：

1. 435 个样本 **427 个**落在该线程自己的 Running 区间内，且间隔严格为 **50 ms**（正是它的唤醒周期）；
2. 按 100 Hz/CPU 的时基，559.1 ms 的 on-CPU 最多应得 ~56 个样本，实测 **778 样本/CPU-s**（7.8 倍）。

→ 这是**采样相位与 50 ms 唤醒节拍锁定**造成的伪影。**若按"样本最多 = 最热 = 根因"解读，会得出完全错误的结论。**
旁证：同一配置在旧实例上给了该线程 **0 个样本**（当时第一名是 `p_kernel_hot`），排名本身不稳定。

补充：`perf_sample` 中 **16873/19192** 落在 `pid 0 ([NULL])`，另有 922 属 `pf-lat-case`、510 属 `pf-sched-case` —— 配置里的 `scope.target_cmdline` **没有生效**，采样是全机的；本报告只使用按 utid 归属到目标进程的样本。

`stack_profile_callsite` 最大深度 = **1**：只有叶帧，**没有** `p_submit_batch > p_parse_batch > … > p_kernel_hot` 的祖先链；`kernel_frames: true` 也未产出内核帧。

### 5.10 Skill 自带 SQL 的独立复核（`05` / `06` / `08`）

**`08-core-busy.sql`**（整机各逻辑核 busy，24 s 窗口）：

| cpu | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| busy % | 6.75 | **11.42** | **19.92** | 2.37 | 2.45 | 16.84 | 10.52 | 10.86 |

（cpu5/6/7 的占用主要来自外来实验；cpu2 最高是因为 q + 外来实验叠加。）

**`06-cpu-spike-episodes.sql`**（200 ms 桶、阈值 150 ms，按 UPID 汇总所有线程 —— 与按线程的 p/q 判定相互独立）：

| episode 起点（相对，s） | 时长 | 桶数 | 峰值 cpu_ms/桶 | 对应 |
|---|---|---|---|---|
| 4.0 | 400 ms | 2 | 200.04 | p-burst #1 |
| 7.2 | 400 ms | 2 | 204.31 | q-burst #1 |
| 9.8 | 400 ms | 2 | 200.06 | p-burst #2 |
| **15.6** | **1000 ms** | 5 | **383.78** | **p-burst #3 与 q-burst #2 时间重叠**（两核同时打满，故单桶 383.78 ms > 200 ms） |
| 21.6 | 400 ms | 2 | 200.03 | p-burst #4 |

这份输出**独立复现了 §5.3 的窗口**，并额外量化了 p#3/q#2 的重叠（这也是 §5.4 中 q#2 出现一次 15.124 ms 心跳的原因——它其实来自并行的 p-burst）。

**`05-cpu-time-buckets.sql`**（200 ms 桶、区间求交）：473 行；基线桶 `target ≈ 5.0 ms / 200 ms`（几乎全为 `pf-svc-tick`），峰值桶 `pf-worker-p = 100.9–200.0 ms / 200 ms` —— 与 §5.5 的归属一致。

**`03-runnable-latency.sql`**（阈值 1 ms，目标 UPID）：86 段（含全部线程）；其中 `pf-svc-tick` 的 **≥3 ms 等待 44 段，全部（44/44）落在 4 个 p-burst 窗口内**，最长 **14.064 ms**。

---

## 6. 全量业务影响（公共 CSV，262.9 s / 5259 次心跳）

| 指标 | 值 |
|---|---|
| min / p50 / p90 / p99 / max | 1.052 / **1.180** / 1.231 / **15.124** / **34.185** ms |
| mean | 1.617 ms |
| 分布 | <1.5 ms: 4786（91.0%）；1.5–3 ms: 5（0.1%）；**3–6 ms: 412（7.8%）**；6–10 ms: 0；**≥10 ms: 56（1.07%）** |
| ≥10 ms 幅度簇 | **≈15.14 ms × 40**；≈24–25 ms × 7；34.18 ms × 1；13.79 ms × 1；其余 ≈15.2 ms |
| ≥10 ms 事件间隔 | 中位数 **5.65 s**（与 p 周期 ≈6 s 一致） |

分布呈"**双峰 + 空档**"：正常态紧贴 1.18 ms，异常态跳到 15.1/24.6 ms，中间几乎为空 —— 与"整段等待某个 slice 结束"的机制一致，而非"计算变慢"。

跨实例对照（同一程序/同一配置，不同板面噪声）：

| 指标 | 本实例（pid 8143，共享板） | 旧实例（pid 1762，空闲板） |
|---|---|---|
| 心跳数 / 时长 | 5259 / 262.9 s | 4205 / 210.2 s |
| p50 / p99 / max | 1.180 / 15.124 / 34.185 ms | 1.189 / 2.617 / 32.602 ms |
| ≥10 ms 比例 | 1.07% | 0.78% |
| 主簇幅度 | **15.14 ms** | **12.5 / 22.6 / 31.6 ms** |
| p-burst 内心跳 p50 | 5.128–5.133 ms | 2.505–2.514 ms |
| q-burst 内心跳 p50 | 1.082–1.087 ms | 1.086–1.089 ms |

---

## 7. 证据边界（UNKNOWN 清单）

1. **`PUBLIC_BRIEF.md` 缺失**：部署信息改由 `RUN_INFO.md` + `README.md` 提供，已在 §1.1 披露；若 brief 另有内容，运行上下文需按 brief 复核。
2. **官方 schema 级 PASS**：无 collector descriptor → UNKNOWN。
3. **函数级调用链祖先 / 内核帧**：`max depth = 1`、无内核帧 → UNKNOWN（本次 `kernel_frames: true` 未生效）。
4. **4.065 / 14.064 ms 量化背后的内核机制**：本次未采 `sched_wakeup` 细节、未确认 `CONFIG_HZ`/`sched_wakeup_granularity`，只报告"观测到 10.0 ms 步进的离散量级"，**属假设不属结论**。
5. **窗口外的 56 次 ≥10 ms 事件**：仅 4 次（15.12 ms 级）落在 trace 窗口内并有逐段归属；其余 52 次只能由"间隔中位 5.65 s ≈ p 周期"推断，**未逐事件证明**。
6. **24–25 ms 簇（7 次）**：全部在窗口外，量级为 15.14 的约 1.6 倍，机制 UNKNOWN。
7. **`pf-svc-tick` 的 `D` 状态**：本次首次出现 D 共 21.158 ms（最大 5.693 ms），旧实例仅 0.092 ms。它远小于 R 的 240 ms，不是主要贡献者，但**成因 UNKNOWN**（未采块 IO / 缺页事件）。
8. **观察者效应**：本次已把 tracebox 移出工作核（cpu1/2 占用 0 ms），但不等于"零影响"——tracebox 仍占 4.33% 系统 CPU、且 frtrace drain 会短暂关中断；这部分无法在单机内完全消除，**残留影响量级 UNKNOWN**。
9. **外来实验的影响面**：已证明它们对心跳延迟的直接贡献仅 0.06%，但它们占 59% 系统 CPU，可能通过**改变了 worker-p 的 slice 结构**间接改变了延迟量级（§5.7 的 4.06 vs 1.2 ms 差异）。这一间接通道**未做受控实验**，属 UNKNOWN。
10. **UI**：无 GUI，未截图 → `UI_UNKNOWN`（步骤见 §9）。

---

## 8. 复现清单

目录：`/root/sdk_ly_x5_1.1.1/tmp/perf-cpu-firstpass-r2/`

| 文件 | 用途 |
|---|---|
| `captures/cpu_run3.pftrace` | 本次真实 trace（2 310 298 B，sha256 `02046b5c…`） |
| `captures/cpu_run3.status` / `.log` | `DONE size_bytes=2310298` / 起止时间 |
| `captures/heartbeat_latency.run3.csv` | 采集结束时的公共业务时延（5259 行，sha256 `810652e1…`） |
| `captures/heartbeat_latency.pre.csv` | 采集前的公共时延（用于先看分布，sha256 `62663c07…`） |
| `captures/board_capture_run3.sh` | 板端驱动（含抓取前的 tracing 空闲检查、外来进程清单，可原样重跑） |
| `captures/post_capture_run3.txt` | 采集后状态（被测/外来进程、loadavg、频率、`tracing_on`） |
| `cfg/cpu_run3.pbtxt`, `cfg/base_freq.pbtxt` | 实际配置（sha256 `a940af07…`） |
| `analyze.py` | 生成窗口/聚类/采样统计的脚本 |
| `sqlout/run3/analysis.json` | 结构化结果（本报告多数数字的直接来源） |
| `sqlout/run3/skill{02,03,05,06,08}.csv` + `*-run.sql` | Skill 自带 SQL 的原始输出与改参后全文（§5.10） |
| `sqlout/run3/*.csv` | 其余原始 SQL 输出：`attrib_cpu1`(逐段归属) `attrib_all`(分类汇总) `longR` `threads` `wp_slices` `tick_compute` `after_wait` `reconcile` `per_sec` `freq_sec` `qburst_cores` `tb_cpus` `perf_upid` `sample_vs_cpu` `sample_inside` `sample_detail` `cpulean` `syscpu` |
| `run_sql.sh` / `run_sqlf.sh` | TP 查询封装（stdout/stderr 分离，避免日志插进 CSV） |

关键文件哈希：

```
02046b5ca4b67d9bdff618abc5a8def9e46df7790536f2264ef0eb5cede07da3  captures/cpu_run3.pftrace
810652e1d732a4ef89e77f879efc722f965e9b2bad5cb85c339adfcd7e1991a3  captures/heartbeat_latency.run3.csv
62663c0743a5bf06d2eea6db6c4327758114546fdafa867e875181755bf013f2  captures/heartbeat_latency.pre.csv
a940af0798ce932a3eaca93f8cd5cb11eb318b2b0bbe6f45942358a23f18b546  cfg/cpu_run3.pbtxt
40adeb975459b638c4c94f06cca6466bb942304c98ab6aaec227eab8dac667c1  analyze.py
```

---

## 9. Skill 版本与哈希

| 项 | 值 |
|---|---|
| Skill | `perfetto-cpu-debugging` v`0.1.0`（status `candidate`），38 文件 |
| 目录 | `/root/.dsh/skills/perfetto-cpu-debugging` |
| MANIFEST 自校验 | 37 项全部一致，**0 mismatch** |
| 树哈希 A（`find \| sha256sum \| sha256sum`） | `85e518409ee47f20ad012b1a1d0b05558fdd19dd2a6b56deeedaaf55c7ae073c` |
| 树哈希 B（38 文件哈希按路径排序拼接再 sha256） | `eb062c4969f7c2a8e3b5ffd195ff92badb64dfb75e89177289500f97f439739b` |
| 被测程序 | `pf-cpu-case` v1.0.0，Build ID sha1 `5216590986a25ab51f5c924c25db8dee675320b7`（trace 内 mapping 实测一致） |
| 采集器 / 分析器 | tracebox `v57.1-c59f57dd4` / trace_processor `v57.1-c59f57dd4` |

---

## 10. UI 复现步骤（本会话未执行 → `UI_UNKNOWN`）

打开 <https://ui.perfetto.dev/>，加载 `captures/cpu_run3.pftrace`：

1. **找进程**：搜 `pf-cpu-case`，展开后 4 条线程轨：`pf-cpu-case`(8143,cpu6)、`pf-svc-tick`(8146)、`pf-worker-p`(8147)、`pf-worker-q`(8148)。
2. **核轨对照**：`CPU 1` Scheduler 在 3.9–4.4 s / 9.7–10.3 s / 15.6–16.2 s / 21.6–22.1 s 被 `pf-worker-p` 填满；`CPU 2` 在 7.1–7.7 s / 15.9–16.6 s 被 `pf-worker-q` 填满，而这两段 **CPU 1 几乎空闲**。
3. **外来实验**：`CPU 0/4` 上会出现 `pf-lat-case` 与本会话 `tracebox` 的轨；`CPU 5/6/7` 上出现 `pf-sched-case`。确认 **CPU1/CPU2 上没有 tracebox**（绑核生效）。
4. **R 等待**：选 `pf-svc-tick` 线程轨，只显示 `Runnable`；在 4.28 s 处有一段 **14.06 ms** 的等待，紧贴 `pf-worker-p` 的 slice 边界。
5. **CPU 时间桶**：Query(SQL) 跑 `sqlout/run3/05-run.sql` → 结果 `⋮` → Add debug track → Counter（Timestamp=`ts`，Value=`cpu_ms`，Pivot=`utid`）。
6. **尖峰 episode**：跑 `sqlout/run3/06-run.sql` → Add debug track → Slice（ns）。
7. **逐段归属（本次核心证据）**：直接跑
   ```sql
   WITH tick AS (SELECT utid FROM thread WHERE tid=8146),
        r AS (SELECT st.ts, st.dur FROM thread_state st JOIN tick USING(utid)
              WHERE st.state IN ('R','R+') AND st.dur>3000000)
   SELECT ROUND((r.ts-14378596598731)/1e9,3) wait_s, ROUND(r.dur/1e6,2) wait_ms,
          p.name proc, th.name thr,
          ROUND(SUM(MIN(s.ts+s.dur,r.ts+r.dur)-MAX(s.ts,r.ts))/1e6,2) held_ms
   FROM r JOIN sched_slice s ON s.cpu=1 AND s.ts < r.ts+r.dur AND s.ts+s.dur > r.ts
   JOIN thread th USING(utid) JOIN process p USING(upid)
   GROUP BY r.ts,r.dur,p.name,th.name ORDER BY r.ts, held_ms DESC;
   ```
8. **频率**：勾选 `CPU Frequency`，在 14 s（≈1175 MHz）与 19 s（≈450 MHz）两处对比心跳时延轨（1.09 vs 1.22 ms）。
9. **Perf 陷阱自检**：选 `Perf Samples` → Flamegraph，会看到 `svc_compute_until` 柱子最高；务必用 §5.9 的两条判据（样本间隔 = 50 ms、778 样本/CPU-s）识别其为相位伪影，**不要**据此判定根因。

---

## 11. 最小下一步（不影响本报告主结论）

1. 若要函数级调用链：改用 `perf record -g --call-graph fp` 或其他能出深栈的采集方式（本次 depth=1 无法补）。
2. 若要判定 §7.9 的"外来负载→slice 结构→延迟量级"间接通道：需要在**同一板面**分别有/无外来负载的同实例对照（本次未做，且不得为分析去关别人的实验）。
3. 若要解释 `D` 状态 21 ms：需补采块 IO / 缺页事件（`block:*`、`kmem:*`），本次未采。
