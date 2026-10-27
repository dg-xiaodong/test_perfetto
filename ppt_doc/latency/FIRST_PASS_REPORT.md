# FIRST_PASS_REPORT — `pf-lat-case` 周期性端到端时延升高（窗口 B 独立盲测）

- 版本/轮次：window B，first pass **rev3**（首轮盲测，未做对照实验、未取私有真值。rev2 修正 UI 跳转时间戳；rev3 修正『无队列深度 Counter』的错误结论，新增 §5.7 Counter 交叉验证与 UI 截图证据 traces/p19.png）
- 目标：RDK X5（aarch64 buildroot）上的 `pf-lat-case 1.0.0`（pid 6692，run_id `run-6692-6482`，采集期间未重启）
- 方法：只使用已安装的 `perfetto-latency-debugging` Skill（v0.1.1 candidate）规定的入口——**TrackEvent 埋点** + Perfetto 实采 + Trace Processor SQL；不使用源码/反编译/私有 Ground Truth。
- 结论置信度：**阶段归因与排队放大：高**（实采数据 + 可复算模型）；**具体触发原因/阻塞原语：中**（可观测特征清楚，但缺 syscall/锁事件，见 §7、SKILL_GAPS.md）。

---

## 0. 结论摘要

1. **现象可复现**：E2E 存在严格的 **30 s 周期**；一个周期内有两个彼此独立的时间窗（以应用启动为 0 点）：
   - **窗口 A（mild，轻）**：`app_time ≡ 20.0 s (mod 30 s)`，约 3.0 s。窗口内**每个请求的 `work` 阶段多消耗约 +14.0 ms CPU**，E2E 从约 15.2–15.8 ms 升到 **29.2–29.4 ms**；队列无积压。
   - **窗口 B（severe，主异常）**：`app_time ≡ 6.0 s (mod 30 s)`，约 3.5 s。窗口内**每个请求的 `output` 阶段多出约 +80 ms 的阻塞等待**（`output` = 85.07 ms 而不是 5.02 ms）；输出服务率从 200/s 掉到 **11.75/s**，低于 20/s 的到达率，导致 `q_out` 队列积压，E2E 最高 **2565.47 ms**（P99 2431.37 ms）。
2. **端到端升高的主体是排队，不是那个“最长 Slice”**：窗口 B 内最先到达的请求 E2E≈95 ms，`output` 阶段本身占 89%；但随着窗口持续，后续请求的 **`q_out` 队列等待**成为主体。窗口最后一个请求（rid 22991）：E2E 2565.47 ms = `q_out` 2469.59 ms（**96.3%**）+ `output` 85.15 ms（3.3%）+ `work` 8.03 ms + `preprocess` 2.03 ms + 其他 0.34 ms。**不能只凭 85 ms 的 `output` Slice 宣称它解释了端到端问题**。
3. **机制特征**：两个窗口都是**按“请求开始时刻是否落在窗口内”逐请求门控的固定附加延迟**（窗口外请求不受影响；窗口内后到的、甚至窗口结束后才被处理的请求同样带该附加延迟）。
   - 窗口 A 的 +14 ms 是 **CPU 忙**（`work` Slice 内 99.3% 时间处于 Running）；
   - 窗口 B 的 +80 ms 是 **阻塞/定时等待**（`output` Slice 内 93.2% 时间处于 S 状态，约 16 次 × 5.0 ms 的可中断睡眠，每次唤醒仅运行约 33 µs），**不是 CPU 不足、也不是被抢占**。
4. **排除项**：不是 tracing 开销（15 分钟无 tracing 的公共 CSV 同样异常）；不是 CPU 争用/调度饥饿（窗口期整机 CPU 利用率约 8.4%，`output` 线程 R 仅 0.42 ms/Slice）；不是其他 lab 进程跨进程干扰（异常全部发生在 `pf-lat-case` 自己的 4 个线程内）。
5. **不确定项**：为什么会以 30 s 周期、在 20.0 s / 6.0 s 相位打开这两个窗口，以及窗口 B 的 5 ms 轮询到底在等什么，**无法从现有事件判定**（没有触发/原因事件、没有 syscall/锁追踪；Skill 配置校验器也不允许加 syscall 事件）。队列深度 Counter 存在且已用于交叉验证（§5.7）。其余缺口见 SKILL_GAPS.md。

---

## 1. 材料边界（盲测纪律）

### 1.1 实际读取的允许材料

| 材料 | 用途 | SHA256 |
|---|---|---|
| `perfetto_skill_lab/latency/PUBLIC_BRIEF.md` | 现象、运行方式、CSV 格式 | `4742f1f3a48d13d8543c12efd4c94c90d01fbae07eb39299b0a2e081b840f709` |
| 已安装 Skill `/root/.dsh/skills/perfetto-latency-debugging`（SKILL.md、references、scripts、sql、configs） | 唯一方法论入口 | 见 [metadata/skill-files.sha256](metadata/skill-files.sha256) |
| 实采 Trace（本次三次采集） | 证据主体 | 见 [metadata/artifacts.sha256](metadata/artifacts.sha256) |
| 公共请求记录 `public_requests.csv`（含采集前 15 分钟无 tracing 版本，`data/public_requests_pre.csv`） | 现象/交叉验证 | `4079cb7c6de96d90cc6b6040b08e4d63876a6677c7e269f3bab40cb5bbcf4190` |
| `start.sh` / `status.sh` / `stop.sh` | 运行与状态操作（未修改；本地重算与 FROZEN 一致） | `3e825d7f…` / `528a285d…` / `82bd9c5a…`（与 FROZEN 一致） |

