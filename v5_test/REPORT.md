# X5 `sched-case-daemon` 调度 / 同步等待诊断报告

- 诊断对象：RDK X5 上常驻 C++ 服务 `sched-case-daemon`（PID 977，helper `sched-case-helper` PID 987）
- 使用 Skill：`perfetto-scheduling-debugging` **v0.1.0 Candidate**
- Skill 实际路径：`/root/.dsh/skills/perfetto-scheduling-debugging`
- 采集器：`/userdata/cpu-lab/perfetto-session/tracebox` = **Perfetto v57.1-c59f57dd4**
- Trace Processor：`/root/.cache/perfetto-skill/trace_processor_shell` = **Perfetto v57.1-c59f57dd4**（RPC API 14）
- 结论分级：**E1 = 线程状态事实；E2 = 事件/唤醒关联；E3 = 机制归因**。E2 不自动升级为 E3；无法验证的机制保留 **UNKNOWN**。

---

## 0. 一句话结论

> 该服务的慢请求分成两个**完全不同**的时间去向：
> ① “约 10 ms 的请求”时间几乎全部消耗在 **Running（本线程占 CPU 执行）**；
> ② “16–34.5 ms 的等待”时间几乎全部消耗在 **Runnable（已唤醒但抢不到 CPU 2）**，而不是锁、不是阻塞、也不是请求排队。
> 直接原因是 **CPU 2 上只有 3 个线程在跑（req-dispatch、compute-1、compute-2，同一进程、同一亲和性 2），突发窗口内三者合计占用 CPU 2 约 90%**，调度器以 ~10 ms 量级的时间片轮转，`req-dispatch` 每次被主线程唤醒后要排队 16–34.5 ms 才能上 CPU。
> 阻塞/唤醒路径可以定位到调用栈：`dispatch_entry()→syscall(futex)` 处停下，由主线程 `enqueue_request()→syscall(futex)` 唤醒（E2）。
> 服务与 helper 之间确有跨进程唤醒，并且都在 futex syscall 内部完成（E2）；但**锁持有者、futex 地址、10 ms 内具体在算什么** = **UNKNOWN**（本采集未覆盖）。

---

## 1. Skill 与环境核验（先确认再动板）

| 项 | 结果 |
|---|---|
| Skill 路径 / 版本 | `/root/.dsh/skills/perfetto-scheduling-debugging`；`SKILL.md` 标注 `v0.1.0 Candidate`；`MANIFEST.json` version=0.1.0 status=candidate |
| 资源完整性 | `python3 scripts/verify_package.py` → `PACKAGE_PASS version=0.1.0 status=candidate hashes=54 resources=44` |
| 本机自检 | `python3 -m unittest discover -s tests` → `Ran 59 tests ... OK (skipped=1)`；跳过项为 `test_real_inventory_queries`（需真实 TP/trace，本次用真机 trace 另行覆盖） |
| 板卡 | `Linux buildroot 6.1.83-DR-PL5.1_V1.0.20 aarch64`，`cpu online = 0-7`（8 核），tracefs=`/sys/kernel/debug/tracing` |
| tracefs 事件能力 | `sched/sched_switch`、`sched/sched_waking`、`sched/sched_wakeup_new`、`sched/sched_process_exit`、`raw_syscalls/sys_enter|sys_exit` 均可用（`survey.sh --events` 共 1170 行，见 `data/available_events.txt`） |
| 采集权限 | root；采集前 `perf_event_paranoid=2`、`kptr_restrict=0`、`tracing_on=1` 且 `events/enable=0`（未占用他人 tracing） |
| 页大小 | 4 KiB（格式文件 `offset/size` 与 ring 预算按 4 KiB 规划） |

### 1.1 目标身份（重要：与 RUNNING_BRIEF 不一致的地方）

运行简报记录 PID 3471，但现场板卡在上一次交接后**重启过**，服务由 autostart 重新拉起，PID/TID 全部变化。**未沿用简报 TID，全部从 `/proc` 重新读取**：

| 角色 | TGID | TID | 线程名 | 亲和性 |
|---|---|---|---|---|
| 主线程（生产者/编排） | 977 | 977 | `sched-case-daem` | 1-2 |
| 请求派发 | 977 | **988** | `req-dispatch` | **2** |
| compute-1 / compute-2 | 977 | 994 / 995 | `compute-1/2` | **2** |
| worker-one/two、stage-one/two/three、ipc-client、echo-one、timer-one、decoy-one | 977 | 989–993、996–999 | 同名 | 1 |
| helper（跨进程） | 987 | 987 | `sched-case-help` | 1-2 |

> 环境中**另有一个与本案无关的常驻进程** `/userdata/cpu-lab/bin/task-service`（PID 1012），其线程亲和性为 **6-7**。已核验它在整个采集窗口内**没有**在 CPU 1/CPU 2 上运行（`03-cpu-competitors` 结果中不存在），因此不作为本目标的 CPU 竞争者，也不参与结论。

