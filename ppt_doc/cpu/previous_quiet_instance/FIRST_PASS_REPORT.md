# FIRST_PASS_REPORT — pf-cpu-case 周期 CPU 异常与心跳时延（X5 实测）

- 报告类型：首轮盲测（FIRST_PASS），由 `perfetto-cpu-debugging` Skill v0.1.0-candidate 驱动
- 执行时间：本会话，板端 CLOCK_MONOTONIC ≈ 1.23e12 ~ 1.44e12 ns 区间（板 RTC 未对时，故只报单调时钟）
- 目标程序：`pf-cpu-case` v1.0.0（pid 1762），板端 `/userdata/perfetto-skill-lab/cpu/`
- 采集次数：2 次真实上板采集（同一运行实例、同一 TraceConfig，仅观察者 CPU 位置不同）
- 结论强度：异常窗口、主要贡献者、观察者效应量级 = **有实测证据**；函数级调用链祖先、窗口外归因、UI 截图 = **UNKNOWN**

---

## 0. 结论摘要（先给结论，再给证据）

1. **业务异常确实存在且可复现**：心跳时延在 210.2 s / 4205 次心跳中 p50 = 1.189 ms，但出现 **33 次 ≥10 ms** 的尾部事件，最大 **32.60 ms**；尾部事件间隔中位数 **5.78 s**，与 trace 中观测到的 `pf-worker-p` 周期（≈6 s）一致。
2. **trace 内的异常窗口集中在 `pf-worker-p` 峰值区间（p-burst）**。两次采样的 p-burst 窗口内，心跳时延 p50 从基线 1.200 ms 升到 **2.505 / 2.514 ms**（≈2.1×），并出现 **12.6 ms / 22.6 ms** 的离散尖峰。
3. **可比对照：`pf-worker-q` 的峰值更大（617–687 ms vs 471–600 ms）但位于另一核，心跳时延不但没变差，反而略优于基线（p50 1.086 / 1.089 ms）**。→ 大 CPU 热点不自动等于业务时延根因；位置（是否与心跳线程同核）才是关键。
4. **机制不是"算得更久"，而是"等得更久"**：`pf-svc-tick` 自身 on-CPU 时间在峰值期没有变长（基线均值 1.212 ms vs 峰值期 1.093 ms），增加的时间全部落在 `thread_state = R`（runnable 等待）。逐条对账：等待 11.469 ms + 运行 1.301 ms ≈ 心跳 12.642 ms；等待 21.468 ms + 运行 1.276 ms ≈ 心跳 22.623 ms。
5. **观察者效应被实测分离并移除**：run1 中 tracebox 自身落到工作核 cpu1，造成 19.8–21.4 ms 连续占用；run1 窗口内 5 个 ≥10 ms 事件中有 **3 个** 与 tracebox 精确同窗。run2 把 tracebox 限定在 cpu0/4/5/6/7 后，cpu1/cpu2 上 tracebox 占用为 0，观察者类心跳消失，剩余 ≥10 ms 事件仍全部落在 p-burst 内。→ 主归因成立，观察者效应已量化并有界。
6. **频率不是原因**：8 核共用同一 cpufreq 取值（cpu1/cpu2 每个时刻完全相同），300–1500 MHz、governor=schedutil。按秒统计显示**时延变差的秒恰好是高频秒**（950–1175 MHz，均值 1.84–2.97 ms），450–660 MHz 的秒均值仅 1.12–1.19 ms。→ 反相关，不支持降频致因。

---

## 1. 输入来源与合规声明

### 1.1 关键偏差：`PUBLIC_BRIEF.md` 不存在

任务要求"运行与部署信息仅从 `perfetto_skill_lab/cpu/PUBLIC_BRIEF.md` 获取"。实际核查：

```
find / -iname "*PUBLIC_BRIEF*"   → 0 hit
ls perfetto_skill_lab/cpu/       → Makefile README.md RUN_INFO.md SELFTEST.md pf-cpu-case pf_cpu_case.cpp
```

该文件在整机范围内不存在（含大小写、全盘 maxdepth 6 与全量 grep）。**本报告因此改用了同目录下唯一属于"公开部署信息"的两份文件**：

| 实际来源 | 用途 | 是否受限 |
|---|---|---|
| `perfetto_skill_lab/cpu/RUN_INFO.md` (e7fcb3a6…) | 板地址、启动/停止/查询命令、程序路径、版本/Build ID、**公共**心跳 CSV 路径与字段语义 | 部署信息，等价于 brief 的应含内容 |
| `perfetto_skill_lab/cpu/README.md` (3c28f7e3…) | 程序公共描述（线程名、输出文件、板端路径）、"只有一个默认模式、无关闭线程开关" | 公共描述 |
| `/root/agent.md` | 板卡网络/口令备忘（**当前平台信息**） | 允许 |
| Skill 自身 package | 路线/配置/SQL/验收口径 | 允许 |

**未读取**（并保持未读直至本报告冻结）：

- `perfetto_skill_lab/cpu/pf_cpu_case.cpp`（源码）
- `perfetto_skill_lab/cpu/SELFTEST.md`（A 的自测材料）
- `/userdata/perfetto-skill-lab/cpu/private/`（`heartbeat_raw.csv`/`burst_raw.csv`/`run_info.txt`，RUN_INFO 明确标注"不属于公共观测面，请勿用于分析"）
- 未反编译、未 `strings` 目标程序、未搜索历史答案/既有 trace；`/userdata/sched-ab-demo/`（他人实验目录）只用于**取 tracebox 二进制**，未读取其 log/pftrace。

### 1.2 只用的业务数据

- `heartbeat_latency.csv`（公共）：`seq,mono_ns,latency_ns`。两次快照：
  - run1 结束时 477 行（实例启动 24 s）
  - run2 结束时 4205 行（实例启动 210.2 s，**同一实例的完整记录**，故用它做全量统计）
- 程序 stdout `run.log`（RUN_INFO 声明为标准输出，公共）：给出选核结果 `p_core=1 / q_core=2 / main_core=3`，用于与 trace 的亲和性交叉验证。

### 1.3 未做的事（按指令）