### 1.2 明确未读取/未使用的材料

- **未读取** `pf_lat_case.cpp`（A 的源代码）、`pf-lat-case.debug`、`Makefile`、`PRIVATE_GROUND_TRUTH.md`、`SELF_TEST.md`；
- **未反编译**、未用 `strings`/符号表推断实现；
- **未读取** 任何答案性日志/自测报告；
- 未修改 Skill、测试程序、tracebox/Perfetto 服务、系统内核/频率/调度参数；未要求窗口 A 改负载或关阶段。

### 1.3 需要披露的一处越界阅读

诊断开始时对 `perfetto_skill_lab/latency/` 做了目录列举，并读取了同目录 `FROZEN_SHA256.txt`（仅版本/哈希指纹：二进制 hash、build id、SDK 版本、脚本 hash）。其内容不含阶段、机制或答案信息，未用于诊断结论；为完整性在此披露。私有真值/自测报告只出现在目录列表中，未打开。

---

## 2. 环境与采集

### 2.1 环境（`metadata/board.txt`、`metadata/versions.txt`）

- 板卡：`Linux buildroot 6.1.83-DR-PL5.1_V1.1.1 #1 SMP PREEMPT ... aarch64`，8 核，1304 MB 内存。
- 应用：`pf-lat-case 1.0.0`，sha256 `bab492b264f6e5bd5d993d6228d309b1610e1a7bd37dad2bbb71d9dac1f00b55`；启动于板端 01:48，`run.log` 仅一行启动记录；**三次采集期间未重启、未改参数**。
- Perfetto 工具（复用板端已安装的兼容版本，未下载/替换）：
  - tracebox `Perfetto v58.2-add693d8b`，sha256 `2d21883e9c55818f851fd8c391afb9b366032b3110076b4fd41f31f30b5849fa`；
  - SDK v58.2（PUBLIC_BRIEF 冻结信息）；
  - host Trace Processor `Perfetto v58.2-add693d8b`，sha256 `58042408e6cc861fb1a731c26bb082dc222285561eaa4e12a48a8b2b90dca7b9`（与 tracebox 同版本）。
- 其他 lab 用例（`pf-cpu-case`、`pf-sched-case`）在采集期间**同时在运行**；它们是独立进程，见 §5.6 与 §7.3 的排除。

### 2.2 采集方式

应用本身通过 System backend 连接 `/tmp/perfetto-producer`。它在启动时若未探测到 tracing 会打印 `tracing=0`，但 SDK 会在 tracebox 起来后自动重连——因此**无需重启业务**。三次采集都用 Skill 的 `record.sh`（`--system-sockets` + `--notify-fd`，仅 READY 后开始计时），输出到独立目录；板端只在新建的 `/userdata/latency-lab-b/` 写入配置/采集产物，应用目录 `/userdata/perfetto-skill-lab/latency/` 只读取 `public_requests.csv` 快照，未写入。

| 采集 | TraceConfig | 时长/缓冲 | 结果 | 用途 |
|---|---|---|---|---|
| `cap-probe` | `track_event`，`rdk.latency` | 15 s / 16 MiB | 1,391,515 B；5,238 slices；300 begin / 259 end（停止时正值 burst，84 open） | **冒烟测试**：确认数据源、类别、事件契约可用；**不用于结论** |
| `cap-main` | `track_event`，`rdk.latency` | 90 s / 16 MiB | 8,573,653 B；32,400 slices；1,800 begin / 1,800 end / **0 open**；5,400 Flow | **主证据**（纯净应用采集） |
| `cap-sched` | `track_event` + `linux.ftrace`（`sched_switch`、`sched_waking`）+ `process_stats` | 70 s / 32 MiB | 7,924,997 B；25,091 slices；49,109 sched rows；1,400 begin / 1,372 end | **补证**：线程状态叠加（S/Running/Runnable） |

配置文件与板端记录副本：[configs/main.pbtxt](configs/main.pbtxt)、[configs/sched.pbtxt](configs/sched.pbtxt)、[configs/probe.pbtxt](configs/probe.pbtxt)、`configs/board-recorded-*.pbtxt`。

采集命令（板端，`TRACEBOX` 为实际路径）：

```sh
TRACEBOX=/userdata/perfetto-skill-lab/work/b/tracebox \
  sh /userdata/latency-lab-b/record.sh /userdata/latency-lab-b/main.pbtxt \
     /userdata/latency-lab-b/cap-main 130
# sched: 同命令，配置换 sched.pbtxt，输出 cap-sched，超时 130
```

