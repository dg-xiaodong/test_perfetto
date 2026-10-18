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
