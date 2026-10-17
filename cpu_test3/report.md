# RDK X5 · task-service 请求延迟抖动 —— Perfetto CPU 实测诊断报告

- 日期：本机 2026-10-18（板端 uptime 与 trace 时钟对齐见 §4.4）
- 目标板：`root@192.168.1.10`，`Linux buildroot 6.1.83-DR-PL5.1_V1.0.20 #3 SMP PREEMPT aarch64`，8 逻辑核
- 被测服务：`/userdata/cpu-lab/bin/task-service --cpu-a 6 --cpu-b 7`（PID 10285，9 线程）
- 结果目录：`/root/code_1.0.20/tmp/cpu-task-service-diag/`

> 本轮为**独立诊断**：未读取 cpu_test2 仓库 / 测试源码 / GROUND_TRUTH / selfcheck 材料；只使用任务给定的路径、`task-servicectl`、业务日志（`requests.jsonl`、`service.log`）和板端二进制（未改、未 strip 操作）。
> 未停止、未重启、未修改服务；未改 sysctl / governor / 挂载；未修改 Skill；未做 UI 自动化。

---

## 0. 结论摘要（先看这段）

1. **延迟变大不是一个原因，而是每 48 s 相位周期（service.log 的 `slot idx 0..5`，每 8 s 一格）里交替出现的三种模式**，本 trace 完整覆盖了 6 个 slot：

| slot | 请求延迟中位数 | 慢请求形态 | 主要机制（本 trace 实测） |
|---|---|---|---|
| idx0 / idx4（前半） | 14–15 µs | 无 | 正常 |
| idx5 | 2.25 ms | 每个请求都慢 | **每请求 CPU 工作量放大**（13 µs → 2.15 ms），`req_worker_main→ts_compute_cpu_budget→ts_mix_block`，**无等待** |
| idx1 | 14 µs | 无 | `calc-worker` 4×250 ms 满载尖峰，**不影响请求延迟** |
| **idx2** | 32 ms，最大 52 ms | 每 2 s 成对出现 2 个（8 s 内 8 个） | **CPU6 饱和 + 单核 10 ms 片轮转**：`req-worker`、`job-alpha`、`job-beta` 三个线程在 CPU6 上各 10 ms 轮流，**CPU7 同期空闲**；窗口内 CPU6 占用 100%，CPU7 0.6–0.8% |
| **idx3** | 15 µs，最大 92.8 ms | **每秒恰好 1 个** | **~91.6 ms 条件变量阻塞等待**，由 `hold-helper` 唤醒；等待期间两核几乎全空闲（CPU6 1.3–2.4%，CPU7 1.0–2.1%） |

2. **"有时伴随 CPU 升高"**：升高的是**进程/单核**，不是整机。本 trace 中服务总 CPU = 6555 ms / 55 s = **11.9% 的单核**（≈整机 8 核的 1.5%）；`ps` 的 11.3%、日志 `cpu_avg=0.113` 与之一致。CPU6 峰值出现在 idx2：服务单秒 CPU 峰值 **418 ms**（≈42% 单核），CPU6 单秒占用峰值 **406 ms**，且**在被观测的 52 ms 请求窗口内精确 100% 饱和**——1 s 粒度的 `top` 只能看到 25–40%，容易漏判。

3. **"整机 CPU 不高但请求仍慢"**：idx3 的 92.8 ms 完全是**阻塞等待（S 状态）**，活跃核空闲率 >97%，与 CPU 饱和度、频率、迁移都无因果关系。

4. **CPU 频率不是解释**：`schedutil` 单 policy（CPU0–7，300/600/1200/1500 MHz）确实在变；但
   - idx2 饱和窗口内 CPU6/7 实测为 **1500 MHz（最高频）**，不是降频造成的；
   - idx3 的 92.8 ms 里线程是 **Sleeping**，频率对它无意义；
   - 即使按 300 MHz 折算，13 µs 级基线工作也只有 ~52 µs，差 3 个数量级。
   温度 54.6 °C（thermal-cpu），无热降频证据。

5. **跨核运行**：服务**被限制在 CPU6–7 两个核**（其余 6 核完全没用）；探测时 `req-worker` 更是只允许 CPU6。trace 中 9 个线程共发生 **1424 次 `sched_migrate_task`**（含唤醒安置），`req-worker` 的 CPU 时间 1324.6 ms 落在 CPU6、98.9 ms 落在 CPU7（**93% 在 CPU6**）。迁移本身不是延迟来源；**"只给 2 核 + 实际全挤在 CPU6"** 才是 idx2 的结构性容量瓶颈。