采集状态：三次均 `collector_rc=0`、`timeout=0`、`forced_kill=0`，collector 日志均有 `FlushAndDisableTracing ... success=1`；main/sched 的 `stats` 中 `traced_final_flush_succeeded=1`。`status.txt` 为 `RECORDED_DATA_UNCHECKED`（按 Skill 语义，这只代表“已写文件”，数据验收由 TP 完成，见 §3）。

### 2.3 一次采集的原始文件

主采集目录（板端 `/userdata/latency-lab-b/cap-main/`，已拉回）：`trace.pftrace`、`config.pbtxt`、`collector.log`、`collector.pid`、`notify.byte`、`exit.txt`、`status.txt`、`READY`、`help.txt`。
Trace：`traces/cap-main-90s.pftrace`，sha256 `ff6cbe6e129d01de5f3738a776948cf5bf3d3a1c2e70460ea11a1889faa6b385`。
Sched Trace：`traces/cap-sched-70s.pftrace`，sha256 `334c832ae1ebe9e0752609dee47b0a7b9f99caee74518cb23c704a110f33dc7e`。

---

## 3. 数据质量与统计口径

### 3.1 Inventory（`analysis/custom-sql/v58-inv-main`、`v58-inv-sched`）

| Trace | 窗口(ns) | app_slices | begin | end | open | Flow | sched |
|---|---|---|---|---|---|---|---|
| cap-main | 7,589,314,363,118 .. 7,679,279,696,994（89.965 s） | 32,400 | 1,800 | 1,800 | **0** | 5,400 | 0 |
| cap-sched | 7,780,164,374,626 .. 7,850,159,776,118（69.995 s） | 25,091 | 1,400 | 1,372 | 56 | 4,173 | 49,109 |

### 3.2 Trace 级质量（`v58-quality-main`、`v58-quality-sched`）

- 两条 Trace 的 `stats` 表**没有** `severity=error` 或 `data_loss` 的条目（只有 info 级：clock_sync_cache_miss、parse/guess 时长、traced_buf_*）。
- Buffer 未溢出：main 写入 8.18 MB / 16 MiB；sched 写入 7.62 MB / 32 MiB；`chunks_read ≈ chunks_written`，最终 flush 成功。
- sched 的 `compact_sched_switch_skipped=8`、`compact_sched_waking_skipped=4` 为 info 级解析统计，不等于业务数据丢失。
- 因此 `analyze.py` 的 `quality_loss=false`，严格统计样本不被全局丢失排除。

### 3.3 完整性与终态（`analysis/main582/`、`analysis/sched582/`）

- **主 Trace**：1,800 个请求 **全部 COMPLETE + SUCCESS**；`stage_count=3`、`queue_count=3`、`flow_count=3` 与 `lat.request.end` 的 `expected_*` 声明逐一相符；无 DROP/ERROR/TIMEOUT/CANCELLED。
- **Sched Trace**：1,371 个 COMPLETE+SUCCESS；1 个 CENSORED（`lat.request.boundary=capture_start_in_flight` 边界见证）；28 个 INCOMPLETE（采集停止时仍在途：`OPEN_QUEUE/OPEN_STAGE/REQUEST_END_MISSING`，属边界截断，不是超时）。**严格统计只用 1,371 个**，窗口级结论用主 Trace 的 1,800 个。
- 主 Trace 两端恰好落在请求边界，因此 0 open；sched 的尾部 28 个不进入统计。

### 3.4 埋点契约检查（`analysis/custom-sql/v58-fields-main`、`v58-names-main`）

| 事件 | 数量 | run/stream/request/process_instance | stage/instance/attempt | queue/visit | link/from/to | status | expected_* |
|---|---|---|---|---|---|---|---|
| `lat.request.begin` | 1,800 | 100% | — | — | — | — | — |
| `lat.request` | 1,800 | 100% | — | — | — | — | — |
| `lat.request.end` | 1,800 | 100% | — | — | — | 100% | 100% |
| `lat.stage` | 5,400 | 100% | 100% | — | — | — | — |
| `lat.stage.result` | 5,400 | 100% | 100% | — | — | 100% | — |
| `lat.queue` | 5,400 | 100% | — | 100% | — | — | — |
| `lat.send` / `lat.receive` | 5,400 / 5,400 | 100% | — | — | 100% | — | — |

- 所有事件 `contract_version="latency.v1"`；ID 为字符串，无 `[NULL]`/空值。
- 每请求恰好 3 个阶段实例（`preprocess`/`work`/`output`）、3 次队列访问（`q_pre`/`q_work`/`q_out`）、3 条显式 Flow 边（`lat.send`→`lat.receive`，link_id 唯一）；`analyze.py` 的 Flow 校验均为 VALID。
- `lat.queue_depth.q_pre/q_work/q_out` Counter **存在**：各 3,600 个采样点（每请求入队/出队各记一次），`04-counters` 导出非空。首轮 rev1 曾误判其不存在，rev3 已修正并用于 §5.7 的模型交叉验证。

### 3.5 与公共记录交叉验证（`data/crosscheck_trace_vs_csv.txt`）

