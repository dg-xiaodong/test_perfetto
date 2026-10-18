# 单次等待关联契约（本 Skill 的实现规则）

来源：S1-S5。官方提供事件抓栈方法与表语义；下述保守关联算法由本包实现，不是宣称官方已有自动锁根因查询。

## 身份与范围

- 一次查询只针对一台机器、一个 Trace 内的实际 UTID、wait_id。多机器合并 trace 不在 v0.1.0 自动关联范围。
- 配置使用 Linux TID；样本和 SQL 关联使用 UTID。必须记录进程生命期；TID 已退出/复用时重新生成配置，不跨期沿用。
- 业务日志用自身时钟记录，需 ClockSnapshot 或实际配对证明转换。SQL 只消费 TP 已归一化的 ns，不用 wall-clock 字符串硬拼。

## 切出侧

候选等待来自一个 S/D/I `thread_state`。必须找到同一 UTID 的正长度 `sched_slice`，结束恰等于该等待开始；多条/缺失保持 BOUNDARY_INCOMPLETE。选择确认属于 switch 流的样本，要求采样 UTID =目标 UTID、CPU=该切出CPU、时间在经验证的容差内。

不使用 next_pid 作为用户栈拥有者；prev/next 过滤只是触发条件，当前采样上下文必须另核对。

## 唤醒侧

等待结束后必须是直接邻接 R/R+，再直接邻接 Running。提前信号、超时、再次阻塞等不自动解释成条件满足；多个等待分别保留。

从 ftrace_event 的 sched_waking 找事件参数 pid=目标Linux TID，事件时间接近 R起点，执行UTID与 thread_state.waker_utid 一致。然后关联已确认 waking 流中同一执行UTID、同一事件CPU的样本。唤醒CPU不必等于切出CPU或最终运行CPU。

`irq_context=1` 或未知时，不将当时执行任务当成业务锁持有者。irq_context 缺列时，完整查询不适用：先跑概览并标出缺列，不创建假0列。irq_context 为NULL时查询保留 CONTEXT_UNKNOWN；可手动看候选样本，但不能改字段凑完整关联。

## 唯一性、缺失和质量

- 不依据会话序号推断流类型。timebase 名、track metadata、实际 config 和原始包/解析规则需交叉核对。
- 两条候选样本 => SAMPLE_AMBIGUOUS，不取最小ID或最近时间。一个样本附近存在多条可能事件 => EVENT_SAMPLE_AMBIGUOUS。
- 默认容差0。非零容差不超过1ms只是工具上限，**不是推荐值**；即使匹配唯一，也只能说在该校准容差下成立。
- null callsite 是 STACK_MISSING；unwind_error 是 STACK_PARTIAL；有名字不保证完整栈或所有模块符号一致。
- 必须单独检查丢样本、缓冲覆盖、时钟、字段和过滤器。E2_EVENT_PAIR_REQUIRES_QUALITY_CHECK 不表示质量自动PASS，更不是E3。
- UNKNOWN 与 FAIL 分开：缺字段/不可见是 UNKNOWN；错误身份/不符边界/证据相矛盾应报告具体失败，不编造空白间隙的原因。

## 对齐结果

保留 wait_id、UTID、睡眠/唤醒/运行边界、两侧CPU、waker_utid、原始event/sample ID、ns偏差、候选数、匹配状态。任何引用调用栈的结论能回到这条关联记录，而不是回到整个线程的热点排行。