6. **热点函数**（100 Hz `linux.perf`，600 个带栈样本，符号已解析）：
   - `req-worker` 118/135 自采样在 `ts_mix_block`（`req_worker_main → ts_compute_cpu_budget → ts_mix_block`）= **纯用户态计算，不是系统调用/锁**；
   - `calc-worker` → `calc_worker_main → ts_compute_until → ts_mix_block`（99）；
   - `job-alpha/job-beta` → `compete_main → ts_compute_until → ts_mix_block`（各 67）；
   - `sync-waiter` → `flag_waiter_main` 自旋（114）+ `ts_spin_pause`（14）；
   - `hold-helper` → `hold_helper_main → sleep_for`，只在极短周期轮询（每次 35–40 µs，约 5 ms 一次）。

7. **反驳简单因果的证据**：idx1（`calc-worker` 4×250 ms 满载）与 idx4（`sync-waiter` 106 ms/s 自旋）期间，请求中位数仍是 **13.8–14.1 µs**。所以"进程 CPU 高 ⇒ 请求慢"在这套服务里**不成立**；真正相关的是**"请求线程所在的核是否被同进程其它线程占满"**（idx2）和**"请求路径是否被条件变量阻塞"**（idx3）。

---

## 1. 实际加载的 Skill 版本与执行约束

| 项 | 实际值 |
|---|---|
| Skill | `perfetto-cpu-debugging` **v0.1.0 (status: candidate)** |
| 路径 | `/root/.dsh/skills/perfetto-cpu-debugging/` |
| `MANIFEST.json` version/status | `0.1.0` / `candidate` |
| `SKILL.md` sha256 | `352986f523b17c0dcfe081479ce26618798c40da78c985dedc0e704ab602cc83`（与 MANIFEST 记录一致 → 未被修改） |
| `sql/00-inventory.sql` sha256 | `dd59d38d551b24a422825a2381bb33da5141e9f326a724647229eedeb262c3f4`（与 MANIFEST 一致） |

按 Skill 要求执行的路由：`overview/scheduling`（sched_switch → CPU 时间桶/线程/尖峰）+ `frequency`（cpufreq/cpuidle）+ `profiling`（linux.perf 采样），共读 `references/01/02/03/04/05/06`。

Skill 自带的会话脚本按原样使用（未修改）：`scripts/linux_session_lib.sh`、`scripts/linux_trace_session.sh`。`scripts/host_pull.sh` 在本机不可用（其内部 `scp` 不带密码认证），改用等价的 `sshpass scp` + 显式非空/sha256 校验，见 §4.3。

---

## 2. 只读状态确认（采集前）

```
$ /userdata/cpu-lab/task-servicectl status
state : running
pid   : 10285
cmd   : /userdata/cpu-lab/bin/task-service --cpu-a 6 --cpu-b 7
threads: 9
uptime: 1175 s
mem   : VmHWM: 2128 kB   VmRSS: 2128 kB
autostart: enabled (/userdata/startup.sh -> task-servicectl start)
```

线程（采集前后一致，PID/线程数未变）：

```
10285 controller      10288 req-dispatch   10289 req-worker     10290 calc-worker
10291 job-alpha       10292 job-beta       10293 hold-helper    10294 sync-waiter
10295 sync-publisher
```

关键只读事实：

- **亲和性**：`controller/req-dispatch/calc-worker/job-alpha/job-beta/hold-helper/sync-waiter/sync-publisher` = `Cpus_allowed_list 6-7`；**`req-worker` = `6`**（只允许 CPU6）。
- CPU：8 核；`policy0 affected_cpus=0 1 2 3 4 5 6 7`，`governor=schedutil`，`min=300000 max=1500000`，`scaling_available_frequencies=300000 600000 1200000 1500000`。
- 温度：`thermal-cpu 54.6 °C`，`thermal-ddr 55.3 °C`（非只读以外的任何写操作未执行）。
- `perf_event_paranoid=2`、`kptr_restrict=0`；root 下 `perf stat -e cpu-clock -a` 实测可用（**未修改任何 sysctl**）。
- tracefs：`/sys/kernel/debug/tracing`，`current_tracer=nop`、`tracing_on=0`（未被占用）。
- `power/cpu_frequency`、`power/cpu_idle`、`sched/sched_switch`、`sched/sched_waking`、`sched/sched_wakeup_new`、`sched/sched_migrate_task` 均在 `available_events`（1170 行，实测导出）。
- 工具：板端 `tracebox` **Perfetto v57.1-c59f57dd4**。说明：板端并无系统级 `tracebox`，仅 `/userdata/cpu-diag-1018-013326/` 下有一个二进制；**只读取并复制该二进制**到本次会话目录（`sha256 58f44bbb…`，未改原件），该目录里的其它文件（trace/fixture/log）**一律未作为证据读取**。主机 `trace_processor_shell` **v57.1-c59f57dd4**（与采集器同版本）。
- 业务日志：`requests.jsonl` 每行一条请求；`service.log` 含 `slot`/`calc`/`cycle` 事件（`cycle.wall_s=48.00`，`slot.dur_s=8`，`aff_moves` 每周期 176→192，`lock_timeout=0`、`spin_timeout=0`）。