---

## 2. 现象、相位与时钟对齐

### 2.1 业务日志（`/userdata/sched-case/logs/service.log`）

实例起点（重启后）：`{"t":"info",...,"pid":977,"mono_ns":5738359127,...}`。当前实例已记录 **11 个完整 cycle（178 行，第 12 周期仍在进行）**；其中可见 **12 个“突发簇”**（每 60 s 一次，首簇在第 9 s，末簇 669 s 属进行中的第 12 周期），结构完全一致：

| 簇起点(相对) | 请求数 | 簇跨度 | 3 个重请求 `dur_us` | 3 个等待请求 `wait_us` | 请求间睡眠间隔(ms) |
|---|---|---|---|---|---|
| 9 s（首簇，日志起点截断 1 条等待） | 5 | 113.8 ms | 10016 / 10011 / 10006 | 20266 / 17217 | 0.71, 20.43, 41.53, 0.65 |
| 69 s | 6 | 114.0 ms | 10013 / 10012 / 10007 | 34559 / 18177 / 16836 | 0.93, 6.29, 0.76, 22.44, 0.67 |
| 129 s | 6 | 114.4 ms | 10011 / 10013 / 10005 | 34531 / 17986 / 16491 | 0.84, 6.53, 0.78, 22.77, 0.68 |
| 189 s | 6 | 114.3 ms | 10017 / 10013 / 10007 | 34563 / 18094 / 16520 | 0.98, 6.23, 0.80, 22.74, 0.67 |
| …（共 12 簇，全部同构） | | ~114 ms | ≈10.01 ms | 34.4–34.6 / 18.0–18.3 / 16.1–17.0 ms | 同构 |
| 429 s | 6 | 114.7 ms | 10014 / 10010 / 10007 | 34488 / 17572 / 16090 | 1.18, 6.43, 0.89, 23.05, 0.77 |

完整 12 簇见 `logs/12-cycle-summary.txt`。**本次 trace 恰好覆盖 429 s 那一簇**（boot 436.039–436.170 s）。

### 2.2 时钟对齐（E1 前置条件）

- `settings`：Perfetto 采集时把 ftrace `trace_clock` 设为 **`boot`**（采集后读回 `... mono mono_raw [boot] tai`），trace 时间域 = `CLOCK_BOOTTIME`。
- TraceProcessor `clock_snapshot`：`BOOTTIME 416803969906 ↔ MONOTONIC 416803970531`，即 **boot − mono = −625 ns**，与业务日志每行 `boot_ns − mono_ns = +333…+417 ns` 在同一量级（采样瞬间不同）。
- trace_bounds = `175.900073625 → 235.424667403 s`，与采集瞬间 `/proc/uptime`（175.05 起、235.88 止）吻合，确认 trace ts 是 boot 时间。
- 结论：业务日志的 `mono_ns/boot_ns` 与 trace ts 可同域换算；日志仅用于**请求边界交叉核对**，所有状态/事件关联都在 trace 内部完成。

---

## 3. 采集方案（两次：一次主采集 + 一次定向补采）

### 3.1 主采集 C1（低开销、只调度数据）

- 配置：`configs/overview.pbtxt`（`make_config.py overview --cpu-count 8 --duration-ms 60000 --trace-buffer-kib 16384`）
- 数据源：`linux.ftrace`（`sched_switch`、`sched_waking`、`sched_wakeup_new`、`sched_process_exit`；ftrace buffer 512 KiB/CPU；drain 100 ms）+ `linux.process_stats`；**无 perf**
- 校验：`RESOURCES_PASS` + `POLICY_PASS` + **`SCHEMA_PASS`（官方 v57.1 trace_config descriptor；descriptor 由公开 `v57.1` tag 的 protos + protoc 3.12.4 生成，元数据见 `configs/trace_config.desc.meta.json`；残留风险：collector 自报 `v57.1-c59f57dd4`，与 tag 是否同一 commit 未独立证明）**
- 产物：`traces/cap1-overview.pftrace`（1,856,154 B，59.52 s，collector rc=0，timeout=0，forced_kill=0）
- 数据量：`sched_switch 109,908`、`sched_waking 55,539`、`sched_wakeup_new 239`、`sched_process_exit 239`

### 3.2 定向补采 C2（有过滤的事件调用栈 + futex syscall）

补采前写下的**未决问题**：`req-dispatch` 每次被主线程唤醒后要等 16–34.5 ms 才上 CPU；需要知道 (a) 它**在何处停下**、由**谁/从哪条路径唤醒**，(b) 等待是否发生在 futex/lock 上。

