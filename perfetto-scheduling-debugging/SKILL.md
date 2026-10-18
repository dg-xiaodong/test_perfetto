---
name: perfetto-scheduling-debugging
description: "Use when diagnosing Linux/Android thread stalls, off-CPU waits, wakeup latency, runnable contention, suspected synchronization blockage, or scheduling wakeup chains with Perfetto, especially when CPU utilization alone does not explain request latency."
---

# Perfetto Scheduling 调试 · v0.1.0 Candidate

目标：围绕**一次具体等待**给出证据，不强行解释完整因果链。独立可安装，不依赖 Memory/CPU Skill。

## 选路

| 输入 / 尚未解决的问题 | 执行路线 |
|---|---|
| 线程慢、CPU 不高、已有 trace | [Overview](workflows/overview.md)：找真实 UTID/窗口，分解 Running、Runnable、睡眠；有业务日志时分开排队与处理 |
| 已找到长等待，需要知道在哪里停下、谁从哪条路径唤醒 | [Block/Wake](workflows/block-wake.md)：定向事件抓栈与同一次等待关联 |
| 直接唤醒者仍不足以解释问题 | [Wakeup Chain](workflows/wakeup-chain.md)：只沿已观察的关系展开 |
| 需要确认 futex 活动 | [Futex](workflows/futex.md)：条件增强，不自动识别锁所有者 |

先读对应 workflow；执行前读 [平台](references/platforms.md) 与 [验收](references/quality.md)。需要界面时读 [UI](references/ui.md)。不默认全读文档或全开数据源。

## 执行

1. 已有 trace 先分析，不重采。新采集先只读 `scripts/survey.sh`，核实版本、事件、目标 TID、CPU 数、页大小、可写目录与余量。不重复询问已知信息。
2. `scripts/make_config.py --help` 生成完整配置；overview 默认无 perf。block-wake 必须有明确 TID、事件列表和 event format，不生成无过滤全系统抓栈。
3. `python3 scripts/validate_config.py --check-resources`；配置策略校验与同版本官方 schema 校验分开。缺 descriptor 记录 SCHEMA_UNKNOWN。
4. Linux 用 `scripts/record.sh`，只管理本次采集子进程；不重启业务、不改 sysctl/governor、不抢占他人 tracing。拉回用 `scripts/pull.sh`，不保存口令。
5. 先执行 `sql/00*.sql` 清点，每个文件**独立**执行。`scripts/render_sql.py` 填入数值参数，`scripts/run_query.py` 保存实际 TP 输出、错误与退出码。
6. `sql/05-event-pair.sql` 只在实际核实 perf 流来源和时钟后设置两个 proof 参数。session ID 不按配置顺序猜测；歧义和缺失不取最近栈凑答案。

## 口径与停止

- E1=状态事实；E2=事件关联；E3=机制归因。执行成功、唯一候选、Critical Path 都不自动得到 E3。
- 睡眠恢复可运行不等于拿到锁或业务条件成立；Sleeping 不自动等于 mutex。Off-CPU 不全部算阻塞。
- 切出栈属于当时的执行上下文，不是 `next_pid` 恢复执行后的栈。跨进程唤醒者不能被目标进程 scope 过滤。
- 所有时间在同一 Trace 规范时钟域。统计用半开区间相交；全核占用必须包括其他进程；请求入队到完成不能只算处理时间。
- 默认只做最小充分采集。补采前写出**一个未决问题和它需要的新证据**。无可验证关系时保留 UNKNOWN，不遍历邻近所有线程，不做 UI 自动化。
- 调度/调用栈不能直接回答业务锁所有者；需要业务语义时提出最小补证，不自行添加生产埋点。

交付：实际 trace/配置/版本、目标与窗口、查询及结果、关联缺失原因、E1/E2/E3 结论、必要手动 UI 步骤。无数据不编造。

本版的 SQL 与工具已做本机离线验证；真实 TP、C1/C2/C3 X5 事件抓栈与 UI 验收边界见 [TEST_REPORT](TEST_REPORT.md)。
