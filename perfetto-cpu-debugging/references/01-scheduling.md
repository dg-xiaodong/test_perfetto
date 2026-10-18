# CPU Scheduling：Running / Runnable / Blocked

官方依据：<https://perfetto.dev/docs/data-sources/cpu-scheduling>；<https://perfetto.dev/docs/analysis/sql-tables>。

## 采集

- `sched/sched_switch` 产生线程实际 on-CPU 时段；配置一般还包括 `linux.process_stats`，辅助关联进程/线程名。
- `sched/sched_waking` 记录线程转成 eligible/runnable 的唤醒；可选 `sched/sched_wakeup_new`。必须先核实 `available_events`，不能凭空选事件。
- 解析结果中 `sched_slice`（或官方 `sched` 视图）表示 Running 时段，`thread_state` 包含 `Running`、`R`、`R+`、`S`、`D` 等状态；字段能否完整恢复要由实际事件和 TP 版本决定。

## 分析

- 先 inventory → 确认 UPID；不要用 `pid` 直接跨重启/跨进程实例累计。
- `01-cpu-usage.sql`：按线程算 **on-CPU 毫秒**，多核进程可 > wall time。
- `02-thread-states.sql`：Running、Runnable 和阻塞分别统计；`03-runnable-latency.sql` 是等待 Runnable 片段的清单，不等于某一次请求的服务延迟。
- `05-cpu-time-buckets.sql`：将每个 sched_slice 与桶求交；`06-cpu-spike-episodes.sql`：先筛高负载桶再按连续索引组成 episode。
- 测试反例：0.9–1.1s 的 200ms slice 应给两个 1s 桶各 100ms，阈值 150ms 时 **没有** spike；1.9–2.25s 的 350ms slice 给相邻桶 100ms/250ms。

## 常见误判

- `R`/`R+` 是 Runnable 等待 CPU，不是 Running；`S` 睡眠通常是正常业务等待，不能一概算成调度器卡顿。
- `sched_slice.end_state` 是这次运行结束时的状态，不能直接代表整个运行区间之前的线程状态。
- Runnable 时间长可以说明线程一度等待 CPU，但要判断是优先级竞争、CPU 饱和、迁移还是锁，需要同窗看其它线程、waker、CPU 队列，以及更直接的事件或业务标记。
- 业务延迟必须有业务日志/trace marker/时间窗；不能以 `thread_state` 的一段时长直接替代。