- 未执行预设 A/B 对照、未 `pkill`/关闭任何计算线程、未重启业务、未注入故障。
- 未改 `perf_event_paranoid`/`kptr_restrict`/governor，未改内核，未改其他程序。
- 采集前后确认板上**不存在**系统 `traced`/`traced_probes`/`traced_perf`/其他 `tracebox`，本会话的 tracebox 是唯一 tracing 会话 → 未抢占系统 tracing service。
- 程序保持运行（未关闭负载），采集结束后未做清理式杀进程。

---

## 2. 环境（只读探测，PASS）

`sh scripts/survey.sh` + `--events`（原始输出：`captures/survey.txt`、`captures/available_events.txt`，1768 行事件）：

| 项 | 实测值 |
|---|---|
| 内核 | `Linux buildroot 6.1.83-DR-PL5.1_V1.1.1 #1 SMP PREEMPT aarch64`（LNX6.1.83_PL5.1_V1.1.1_20261022-1147） |
| CPU | 8 × capacity=1024（同构），`cpuinfo_min/max` = 300000/1500000 kHz，governor=`schedutil` |
| tracefs | `/sys/kernel/debug/tracing`，`current_tracer=nop`，`trace_clock=[local]` |
| 关键事件 | `sched:sched_switch` / `sched:sched_waking` / `sched:sched_wakeup` / `sched:sched_wakeup_new` / `power:cpu_frequency` / `power:cpu_idle` 全部存在 |
| 权限 | root；`perf_event_paranoid=2`，`kptr_restrict=0` |
| 工具 | 板上无 `tracebox`/`perfetto` 于 PATH，仅 `/usr/bin/perf` 6.1.12；本会话 tracebox 取自 `/userdata/perfetto-skill-lab/memory/tracebox` = **Perfetto v57.1-c59f57dd4**（md5 `fe131c3ac583ffc70936bc2cbfcd5a8e`） |
| 主机 TP | `/root/.cache/perfetto-skill/trace_processor_shell` = **v57.1-c59f57dd4**（与板端 collector **同版本**） |
| 存储 | `/userdata` ext4 rw，26 G 可用（trace 写这里，不落 tmpfs，避免自身干扰） |
| 采集前负载 | loadavg 0.04/0.01/0.00，`1/200` 可运行，系统基本空闲 |

程序公共状态（run.log + `/proc`）：

```
pf-cpu-case v1.0.0 pid=1762
selected p_core=1 (hosts svc-tick+worker-p) q_core=2 main_core=3
```

线程亲和性由 `/proc/<tid>/status:Cpus_allowed_list` **独立核实**：`1764 pf-svc-tick cpus=1`、`1765 pf-worker-p cpus=1`、`1766 pf-worker-q cpus=2`、`1762 main cpus=3` —— 与 trace 内实际运行核完全一致（见 §5.2），非仅凭日志。

---

## 3. 采集路线与配置

### 3.1 路由决策

症状是"周期性 CPU 尖峰 + 业务心跳时延"，且需要区分"谁在烧 CPU"与"为什么心跳慢"。按 Skill §1：

- 主路由 **scheduling**（`sched_switch` + `sched_waking` → `sched_slice` / `thread_state` / Runnable）
- 并行 **frequency**（`power/cpu_frequency` + `power/cpu_idle` + `linux.sys_stats cpufreq` 轮询），用于主动排除降频
- 条件路由 **profiling**（`linux.perf`），只在需要函数级归因时启用；本机 `perf_event_paranoid=2` 但为 root 且 tracebox 内含 `traced_perf`，先做单次 smoke 而不是改 sysctl

Skill 的 4 个模板是互斥的（`make_config.py` 只有单一 route），因此**用模板生成 freq 路线，再按 profiling 模板原文追加 `linux.perf` 段**；组合处已在上文标注，模板字段未改写。

### 3.2 生成与校验命令（主机）

```bash
# 事件清单来自板端只读 survey
ssh BOARD 'sh /userdata/perfetto-cpu-session/survey.sh --events' > captures/available_events.txt

python3 $SKILL/scripts/make_config.py frequency --platform linux \
  --events captures/available_events.txt --duration-ms 20000 \
  --poll-ms 200 --buffer-kb 32768 --ftrace-kb 2048 --drain-ms 100 \
  > cfg/base_freq.pbtxt

# 追加（逐字段等同 configs/cpu-profiling.pbtxt 的 linux.perf 段）
cat >> cfg/cpu_firstpass.pbtxt <<'EOF'
data_sources { config { name: "linux.perf"
  perf_event_config {
    timebase { counter: SW_CPU_CLOCK frequency: 100 timestamp_clock: PERF_CLOCK_MONOTONIC }
    callstack_sampling { scope { target_cmdline: "pf-cpu-case" } kernel_frames: true }
  }
} }
EOF

python3 $SKILL/scripts/validate_config.py --check-resources   # → [PASS] 25 files + 4 configs
python3 $SKILL/scripts/validate_config.py cfg/cpu_firstpass.pbtxt
# → [PASS] structural checks passed (NOT official schema)
# → [UNKNOWN] official schema: no --descriptor-set
```

### 3.3 实际生效配置（`cfg/cpu_firstpass.pbtxt`, sha256 `144908e4…`）

```
duration_ms: 20000

buffers { size_kb: 32768 fill_policy: RING_BUFFER }

data_sources { config { name: "linux.process_stats" process_stats_config { scan_all_processes_on_start: true proc_stats_poll_ms: 1000 } } }

data_sources { config { name: "linux.ftrace"
    ftrace_config { buffer_size_kb: 2048 drain_period_ms: 100
      ftrace_events: "sched/sched_switch"
      ftrace_events: "sched/sched_waking"
      ftrace_events: "sched/sched_wakeup_new"
      ftrace_events: "power/cpu_frequency"
      ftrace_events: "power/cpu_idle"
    }
  } }

data_sources { config { name: "linux.sys_stats" sys_stats_config { cpufreq_period_ms: 200 } } }

data_sources { config { name: "linux.perf"
  perf_event_config {
    timebase { counter: SW_CPU_CLOCK frequency: 100 timestamp_clock: PERF_CLOCK_MONOTONIC }
    callstack_sampling { scope { target_cmdline: "pf-cpu-case" } kernel_frames: true }
  }
} }
```

### 3.4 目标机执行（板端，脚本原文见 `captures/board_capture.sh` / `board_capture2.sh`）

