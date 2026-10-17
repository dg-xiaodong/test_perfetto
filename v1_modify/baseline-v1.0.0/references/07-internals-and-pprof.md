# 设计文档转化为调试决策；pprof 导入导出

依据：[S08/S09/S10/S11](sources.md)、[S17/S22](sources.md)。这是需要解释采样、开销、队列或pprof时才加载的参考，不要求每次回答都复述内部实现。

## heapprofd 的分工与实际含义

客户端在被采中的分配处保存用于展开的栈/寄存器等信息，经共享内存交给进程外daemon处理。daemon负责展开、分配地址与释放配对、聚合并写trace。序号帮助跨线程事件进行正确记账；不能因为两条记录到达顺序不同，就按文本顺序认定泄漏。

设计收益是减少目标内部的重型unwind和记账工作，不是“对目标完全没有性能/内存影响”。共享内存映射、拷栈、同步/通信都要花资源；目标的RSS/PSS也可能包括相应页面。设计文档的历史Pixel2测量不能写成X5实测，daemon故障隔离也不能改写成任何情况下目标绝不会受到影响。

它是分配调用栈归因器，不是精确的malloc耗时分析器。profile快照表示聚合分配统计，不能把slice宽度或daemon展开耗时视为业务malloc延迟。延迟问题需要CPU、调度或额外定时证据。

## 随机采样如何影响判断

平均间隔I表示按分配字节流稀疏采样；不是固定次数采样。单个小对象可能没采中，重复相同操作才能估计热点稳定性。采样估计有方差；对过小差异不要给出精确字节级“优化收益”。

当前sampling design与早期概述对大分配快路径的描述不完全相同。因此Skill输出保持“版本相关的加权采样”，需要具体数学/实现时才查对应版本代码。分析表中的估计量不要再次按I放大。

修改I的目的是在观测成本与统计精度之间取舍。不能同时承诺极低开销、每次小分配都精确、任意高吞吐无损。小对象泄漏可以结合Count视图、长一点的可控复现和重复试验，而不是直接将I设到极小并忽略目标资源。

## 三类buffer的故障不应混治

| 层次 | 装什么 | 典型策略 |
|---|---|---|
| heapprofd client shmem | 待展开/记账的分配释放信息 | 限定进程、稀疏采样；短burst可增大shmem |
| traced service buffers | 已提交的trace数据 | 调整容量/时长/填充策略，保护关键profile |
| ftrace per-CPU ring | 内核事件 | 选择事件、合适drain与容量，检查overrun |

同步阻塞可能避免某一层的丢失，但会改变目标时序。工程方案应优先给出保真目标、可接受开销和丢失检测，而非固定“把所有buffer拉满”。

## pprof：已有profile，不是另一种板端采集器

当前Perfetto可导入raw或gzip的pprof protobuf。Go、C++等工具的pprof可以直接进入UI的Aggregate Profiles；不需要先假装它是一个含时间线的Perfetto trace。

先在UI选择scope/文件，随后选择实际sample_type及unit。不同文件可能带CPU nanoseconds、allocation count、inuse/alloc bytes，不能都称作“内存大小”。用`sql/08-pprof.sql`发现实际aggregate表；design doc中的概念表名与实现的`__intrinsic_*`名可能不同，实际schema优先。

pprof的本质是聚合数据。它不能回答某毫秒发生了哪次分配、当时RSS多少、是否触发CMA重试。这些问题需要原始时间相关trace。即使profile有采集开始/持续时间元数据，也不等于每个sample有逐事件时间戳。

从heapprofd导出pprof方便其他生态使用，但保留raw trace：某些启动/并发诊断元数据或联合时间线不会同样保留。当前统一工具的入口可能为 `trace_processor convert profile`；旧版为`traceconv profile`。先查看对应子命令help决定输出目录和选项，不拼接两代语法。

## 维护时做什么

当用户设备版本不同、官方链接更新或采集报未知字段时，核对实际版本proto、helper与SQL标准库，而不是机械重试旧模板。更新后运行tests并重做一条最小设备验证；若只更新了文档而未重新采集，应保持原先设备验证状态。
