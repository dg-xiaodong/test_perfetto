# 验收矩阵与后续场景测试

不以文件数量、配置可解析或 fixture 通过代替 Agent 自主选路。四个层次分别记：配置/运行、数据覆盖、分析正确、独立 Agent 行为。UI 和测量开销另列。

| 场景 | Ground Truth / 验收 | 首版当前证据 |
|---|---|---|
| L1 函数 Wall 与 CPU | stage 中分别 Compute 和 sleep，嵌套 compute 不重复计入父阶段 | 算法/SQL fixture；真实 SDK 待测 |
| L2 异步请求与队列 | 3 worker、bounded queue，begin/end 跨线程显式 Track，统计声明对账 | 提供 C++ 源码；真实运行待测 |
| L3 多 stream 帧抖动 | 同 ID 分流、重试、drop、timeout、输出乱序/间隔 | 合成 fixture；真实运行待测 |
| L4 数据完整性反例 | 缺 begin/end、开放 Slice、明确边界、ID冲突、阶段重复、错误/缺失 Flow | 本地 fixture 执行 |
| L5 并行 | 12/7 ms 同起点并行：union=12，不是19；B排队8+执行7时不可只按最长计算片选A | union/identity/Flow反例；不实现自动DAG关键路径 |
| L6 X5 SDK System + ftrace | 同一会话有 track_event Slice/Flow/Counter 与 sched；producer实际连接；退出/flush/TP成功 | 未执行，首个板端关卡 |
| L7 开销 A/B/C | 同一带埋点二进制 off、TrackEvent、TrackEvent+ftrace，固定输入，重复短测试 | 未执行，不每次诊断强制做 |
| L8 **跨进程同一个 Slice** | A 进程 BEGIN、B 进程 END，传播同一全局 UUID；实际 `slice` 正确闭合、正确 track、两进程证据独立；验证缺失 END 和 ID 冲突不造假 | v0.1.1 提供最小双进程源码及操作指南，真实 SDK/System/TP **NOT_RUN** |

## 最小执行顺序

先安装+离线检查。获准后先主机真实 SDK InProcess（一个短例子），确认 actual Flow 与解析字段；再一个 X5 联合采集。没有决定性缺口不追加多轮场景。实际失败应保存而不是改测试标准。

`PERFETTO_SDK_DIR=/abs/sdk PERFETTO_TP=/abs/tp python3 -m unittest discover -s tests -v` 启用真实集成测试（需要工具，不会下载）。这只验证运行该命令的主机，不自动声称 ARM64/板端通过。

L7 比较 FPS、延迟P95、CPU、RSS、丢数据；A基线已经含埋点禁用成本，不能推算 pristine 未埋点开销。观察稳定输入和暖机、复测顺序，不设凭空统一5%合格线，也不从一次差值断言因果。

## 独立 Agent 短 Prompt（安装以后另开会话）

“使用 perfetto-latency-debugging。请在获准的测试目录中接入 TrackEvent，验证这个 C++ 流水线的请求时延、队列积压和帧输出抖动，给出真实 Trace、分析结果与手动 UI 查看方法。不要修改生产服务，不做 UI 自动化；证据足够后结束。”

构造者与诊断者隔离。源码/自检答案只给评审，诊断者可看业务定义和已获授权的接入范围。故意省略证据时，应正确给 INCOMPLETE/UNKNOWN；这证明降级正确，不代表完整定位能力已通过。

## L8 跨进程 Slice 专项验收（不是所有诊断的强制步骤）

1. 首先只使用两个新建的小程序进程（不同进程的独立 PID），不替换生产库、不影响业务监管；由测试者控制 Begin/End 的顺序，需同一次 System Backend 采集与双方类别就绪。
2. 正例：双方共享由一次运行和一次请求确定的全局 UUID，Trace Processor 中 `xproc.global_track.demo` 恰有一条 `dur > 0` 的 Slice；TP 数据与两进程 PID/日志、请求标记一致。观察到一条完整 Slice 不等于证明其身份可信，身份由独立业务日志或传递的 Request ID 交叉验证。
3. 反例：同一 stream 的不同请求、两个 stream 同 frame_id 不应共用一个全局 Track UUID；Frame ID 回绕/重启时不能误配。没有独立业务身份可证明则 `UNKNOWN`。
4. 丢失 END：Trace 中可能为开放 Slice 或被截断，必须报告 `INCOMPLETE/UNKNOWN`，不能填 0 或默认 TIMEOUT。检查 Collector 数据丢失。
5. 如果同一全局 Track 存在多个未完成 Begin，先证明严格栈嵌套；做不到就使用每请求唯一 UUID。不要以 per-port 单 Track 冒充自动配对。
6. 正例不通过时，检查 Producer socket、category、SDK 版本/静态存储、Global Track UUID 和 Descriptor、事件时间排序及 Trace Processor 实际导入结果。保留失败日志；不要为了 PASS 修改 `analyze.py` 或换成 raw TracePacket 后宣称本方案成功。
7. 独立 Agent 的同一短 Prompt 分别对 v0.1.0 / v0.1.1 运行，不提示 API，测的是能否自主区分 Global Track 和 Global Flow；记成本、正确性、UNKNOWN。不以本地文本单测代替行为 A/B。
