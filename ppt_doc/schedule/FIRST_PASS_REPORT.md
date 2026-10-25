# FIRST_PASS_REPORT — pf-sched-case / periodic-A 单次独立诊断

- 窗口：B｜Scheduling（单次独立诊断，V4）
- 日期：2026-10-25
- 使用 Skill：`perfetto-scheduling-debugging` v0.1.0（candidate）；`SKILL.md` SHA256 `71d5dd66…bcec`
- 允许观察面：`perfetto_skill_lab/scheduling/PUBLIC_BRIEF.md`、公共周期时延 CSV、本次真实 Trace、`/proc` 运行事实
- 未使用：源码、`PRIVATE_GROUND_TRUTH.md`、A 的测试设计/自测日志、反编译；未停止/重启/改优先级/改亲和/改 governor/kexec/刷机

---

## 0. 结论先行（TL;DR）

`periodic-A` 在本次观测中对应 `pf-sched-case` 的 **`pf-t0`（TID 4705，nice=17，CPU 亲和性仅 CPU5）**。公共 CSV 与 Trace 的 1397/1398 个周期起点落在该线程的 Running 区间内，残差 3.3–25.5 µs，身份匹配成立。

迟到不是睡眠等待、也不是唤醒延迟，而是 **CPU 调度导致的 Runnable（可运行）饥饿**：

- 每个迟到周期，`pf-t0` 在计划时刻后 **52–55 µs** 就被 hrtimer 唤醒进入 Runnable（唤醒准时）；
- 随后 p50 **36.5 ms**（均值 36.3 ms，最大 46.5 ms；定向 trace 中另见一例 56.5 ms，未与 CSV 行配对）处于 Runnable，等 CPU5；
- 迟到周期中 **99.85%** 的 latency 由这段 Runnable 等待构成；
- 这些 Runnable 等待时间里，**CPU5 100.0% 正在执行同进程的 `pf-t1`（TID 4706，nice=0，同样仅 CPU5）**；
- `pf-t1` 以 **415–477 ms 的 burst、单核 97.7% 占用、每 3.3–3.9 s 一次**运行；30 s 内 7 个 burst 与 7 个迟到窗口 **1:1 对齐**；
- 定向 `block/wake` 采集的调用栈进一步证明：`pf-t0` 的睡眠是 `clock_nanosleep`，唤醒源是 **arch timer hrtimer IRQ**（`hrtimer_wakeup ← __hrtimer_run_queues ← hrtimer_interrupt ← arch_timer_handler_phys`），不是 `pf-t1` 的用户态信号。

因此：**迟到 = CPU 可运行态竞争（同一 CPU5 上 nice=0 的 CPU 密集 burst 使 nice=17 的周期线程持续让出 CPU）**；不是 Sleeping 阻塞，也不是 wakeup 慢。`pf-t1` 为什么 burst、为什么 A 被设为 nice 17/绑核，属于 UNKNOWN（未看源码，未做对照）。

---

## 1. 环境与内核事件能力核验

板端（只读探测 + 新建取证目录）：

| 项目 | 实测值 |
|---|---|
| 内核 | `Linux 6.1.83-DR-PL5.1_V1.1.1 #1 SMP PREEMPT Thu Oct 22 11:40:38 CST 2026 aarch64` |
| CPU | 8 核，online `0-7`；`CONFIG_HZ=100` |
| 页大小 | 4 KiB（`KernelPageSize: 4 kB`） |
| `CONFIG_FTRACE` | `y` |
| `CONFIG_SCHED_TRACER` | `y` |
| `CONFIG_FUNCTION_TRACER` | `y` |
| `CONFIG_STACKTRACE` / `CONFIG_FRAME_POINTER` | `y` / `y` |
| `CONFIG_PERF_EVENTS` / `CONFIG_TRACEPOINTS` | `y` / `y` |
| tracefs | `/sys/kernel/debug/tracing`（可用；`/sys/kernel/tracing` 为空壳） |
| trace_clock | `[boot]` |
| `tracing_on` / `events/enable`（采集前） | `0` / `0` |
| 目标 tracepoints | `sched:sched_switch`、`sched:sched_waking`、`sched:sched_wakeup`、`sched:sched_wakeup_new`、`sched:sched_migrate_task` 均存在 |
| `perf_event_paranoid` | `2`（root 实测可做 tracepoint 事件采样 + 内核栈） |
| `perf_event_mlock_kb` / `kptr_restrict` | `516` / `0` |
| 采集器 | tracebox `Perfetto v58.2-add693d8b`（aarch64，部署到 `/userdata/perfetto-skill-lab/work/b/`） |
| 解析器 | `trace_processor_shell` `Perfetto v57.1-c59f57dd4` |

结论：**内核具备 CONFIG_FTRACE/tracefs，并产出了真实 `sched_switch` / `sched_waking` 数据**；本次不是能力受阻场景。没有修改 sysctl、governor、挂载、启动脚本或他人 tracing；只在 `/userdata/perfetto-skill-lab/work/b/` 新建了工具与采集目录。

