# 验收、故障分流与证据等级

依据：[S03/S04/S07/S13–S15/S17](sources.md)。验收先于截图和结论。

## 四级验收

| 级别 | 要看什么 | 不能替代下一层 |
|---|---|---|
| 1. Schema | 与采集器对应的TraceConfig proto解析通过 | 不证明事件/producer在该设备存在 |
| 2. 运行条件 | 数据源、内核事件、目标权限与注入路径 | 不证明本次采集有有效目标数据 |
| 3. 数据 | 正确进程/窗口、非空样本、无影响结论的缺失 | 不证明SQL口径、符号或因果判断正确 |
| 4. 分析/UI | 单位、UPID、时间窗口、图形与统计一致 | 相关性仍不自动等于因果 |

## 1. 精确schema验证

在主机准备与**板端采集器**匹配的Perfetto源码及protoc，然后从源码根生成descriptor set：

```bash
cd "$PERFETTO_SRC"
protoc -I . --include_imports \
  --descriptor_set_out=/absolute/work/trace_config.desc \
  protos/perfetto/config/trace_config.proto
```

在Skill目录验证并可选编码：

```bash
python3 scripts/validate_config.py memory.pbtxt \
  --descriptor-set /absolute/work/trace_config.desc \
  --binary-out memory.pb
```

Python protobuf和protoc都在主机，板端不需要Python。编码后的配置使用`-c memory.pb`，不带`--txt`。验证器严格拒绝未知字段/枚举；`MEMINFO_MEM_CACHED`之类拼写错误不能默默跳过。

当前包没有内置某版官方descriptor，也没有声称在本环境跑过官方TraceConfig解析。生成器单元测试、括号检查和fixture schema测试不是第1级的替代品。text config是便利输入，正式稳定流程可以保留经匹配schema编码的binary config。

## 2. 采集前检查

记录：工具版本/架构、配置hash、目标命令行、采集目录挂载类型与余量、设备事件清单、采样/轮询间隔、是否开启阻塞、预计复现操作。预算不仅有traced buffer：还包括ftrace每CPU buffer、heapprofd shmem、daemon/符号工作内存和输出文件。

选择有余量的授权测试环境；同时采集多种profile需要更谨慎。实际业务帧延迟分析保留未开profiler的对照。没有kprobe不直接否定tracepoint；有perf二进制也不直接证明perf tracepoint采样权限。

## 3. 采集后检查

在UI执行 `sql/00-inventory.sql` 中独立的检查语句：

- trace_bounds覆盖预期复现阶段，开头/末尾没有因buffer轮转被丢掉关键证据。
- process里目标UPID正确，PID复用/同名多进程没有混合。
- RSS：实际counter行存在，类别/轨道/单位匹配；不只检查trace文件大小。
- Native：heap_profile_allocation中有目标UPID+heap，快照数/跨度合理；peak模式另行检查，不硬套普通增量表的预期。
- ART：heap_graph_object及types引用完整；多个graph_sample_ts按快照分组。
- ftrace：所需事件实际产生，读args核对字段；“有tracepoint但此时没触发”和“未采到”分别判读。
- stats：检查非零错误、data loss与heap/ftrace/packet相关诊断；部分info非零是正常统计，不全判失败。
- collector/daemon日志：并发拒绝、权限、socket断开、缓冲溢出、unwind失败、提前停止。字段和错误名称以版本实际输出为准。

stats没有错误不保证所有预期事件均被启用。没有CMA事件可能只是没有CMA分配；没有heap样本可能只是采样区间没有分配或目标未匹配。验收应包含一个小且已知的测试动作，不能只看“零错误”。

## 4. 常见失败 → 最小下一步

| 表现 | 先查 | 下一步 |
|---|---|---|
| 配置拒绝或trace近乎空 | stderr、精确字段/枚举、collector版本 | 用匹配descriptor验证，保留失败日志 |
| 有系统counter，无目标heap | 对象名、权限、preload、生产者、并发会话 | 独立memprobe测试，不直接改cam-service |
| tracefs目录存在但没事件 | available_events是否真的可读且有内容 | 优先实际debugfs路径，不只test -d/-s |
| Native中途停止 | shmem、产生速率、断开、进程退出 | 降低采样频率或限定目标，区分不同buffer层级 |
| profile变得更卡 | block_client、CPU/内存开销、tmpfs输出 | 无profiler对照；--no-block-client并检查缺失 |
| trace只有地址 | Build ID、unstripped ELF、debug文件 | 按S15做离线符号化，检查解析报告 |
| RSS高但heap低 | 不回溯、采样范围、映射/驻留/allocator | 先对齐口径，不直接认定碎片 |
| Java Total一直增长 | 选择的是ART allocation而不是graph | 这是累计分配；改graph观察保留关系 |
| graph/HPROF加载不全 | 版本、截断、buffer、文件完整性 | 保留原件，检查collector/解析诊断 |
| 没有字符串/位图内容 | 输入其实是Perfetto graph | 授权生成支持内容的完整ART HPROF |
| 要画150ms heap峰值却每5s才一dump | 观测粒度与目标不匹配 | RSS事件观测/heap peak模式，不插值编出峰值 |

## 5. 符号化

保存匹配Build ID的二进制/库与独立debug文件；主机准备llvm-symbolizer。当前统一CLI支持时，按官方[S15](sources.md)使用bundle：

```bash
trace_processor bundle --symbol-paths /absolute/sdk/unstripped \
  --verbose memory.pftrace enriched.tar
```

Android混淆需要与该包版本一致的ProGuard mapping，命令参数先核实help。旧SDK则按其traceconv/trace_processor工具支持的symbolize路径走，不混用新旧CLI。

即使命令返回0，也要检查尚未解析的模块/帧。不要只凭函数名合理就认定Build ID匹配。符号包不自动保证每帧都有文件/行号；内联、优化、ICF和栈展开缺失都影响结果。

只对官方允许的protobuf trace使用拼接symbol包的旧路径；JSON、HPROF、pprof不应直接cat拼接“符号数据”。保留原始trace，不以导出后的pprof代替完整取证文件。

## 6. 输出结论的格式

先写实际观察（UPID、窗口、指标与量级），再写推论及支持证据，最后写尚缺的因果环节。对没有执行的设备/UI测试明确标记未验证。完整图表应能追溯到配置、trace、SQL和版本，不依赖助手记忆中的一次结果。