```sh
# 只启动文档化的单一默认模式，不碰其他进程
setsid nohup /userdata/perfetto-skill-lab/cpu/pf-cpu-case > .../run.log 2>&1 < /dev/null &
sleep 4
WORK=/userdata/perfetto-cpu-session TRACEBOX=$WORK/tracebox \
  sh $WORK/linux_trace_session.sh $WORK/cpu_firstpass.pbtxt cpu_firstpass 45
cp $APPDIR/heartbeat_latency.csv $WORK/heartbeat_latency.public.csv   # 公共时延记录快照
```

两次采集的**唯一差异**（补采目的：分离观察者效应）：

| run | tracebox CPU 位置 | 时间窗（ts, ns） | 时长 | 大小 | 状态 |
|---|---|---|---|---|---|
| run1 | 不限定（默认可跑任意核） | 1234004298046 – 1254131767722 | 20.127 s | 1 613 046 B | `DONE` |
| run2 | `taskset -c 0,4,5,6,7`（避开工作核 cpu1/2/3） | 1420405059802 – 1440390373520 | 19.985 s | 1 594 756 B | `DONE` |

两次均正常自然结束（非 `TIMEOUT_STOPPED`）：`traced_flushes_requested=1 / succeeded=1`、`traced_final_flush_succeeded=1`。

---

## 4. 四级验收（Schema / Runtime / Data / Analysis）

| 级别 | 判定 | 依据 |
|---|---|---|
| **1 Schema（collector）** | **UNKNOWN** | Skill 未随包提供 tracebox v57.1 对应的 `trace_config.desc`，`validate_config.py` 报 `[UNKNOWN] official schema: no --descriptor-set`。仅有结构检查 PASS，**不等于** collector schema PASS。 |
| **2 Runtime** | **PASS** | tracebox v57.1 = host TP v57.1（版本严格匹配）；tracebox 正常启动/停止；`.status = DONE size_bytes=…`；flush 成功；进程 stats 显示 `traced_data_sources_seen=4`、`traced_producers_connected=2`（linux.ftrace + linux.perf 生产者就绪）。 |
| **3 Data** | **PASS（一项受限）** | 见 §4.1 |
| **4 Analysis / UI** | **SQL PASS，UI UNKNOWN** | 全部数字来自真实 `.pftrace` 上的 PerfettoSQL；本会话无 GUI，未伪造截图，UI 复现步骤见 §9。 |

### 4.1 Data 级明细

| 检查项 | run1 | run2 |
|---|---|---|
| `stats` 中 severity∈{data_loss,error} 且 value≠0 | **0 条** | **0 条** |
| `ftrace_cpu_dropped_events_delta`（8 核） | 全 0 | 全 0 |
| `ftrace_cpu_commit_overrun_delta`（8 核） | 全 0 | 全 0 |
| `traced_buf_data_loss_*` | 全 0 | 全 0 |
| 目标 UPID/UTID | upid=188, pid=1762 | upid=184, pid=1762 |
| `sched_slice` 覆盖 | 目标 1003 slice / 3394.2 ms | 目标 1002 slice / 3336.8 ms |
| `thread_state` 含 R/R+ | 有（svc-tick R 397 段 / 114.43 ms） | 有（svc-tick R 393 段 / 90.65 ms + R+ 1 段） |
| `perf_sample` | 总数 16000，目标进程 **294** | 15603，目标 **300** |
| `perf_samples_skipped` | 0 | 0 |
| cpufreq 计数器 | 8 核 × 250 点（200 ms 轮询 + 变更事件） | 同 |
| `clock_snapshot` 含 MONOTONIC | 有（2 个快照） | 有（2 个快照） |
| **受限项** | `stack_profile_callsite` **max depth = 1**（23 callsite / 23 frame）：只有叶帧，没有祖先链 | 同（34 callsite） |

> 说明：`linux.perf` 的 `perf_sample` 有 15 613 条落在 `pid 0 ([NULL])`，说明本版 tracebox 的 `scope.target_cmdline` 并未把采样限制在目标进程；本报告**只使用按 utid 归属到目标进程的样本**（294/300 条），不把全机 summary tree 当作目标热点。

---

## 5. 结果：异常窗口、主要贡献者、业务影响

### 5.1 CPU 时间桶（Skill `05-cpu-time-buckets.sql`，200 ms 桶，区间求交）

run1 目标进程（upid=188）逐线程桶（单位 ms/200 ms，节选）：

```
 idx   t_s  main  svc-tick  worker-p  worker-q   SUM
  10   1.6   0.1       5.1       0.1       0.1     5.4     ← 基线：≈2.7% 单核
  19   3.4   0.1       5.0      62.1       0.1    67.4
  20   3.6   0.0       4.3     195.6       0.0   200.0     ← cpu1 被 worker-p 占满 ≈98%
  21   3.8   0.0       4.3     195.7       0.0   200.0
  22   4.0   0.0       4.3      94.1       0.0    98.4
  40   7.6   0.1       5.0       0.1     111.2   116.3
  41   7.8   0.0       4.3       0.0     200.0   204.3     ← cpu2 被 worker-q 占满
  42   8.0   0.0       4.3       0.0     200.0   204.3
  48   9.2   0.1       5.1       0.1       0.1     5.3
  49   9.4   0.1       4.3     195.6       0.0   200.0     ← p-burst #2
  86  16.8   0.1       5.0       0.0     123.1   128.2     ← q-burst #2
  87  17.0   0.0       4.2       0.0     200.0   204.3
```

要点：
- 基线时目标进程共 **≈5.3 ms / 200 ms（≈2.6% 单核）**，几乎全部来自 `pf-svc-tick`（每 50 ms 约 1 ms）。
- 峰值窗口里 **单个桶 = 200.0 ms**，即该核被单个 worker 完全占满。
- 峰值期间 `svc-tick` 的桶从 5.1 ms 掉到 **4.2–4.3 ms**（被挤掉约 15%），但**没有掉到 0**。

### 5.2 异常窗口（两次采样一致）

