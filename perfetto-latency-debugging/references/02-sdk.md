# C++ SDK 集成

版本目标：Perfetto C++ SDK v58.2（不是运行时自动追随 latest）。依赖与工具不放进 Skill ZIP，避免每个 Skill 携带一份巨大 SDK/平台二进制。

从 `prepare_sdk.py --dest NEW_SDK_DIR` 读取官方 v58.2 Release 元数据、取 SDK asset 和 SHA256。也可以 `--zip SDK.zip --sha256 VERIFIED_HASH --dest NEW_DIR` 离线提取。使用 API digest 是来源校验的一环，不等于密码学签名信任；记录 SDK_PROVENANCE。CMake 同时需要该目录中的 perfetto.h 与 perfetto.cc，禁止只拿 header 或使用 stub 代替真实 SDK。

初始化只做一次：Tracing::Initialize，设置 backend；TrackEvent::Register；一个编译单元提供 PERFETTO_TRACK_EVENT_STATIC_STORAGE。可复用示例的 `latency_trace.h/.cc`，但先核对目标项目已有 categories/SDK，避免在多个静态库中重复定义不同 SDK runtime。

## InProcess 验证

应用内服务只接收自身 TrackEvent；StartBlocking 后确认类别实际启用，再产生工作负载。完成请求、join 线程、Flush、StopBlocking、ReadTraceBlocking、检查写出/关闭。它不能采到内核调度数据。

## System 联合采集

应用使用 kSystemBackend 连接 traced producer socket。collector 使用系统 socket；tracebox 默认私有 service 不能假定应用自动连上。可用 Perfetto socket 配置以本机实际工具帮助为准；正常环境变量名为 `PERFETTO_PRODUCER_SOCK_NAME`，应用和服务必须一致。

推荐：先启动示例 `--backend system --wait-ms 30000` 让 producer 注册，随后启动 collector。示例在类别启用前不制造测试请求，超时明确失败。`--notify-fd` 只能证明会话就绪，不能替代应用类别启用和实际 slice 数据验证。

禁止将用户时钟裸整数当成 Perfetto 默认时钟时间戳。默认使用 SDK 自带时间；跨机器、独立 inproc trace 的合并需要明示 clock mapping，首版不自动合并。

## 跨进程同一 Slice：Global Track（可选，不等同于 Global Flow）

问题先分型：**A 进程负责一个 Slice 的 BEGIN、B 进程负责同一个 Slice 的 END**，尝试使用 `perfetto::Track::Global(uuid)`；若是两个独立 Slice 间的交接箭头，才使用 `Flow::Global`/`TerminatingFlow::Global`。Perfetto v58.2 的 `Track(id)` 默认与进程 Track UUID 组合，两个进程相同数字不会自动成为同一时间线；`Track::Global(uuid)` 构造无进程父级的全局 Track。参考 [v58.2 track.h](https://github.com/google/perfetto/blob/v58.2/include/perfetto/tracing/track.h) 与 [v58.2 track_event_args.h](https://github.com/google/perfetto/blob/v58.2/include/perfetto/tracing/track_event_args.h)。

```cpp
// A 进程：已初始化相同类别、System Backend，获得双方一致的全局 id。
auto track = perfetto::Track::Global(global_track_uuid);
TRACE_EVENT_BEGIN("rdk.latency", "AE dispatch to write done", track);

// B 进程：加载了自己的 SDK Producer，使用完全相同的 global_track_uuid。
auto track = perfetto::Track::Global(global_track_uuid);
TRACE_EVENT_END("rdk.latency", track);
```

上面是 **SDK 接口设计示意，不是已经过真实 TP 验收的 X5 代码**。不要求 B 重放 A 的 T0，不要求为了这条 Slice 使用 raw TracePacket；若两端无法传播 UUID，先调查已有 IPC/消息身份，不应直接创建新的共享内存或更改内核 ABI。`Track::Global` 不会自动传递业务 Request ID，不能通过同一 port 的两个函数调用就假定它们严格成对。

生产接入条件：两个进程都 `Tracing::Initialize(kSystemBackend)` 与 `TrackEvent::Register`，每个进程的类别/静态存储和 SDK 版本须一致；只在类别实际 enabled 后发事件；检查动态链接 SO 的初始化是否执行，避免重复或混用 SDK runtime。不要混用不同来源的 `perfetto.h`/`perfetto.cc` 或在两个 SO 中意外加载相互冲突的静态 SDK。若设置自定义 `TrackDescriptor`，不要让两个 Producer 用同一 UUID 发布彼此矛盾的描述符。优先只由一个明确的所有者设置稳定的 Track 名称，实际行为以 TP 解析为准。

在同一份真实 `.pftrace` 上用 Trace Processor 查询 `slice` JOIN `track`，检验一条完整正时长 Slice、非负 `dur`、符合实际起止位置，以及对应 Track ID。用业务日志/注解核对两端 PID、请求身份和类别使能状态；观察重复 UUID、并行重叠、缺失 END、重启或帧号回绕。**不允许只靠 BEGIN/END 数量相等、没有重叠或 UI 可视化就认定业务配对正确**。异常要注明 `UNKNOWN/INVALID`，原包 `analyze.py` 的 `latency.v1` 综合请求检查与自定义 XPROC Slice 的验证不能混为一谈。

最小双进程 Producer：`examples/cpp/cross_process_slice_demo.cc`（见 [运行说明](../examples/cpp/README.md)）。两个独立进程、同一 System Backend 与 Global UUID；本包不伪造 SDK/Collector 的成功记录。真实测试前不部署生产 SO、不重启产品服务；若 collector 不支持或 trace 没有配对证据，报告 BLOCKED/UNKNOWN，保留配置与原始 Trace。

## 授权与兼容性

接入意味着修改、重新构建、部署业务代码；先获得范围授权。ABI、glibc/libstdc++、动态加载器、Build ID、符号和 `.eh_frame` 要与目标兼容。保留调试信息并不保证上板运行，配置通过也不保证 producer 注册。X5 目标系统和 TP v57.1/v58.2 的真实联合验证尚未执行，不能从既往 CPU/Scheduling 成功外推本新 SDK 集成通过。