- 配置：`configs/block-wake.pbtxt`（`make_config.py block-wake --tid 977 --tid 987 --tid 988 --tid 994 --tid 995 --tid 996 --with-futex --page-size 4096 --duration-ms 60000`）
  - 两路 `linux.perf`：`sched/sched_switch filter "prev_pid == {977,987,988,994,995,996}"`、`sched/sched_waking filter "pid == {…}"`，`period: 1`，`PERF_CLOCK_MONOTONIC`，`callstack_sampling kernel_frames:false`，ring 64×4 KiB
  - `linux.ftrace` 追加 `raw_syscalls/sys_enter|sys_exit` + `syscall_events: "sys_futex"`
  - **没有**全系统无过滤抓栈；没有 perf scope 过滤（保留跨进程唤醒者）
- 校验：`RESOURCES_PASS` + `POLICY_PASS` + **`SCHEMA_PASS`（同上 descriptor）**
- 产物：`traces/cap2-blockwake.pftrace`（2,750,785 B，59.86 s，collector rc=0）
- 数据量：perf session **0 = `scheduling.waking`**（3109 样本 / 71 带栈 / 3 unwind 错误）、session **1 = `scheduling.switch`**（2344 样本 / 2344 带栈 / 0 unwind 错误）；`sys_futex` slice 6984 条
- **样本流来源不是按配置顺序猜的**：`08-perf-streams.sql` 给出两个 session，`08a-perf-tracks.sql` 给出 `perf_counter_track(name, perf_session_id)`：session 0 的轨道名是 `scheduling.waking`、session 1 是 `scheduling.switch`，两路都同时出现在 CPU1/CPU2，与配置一致后才置 `streams_verified=1`。

---

## 4. E1：线程状态事实（问题 1 / 问题 2）

### 4.1 突发窗口 W1（cap2：boot 436.039–436.171 s，132 ms）

`01-state-window.sql`（utid=2 = req-dispatch，**13/13 区间覆盖，无 UNKNOWN 缺口**）：

| 状态 | 时长 | 区间数 |
|---|---|---|
| **Runnable (R)** | **68.04 ms** | 6 |
| **Running** | **31.46 ms** | 6 |
| Sleeping (S) | 32.50 ms | 7 |

同一窗口内全部目标线程与 helper 的状态（下表为 **cap1**（无 perf，未受采集扰动）的突发窗口数值；cap2 同窗口下 `req-dispatch`/`compute-1`/`compute-2` 差异 ≤1 ms，主线程 Running 11.60→15.20 ms 属采集扰动与相位差异，见 `results/cap2/thread-state-burst`）：

| 线程 | Running | Runnable | Sleeping | 说明 |
|---|---|---|---|---|
| **req-dispatch (988)** | 30.68 ms | **69.26 ms** | 32.06 ms | 请求线程：R 占 52% |
| **compute-1 (994)** | 40.83 ms | 47.23 ms | 43.93 ms | 也在抢 CPU 2 |
| **compute-2 (995)** | 47.00 ms | 41.24 ms | 43.76 ms | 同上 |
| 主线程 (977) | 11.60 ms | 9.12 ms（406 次×22 µs） | 111.27 ms | 4 kHz 忙轮询相位 |
| helper (987) + stage/worker/ipc/echo/timer/decoy | 0.02–0.11 ms | 0.01–0.12 ms | ≈131.9 ms | 单次 500 ms 睡眠，未参与 |

**cap1 全 trace 对照**：req-dispatch 的 Runnable 总计 112.3 ms，其中 **69.3 ms（61.7%）集中在 W1 这 132 ms 内**（占 trace 时长 0.22%）。也就是说“明显等待”不是弥散在整段，而是集中在突发簇。

### 4.2 慢请求的时间去向（问题 2，逐请求分解）

业务边界来自日志（mono ns），状态来自 trace（boot ns）；同一请求 6 条独立边界核对一致。窗口内 6 个请求：

| 请求 id | 排队 enq→start | 其中 Sleeping(等唤醒) | 其中 Runnable | 处理 start→done | 其中 Running |
|---|---|---|---|---|---|
| 94 | 164 µs | 62 µs | 50 µs | **10.015 ms** | **10.016 ms** |
| 95 | **34.488 ms** | 28 µs | **34.374 ms** | 10 µs | 11 µs |
| 96 | 80 µs | 29 µs | 26 µs | **10.011 ms** | **10.012 ms** |
| 97 | **17.573 ms** | 25 µs | **17.515 ms** | 5 µs | 6 µs |
| 98 | 46 µs | 17 µs | 13 µs | **10.008 ms** | **10.009 ms** |
| 99 | **16.090 ms** | 14 µs | **16.058 ms** | 4 µs | 5 µs |

（表内剩余量 = 7–86 µs 的 Running “处理序言”，实测 `start_ns` 在进入 Running 之后 7–86 µs 才打点，见 `results/cap2/request-accounting/query.sql`。）

**结论（E1，PASS）**：

