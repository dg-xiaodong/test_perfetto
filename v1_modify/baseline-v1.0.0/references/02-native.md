# Native / ART allocation profiling：用调用栈回答“谁分配”

依据：[S01/S04/S07](sources.md)、[S08–S10](sources.md)、[S17/S22/S24](sources.md)。运行方式另见 [平台](05-platforms.md)。

## 指标与问题一一对应

| 问题 | UI 指标 | 解释 |
|---|---|---|
| 哪条路径保留了较多分配 | Unreleased Malloc Size | 追踪范围内分配而尚未配对释放的请求量估计；不等于 RSS |
| 小对象数量不断积累 | Unreleased Malloc Count | 有机会发现单个很小但数量很多的保留对象 |
| 谁反复分配大量字节 | Total Malloc Size | 累计分配量，包括后来释放的内存 |
| 谁高频创建小对象 | Total Malloc Count | 累计分配次数估计；不是逐调用精确日志 |
| 最大 heap 时是谁占用 | dump_at_max 对应 profile | sampled heap 峰值归因，不等同于进程 RSS 峰值 |

持续未释放只是泄漏候选。先定义对象何时应该释放，再执行重复操作、清理或等待后比较同一业务阶段。正常缓存、池扩容和异步释放不能仅凭红色/宽火焰图认定泄漏。高 Total 说明分配活跃，不独自证明锁竞争、CPU 开销或掉帧。

## 默认模板与变体

```bash
python3 scripts/make_config.py native --platform linux --process memprobe \
  --duration-ms 30000 --sampling 4096 --dump-ms 5000 > native.pbtxt

python3 scripts/make_config.py native-peak --platform android --api 34 \
  --process com.example.app > native-peak.pbtxt
```

普通模板：只选一个明确目标，平均采样间隔4096 bytes，连续快照5000ms，shared memory 8MiB，`block_client:false`。这些是起点而不是所有程序的最优参数。峰值模板使用 `dump_at_max:true`，不混合 continuous dump；该模式与正常 allocation/free 增量表的分析语义需分开。

采样间隔是随机字节采样的平均参数，不是“每4096字节固定打点”或“每次 malloc 都记录”。已经输出到分析表的 size/count 是分析器处理后的统计口径，不再自行乘采样间隔。小分配热点有方差，应重复相同 workload；改成更小间隔会增大开销与队列压力。

高分配量时可以先试更稀疏采样（如16384/65536 bytes），用对照数据评估是否还能回答问题；不是保证安全或准确的固定推荐。大分配快路径在不同实现版本有差异，按对应 proto/实现确认，不沿用旧 design doc 的简化阈值。

### block_client 的选择

当前官方 helper 有默认阻塞客户端的行为；调查掉帧/延迟时显式使用 `--no-block-client`，或手写配置 `block_client:false`。这样缓冲不足时可能丢失/提前终止，必须检查质量。开启阻塞可能提高完整性，却也能把采集压力直接传到目标线程；不能把这种延迟归因于原业务。

shared memory、traced buffers、ftrace per-CPU buffers 是不同层级。放大 traced buffer 不一定解决 heapprofd client shmem 溢出；放大 shmem 也不能解决长期产生速率大于处理速率。所有 buffer 和输出文件都占资源。

## 启动前、运行中与“不回溯”

**Android**：按 process_cmdline 匹配可以覆盖新启动进程和运行进程，具体排除行为由 no_startup/no_running 等字段控制；权限与设备版本要确认。运行时激活有延迟，刚 attach 后立刻发生的 burst 可能漏掉。启动型要先启动采集再启动业务，profile 的 from_startup 元数据可用于验收，但 zygote specialization 更早阶段并不全部包含。

**普通 Linux/glibc**：LD_PRELOAD 需要在进程启动时加载。给一个已经运行、未预加载的进程设置环境变量或套 Android 信号注入流程，不是有效方案。`PERFETTO_HEAPPROFD_BLOCKING_INIT=1` 等待初始化以减少首次分配遗漏；先验证服务/匹配路径，否则第一次 malloc 可能阻塞。已通过 preload 启动的进程是否支持后续会话，还要按该版本实现验证。

**不能重启**：先看当前 RSS/smaps，或观察可支持的未来分配增量。heapprofd 不能凭空解释 attach 前已经存在的300MiB；ART graph 可以描述当前对象关系，但那是不同的数据源和平台。

## 覆盖边界

默认 libc hook 观察 malloc/free 与相应 new/delete 等调用。自定义 allocator/pool 若向 malloc 申请 backing block，则能看到 backing 分配，但看不到每个池内对象的生命周期。完全直接映射/设备 ioctl 分配不因启用 hook 就可见。heapprofd 有自定义 heap 的应用集成能力，属于需要改代码的额外方案，不是启用现成开关就覆盖所有 heap。

静态链接程序不走动态 LD_PRELOAD；发现映射了 glibc 也仅说明一个前提，不证明 ABI、socket、daemon、权限、unwind 或符号可用。ION/CMA/dma-buf 本体与其由 malloc 分配的管理结构应分别看待。

RSS 与 heap live 不一致时，按覆盖时间→进程/heap→采样→驻留/映射类别→allocator 保留等顺序核对。不要写 `heap <= malloc_info <= RSS` 这种普遍不成立的大小链，也不要仅凭差值直接归因为碎片。

## 分析的时间口径

普通 Native profile 的 `heap_profile_allocation` 以正分配/负释放表达变化。先按 `upid, heap_name, ts` 聚合，再累计得到追踪范围内 live 估计。只取区间内的正负变化得到的是**净变化**，不是区间结束时的完整 live；结束值需要窗口之前的追踪基线。

continuous dump 将分配行为按快照汇总，不能从 dump 时间反推每次 malloc 的真实发生时刻。5秒一份 heap dump 不会天然还原150ms live 尖峰；要同时用 rss_stat 观察 RSS，或在确实需要 heap 峰值时使用 peak 模式。两者峰值不能混为一个指标。

`android_heap_profile_summary_tree` 汇总整份 trace 的所有进程，并不带可供过滤的 upid/ts。单进程查询先在 allocation 表过滤，再按 callsite 聚合/递归到父栈；本包 `sql/04-native-callstacks.sql` 提供这种写法。cumulative 字节在祖先栈会重复出现，不能把所有函数 cumulative 相加当总内存。

## 空 profile / 错栈排查

先看目标进程是否匹配、存活并有分配；检查正确会话中的 heapprofd 数据源、运行/启动策略、并发 profiling 拒绝、权限、socket和预加载。再看 buffer_overran、disconnected、unwind failures 等日志/trace诊断；字段名称以实际版本为准，不把“文件存在”作为完成。

有 allocation 行但未知地址：读取 Build ID，准备匹配 unstripped ELF /独立 debug files、llvm-symbolizer；Java混淆需 mapping。拿另一次构建的同名库不能保证符号正确。缺函数名时先按模块归因；文件和行号需要相应调试信息。

Android旧版存在特定32/64位组合、ART栈或小缓冲+阻塞等已知问题。遇到异常按 [S04](sources.md) 对照实际Android版本与补丁级别，不默认把某个历史问题推广到所有现代系统。

`PERFETTO_HEAPPROFD_BLOCKING_INIT`与`block_client`是不同控制：前者等待启动初始化，后者涉及运行时采集缓冲压力。不能用“已禁用block_client”推断首次malloc不再等待初始化。