---

## 3. 数据源与配置（实际使用）

一条 55 s 的 Trace 同时承载三条路线（sched + freq/idle + perf），而不是连续抓多次：

| 数据源 | 实际参数 | 目的 |
|---|---|---|
| `linux.ftrace` | `sched/sched_switch`、`sched/sched_waking`、`sched/sched_wakeup_new`、`sched/sched_migrate_task`、`power/cpu_frequency`、`power/cpu_idle`；`buffer_size_kb 4096`、`drain_period_ms 250` | 忙/等（Running vs Runnable vs Sleeping）、跨核迁移、频率/Idle |
| `linux.process_stats` | `scan_all_processes_on_start`、`proc_stats_poll_ms 1000` | 进程/线程名与 UPID 归属 |
| `linux.sys_stats` | `cpufreq_period_ms 500` | 频率初值与 500 ms 轮询（`cpu_frequency` 只在变化时出事件） |
| `linux.perf` | `SW_CPU_CLOCK 100 Hz`（每 CPU）、`callstack_sampling.scope.target_cmdline="task-service"`、`kernel_frames: true` | 用户态热点函数（只采本进程，避免整机 unwind 开销） |
| 通用 | `duration_ms 55000`、`buffers 65536 KB RING_BUFFER` | 覆盖 ≥1 个 48 s 相位周期 |

配置文件：`tmp/cpu-task-service-diag/cpu-combined.pbtxt`（实际下发的那份，含偏离模板的理由注释）。
同时用 Skill 的生成器基于**板端真实** `available_events.txt` 生成了 4 份路线模板：`cfg-overview.pbtxt`、`cfg-scheduling.pbtxt`、`cfg-frequency.pbtxt`、`cfg-profiling.pbtxt`（`make_config.py` rc=0，无"event unavailable"告警）。

校验（`scripts/validate_config.py`）：

```
[PASS] config: structural checks passed (NOT official schema)
[PASS] schema: validated with supplied collector-matching descriptor   # 见下方说明
[NOTE] runtime event support, perf privileges, data, and flush NOT checked
```

- 结构检查 **PASS**（5 份配置全部）。
- schema：用本机仅有 `/root/code_1.0.20/trace_config_v58.2.desc` 解析通过，但**板端采集器是 v57.1**，版本不匹配 → 按 Skill 规则正式 schema 判定记 **UNKNOWN（不冒充 PASS）**。
- 实际运行条件另由本轮真实 trace 验证（见 §4.2）。

---

## 4. 采集与 Trace 验收

### 4.1 实际命令

```bash
# 板端（WORK/TRACEBOX 在目标机展开）
WORK=/userdata/cpu-lab/perfetto-session \
TRACEBOX=/userdata/cpu-lab/perfetto-session/tracebox \
sh /userdata/cpu-lab/perfetto-session/linux_trace_session.sh \
   /userdata/cpu-lab/perfetto-session/cpu-combined.pbtxt cpu 90
```

### 4.2 采集状态（脚本产出，非人工声称）

```
tracebox_pid=10744
DONE size_bytes=7024848
CAPTURE_RC=0
```

- `cpu.status = DONE size_bytes=7024848`，非 `TIMEOUT_STOPPED`、非 `EMPTY`；主机侧耗时 57 s。
- 采集前后：`uptime 46289.87 → 46346.49`；`requests.jsonl` 行数 `4589 → 5123`（窗口内 522 条请求可对齐）。
- 注：采集后板端自身在 ~03:10 轮转了日志（现 `requests.jsonl` 只剩 2563 行、另有 `.1`）；窗口证据已在本目录 `requests-after.jsonl`（5139 行）中留存，不影响分析。
- TP 内置 `stats` 表 468 行，**所有 value=0**（无 buffer 覆盖/丢弃告警）。`linux.perf` 无丢样本标记。

### 4.3 拉回与完整性

```
PULL OK: cpu.pftrace    size=7024848    sha256=07f5596ecd9b1ff6fbeafde3a559b41011213dea35393d146b89f17f52da527a
PULL OK: cpu.log        size=43
PULL OK: cpu.status     size=24
PULL OK: cpu.pid        size=6
```

### 4.4 Trace 基本信息与时钟对齐

