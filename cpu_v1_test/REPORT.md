# RDK X5 CPU 性能诊断 — 真实上板测试报告

> Skill：`perfetto-cpu-debugging` v0.1.0（本机安装版）
> 测试时间：2026-10-18（板卡 RTC 未校准，板上时间显示为 uptime/1970，所有分析基于单调时钟纳秒时间轴）
> 结论性质：**单次受控采集**，一次采集已回答全部三问，未做补采与扩展实验。

## 1. 环境与前置（只读探测）

| 项 | 实测值 |
|---|---|
| 板卡 | `buildroot` 6.1.83-DR-PL5.1_V1.0.20，aarch64，8 逻辑核 |
| tracefs | `/sys/kernel/debug/tracing`，`tracing_on=0`，`current_tracer=nop`（采集前未被占用） |
| 可用事件 | `sched:sched_switch` / `sched_waking` / `sched_wakeup_new`、`power:cpu_frequency`、`power:cpu_idle` 均在 |
| perf 权限 | `perf_event_paranoid=2`、`kptr_restrict=0`（本轮未使用 `linux.perf`） |
| 频率快照 | 采集前 sysfs `cpu0..7 = 1200000 kHz`（**时点读取，不是 trace 数据**） |
| 写入位置 | `/userdata/cpu-diag-1018-013326/`（ext4，采集时 26 G 可用；rootfs 只读未动） |
| tracebox | v57.1-c59f57dd4（aarch64，官方构建） |
| Trace Processor | v57.1-c59f57dd4（与采集器同版本） |

**未做**：未改 sysctl/governor/mount，未重启或干扰任何业务进程，未清 tracefs、未 pkill 其他进程。

## 2. 测试程序（交叉编译，静态链接）

源码：[cpu_spike_fixture.cpp](cpu_spike_fixture.cpp)（同目录），`aarch64-none-linux-gnu-g++ 11.3`（与板端内核构建工具链一致）：

```
- spike-worker : 先睡，再满负荷烧 300 ms CPU，周期 3000 ms
- bg-light     : 每 100 ms 烧 3 ms（≈3% 单核），用于验证能否区分"尖峰线程"与"背景线程"
- main         : 只睡，不占 CPU
总时长 30000 ms；每个 tick 起止都打印 CLOCK_MONOTONIC ns，用于与 trace 时间轴对齐
```

```sh
/opt/arm-gnu-toolchain-11.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-g++ \
  -O2 -std=c++17 -static -pthread -o cpu_spike_fixture cpu_spike_fixture.cpp
```

## 3. 采集命令（完整可复现）

```sh
# 【板端，只读】探测
sh survey.sh ; sh survey.sh --events > board_events.txt

# 【主机】路由=scheduling（问题只问"哪个线程/何时/多久/多少 CPU"，sched_switch 已足够；不启 perf/频率）
python3 scripts/make_config.py scheduling --events board_events.txt --duration-ms 20000 > cpu.pbtxt
python3 scripts/validate_config.py cpu.pbtxt      # [PASS] 结构；官方 schema UNKNOWN（无匹配 descriptor）

# 【板端】同一窗口内：先起负载，再采 20 s
./cpu_spike_fixture 30000 3000 300 > fixture.log 2>&1 &
sleep 1
WORK=/userdata/cpu-diag-1018-013326 TRACEBOX=/userdata/cpu-diag-1018-013326/tracebox-arm64 \
  sh linux_trace_session.sh cpu.pbtxt cpu 30
# -> DONE size_bytes=102853

# 【主机】拉回后分析
trace_processor_shell query -f sql/04-spike-episodes.sql cpu.pftrace
```

## 4. 验收（四级，逐项）

| 级别 | 结果 | 依据 |
|---|---|---|
| Schema | **UNKNOWN** | 无与板端采集器版本匹配的 `trace_config.desc`，仅结构预检 PASS |
| Runtime | **PASS** | 事件实际存在；tracebox 正常启动/停止；`cpu.status=DONE size_bytes=102853`；无 `TIMEOUT_STOPPED` |
| Data | **PASS** | `trace_bounds` 19.683 s；目标 UPID=185；`sched_slice` 有数据；`stats` 468 行、严重级异常 0（无 data loss） |
| Analysis | **PASS（限于调度层）** | SQL 区间交集/裁剪、单位、线程归属、时间轴对齐均交叉校验（见 §5.5） |
| 频率 / 函数级热点 | **UNKNOWN** | 本轮未采 `power/cpu_frequency`、未采 `linux.perf`；不得据此断言降频或函数热点 |