---

## 2. 目标身份与观测面

### 2.1 公共面

- 程序：`/userdata/perfetto-skill-lab/scheduling/pf-sched-case`，PID **4703**，`/proc/4703/stat` starttime=370262；整个观测期间同一进程，未重启。
- 二进制 SHA256：`0c535463214af2bd073e49003e503d6b14fb3a75998ad1f6fa550a3aba321e0b`（与 PUBLIC_BRIEF 一致）；switch 栈中 mapping Build ID=`8b05dbf75060b48635830d095cdccfbbcce68c0d`（与 PUBLIC_BRIEF 一致）。
- 公共 CSV：`/userdata/perfetto-skill-lab/scheduling/a_latency.csv`（本次快照 `a_latency_after.csv`，41 536 行，seq 1..41536）。

### 2.2 线程事实（`/proc`，采集期间同一进程）

| TID | comm | nice | 调度类 | 亲和性 | 说明 |
|---|---|---|---|---|---|
| 4703 | pf-sched-case | 0 | `TS`=SCHED_OTHER | CPU7 | 主线程 |
| **4705** | **pf-t0** | **17** | **SCHED_OTHER** | **CPU5** | **periodic-A（推定）** |
| 4706 | pf-t1 | 0 | SCHED_OTHER | CPU5 | 同核竞争线程 |
| 4707 | pf-t2 | 0 | SCHED_OTHER | CPU6 | 不共享 CPU5 |

无 RT 线程（`ulimit -r`=0，`ps CLS=TS`），无 cgroup 成员（`/proc/PID/cgroup` 为空）。CPU5 的 `scaling_cur_freq=1500000`、governor=`schedutil`（单点快照，非连续）。

### 2.3 `periodic-A = pf-t0` 的匹配证据

公共 CSV 的 `start_ns` 是 `CLOCK_MONOTONIC`；Trace 时间戳是 BOOTTIME。ClockSnapshot 显示 `MONOTONIC = BOOTTIME + 291 ns`（overview）/`+250 ns`（定向 trace）。

- 把 CSV `start_ns − 291 ns` 与 `pf-t0` 的 Running 区间逐条匹配：**1397 / 1398 命中**，残差（CSV start − 内核 sched_switch 时间戳）最小 3.3 µs、p50 15.1 µs、p90 16.5 µs、最大 25.5 µs。
- 唯一未命中 1 条（seq 39913）位于 Trace 起始后 17.85 ms 的裁剪边缘（早于 pf-t0 首个完整状态区间 +37.8 ms），pf-t0 尚无完整 Running 区间。
- 匹配率与残差量级足以把公共周期线程锁定为 `pf-t0`（UTID 210 in overview / UTID 2 in 定向 trace，TID 均为 4705）。

---

## 3. 采集与执行（可复现）

### 3.1 路线选择

先做 **overview**：系统级 `sched_switch` + `sched_waking` + `process_stats`，30 s，无 perf，回答“Running / Runnable / Sleeping 谁占主导”。分解结果显示 Runnable 占主导、唤醒准时，因此再做一个 **定向 block/wake**：仅对 TID 4705 抓 `sched_switch(prev_pid)` / `sched_waking(pid)` 两路事件采样与内核栈，验证睡眠/唤醒两端的执行上下文。

### 3.2 命令（主机与板端）

```sh
# 板端只读探测
sh survey.sh
sh survey.sh --events > events.txt
sh survey.sh --formats formats

# 主机生成 + 策略校验（无 descriptor 时明确为 SCHEMA_UNKNOWN）
python3 scripts/make_config.py overview --cpu-count 8 --events events.txt \
  --duration-ms 30000 --ftrace-buffer-kib 2048 --trace-buffer-kib 24576 \
  --budget-mib 96 --output overview-30s.pbtxt
python3 scripts/validate_config.py overview-30s.pbtxt
# => POLICY_PASS; SCHEMA_UNKNOWN (no descriptor executed)

python3 scripts/make_config.py block-wake --cpu-count 8 --page-size 4096 --tid 4705 \
  --events events.txt --formats formats --duration-ms 15000 --kernel-frames \
  --output block-wake-15s.pbtxt
python3 scripts/validate_config.py block-wake-15s.pbtxt

# 板端采集（record.sh 只管理本次采集子进程，不启停业务）
TRACEBOX=/userdata/perfetto-skill-lab/work/b/tracebox sh record.sh \
  overview-30s.pbtxt /userdata/perfetto-skill-lab/work/b/cap-ov-1 45
TRACEBOX=/userdata/perfetto-skill-lab/work/b/tracebox sh record.sh \
  block-wake-15s.pbtxt /userdata/perfetto-skill-lab/work/b/cap-bw-1 30

# 主机拉回（scp/tar；不在报告中保存口令）
```

