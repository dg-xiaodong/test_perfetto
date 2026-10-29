# perfetto-latency-debugging v0.1.1 Candidate — 测试报告

日期：2026-10-20。此次是 **v0.1.0 的限定范围修订**，不宣称完整跨进程链路已经验证。原 v0.1.0 报告保存在 [`evidence/v010-TEST_REPORT.md`](evidence/v010-TEST_REPORT.md)。

## 1. 修改与测试范围

新增：跨进程同一 Slice 的 `Track::Global()` 选型指南，区分跨进程 Flow，明确全局 UUID 的身份、串行、重启和缺失事件约束；为 System Backend 增加两个独立进程的最小 C++ 源码、构建入口和 L8 验收用例。没有更改 `latency.v1` 请求字段与判断语义，不更改原分析 SQL、`analyze.py`、`latency_core.py`、采集或配置校验逻辑。仍保留单 Category 策略限制。

## 2. 本地执行证据

| 检查 | 状态 | 说明 |
|---|---|---|
| v0.1.0 RED 对照 | 6 项专项测试中出现 13 处 FAIL 和 1 处 ERROR | 缺选型指南/双进程示例/L8 验收；见 `evidence/v011-red-summary.txt` |
| v0.1.1 完整 unittest | **92 项，91 PASS / 1 SKIP，0 FAIL** | 包含原 86 项（85 PASS、1 SKIP）与新增 6 项静态专项测试；`evidence/v011-local-tests.txt` |
| 原生 SDK v58.2 编译 `latency_xproc_demo` | **NOT_RUN** | 本环境没有配套真实 `perfetto.h`/`perfetto.cc`，不能拿 stub 冒充构建成功 |
| Trace Processor v57.1 / v58.2 跨进程配对 | **NOT_RUN** | 未产生两个独立 Producer 的实际 `.pftrace` |
| X5 Board + 第三方 SO | **NOT_RUN** | 本轮未访问板端/修改产品进程 |
| 独立 Agent 短 Prompt A/B | **NOT_RUN** | 后续与 v0.1.0 对照；不以静态说明测试代替 Agent 能力证明 |

单元测试原有跳过项：`test_real_sdk_inprocess_and_tp`，真实 SDK/TP 未提供。新示例也需真实 SDK + System Backend + TP 共同验证，离线文档检查**不算该端到端测试通过**。

## 3. 真正的新增能力验收门槛

测试者使用 `examples/cpp/README.md` 的 `latency_xproc_demo` 双进程配方（必须新握手目录、唯一全局 UUID），先确认进程 A 与 B 连接同一采集会话且类别 enabled。用真实 Trace Processor 得到**一条完整 `xproc.global_track.demo` Slice**；再核对 Track ID、两进程 PID/日志和业务 Request ID。缺 END、重用 UUID、重叠、跨 stream 同帧号不能被错误认为“正常配对”。详细步骤见 `tests/SCENARIOS.md` 的 L8。

若真实 TP 把事件分离成不同 Track、仅得到开放 Slice 或数据丢失，标 FAIL/UNKNOWN，保留原始证据。不要偷偷退回原子 TracePacket 方案来宣布 Global Track 验收通过。SDK 不可用的情况报 BLOCKED 而不是 PASS。

## 4. 打包与回归

打包前后必须运行：

```sh
python3 -B -m unittest discover -s tests -v
python3 scripts/validate_config.py --check-resources
python3 scripts/verify_package.py
```

正式 ZIP 需校验 CRC、SHA256、路径安全和解压后回归；具体封包核验数值由构建时实际输出决定，不提前填写。此报告中测试结果不等于真实跨进程业务诊断结果。
