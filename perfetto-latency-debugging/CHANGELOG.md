# v0.1.1 Candidate — Scope and provenance

源包：`perfetto-latency-debugging-v0.1.0-candidate.zip`（SHA256 `457ae9847f14ea174588ef1a70b8ffecfddfe9de4ff3d5c5c3e9ddeeb455a954`），未修改源包。变更限制为**跨进程同一 Slice 的 Track 选型与最小专项验收**。

- `SKILL.md`：增加跨进程 Begin/End 的触发说明，链接到 SDK 跨进程指南。
- `references/01-contract.md`：加入线程 Track、全局 Track 与全局 Flow 的选择表；说明多路帧/重启/丢 END 情况下的身份约束。
- `references/02-sdk.md`：官方 v58.2 API 依据，System Backend、多 Producer、Descriptor/Clock/Load 检查和实际 Trace 验证边界。
- `examples/cpp/cross_process_slice_demo.cc`：新增最小双进程 System Backend Demo；仅验证 Global Track，不代替 `latency.v1` 请求分析器。
- `examples/cpp/CMakeLists.txt`、`examples/cpp/README.md`：构建目标与手动真实采集步骤。
- `tests/test_cross_process_guidance.py`、`tests/SCENARIOS.md`：六项新的离线回归及 L8 真实验收条件。先写测试，在 v0.1.0 上 RED；详情见 `evidence/v011-red-summary.txt`。
- README/测试报告/交接、来源索引、版本标记及包校验清单随版本升级。

**未改**：原 `latency.v1` 字段/状态定义、SDK 三线程流水线功能、PerfettoSQL、`analyze.py` / `latency_core.py` 分析逻辑、配置校验策略、collector 与板端脚本执行行为。当前仍强制单 Category，作为后续独立问题处理。

**尚未完成**：真实 SDK 编译新 Demo、System Backend 跨进程配对、实际 Trace Processor 结果、X5 板端、Agent A/B。静态指导检查与原有模拟测试不能证明这些能力已通过。旧报告保存在 `evidence/v010-TEST_REPORT.md`。