| 项 | 值 |
|---|---|
| `trace_bounds` | `46290515351739 … 46345505419807` ns，**54.99 s** |
| 时钟 | boot ≈ monotonic（板端无 suspend）：trace 起点 46290.515 s ≈ 采集前 `uptime 46289.87 s` + SSH 启动延迟 |
| 目标 UPID | **3**（`/userdata/cpu-lab/bin/task-service`，pid 10285） |
| 线程 | 9 条全部出现在 trace 中 |
| CPU 计数器轨道 | `cpufreq`×8、`cpuidle`×8 |
| perf 样本 | **44,000** 条（=100 Hz×8 CPU×55 s）；其中 **600** 条归属 task-service 且**全部有调用栈**，另有 43,092 条为 idle swapper（无栈，符合预期） |
| 符号 | task-service mapping `build_id=7cd00d399205f0a9f67ea31f2d8d382fafabf15f`；trace 内 `interned_data.function_names` 已含函数名；`stack_profile_frame` 140 帧中 129 帧有名（如 `ts_mix_block`、`ts_compute_until`、`_ZL16flag_waiter_mainPv`）。机制：板端 libunwindstack 在 unwind 时用 `/proc/<pid>/maps` 的 ELF 解析函数名并写入 trace，所以**主机不需要本地 ELF**；少数 libc/PLT 帧无名为 `[unsym]`，未虚构成函数名。 |
| 观测开销（须披露） | 采集器自身 **2751.8 ms** CPU / 55 s（tracebox 2662.4 + stack-unwinding 89.4）：CPU3 1896.6 ms、CPU5 390.9 ms、**CPU6 256.7 ms**、CPU2 104 ms、CPU1 89.4 ms、CPU7 14.1 ms。服务被限制在 CPU6–7，故仅在 CPU6 上产生 0.5% 级干扰；此为采样+写盘开销，因果结论已用不含该开销的 sched/业务日志交叉验证。 |

对齐验证（用业务日志 `st/en` 与 `sched_slice` 互证）：92.81 ms 的慢请求窗口内 `req-worker` 只有 0.11 ms Running；13.4 µs 的快请求窗口内切片完全覆盖 —— 说明日志时间戳与 trace 时间轴可直接对应（无额外偏移）。

---

## 5. 分析结果（Skill SQL + 追加查询）

> 所有 SQL 与输出见 `sql-run/`、`q-*.sql`、`out/`。`sql-run/*.sql` 是 Skill `sql/01..08` 的副本，仅把 `target_upid` 从 -1 换成实测 **3**。

### 5.1 Inventory（`sql-run/00`，逐条执行）

| upid | 进程 | running_slices | cpu_ms |
|---|---|---|---|
| 0 | swapper（idle） | 46,597 | 426,849 |
| **3** | **task-service** | **43,282** | **6,555.55** |
| 2 / 1 / 187 | tracebox（观测开销） | 246 / 1,276 / 508 | 2,011 / 565 / 176 |
| 90 | sugov:0 | 368 | 26.66 |
| 15 | rcu_preempt | 829 | 26.11 |

线程状态汇总（全 trace，所有进程）：`Running 48,557`、`R 48,332`、`S 46,124`、`I 1,497`、`D 429`、`R+ 146`、`Z 54`。

### 5.2 每个线程在忙什么 / 在等什么（`sql-run/01`、`02`）

| 线程 | CPU ms | Running 最长 | Runnable(R/R+) | Sleeping(S) | 最长 S |
|---|---|---|---|---|---|
| sync-waiter | **1513.0** | 100.0 ms | 249 ms | 52,863 ms | 10.1 ms |
| req-worker | **1423.5** | 20.1 ms | **1330 ms（最长 26.2 ms）** | 51,792 ms | **91.7 ms** |
| calc-worker | 1188.4 | **250.1 ms** | 206 ms | 53,225 ms | 10.1 ms |
| job-beta | 773.4 | 13.1 ms | **1429 ms（最长 20.0 ms）** | 52,419 ms | 20.1 ms |
| job-alpha | 761.9 | 13.4 ms | **1425 ms（最长 32.2 ms）** | 52,434 ms | 20.1 ms |
| req-dispatch | 354.8 | 0.2 ms | 403 ms | 53,868 ms | 10.1 ms |
| sync-publisher | 229.9 | 0.1 ms | 254 ms | 54,142 ms | 10.1 ms |
| hold-helper | 190.1 | 0.2 ms | 213 ms | 54,218 ms | 10.1 ms |
| controller | 120.7 | 4.7 ms | 103 ms | 54,385 ms | 20.1 ms |