- “10 ms 级”请求：delay 的 **≥99.9% 是 Running**（本线程在 CPU 2 上执行），不是阻塞；
- “34.5 / 18 / 16 ms 级”请求：delay 的 **99.6–99.9% 是 Runnable**（已被主线程唤醒，但抢不到 CPU 2），睡眠只有 14–28 µs，**请求排队（enq→wake）也只有 14–90 µs**；
- 突发簇内 0.6–23 ms 的 Sleeping **是请求之间的空闲**（等下一次 futex 唤醒），不是慢的原因。

### 4.3 第二个等待窗口 W2（主线程，生产者侧）

cap2 中另有一处明显等待，**与 W1 不同源**：

| 线程 | 窗口 | 状态 | 时长 | 同核竞争者 |
|---|---|---|---|---|
| 主线程 (977) | 456.040166–456.060276 s | **R+（可运行被抢占）** | **20.109 ms** | stage-three Running 7.53+4.46 ms、stage-two 8.09 ms（均在 CPU 1） |
| stage-three (993) | 456.052382–456.060718 s | R+ | 8.336 ms | 被 stage-two 抢占 |

主线程在被抢占前的调用路径是 `run_one_cycle() → pthread_cond_signal()`（callsite 209/214），即**主线程自己唤醒了 stage 线程**，随后在 CPU 1 上被它们轮转挤出 20.1 ms。
**范围声明**：该窗口内日志没有任何请求（前后请求在 451.039 s / 461.039 s），因此**这条等待对请求延迟的贡献 = UNKNOWN**（不能把“主线程被拖住”直接算成请求变慢）。

---

## 5. 问题 3：谁占用了目标线程需要的 CPU

`03-cpu-competitors.sql`（**不按目标进程预筛**，统计该 CPU 上所有任务；tid=0 空闲已排除）：

**CPU 2，W1（132 ms）**

| 线程 | CPU 时间 | 占单核 |
|---|---|---|
| compute-2 (995) | 46.58 ms | **35.29%** |
| compute-1 (994) | 40.72 ms | **30.85%** |
| req-dispatch (988) | 31.46 ms | **23.83%** |
| （其余线程） | 0 | 0 |
| 合计非空闲 | ≈119 ms | **≈90%** |

（cap1 同窗口另有 `kworker/2:1` 0.17 ms，可忽略。）

**CPU 1，W1**：主线程 15.20 ms（11.5%），其余所有线程 ≤0.23 ms → **CPU 1 基本空闲**，不是瓶颈。

**E1/E3 判定**：占用 `req-dispatch` 所需 CPU 的就是同进程的 `compute-1`、`compute-2`（同一亲和性 `2`）。5 ms 桶时间线（`results/cap1/cpu2-timeline`，cap1）显示 CPU 2 在 W1 内被这三者以 ~10 ms 片轮转：
`req-dispatch 10.25 → compute-1 10.29 → compute-2 19.94 → compute-1 4.74 → req-dispatch 10.16 → compute-1 8.55 → compute-2 9.99 → compute-1 16.32 → req-dispatch 7.24 → compute-2 17.01 …`
这正是“请求线程没有明显消耗 CPU、请求却完不成”的直接机制：**它不在跑，它在等 CPU**。

---

## 6. 问题 4：停下位置的调用路径 + 唤醒上下文与调用栈（E2）

### 6.1 关联参数（先证明来源，再看结果）

- 身份：cap2 `utid=2` = tid 988 = `req-dispatch`（`00-threads.sql`）。
- 会话：`switch_session=1`（`scheduling.switch`）、`waking_session=0`（`scheduling.waking`）——由 `08a-perf-tracks.sql` 的 `perf_counter_track` 名称反查，不按配置顺序。
- 时间戳容差：**默认 0 匹配 = 0 条命中**。实测同一 `sched_switch` 的 perf 样本 ts 与 ftrace 事件 ts 存在 **16.8–111.4 µs（中位 85.2 µs）** 的工具侧偏差，且随时间稳定（6 个 10 s 桶中位数 83.9–87.2 µs）；`clock_snapshot` 显示 boot−mono 仅 −0.625 µs，**说明这不是时钟域差异**（产生该偏差的采集器内部机制 = UNKNOWN）。因此显式使用 `--tolerance-ns 150000`，并逐条核对唯一性：
  - switch 流：`tol=150 µs` → 1194/1200 唯一、6 缺失、**0 歧义**；
  - waking 流：76 个“真实线程执行”的样本，实测 `tol=50 µs` → 65 唯一 / 7 缺失 / 4 歧义；`tol=100 µs` → 68 / 2 / 6；`tol=200 µs` → 70 / 0 / 6（歧义处不取最近样本，直接报 `SAMPLE_AMBIGUOUS`）。

### 6.2 关联结果（`05-event-pair.sql`，burst 内全部 6 个等待）

