# test_perfetto

X5 上 heapprofd 端到端实验（A/B）的真实 Perfetto trace 与验收结果，见 [`x5_heapprofd_traces/`](x5_heapprofd_traces/)。

- `x5_heapprofd_A_no_tick.pftrace`：无 tick（1 份 dump）
- `x5_heapprofd_B_tick_200ms.pftrace`：持有期每 200ms 4KiB tick（6 份 dump，Live 8→0 MiB）

采集端 tracebox v57.1（X5），分析端 Trace Processor v58.2。可直接拖进 <https://ui.perfetto.dev/> 查看。

## 截图

- `x5_heapprofd_traces/折线图.png`：实验 B trace 在 Perfetto UI 中的截图。
  注意：该图的 debug track 被添加成了 **Debug Slice Track**（按 slice 渲染，显示为色块+横线），
  不是 `heap_live_timeline.sql` 期望的 **Counter Track**（折线/散点，值应为 `8,8,8,0,0,0` MiB）。
  若要得到真正的 Heap Live 折线，请在 Query 结果区选择 **Add debug track → Counter Track**。

## CPU 性能诊断

- [`cpu_v1_test/`](cpu_v1_test/)：X5 上 C++ 多线程负载（每 3 s 烧 300 ms）的 CPU 尖峰归因。
  采集端 tracebox v57.1 + scheduling 路由（20 s），分析端 Trace Processor v57.1；
  结论：`spike-worker`(tid 12044) 每 3000 ms 满占 CPU1 一个核 300 ms，Runnable 仅 ~80 µs，非调度延迟。

## CPU Skill 可用基线（[`perfetto-cpu-debugging/`](perfetto-cpu-debugging/)，v0.1.0-r1）

- [`perfetto-cpu-debugging/`](perfetto-cpu-debugging/)：**当前归档基线**，完整可安装 Skill
  （`SKILL.md`、references、scripts、configs、sql、tests、examples + `MANIFEST.json` + `SHA256SUMS.txt`，共 65 个文件）。
- 版本：`MANIFEST.json` 记 `version 0.1.0-r1`、`status candidate-r1`；内容与
  [`perfetto-cpu-debugging-v0.1.0-r1/`](perfetto-cpu-debugging-v0.1.0-r1/) **逐字节一致**
  （r1 = v0.1.0 + 四项定点修复，两版未混合；本机已安装的 v0.1.0 副本未改动，Memory Skill v1.0.2 未被覆盖）。
- 本次只做版本整理与归档：未改核心算法、未重构 Skill、未重新上板测试、未增功能、未做 release。

### 已验证能力

| 能力 | 证据（2026-10-18 归档复核） |
|---|---|
| 本地单元测试 | `python3 -m unittest discover -s tests -v` → **33 passed / 0 failed**（v0.1.0 的 22 + r1 新增 11：单语句约束、inventory 五文件、frequency≠overview、频率门 4 种判定等） |
| 资源完整性 | `validate_config.py --check-resources` → `[PASS] resources: 25 essential files + 4 configs` |
| 四份配置静态结构 | 4/4 PASS（官方 collector schema 仍 `UNKNOWN`） |
| inventory + 频率门真实 trace 回归 | `tests/real_trace_regression` 在 TP v57.1 上复跑 `cpu_v1_test/cpu.pftrace` → **7/7 PASS**，与归档 `tp-v57.1/` 输出逐字节一致；r1 记录另有 v58.2 7/7 且两版一致 |
| X5 上板调度归因 | [`cpu_v1_test/`](cpu_v1_test/)：`spike-worker` 每 3 s 满占一核 300 ms、Runnable ~80 µs，非调度延迟 |
| X5 上板全链路（sched + linux.perf + freq/idle） | [`cpu_test3/`](cpu_test3/)：单次 55 s 采集、44,000 个 perf 样本 / 0 丢数，并用 `01..08` SQL 完成忙/等/热点分析 |
| 文件哈希 | 目录内 `SHA256SUMS.txt` 覆盖除自身外的全部 64 个文件，`sha256sum -c` 全部通过 |

### 已知限制