| 事件 | run1 窗口（相对 trace 起点，s） | 时长 | run2 窗口 | 时长 |
|---|---|---|---|---|
| p-burst #1 | 3.937 – 4.496 | 559.5 ms | 3.485 – 3.956 | 471.3 ms |
| p-burst #2 | 9.766 – 10.290 | 524.5 ms | 9.266 – 9.796 | 529.1 ms |
| p-burst #3 | 15.891 – 16.389 | 498.6 ms | 15.097 – 15.697 | 599.6 ms |
| q-burst #1 | 8.089 – 8.751 | 661.9 ms | 1.519 – 2.136 | 617.2 ms |
| q-burst #2 | 17.277 – 17.964 | 687.3 ms | 10.509 – 11.153 | 644.3 ms |

（窗口由 `pf-worker-p` / `pf-worker-q` 的 `sched_slice` 按间隔 <3/5 ms 合并成 episode，脚本 `analyze.py`）

核占用（Skill `08-core-busy.sql`，占单核百分比）：

| | cpu0 | cpu1 | cpu2 | cpu3 | cpu4 | cpu5 | cpu6 | cpu7 |
|---|---|---|---|---|---|---|---|---|
| run1 | 0.75 | **11.35** | **8.68** | 0.30 | 0.38 | 0.05 | 0.04 | 0.16 |
| run2 | 3.18* | **10.28** | **6.56** | 0.11 | 0.84 | 0.01 | 0.25 | 0.42 |

\* run2 的 cpu0 升高是 tracebox 被 `taskset` 限定到 cpu0/4/5/6/7 的结果（观察者自身开销），与业务无关。

### 5.3 主要贡献者：线程级归因（有证据）

目标进程 4 个线程在 20 s 内的 on-CPU（`sched_slice`）与状态（`thread_state`）：

| 线程 | tid | 运行核 | slices | on-CPU ms | Running | R（runnable 等待） | R 最大单段 |
|---|---|---|---|---|---|---|---|
| `pf-worker-p` | 1765 | cpu1 | 226 | 1555.17 | 1555.17 | 56.09 ms | 14.54 ms |
| `pf-worker-q` | 1766 | cpu2 | 184 | 1356.30 | 1356.30 | **8.19 ms** | 0.08 ms |
| `pf-svc-tick` | 1764 | cpu1 | 399 | 476.24 | 476.24 | **114.43 ms** | **12.24 ms** |
| `pf-cpu-case`(main) | 1762 | cpu3 | 194 | 6.50 | 6.50 | 7.57 ms | 0.12 ms |

**`pf-svc-tick` 的 runnable 等待是 q 线程的 14 倍**，且长段全部落在 p-burst 内：

```
run1  svc-tick 长 R 段（ns → 相对 trace 起点）：
  1237958579715  3.954 s  11.469 ms  （p-burst #1 内，worker-p slice 边界结束）
  1243008581384  9.004 s  11.840 ms  （tracebox 占 cpu1）
  1247008587719 13.004 s  11.416 ms  （tracebox 占 cpu1）
  1249908575554 15.904 s  11.492 ms  （p-burst #3 内）
  1253008587264 18.004 s  12.236 ms  （tracebox 占 cpu1）
```

### 5.4 业务影响：与公共 `heartbeat_latency.csv` 对齐

对齐方式（可复核）：trace 自带 `clock_snapshot`，`CLOCK_MONOTONIC` 与 trace 时间轴（BOOTTIME）偏移 **+458 ns / +250 ns**（两个快照），即 `mono_ns ≈ ts`（误差 < 1 µs，对 50 ms 心跳可忽略）。因此 CSV 的 `mono_ns` 可直接与 `sched_slice` / `thread_state` 的 `ts` 比较。

**窗口内分类统计**（把每次心跳的 `[完成时刻−latency, 完成时刻]` 与 p-burst / q-burst / 观察者窗口求交）：

| 分类 | run1 n | run1 p50 | run1 max | run2 n | run2 p50 | run2 max |
|---|---|---|---|---|---|---|
| 与 **p-burst 重叠** | 37 | **2.505 ms** | 12.645 ms | 32 | **2.514 ms** | 22.623 ms |
| 与 **q-burst 重叠** | 36 | **1.086 ms** | 1.212 ms | 33 | **1.089 ms** | 1.204 ms |
| 与 **tracebox(cpu1/2) 重叠** | 14 | 1.201 ms | **13.410 ms** | 0 | — | — |
| 与 p-burst + tracebox 同时重叠 | 2 | 7.797 ms | 12.998 ms | 0 | — | — |
| 都不重叠（基线） | 314 | **1.200 ms** | 1.220 ms | 335 | **1.200 ms** | 1.216 ms |

**全量（同一实例 210.2 s / 4205 次心跳，来自 `heartbeat_latency.run2.csv`）**：

| 指标 | 值 |
|---|---|
| p50 / mean | 1.189 ms / 1.397 ms |
| p90 / p99 | 1.207 ms / 2.617 ms |
| max | **32.602 ms** |
| 分布 | <1.5 ms: 3834（91.2%）；1.5–3 ms: 337（8.0%）；**3–6 ms: 0**；6–10 ms: 1（7.95 ms）；≥10 ms: **33（0.78%）** |
| ≥10 ms 事件幅度 | ≈12.5 ms × 23；22.6 ms × 5；31.56/31.64/32.60 ms × 3；13.0 / 13.41 ms × 2（**均在 run1 窗口内，= 观察者签名**） |
| ≥10 ms 事件间隔 | 中位数 **5.78 s**，均值 6.35 s（对照 p 周期 ≈6 s） |

**分布是"双峰 + 空档"的**：正常态紧贴 1.2 ms，异常态跳到 12.5/22.6/31.6 ms，中间 3–10 ms 几乎为空（仅 1 次 7.95 ms）。这与"整段等待某个 slice 结束"的机制一致，而不是"计算稍微变慢"。

### 5.5 因果链逐条对账（不只靠相关性）

| 事件 | 心跳 latency | `thread_state=R` 等待段 | 之后 Running | 合计 | 差 |
|---|---|---|---|---|---|
| run1 seq=140（rel 3.967 s） | 12.642 ms | 11.469 ms（3.9543→3.9658） | 1.301 ms | 12.770 ms | 0.13 ms（量测边界） |
| run2 seq=4091（rel 15.126 s） | 22.623 ms | 21.468 ms（15.1035→15.1250） | 1.276 ms | 22.744 ms | 0.12 ms |