## 5. 证据

### 5.1 谁在烧 CPU（Q1）

| utid | tid | 线程 | sched_slice 段数 | CPU 时间 | 落在哪个核 |
|---|---|---|---|---|---|
| 206 | 12044 | **spike-worker** | 8 | **2101.4 ms** | CPU1（全部） |
| 207 | 12045 | bg-light | 191 | 583.3 ms | CPU7（全部） |
| 185 | 12042 | main（`[NULL]` comm） | 0 | 0 ms | — |

主线程 0 段、背景线程只占 3%：周期性尖峰**全部来自 `spike-worker`（tid 12044）**，不是主线程、不是背景线程、也不是系统噪声。

### 5.2 尖峰时间/时长/占用（Q2）

`sql/04-spike-episodes.sql`（按 >1 s 静默切分该线程的 on-CPU 区间）：

| # | 相对 trace 起点 | span | CPU 时间 | 单核占用 | 核 |
|---|---|---|---|---|---|
| 0 | +1.329 s | 300.2 ms | 300.2 ms | 100% | CPU1 |
| 1 | +4.329 s | 300.2 ms | 300.2 ms | 100% | CPU1 |
| 2 | +7.329 s | 300.2 ms | 300.2 ms | 100% | CPU1 |
| 3 | +10.329 s | 300.2 ms | 300.2 ms | 100% | CPU1 |
| 4 | +13.329 s | 300.2 ms | 300.2 ms | 100% | CPU1 |
| 5 | +16.329 s | 300.2 ms | 300.2 ms | 100% | CPU1 |
| 6 | +19.329 s（trace 末尾，完整覆盖至 +19.630 s） | 300.2 ms | 300.2 ms | 100% | CPU1 |

- 周期：相邻起点间隔 **3000.0 / 3000.0 / 3000.0 / 3000.0 / 3000.0 / 3000.0 ms**（trace 自身数据，不依赖测试程序自述）。
- 尖峰形态（50 ms 桶，`sql/10-buckets-50ms.sql`）：起跳后连续 6 个桶各 50.00 ms，`spike-worker` 独占该核 ≈300 ms，期间 `bg-light` 只占 3 ms/100 ms。
- 分母要说清：尖峰内是 **1 个逻辑核的 100%**；摊到 19.683 s 采集窗口是 **2101.4/19683 = 10.7% 单核**；摊到 8 核是 **1.3% SoC**。
- 每核 busy（`sql/11-core-busy.sql`）：CPU1 **2105.6 ms / 10.70%**（≈worker 2101.4），CPU7 **586.2 ms / 2.98%**（≈light 583.3），其余核 ≤0.26%。

### 5.3 能否解释原因（Q3）

`sql/06-thread-states.sql`、`sql/07-runnable-latency.sql`：

| 线程 | Running | R (Runnable 等 CPU) | S (睡) | 最长 Runnable 等待 |
|---|---|---|---|---|
| spike-worker | 2101.4 ms | **0.6 ms / 8 段** | 16198.3 ms | **0.084 ms** |
| bg-light | 583.3 ms | 7.1 ms / 192 段 | 19008.9 ms | 0.050 ms |