- 按 `request_id` 匹配 **1800/1800**，状态全部一致（SUCCESS）。
- `e2e_csv − e2e_trace`：中位 **−209 ns**，范围 [−86.2 µs, +67.2 µs]。
- `trace_begin − csv_start` 中位 5.2 µs；`trace_end − csv_finish` 中位 3.7 µs。
- 结论：Trace 的请求生命周期与程序公开记录**同一时钟、同一请求、误差 <0.1 ms**；公共 CSV 可作为独立见证。

### 3.6 统计口径（严格遵循 Skill）

- 严格请求统计仅纳入 **COMPLETE + SUCCESS + 无全局数据丢失**；DROP/ERROR/TIMEOUT 单列（本次为 0）。
- 分位数：nearest-rank `ceil(q·N)`；`N=1800`（主 Trace）。`p95/p99` 是经验分位，不是置信区间。
- 队列/阶段/Flow 分开统计：`stage_work_wall_sum`、`stage_wall_union`、`queue_wall_sum` 不相加当 E2E。
- 临界路径：`critical_path_status=NOT_COMPUTED`（Skill 首版不自动推导任意 DAG 关键路径）；本报告的“关键分支”论证只基于真实阶段/队列/Flow 与业务到达率。
- 相位划分以**请求开始时刻**相对应用启动（request 1 的 `start_ns`）计算，窗口边界精度受 50 ms 采样限制。
- 窗口内/窗口外的划分只用于展示，不改变原始 Trace/SQL；原始查询在 `analysis/custom-sql/`。

---

## 4. 现象与周期

### 4.1 无 tracing 的公共记录已显示相同周期（排除观测干扰）

`data/public_requests_pre.csv`（15 分钟、18,352 请求、**tracing 未开启**）：

- E2E：p50 15.252 ms，p95 1972.28 ms，p99 2450.55 ms，max 2559.46 ms；`>100 ms` 占 **20.95%**。
- 以 request 1 为 0 点，每 30 s：
  - `20.000 + 30k` 秒起，约 60 个请求 E2E≈29.1–29.3 ms（mild）；
  - `6.0 + 30k` 秒起 severe 窗口，`>500 ms` 持续约 5.15 s（含队列消化），max 2.55–2.56 s。
- 详见 [analysis/summary/public_csv_analysis.txt](analysis/summary/public_csv_analysis.txt)。

### 4.2 两次独立实采的相位完全一致

以 request 1 的 `start_ns` 为 0 点（同一 run）：

| 采集 | mild 窗口（请求开始时刻，s） | severe 窗口（请求开始时刻，s） |
|---|---|---|
| cap-main（90 s） | 1100.05–1103.00；1130.00–1133.00；1160.05–1163.00 | 1116.05–1119.50；1146.05–1149.50；1176.00–1179.50 |
| cap-sched（70 s） | 1310.00–1312.95；1340.00–1342.95 | 1296.00–1299.50；1326.00–1329.50；1356.00–1357.90（截断） |

- mild 起点 `mod 30 = 20.0 s`；severe 起点 `mod 30 = 6.0 s`；mild 起点到其后最近一次 severe 起点相隔 16 s（等价地 severe→mild 14 s）；周期 30 s。三次会话（15 min 无 trace + 90 s + 70 s）一致。
- 说明：窗口边界以 50 ms 请求采样观测，真实窗口约为 **3.0 s（mild）** 与 **3.5 s（severe）**；不对边界作更细声明。

### 4.3 影响面（cap-main，N=1800）

| E2E 分类 | 数量 | 占比 | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|
| 正常（<20 ms） | 1,239 | 68.8% | 15.773 ms | 16.030 ms | 16.106 ms | 16.393 ms |
| mild（20–40 ms） | 180 | 10.0% | 29.344 ms | 29.905 ms | 30.001 ms | 30.008 ms |
| 过渡（40–100 ms） | 9 | 0.5% | 95.577 ms | — | — | 96.474 ms |
| **severe（>100 ms）** | **372** | **20.7%** | **1332.480 ms** | **2431.369 ms** | **2530.232 ms** | **2565.467 ms** |

全量：p50 **15.925 ms**、p95 **1966.19 ms**、p99 **2431.37 ms**、max **2565.47 ms**（`analysis/main582/SUMMARY.md`）。
与无 tracing 公共记录的 `>100 ms` 占比（20.95%）一致，说明采样窗口没有系统性偏差。

---

## 5. 主异常（severe）：证据链

### 5.1 请求路径（真实观测到的结构，未补全）

每个请求（1,800/1,800）都包含：

```
lat.request.begin
 └ lat.request（request lane 00..51，显式自定义 Track）
    q_pre  (lat.queue, q_pre lane)   →  lat.send → lat.receive(Flow)  → preprocess (thread pf-lat-1)
    q_work (lat.queue, q_work lane)  →  lat.send → lat.receive(Flow)  → work       (thread pf-lat-2)
    q_out  (lat.queue, q_out lane)   →  lat.send → lat.receive(Flow)  → output     (thread pf-lat-3)
lat.request.end（status + expected_stage/queue/link_count）
```

