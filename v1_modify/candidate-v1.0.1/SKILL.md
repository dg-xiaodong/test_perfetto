---
name: perfetto-memory-debugging
description: Use when diagnosing memory growth, transient RSS spikes, native or ART allocation churn, suspected leaks, OOM or LMK events, mmap usage, or heap retention with Perfetto; also when preparing memory trace configs, interpreting heap profiles, or building memory views in Perfetto UI on Linux or Android.
---

# Perfetto 内存定位

把用户的问题转成可执行的采集与分析方案。先区分“占用多少、何时变化”“哪条调用栈分配”“什么对象在持有”，再选择数据源。默认使用中文，保留官方字段与 UI 名称。

## 1. 选路，只读取相关参考

| 用户问题 | 主要路线 | 读取 |
|---|---|---|
| 内存大、缓慢增长、系统压力、短时 RSS 尖峰 | process/sys counters；短尖峰加 rss_stat | [场景索引](references/00-routing.md)、[计数器](references/01-counters.md) |
| malloc/new 泄漏嫌疑、分配抖动、启动分配、峰值调用栈 | heapprofd，区分 live / total / peak | [Native](references/02-native.md) |
| Java/Kotlin 高频分配 | heapprofd 的 ART allocation heap，不追踪 GC/free | [Managed](references/03-managed.md) |
| Activity 泄漏、对象为什么活着、谁持有谁 | ART heap graph、roots、dominators | [Managed](references/03-managed.md) |
| 字符串/位图重复、字段内容 | 完整 ART HPROF + Heap Dump Explorer | [Managed](references/03-managed.md)、[UI](references/04-ui.md) |
| LMK、Linux OOM、Java OOME、CMA/回收与掉帧 | 先区分事件性质，再组合时间线 | [计数器](references/01-counters.md)、[Managed](references/03-managed.md) |
| 直接 mmap；已有 pprof；符号缺失 | syscall/perf；Aggregate Profiles；离线符号化 | [计数器](references/01-counters.md)、[内部机制与 pprof](references/07-internals-and-pprof.md) |

所有路线均读取 [平台与执行](references/05-platforms.md)、[验收](references/06-quality.md)、[UI 配方](references/04-ui.md)。完整官方章节对应见 [来源](references/sources.md)。

## 2. 最小环境确认

沿用已知环境；能只读检查就先检查，不重复询问。确认操作系统/API、架构、采集器与主机分析器版本、目标 cmdline/PID、权限、是否能重启、tracefs 事件、剩余内存与输出目录挂载类型。缺信息只问会改变方案的一至三个问题，同时给出不依赖这些信息的安全采集起点。

可运行 `sh scripts/survey.sh`；内核事件清单用 `sh scripts/survey.sh --events`。脚本不修改系统。X5 的历史环境来自用户报告，不能代替本次探测。

### 2.1 资源完整性与复用

- 选好路线后，先检查该路线依赖的 `references/`、`sql/`、`scripts/` 是否完整可读：`python3 scripts/validate_config.py --check-resources`。
- 资源缺失或不可读时，**明确列出缺失项与降级范围**（例：缺 `sql/04-native-callstacks.sql` → 只能给调用栈思路，不能给可跑查询），不得称为完整 Skill 流程。
- 优先复用包内已验证实现（`sql/`、`scripts/`、`configs/`），只调整明确的目标名、路径、版本与采集参数；不改写已验证的判据。

## 3. 构造配置与执行

优先调用 `python3 scripts/make_config.py --help`，按实际平台、目标和事件文件生成完整 pbtxt。十个常用场景已实现；高级变体按相应参考扩展，不把生成器选项当作能力全集。

字段依据优先级：**采集器对应版本的 proto/实现 > 同版本工具帮助 > 当前官方操作文档 > 历史 design doc**。主机 UI 较新不代表板端会采到新字段。涉及版本差异时核对 [来源](references/sources.md)，保留官方链接与版本依据。

有匹配版本 descriptor 时运行 `python3 scripts/validate_config.py`；没有时标记“配置已构造，未做该版本 schema 验证”。语法通过、数据源存在、实际采到、分析正确是四个不同结论。

执行时清楚标注【主机】和【目标机】、启动顺序、结束条件、文件拉回及本次会话清理。应用重启、强制 GC、信号注入和采集负载都可能扰动业务；先用测试进程。不得自行关闭 SELinux、调低安全 sysctl、清缓存、杀掉别人的 tracing 会话或重启生产服务。

## 4. 每次回答的交付结构

1. **定位路线**：问题、待验证假设、所选数据源与不覆盖的内存。
2. **采集配置**：完整、已填入目标参数的 pbtxt；关键参数、单位、采集器版本条件与来源。
3. **操作步骤**：准备、启动采集、复现、停止、拉回；命令失败时该查看的日志。
4. **采集验收**：目标 UPID、时间范围、数据条数、丢包/截断、调用栈与符号情况。
5. **Perfetto UI**：打开哪个文件、展开哪条轨道、选择哪个指标；提供可运行 SQL 和 Add debug track 的字段映射。
6. **如何下结论**：什么结果支持或反驳假设；当前证据能说明什么；一个最有价值的下一步。

只有用户已提供 trace/实测结果，才输出诊断结果。没有数据时输出预期现象与判读规则，不编造曲线、火焰图、截图或设备验证结论。

## 5. 分析时必须保持的口径

- `rss_stat.size` 是该类别当时的绝对量，不累加；不是每次 malloc 的日志，也不是无损、逐页精确时间线。
- RSS、PSS、heap live、heap total、虚拟映射、CMA/dma-buf 不相等；差值不能直接定性为泄漏或碎片。
- heapprofd 默认采样且不能回溯；ART allocation 只有分配信息，不能画“GC 后 live bytes”。
- Native 分配表按 UPID、heap、时间筛选后聚合；官方 summary_tree 合并全 trace 的全部进程。
- 完整 heap graph 的不同快照不累加；引用树的最短路径子树不等于 dominator retained size。
- `ts/dur` 保留纳秒；字节、KiB、MiB、页数分别标注。缺失值不补成“确定为零”。
- 发现内存尖峰不是证明它导致掉帧；需时间关联、线程/分配延迟和业务标记。
- 图形服务于证据：使用原生轨道、火焰图、Heap Dump Explorer 或 SQL debug tracks；没有对应数据就不承诺对应图表。

实操示例见 [完整演练](references/08-worked-examples.md)，回归场景见 [tests/scenarios.md](tests/scenarios.md)。

运行时/启动过滤、多进程、多heap、graph筛选与可选计数器见[高级配置变体](references/09-advanced-configs.md)。