| wait_id | 睡眠 | 其后 Runnable | switch_status | wake_status | switch 栈 | wake 栈 | 偏差(ns) |
|---|---|---|---|---|---|---|---|
| 60401 | 32.56 ms | 50.4 µs | **MATCH_UNIQUE** | **MATCH_UNIQUE** | cs 3 | **cs 164** | −83,958 / −34,167 |
| **60642** | **0.78 ms** | **34.374 ms** | **MATCH_UNIQUE** | SAMPLE_MISSING | cs 3 | — | −99,458 / — |
| 61093 | 6.33 ms | 25.5 µs | SAMPLE_MISSING | **MATCH_UNIQUE** | — | **cs 164** | — / −16,083 |
| 61257 | 0.659 ms | **17.515 ms** | **MATCH_UNIQUE** | SAMPLE_MISSING | cs 3 | — | −90,500 / — |
| 61509 | 22.91 ms | 13.4 µs | **MATCH_UNIQUE** | **MATCH_UNIQUE** | cs 3 | **cs 164** | −49,667 / −10,833 |
| 61896 | 0.631 ms | **16.058 ms** | **MATCH_UNIQUE** | SAMPLE_MISSING | cs 3 | — | −52,292 / — |

原始 id（可回到 trace 复核）：wait 60642 → 切出样本 `perf_sample id=1504`（session 1）、切出事件 `sched_switch id=64621`（prev=988，cpu2）、唤醒事件 `sched_waking id=64641`（pid=988，cpu1，执行 utid=1 主线程）；wait 60401 → 样本 1462 / 事件 64483 / 唤醒事件 64481 / 唤醒样本 1464；wait 61509 → 样本 1717 / 唤醒事件 65797 / 唤醒样本 1777。

### 6.3 调用栈（符号已解析，`06-callstack.sql`）

**停下位置（切出栈，callsite 3，1200/1200 样本同一栈）**

```
#0  syscall                              /usr/lib/libc.so.6
#1  dispatch_entry(void*)                sched-case-daemon  build_id b3cf4561…
#2..#3  (libc 线程启动帧，无符号名)
```

**唤醒者（唤醒栈，callsite 164）**

```
#0  syscall                              /usr/lib/libc.so.6
#1  enqueue_request(int)                 sched-case-daemon  build_id b3cf4561…
#2  run_one_cycle()                      sched-case-daemon
#3  main
```

**futex 侧证据（`09-futex-slices.sql` + slice 包含关系）**

- `req-dispatch`：60 s 内 1195 条 `sys_futex` slice；**6 次唤醒（436039309124 / 436050635082 / 436091560582 / 436102537416 / 436143152499 / 436153968291）全部落在主线程的 `sys_futex` slice 内部**（slice id 2205 / 2214 / 2233 / 2239 / 2252 / 2259）。
- 关键反例：wait 60642 对应的 futex slice `id=2210` `ts=436049705832 dur=35.349 ms`，而该 wait 的 Sleeping 只有 **0.78 ms**、其后的 Runnable 有 **34.374 ms**。**syscall 时长 ≠ 睡眠时长 ≠ 锁持有时间**；把“futex 35 ms”读成“锁等了 35 ms”是错的。

**E2 判定（PASS，但只到“事件+执行上下文+栈”）**：`req-dispatch` 在 `dispatch_entry()` 内的一个 `syscall`（futex）上停下；主线程在 `run_one_cycle() → enqueue_request()` 的 `sys_futex` 里把它唤醒。`waker ≠ 锁持有者`，唤醒 ≠ 业务条件成立。

### 6.4 第二大等待窗口 W2 的栈

- 主线程被抢占前：`run_one_cycle() → pthread_cond_signal()`（cs 209 / 214，374+ 样本），即唤醒 stage 线程；
- 主线程常规阻塞：`run_one_cycle() → isleep_ns(long) → clock_nanosleep()`（cs 10，574 样本），以及 `run_one_cycle() → wait_cmd(WI,long) → clock_nanosleep()`（cs 257/223）；
- **W2 抢占点的样本缺失**（该次 `sched_switch` 的样本属于 797 条丢样本之一）→ 该次“主线程停下位置”的具体栈 **UNKNOWN**。

---

## 7. 问题 5：跨进程唤醒、等待依赖与 futex