- **schema**：没有与板端采集器（v57.1）同版本的官方 descriptor，官方 schema 校验仍为 `UNKNOWN`；静态结构 PASS 不等于 collector schema PASS。
- **回归范围**：只有 inventory 与频率验收门做了自动化真实 trace 回归；`01..08` 其余 SQL 的实跑证据来自 `cpu_test3` 的一次实际使用，不是自动化回归。
- **`scripts/host_pull.sh`**：内部 `scp` 不带非交互认证（`cpu_test3` 实测会失败，需自行用 sshpass/密钥 + sha256 校验替代）。
- **平台依赖**：`linux.perf` 依赖目标机 `perf_event_open` 权限、producer 与符号；Perfetto UI 无自动化（`UI_UNKNOWN`）；Android 路径未验证。
- **频率口径**：`power/cpu_frequency` 只在变化时出事件；单 policy 驱动多核时，逐核频率轨迹不能独立解释每个核；空结果不得读成 0 MHz（用 `04a` 判定门）。

### 后续改进项（留待下一版本）

1. `scripts/host_pull.sh` 支持密钥/密码非交互认证，或在失败时给出明确指引。
2. 为 `01..08` 增加真实 trace 自动化回归（现仅 inventory + 频率门）。
3. 用匹配 v57.1 的官方 descriptor 补 schema 校验。
4. `references/06-ui.md` 补一条：Perfetto 火焰图 `Perf Samples (cpu-clock)` 的权重在"累计 counter"trace 上不是 CPU 时间，优先切 `Sample Count`。
5. 提供多语句 SQL 的 CLI 包装（`trace_processor_shell query -f` 只接受单语句）。
6. Android / `linux.perf` 平台能力矩阵补测。

### 归档复核记录（2026-10-18）

```text
python3 -m unittest discover -s tests -v              -> Ran 33 tests ... OK
python3 scripts/validate_config.py --check-resources  -> [PASS] resources: 25 essential files + 4 configs
sh -n scripts/*.sh                                    -> 4/4 OK
sha256sum -c SHA256SUMS.txt                           -> 64/64 OK（清单不含自身）
tests/real_trace_regression (TP v57.1, cpu_v1_test)   -> 7/7 PASS，与归档输出逐字节一致
```

## 历史：R1 制作与测试（原记录，保留）

- [`perfetto-cpu-debugging-v0.1.0-r1/`](perfetto-cpu-debugging-v0.1.0-r1/)：
  基于 `cpu_v1_test` 上板反馈的四项定点修复（inventory SQL 单语句化、frequency/overview 路由区分、
  频率数据验收门、报告证据表述）。完整可安装 Skill，`MANIFEST.json` 记录 63 个文件哈希。
- [`perfetto-cpu-debugging-v0.1.0-r1.diff`](perfetto-cpu-debugging-v0.1.0-r1.diff)：对 v0.1.0 的 unified diff（`patch -p1` 可应用，已验证）。
- [`perfetto-cpu-debugging-v0.1.0-r1.TEST_REPORT.md`](perfetto-cpu-debugging-v0.1.0-r1.TEST_REPORT.md)：
  修改清单、四项状态、33 项单测与 TP v57.1/v58.2 真实 trace 回归结果、未验证范围。

## Scheduling Skill 可用基线（[`perfetto-scheduling-debugging/`](perfetto-scheduling-debugging/)，v0.1.0 Candidate / Usable Baseline）

- [`perfetto-scheduling-debugging/`](perfetto-scheduling-debugging/)：**本次归档的 v0.1.0 Candidate 可用基线**，完整可安装
  （`SKILL.md`、`references/`、`scripts/`、`sql/`、`configs/`、`tests/`、`examples/`、`workflows/` + `MANIFEST.json` +
  `SHA256SUMS.txt` + `PROVENANCE.md`，共 57 个文件）。版本标记为 **v0.1.0 Candidate / Usable Baseline**，**不是 Stable**。
- 来源：本机实际安装并用于 `v5_test` 的同一份包（安装版 `MANIFEST.json` sha256 `d224b204…`，与原始解压包 `diff -rq` 无差异）；
  本归档只更新 README/TEST_REPORT/MANIFEST/SHA256SUMS 并新增 `PROVENANCE.md`，**其余 52 个文件逐字节一致**（可 `diff -r` 复核）。
- 归档校验：`verify_package.py` → `PACKAGE_PASS hashes=55 resources=44`；`--check-resources` → `RESOURCES_PASS count=44`；
  `unittest discover -s tests` → 59 tests（58 pass / 1 skip：需真实 TP）；`sha256sum -c SHA256SUMS.txt` → 56/56 OK。
- 已完成真实 X5 验证（见 [`v5_test/`](v5_test/)）：基础调度采集与线程状态分析、Runnable 延迟与同核竞争归因、
  定向 `sched_switch`/`sched_waking` 调用栈采集、部分切出/唤醒事件关联、跨进程唤醒与 futex 活动。