- 三个阶段各自固定跑在独立线程（`stages.csv` 的 `thread_utid`：pre=3/pf-lat-1、work=4/pf-lat-2、output=5/pf-lat-3），主线程与 `pf-lat-0` 基本空闲。
- 队列等待按 `lat.queue` Slice 的 `dur` 计算（入队→出队墙钟）；队列瞬时深度由 `lat.queue_depth.*` Counter 独立记录，两者口径不同、可互相验证（§5.7）。
- `lat.request` 是 UI 展示用的显式 Track Slice，**E2E 以 `lat.request.begin/end` 两个 Instant 计算**（Skill 要求）。

### 5.2 窗口内逐请求时间线（`analysis/summary/timeline_severe.csv`）

一个 severe 窗口（rid 22320 起，app 时间 1115.95–1122.6 s，单位为 ns）：

| request | out dur | q_out | E2E | 说明 |
|---|---|---|---|---|
| 22320（窗口前） | 5,006,959 | 28,250 | 15.23 ms | 正常 |
| 22321（窗口第 1 个） | **85,066,750** | 41,208 | **95.29 ms** | 阶段自身 +80 ms |
| 22322 | 85,077,667 | 35,164,750 | 130.42 ms | 队列开始累积 |
| 22323 | 85,102,375 | 70,354,042 | 165.66 ms | 每 50 ms 到达、每 85.1 ms 服务 |
| … | ≈85.1 ms | 单调上升 | 上升 | 服务率 < 到达率 |
| 22391（窗口末） | 85,123,791 | 2,470,008,959 | **2,565.45 ms** | 队列最长（窗口内最后到达） |
| 22392（窗口后第 1 个） | 5,031,500 | 2,505,389,042 | 2,520.76 ms | 服务已恢复，但它排在队列头 |

- 窗口内 `output` Slice 起点间隔中位 **85.25 ms**，与 85.1 ms 的服务时间吻合：输出线程被这一个阶段串行占满。
- 窗口结束后，**新请求的 `output` 立即恢复 5.0 ms**，但它们仍排在窗口内请求留下的 `q_out` 队列后面；`q_out` 从 2.5 s 线性下降到 0，消化约 **2.5 s**。以第三个窗口为例：窗口止于 1179.5 s，最后一个慢 `output` 约在 1182.0 s 结束（比窗口晚约 2.5 s）。

### 5.3 排队模型（可复算，非拟合）

- 到达率：请求间隔中位 50.000 ms → **20/s**（公共 CSV 的 `start_ns` 差值验证）。
- 窗口内输出服务时间：85.1 ms → **11.75/s**。
- 净积压速率：20 − 11.75 = **8.25/s**；窗口 3.5 s → 约 **28.9** 个请求积压。
- 预测最大队列等待：28.9 × 85.1 ms ≈ **2.46 s**；实测最大 `q_out` **2,505.4 ms**（rid 22392：窗口结束后到达、却排在队列头）；窗口内最后到达的 rid 22991 `q_out`=2,469.6 ms，对应最大 E2E 2,565.5 ms。
- 一个直接校验：2,505 ms / 85.1 ms ≈ **29.4** 个“前序服务单元”，与 28.9 的模型值一致。
- 因此：**`output` 阶段 +80 ms 是触发器，`q_out` 排队是放大器**；端到端升高的量级由“窗口时长 × 服务率差”决定。

### 5.4 为什么不能把最长 Slice 当根因（数字）

- 窗口内**第 1 个**请求（rid 22321，E2E 95.29 ms）：`output` 85.07 ms 占 89%，队列仅 0.04 ms。
- severe 窗口的末请求（以 rid 22991 为例，app 1149.5 s，E2E 2565.47 ms）逐项分解（全部来自 Trace）：

| 分量 | 值 | 占 E2E |
|---|---|---|
| `q_out`（`lat.queue`） | 2,469,585,626 ns | **96.26%** |
| `output`（`lat.stage`） | 85,154,125 ns | 3.32% |
| `work` | 8,028,625 ns | 0.31% |
| `preprocess` | 2,026,458 ns | 0.08% |
| `q_pre` + `q_work` | 329,667 ns | 0.01% |
| 阶段外/交接开销 | 342,167 ns | 0.01% |
| **E2E** | **2,565,466,668 ns** | 100% |

- 结论：**“最长 Slice”在不同请求上不同**——窗口首请求是 `output`(85 ms)，窗口末请求是 `q_out`(2.47 s)。只报一个“最长 Slice”会漏掉 96% 的端到端时间。

### 5.5 线程状态：+80 ms 是阻塞/定时等待，不是 CPU（cap-sched）

对 181 个慢 `output` Slice（dur>50 ms）按 utid=5 叠加 `thread_state`（`analysis/custom-sql/v58-overlay-sched/stdout.csv`）：

| 类别 | Slice 数 | 每 Slice Running | 每 Slice S | 每 Slice Runnable |
|---|---|---|---|---|
| `output` 快（<50 ms） | 1,182 | **5.020 ms** | 0 | 0.080 ms |
| `output` 慢（>50 ms） | 181 | **5.400 ms** | **79.290 ms** | 0.420 ms |