采集返回：

- overview：`RECORDED_DATA_UNCHECKED size_bytes=345867`，`collector_rc=0 timeout=0 forced_kill=0`
- block-wake：`RECORDED_DATA_UNCHECKED size_bytes=298275`，`collector_rc=0 timeout=0 forced_kill=0`

> `RECORDED_DATA_UNCHECKED` 只表示 CLI 正常结束，不表示事件/栈完整；下文数据质量检查是独立的。

---

## 4. 数据质量检查

### 4.1 overview（`cap-ov-1/trace.pftrace`）

| 检查 | 结果 |
|---|---|
| Trace 范围 | `4554475669046..4584181768269` = **29.706 s** |
| `sched_switch` | **10 430** 条 |
| `sched_waking` | **5 153** 条 |
| `sched_wakeup_new` / `sched_process_exit` | 119 / 119 |
| 丢事件/覆盖（commit_overrun、dropped_events、buffer overrun） | **全部为 0** |
| compact parser 跳过 | `compact_sched_switch_skipped=8`、`compact_sched_waking_skipped=4`（≈0.08%；具体内容 TP 未暴露，标 UNKNOWN） |
| 目标线程状态覆盖（UTID 210，显式窗口） | `S 25 224.7 ms / 1 396 段`；`R 2 549.4 ms / 1 400 段`；`Running 1 887.3 ms / 1 402 段`；`D 0.139 ms / 5 段`；`UNKNOWN 44.5 ms` |
| 未知覆盖位置 | 仅首尾：lead 37.84 ms + trail 6.70 ms；**内部无 >1 ms 的状态空档** |
| 区间重叠 | 0 条 |
| 时钟 | BOOTTIME；ClockSnapshot `MONOTONIC = BOOTTIME + 291 ns` |

### 4.2 定向 block/wake（`cap-bw-1/trace.pftrace`）

| 检查 | 结果 |
|---|---|
| Trace 范围 | `4982634661584..4997515115841` = **14.880 s** |
| `sched_switch` / `sched_waking` | 9 129 / 4 524 |
| perf 流 | session 0 = `scheduling.switch`（CPU5），session 1 = `scheduling.waking`（CPU5）；各 **696 样本** |
| 带栈样本 / unwind 错误 | 696/696 / **0** |
| 数据丢失 | `perf_cpu_lost_records[5]=1`（**1 条** perf 样本丢失；选中 wait 位于 trace 中部且边界完整，关联仍唯一；不排除其它时段样本缺失） |
| compact parser 跳过 | switch 8 / waking 5 |
| 目标状态覆盖（UTID 2） | `S 12 071.6 ms`；`R 1 544.2 ms / 679 段`；`Running 969.8 ms / 682 段`；`D 14.33 ms / 5 段`；`UNKNOWN 280.5 ms` |
| 未知覆盖位置 | 首尾：lead 260.08 ms + trail 10.62 ms；内部无 >1 ms 空档，另有累计约 9.8 ms 的亚毫秒级小空档 |
| 时钟 | BOOTTIME；`MONOTONIC = BOOTTIME + 250 ns` |

### 4.3 事件-样本对时（E2 关联的校准）

同一 sched 事件与 perf 样本的时间戳存在固定路径偏差（不是 0）：

- switch 流（session 0，696 样本）：`event.ts − sample.ts` 的 p10≈+21.5 µs、p50≈+89.5 µs、p90≈+108.9 µs（边缘样本出现 140/260 ms 的“最近事件”离群，对应 trace 首尾缺失事件）；
- waking 流（session 1，696 样本）：p10≈+3.3 µs、p50≈+12.8 µs、p90≈+14.7 µs。

因此 E2 关联使用 **200 000 ns 校准容差**，并先验证唯一性：200 µs 内 switch 样本 678/696 只有 1 个候选、4 个有 2 个候选、14 个无候选（首尾）；waking 样本 677/696 只有 1 个候选、0 个多候选。所选 wait 的两侧各 **1 个**候选（见 §7）。该容差是工具校准值，不改变原始时间戳。

---

## 5. 观察到的迟到时间窗

### 5.1 公共 CSV 全量（13.8 min，41 536 周期）

- 周期网格：`scheduled_ns` 固定在 **20 ms 绝对网格**（`scheduled_ns mod 20 ms = 13 450 973` 恒定）。
- latency：p50 **110.9 µs**、p90 120.6 µs、p99 **46.56 ms**、max **76.56 ms**。
- latency > 5 ms：**2 185 / 41 536 = 5.26%**，聚成 **222 个簇**；簇跨度中位 420 ms，簇间间隔中位 **3.6 s**（3.28–3.94 s）。

### 5.2 Trace 内的 7 个迟到窗口（UTID 210；时间相对 Trace 起点）

