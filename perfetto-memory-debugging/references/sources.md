# 官方来源、覆盖范围与版本策略

核对日期：2026-10-14。以下是本 Skill 的来源索引，不是冻结的官方文档镜像。链接到 `main` 的实现会变化；正式部署记录所用 SDK 的 tag/commit、配置 SHA256、采集器版本、Trace Processor 与 UI 版本。

## 用户指定的 11 篇

| 编号 | 官方页面 | 转换后的用途 |
|---|---|---|
| S01 | [Memory profiling 入门](https://perfetto.dev/docs/getting-started/memory-profiling) | Native / ART allocation / ART graph 路由；Linux 与 Android 执行入口 |
| S02 | [Memory case study](https://perfetto.dev/docs/case-studies/memory) | 按映射类别排查；mmap syscall + perf 调用栈；PSS/RSS 分流 |
| S03 | [Memory counters](https://perfetto.dev/docs/data-sources/memory-counters) | process/sys polling、rss_stat、mm_event、LMK |
| S04 | [Native heap profiler](https://perfetto.dev/docs/data-sources/native-heap-profiler) | 采样、四种聚合指标、启动/运行时、连续快照、权限及故障 |
| S05 | [Java heap profiler](https://perfetto.dev/docs/data-sources/java-heap-profiler) | ART 对象图、GC roots、类型与原生大小 |
| S06 | [Heap Dump Explorer](https://perfetto.dev/docs/visualization/heap-dump-explorer) | graph / HPROF 差异；对象、支配关系、字符串、数组、位图 |
| S07 | [heap_profile CLI](https://perfetto.dev/docs/reference/heap_profile-cli) | 官方 Android / Linux helper 与参数；记录工具实际帮助 |
| S08 | [heapprofd design](https://perfetto.dev/docs/design-docs/heapprofd-design) | 远程 unwind、采样客户端与记账架构；历史性能数字的适用范围 |
| S09 | [heapprofd wire protocol](https://perfetto.dev/docs/design-docs/heapprofd-wire-protocol) | 共享内存/唤醒、顺序与配对；采集扰动和不同 buffer 层次 |
| S10 | [heapprofd sampling](https://perfetto.dev/docs/design-docs/heapprofd-sampling) | 随机采样、估计/方差、大分配快路径的版本差异 |
| S11 | [pprof support](https://perfetto.dev/docs/design-docs/pprof-support) | 导入现有 pprof；Aggregate Profiles；聚合数据没有逐事件时间线 |

## 为“能落地”补充核对的官方来源

| 编号 | 来源 | 解决的问题 |
|---|---|---|
| S12 | [Debug tracks](https://perfetto.dev/docs/analysis/debug-tracks) | SQL 列如何变成 timeline counter/slice |
| S13 | [tracebox](https://perfetto.dev/docs/reference/tracebox) | autostart、system sockets、applets |
| S14 | [perfetto CLI](https://perfetto.dev/docs/reference/perfetto-cli) | --txt、--background-wait、--notify-fd、--query |
| S15 | [Symbolization](https://perfetto.dev/docs/learning-more/symbolization) | Build ID、debug ELF、ProGuard、bundle 与旧版路径 |
| S16 | [本地 Android 采集：OOM heap dump](https://perfetto.dev/docs/getting-started/local-android-trace-recording#oom-heap-dump) | Android 14+ OOME 触发方式，不等同于 LMK |
| S17 | [HeapprofdConfig proto](https://raw.githubusercontent.com/google/perfetto/main/protos/perfetto/config/profiling/heapprofd_config.proto) | 采样、block_client、dump_at_max、heap、弃用字段 |
| S18 | [JavaHprofConfig proto](https://raw.githubusercontent.com/google/perfetto/main/protos/perfetto/config/profiling/java_hprof_config.proto) | continuous dump 时机、进程重扫描、smaps 版本变化 |
| S19 | [SysStatsConfig proto](https://raw.githubusercontent.com/google/perfetto/main/protos/perfetto/config/sys_stats/sys_stats_config.proto) | 轮询周期、可选 PSI/buddyinfo |
| S20 | [sys_stats_counters 枚举](https://raw.githubusercontent.com/google/perfetto/main/protos/perfetto/common/sys_stats_counters.proto) | MEMINFO_CACHED 等精确拼写与计数器选择 |
| S21 | [PerfEventConfig proto](https://raw.githubusercontent.com/google/perfetto/main/protos/perfetto/config/profiling/perf_event_config.proto) | mmap tracepoint 采样和 callstack scope |
| S22 | [官方 heap_profile 实现](https://raw.githubusercontent.com/google/perfetto/main/tools/heap_profile) | helper 的真实默认值、主机架构选择、Linux 注入与启动顺序 |
| S23 | [linux.memory.process 标准库](https://raw.githubusercontent.com/google/perfetto/main/src/trace_processor/perfetto_sql/stdlib/linux/memory/process.sql) | 统一 RSS/swap 时间跨度表与字节单位 |
| S24 | [Native summary_tree 标准库](https://raw.githubusercontent.com/google/perfetto/main/src/trace_processor/perfetto_sql/stdlib/android/memory/heap_profile/summary_tree.sql) | 全进程汇总，不能误加不存在的 upid 过滤字段 |
| S25 | [ART graph class aggregation 标准库](https://raw.githubusercontent.com/google/perfetto/main/src/trace_processor/perfetto_sql/stdlib/android/memory/heap_graph/heap_graph_class_aggregation.sql) | 按 upid、graph_sample_ts、类型比较快照 |
| S26 | [Android trace analysis](https://perfetto.dev/docs/getting-started/android-trace-analysis) | Android RSS/swap/oom_score 标准分析入口 |
| S27 | [Memscope & Memory Overview](https://perfetto.dev/docs/visualization/memscope) | 新版 UI 的可选内存浏览入口；基础方案不依赖它 |

## 文档之间存在的版本差异

| 差异 | 本 Skill 的处理 |
|---|---|
| 操作页简化为“大于采样间隔就精确记录”；sampling design 已描述不同快路径阈值 | 统一解释为随机采样估计；需要推导具体阈值时读取目标版本实现，不据旧段落推断 |
| 入门页把 ART dump 描述为录制末尾；当前 proto 写明启动时已有一次 dump | 不靠录制结束时刻代替快照时刻，以实际 graph_sample_ts 为准 |
| CLI 参考可能仍出现 idle-allocations；当前 proto 已保留/弃用该字段 | 生成器不输出 idle_allocations，不用“帮助里有”代替实际版本验证 |
| JavaHprofConfig v58+ 引入 smaps_config | 默认模板使用旧的 dump_smaps；需要新版覆盖范围时按实际版本改，不把新字段塞进 X5 v57.1 |
| 新文档使用统一 trace_processor 命令；旧 SDK 有 trace_processor_shell / traceconv | 先执行各自 --help，分别提供命令，不混用参数语法 |
| 当前 UI 有新版 Heap Dump Explorer / pprof / Memscope | 确认使用的主机 UI；升级主机分析器不能补出板端没有记录的数据 |

## 来源边界

官方事实用 S01–S27 追溯；配置参数组合、SQL 展示配方、预算和排障顺序是本 Skill 的工程整理。X5 环境来自本次用户提供的勘察报告，不是 Perfetto 官方对 X5 的认证；没有宣称已在本环境连接 X5。

原官方文档页面注明正文 CC BY 4.0、代码示例 Apache 2.0。本包对内容进行了中文归纳、重组和工程扩展；不是 Perfetto 项目官方发布的 Skill，不包含官方二进制或完整文档拷贝。
