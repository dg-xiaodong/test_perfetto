# latency.v1 埋点契约

这是本 Skill 定义的业务契约，不是 Perfetto 原生请求模型。所有事件使用类别 `rdk.latency`（自定义类别时同时修改配置、示例和查询参数）。事件名称保持常量；ID 放 debug annotations，不拼进 event name。

## 身份

所有请求相关事件带 `contract_version="latency.v1"`、`run_id`、`stream_id`、`request_id`、`process_instance_id`。前三者组成业务键；按字符串传递，避免 64 位数字经过浮点转换。推荐安全 token，不使用空值、字面 `[NULL]` 或 `NULL`。

`run_id` 是协作流水线的运行命名空间，由请求发起方建立并向下游传播。新的一次独立运行用新 run_id。一个参与进程重启但继续处理既有请求时，不重写该请求的 run_id；更新 `process_instance_id` 并保留关联上下文。不同相机通过 stream_id 区分。

阶段必须有 `stage_id` 和每请求唯一 `stage_instance_id`。两路并行的相同阶段、同一阶段的重试必须分配不同实例；`attempt_id` 是业务重试序号，不代替实例身份。队列另带 `queue_id + queue_visit_id`。

可选 parent 信息必须是明确类型的完整父请求键或父阶段实例键；不得混淆 `slice.parent_id`（同轨嵌套）与业务父子关系。多前驱汇合用多条有独立 ID 的 Flow，不能用一个 parent_id 伪装整个依赖图。本版不做任意父子/DAG自动重建。

## 事件和字段

| 事件 | 形式 | 除业务身份外的字段 |
|---|---|---|
| `lat.request.begin` | Instant | `object_type=request/frame`；帧可带 `frame_seq` |
| `lat.request` | 显式 Track 的 Slice | 用于 UI 的整个生命周期；不是计算 E2E 的唯一依据 |
| `lat.request.end` | Instant | `status` 和下述计数声明；帧仍带 object_type/frame_seq |
| `lat.stage` | 线程上的闭合 Slice | stage_id、stage_instance_id、attempt_id |
| `lat.stage.result` | Instant | 对应 stage/instance、status，在 Slice 结束之后记录 |
| `lat.queue` | 唯一队列访问 Track 的 Slice | queue_id、queue_visit_id；在实际入队/出队边界开始/结束 |
| `lat.send` / `lat.receive` | Instant + SDK Flow/TerminatingFlow | link_id、flow_scope、from_instance、to_instance |
| `lat.request.boundary` | 可选 Instant | boundary=`capture_start_in_flight` 或 `capture_stop_in_flight`，仅用于确实观测到的边界见证 |
| 非 `lat.*` 名称的函数事件 | Scoped Slice | 建议完整请求身份；统计墙钟时长，不伪造 CPU 时间 |
| `lat.queue_depth.<queue>` | Counter | 精确快照深度；不对样本求和当队列长度 |

业务终态：SUCCESS、ERROR、DROP、TIMEOUT、CANCELLED。它与分析完整性无关。失败重试的阶段可以 ERROR，最终请求 SUCCESS。

终态计数声明：`expected_stage_count` = 此请求实际执行过的阶段实例数（包括失败重试），`expected_queue_count` = 队列访问数，`expected_link_count` = 显式交接边数。根据业务实际动作记账，不根据“成功写出多少 trace event”记账。否则无法检测漏埋点。

未提供声明时仍能检查起止端点，但综合 pipeline integrity 为 INCOMPLETE；不把端点存在包装成完整链路。

## Track 与 Flow

### 根据目标选择不同关联机制

| 需要回答的问题 | 机制 | 实现/身份约束 |
|---|---|---|
| 同一线程函数/同步区间 | 默认线程 Track 的作用域 Slice | 在相同线程、正确嵌套结束 |
| 同一进程不同线程的**同一个 Slice** | 显式 `perfetto::Track(id)` | BEGIN/END 引用同一 Track；并行非嵌套请求不能共用同一栈 |
| 不同进程的**同一个 Slice**（分别写 BEGIN/END） | **`perfetto::Track::Global(uuid)`** 候选方案 | 两端传播同一业务 Request ID 及 UUID，使用同一 System tracing 会话，真实 Trace 验证配对 |
| 跨线程/跨进程不同 Slice 之间的因果交接 | `perfetto::Flow::Global(flow_id)` 和 `perfetto::TerminatingFlow::Global(flow_id)`（跨进程） | 一条实际业务边一个可复核的全局 Flow ID；它**不会**帮两个 BEGIN/END 合并成一个 Slice |
| 无法证明请求身份或两端顺序 | 暂不建立确定配对 | 报告 UNKNOWN/AMBIGUOUS；可另做受限时间关联，但不能当成业务 ID |

**Track 是事件所在的时间线，Flow 是事件之间的因果连接。** `Track(id)` 默认生成带进程作用域的 UUID；两个进程即使填相同的数，也不能假定是同一 Track。`Track::Global(uuid)` 使用全局 ID；避免与其他 Producer 冲突，不能直接使用可回绕的帧号或仅凭 port 编号充当全局唯一身份。推荐从完整的 `(run_id, stream_id, request_id)` 派生稳定的 64-bit 标识（两端算法相同，冲突可检测），或经证实无重叠、无缺失、无回绕的单 lane 严格串行配对；未知时不宣称逐请求准确。

全局 Track 的前提包括两端确实加载了埋点、两者都能连接同一 System Backend、相同 category 在同一次采集中被启用，并且 TrackDescriptor/`track_uuid` 不冲突。不同 Producer 发出的跨进程 BEGIN/END 必须以真实 Perfetto Trace + Trace Processor `slice` 记录核验：预期一条闭合 Slice、正确的身份与时间顺序、缺事件不能冒充完整。这个条件尚未经本包真实 SDK/X5 双进程验收；有关最小操作见 [SDK 指南](02-sdk.md)。

默认线程 Track 的 BEGIN/END 只能在同一线程同一嵌套栈内成对。跨线程 request/queue 必须传递同一显式 Track。并行且非嵌套的生命周期不能共享一条栈；唯一 Track 或不重叠复用的 lane。不能用裸 frame_id 当全局 Track UUID。

示例从统一进程内单调 ID 分配器分配 Track/Flow；ProcessScoped 消除不同进程的数字碰撞，但不能形成跨进程边。跨进程必须传播完整业务身份，并在核验 SDK 支持后使用一致的全局 Flow ID（或原生 TrackEvent 全局 flow_ids）。本版增加了**待真实 SDK/System Trace 验证**的跨进程 C++ 最小示例；不将源码存在当作跨进程实测通过。

每条交接边唯一 link_id；send 和 receive 的业务键、边 ID、from/to 都必须相同，且真实 `flow` 表确实包含该边。源可为 `input`，目标可为 `output`，其余须指向实际 stage_instance。源阶段结束不能晚于发送，目标阶段开始不能早于接收。本版不据此宣称观察了全部潜在依赖。

## 边界与开销

缺 request_end、dur=-1 只证明不完整；不能自动推断 timeout 或 CENSORED。边界见证需要业务/采集协调方确实知道请求跨越采集边界。示例未实现自动在 Category OnStart 枚举在途请求；窗口中途切换时可能合理地产生 INCOMPLETE。

在 event lambda 内准备 debug annotations，避免禁用类别时仍做昂贵的序列化；禁止埋点热循环每次迭代。短时测试可每请求一条 custom Track；长驻生产需有界 descriptor/lane 管理。本示例在生命周期结束后 EraseTrackDescriptor，未证明任意小时级持续追踪内存恒定。