| seq | 首 deadline (ms) | 末 deadline (ms) | 簇跨度 (ms) | 执行周期数 | max latency (ms) | mean latency (ms) |
|---|---|---|---|---|---|---|
| 40087–40096 | 3 497.8 | 3 917.8 | 420 | 10 | 46.6 | 39.6 |
| 40270–40279 | 7 437.8 | 7 857.8 | 420 | 10 | 46.6 | 33.6 |
| 40452–40460 | 11 317.8 | 11 677.8 | 360 | 9 | 46.6 | 38.5 |
| 40629–40637 | 15 097.8 | 15 457.8 | 360 | 9 | 46.6 | 37.7 |
| 40832–40841 | 19 397.8 | 19 817.8 | 420 | 10 | 46.6 | 37.6 |
| 41006–41015 | 23 137.8 | 23 537.8 | 400 | 10 | 46.6 | 33.6 |
| 41180–41190 | 26 837.8 | 27 297.8 | 460 | 11 | 46.6 | 34.8 |

- Trace 内共有 1 398 个周期起点，其中 **69 个** latency>5 ms，全部落在上述 7 个窗口内；窗口外无迟到。
- 迟到值呈明显量化：**16.6 / 26.6 / 36.6 / 46.6 ms**（另有 6.5/6.8/6.9/44.0 ms 少量）。
- 迟到期间 `scheduled_ns` 的相邻差值变为 **40 / 60 ms**（正常 20 ms）：说明应用的绝对 20 ms 网格在错过 deadline 后跳到下一个未来网格点，**被跳过的周期不补执行**。这是对 CSV 的观察/推断，不是源码结论。

---

## 6. 迟到分解：等待 / 唤醒 / CPU 调度

对 1 397 个可与状态边界直接邻接的周期做分解：`scheduled → S→R（唤醒）→ Running（拿到 CPU）`。

| 指标 | 值 |
|---|---|
| 正常周期 Runnable 等待 | overview 1 328 个：p50 **43 µs**；定向 trace 正常唤醒 637 个：9.96–59.5 µs |
| 迟到周期（69 个）唤醒延迟 `S→R − scheduled` | min 52.0 / p50 **52.6** / max 55.2 µs |
| 迟到周期 Runnable 等待 `Running − S→R` | min 6.48 / p50 **36.51** / max **46.51** ms |
| Runnable 等待占 latency 比例 | p50 **0.9985**（99.85%） |
| 迟到唤醒的 `irq_context` | **69/69 = 1（IRQ 上下文）** |
| 迟到唤醒的 `waker_utid` | **69/69 = 211（pf-t1）** |

关键解释：`waker_utid=211` **不是** “pf-t1 用 futex/信号唤醒 A”的证据。这些 Runnable 区间的 `irq_context=1`，`waker_id` 指向的是 **hrtimer IRQ 打断 pf-t1 时 pf-t1 的 Running 区间**；语义上的唤醒源是定时器中断（§7 用真实样本栈证明）。按 Skill 口径：`waker` ≠ owner，IRQ 上下文中的执行任务不能当作业务唤醒者。

结论：**latency ≈ 52.6 µs（唤醒）+ 36.5 ms（Runnable 等 CPU）**。不是 Sleeping 阻塞，不是唤醒慢。

---

## 7. 定向 block/wake：睡眠与唤醒两端的真实上下文

### 7.1 选中 wait（`02-wait-episodes.sql`，UTID 2）

```
wait_id=1197, state=S
sleep_start_ts = 4984051172376, sleep_ns = 2 345 458
wake_ts        = 4984053517834
run_ts         = 4984090011751
runnable_ns    = 36 493 917
boundary_status= COMPLETE
```

即：睡 2.35 ms → 醒来 → Runnable **36.49 ms** → 运行。

### 7.2 事件对关联（`05-event-pair.sql`，容差 200 µs，两个 proof 参数均已核实）

```
wait_id=1197  utid=2  switch_cpu=5  waking_cpu=5  waker_utid=211  irq_context=1
switch_status = MATCH_UNIQUE   switch_sample_id=140  switch_offset=-21 125 ns
wake_status   = IRQ_CONTEXT    wake_sample_id=141    wake_offset  =-11 708 ns
evidence      = PARTIAL_OR_UNKNOWN_NO_ROOT_CAUSE
```

- `switch_status=MATCH_UNIQUE`：切出边界（睡眠开始）与 session 0 样本唯一对应，且 `nearby_events=1`。
- `wake_status=IRQ_CONTEXT`：按 Skill 规则，IRQ 上下文**不**把当时执行任务认定为语义唤醒者；但唤醒样本真实存在，下面是它的实际栈。
- 数据丢失说明：本 trace 有 1 条 `perf_cpu_lost_records`；所选 wait 不在首尾，两侧候选唯一。

### 7.3 切出栈（sample 140，pf-t0 睡眠开始，callsite 16）