同一时间点的 sched 轨（run2，cpu1）证明"占用者"就是 `pf-worker-p`：

```
15.0974  pf-worker-p  27.548 ms  → 被切走
15.1250  pf-svc-tick   1.276 ms  ← 心跳实际开始运行（此前已 runnable 21.47 ms）
15.1263  pf-worker-p  28.699 ms
15.1550  pf-svc-tick   1.125 ms
15.1561  pf-worker-p  48.865 ms
15.2050  pf-svc-tick   1.078 ms   ← 之后进入稳定的 50 ms 节拍
```

**"等"而非"算"**：`pf-svc-tick` 自身 on-CPU 时间在峰值期没有变长——

| | 基线（p-burst 外） | p-burst 内 |
|---|---|---|
| svc-tick slice 数 | 365 | 32 |
| 平均 on-CPU / slice | 1.2124 ms | **1.0933 ms** |
| 最大 | 1.475 ms | 1.379 ms |

→ 心跳增加的时间 100% 落在"成为 runnable 之后、真正上 CPU 之前"，心跳自身的工作量没有变重。

### 5.6 观察者效应：实测分离（run1 vs run2）

run1 中 tracebox（pid 1787，tid 1787）在 cpu1/cpu2 上共运行 594 ms，形成 **19.8–21.4 ms 连续块**（约每 1 s 一次）+ **3 ms 块**（约每 200 ms 一次）：

```
8.996 – 9.016  (20.0 ms)   ← 与 svc-tick 11.84 ms 等待、seq=241 (12.998 ms) 完全同窗
12.996 – 13.016 (19.8 ms)  ← seq=321 (12.625 ms)
18.996 – 19.017 (19.8 ms)  ← seq=441 (13.410 ms)
```

run2 把 tracebox 限定到 cpu0/4/5/6/7 后：**cpu1/cpu2 上 tracebox 占用 = 0 ms**，观察者类心跳 = 0 条；剩余 ≥10 ms 事件（12.625、22.623 ms）**全部落在 p-burst 内**。

结论与边界：
- **PASS**：run1 窗口内 5 个 ≥10 ms 事件中 3 个由**采集器自身**造成；该效应量级 12.6–13.4 ms，**与业务异常同量级**，若不分离会直接污染归因。
- **PASS**：把这 3 个事件剔除后，业务侧仍存在 12.6 / 22.6 ms 级事件，且 run2 在观察者缺席时复现同型事件。
- **UNKNOWN**：run1 未开 perf 对照，无法判断这 10–20 ms 块属于 `traced_perf` 还是 ftrace drain（run2 中 tracebox 移到非工作核后，cpu0 上仍出现同类块，提示与 ftrace drain 相关，未证实）。

### 5.7 频率：主动排除，不是原因

- 8 核取值 300–1500 MHz，governor `schedutil`；**cpu1 与 cpu2 在每个时间点取值完全相同**（观测到单一 policy）。
- run1 首个 p-burst 起点前后：`3.83 s = 300 MHz → 4.01 s = 600 → 4.02 s = 1200 → 4.05 s = 1500 MHz`（约 150 ms 爬升），p-burst 主体运行在 1500 MHz。
- 按秒对照（run2，cpu1 平均频率 vs 该秒心跳时延）：

| 秒 | 平均 MHz | 心跳均值 | 该秒最大 |
|---|---|---|---|
| 4 | 559 | 1.186 ms | 1.211 ms |
| 6 | 488 | 1.187 ms | 1.207 ms |
| 7 | 488 | 1.194 ms | 1.211 ms |
| 8 | 488 | 1.198 ms | 1.208 ms |
| **3** | **1033** | **2.363 ms** | **12.625 ms** |
| **9** | **1175** | **1.844 ms** | **2.627 ms** |
| **15** | **950** | **2.967 ms** | **22.623 ms** |

→ **时延变差的秒恰好是高频秒**；低频秒（450–660 MHz）时延平整在 1.2 ms。频率与慢**反相关**，不支持"降频致因"。符合 Skill §3 的口径：频率与慢同窗不构成因果。

### 5.8 采样热点（`linux.perf`，只到叶帧）

| 线程 | 叶帧（已符号化） | 样本数 | 占比 |
|---|---|---|---|
| `pf-worker-p` | `pfp::p_kernel_hot(unsigned long, long)`（mangled `_ZN3pfp12p_kernel_hotEml`） | 158 | 53.7% |
| `pf-worker-q` | `pfq::q_kernel_hot(unsigned long, long)`（`_ZN3pfq12q_kernel_hotEml`） | 136 | 46.3% |

- 目标进程 294/300 个样本 **100% 落在两个 worker 的热叶子函数**里；`pf-svc-tick` 一个样本都没有（它太轻，100 Hz 采样抓不到）——这本身也说明**不能用"采样热点"去找心跳线程**。
- **`stack_profile_callsite` 最大深度 = 1**：本次 trace 只有叶帧，没有 `p_submit_batch > p_parse_batch > … > p_kernel_hot` 的祖先链。因此"函数级调用链归因"= **UNKNOWN**，不能用叶帧样本数当函数 CPU 毫秒数。
- 符号质量：mapping build_id = `5216590986a25ab51f5c924c25db8dee675320b7`，与 `RUN_INFO.md` 声明的 Build ID **一致**；两个符号成功反解 → 符号化 PASS（仅限这两个叶帧）。`kernel_frames: true` 已请求，但栈内**没有内核帧**（run2 仅 1 条 `hrtimer_nanosleep`）→ 内核帧 UNKNOWN。

### 5.9 明确排除项

| 假设 | 判定 | 依据 |
|---|---|---|
| `pf-worker-q` 的更大 CPU 峰值导致心跳变慢 | **FAIL（不支持）** | q 峰期心跳 p50 = 1.086/1.089 ms，**低于**基线 1.200 ms；q 在 cpu2，心跳在 cpu1 |
| CPU 降频导致异常 | **FAIL（不支持）** | 见 §5.7，反相关 |
| 心跳线程自身计算变重 | **FAIL（不支持）** | 峰值期 on-CPU/slice 1.093 ms < 基线 1.212 ms |
| 内存/IO 阻塞 | **FAIL（不支持）** | svc-tick 的 `D` 状态仅 0.092 ms；心跳慢段全部是 `R`，不是 `D` |
| 观察者（tracebox）是唯一原因 | **FAIL（部分）** | run1 有 3/5 由观察者造成；run2 移除观察者后仍有 12.6/22.6 ms |

