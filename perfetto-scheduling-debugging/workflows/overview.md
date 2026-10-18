# Overview：先选具体窗口

1. 有 trace 则不重采。无 trace 用 overview：全系统 sched_switch、sched_waking + 线程身份，默认 15 s、无 perf。实际周期更长可设 ≤60 s。
2. `00-threads.sql` 识别 UPID/UTID 和生命周期，`00a` 看范围，`00b` 看非零诊断，`00c` 检查列。不假定独立 `sched_waking` 表存在。
3. `01-state-window.sql` 用真实 UTID、慢窗口。它裁剪两端，保留未知覆盖，`dur=-1` 不计为确定的 0。
4. `02-wait-episodes.sql` 识别 S/D/I → R/R+ → Running 的直接邻接片段，起点/终点不可见时保留不完整状态，不找任意下一次 Running 凑时长。
5. Runnable 占主导：`04-runnable.sql` 找等待，再对**已确定的相关 CPU 和同一窗口**跑 `03-cpu-competitors.sql`。它统计所有进程，不能拿目标进程占用替代整核忙碌率。CPU 可能迁移，不能只凭最终 run_cpu 推断整个等待时段只能在那一核。
6. 睡眠占主导：进入 block/wake，除非业务日志已足够解释（正常等请求、明确的定时 sleep 等）。高 Running 且疑似忙等：需要事件栈/CPU 热点补证，不直接认定有效计算。

业务 CSV 规范：`request_id,utid,enq_ns,start_ns,end_ns`，由业务日志适配，必须校验时钟：

```sh
python3 scripts/request_latency.py normalized_requests.csv --clock-verified > latency.csv
```

该工具只计算 queue/processing/total，不伪造 Running/Sleeping 分解。对每个 `[start_ns,end_ns)` 再用状态查询；一个请求跨多个工作线程时需业务任务标识，不简单求和线程时间。图形见 UI 指南。

停止：已有证据回答当前问题就交付；不能用全窗口平均掩盖局部争用，也不用每次多跑空载、压力、异常退出对照。
