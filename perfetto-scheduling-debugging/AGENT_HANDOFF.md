# 安装与首轮测试交接

## 给安装 Agent 的短指令

> 请安装此 ZIP 中完整的 `perfetto-scheduling-debugging` v0.1.0 Candidate。先检查已有同名目录；有则备份或独立安装，不静默覆盖。运行 verify_package.py、--check-resources 和本机 unittest，报告实际路径/版本/结果。不要上板、不要修改包、不要扩展功能，完成后停止。

## 给独立诊断 Agent 的短指令

> 使用 perfetto-scheduling-debugging。X5 上一个 C++ 工作线程偶尔卡住，但整机 CPU 不高。服务与日志路径由我提供，请实际采集并分析它在等 CPU 还是在阻塞，必要时查阻塞和唤醒路径。不要改系统或业务；保留真实 Trace 和 SQL，证据足够就结束，不做 UI 自动化。

先确认真的存在目标程序，不搜索一个虚构的进程。需要受控测试时，由独立构造窗口编译 `examples/schedprobe.cpp`；构造窗口保存源码、PID/TID、返回码和 Ground Truth，诊断窗口只拿服务身份、符号和允许的业务日志。不要把 C1/C2/C3 的预期答案同时交给诊断窗口。

第一轮先完成 C1 → C2 → C3，可逐项测试，不自动在一次任务中跑完全部。C3 必须验证跨进程唤醒者没有被 scope 过滤；时间采样成功不能替代事件触发采样验收。板端失败保留证据，不现场偷偷修改被测 Skill。

`tests/SCENARIOS.md` 是给维护/评审者的验收标准，不是给盲测窗口的长 Prompt。首轮回答和工具调用记录冻结后，再查 Ground Truth。当前 ZIP 是 Candidate，不是发布、不是部署授权。
