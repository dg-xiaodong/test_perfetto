# 安装交接

## 本次只安装（推荐直接发给安装 Agent）

请安装完整 `perfetto-latency-debugging v0.1.1 Candidate`。先检查已有同名版本，不静默覆盖。解压后运行：

```sh
python3 scripts/verify_package.py
python3 scripts/validate_config.py --check-resources
python3 -m unittest discover -s tests -v
```

报告实际安装路径、版本、哈希和测试结果。本次不下载 SDK、不连接板子、不修改应用、不自动开始场景测试。SDK/TP 缺失导致真实集成测试跳过是如实状态，不需为了让测试全绿自行改用假 SDK。

## 本次新能力

跨进程“同一 Slice”先读 references/01-contract.md 与 02-sdk.md，必要时使用 `examples/cpp/cross_process_slice_demo.cc` 的 System Backend 双进程最小示例，确认 Trace Processor 真实配对。`Flow::Global()` 用于不同事件的因果交接。缺 SDK、无 System sockets 或 Frame/Request ID 不可靠则记录 UNKNOWN/BLOCKED，**不替换生产 SO 或重启板卡**。

## 获准进行首次集成测试时

先取得经过校验的真实 SDK v58.2，运行 examples/cpp 的短 InProcess 例子，通过真实 TP 验证应用 Slice、实际 Flow 和 Counter；然后才测试 X5 System backend + ftrace。每一步的错误保留原日志，不现场改判据凑通过。

`tests/SCENARIOS.md` 已区分主机测试、真实集成、板端和 Agent 独立诊断。首次不做自启动、复杂守护进程、UI 自动截图或压力实验。