```
__schedule → schedule → do_nanosleep → hrtimer_nanosleep
→ common_nsleep_timens → __arm64_sys_clock_nanosleep
→ invoke_syscall → el0_svc_common → do_el0_svc → el0_svc
→ el0t_64_sync_handler → el0t_64_sync
→ clock_nanosleep (libc) → pf-sched-case+0x404…
```

→ periodic-A 的睡眠是 **`clock_nanosleep`**（自愿定时睡眠），不是 mutex/futex 阻塞。

### 7.4 唤醒栈（sample 141，hrtimer IRQ 打断 pf-t1 用户态，callsite 74）

```
try_to_wake_up → wake_up_process → hrtimer_wakeup
→ __hrtimer_run_queues → hrtimer_interrupt → arch_timer_handler_phys
→ handle_percpu_devid_irq → generic_handle_domain_irq → gic_handle_irq
→ call_on_irq_stack → do_interrupt_handler
→ el0_interrupt → __el0_irq_handler_common → el0t_64_irq_handler → el0t_64_irq
→ (用户态 PF 进程 PC)
```

→ 唤醒源是 **arch timer 的 hrtimer 中断**；`pf-t1` 只是被中断的当前任务。**不能**据此说 pf-t1 唤醒了 A。

### 7.5 15 s 定向 trace 的统计一致性

UTID 2 的 Runnable 区间按等待时长与 `waker_utid` 交叉：

| 类别 | waker_utid | 个数 | Runnable 等待范围 |
|---|---|---|---|
| 正常（≤5 ms） | 0（swapper / CPU5 idle） | 637 | 9.96–59.5 µs |
| 迟到（>5 ms） | **211（pf-t1，IRQ 上下文）** | **40** | **16.5–56.5 ms** |
| 正常 | 178（mmc/IO 完成上下文） | 2 | 61.2–61.3 µs |

切换出栈分布：691/696 为 `clock_nanosleep`；3 为 ext4 journal `wait_transaction_locked`；2 为 jbd2 `io_schedule`（CSV 日志写 `/userdata` 的 I/O，合计 D 态 14.3 ms，与 36–46 ms 迟到无关）。
唤醒栈分布：651 为 idle 上下文的 hrtimer（`el1` 中断），40 为 pf-t1 上下文的 hrtimer（`el0` 中断），3 为 jbd2，2 为 mmc IO 完成。

---

## 8. 同核竞争与调度事实（CPU5，全进程，不只目标进程）

`03-cpu-competitors.sql` 不按目标进程过滤。对 7 个迟到窗口中第一个窗口 `[+3 494.3 ms, +3 584.3 ms)`（90 ms）：

```
CPU5: pf-t1  86.95 ms  (96.6% of 90 ms window)
      pf-t0   2.22 ms  ( 2.5%)
```

对整个 30 s 的迟到 Runnable 等待做区间相交（半开区间；所有进程）：

| CPU5 执行者 | 覆盖迟到等待 | 占比 |
|---|---|---|
| **pf-t1 (TID 4706)** | **2 507.02 ms** | **100.0%** |
| kworker/5:2 | 0.03 ms | 0.0% |
| migration/5 | 0.03 ms | 0.0% |
| 合计 | 2 507.1 ms | 100% |

全部 Runnable 等待（含正常）中：pf-t1 98.3%，swapper/idle 1.7%（42.23 ms，对应 1 328 个正常周期；其中位 ~43 µs、均值 ~32 µs 的唤醒→运行延迟）。

`pf-t1` 的 burst 统计（CPU5，30 s）：

| burst 序号 | 起始（相对 trace, ms） | 跨度 (ms) | busy (ms) | 单核占用 |
|---|---|---|---|---|
| 1 | 3 495.1 | 471.9 | 460.8 | 97.7% |
| 2 | 7 428.5 | 435.8 | 425.8 | 97.7% |
| 3 | 11 306.4 | 415.4 | 406.5 | 97.9% |
| 4 | 15 085.3 | 424.4 | 414.5 | 97.7% |
| 5 | 19 382.5 | 461.9 | 452.0 | 97.8% |
| 6 | 23 120.8 | 423.9 | 413.9 | 97.6% |
| 7 | 26 827.8 | 476.9 | 465.8 | 97.7% |

- burst 间空闲 3.28–3.87 s；
- 7 个 burst 与 §5.2 的 7 个迟到窗口 **1:1 重叠**；迟到窗口的首个 deadline 出现在 burst 开始后 **+2.6…+17.0 ms**，最后一个迟到 deadline 在 burst 结束前；
- pf-t1 切片长度：80 段，其中 67 段落在 20–50 ms（均值 43.5 ms，最大 48.9 ms）；
- pf-t0 切片：1 402 段，均值 1.35 ms，最大 1.63 ms（每周期只拿到很短 CPU）。

