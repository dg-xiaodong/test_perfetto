# perfetto-cpu-debugging v0.1.0-r1 Candidate — 定点修复测试报告

- 基线：`perfetto-cpu-debugging v0.1.0 Candidate`（首次上板版，安装副本 `/root/.dsh/skills/perfetto-cpu-debugging` 未改动）
- 输入：首次 X5 上板测试记录 [`cpu_v1_test/`](cpu_v1_test/)，重点为其 `REPORT.md` §8 四条问题
- 输出：本目录 [`perfetto-cpu-debugging-v0.1.0-r1/`](perfetto-cpu-debugging-v0.1.0-r1/)（完整可安装 Skill）
  + [`perfetto-cpu-debugging-v0.1.0-r1.diff`](perfetto-cpu-debugging-v0.1.0-r1.diff)（对 v0.1.0 的 unified diff）
- 定位：**候选版**，不是正式发布；未替换已安装的 v0.1.0，未重采板端数据。

## 1. 改了哪些文件、为什么

| 文件 | 类型 | 原因 |
|---|---|---|
| `sql/00-inventory.sql` | 重写 | 原文件含 5 条 SELECT，`query -f` 在 TP v57.1 报 `Result rows were returned for multiples queries`（v58.2 同样不适合）。改为单语句：按进程 CPU 排名，用来找 UPID |
| `sql/00a-trace-bounds.sql`<br>`sql/00b-thread-states.sql`<br>`sql/00c-counter-tracks.sql`<br>`sql/00d-stats.sql` | 新增 | 把原 inventory 的其余 4 项检查拆成各自单语句文件，能力不降级 |
| `scripts/make_config.py` | 修改 | `frequency` 与 `overview` 默认生成逐字节相同的配置。frequency 改为轻量路线（默认无 sched，`--with-sched` 显式加回）；缺 power 事件时退化为纯轮询并提示 |
| `configs/cpu-frequency.pbtxt` | 重新生成 | 与新 frequency 默认一致（power 事件 + cpufreq 轮询，无 sched） |
| `sql/04a-frequency-inventory.sql` | 新增 | 频率数据验收门：无 `cpufreq` 轨道/无样本直接判 `UNKNOWN`，并禁止读成 0 MHz |
| `sql/04-cpu-frequency.sql` | 修改 | 增加 `raw_unit` 列、注明必须先跑 04a、空结果语义（未采集 ≠ 0 MHz） |
| `tests/test_sql.py` | 修改 | 新增 8 个回归：单语句约束、inventory 五文件、频率门 4 种判定、无轨道时时间线为空 |
| `tests/test_configs.py` | 修改 | 新增/改写 6 个回归：frequency≠overview、`--with-sched`、无 power 事件退化为轮询、非法组合、静态配置差异 |
| `tests/real_trace_regression/` | 新增 | 真实 trace 回归脚本 + v57.1/v58.2 双版本原始输出归档 |
| `SKILL.md`、`references/02-frequency.md`、`references/04-platforms.md`、`README.md` | 修改 | 同步调用方式、轻量频率路线、验收顺序与单位说明 |
| `TEST_REPORT.md`、`PROVENANCE.md`、`MANIFEST.json` | 修改 | 追加 r1 验证记录与变更来源；版本号 `0.1.0-r1`、状态 `candidate-r1`（63 个文件哈希） |
| `cpu_v1_test/REPORT.md` | 修改 | 第 4 项：证据表述改严谨；补 C++ 负载如何被验证；时间差声明标明可复算脚本 |
| `cpu_v1_test/logs/check_alignment.py`、`logs/alignment_check.txt` | 新增（派生物） | 仅读归档的 `fixture.log` + `sql_out/04-*`，复算 tick 与 trace 的 20.8–35.2 µs 偏差 |

未改：`00-routing.md`、`01-scheduling.md`、`03-profiling.md`、`05-quality.md`、`06-ui.md`、`sources.md`；
未改复用自 Memory Skill v1.0.2 的三个 shell 脚本（SHA-256 不变）；未改 CPU 时间桶/episode 算法。

## 2. 四项问题是否解决

