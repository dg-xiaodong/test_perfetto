# Scheduling v0.1.0 场景验收矩阵（维护者，不交给盲测窗口）

| 场景 | Ground Truth | 真实trace的必要验收 | 本包已有 |
|---|---|---|---|
| C1 同进程主动等待 | 构造程序、返回值、PID/TID/时钟日志 | 切出栈属于waiter；waking栈属于waker；两段等待边界 | SQLite关联正例、主机程序运行；板端未测 |
| C2 Runnable争用 | CPU affinity与同核竞争负载；线程CPU/墙钟 | 状态确认Runnable，竞争者来自全系统，不把睡眠/队列算成R | 区间与全系统竞争fixture；板端未测 |
| C3 跨进程唤醒 | 共享futex父子身份/返回码 | 不因进程scope丢waker；关联正确PID生命期、UTID、CPU与事件来源 | 跨进程fixture、主机程序运行；板端未测 |
| C4 多级依赖 | 独立构造的关系图和阶段日志 | 只沿已证实边展开，最后waker不等于完整锁链 | 直接关系查询，不声称全图已实现/验证 |
| C5 缺失/歧义 | 合成副本明确删除/复制某些事件与栈 | SOURCE/CLOCK/STACK_UNKNOWN 或 AMBIGUOUS，不就近补栈 | 错UTID/CPU/source、缺栈、重复样本等反例 |
| C6 超时/信号/未知 | 返回码、谓词状态、时钟日志 | 不把恢复可运行解释为条件成立 | 不完整边界/IRQ/上下文未知反例；超时信号板端未测 |

T1 配置，T2 数据，T3 分析对Ground Truth，T4 新Agent短Prompt。配置成功不能替代任何下一层。事件抓栈缺失但如实降级不是“核心能力已通过”。

可用短Prompt：
> 服务里的一个线程偶尔卡20ms，CPU看起来不高。使用此Skill实际采集并查原因，不改系统与业务，给出trace和有证据的结论。

构造窗口与诊断窗口分开；不公开答案后再声称严格盲测。保留首轮原始输出；先评分，再反馈。核对身份、窗口、source/cpu/栈归属、是否过度补采以及任务耗时，不仅检查预期文字。

真实Trace Processor回归：
```sh
TP_BINARY=/absolute/trace_processor_shell TP_TRACE=/absolute/input.pftrace \
  python3 -m unittest discover -s tests -v
```
该可选测试只跑inventory，完整事件关联仍需C1-C3的目标参数和真实来源/时钟校验。用`run_query.py`保存实际输出，不只写PASS摘要。
