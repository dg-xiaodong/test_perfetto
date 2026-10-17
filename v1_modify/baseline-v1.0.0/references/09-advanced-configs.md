# 高级配置变体：生成器之外的官方能力

依据：[S04/S07/S17/S18/S19](sources.md)。以下是要合入对应数据源的**局部配置片段**；Agent输出最终方案时必须把它们合并成完整TraceConfig，不能让用户猜嵌套位置。先核对采集器proto和目标版本。

## 只看已经运行的Android进程

在heapprofd_config中用明确PID，并排除startup；PID属于当前进程实例，采集时核实未重启：

```text
pid: 1234
no_startup: true
```

替换示例PID，并避免同时保留一个会意外扩大范围的进程名选择。no_startup/no_running有版本条件；运行时激活延迟仍存在。这个片段不能给普通Linux未预加载进程提供Android的hook机制。

只看之后启动的匹配进程，可使用process_cmdline与`no_running:true`（支持该字段的版本）。两种排除策略不要同时启用。启动期先启会话再启应用，并检查实际profile是否from_startup。

## 多个进程、多个heap

```text
process_cmdline: "com.example.app"
process_cmdline: "com.example.app:worker"
```

这仍然是明确的allowlist。记录每个UPID、heap、采样和是否被并发会话拒绝；同名不等于同一进程。不要用`all:true`代替定位目标，尤其用户构建权限或资源受限设备。

在已经具备ART allocation支持的Android上，需要同时观察两种heap时可显式选择：

```text
heaps: "libc.malloc"
heaps: "com.android.art"
```

Native的live/free分析只应用在对应Native heap，不能把ART只增的allocation量并入总live。其他自定义heap必须已经由应用/运行时注册并接入heapprofd；填写名字不会自动hook原本未集成的allocator。

较新版本支持的cmdline wildcard不是跨版本通用能力。特别是HeapprofdConfig v57的glob支持限定运行进程匹配，需配合`no_startup:true`；不能据此声称启动时也支持通配符。基础生成器刻意只接受精确名字。

## ART graph选目标、控制重复快照

java_hprof_config可按目标PID或process_cmdline选择。已确认版本支持时可设置`min_anonymous_memory_kb`，按anon RSS+swap门槛筛选大进程；它不是Java heap大小。新的`min_java_heap_size_kb`字段又是另一条件，须实际版本验证。

continuous_dump_config可设置dump_phase_ms/dump_interval_ms；但当前proto仍说明启动时已有一次dump，因此不能把phase当成“所有快照都延迟至这个时刻”。实际graph_sample_ts是时间证据。

Android12及以前/Android13及以后，连续dump默认是否重新扫描匹配进程的行为存在差别。目标可能在采集期间新启动时，核对`scan_pids_only_on_start`的版本语义；不要认为反复dump必定发现后来创建的同名进程。

`target_installed_by`可在支持的Android版本限制安装来源；它是目标过滤，不是权限绕过。dump_smaps在旧版本只覆盖受限路径，v58+的smaps_config是新字段；不能把两者当成跨版本等价的“所有smaps全量快照”。

## 厂商mm_event与附加系统计数器

存在 `mm_event/mm_event_record` 时，将其作为ftrace_events加入已有linux.ftrace配置，不新建一个想象中的mm_event数据源。该事件在部分厂商内核提供细分fault/IO/reclaim统计，数据包和UI单位以实际实现为准。

sys_stats中可按问题增选vmstat、PSI或buddyinfo轮询，但每个字段都需要对应版本proto及目标/proc能力确认。不要把所有计数器全开作为默认模板，也不要将累计事件数当作当前内存占用。需要事件速率时按相邻时间和计数差计算，处理重启/重置/缺失值，不用max减min掩盖时间结构。

## 不再机械沿用的选项

当前proto已弃用/保留idle_allocations字段，旧CLI参考出现该选项不等于新版本仍能采集。不要为满足“曾在官方文档中出现过”而输出失效配置；应明确版本限制，并改用仍可用的profile/映射分析回答用户实际问题。