| 事实 | 证据 | 级别 |
|---|---|---|
| helper 的阻塞原语 | 切出栈 cs 15：`main → syscall`（futex）；60 s 内 122 条 `sys_futex` slice | E1/E2 |
| **helper → ipc-client 跨进程唤醒** | `sched_waking` @ **446044980795**（boot），pid=996，执行 utid=3（helper main，process context，`irq_context=0`）；该事件落在 helper 的 `sys_futex` slice `id=3414`（72.5 µs）内部；唤醒者栈 cs 203：`syscall ← main`（helper，build_id 7a0b5543…） | **E2 PASS** |
| 主线程 → helper 唤醒 | 2 条 process-context 边（977→987） | E2 PASS |
| 外部进程唤醒本服务 | **0 条**（全 trace 检查） | E1 |
| 进程内唤醒关系（cap1，195.5–197.5 s 窗口内计数） | 主线程 977 → {988 req-dispatch ×13, 989 ×4, 994 ×3, 995 ×3, 990/997 ×2, 991/992/993/996/998/999 ×1}；stage-three(993) → stage-two(992) ×2；stage-two(992) → stage-one(991) ×2；helper(987) → ipc-client(996) ×1；decoy-one(999) ← ipc-client(996) ×2 | E2 |
| 其它线程的等待原语 | `ipc-client`、`compute-1/2`：切出栈 `pthread_cond_timedwait`（cs 18 / 21，均 118–120 样本，10 ms/500 ms 周期） | E1/E2 |
| **futex 活动** | `sys_futex` slice 共 6984 条 / 19 个线程；`req-dispatch` 1195 条（≈全部空闲等待），`compute-1/2` 各 244 条，`helper` 122 条，`ipc-client` 240 条 | E1 |
| **锁地址 / 返回码 / 锁持有者** | **未采集**（无 futex 参数、无 syscall 返回值、`blocked_function` 列存在但全为 NULL） | **UNKNOWN** |

> 已在 `blocked_function` 列上做过尝试：该列存在，但本板卡内核在本 trace 中未提供值（全 NULL），因此**不能**从调度数据直接读出“阻塞在哪把锁/哪个内核函数”。

---

## 8. 问题 6：每种主要等待，证据能解释到什么程度

| # | 等待类型 | 观察事实（E1） | 事件/唤醒（E2） | 机制归因（E3） | 仍缺什么 |
|---|---|---|---|---|---|
| A | 请求线程 **Runnable 16–34.5 ms**（“没吃 CPU 但完不成”） | **PASS**：R 占 wait 的 99.6–99.9%，睡眠仅 14–28 µs | **PASS**：唤醒者 = 主线程，在 `enqueue_request()→sys_futex` 内完成（部分 wait 的唤醒栈样本缺失，已标 SAMPLE_MISSING） | **PASS（本条）**：CPU 2 上 compute-1/compute-2 + req-dispatch 三者 ~90% 占核，10 ms 片轮转；请求线程排在另外两者之后 | 为什么 compute 线程要占 10 ms —— **UNKNOWN** |
| B | 请求处理 **Running ≈10.0 ms** | **PASS**：线程确实在 CPU 2 上执行 10.0–10.5 ms | 与 A/B 无关 | **UNKNOWN**：是有效计算还是自旋/轮询，本采集无 CPU 时间采样、也没有该时段的抢占样本 | 需要 CPU 采样栈（本 Skill 的最小方案未包含） |
| C | 请求之间的 **Sleeping 0.6–23 ms** | **PASS**：全部落在 `dispatch_entry→syscall` 的 futex 上 | **PASS**：由主线程在下一个请求 enqueue 时唤醒 | **PASS（本义）**：等下一个请求，不是延迟来源 | — |
| D | 主线程 **R+ 20.1 ms**（W2，CPU 1） | **PASS** | 部分 PASS：主线程自己用 `pthread_cond_signal` 唤醒 stage 线程，随后被其抢占；该次切出样本丢失 | 机制（CPU 1 与 stage 线程争用）**PASS**；**对请求延迟的影响 UNKNOWN**（该窗口无请求） | 需要与请求到达关联的业务证据 |
| E | **futex / 锁** | **PASS**：确有大量 futex syscall | **PASS**：唤醒发生在 waker 的 futex syscall 内 | **UNKNOWN**：不知道 futex 地址、类型（MUTEX/COND/PRIVATE）、返回值、owner | 需要 syscall 参数/返回码与业务语义埋点 |
| F | 跨进程依赖 | **PASS**：helper↔daemon 双向唤醒，无外部进程唤醒本服务 | **PASS**：helper→ipc-client 在 helper 的 futex syscall 内，栈 `syscall←main` | **UNKNOWN**：这次跨进程交换在业务上做了什么、是否进入慢请求关键路径（本次突发窗口中未发生） | 需要 IPC 业务日志/协议标识 |

**一句话**：A 已经可以“机制级”解释（CPU 2 过度捆绑 + 同核竞争），B/E/F 停在“事实 + 事件”层，**不编造**。

---

## 9. 数据质量