- 每次尖峰前，线程是 **S（睡）→ 被唤醒 → R 约 76–84 µs → Running 300.2 ms**；waker 归属：`swapper`(utid 0，空闲/定时器上下文) 7 次，另 1 次为尖峰内部抢占（waker 为空）。
- 调度数据能证明的是：尖峰期间该线程**连续 on-CPU 计算 300 ms**；进入运行态前的 Runnable 等待仅 76–84 µs；窗口内没有 `D`（不可中断睡眠）状态，也没有超过 84 µs 的运行排队。因此可以排除「CPU 被别的任务抢走」和「调度器排队造成延迟」这两类原因。
- 但调度数据**不能独立排除所有锁/同步问题**：mutex/futex 争用通常体现为 `S` 而不是 `R`，且 `thread_state` 不记录「阻塞在哪把锁」（本 trace 的 `blocked_function` 为空）；线程在持锁状态下自旋或做 300 ms 计算，在 sched 视图里同样是 `Running`。要判定锁等待需要 futex/lock ftrace 事件、业务打点或 `linux.perf` 采样，本 trace 均未采集，故「是否存在锁等待」属于 **UNKNOWN**，不是「已排除」。
- 结合测试程序源码（`cpu_spike_fixture.cpp`）可以进一步约束：尖峰线程的忙循环只做整数 LCG 迭代 + `std::chrono::steady_clock` 读时间判退出，**不取锁、不 sleep、不做 I/O 或堆分配**；结果只通过 relaxed `std::atomic::fetch_add` 汇总。这与 trace 里「无 D 状态、无长 Runnable、连续 Running 300 ms」一致，说明本轮的尖峰是**周期性 CPU 密集计算**，而不是阻塞或锁自旋。
- 「周期性计算负载」本身如何被验证（不是只信代码注释）：
  1. 程序按 `t0 + (idx+1)*period_ms` 计算下一 tick 的绝对时间并 `sleep` 到点，每个 tick 打印起止 `CLOCK_MONOTONIC` 时间戳；
  2. 程序自报 10 个 tick 的燃烧时长 `dur_ms` 为 **300.081–300.120 ms**；
  3. trace 中 7 个 episode 的 span 全为 **300.2 ms**、相邻间隔全为 **3000.0 ms**；
  4. 两者时间轴对齐（见下一条），因此「每 3 s 一次、每次约 300 ms 的计算」在被观测窗口内确实发生了。
- 与测试程序对齐（`logs/fixture.log` 与 §5.5）：trace 起跳点比程序自己打印的 `tick_start` **早 20.8–35.2 µs**，正好是「被调度上 CPU → printf 落盘」的开销，两者同一时基。该差值可由归档文件独立复算：`python3 logs/check_alignment.py`，输出存档在 `logs/alignment_check.txt`（只读 `logs/fixture.log` + `sql_out/04-spike-episodes.txt`，不重新采集、不补造数据）。
- 采集开销自曝：本会话 `tracebox-arm64` 自身 366.5 ms（1.9% 单核），未污染结论。

### 5.4 反例保护（本轮特意加入 `bg-light`）

若只看到"进程周期性占 CPU"就下结论，会误判为整个进程尖峰；本次 `bg-light` 稳定 3% 且恒定在 CPU7，`spike-worker` 独占 CPU1，说明**按 utid 归属 + 每核 busy 交叉核对**能区分"真尖峰线程"和"背景常驻负载"。

### 5.5 表观一致性校验

| 校验 | 结果 |
|---|---|
| trace 时间轴 vs 程序 CLOCK_MONOTONIC | 7 个 tick 偏差 −20.8…−35.2 µs（应为负，printf 在调度之后）；复算脚本 `logs/check_alignment.py`，输出 `logs/alignment_check.txt` |
| 程序自报 tick 周期 vs trace episode 间隔 | 3000.0 ms vs 3000.0 ms |
| 程序自报 300 ms 燃烧 vs trace 区间 | 300.084–300.120 ms vs 300.2 ms（+0.1 ms 为调度/统计粒度） |
| 进程总 CPU vs 线程求和 | 2101.4 + 583.3 = 2684.7 ms，与 §5.2 各核 busy 一致 |

### 5.6 证据可复核性（本轮修复补充）

| 报告中的数字 | 由哪个归档文件复算 |
|---|---|
| 每线程 CPU 时间、时长、核 | `sql_out/01-thread-cpu.txt`、`sql_out/04-spike-episodes.txt`（原始 TP 输出，未改动） |
| 线程状态 Running/R/S 与最长 Runnable 等待 | `sql_out/02-thread-states.txt`、`sql_out/03-runnable-latency.txt` |
| 每核 busy 比例 | `sql_out/06-core-busy.txt` |
| 无 data loss | `sql_out/09-quality.txt`（value>0 的 error/data_loss 为 0） |
| tick 自报时长 300.081–300.120 ms | `logs/fixture.log`（10 个 tick 的 `tick_end` 行） |
| trace 与程序时间轴偏差 20.8–35.2 µs | `python3 logs/check_alignment.py` → `logs/alignment_check.txt` |
| 采集是否正常结束 | `logs/cpu.status` = `DONE size_bytes=102853` |