---

## 6. 证据边界（UNKNOWN 清单，逐条）

1. **`PUBLIC_BRIEF.md` 缺失** → 部署信息改由 `RUN_INFO.md` + `README.md` 提供，已在 §1.1 逐项披露。若 brief 另有不同内容（例如不同的路径/端口/负载参数），本报告的运行上下文需按 brief 复核。
2. **官方 schema 级 PASS**：无板端 collector 的 `trace_config.desc`，`[UNKNOWN]`。
3. **函数级调用链祖先**：`max depth = 1`，无法从本次 trace 得到 `p_submit_batch` 等上层函数；`kernel_frames: true` 亦未产出内核帧。
4. **窗口外的归因**：两次 trace 各只覆盖 ~20 s；210 s 全量统计里 31/33 个 ≥10 ms 事件发生在 trace 窗口之外，**只由 CSV 周期（中位 5.78 s）与 p 周期一致推断**，属于"强相关但未逐事件证明"。
5. **12.5 / 22.6 / 31.6 ms 的量级量化**：三次观测到的等待量级相差约 10 ms 步进。**假设**与调度 tick/wakeup 抢占粒度有关，本次**没有**采集 `sched:sched_wakeup` 细节或 `/proc/config.gz` 的 `CONFIG_HZ` 来证实 → UNKNOWN。
6. **观察者块的具体来源**（`traced_perf` 采样 vs ftrace drain）：未做无 perf 对照 → UNKNOWN。
7. **UI**：本会话无图形界面，未打开 Perfetto UI，未生成截图 → `UI_UNKNOWN`（步骤见 §9）。
8. **其他系统线程**（`ntpd` 9.1 ms、`ptp4l` 4.2 ms、`sugov:0` 11.1 ms 等）未纳入归因；它们总量远小于工作负载，且未出现在 cpu1 的长段占用里，但不能声称"绝对无影响"。
9. **程序内部语义**（各函数的实际工作量、deadline 如何设定）只能从公共字段推断，未读源码 → 报告中凡涉及"设计意图"的表述均标注为"公共描述"而非实测。

---

## 7. 复现清单（文件 → 用途）

目录：`/root/sdk_ly_x5_1.1.1/tmp/perf-cpu-firstpass/`

| 文件 | 用途 |
|---|---|
| `captures/cpu_firstpass.pftrace` | run1 真实 trace（1 613 046 B） |
| `captures/cpu_firstpass2.pftrace` | run2 真实 trace（观察者已移出工作核） |
| `captures/cpu_firstpass.status` / `…2.status` | `DONE size_bytes=…` |
| `captures/cpu_firstpass.log` / `…2.log` | 采集起止时间 |
| `captures/heartbeat_latency.public.csv` | run1 时刻的公共业务时延（477 次） |
| `captures/heartbeat_latency.run2.csv` | 同实例全量公共业务时延（4205 次 / 210.2 s） |
| `captures/survey.txt`, `available_events.txt` | 只读探测与 1768 行事件清单 |
| `captures/board_probe.txt`, `board_probe2.txt`, `tracebox_probe.txt` | tracebox 版本/既有 tracing 会话/CPU 拓扑/perf 支持 |
| `captures/post_capture_state.txt`, `post_capture2_state.txt` | 采集后程序状态、线程亲和性、频率、loadavg |
| `cfg/cpu_firstpass.pbtxt`, `cfg/base_freq.pbtxt`, `cfg/validate.out` | 实际配置与静态校验输出 |
| `captures/board_capture.sh`, `board_capture2.sh` | 板端采集驱动（可原样重跑） |
| `analyze.py` | 全部分析数字的生成脚本（PerfettoSQL + 对齐 + 分类） |
| `sqlout/run1/*`, `sqlout/run2/*` | 原始 SQL 与原始输出（`*.csv`）、TP 日志（`*.stderr`）、改参后的 SQL（`*-run.sql`） |
| `sqlout/run{1,2}/analysis.json` | 结构化结果（本报告数字的直接来源） |

关键文件 SHA256（完整清单见 §10）：

```
21db72ff32c89b3301e197eacc7cd872667671b08f12e678d2e210bf5ac4ee0c  captures/cpu_firstpass.pftrace
4fafebeaa2fc97d3fbb7d479284fca3aeb6169db07ade7b57dbff5b75122c363  captures/cpu_firstpass2.pftrace
5933a7a3c8bc8d937eb32cc5fc5757bbea43b8d7ad5ce6a8aaf8784e7c4bb6e8  captures/heartbeat_latency.public.csv
2740045e7deaf2e7845cdc7e25b70692f1b935f3903bcf960932c0dade191a27  captures/heartbeat_latency.run2.csv
144908e4734c0058ceb79799e0d2c21052ab6463339ecd738c5fc0aa5d691471  cfg/cpu_firstpass.pbtxt
40adeb975459b638c4c94f06cca6466bb942304c98ab6aaec227eab8dac667c1  analyze.py
```

---

## 8. Skill 版本与哈希

| 项 | 值 |
|---|---|
| Skill 名 | `perfetto-cpu-debugging` |
| 版本 | `0.1.0`，`status = candidate`（MANIFEST.json） |
| 目录 | `/root/.dsh/skills/perfetto-cpu-debugging`（38 个文件） |
| MANIFEST 自校验 | **全部 37 项文件哈希与 MANIFEST 一致，0 mismatch** |
| 树哈希 A（`sha256sum \| sha256sum`） | `85e518409ee47f20ad012b1a1d0b05558fdd19dd2a6b56deeedaaf55c7ae073c` |
| 树哈希 B（38 个文件哈希按路径排序后拼接再 sha256，MANIFEST 口径） | `eb062c4969f7c2a8e3b5ffd195ff92badb64dfb75e89177289500f97f439739b` |
| 本报告使用的 Skill 脚本 | `make_config.py` `df04401a…`；`validate_config.py` `f671c239…`；`survey.sh` `7275e899…`；`linux_trace_session.sh` `e5d959ad…`；`linux_session_lib.sh` `09e32bb4…`；`sql/*`（8 个，哈希见 MANIFEST） |
| 目标程序 | `pf-cpu-case` v1.0.0，SHA256 `70bb82caec3bc3224f4303cc6ddeb5565123b2d9c4aa3dcd34f2ec71a9332c66`（RUN_INFO 声明），Build ID sha1 `5216590986a25ab51f5c924c25db8dee675320b7`（trace 内 mapping 实测一致） |
| 采集器 | tracebox Perfetto `v57.1-c59f57dd4`，md5 `fe131c3ac583ffc70936bc2cbfcd5a8e` |
| 分析器 | `trace_processor_shell` `v57.1-c59f57dd4`（RPC v14） |

