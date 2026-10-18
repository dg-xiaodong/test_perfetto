# linux.perf：CPU 采样热点

官方依据：<https://perfetto.dev/docs/getting-started/cpu-profiling>。

## 采集路线

`linux.perf` 用 `perf_event_open`（和 perf 工具同一基础机制）采样，配置可以与 sched/freq 共用 Trace 时间轴。`scripts/make_config.py profiling --target ACTUAL_NAME --frequency-hz 100` 默认使用每 CPU 100Hz `SW_CPU_CLOCK`，采样调用栈 scope 按真实进程名称筛选。

必须按顺序核对：

1. `tracebox` 版本与实际 `linux.perf` 数据源支持，而不是仅看配置字段；`traced_perf` producer 是否可用。
2. 权限：`perf_event_paranoid`、进程可见性、必要 capability/SELinux 及构建支持；**不自行更改 sysctl**。Android 还需 profileable/debuggable 和平台版本限制。
3. 样本：先确认 `perf_sample` 实际有目标线程数据、对应调用栈 `callsite_id` 非空；没有样本是 UNKNOWN，不能断言函数不忙。
4. 符号：Build ID、非 strip ELF、离线 debug 信息；未符号化帧按模块或地址表达，不能虚构函数名。
5. 开销：初始 100Hz/CPU，缩短采集；采样可能扰动性能，因果时保留无 perf 的对照。

## SQL 与 UI

`sql/07-perf-samples.sql` 按 UPID 和 leaf callsite 统计样本，**只是叶子热点**，不是完整祖先函数累计树。若主机 TP 支持官方 stdlib：

```sql
INCLUDE PERFETTO MODULE linux.perf.samples;
SELECT * FROM linux_perf_samples_summary_tree LIMIT 100;
```

这张 summary tree 是**整条 trace** 的聚合，不保证已按当前 UPID 过滤；不能直接把整机最热函数说成目标进程热点。UI 中按进程/线程选择 Perf samples 区域，使用 Flamegraph，结合 `sql/07` 核对归属和样本量。

报告必须说明采样统计 vs 精确 CPU 时间之间的差异。只有确定需要函数级归因时才启用该路线；只要 CPU 使用量/调度量即可回答问题，就不要增加 perf 采样。
