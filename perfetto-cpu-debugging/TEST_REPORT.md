# perfetto-cpu-debugging v0.1.0 Candidate — Verification

日期：2026-10-18。本 Candidate 在当前制作环境完成**主机本地验证**，**没有**在 RDK X5 实际采集新的 CPU Trace。

## 本地执行记录

- `python3 -m unittest discover -s tests -v`：**22 项通过、0 失败**；原始输出见 `tests/local_test_run.txt`（配置生成/资源/静态校验、shell、SQLite 夹具和跨桶反例）。
- 全部四份 `configs/*.pbtxt` 用 `scripts/validate_config.py` 做**结构预检**，不是官方 descriptor schema。
- `sh -n scripts/*.sh` 检查 Shell 语法；复用的 `linux_session_lib.sh`、`linux_trace_session.sh`、`host_pull.sh` SHA-256 与 Memory Skill v1.0.2 冻结源相同。
- `examples/cpu_probe.c` 在主机使用 gcc 构建为临时可执行文件并运行（记录在测试日志）。
- `sql/01/02/03/04/05/06/08` 以 SQLite 合成 fixture 执行；**不是** Trace Processor 真实运行。`sql/00/07` 仅人工核对字段/官方 schema 文档，没有对真实 perf_sample 数据执行。

## 没有执行、不可推定通过

- 没有目标采集器版本匹配的 `trace_config.desc`，**正式 schema 验证 UNKNOWN**。
- 没有新 X5 CPU Trace；实际 `sched_waking` / cpufreq / linux.perf producer/PMU/权限支持 **UNKNOWN**。
- 未做 Perfetto Trace Processor 上新增 SQL `02/03/04/07/08` 的真实 Trace 回归；真实 TP 兼容性 **UNKNOWN**。
- 未做 X5 板端采集、Android 端到端、Perfetto UI 操作/截图。
- 历史可信来源：Memory Skill v1.0.2 曾在 X5 验证普通 Trace 脚本和 CPU 时间桶/episode 核心算法，但**不能冒充本 Candidate 的新板端测试**。

## 使用与发布说明

这是可交付、可供 Agent 测试的**v0.1.0 Candidate**，而不是可承诺全平台通过的 Stable Release。下一步只做最小 CPU-bound、线程唤醒、频率和 `linux.perf` 能力 smoke，按采集器版本核对字段。不要为了“全量测试”主动执行长时间压力、改变系统策略或重启生产服务。

## v0.1.0-r1 定点修复验证（2026-10-18）

依据：首次 X5 上板报告 `cpu_v1_test`（GitHub `dg-xiaodong/test_perfetto`）。只处理四项，不扩展功能。

### 修改

1. `sql/00-inventory.sql` 拆为单语句 `00 / 00a / 00b / 00c / 00d`，兼容 `query -f`（v57.1 与 v58.2）。
2. `scripts/make_config.py frequency` 改为**轻量**路线（默认不采 sched，`--with-sched` 显式加回）；
   `overview` 仍为综合路线；缺 power 事件时自动退化为纯轮询并打印 NOTE。
3. 新增 `sql/04a-frequency-inventory.sql` 频率数据验收门（无轨道/无样本 → UNKNOWN，禁止读成 0 MHz）；
   `sql/04-cpu-frequency.sql` 暴露 `raw_unit` 并注明 kHz→MHz。
4. 文档同步：`SKILL.md`、`references/02-frequency.md`、`references/04-platforms.md`、`README.md`。
   （第 4 项“报告证据表述”落在外部测试记录 `cpu_v1_test/REPORT.md`，不进本包。）

### 已执行

- `python3 -m unittest discover -s tests -v` → **33 passed / 0 failed**（原 22 + 新增 11；
  新增覆盖：单语句约束、inventory 五个文件、频率门 4 种判定、frequency/overview 配置差异、
  `--with-sched`、无 power 事件退化为轮询、非法参数组合）。
- `sh -n scripts/*.sh` → 全部通过。
- `scripts/validate_config.py --check-resources` 与四份静态配置结构预检 → PASS。
- **真实 trace 回归**（`cpu_v1_test/cpu.pftrace`，sha256 `ba40ba56…3e0501`，只读，不重新采集）：
  TP **v57.1** 与 **v58.2** 各 7/7 PASS，两版本输出逐字节一致：
  `00-inventory`(30 行，目标进程 cpu_ms=2684.71)、`00a`(1 行)、`00b`(7 行)、
  `00c`(0 行)、`00d`(0 行)、`04a`(1 行)、`04`(0 行)。
  `04a` 在该 scheduling 路由 trace 上输出
  `UNKNOWN: no cpufreq counter track -> frequency not collected (do NOT read as 0 MHz)`。
  原始输出归档在 `tests/real_trace_regression/tp-v57.1/` 与 `tp-v58.2/`，复跑脚本
  `tests/real_trace_regression/run_regression.sh`。

### 未执行 / 不可推定

- 未重新上板采集；未在**带 cpufreq 数据的真实 trace** 上跑 `04`（当前无此 trace，频率时间线只用
  SQLite 正反例验证）。
- 未做官方 collector descriptor schema 验证；未做 Perfetto UI 自动化。
- 未对 `01..08` 其它 SQL 做真实 TP 回归（仅 inventory 与频率门做了）。
- X5 上 CPU 频率、`linux.perf` 的 producer/权限/符号能力仍为 UNKNOWN。