---

## 9. UI 复现步骤（可复核；本会话未执行 → `UI_UNKNOWN`）

打开 <https://ui.perfetto.dev/>，加载 `captures/cpu_firstpass.pftrace`（或直接拖入），然后：

1. **定位进程**：左侧 `Current Trace` 搜索框输入 `pf-cpu-case`；展开进程后应看到 4 条线程轨：`pf-cpu-case`、`pf-svc-tick`、`pf-worker-p`、`pf-worker-q`（TID 1762/1764/1765/1766）。
2. **核轨**：展开 `CPU 0…7` 的 `Scheduler` 子轨。在 t≈3.9–4.5 s 应看到 **cpu1 完全被 `pf-worker-p` 填满**，t≈8.1–8.8 s 应看到 **cpu2 被 `pf-worker-q` 填满**。
3. **Runnable 等待**：选中 `pf-svc-tick` 线程轨，只勾选 `Thread State` 的 `Runnable` 图例；在 t≈3.954 s 处可见一段约 11.5 ms 的等待段，紧贴 `pf-worker-p` 的 slice 边界。
4. **CPU 时间桶**：`Query (SQL)` 面板粘贴 `sqlout/run1/05-run.sql` 全文运行 → 结果面板右上 `⋮` → **Add debug track → Counter**：Timestamp=`ts`，Value=`cpu_ms`，Pivot=`utid`。应得到 §5.1 的阶梯形曲线（≈5 ms 基线，峰值 195–200 ms）。
5. **尖峰 episode**：同法跑 `sqlout/run1/06-run.sql` → **Add debug track → Slice**：ts/dur（单位 ns，name 可用 SQL 里追加的常量）。
6. **频率/Idle**：勾选 `CPU Frequency`、`CPU Idle` 轨，确认 §5.7（300→1500 MHz 台阶、低频秒时延不变）。
7. **Perf 热点**：选中进程后在 `Perf Samples` 区域打开 **Flamegraph**，应只看到 `pfp::p_kernel_hot` / `pfq::q_kernel_hot` 两个叶帧（**深度 1**，无祖先），与 §5.8 一致。
8. **业务时延对齐**：`mono_ns ≈ ts + 0.5 µs`（据 `clock_snapshot`），可直接把 CSV 中 `mono_ns` 当作 trace 时间轴定位事件，无需转换。
9. 如需复核 run2：加载 `captures/cpu_firstpass2.pftrace`，重复 1–3、6–7；观察 `CPU 0/4/5/6/7` 上出现 tracebox 轨，而 **cpu1/cpu2 上没有 tracebox**。

---

## 10. 完整文件哈希（本目录内）