- 慢 `output` 的 85.1 ms = 5.40 Running + 79.29 S + 0.42 R（合计 85.11 ms）。
- S 区间共 2,896 个：**avg 4.956 ms**，max 5.055 ms，**93.7%（2,715 个）落在 4.9–5.2 ms**；每个慢 Slice 约 16 次。
- 每次唤醒后的 Running 片段：中位 **32.7 µs**；>1 ms 的片段 366 个（≈2/慢 Slice，即首尾两段 ~5 ms 的实际工作）。
- 单 Slice 原始状态时间线（`v58-slice_states-sched`）：`Running 5.15 ms → [S 5.04 ms → R 40 µs → Running 35 µs] × 16 → 结束`，即**定时轮询/超时等待**，不是一次性 80 ms 纯睡，也不是 CPU 自旋。
- `work` 慢（>15 ms，121 个）：**Running 21.85 ms / Slice**，R 仅 0.66 ms → **CPU 忙**。

### 5.6 排除 CPU 争用/调度饥饿

- 在一个 severe 窗口 + 消化期（6.057 s）内，整机 8 核 Running 合计 4,063.6 ms / 48,455.8 ms = **8.4%** 利用率；CPU 远未饱和。
- 慢 `output` 的 Runnable 每 Slice 仅 0.42 ms（最大 R 区间 131.5 µs），不构成“等 CPU”。
- 因此：窗口内慢不是外部 CPU 压力或调度饥饿造成，而是**阶段内部主动/被动的定时等待**。

### 5.7 队列深度 Counter 交叉验证（rev3 新增；UI 截图证据 `traces/p19.png`）

`lat.queue_depth.q_pre / q_work / q_out` 各 3,600 个采样点（`analysis/custom-sql/v58-ctrmax-main/`、`main582/04-counters/`）：

| Counter | min | max | 行为 |
|---|---|---|---|
| `q_pre` | 0 | **1** | 从不积压 |
| `q_work` | 0 | **1** | 从不积压 |
| `q_out` | 0 | **51** | severe 窗口期爬升；峰值出现在慢 output 消化结束时（≈窗口起点+6.05s，如窗口#3：51 @ trace+83.56s），随后以 ≈每 5.1ms 减 1 的斜率排空（正是 5ms 的 output 服务率） |

模型对账：窗口末积压 ≈30（71 到达 − 41 已出队），慢消化期间再入队 ≈51、同时出队剩余慢请求 ≈29 → 预测峰值 ≈52，与实测 51 吻合；`q_pre/q_work ≤1` 证明积压只发生在 output 一级。UI 截图（`traces/p19.png`，用户侧复核）中 `q_out` 的三角形与此一致；其 y 轴顶格 55 是坐标轴刻度，数据峰值 51。

> 修订说明：rev1 曾误判『无队列深度 Counter』——当时只枚举了含 Slice 的轨道、未查 `counter_track`；rev3 修正，并把该 Counter 用作队列模型的独立验证。

---

## 6. 次异常（mild）：证据链

### 6.1 数值

- 窗口：`app_time ≡ 20.0 s (mod 30 s)`，约 3.0 s；窗口内约 180 个请求（3 个窗口各约 60）。
- 组件（中位，ms）：`preprocess 2.015`、`work` **22.008**（窗口外 8.019，**+13.99 ms**）、`output 5.008`；`q_pre 0.061`、`q_work 0.064`、`q_out 0.036` → **队列全部正常，无积压**。
- E2E 中位 **29.344 ms**（窗口外 15.773 ms）。
- 线程状态（cap-sched，121 个慢 `work` Slice）：**Running 21.85 ms/Slice**（99.3%），Runnable 0.66 ms → 纯 CPU 计算增加约 14 ms，不是睡眠/等待。
- 服务率 1/29.3 ms = 34/s > 20/s 到达率，故**不产生队列**，只把每个请求推迟约 14 ms。

### 6.2 与 severe 的区别（重要）

| | mild | severe |
|---|---|---|
| 受影响阶段 | `work` | `output` |
| 附加延迟 | +14.0 ms | +80.05 ms |
| 线程状态 | Running 99.3% | S 93.2%（~16 × 5 ms 轮询） |
| 对服务率 | 34/s > 20/s，无积压 | 11.75/s < 20/s，积压 29 个 |
| E2E 影响 | 15.8 → 29.3 ms | 15.8 → 2,565 ms（长尾） |

---

## 7. 机制：已证实的与不确定的

### 7.1 已由数据证实的机制特征

1. **逐请求门控**：附加延迟只取决于**请求开始时刻是否落在窗口内**。证据：窗口内到达但窗口结束后才被处理的请求，`output` 仍是 85.1 ms（例如 rid 22391 在 1119.5 s 到达，其 `output` 直到约 1121.98 s 才执行——`q_out`≈2.47 s——仍为 85.1 ms）；窗口结束后到达的请求 `output` 立即恢复 5.0 ms。
2. **固定增量**：mild +13.99 ms（`work` 22.008 vs 8.019），severe +80.05 ms（`output` 85.067 vs 5.020）；分布非常窄（`work` 慢 22.006–22.101 ms；`output` 慢 85.065–85.254 ms），不像资源争用的随机波动。
3. **周期 30 s、双窗口**：mild 在 20.0 s，severe 在 6.0 s（mod 30），三次独立运行/15 分钟无 trace 记录一致。
4. **执行性质不同**：mild 是 CPU 忙等；severe 是定时轮询等待（S 状态、~5 ms/次、约 16 次）。

