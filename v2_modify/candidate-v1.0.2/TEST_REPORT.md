# 验证报告

日期：2026-10-14。

## 范围

本次在主机容器执行本包脚本/SQL算术fixture/C程序检查。没有连接用户板卡，没有修改生产服务，没有取得新的真实业务trace。

| 项目 | 状态与范围 |
|---|---|
| 配置生成契约 | 运行tests/test_config.py：平台/API、目标名称、事件门槛、采样与buffer参数、10种配置构造 |
| SQL口径 | SQLite合成fixture验证符号分配累加、窗口前基线、UPID/heap隔离、调用栈累计、ART快照不混合 |
| 配置验证器 | 小型fixture protobuf schema测试严格字段/枚举、范围、依赖；不是官方TraceConfig解析 |
| Skill包结构 | frontmatter、内部链接、11个用户来源与10份配置产物检查 |
| Shell | sh -n及临时tracefs fixture检查事件输出和状态不变 |
| C测试程序 | gcc -Wall -Wextra -Werror构建；heap/spike/churn/mmap模式以小规模参数在本机执行 |
| 对应版本官方TraceConfig schema | **未执行**：没有本环境可用的匹配官方descriptor/protoc |
| 真正的Trace Processor执行与Perfetto SQL标准库导入 | **未执行**：本环境没有相应可执行文件；SQLite fixture不能替代 |
| Perfetto UI打开trace/截图/交互验证 | **未执行**：交付的是官方对应的UI操作配方，不是本次UI实测 |
| X5 / Android板端采集、heapprofd端到端 | **未执行**：需要真实设备和匹配SDK组件 |
| 独立Agent行为A/B回归 | **未执行**：提供28个行为测试场景，未把人工编写用例算作实测通过 |

## 测试结果

最终执行结果见本文件后续记录；成功只覆盖上表明确列出的本地范围。程序中的事件/对象数据是fixture或本机小测试，不是X5测量数据。

## 交付边界

本包为可使用并继续验证的Skill及工程配方，不附带官方二进制，不保证所有未来版本字段、UI命名或目标系统权限不变。具体采集时由Skill按“schema→运行条件→实际数据→分析/UI”逐级验收。

## 本次主机测试记录

`python3 -m unittest discover -s tests -v`：**35项通过，0失败，0跳过**（环境中已提供Python protobuf）。其中18项配置契约、6项SQLite统计口径、6项fixture schema严格性、5项包结构检查。

gcc在`-Wall -Wextra -Werror`下构建memprobe通过；heap模式使用1MiB/1ms/2轮，spike/churn/mmap各使用1MiB/1ms/1轮，均正常退出并打印结束事件。没有在这里执行300MiB压力测试。

只读survey的临时tracefs fixture输出与输入事件文件逐字一致，tracing_on保持0；`sh -n`通过。独立CLI smoke中Native配置完整输出；在Linux上请求java-graph被拒绝且stdout没有残留半份配置。

## 1.0.1 候选版（范围受限修改）

新增测试：`test_targets.py`（候选发现/路径名/歧义）、`test_dump_capability.py`（可见 dump/零宽窗口/v57.1 降级）、`test_validator.py` 的 `PreflightTests`（资源完整性、deploy-name、ELF PT_INTERP、退出码）。

- 本地单测：**65 项通过**（`python3 -m unittest discover -s tests`；含 2026-10-17 预检修复新增用例）。
- 真实 TP 回归（v58.2 + X5 A/B 真实 trace）：候选查询各返回 2 行、唯一 data-bearing；`sql/10` 在 A 报 `dumps=1/dur=0`、B 报 `dumps=6/dur=0`；`sql/03` 在 B 得到 `8,8,8,0,0,0`。
- 未执行：Perfetto UI 检查、X5 现场采集（本轮不要求）、独立 Agent A/B（材料见 `tests/agent_ab/`）。
- 预检脚本只证明静态前提；**运行期就绪/注入/停止/flush 仍需运行期证据**（notify-fd 字节、trace 内容、stats/日志）。

## 2026-10-17 修订（定点修复）

- `scripts/validate_config.py`：支持同行/多目标/路径归一化；glob、无 cmdline、非 ELF、截断 ELF 判 UNKNOWN（rc=2）；configs 检查可读且非空；运行期未验证改为 `[NOTE]`，不影响退出码。
- `references/02-native.md`：上界证据**不得**断言"实际持有与预期不符"。
- `tests/agent_ab/rubric.md`：符号无数据接受 UNKNOWN；UNKNOWN 后禁用 interval 推断"不符"；重新评分 6/9 vs 8/9。
- 真实 TP 回归脚本 `verify/tp_check.py` 加固断言并新增故障注入测试（8 例）。

## 2026-10-17 第二轮定点修复

- `scripts/validate_config.py`：`process_cmdline` 改为**结构感知解析**——跳过注释与字符串、按整词匹配标识符、只接受 `heapprofd_config` 块内字段；括号/字符串不闭合或字段在块外 → UNKNOWN(rc=2)；归一化按 `NormalizeCmdLine`（截断首个 `@` 后取 basename）。
- `verify/tp_check.py`：Live 结果校验 `ts/value/series` 三列、ts 为整数且严格递增、ts 与 dump 轴一致；新增 5 个故障注入反例。

## 1.0.2 候选版（增量）

日期：2026-10-17。范围：普通 Linux 生命周期脚本、CPU 时间桶/spike SQL、质量指南与回归；
不扩展 Android ART/heap graph/OOM，不改变目录体系，不部署。

### 实际执行

- `python3 -m unittest discover -s tests -v`：**73 项通过，0 失败，0 跳过**。
  新增 `tests/test_cpu_sql.py`（6 项：跨桶 200 ms=100+100、150 ms 不假 spike、
  350 ms 正确 spike、安静间隔两段、窗口裁剪、UPID 过滤）与
  `tests/test_linux_scripts.py`（2 项：`sh -n`、mock tracebox 的普通/heapprofd
  生命周期与 pull 失败传播）。
- 新增 SQL 在主机 Perfetto v58.2 Trace Processor 上对本地 trace（非 `worker_app`）执行：
  `sql/11` 输出目标 UPID 的 1 s CPU 桶（例：约 55–56 ms/s）；`sql/12` 在阈值 50 ms
  时输出一个 11 s episode。记录见 `tests/tp_cpu_sql_v58.2.txt`。
- 新增 Shell 脚本在主机用 mock tracebox/app 执行：普通 trace 会话、heapprofd 会话、
  host pull 成功/缺失失败均通过；真实板端未执行。
- 独立 Agent 行为对照：B1/B2/B3 × v1.0.1/v1.0.2 共 6 个独立子会话已执行，
  原始输出与对照见 `tests/agent_v102/results/COMPARISON.md`。单次运行、无温度控制，
  不是统计基准。

### 未执行

- 未连接 X5/Android；未运行真实 tracebox、heapprofd、perf。
- 未用 v57.1 descriptor 做 schema 校验；仅 v58.2 静态/TP 执行。
- 未打开 Perfetto UI 检查新 SQL 的 debug track。
- 未证明性能因果；C2 的真实 producer 注册/flush 时序仍未验证。