```
40adeb975459b638c4c94f06cca6466bb942304c98ab6aaec227eab8dac667c1  analyze.py
1e359622c19f55ebee993a37b95f4f659d8e018ef0c1fd9e5bc0173edeb3e879  captures/available_events.txt
7bf8caf0082abd4acd0d4a40207b145296c3f1b28ce3e187f2fe2a58ede57be5  captures/board_capture.sh
34f6819506c6dc91c00b79f099811bf4b936f9e33b142f03c9086cf61e7f3646  captures/board_capture2.sh
82320cc92cbb0a9bda98f949639608ebbe596fe8fc8801fed954f7ea644189e8  captures/board_probe.txt
b8973fa75fdb8a1426d92da333918c33b40b8a3fa60d9cf6eee89e13254ff30d  captures/board_probe2.txt
9fa8419c7836eea023d2ab6f7db20cd59eee87f064647c6d6b82a7587e33d969  captures/capture_run1.log
7ae798077569d5b3c41c2bcafb909d03668b9584d16849fd67058b14efda8555  captures/capture_run2.log
c7ebfdd1cc1abac501f70963b4a8a88ef51c894dc672960f9c589661e2647fca  captures/cpu_firstpass.log
21db72ff32c89b3301e197eacc7cd872667671b08f12e678d2e210bf5ac4ee0c  captures/cpu_firstpass.pftrace
3eeb1df0b2fae4046441989dad68b23bd07a40dd0e44fee3bba7ac03dbc89641  captures/cpu_firstpass2.log
4fafebeaa2fc97d3fbb7d479284fca3aeb6169db07ade7b57dbff5b75122c363  captures/cpu_firstpass2.pftrace
5933a7a3c8bc8d937eb32cc5fc5757bbea43b8d7ad5ce6a8aaf8784e7c4bb6e8  captures/heartbeat_latency.public.csv
2740045e7deaf2e7845cdc7e25b70692f1b935f3903bcf960932c0dade191a27  captures/heartbeat_latency.run2.csv
baa55e30de24ac56c9ec42b3802f6001416ca9544d19e4b8d682242013103459  captures/post_capture2_state.txt
94f8ba44c03f687d2da687fadb3a602a215ad136c4b5d347a7465d7f95560384  captures/post_capture_state.txt
fb793443cf32ea52de95f224561261e26f5d0dc73d4a85414be482c9ba60fbfe  captures/survey.txt
81f0b969f483397d119e0d6ac65233a5f1d124245870764bc651df6431402951  captures/tracebox_probe.txt
2bbd0ff0e7b0424c840946214a2bb80e6dbec18223def0e378eea9f0c3298bff  cfg/base_freq.pbtxt
144908e4734c0058ceb79799e0d2c21052ab6463339ecd738c5fc0aa5d691471  cfg/cpu_firstpass.pbtxt
228927dc52722b542b9c78f22473b3933f40e8408da7ac615a1000d4e476d88d  run_sql.sh
d4c59653badaee2ca2d9572fa7bb85e7b3e7b07d15ba7cbf592e0d6af60e5b78  run_sqlf.sh
1e6ed581c49963b32c3a26b0c664452ffb88d8d52acf06dd746de34a36101092  sqlout/02-run.sql
2632966554daa6ddebfa85ced3705cd59ca0a6634230840e0269c6a9b28de85c  sqlout/03-run.sql
2d2cf1f7694ea855e2ea7f44d20829e7b2fc5a0facb1802fe0d18cbebee49495  sqlout/05-run.sql
2421f6a22d15bd3f6035f1e1f34d87cd44d9979a5cd3cb65facd5708ff0dfb81  sqlout/06-run.sql
286be48f4fd7f7c3133082d495fecd6c76731a463e29b7b5defb5c665e32378b  sqlout/run1/02-thread-states.csv
c3ea4dd4c737eb853d67c877de455249633e322c4605c58b7bfe5615d1b42190  sqlout/run1/03-runnable-latency.csv
c7939ecf1881b71c60351221eb80f039b711baac6291a6d884763e16245e1727  sqlout/run1/05-buckets200ms.csv
d9096f23b4fb7ddc828f5fa21bdc2de8f57bd42a783f08d1b2c228e9af888153  sqlout/run1/06-spike-episodes.csv
f6311eefbd8ad1bf494d02a25b6cc3a986c70055f49b92fc8d94b39013a93a7e  sqlout/run1/08-core-busy.csv
58ed93ef3907828a843fc2311cc53a018b1f315b5f9fcbd8ae513b3e981f23aa  sqlout/run1/analysis.json
e0cec3b508ea336bed68207cda588cb60187e60fc86ad2b7731fa3a0c39b6250  sqlout/run1/bursts_p.csv
b9dd8b4aa1ec36a6f90a3a07955744389b2828f7446044d395df71c2f22c0a0f  sqlout/run1/bursts_q.csv
1df7b9aa647ad64db1f0be96be8cd325b0bee34b666257b45f571c74636b4fcc  sqlout/run1/cpu1_18s.csv
5df9511f5fda172145ba0646f8d75c5f29aa2a083ffa169541833262d9097b61  sqlout/run1/cpu1_3954.csv
7baa60cc3245b20c8b2794437dceb40ce690b4e16b7c270f87bbcc7351965e84  sqlout/run1/cpu1_all.csv
e58f7661fc099b98f37fad1432cdb4b1b415a3b4f6affe9f6694b4a6d082e4ba  sqlout/run1/cpu1_around_13s.csv
044df9d5fba54c64941c367bf19a77aa88ea4d3079942f616c8d8b6b58391a84  sqlout/run1/cpu1_around_9s.csv
d7131caab297a8fc58c840e4a65128234df5a9356ba2f8cefce15156c2efbee4  sqlout/run1/cpu1_tracebox.csv
366d7d2fbca0ae2e72b97148d59de48b5ab3267ae0a3e551d36df69494fe1565  sqlout/run1/cpu1_tracebox_tid.csv
3ce42a738daf4fcd86659e6cd0ae9a1a9235efe4625140ca70a9189bca297643  sqlout/run1/cpu2_all.csv
d934290ee004981bdf4e5611825682a42864401a98e479f63ec89f1888cfb61b  sqlout/run1/svctick_longR.csv
18d5dbbb58ee366beede65eec5b92de7984c5927aa6f2e36dcdfe022cc7a29a9  sqlout/run1/tracebox_threads.csv
6744c45cd902ff71695c2144c43052adb45a1e698848b5455a6cedbb1e0d9aba  sqlout/run2/02-run.sql
7421c6ca58fe37f23cc741d469c58b7d79805c07a0bbe5956c074e15e1e1dc17  sqlout/run2/03-run.sql
c90f92d9d49a39d4012f5c4d167ba5eb8479d2073a1fba54c59c70339a85d215  sqlout/run2/05-run.sql
f403380bf651b851cf1cb35c986d2481cc4feced617ba1476a3a5888b826f036  sqlout/run2/06-run.sql
666af228cb429b2b8aeea3bbd5f94b452d139ba3793ed77bc4f1eed471bc3f9f  sqlout/run2/08-core-busy.csv
91413a273ca202263124b19fbed5e757fecd849df56c7a5bf4f997030898ec34  sqlout/run2/08-run.sql
a963d3c3d2d6d920106b22b6cffe1ca0f8fcae6f1c45e0f38a65960e74abe4ff  sqlout/run2/analysis.json
2239d4e0e75a9b1c24c3a137c4642fad438e12a964bf0bed64171becf7b0cd14  sqlout/run2/freq_per_sec.csv
5365cc96391a7a6236cf2ad0fb7b14b750b8ba379cc13c9178041fd1556099f8  sqlout/run2/skill02.csv
9cb0fe2bc1e85d369ac44523be507c33cec0616c87bb28767c969aeb375f8edf  sqlout/run2/skill03.csv
181a8e59a5f737dad557859b2f76b24cbf7779e266356f821fcdd23c014246bc  sqlout/run2/skill05.csv
923496926f46f4695586c43f80c1dfe5cf3f1c6efe846fa83143f9d8e80715c9  sqlout/run2/skill06.csv
```

板端留存（未删除，便于复核）：`/userdata/perfetto-cpu-session/` 下同名 `.pftrace`/配置/脚本/CSV 快照；采集结束后 `pf-cpu-case`（pid 1762）**仍在运行**，未被人为关闭。

---

## 11. 最小下一步（若允许继续）

1. 若需函数级调用链：换用带完整栈的采集方式（提高 `linux.perf` 的 `callstack_sampling` 深度支持/改用 `perf record -g --call-graph fp` 后导入），本次 `depth=1` 无法补。
2. 若需确认观察者块来源：一次 `--no-perf`（仅 sched+freq）同窗采集即可判定；本次未做。
3. 若需窗口外逐事件归因：把采集窗口拉长到 ≥ 一个完整 p 周期倍数（如 60 s），或改为周期性多段短采集。
4. 以上均**不影响**本报告主结论（同核 CPU 竞争 → runnable 等待 → 心跳尾部时延），只影响归因颗粒度。