- **没有任何 `D`（不可中断）区间**：`thread_state` 中服务 9 线程 D 状态条数 = 0 → 不是 I/O/内核不可中断等待。
- `sched_slice` 的 Runnable 清单（`sql-run/03`，>1 ms）头部全部是 `job-alpha/job-beta/req-worker` 的 20–32 ms 等待——但要判断"等的是谁"，必须看同核占用（§5.5），不能只看数字。
- 单线程 CPU ms 与 % 分母不同：`sync-waiter` 1513 ms 是 55 s 内的 CPU 时间，= 2.75% 单核，不是 1513%。

### 5.3 热点函数（`sql-run/07` + 自建按线程调用树）

`sql-run/07`（叶子帧 Top，按样本数）显示前几名均为 `ts_mix_block`（req-worker 38/30/18/18/14、calc-worker 31/23/17/14、job-alpha 25/16/14、job-beta 23/11/10）与 `sync-waiter` 的 `_ZL16flag_waiter_mainPv`。

按线程重建调用树（`q-pf/q-cs/q-fr`，`analysis` 见 `out/q-*.csv`）：

```
req-worker (135 samples)   self: ts_mix_block=118, finish_task_switch=6, [unsym]=3
  incl: req_worker_main > ts_compute_cpu_budget > ts_mix_block=118 | pthread_cond_clockwait=14
calc-worker (114)          self: ts_mix_block=99
  incl: calc_worker_main > ts_compute_until > ts_mix_block=100 | sleep_for>nanosleep=13
job-alpha/beta (69/74)     self: ts_mix_block=67 / 67
  incl: compete_main > ts_compute_until > ts_mix_block=67
sync-waiter (152)          self: flag_waiter_main=114, ts_spin_pause=14
  incl: flag_waiter_main > sleep_until_watch/clock_nanosleep=22（其余为自旋）
hold-helper (14)           self: finish_task_switch=7 ...  incl: hold_helper_main > sleep_for
req-dispatch (14)          incl: producer_main > sleep_until（几乎全在睡）
controller (6)             incl: main > snapshot_proc > read_task_stat（读 /proc 快照）
```

要点：
- **请求线程的 CPU 是纯用户态计算**（`ts_mix_block`），不是锁自旋、不是系统调用、不是缺页；`ts_compute_cpu_budget` 的命名与 10.00 ms 整片现象一致，指向"按时间预算干活"的实现（此为由命名+切片形态的**推断**，非源码证明）。
- **采样 ≠ 精确 CPU 时间**：600 个样本×~10 ms ≈ 6.0 s，与 sched 口径的 6.56 s 基本吻合；但样本数不能当成函数执行次数。

### 5.4 请求延迟分类与时间轴（业务日志 × trace）

522 条请求按 `en`−`st` 分档，并用 trace 拆解 `req-worker` 在 `[st,en]` 内的状态：

| 类别 | n | 平均延迟 | Running | Runnable | Sleeping |
|---|---|---|---|---|---|
| A 快 (<0.1 ms) | 369 | 0.01 ms | 0.01 ms | 0 | 0 |
| B 降级 (1–5 ms) | 46 | 2.16 ms | **2.15 ms** | 0 | 0 |
| C 差 (5–50 ms) | 91 | 21.95 ms | 12.06 ms | 9.89 ms | 0 |
| D 严重 (>50 ms) | 16 | 72.46 ms | 6.09 ms | 20.05 ms | 46.33 ms |

→ **B 类纯 CPU 工作量**、**C 类 CPU+排 runnable**、**D 类一半是阻塞睡眠**；三类机制不同，不能混为一谈。

按 `service.log` 的 `slot` 事件切相位（每个 8 s，周期 48 s；相位边界误差 <0.03 s）：

| slot | 区间(s) | n | 中位数 | 最大 | req-worker | calc-worker | job-alpha | job-beta | sync-waiter |
|---|---|---|---|---|---|---|---|---|---|
| idx4 | -2.24…5.77 | 58 | 13.8 µs | 18.7 µs | 14 ms | 18 ms | 9 ms | 10 ms | **530 ms** |
| idx5 | 5.77…13.78 | 40 | **2249 µs** | 2306 µs | 105 ms | 30 ms | 15 ms | 15 ms | 31 ms |
| idx0 | 13.78…21.77 | 80 | 15.2 µs | 158.7 µs | 22 ms | 33 ms | 15 ms | 15 ms | 31 ms |
| idx1 | 21.77…29.76 | 80 | 14.1 µs | 18.1 µs | 21 ms | **1024 ms** | 13 ms | 14 ms | 29 ms |
| **idx2** | 29.76…37.77 | 98 | **32.0 ms** | **52.1 ms** | **1192 ms** | 22 ms | **677 ms** | **688 ms** | 22 ms |
| **idx3** | 37.77…45.76 | 80 | 15.4 µs | **92.9 ms** | 35 ms | 30 ms | 15 ms | 15 ms | 30 ms |
| idx4 | 45.76…53.77 | 80 | 13.9 µs | 17.0 µs | 22 ms | 27 ms | 15 ms | 15 ms | **836 ms** |
| idx5 | 53.77…60 | 6 | 2263 µs | 2279 µs | 14 ms | 4 ms | 2 ms | 2 ms | 5 ms |