| 项 | 实测 | 影响 |
|---|---|---|
| ftrace 数据丢失 | `compact_sched_switch_skipped=8`、`compact_sched_waking_skipped=7`（cap1/cap2 相同） | 规模很小；未观察到影响目标线程的边界一致性（`02` 中目标 wait 全部 COMPLETE） |
| traced 环形缓冲 | `traced_buf_bytes_written = bytes_read`（cap1 1,867,776；cap2 2,719,744），16 MiB buffer | **无环形溢出** |
| perf 丢样本 | `perf_cpu_lost_records = 724 + 73`、`perf_samples_skipped = 5` | switch 流逐个目标线程（`sched_switch prev_pid` 事件数 → perf 样本数）：977 **1438→659（约 54% 丢失）**、988 **1196→1200（计数近似 1:1）**、994 125→123、995 125→122、996 121→120、987 120→120。**“计数接近 1:1”不等于“每个切出点都有样本”**：`wait 61093` 的切出点（436085231374）就没有样本，因此 §6.2 逐条判定仍保留 `SAMPLE_MISSING`，不用全局计数去补单点缺失 |
| waking 流样本归属 | 3109 样本中 3033 归属 `swapper` 且无栈（定时器在 idle CPU 上唤醒，执行上下文是空闲任务） | 唤醒**事件**（谁、哪个 CPU、是否 IRQ）完整；唤醒**栈**只有 71 条真实线程样本 → 60642/61257/61896 的 wake_status = SAMPLE_MISSING |
| 时间戳偏差 | perf 样本相对同 tracepoint 的 ftrace 事件：switch 16.8–111.4 µs（中位 85.2 µs）、waking −29.1…+102.8 µs（中位 34.0 µs），时间上稳定 | 0 容差不可用；使用 150 µs 并验证唯一性（开关侧 0 歧义）。**偏差成因 UNKNOWN**，未用“最近时间戳”强行配对 |
| 时钟 | trace = BOOTTIME（`trace_clock=boot`）；`boot−mono = −0.625 µs`（ClockSnapshot） | 同域，可交叉核对 |
| `blocked_function` | 列存在，值为 NULL | 阻塞原语只能靠栈 + futex syscall 间接判定 |
| 业务日志 | 实例边界处有 NUL 填充（327 B）；板卡重启导致 PID 与简报不一致 | 解析时剥离 NUL；PID/TID 全部重新读取 |
| 环境干扰 | `task-service`（PID 1012，亲和性 6-7）常驻 | 已核验不在 CPU1/2，不影响竞争者统计 |

---

## 10. 采集开销

| 采集 | tracebox 线程合计 CPU / 60 s | 对目标的扰动 |
|---|---|---|
| C1（仅调度数据、无 perf） | ≈**1.63 s**（≈2.7% 单核） | 未做 A/B，仅作基线采集器开销记录 |
| C2（两路 perf 事件栈 + futex syscall） | ≈**3.22 s**（tracebox 1.84 s + 1.84 s 拆分项 + stack-unwinding 0.48 s 等，≈5.4% 单核，分散在多核） | **可测扰动**：`req-dispatch` 线程总 Running 从 86.3 ms（C1）升到 **213.1 ms**（C2），增量 ≈127 ms ≈ 1196 次切出 × ≈0.1 ms（每次事件栈采集的内核拷贝/展开代价记在被切出线程上）。**突发窗口内的绝对量几乎不变**（Running 30.68→31.46 ms，R 69.26→68.04 ms），所以 E1 的绝对 CPU 时间以 C1 为准，C2 只用于 E2 关联 |

trace 体积 1.86 MB / 2.75 MB；板卡 MemFree ≈1.0 GB；两次采集均 `RECORDED_DATA_UNCHECKED` + `collector_rc=0` + `timeout=0`（正常收尾，非 SIGKILL）。

---

## 11. 未覆盖的能力（明确写出来，不当作已排除）

1. **无 CPU 时间采样栈**：本 Skill 的最小方案只采调度 + 有过滤的事件栈，所以“10 ms Running 内部在算什么”= UNKNOWN。
2. **`kernel_frames:false`**：切出栈只有用户栈，看不到 `futex_wait`/`do_nanosleep` 等内核帧；内核侧阻塞路径未覆盖。
3. **futex 语义**：无 futex 地址、无 `FUTEX_WAIT/WAKE` 类型、无返回码、无 owner → 不能命名具体锁/条件变量。
4. **IRQ 上下文归属**：调度数据无法把 slice 内的 IRQ/软中断时间分离（本窗口 CPU2 无显著 ksoftirqd/kworker，但不能外推到其它时间）。
5. **W2 的请求影响**：该窗口无请求，无法量化。
6. **UI 自动化**：按要求未做；手工查看步骤见第 12 节。

---

## 12. 手动 Perfetto UI 查看步骤（对应实际 trace）

打开 `traces/cap2-blockwake.pftrace`（或 cap1）后：