| # | 问题 | 状态 | 证据 |
|---|---|---|---|
| 1 | Inventory SQL 兼容性（P0） | **已解决** | 5 个单语句文件；真实 trace 上 TP v57.1 与 v58.2 各 7/7 PASS，两版输出逐字节一致；单语句约束已写成单元测试（`test_inventory_files_are_single_statement`） |
| 2 | Frequency 与 Overview 路由区分（P1） | **已解决** | 默认配置不再相同：frequency 无 `sched_switch`，含 `power/cpu_frequency`、`power/cpu_idle`、`cpufreq_period_ms: 500`；overview 保留 sched。`--with-sched` 显式加回；无 power 事件时纯轮询并打印 NOTE；新增 6 个配置回归测试 |
| 3 | Frequency SQL 数据验收（P2） | **已解决** | 新增 `04a` 判定门（4 种 verdict）；SQLite 正反例 5 个测试；真实 scheduling trace 上判 `UNKNOWN` 且文案明确 "do NOT read as 0 MHz"；`04` 暴露 `raw_unit` 并保留 kHz→MHz 换算 |
| 4 | 报告证据表述 | **已解决** | `cpu_v1_test/REPORT.md` §5.3/§6 改为「可排除调度排队/抢占，不能独立排除锁/同步（UNKNOWN）」；补 C++ 语义与 4 条负载验证；`logs/fixture.log` 确认存在（已归档，10 个 tick），偏差声明附复算脚本与输出 |

## 3. 实际测试结果

| 测试 | 结果 |
|---|---|
| `python3 -m unittest discover -s tests -v` | **33 passed / 0 failed**（原 22 + 新增 11），原始输出见 `perfetto-cpu-debugging-v0.1.0-r1/tests/local_test_run.txt` |
| `sh -n scripts/*.sh` | 4/4 通过 |
| `validate_config.py --check-resources` | `[PASS] resources: 25 essential files + 4 configs` |
| 四份静态配置结构预检 | 4/4 PASS（官方 schema 仍 UNKNOWN） |
| 真实 trace · TP v57.1 | 7/7 PASS：`00-inventory` 30 行（目标进程 cpu_ms=2684.71）、`00a` 1 行、`00b` 7 行、`00c` 0 行、`00d` 0 行、`04a` 1 行、`04` 0 行 |
| 真实 trace · TP v58.2 | 7/7 PASS，且与 v57.1 输出逐字节一致 |
| 频率门在真实 trace 上的判定 | `UNKNOWN: no cpufreq counter track -> frequency not collected (do NOT read as 0 MHz)` |
| frequency vs overview 默认配置 | `diff` 仅差 sched 三行（frequency 更轻）；静态配置同样不同 |

真实 trace：`cpu_v1_test/cpu.pftrace`，sha256 `ba40ba562ab097ea1651e5a2897c741ed15d41da34b40bfbfe80ce9c863e0501`；
回归原始输出归档在 `perfetto-cpu-debugging-v0.1.0-r1/tests/real_trace_regression/{tp-v57.1,tp-v58.2}/`，
复跑：`sh run_regression.sh <trace> <trace_processor_shell> <outdir> <origin-label>`。

## 4. 尚未验证的范围

- **未重新上板采集**；未在 X5 上重测 frequency 路由。
- 未在**带 cpufreq 数据的真实 trace** 上执行 `04-cpu-frequency.sql`（当前无此 trace）；该路径只有 SQLite 正反例。
- 未做官方 collector descriptor schema 校验（仍 UNKNOWN）。
- 未对 `01..08` 其它 SQL 做真实 TP 回归（本轮只覆盖 inventory 与频率门）。
- 未做 Perfetto UI 自动化；未扩展 `linux.perf` / DVFS / Android。
- X5 上 `power/*` 是否齐全、`linux.perf` 权限/符号能力：仍 UNKNOWN（frequency 路由首次上板不在本轮范围）。

## 5. 基线保留

- 已安装的 v0.1.0：`/root/.dsh/skills/perfetto-cpu-debugging`（**未改动**）。
- r1 以独立目录存在，未覆盖安装；未修改 Memory Skill v1.0.2。
