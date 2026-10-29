# perfetto-latency-debugging v0.1.0 Candidate — 测试报告

报告日期：2026-10-18。范围是当前工作容器中的实现、单元测试、SQL fixture、Shell 模拟和包完整性。**本次未连接 RDK X5，没有生成真实 TrackEvent `.pftrace`，未执行真实 SDK 编译、真实 TP 解析、GUI 或 Agent 盲测。**

## 1. 交付定位

独立 Skill；唯一入口为 C/C++ TrackEvent 埋点。支持函数墙钟、请求生命周期、流水线队列/交接和帧间隔。ftrace 是可选联合数据源；InProcess/System 是部署方式。没有通用日志转 Trace、自动给所有函数插桩、任意 DAG 关键路径或 BPU 硬件时间推断。

## 2. 实际执行

| 检查 | 结果 | 证据/含义 |
|---|---|---|
| `python3 -m unittest discover -s tests -v` | **86 项：85 通过、1 跳过；无失败/错误** | evidence/local-tests.txt |
| 组合身份和阶段实例 | PASS（合成输入） | 多 stream、run 重启、64位字符串ID、重复begin/end、重复实例、重试和并行 |
| 生命周期/业务结果 | PASS（合成输入） | 缺终态非timeout、开放Slice、显式边界、DROP/TIMEOUT/CANCELLED和完整性分开 |
| Flow 与并行 | PASS（合成输入） | 实际边导出模型、跨请求错误、源/目标阶段、ProcessScoped跨进程拒绝、union非sum |
| 配置生成/策略 | PASS | 两份静态配方；时长/内存/类别/事件检查；非法及重复字段拒绝 |
| SQL 模板 | PASS（SQLite fixture） | 10 个查询逐条执行；64位字符串、线程绑定、跨窗口裁剪反例 |
| Shell | PASS（语法＋模拟collector） | 正常路径、提前退出、错误传播；模拟产物不是Trace |
| TP 调用封装与综合导出 | PASS（模拟TP传输） | 非0退出码、原始输出、哈希；一份模拟导出可完成分析与UI SQL生成 |
| SDK 提取工具 | PASS（假archive专测提取） | 校验和拒绝、扁平安全提取、重复SDK成员拒绝；不证明SDK可编译 |
| CMake 缺SDK | PASS（负例） | 真SDK缺失时明确FATAL，不降级成stub |
| Python/Shell资源与打包 | 在最终封包时执行 | verify_package.py、相对链接、ZIP CRC、解压复核与解压后重跑测试 |

初始配置测试在实现前观察到明确断言失败（缺 TrackEvent 输出），之后完成实现和回归。独立 Agent 行为 RED/GREEN **未执行**，不把编写场景或历史三套 Skill 的实测记成本版 Agent 验收。

## 3. 唯一跳过的集成测试

`test_real_sdk_inprocess_and_tp` 需要 `PERFETTO_SDK_DIR` 与 `PERFETTO_TP`。本环境未提供这两个真实依赖。

已尝试通过官方 v58.2 Release 获取 SDK，容器网络发生 DNS 解析失败，`prepare_sdk.py` 返回 `SDK_BLOCKED` / rc=2（evidence/sdk-network-check.txt）。没有无休止换安装路径，也没有用假库生成“真实Trace”。

安装后在具备真实依赖的主机可运行：

```sh
PERFETTO_SDK_DIR=/absolute/sdk PERFETTO_TP=/absolute/trace_processor_shell \
  python3 -m unittest discover -s tests -v
```

该测试会用真实 SDK 编译 C++ 示例、生成 InProcess Trace，再跑本包分析器验证24个请求的契约完整性。只有执行成功才可记录为主机集成通过，不能外推为X5通过。

## 4. 未验证清单

- Perfetto SDK v58.2 对该 C++ 示例的真实 API/ABI、编译和运行兼容性。
- Trace Processor v57.1/v58.2 真实 `slice/flow/counter` 导出和 category/annotation 解析。
- 采集器对应版本官方 TraceConfig descriptor 校验；现有 POLICY_PASS 只是配方子集检查。
- X5 ARM64 编译产物的 glibc/libstdc++ 与解释器兼容性。
- X5 System backend producer socket、category就绪以及 TrackEvent+ftrace 同一会话。
- 真实跨进程 Flow、运行中开启/关闭捕获、并行分支SDK采集、长驻Track资源增长。
- UI实际箭头、Slice/Counter渲染及手动操作；没有截图验收。
- off / TrackEvent / TrackEvent+ftrace A/B/C测量开销。
- 独立Agent的短Prompt选路、接入质量及停止行为。

这些是后续场景测试项目，不以源代码设计、unit通过或前三个Skill的板端证据替代。

## 5. 已知设计边界

事件名和状态分类是本包的 latency.v1 契约，非 Perfetto 内置业务模型。端点完整不等于pipeline完整；计数声明只覆盖应用声明的实例数，不能证明所有业务依赖已埋点。缺失必要声明时综合INCOMPLETE。

无明确边界见证时，缺END为INCOMPLETE而非自动CENSORED。跨进程合同和错误scope检查已实现，但C++示例仍是单进程三线程。无完整DAG算法：critical_path_status固定NOT_COMPUTED，输出已观测的阶段、队列和显式边。

函数inclusive wall不是CPU；custom Track不绑定执行线程。原始函数分布是观测群体；严格请求分位数默认排除不完整/非成功/全局数据丢失。N<1000仅是尾部样本量提醒，不构成置信保证。

首版分析器为易审计的标准库实现，逐条执行5个导出SQL；超大Trace尚未性能测试。需要优化时可在后续版本复用TP持久会话，不在当前候选引入额外服务器部署。

## 6. 推荐下一步

先安装检查；随后只做一次真实SDK InProcess示例，再做一次X5联合采集。保留首轮错误和原始产物；不要同时扩展多轮复杂守护/自启动/高压/UI自动化测试。具体范围见 tests/SCENARIOS.md。