调度属性事实：pf-t0 nice=17（CFS weight 约 23），pf-t1 nice=0（weight 1024），同绑 CPU5。两者都在 Runnable 时，A 的长期公平份额约 `23/(23+1024)=2.2%`；而 A 的需求约 `1.887 s / 29.706 s = 6.35%`。这只能说明“在 pf-t1 连续占核时，A 的权重处于结构性劣势”，不等于单独证明了 nice 设置是唯一原因（见 UNKNOWN）。

---

## 9. 事实边界：E1 / E2 / E3

| 层级 | 判定 | 本报告中的依据 | 不能越过的边界 |
|---|---|---|---|
| **E1 状态事实** | **PASS** | `thread_state`：迟到周期 Runnable 占比 p50 99.85%；`sched_slice`：迟到等待期间 CPU5 100% 由 pf-t1 执行；1 397/1 398 周期起点与 pf-t0 Running 区间匹配；7/7 迟到窗口与 pf-t1 burst 对齐 | E1 只说明“谁在什么状态、CPU 在跑谁”；不说明 pf-t1 的代码语义 |
| **E2 事件/执行上下文关联** | **PASS（有质量注记）** | 定向 trace 的切出样本与唤醒样本均唯一关联：切出栈 `clock_nanosleep`，唤醒栈 `hrtimer_wakeup ← hrtimer_interrupt ← arch_timer_handler_phys`；唤醒发生在 pf-t1 被中断的用户态上下文（`irq_context=1`） | `waker_utid=211` 是 IRQ 打断上下文，**不是** pf-t1 用户态信号；E2 不自动推出锁所有者；1 条 perf 记录丢失+200 µs 校准容差需随结论保留。定向 trace 的 `05-event-pair.sql` 因 `wake_status=IRQ_CONTEXT` 把 `evidence` 保守地写成 `PARTIAL_OR_UNKNOWN_NO_ROOT_CAUSE`；这里 E2 的 PASS 指“切出/唤醒两端样本已被真实栈核实”，不是 SQL 自动给出的根因结论 |
| **E3 机制归因** | **PASS（机制层，带边界）** | 迟到窗口内 A 一直 Runnable，CPU5 一直被 pf-t1 占用；7/7 burst 对齐；nice17 vs nice0 的权重差与“A 无法抢占、只能等 pf-t1 让出”一致 | 只归因到 **CPU 调度竞争/可运行态饥饿**。不归因 pf-t1 的业务目的、不归因 nice/绑核的设置者、不声称分清了“纯 busy”与“nice 权重”的相对贡献；无对照实验（按要求不做） |

**明确排除（在本次数据范围内）**：

- 不是 Sleeping 阻塞：睡眠为 `clock_nanosleep`，2.35–18.9 ms，且醒来时刻在 deadline 后 ~52 µs；
- 不是 wakeup 延迟：hrtimer 唤醒延迟约 52 µs，仅占迟到 latency 的约 0.1%–0.8%；
- 不是 RT 抢占：pf-t1 为 SCHED_OTHER nice=0，无 RT 线程；
- 不是 futex 锁等待/锁所有者问题：切出栈为 `clock_nanosleep`，不是 futex；
- 不是 CSV I/O 阻塞：D 态仅 0.139 ms（overview），远小于 36–46 ms；
- 不是 CPU 迁移：pf-t0 全部 1 402 个切片都在 CPU5。

---

## 10. 可能原因（按证据强度）

1. **（主因，强证据）同核 CPU 竞争 / Runnable 饥饿**：pf-t1 每 3.3–3.9 s 出现一次 415–477 ms、97.7% 单核占用的 burst；A 每个 20 ms 周期准时被 hrtimer 唤醒，但在 pf-t1 让出 CPU5 前无法运行，累积成 16.5–46.5 ms 的逐周期迟到。7/7 迟到窗口与 burst 对齐，迟到等待 100% 与 pf-t1 执行重叠。
2. **（结构性放大因素，中强）CFS 权重差**：pf-t0 nice=17、pf-t1 nice=0 且同绑 CPU5；A 的权重约为 pf-t1 的 1/44，唤醒时不能抢占 pf-t1，只能等其时间片结束/让出。观察到的 16.6/26.6/36.6/46.6 ms 台阶与“等若干调度片”一致，但未做分离 nice 与 pure-busy 的对照。
3. **（应用行为，观察）错过 deadline 后跳过**：迟到时 `scheduled_ns` 间隔变为 40/60 ms，说明 missed 的 20 ms 周期不补跑；这会让“每个执行周期都迟到”的现象持续约 0.36–0.46 s。
4. **（次要，已排除为主因）CSV 日志 I/O**：ext4 journal / mmc 完成导致的 D 态总计 0.139 ms（overview）/14.3 ms（定向 trace），不解释 36–46 ms 的 Runnable 等待。

---

## 11. UNKNOWN 清单