CPU 尖峰（`sql-run/06`，阈值 100 ms CPU/1 s 桶）：`0–4 s`（131 ms/s，sync-waiter）、`22/24/26 s`（276 ms/s，calc-worker）、**`28–36 s`（均值 329、峰值 418 ms/s，idx2 竞争）**、`45–52 s`（134 ms/s，sync-waiter）。

### 5.5 两种慢模式的逐事件证据

#### (A) idx2：52.06 ms —— CPU6 被三个线程挤满，CPU7 空闲

以 `id=12546` 为例（`t_rel=29.91 s`，52.06 ms），该窗口内 CPU6 上非 idle 占用 **100.0%**、CPU7 **0.6%**：

```
cpu6 req-worker  rel=-8.526 ms dur=10.001   （窗口内 1.5 ms）
cpu6 job-alpha   rel= 1.475 ms dur= 9.997
cpu6 job-beta    rel=11.472 ms dur= 9.999
cpu6 req-worker  rel=21.471 ms dur=10.000
cpu6 job-alpha   rel=31.471 ms dur=10.002
cpu6 job-beta    rel=41.473 ms dur=10.007
cpu7 仅 8–15 µs 级唤醒（req-dispatch/hold-helper/sync-publisher/sync-waiter/controller/calc-worker）
```

`req-worker` 的状态序列：`Running 1.5 ms → R 20.0 ms → Running 10.0 ms → R 20.0 ms → Running 0.6 ms`（窗口内 Running 12.06 ms / Runnable 40.01 ms）。**它的每一次 Runnable 等待，正好落在 `job-alpha`/`job-beta` 各 10 ms 的片里**。

- 8 个 52.06 ms 请求全部同型（`id=12546/12551/12568/12573/12593/12598/12618/12623`），CPU6 均 100%、CPU7 均 <1%。
- 请求处理本身在该相位也变重（每请求约占 3 个 10 ms 片），叠加 10 ms 轮转 → 32 ms/52 ms 两档；`requests.jsonl` 的 `qw_us` 在同期涨到 **155 ms**（队列堆积），与此一致。
- 8 个调度片全部恰好 **10.00 ms**：形态上更像应用层按时间预算让出（`ts_compute_cpu_budget`），而不是 CFS 默认量子；`sched_waking` 的 `prio=120` 说明是 SCHED_OTHER，不是 RR。**此归因标记为推断。**

#### (B) idx3：92.8 ms —— 条件变量阻塞，等待被 `hold-helper` 结束

以 `id=12644` 为例（`t_rel=38.30 s`，92.81 ms）：

```
req-worker: Running 0.07 ms → S 91.57 ms → Running 0.05 ms → S 1.04 ms → Running 0.21 ms
窗口内 CPU6 非 idle 1.3%、CPU7 2.1%（只有各线程 35–40 µs 的周期性唤醒：
  hold-helper×18、req-dispatch、sync-publisher、sync-waiter、job-alpha/beta、calc-worker、controller）
```

- 8 个慢请求（38.30…45.30 s，**每秒恰好 1 个**，占请求相位 .8157 s）的 S 区间长度：`91.57/91.55/91.56/91.70/91.67/91.57/91.65/91.66 ms` —— **高度稳定的定长阻塞**，不是抖动。
- **唤醒者统计**（`sched_waking` 的 `pid=10289` + 当前运行线程判定）：全程 1081 次唤醒中 `swapper 620`、`req-dispatch 452`、**`hold-helper` 8 次**、`job-beta 1`。这 8 次 `hold-helper` 唤醒，与 8 个 91.6 ms 阻塞**一一对应**（例如 `req-worker` S 结束于 46328907404632 ns，唤醒者 = `hold-helper`）。
- `pthread_cond_clockwait` 出现在 `req-worker` 的 14 个采样栈里（`req_worker_main > pthread_cond_clockwait`）→ 阻塞点是**条件变量**，与 `hold-helper`（`hold_helper_main > sleep_for`，约 5 ms 轮询一次、每次 35–40 µs）配合。
- 因此这 92.8 ms **不是 CPU 不够、不是被抢占、不是频率**，而是**请求路径上等了一把被别的线程按 ~91.6 ms 持有的"hold"**。具体业务语义（谁在什么条件下 hold 多久）不在允许读取的材料范围内，标记 **UNKNOWN**。

