# 场景路由与覆盖矩阵

从要回答的问题选择观测对象。一个数据源不能回答所有层级：计数器是占用，heapprofd 是分配归因，ART graph 是引用保留关系。依据：[S01–S11](sources.md)。

| 场景 | 首选证据 / 配置入口 | UI 与判读 | 条件 / 下一层 |
|---|---|---|---|
| 不知道为什么进程很大 | `overview`，必要时 smaps/dumpsys | RSS 类别、系统 MemAvailable | 先区分 anon、file、shmem、native/managed |
| 长期缓慢增长 | overview 延长或多次等负载采集；再 native/graph | 趋势、同业务阶段前后值 | 增长不自动等于泄漏 |
| 一秒轮询遗漏短时尖峰 | `rss-spike` | RSS 事件曲线与故障时间 | 必须有 rss_stat；检查丢事件和记账批处理 |
| Native 哪条路径保留内存 | `native`，从操作前开始 | Unreleased Size / Count | 看释放语义、基线和重复操作后是否回落 |
| Native 高频申请又释放 | `native` | Total Size / Count；按窗口比较 | 总量不是占用；需 CPU/延迟证明性能影响 |
| 启动阶段已分配的大量对象 | 按名字匹配，先 trace 后启动；Linux preload+阻塞初始化 | 最早 profile、from_startup 元数据 | 不回溯；Android zygote 更早阶段不全覆盖 |
| 不许重启，想看过去分配 | Native 不支持历史追溯 | 只看当前映射或未来增量 | 已运行的普通 Linux 未注入进程不能直接套 Android attach |
| 最“胖”的 heap 是哪些调用栈 | `native-peak` / dump_at_max | Peak profile | 指 sampled heap peak，不是 RSS peak |
| 多个进程或多个自定义 heap | 精确目标集合与 heaps 选择，显式修改配置 | 分 UPID/heap 分析 | 不默认 all:true；自定义 heap 需应用集成 |
| Java/Kotlin 对象分配抖动 | `java-alloc` | Total Allocation Size / Count | Android 12+；不跟踪 GC/free，不代表 live |
| Java 对象现在为什么活着 | `java-graph` 或 java_heap_dump | roots、Classes、Objects、Dominators | Android 11+；graph 不提供每个对象的分配历史 |
| Activity/Context 泄漏嫌疑 | 相同交互阶段多份 ART graph | 不应存活实例的 root 路径与 dominator | 结合生命周期与 GC 机会，不只数对象 |
| 管理堆之外的 JNI/native 增长 | graph + native，必要时分开低扰动复现 | managed / native 分开比较 | Java API 也可能拥有 native allocations |
| 字符串、数组内容重复 | 完整 ART HPROF | Strings / Arrays 的重复内容 | graph 缺少实际内容；对象大小相同不等于内容相同 |
| 大图/重复 bitmap/像素预览 | 带位图内容的 ART HPROF | Bitmaps、预览、重复占用 | 按设备 am help 核实新参数；完整 dump 有暂停与敏感内容风险 |
| Java OOME 时的对象图 | `java-oom` 或 wait-for-oom helper | OOME graph；有数据时看 Callstack | Android 14+；不是 LMK，不依赖事件发生后再 attach |
| Android 低内存杀进程 | `android-lmk` + RSS/oom_score | victim PID、被杀前状态 | legacy lowmemorykiller 与现代 lmkd 分开 |
| Linux OOM killer | `kernel-pressure` 中可用 oom 事件 +日志 | 受害者、压力、时间关联 | 不把一次 Java OOME 当内核 OOM |
| 普通内存压力导致卡顿 | `kernel-pressure --sched` +业务标记 | RSS→reclaim/compaction→线程延迟 | 占用尖峰与回收仅同时间还不能证明因果 |
| X5 相机 CMA/ION buffer 异常 | 可用 cma ftrace +快照+帧标记 | CMA事件/分配耗时/重试与帧时间线 | 工程扩展；厂商无事件时不能凭空画厂商轨道 |
| RSS 高，malloc 解释不了 | smaps 分类；直接映射用 `mmap` | syscall slices +perf callstacks | allocator 自己调用 mmap 的 backing 仍可能被 malloc hook 覆盖 |
| mmap 哪条栈调用、申请多大 | `mmap` | syscall与采样调用栈 | 架构 syscall ID、perf权限、Android14参数支持等分别核验 |
| file/shmem 增长 | overview +smaps/文件/tmpfs 侧调查 | RSS file/shmem 与共享映射 | 不把共享页多进程 RSS 相加成物理总消耗 |
| 厂商 mm_event 细分缺页/回收 | 在存在的设备上显式加 mm_event | count / avg_lat / max_lat | 并非通用 Linux 必有；单位按实际字段确认 |
| 一份已有的 .pprof/.pb.gz | 直接打开，Aggregate Profiles | 选择 sample type 与 unit | 聚合格式没有逐分配时间线 |
| trace 打开却只有地址/空白 | 质量检查、符号/版本/进程匹配 | 先验收再美化 | 参见 06-quality，不把无数据说成“没有问题” |

## 组合时的节制

首轮通常选择 overview 或单一 heap 路线。只有问题需要时间关联时才增加 ftrace/sched/perf。不要默认同时开启高频 sched、全系统 heap、密集 ART dump、全部 vmstat；采集本身可能成为内存与延迟来源。

“源码行级定位”要求匹配符号；“漂亮图表”要求数据源、单位、时间窗口都正确。没有符号仍可先按 mapping/地址稳定归因，但应标明定位粒度。