1. **pf-t1 为什么 burst、burst 里做什么**：未查看源码/业务日志；只能确认其 CPU5 占用形态（415–477 ms，97.7%），不能确认业务目的。
2. **为什么 periodic-A 被设为 nice=17、pf-t0/pf-t1 都绑 CPU5**：这是运行事实，不是本次可归因的设计意图；未查启动脚本/源码/测试设计。
3. **pf-t1 切片内 IRQ/softirq 的占比**：未采集 IRQ 事件；`sched_slice` 的“pf-t1 占用”包含落在其上下文中的中断时间。唤醒栈本身就是一个 hrtimer IRQ，但不能量化全部 IRQ 时间。
4. **16.6/26.6/36.6/46.6 ms 台阶的精确 CFS 机制**：未读取 `sched_latency_ns` 等运行参数（部分 /proc 文件不可读），也未做调度器级复算；只报告观测。
5. **~52 µs 唤醒延迟的构成**（hrtimer 精度、IRQ 延迟、tick 行为）：只测到结果，未采集 `timer:*` 事件。
6. **CSV 中 40/60 ms 间隔是“显式 skip 策略”还是“应用按当前时刻重算网格”**：数据只能证明网格被跳过，不能证明代码策略。
7. **1 条 perf 丢失记录 / 14 条首尾无候选样本的具体内容**：`perf_cpu_lost_records[5]=1`，无法知道丢的是哪一条；主结论不依赖它，但关联质量注记必须保留。
8. **单次性与泛化**：1 次 overview（30 s）+ 1 次定向（15 s），未做负载/空载/重跑对照（按要求不做额外对照）；不能声称覆盖所有运行条件。
9. **pf-t1/pf-t2 是否对应题目中的 worker-B/C**：未假设、未命名、未据此建立因果；本报告只按 TID/线程名陈述观测。
10. **CPUfreq/热/其它 IRQ 对 CPU5 的长期影响**：只有 governor/频率单点快照，无连续数据。

---

## 12. 留存物、版本与哈希

目录：`/root/sdk_ly_x5_1.1.1/tmp/sched-diag/`

| 文件 | SHA256 |
|---|---|
| `cap-ov-1/trace.pftrace`（真实 overview Trace） | `eacb36803c1788e0834cdff76fd1b56ab45754abdc91312da993bf12c0f025d0` |
| `cap-ov-1/config.pbtxt` | `1cc539dca5ad67587da7a6aca7a94f8eb020624e8c388e6f4749ea34175d87b5` |
| `cap-bw-1/trace.pftrace`（定向 block/wake Trace） | `db96d5f2f69e73cf0087b11f7b814dc28d7d884fc1ff9daa790b16404fd30bf8` |
| `cap-bw-1/config.pbtxt` | `26d03de8b7a6d9f51d6a2a20cbce53087fd2e2b271a2c3159495b111f92669c6` |
| `a_latency_after.csv`（采集后公共 CSV 快照） | `3fab975a20c88c2e07c3eee5b6a41f87f1c29cb1d13b75932cb7c17d951aa80d` |
| `events.txt`（板端 available_events 快照） | `1e359622c19f55ebee993a37b95f4f659d8e018ef0c1fd9e5bc0173edeb3e879` |
| `formats/sched_switch.format` | `055b48555a185ce9e2eccb960cca6604553f68e91bcb83b886461818a3ce65d9` |
| `formats/sched_waking.format` | `59c8a0da3729aaa96c5c75c21a48fcb4a5b43a4343a6e2566d196b936eb2be0c` |
| `analysis/correlate.py`（CSV↔Trace 对账脚本） | `bd945526f8fb00693463ea29afed7d711c23225770ac5bd8a816c5e74a372e39` |

工具/版本：

- tracebox `v58.2-add693d8b`，sha256 `2d21883e9c55818f851fd8c391afb9b366032b3110076b4fd41f31f30b5849fa`
- trace_processor_shell `v57.1-c59f57dd4`，sha256 `79ae477e2f7c1a80a74a48cb0eb660caab29b36cc4f9bdb511b61155d55eaf4d`
- Skill `perfetto-scheduling-debugging` v0.1.0 candidate：`SKILL.md` `71d5dd66…bcec`，`MANIFEST.json` `d224b204…f291`
- 目标二进制 `pf-sched-case`：`0c535463…1e0b`（与 PUBLIC_BRIEF 一致）；Build ID `8b05dbf75060b48635830d095cdccfbbcce68c0d`

其他留存：`cap-ov-1/{status.txt,exit.txt,collector.log,notify.byte,help.txt}`、`cap-bw-1/`（含 config/status/log/targets-before）、`analysis/runs/`（每条 SQL 的渲染查询、stdout.csv、stderr.txt、run.json、版本）、`analysis/{correlation.txt,pf_t0_states.csv,cpu5_slices.csv,pf_t1_slices.csv}`、`analysis/bw/{q05_result.csv,q05_tol200us.sql,q06_switch.csv,q06_wake.csv}`、`board_facts.txt`、`SHA256SUMS.txt`。

---