- 尚未完成全部专项验收：多级等待链完整归因、干扰事件的板端错误关联专项、超时等待原因识别、Perfetto UI 实际操作。
  **不声明 C1–C6 全部通过。**
- 已知限制：事件采样缺失、部分唤醒调用栈不可用、perf 样本与 ftrace 事件存在 16.8–111.4 µs 时间偏差（需显式容差并逐条验唯一性）、
  不能从唤醒关系推断锁所有权。

## 调度 / 同步诊断（[`v5_test/`](v5_test/)，perfetto-scheduling-debugging v0.1.0 Candidate）

X5 常驻 C++ 服务 `sched-case-daemon`（PID 977，12 worker + main，helper 987，亲和性 CPU 1-2）的
**独立盲诊断**：先只读侦察、复用性检查、相位对齐主采集（仅调度数据 60 s）→ 有过滤事件栈 + futex 定向补采（60 s），
全程真实 trace + SQL，E1/E2/E3 分层结论。

- [`v5_test/REPORT.md`](v5_test/REPORT.md)：完整报告（E1 状态事实 / E2 事件与唤醒关联 / E3 机制归因、数据质量、开销、UNKNOWN、UI 步骤）
- [`v5_test/traces/`](v5_test/traces/)：`cap1-overview.pftrace`（调度 60 s）、`cap2-blockwake.pftrace`（事件栈 + `sys_futex` 60 s）
- [`v5_test/configs/`](v5_test/configs/)：两套实际 TraceConfig + v57.1 官方 schema descriptor 及元数据
- [`v5_test/results/`](v5_test/results/)：每条 SQL 的 stdout / run.json / 渲染 SQL；[`v5_test/COMMANDS.md`](v5_test/COMMANDS.md) 为实际命令

主要结论（可复核）：慢请求分成两类——`dur≈10 ms` 的请求时间 **≥99.9% 在 Running**；
`wait≈34.5/18/16 ms` 的请求时间 **99.6–99.9% 在 Runnable**（睡眠 14–28 µs、排队 14–90 µs）。
原因：CPU 2 上只有同进程 `compute-1`(30.9%)+`compute-2`(35.3%)+`req-dispatch`(23.8%) 三者，突发窗口内 ≈90% 占核、~10 ms 片轮转；
CPU 1 基本空闲。切出栈 `dispatch_entry()→syscall(futex)`，唤醒栈 `enqueue_request()→run_one_cycle()→main`，
6 次唤醒全部落在主线程 `sys_futex` slice 内；helper→ipc-client 跨进程唤醒亦在 helper 的 futex syscall 内。
锁 owner、futex 地址、10 ms Running 内部工作 = UNKNOWN（未采集，不编造）。

## 应用时延 / ISP-SIF 测量（[`v6_test/`](v6_test/)，perfetto-latency-debugging v0.1.0 Candidate）

X5 imx678 linear **offline**（SIF→DDR→ISP）的四项时延测量设计。**本轮未采集**：板上无 imx678
（在挂 sc230ai ×4；rootfs 无 `imx678.ko`；kernel 树无驱动），按用户确认只交付方法学 + 埋点补丁 + 静态自验。
**0 条真实 trace、0 个实测数值**；sc230ai 数值不得外推到 imx678。

- [`v6_test/REPORT.md`](v6_test/REPORT.md)：四项边界（SIF 入队→ISP 出队 / 用户态 MCM_SCH→FRAME_DONE / 内核 ISP FS→FE / 内核 SIF FS→FE）、
  埋点地图、构建/部署/采集/分析步骤、证据边界与采集后自检清单
- [`v6_test/patches/`](v6_test/patches/)：内核 `camsys.sif2isp.queue` atrace 补丁（T1）+ cam-service HAL TrackEvent 补丁（T2，可选开关）
- [`v6_test/config/`](v6_test/config/)：`ftrace/print` + `track_event(camsys)` 主配置；仅 T2 的 TrackEvent 配置
- [`v6_test/sql/`](v6_test/sql/)：inventory、质量门、T1 双口径、T2、T3、T4 的 PerfettoSQL（8 个，TP v57.1 语法通过）
- [`v6_test/docs/build-verification.md`](v6_test/docs/build-verification.md)：编译/策略/SQL/补丁的静态自验记录

关键事实：运行中的 `vs_sif_nat.ko`/`vs_isp_nat.ko` 已含 `camsys.sif.frame`/`camsys.isp.frame`，**T3/T4 用现有模块即可采**；
T1 需替换新模块（vermagic 与板上 `6.1.83-DR-PL5.1_V1.0.20` 一致）；T2 需真实 Perfetto SDK 重编 libisc。
