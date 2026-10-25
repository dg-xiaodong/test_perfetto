# perfetto-latency-debugging v0.1.1 Candidate

独立可安装的 Agent Skill。仅围绕 **Perfetto TrackEvent 埋点**实现 C/C++ 应用时延追踪；不依赖安装另外三个 Skill，不提供日志转换路线，不自动给所有函数插桩。

## 安装与检查（不需要板子、不联网）

将整个 `perfetto-latency-debugging/` 目录放进 Agent 支持的 Skills 目录。入口是 `SKILL.md`；不要只复制入口文件，不静默覆盖已有同名版本。

在包根执行：

```sh
python3 scripts/verify_package.py
python3 scripts/validate_config.py --check-resources
python3 -m unittest discover -s tests -v
```

Python 3.9+ 的标准库足够执行常规本地测试与分析。真正的 protobuf Schema 校验额外需要 `google.protobuf`；C++ 示例需要真实 Perfetto SDK、C++17 编译器和 CMake；解析 `.pftrace` 需要用户已有的 Trace Processor。常规测试不会自动下载它们。

## 包内能力

| 资源 | 用途 |
|---|---|
| `examples/cpp/` | 三线程有界流水线、多流/重试/终态；新增 `latency_xproc_demo` 双进程 Global Track 冒烟示例（真实 System Backend 待验） |
| `scripts/make_config.py` | TrackEvent-only 及可选 ftrace 的有限时配置 |
| `scripts/validate_config.py` | 严格配方策略；可选外部 descriptor 校验 |
| `scripts/record.sh` | tracebox 系统 socket、notify-fd、子进程身份、超时/失败检查 |
| `scripts/analyze.py` | 从真实 TP 导出事件，再运行身份/生命周期/Flow 完整性分析 |
| `sql/` | 单结果集 inventory、原始事件、Flow、函数分布、帧间隔、线程状态叠加 |
| `tests/` | 正常与错误关联、缺失/截断、并行、配置、SQL fixture、Shell 桩、可选真实集成 |

`analyze.py` 生成 `analysis.json`、`requests.csv`、`stages.csv`、`queues.csv`、`flows.csv`、`function_summary.csv`、`frame_summary.csv`、`frame_intervals.csv` 和 `ui-request-track.sql`。

**SQL 的可执行结果不等于业务通过。** 包内 10–14 号 SQL 是检查/探索视图；综合判断以 `analyze.py` 的契约检查为准。完整性仅说明满足已声明契约，不保证所有业务依赖或源码阶段都已被观测。

## v0.1.1 范围

本版仅补充跨进程同一个 Slice 的 `Track::Global()` 选型指导、身份/Descriptor/Session 验证规则与最小双进程示例；原 `latency.v1`、分析 SQL 与配置约束保留。与跨进程不同 Slice 的 `Flow::Global()` 明确区分。**本版不是全功能跨进程分析器，也没有修复多 Category 策略问题。**

## 第一个技术关卡

先按 [C++ 示例说明](examples/cpp/README.md) 用真实 SDK 编译，生成本机 InProcess Trace 并用真实 TP 解析；再在 X5 验证 System backend + ftrace。不要把 host 模拟、Schema 或 SQLite fixture 当作板端通过。

外部依赖网络不可用时，不循环尝试大量安装方式；记录 BLOCKED，可由主机提供校验过的离线 SDK。具体边界见 [TEST_REPORT](TEST_REPORT.md)，安装交接见 [AGENT_HANDOFF](AGENT_HANDOFF.md)。

来源、固定版本和复用脚本说明见 [sources](references/sources.md)、[NOTICE](NOTICE.md)。