## 13. Perfetto UI 复核步骤（手动）

UI 版本会变，以下只描述语义，不承诺按钮位置。

### A. overview（回答“迟到窗口里 A 在哪个状态、CPU5 在跑谁”）

1. 打开 <https://ui.perfetto.dev> → “Open trace file” → 选择 `cap-ov-1/trace.pftrace`。
2. 在进程列表找到 `/userdata/perfetto-skill-lab/scheduling/pf-sched-case`，展开：
   - **pf-t0（TID 4705）**：Thread State 轨道；
   - **pf-t1（TID 4706）**、**pf-t2（TID 4707）**；
   - **CPU 5** 轨道（以及 CPU 6/7 用于排除）。
3. 用“时间跳转/搜索”定位到任一迟到窗口，例如 BOOTTIME `4557973450973` 附近（约 Trace 起点 +3 498 ms）：
   - pf-t0 轨道应出现很长的 **Runnable（R）** 条，紧接短暂的 **Running**；
   - CPU5 轨道同一时间由 **pf-t1** 的 20–50 ms 连续切片占满。
4. 点击 pf-t0 的 Runnable 条，在详情面板核对：
   - Duration ≈ 26–46 ms；
   - `irq_context=1`；
   - Waker 显示为 **pf-t1** —— 结合 IRQ 上下文与 §7 的栈，应读作“定时器 IRQ 打断 pf-t1”，**不是** pf-t1 信号唤醒。
5. 缩放到正常周期（窗口外的 20 ms 周期）：pf-t0 的 Runnable 只有几十 µs，CPU5 为 idle/其他；这是同一 Trace 内的自然对照，不是额外实验。
6. 可选 Debug Track：先跑渲染后的 `01b-state-track.sql`（`--utid 210 --start-ns … --end-ns …`），在 Query 结果上 “Add debug track → Slice”，字段 ts / dur / state，Pivot 用 utid；单位仍为 ns。

### B. 定向 block/wake（回答“睡在哪、谁/什么唤醒”）

1. 打开 `cap-bw-1/trace.pftrace`。
2. 展开 pf-t0（TID 4705，本 trace 中 UTID 2）；定位到 `wait_id=1197` 的睡眠：
   - sleep 起点 `4984051172376`，wake 边界 `4984053517834`，run 起点 `4984090011751`。
3. 在 perf 轨道中找到 `scheduling.switch` / `scheduling.waking`（本 trace 中 session 0/1，均 CPU5）；点击睡眠边界/唤醒边界处的样本，展开调用栈 chevron：
   - switch 样本：`clock_nanosleep → … → __schedule`；
   - waking 样本：`try_to_wake_up → wake_up_process` 上游应为 `hrtimer_wakeup → __hrtimer_run_queues → hrtimer_interrupt → arch_timer_handler_phys`。
4. 注意：唤醒样本显示的执行者是 pf-t1（被中断者），但栈证明唤醒发生在 hrtimer IRQ，不应把它画成 pf-t1→pf-t0 的“业务唤醒箭头”。

### C. 时间对账

- UI 中的 Timestamp 是 Trace 的 **BOOTTIME**；公共 CSV 是 **CLOCK_MONOTONIC**。
- overview：`trace_ts ≈ csv_mono − 291 ns`；定向 trace：`trace_ts ≈ csv_mono − 250 ns`。
- CSV 的 20 ms 网格与 Trace 内 1 397/1 398 条 Running 起点匹配，残差 3.3–25.5 µs；可用 `analysis/correlate.py` 复算。

> UI 未做自动化截图/浏览器验收；以上为手动配方。若实际 UI 与该版本行为不同，以本报告的 SQL/CSV 原始输出为准（UI_UNKNOWN）。

---

## 14. 范围声明

- 本报告只做 **一次独立诊断**：1 次 30 s overview + 1 次 15 s 定向采集；**没有**做负载/空载/重跑/对照实验，**没有**干预 pf-t0/pf-t1/pf-t2（未 stop/start、未改 nice/affinity/governor/sysctl），**没有** kexec/刷机/替换内核/重启板卡。
- 未读取源码、`PRIVATE_GROUND_TRUTH.md`、A 的测试设计/自测日志，未反编译二进制。
- `E2` 的结论依赖 200 µs 校准容差与唯一候选；`E3` 只覆盖“CPU 调度竞争/可运行态饥饿”这一机制层，不外推到 pf-t1 的业务语义或设计意图。
- 若需把 UNKNOWN 收敛为确定结论，所需的最小增量证据是：IRQ/softirq tracepoints（量化 pf-t1 切片内 IRQ 时间）、`timer:hrtimer_start/expire`（唤醒 52 µs 的构成）、以及在不改变业务的前提下由用户授权的一次受控对照（本报告按任务要求不做）。

---

**报告冻结**：本文件写完后计算 SHA256，见 `FIRST_PASS_REPORT.md.sha256`；此后不再修改。