### 7.2 不能从现有证据确定的（明确标注 UNKNOWN）

- **触发源**：没有事件告诉我们“窗口为什么打开”。可能是应用内的周期故障注入/负载相位，但没有 cause/phase 事件、没有 Counter、没有源码，不能下结论为“设计如此”。
- **severe 等待的对象**：5 ms 轮询在等什么（下游确认、令牌、共享标志、超时 deadline）未知；从数据只能看到“每次 5.0 ms 超时后醒来、跑 ~33 µs、再睡”，直到累计约 80 ms。
- **阻塞原语**：`S` 状态与 Timeout 型轮询与 `sleep_for(5 ms)`、`condition_variable::wait_for(5 ms)`、`try_lock_for(5 ms)` 都相容；**没有 syscall（nanosleep/futex）或锁事件**，不能进一步区分（且 Skill 的 `validate_config.py` 明确拒绝这两类事件，见 G3）。
- **80 ms/14 ms 的数值来源**：未知；只能确认是固定附加量。

### 7.3 已排除的解释

| 候选 | 证据 |
|---|---|
| tracing 开销导致 | 15 min 无 tracing 的 CSV 有完全相同的 30 s 周期/幅度 |
| CPU 争用/调度饥饿 | 窗口期整机 CPU 8.4%；慢 `output` Runnable 0.42 ms/Slice；`output` 是 S 不是 R |
| 其他 lab 进程跨进程干扰 | 异常全部在 `pf-lat-case` 的 4 个线程内；`pf-cpu-case`/`pf-sched-case` 是独立进程，其线程活动不改变本应用的逐请求固定增量 |
| 队列 Counter/采样伪影 | `lat.queue_depth.q_out` Counter 独立印证：峰值 51 @ 慢消化结束点、排空 ≈5.1ms/个，与 `lat.queue` Slice 等待和 E2E/CSV 三方一致（§5.7） |
| 采集边界/截断 | 主 Trace 0 open、1,800 全 COMPLETE；边界截断只在 sched 的 28 个尾部请求，已排除 |

---

## 8. UI 复核说明（手动，未自动化）

前提：UI 打开真实 `.pftrace`；下列对象在 Trace 中确实存在（名称来自本 Trace）。截图样例：`traces/p19.png`（q_out 深度三角形，峰值 51）、`traces/p20-1.png`（severe 慢 output 85ms 66µs）、`traces/p20-2.png`（mild 慢 work 22ms 06µs）、`traces/p22.png`（severe 长请求 2s162ms + 两个 `lat.queue` + q_out 三角形）、`traces/p21.png`（sched trace 线程状态：Runnable 后连续 Sleeping，每段 ~5ms）。

1. **主 Trace**：打开 `traces/cap-main-90s.pftrace`，在进程 `/userdata/perfetto-skill-lab/latency/pf-lat-case` 下找到线程 `pf-lat-1`（preprocess）、`pf-lat-2`（work）、`pf-lat-3`（output）。
2. **定位慢 output**：主 Trace 有 3 个 severe 窗口，在 trace 开始后 ≈17.5 s / 47.5 s / 77.5 s（绝对 ts ≈7,606,814,332,511 / 7,636,814,332,511 / 7,666,814,332,511 ns，对应 app 1116.0 / 1146.0 / 1176.0 s）。在 `pf-lat-3` 线程轨道上任选一个窗口展开 `lat.stage`，可见 dur≈85.1 ms 的 `output` Slice；普通时刻同阶段为 5.0 ms。选中 Slice，详情中 `stage_id=output`、`stage_instance_id=out-<request_id>`、`request_id` 可从 debug annotation 读到。
3. **请求生命周期**：在 `request lane 00`…`request lane 51` 自定义 Track 上找 `lat.request`（最长 2.565 s）；详情里用 `run_id/stream_id/request_id` 区分并发请求（不要用 lane 号当身份）。
4. **Flow**：选中 `lat.send`（Instant）可见 Flow 箭头指向对应 `lat.receive`；每请求 3 条边，`link_id` 唯一；用 `analysis/custom-sql/flow-probe-1`/`02-flow` 的 SQL 可复核 `flow` 表。
5. **队列**：在 `q-out lane 00`… 上查看 `lat.queue`（q_out 最长 2.505 s）；同时展开 `lat.queue_depth.q_out` Counter：severe 期三角形爬升，峰值 **51**（y 轴顶格 55 是刻度）在慢消化结束点（≈窗口起点+6.05s），随后 ≈5.1ms 减 1 排空；`q_pre/q_work` 恒 ≤1。截图样例 `traces/p19.png`。
6. **线程状态（sched Trace）**：打开 `traces/cap-sched-70s.pftrace`，选中 `pf-lat-3` 上的慢 `output` Slice，开启 CPU/Thread State 轨道，可看到 `S`（~5 ms）与 `Running`（~33 µs）交替约 16 次；`work` 慢 Slice 则几乎全为 `Running`。
7. **SQL 复核**：UI Query 中直接粘贴 `analysis/main582/00-inventory/query.sql`、`analysis/main582/01-events/query.sql` 等（`${CATEGORY}` 已替换为 `rdk.latency`）；或用 `ui-request-track.sql` 生成派生 Debug Track（只含严格合格请求，不是新测量）。
8. **看图注意**：Slice 长度是墙钟；`lat.request`/`lat.stage` 跑在自定义/线程 Track 上，不能把最长 Slice 直接当关键路径；队列等待、阶段墙钟、CPU 时间是三个不同维度。

