# 官方来源与版本注意

- [CPU Profiling: linux.perf/timebase/callstack sampling](https://perfetto.dev/docs/getting-started/cpu-profiling)
- [CPU Scheduling events / sched_switch / sched_waking](https://perfetto.dev/docs/data-sources/cpu-scheduling)
- [CPU frequency, idle states, sys_stats cpufreq_period_ms](https://perfetto.dev/docs/data-sources/cpu-freq)
- [Scheduling blockages case study](https://perfetto.dev/docs/case-studies/scheduling-blockages)
- [PerfettoSQL prelude tables](https://perfetto.dev/docs/analysis/sql-tables)
- [PerfettoSQL getting started](https://perfetto.dev/docs/analysis/perfetto-sql-getting-started)
- [PerfettoSQL standard library](https://perfetto.dev/docs/analysis/stdlib-docs)
- [TraceConfig official proto](https://github.com/google/perfetto/blob/main/protos/perfetto/config/trace_config.proto)
- [Linux PerfEventConfig proto](https://github.com/google/perfetto/blob/main/protos/perfetto/config/profiling/perf_event_config.proto)

## 内部可复用源

- [`perfetto-memory-debugging v1.0.2` frozen commit](https://github.com/dg-xiaodong/test_perfetto/tree/0fa17e08eb8b93a9944232e380c7ddb39666fcf2/v2_modify/candidate-v1.0.2)
- 原样复用 `scripts/linux_session_lib.sh`、`scripts/linux_trace_session.sh`、`scripts/host_pull.sh`；CPU SQL 05/06 对应原 Skill SQL 11/12 的等价核心算法，注释/文件名调整。
- 已有 X5 调度 Trace 真实回归可见用户仓库 `v2_bord_test`、`v2_modify`；这些历史验证不是本 Candidate 的新板端实测。

官方网页会持续演进；配置中的字段需按目标 tracebox 版本核对，主机 Trace Processor 新版本不代表板端具备该字段。
