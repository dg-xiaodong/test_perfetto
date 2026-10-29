# 官方来源与版本索引

核对日期：2026-10-18。官方在线文档会更新；实现以 C++ SDK v58.2 为首个构建目标，collector/TP 独立记录实际版本。不是 Perfetto 官方发布的 Skill。

| 来源 | 采用内容 | 本包资源 | 验证边界 |
|---|---|---|---|
| https://perfetto.dev/docs/instrumentation/track-events | Slice/Flow/Counter、显式 Track、category、事件参数、时钟 | contract、C++ adapter、UI | 已读；本机真实 SDK 未构建 |
| https://perfetto.dev/docs/instrumentation/tracing-sdk | 初始化、注册、InProcess/System、构建 | prepare_sdk.py、CMake、platforms | 已读；网络下载失败，集成待测 |
| https://perfetto.dev/docs/analysis/sql-tables | slice/flow/counter/thread_track/thread_state/stats | sql/、latency_core.py | SQLite fixture 可执行；真实 TP 待测 |
| https://perfetto.dev/docs/concepts/clock-sync | 时钟域与同步 | contract、platforms、analysis | 不自动合并无同步 Trace |
| https://perfetto.dev/docs/analysis/debug-tracks | SQL 派生 Slice/Counter 轨道 | 05-ui、ui-request-track.sql | UI 未操作 |
| https://perfetto.dev/docs/data-sources/cpu-scheduling | 可选 sched 联合分析边界 | 14-thread-overlay.sql、配置 | 新 TrackEvent+ftrace 路线未上板 |
| https://github.com/google/perfetto/releases/tag/v58.2 | 版本固定、官方下载元数据 | prepare_sdk.py | API 元数据已读；本机 SDK 文件未下载 |
| https://github.com/google/perfetto/blob/v58.2/protos/perfetto/config/track_event/track_event_config.proto | TrackEvent category 字段版本核对入口 | validate_config.py | 配方子集策略，不等于官方 descriptor 验证 |

本包的业务名、组合 ID、integrity/outcome 分类、声明计数、nearest-rank 阈值提示是本项目约定，不归称为 Perfetto 官方语义。原始数据表能力和本项目派生判据明确分开。

## v0.1.1 新增核对（2026-10-20）

- [Perfetto v58.2 `track.h`](https://github.com/google/perfetto/blob/v58.2/include/perfetto/tracing/track.h)：`Track(id)` 默认进程作用域 UUID；`Track::Global(id)` 显式全局 Track，存在全局碰撞风险。
- [Perfetto v58.2 `track_event_args.h`](https://github.com/google/perfetto/blob/v58.2/include/perfetto/tracing/track_event_args.h)：`Flow::Global`/`TerminatingFlow::Global` 是**交接边** API，不是同一 Slice 的跨进程 BEGIN/END 配对 API。
- [官方 Track Events 文档](https://perfetto.dev/docs/instrumentation/track-events)：自定义 Track / Slice / category 的使用背景。以上代码审阅仅确认 API 可用性，**不等于**真实 SDK 链接、跨进程序列合并或 X5 联合采集通过。