---

## 9. 复现命令（关键步骤）

```sh
# 0) 主机生成/校验配置（Skill 脚本）
python3 scripts/make_config.py --duration-ms 90000 --buffer-kib 16384 --output main.pbtxt
python3 scripts/validate_config.py main.pbtxt --check-resources   # POLICY_PASS + SCHEMA_UNKNOWN

# 1) 板上采集（独立目录；不重启业务）
TRACEBOX=/userdata/perfetto-skill-lab/work/b/tracebox \
  sh /userdata/latency-lab-b/record.sh /userdata/latency-lab-b/main.pbtxt \
     /userdata/latency-lab-b/cap-main 130

# 2) 拉回后分析（TP v58.2）
python3 scripts/analyze.py --tp <TP> --trace cap-main/trace.pftrace --out analysis/main582

# 3) 相位/组件与线程状态（本报告自定义 SQL，已随附）
<TP> query -f analysis/custom-sql/v58-overlay-sched/query.sql traces/cap-sched-70s.pftrace
```

环境变量/工具哈希、配置哈希、Trace 哈希见 `metadata/` 与 `SHA256SUMS.txt`。

---

## 10. 证据索引（结论 → 文件）

| 结论 | 证据文件 |
|---|---|
| 30 s 周期、无 tracing 也存在 | `analysis/summary/public_csv_analysis.txt`、`data/public_requests_pre.csv` |
| Trace 生命周期与 CSV 一致 | `data/crosscheck_trace_vs_csv.txt` |
| 1800 全 COMPLETE/SUCCESS、契约完整 | `analysis/main582/analysis.json`、`analysis/custom-sql/v58-fields-main/`、`v58-inv-main/` |
| E2E 分位与相位统计 | `analysis/main582/SUMMARY.md`、`analysis/summary/main582_phase_numbers.txt`、`impact_classes.txt` |
| severe 逐请求时间线 | `analysis/summary/timeline_severe.csv` |
| mild 逐请求时间线 | `analysis/summary/timeline_mild.csv` |
| 慢 output 线程状态（S 79.29 ms） | `analysis/custom-sql/v58-overlay-sched/stdout.csv` |
| 5 ms 轮询分布 | `analysis/custom-sql/v58-wait_hist-sched/stdout.csv` |
| 单 Slice 状态时间线 | `analysis/custom-sql/v58-slice_states-sched/stdout.csv` |
| 慢 work 为 CPU（Running 21.85 ms） | `analysis/custom-sql/v58-overlay-sched/stdout.csv` |
| 数据质量/无丢失 | `analysis/custom-sql/v58-quality-main/`、`v58-quality-sched/` |
| 边界/截断处理 | `analysis/sched582/requests.csv`（CENSORED/INCOMPLETE 行） |
| 原始 Trace/Config/采集日志 | `traces/`、`configs/`、`metadata/collector-*.log` |
| 队列深度 Counter（峰值 51、排空斜率） | `analysis/custom-sql/v58-ctrmax-main/`、`analysis/main582/04-counters/` |
| UI 截图证据（q_out 三角形；慢 output 85ms；慢 work 22ms；2.16s 长请求+队列；sched 线程状态） | `traces/p19.png`、`traces/p20-1.png`、`traces/p20-2.png`、`traces/p22.png`、`traces/p21.png` |
| Skill 文件版本与哈希 | `metadata/skill-files.sha256`、`metadata/versions.txt` |

---

## 11. 交付边界与下一步（交给独立评估者）

- 本报告是**首轮盲测**：未运行“关闭某阶段/换负载/加对照”的实验，未从窗口 A 取得真值，未读取私有 Ground Truth。
- 如需进一步定位“窗口触发源”，需要：应用侧 cause/phase 事件、队列深度 Counter、或 syscall/锁追踪中的至少一项；当前 Skill 的配置校验器不允许第 4 类事件（见 SKILL_GAPS.md G3），因此本轮按纪律报告证据缺口，不猜测实现。
- Ground Truth 对照、A/B 归因与最终结论由独立评估者完成；本报告只提供可复核的观测与量化模型。

---

## 12. 冻结哈希

见 `SHA256SUMS.txt`：前半部为全部交付物哈希；文件末部 `FROZEN` 段单独列出本报告与两条主 Trace 的 SHA256（最后三行），便于冻结。