1. **定位窗口**：搜索/缩放至 `436039–436171 ms`（cap1 对应 `196039–196171 ms`）。
2. **请求线程状态**：选 `req-dispatch` 线程轨，看 Thread State 的 **Runnable / Running / Sleeping** 三个状态名（不看颜色）：Runnable 段为 34.374 / 17.515 / 16.058 ms，Running 段为 10.49 / 10.29 / 10.17 ms。
3. **唤醒关系**：点 Runnable 段起始的 `sched_waking`（或状态详情里的 *Woken by*），确认 waker 是 `sched-case-daem`(977) 且 CPU=1；点它可看 `enqueue_request()` 的调用栈。
4. **CPU 轨道**：同时展开 CPU 1 / CPU 2 两条 CPU 轨。CPU 2 上应看到 `compute-2 → compute-1 → req-dispatch` 的 ~10 ms 交替；CPU 1 上基本只有主线程的 0.3 ms 周期小片。
5. **事件栈样本**：点击 `sched_switch` 的 perf 样本（切出侧）看 `dispatch_entry → syscall`；点击唤醒侧样本看 `enqueue_request → run_one_cycle → main`。
6. **futex**：在 `req-dispatch` 的线程轨上找 `sys_futex` slice，验证 slice 2210（35.349 ms）同时包含 0.78 ms 睡眠与 34.37 ms Runnable（即 syscall 时长 ≠ 睡眠）。
7. **辅助 Debug Track（可选）**：执行 `sql/01b-state-track.sql`，参数 `--utid 2 --start-ns 436039000000 --end-ns 436171000000`，渲染结果用 *Add debug track → Slice*（ts/dur/state，ns）。
8. **跨进程**：在 `sched-case-help`(987) 轨上找 446.045 s 附近的 `sys_futex`，其内部有对 `ipc-client`(996) 的 `sched_waking`。
9. **W2**：缩放到 `456040–456061 ms`，看主线程 R+ 20.1 ms 与 `stage-three`/`stage-two` 在 CPU 1 上的 Running。

> 说明：本报告没有实际打开 UI 做验收截图，UI 相关验收状态 = **UI_UNKNOWN**；上述步骤均指向 trace 内真实存在的对象/时间。

---

## 13. 复现（完整命令见 `COMMANDS.md`）

```sh
# 1) Skill 自检
cd /root/.dsh/skills/perfetto-scheduling-debugging
python3 scripts/verify_package.py
python3 -m unittest discover -s tests

# 2) 只读侦察
sh scripts/survey.sh report            # 在板上执行
sh scripts/survey.sh --events  > /tmp/events.txt
sh scripts/survey.sh --formats /tmp/fmts

# 3) 生成 + 校验配置
python3 scripts/make_config.py overview --cpu-count 8 --duration-ms 60000 \
  --events /tmp/events.txt --trace-buffer-kib 16384 --output overview.pbtxt
python3 scripts/validate_config.py overview.pbtxt --descriptor config.desc \
  --descriptor-metadata config.desc.json --collector-version v57.1-c59f57dd4

# 4) 板端采集（只管理本次采集子进程，不动业务）
TRACEBOX=/userdata/cpu-lab/perfetto-session/tracebox \
  sh record.sh overview.pbtxt /userdata/sched-diag/cap1 85

# 5) 拉回 + 查询
sh scripts/pull.sh root@<board> /userdata/sched-diag/cap1 cap1 trace.pftrace config.pbtxt status.txt
python3 scripts/run_query.py --tp <tp> --trace cap1/trace.pftrace \
  --sql sql/01-state-window.sql --out out/01 --utid 2 --start-ns 436039000000 --end-ns 436171000000
```

`run_query.py` 会保存实际执行的 SQL、stdout、stderr、退出码、trace/TP/SQL 的 SHA256（见 `results/*/run.json`）。

---

## 14. 文件清单

| 路径 | 内容 |
|---|---|
| `traces/cap1-overview.pftrace` | 主采集（仅调度数据，59.52 s） |
| `traces/cap2-blockwake.pftrace` | 定向采集（事件栈 + futex，59.86 s） |
| `configs/overview.pbtxt`、`configs/block-wake.pbtxt` | 实际使用的 TraceConfig |
| `configs/trace_config_v57.1.desc`、`configs/trace_config.desc.meta.json` | 官方 schema 校验用 descriptor + 出处/SHA256 元数据 |
| `logs/` | survey、线程清单、配置生成/校验、采集、拉回、schema、12 簇汇总、collector.log、status/exit |
| `results/cap1/<query>/`、`results/cap2/<query>/` | 每条 SQL 的实际输出 `stdout.csv`、`run.json`、渲染后的 `query.sql`（按 trace 分组） |
| `sql/` | Skill 自带 SQL + 本次自定义 SQL（含请求分解、跨进程唤醒边、perf/事件偏移统计） |
| `data/` | 业务日志、可用事件清单、sched_switch/sched_waking 事件 format |
| `COMMANDS.md` | 本次实际执行的命令（口令已脱敏） |
| `SHA256SUMS` | 全部交付文件哈希 |