未改动历史 `cpu.pftrace` 与 `sql_out/*` 原始输出；`logs/check_alignment.py`、`logs/alignment_check.txt` 为 r1 依据归档文件新增的**派生物**，不含新采集。

## 6. 结论

1. **尖峰线程**：`spike-worker`（pid 12042 / tid 12044，utid 206）。
2. **尖峰特征**：每 3000 ms 一次，每次连续 ~300.2 ms 满占 **1 个逻辑核（CPU1，100%）**；采集窗口内 7 次，累计 2101.4 ms（窗口内 10.7% 单核、1.3% SoC）。
3. **原因**：Perfetto 调度数据足以解释到「线程自身连续 on-CPU 计算 300 ms，进运行态前只等 ~80 µs，因此不是调度排队或 CPU 被抢占」。但**不能据此宣称已排除锁/同步问题**（sched 数据看不到锁，见 §5.3），也无法给出函数级归因或频率结论——前者要 `linux.perf` 采样，后者要 `power/cpu_frequency` + `sys_stats`；按最小证据原则本轮未扩大采集，这两项均为 **UNKNOWN**。

## 7. 局限与最小下一步

- 只采 20 s（覆盖 7/10 个 tick），未覆盖程序启动/退出阶段。
- 无 `linux.perf`（`perf_event_paranoid=2`，未验证 producer/符号）：热点函数 **UNKNOWN**。
- 无频率 counter：采集窗口内频率是否变化 **UNKNOWN**（只有采集前 sysfs 的 1.2 GHz 时点快照，不能当 trace 证据）。
- 若下一步要函数级归因：单次短 smoke = `make_config.py profiling --target cpu_spike_fixture --frequency-hz 100`，先确认 `perf_event_open` 权限与 `perf_sample` 是否有数据；失败就停在 UNKNOWN，不改 sysctl。
- 板端残留（本会话自建，未删）：`/userdata/cpu-diag-1018-013326/`（含 trace、日志、fixture、tracebox，约 8 MB）。


## 8. 本次暴露的 skill 使用问题（建议回流到 skill）

1. skill 的 `<skill>/sql/00-inventory.sql` 是多条 SELECT，直接 `trace_processor_shell query -f <skill>/sql/00-inventory.sql <trace>` 在 v57.1 会报
   `Result rows were returned for multiples queries`，只输出最后一条。skill 应拆成单条文件或说明用
   `suppress_query_output()` / 逐条执行，否则第一次上板就容易误以为"SQL 没结果"。
2. 本 TP 构建（v57.1）**没有** `sched_waking` 表：raw 里 `sched_waking` 事件 1222 条，但只能通过 `thread_state`
   的 R 区间 + `waker_utid` 读唤醒关系。文档若给 `sched_waking` 直查示例会踩空。
3. `scripts/make_config.py frequency` 与 `overview` 默认输出**逐字节相同**（两者都无条件加 sched + power 事件），
   路由表承诺的"更轻频率采集"不成立；建议 frequency 默认 `--no-sched`，或让 frequency 只采 power/sys_stats。
4. 采 `scheduling` 路由时 `cpu_counter_track` 为空，这是设计使然；建议在 skill 的 `<skill>/sql/04-cpu-frequency.sql` 头部加一句
   "先确认 `cpu_counter_track` 有 name，否则频率问题直接 UNKNOWN"，避免有人把空表当"频率为 0"。

## 9. 产物清单

| 文件 | 说明 |
|---|---|
| `cpu.pftrace` | 真实 trace，102853 B，v57.1 |
| `logs/cpu.status` | `DONE size_bytes=102853` |
| `logs/fixture.log` | 负载自报 tick 时间戳（10 个 tick） |
| `cpu_spike_fixture.cpp` | 测试程序源码（静态 aarch64 二进制在板端） |
| `sql/*.sql` | 本次使用的分析 SQL（含 skill 原 SQL 的适配说明） |
| `sql_out/` | 全部 SQL 原始输出 |
| `config/cpu.pbtxt` / `config/board_events.txt` | 实际采集配置与板端事件清单 |
