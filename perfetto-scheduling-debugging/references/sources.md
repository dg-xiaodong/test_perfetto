# 官方来源与覆盖

核对日期：2026-10-18。官方案例是方法来源，不是 X5 已验证结论。

| ID | 来源 | 本包落点 | 验证边界 |
|---|---|---|---|
| S1 | https://perfetto.dev/docs/case-studies/scheduling-blockages | 两路事件采样、过滤、Woken by、Critical Path、futex附录 | 配方按X5预算改写；未移植Android参数/线程名/大缓冲 |
| S2 | https://perfetto.dev/docs/data-sources/cpu-scheduling | 状态/切出/唤醒时间线 | 源语义核对；实际列先探测 |
| S3 | https://raw.githubusercontent.com/google/perfetto/v58.2/protos/perfetto/config/profiling/perf_event_config.proto | scope、ring、shared queue | 源字段核对；未跑对应官方descriptor |
| S4 | https://raw.githubusercontent.com/google/perfetto/v58.2/protos/perfetto/common/perf_events.proto | timebase、name、tracepoint filter、clock、period | period1不承诺无损 |
| S5 | https://raw.githubusercontent.com/google/perfetto/v57.1/src/trace_processor/tables/profiler_tables.py | perf_sample、session ID、展开错误、callsite/mapping | SQL用兼容视图；未执行实际TP |
| S6 | https://github.com/google/perfetto/blob/v58.2/src/trace_processor/perfetto_sql/stdlib/sched/thread_executing_span.sql | 直接关系/IRQ不完整、Critical Path边界 | 不复制完整依赖图实现 |
| S7 | https://perfetto.dev/docs/data-sources/syscalls | 可选futex syscall检查 | 需目标schema/runtime确认 |
| S8 | https://perfetto.dev/docs/analysis/debug-tracks | 手动Slice Debug Track | UI未实操 |
| S9 | https://perfetto.dev/docs/concepts/clock-sync | 跨源时钟域 | 每份trace独立核对 |
| S10 | https://perfetto.dev/docs/getting-started/cpu-profiling | linux.perf与CPU热点区别 | 时间采样成功不替代事件采样验证 |
| S11 | https://perfetto.dev/docs/reference/perfetto-cli | notify/结束行为 | shell mock，不是tracebox实测 |
| S12 | https://man7.org/linux/man-pages/man2/FUTEX_WAIT.2const.html | 超时、EAGAIN/EINTR、条件重查 | C3只验证有界样例程序本机运行 |

完整案例阅读所提炼的流程：失败的全系统抓栈→tracepoint过滤→切出/唤醒两端→继续调查相关线程→有针对性扩展→根因证据→可选syscall。这里的唯一性算法、E1/E2/E3、测试数据结构是本包工程设计，不冒称官方现成实现。

前作经验来源：
- Memory stable: https://github.com/dg-xiaodong/test_perfetto/tree/perfetto-memory-debugging-v1.0.2
- CPU实测记录: https://github.com/dg-xiaodong/test_perfetto/tree/6a02511131006863ac0a6e84e094971d126951dd/cpu_test3

本次没有重新执行这些历史测试，也没有将其中的板端PASS算作新Skill已通过。未打包这些仓库的数据、工具或凭据。