### 5.6 跨核与迁移

- 服务 9 线程全部限定 CPU**6–7**；`req-worker` 探测时仅 CPU**6**。其余 6 核（0–5）与本服务无关。
- `sched_migrate_task` 共 **1424** 次（55 s）：`sync-waiter 262 / sync-publisher 250 / calc-worker 175 / req-dispatch 172 / hold-helper 156 / req-worker 134 / job-beta 102 / job-alpha 90 / controller 83`。即平均 ~25.9 次/s，远高于业务日志 `aff_moves≈4/s` —— 说明这些事件主要是**唤醒安置**（睡眠线程在另一核被唤醒）而非单独 `sched_setaffinity`；两者共同造成"同一线程在两核间来回跑"。
- 结果是：虽然允许 2 核，**实际负载严重偏斜**——`req-worker` 93% CPU 在 CPU6；`job-alpha/job-beta` 也主要落 CPU6（717/728 ms vs 44/46 ms）。idx2 时三者在 CPU6 上串行、CPU7 空转。
- 迁移本身没在时间上造成额外的长 R 段（R 段与"另一线程 10 ms 片"一一对应），所以**不是迁移导致延迟**；但**亲和性上限=2 核 + 负载偏斜**是容量瓶颈的结构原因。

### 5.7 CPU 频率 / Idle / 温度

- 频率轨道共 479 点/CPU（变化事件 + 500 ms 轮询），取值 `300 / 600 / 1200 / 1500 MHz`，`schedutil`，单 policy（CPU0–7）。`power/cpu_frequency` 是**变化事件**，空档不代表 0；初始值来自 `linux.sys_stats` 轮询。
- **idx2 饱和窗口**（29.986 s）：CPU6/7 实测 **1500 MHz（最高）** → 不是降频。
- **idx3 阻塞窗口**：两核在 300 MHz（因为几乎全程 idle）——但线程是 Sleeping，频率与之无关。
- per-second 频率层（CPU6）：idx2/idle 相位都出现过 300/600/1200/1500 混合，短时 300 MHz 出现在空闲退出前，不能当成"降频导致慢"。
- Idle：CPU6 在 55 s 中 idle 49.36 s（**89.8%**）、CPU7 idle 53.0 s（**96.4%**）；`cpuidle` 计数器为 `4294967295`（=离开 idle）与 `1`（idle）两种值，CPU6/7 的进入/退出次数（23,949/28,114）显著高于其它核（~6,500），与"服务线程在 6/7 上频繁唤醒"一致。
- 温度 54.6 °C，无 throttling 迹象。
- 结论：**频率/Idle 数据可以解释"为什么整机看起来不忙"（大量 300 MHz + idle），但不能解释延迟的量级**。

---

## 6. 证据等级（按 Skill 质量口径分别判定）

| 层级 | 判定 | 依据 |
|---|---|---|
| 1 Schema | **UNKNOWN** | 仅用 v58.2 descriptor 解析通过；板端采集器 v57.1，版本不匹配，不冒充 collector-matching PASS |
| 2 Runtime | **PASS** | tracebox 启动/退出正常、`DONE`、ftrace 事件真实存在、`linux.perf` producer 可用（44,000 样本）、无 sysctl 改动 |
| 3 Data | **PASS** | `trace_bounds` 54.99 s；UPID 3；`sched_slice 43,282`；`thread_state` 含 Running/R/R+/S（无 D）；`cpufreq`/`cpuidle` 每 CPU 有数据；`perf_sample` 44,000（600 带栈、0 丢）；`stats` 全 0 |
| 4 Analysis | **PASS（本机 SQL/TP 复算）**；**UI_UNKNOWN** | 所有数字可由 `sql-run/` + `analysis.py` 复现；**未做 Perfetto UI 操作/截图**（见 §8 手动步骤），不虚构截图 |
| 业务语义（hold 的具体条件与时长来源） | **UNKNOWN** | 需业务打点/源码，超出本轮允许材料；trace 只能证明"等 condvar ~91.6 ms、由 hold-helper 唤醒" |

---

## 7. 局限与最小下一步

