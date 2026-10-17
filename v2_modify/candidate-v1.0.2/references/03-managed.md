# ART：分配抖动、引用保留、内容与 OOME

依据：[S01/S04/S05/S06](sources.md)、[S16/S18/S25](sources.md)。这里的 ART 是 Android Runtime，不是普通 Linux 上所有 JVM 的通用抓堆方案。

## 路线 A：谁创建了太多对象

```bash
python3 scripts/make_config.py java-alloc --platform android --api 34 \
  --process com.example.app --dump-ms 5000 > java-alloc.pbtxt
```

Android12/API31起，heapprofd 选择 `heaps:"com.android.art"`。看 Total Allocation Size / Count 定位创建对象的栈；该路线不跟踪 GC/free，不能用其累计值画“当前Java堆存活量”，也不能只用“未释放视图”证明Java泄漏。

对象 churn 可能与 GC/CPU/帧延迟相关，但要用实际 GC/调度/业务事件验证。Java API 经 JNI 分配的 native 内存仍可能需要 Native profile，不能因为用户写的是 Kotlin 就排除 native 问题。

## 路线 B：对象现在由谁持有

Android11/API30起，采 ART heap graph：

```bash
python3 scripts/make_config.py java-graph --platform android --api 34 \
  --process com.example.app --dump-ms 10000 --duration-ms 25000 > graph.pbtxt
```

或者使用主机上的官方 helper：

```bash
python3 java_heap_dump -n com.example.app
```

以 helper 的真实输出路径拉回/打开 trace。正式命令前先检查 helper `--help` 与目标 app 的 profileable/debuggable 权限。若只需要单次快照，删除 `continuous_dump_config` 并选短采集，不要为了“更多数据”无限延长。

graph提供对象、类型、引用和GC根，能观察采集开始前就存在的对象，但不能恢复这些对象历史上的分配调用栈。按实际 `graph_sample_ts` 确定快照时刻，不能假设都在录制结束。多次graph的对象集合是重复快照，不是增量，按UPID+快照分别计算。

### Activity 泄漏演练

准备可重复的“打开页面→关闭页面→等待异步清理/GC机会”操作。基线和若干次操作后的快照保持相同阶段。在 Classes 找目标 Activity 类型，选本应销毁的实例，查看 shortest path to GC root、反向引用与 dominator path。记录实际持有者（例如某长生命周期容器），再用释放/注册注销后的对照快照验证。

对象还可达本身不是错误；需要业务上“它应当不再被持有”的条件。强制GC改变实验，只有授权测试环境才考虑；记录是否执行过，不能将带GC与不带GC结果直接等价比较。

### Native size

较新Android可在graph记录经NativeAllocationRegistry关联的native_size。它不是对象self_size，也不是应用所有native分配总量。UI的[native]部分要单独解释。不要把JNI内存、设备buffer和全部匿名RSS都塞进这一栏。

## 路线 C：看内容、重复字符串与位图

Perfetto 的 ART graph 不包含完整对象内容。要分析字符串/primitive array内容、重复bitmap像素或字段值，需要**完整 ART HPROF**，不是给 java_hprof 配置随便加“contents:true”。

先检查设备：

```bash
adb shell am help
```

基础授权抓取：

```bash
adb shell am dumpheap com.example.app /data/local/tmp/heap.hprof
adb pull /data/local/tmp/heap.hprof ./heap.hprof
```

仅在设备 `am help` 明确支持对应扩展、且允许其暂停和GC影响时，使用当前 Explorer 文档示例形式：

```bash
adb shell am dumpheap -g -b png com.example.app /data/local/tmp/heap.hprof
adb pull /data/local/tmp/heap.hprof ./heap.hprof
```

`-g` 会请求GC，`-b` 的位图内容选项存在版本条件；不支持就降级，不保证旧设备也有Bitmaps像素预览。权限失败时使用可调试版本/授权调试通道，不自动解除设备保护。

在支持该格式的新版 Perfetto UI 打开HPROF→Heap Dump Explorer。Strings/Arrays 分组看真实内容重复；Bitmaps看尺寸、内容与占用，再追到持有实例。两个同尺寸/同大小对象不等于内容重复。完整dump可能暂停进程、体积巨大且包含敏感文本/图像，应在授权环境生成并控制保存与共享范围。

## 路线 D：OutOfMemoryError 时取证

Android14/API34+支持 ART OOME 触发。先布防，再复现错误，而不是错误之后才尝试 attach。

```bash
python3 scripts/make_config.py java-oom --platform android --api 34 \
  --process com.example.app --oom-wait-ms 60000 > oome.pbtxt
```

模板使用 `android.java_hprof.oom` 和 START_TRACING trigger，事件名 `com.android.telemetry.art-outofmemory`。等待窗口以trigger_timeout_ms控制，不同时塞一个常规duration_ms导致语义冲突；stop_delay和数据源停止超时处理触发后的dump完成。默认64MiB graph buffer只是工程起点，不保证装得下任意大堆；以包完整性/丢弃信息验收。

官方 helper 的对应路线（先核实该版本参数）：

```bash
python3 java_heap_dump --wait-for-oom --oom-wait-seconds 60 \
  -n com.example.app -o oome.pftrace
```

等待到期没有OOME触发，应记录“未观察到触发”，不能说“应用不存在内存问题”。LMK或内核OOM可能直接杀进程，并不等同于ART抛OOME，因此不会保证走这条链路。

新版的 `dump_oome_callstack` 只有在采集器proto、设备和UI均支持时显式加入；它描述触发OOME的线程调用栈，不是每个已存在对象的分配栈。没有该字段/数据时仍可用对象图，不虚构Callstack面板内容。

## Explorer 中最重要的区别

引用图有共享节点。按最短GC根路径展开得到的树，其子树大小不等于“删除此对象后一定释放的内存”。要看独占保留使用 dominator / Dominated Object Size或Count：对象的所有根路径都经过某个支配者时才属于其支配集合。多个对象的dominated累计量可能重叠，也不能随意求和。

这种可达性结论也不承诺立即减少等量RSS：GC、终结器、allocator保留与页面回收仍有各自时序。