1. **未做第二次采集**：首轮 55 s 已覆盖完整 48 s 相位周期且两类慢模式各有 8 个样本，证据足够，故不补采（Skill 的"最小充分证据"原则）。
2. **观测开销**：采集器自身 2751.8 ms CPU（CPU3 1896.6 ms，CPU6 256.7 ms），`linux.perf` 100 Hz unwind 有一定扰动；因果结论主要依赖 sched/业务日志（无 perf 也可成立），但严格 A/B 对照需另抓一次不带 perf 的 trace。
3. **无法区分"应用把亲和性临时设为 6"还是"负载均衡没拉走"**：trace 缺少 `sched_setaffinity` 语义（内核无该 tracepoint）；只能看到结果（CPU6 100%、CPU7 空闲）。
4. **10.00 ms 整片归因**为推断；要坐实需应用侧打点或 `raw_syscalls` 的 `sched_yield` 证据。
5. 可选最小下一步（都 ≤60 s，且不改系统/服务）：
   - 只补 `sched/sched_switch + raw_syscalls/sys_enter_sched_setaffinity` 的 60 s trace → 证明 idx2 期间的亲和性变更；
   - 或只补不带 perf 的 60 s sched trace → 排除采样扰动（预计结论不变）。

---

## 8. 手动 Perfetto UI 查看步骤（本轮未做 UI 自动化 → UI_UNKNOWN）

1. 打开 <https://ui.perfetto.dev/> → **Open trace file** → 选择 `cpu-task-service-diag/cpu.pftrace`（7,024,848 B）。
2. 左侧 `CPU 0…7` → 展开 `CPU 6`、`CPU 7`：
   - 定位 **29.9 s** 附近：可见 `req-worker` / `job-alpha` / `job-beta` 各 10 ms 交替占满 CPU6，CPU7 基本空；对齐 `CPU Frequency` 轨道为 1500 MHz。
   - 定位 **38.3 s … 45.3 s**：`req-worker` 轨道上每秒一次 ~92 ms 的 `Sleeping` 长条，期间 CPU6/7 仅零星 30–40 µs 短条。
3. 进程轨道 `task-service (10285)` → 展开 9 个线程 → 打开 **Thread state**，按状态筛 `Running` / `R` / `S`（本次实测无 `D`）。
4. **CPU Frequency / Idle** 轨道：确认频率在 300/600/1200/1500 间变化，且阻塞窗口对应 300 MHz（因空闲）。
5. **Perf Samples** → 选中 `task-service` → **Flamegraph**：可见 `req_worker_main → ts_compute_cpu_budget → ts_mix_block`、`calc_worker_main → ts_compute_until → ts_mix_block`、`flag_waiter_main`。
6. **Query (SQL)**：粘贴 `sql-run/01-cpu-usage.sql`（已把 `target_upid` 设为 3）→ Run；再试 `02/03/05/06/07/08`。
7. 可选：把 `service.log` 的 `slot` 时间（每 8 s，周期 48 s）与时间轴对照，即可看到"slot 相位 → 慢模式"的对应关系。

---

## 9. 交付物清单

| 文件 | 说明 | sha256/大小 |
|---|---|---|
| `cpu.pftrace` | **实际采集的 trace**（55 s，sched+freq+idle+perf） | 7,024,848 B / `07f5596e…52a527a` |
| `cpu-combined.pbtxt` | **实际下发配置**（含偏离理由注释） | 2,123 B / `1b32ec14…e497df2` |
| `cfg-overview.pbtxt` `cfg-scheduling.pbtxt` `cfg-frequency.pbtxt` `cfg-profiling.pbtxt` | 用板端真实事件生成的 4 条路线模板（`make_config.py` rc=0） | 见 `manifest-sha256.txt` |
| `available_events.txt` | 板端 `survey.sh --events` 原样输出（1170 行） | — |
| `sql-run/01-cpu-usage.sql` … `08-core-busy.sql` + `q00-0..4.sql` + `00-inventory.sql` | Skill SQL 副本（`target_upid=3`；`00` 因 TP 单语句限制拆成 5 条执行） | — |
| `q-*.sql` + `out/*.csv` `out/*.txt` | 追加查询与原始结果（slices/states/cpufreq/cpuidle/栈/逐请求分析） | — |
| `analysis.py` + `out/analysis-summary.txt` | **可复现**的关联分析（分类、窗口、相位、频率） | — |
| `export_data.sh` | 从 trace 重新导出分析表的脚本 | — |
| `requests-after.jsonl`、`service-after.log` | 采集窗口内的业务日志（对齐用） | — |
| `commands-and-queries.md` | 全部上板命令、SQL、判读口径（首轮工具调用记录） | 见 manifest |
| `skill-hashes.txt` | 实际加载 Skill 的版本与哈希 | 见 manifest |
| `manifest-sha256.txt` | 全部交付物 sha256 清单（50 行） | — |
| `capture-console.txt` `capture-mark-before.txt` `cpu.log` `cpu.status` `cpu.pid` `pull.txt` | 采集过程原始凭据（含 host_pull 失败记录） | — |
