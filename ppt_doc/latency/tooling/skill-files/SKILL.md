---
name: perfetto-latency-debugging
description: Use when instrumenting C/C++ applications with Perfetto TrackEvent for slow function wall time, asynchronous request timeouts, pipeline queueing, multi-stream frame jitter, retries, or cross-thread/cross-process execution chains. Not a general log converter or CPU hotspot profiler.
---

# Perfetto 应用时延与执行链路 — v0.1.1 Candidate

**唯一入口：TrackEvent 埋点。** 帮助用户设计、接入和分析应用级 Slice、Flow、Counter。复用本轮 TrackEvent 产物是工作步骤，不扩展为通用 Trace 分析或业务日志转换。默认中文，保留字段原名。

## 1. 先确定业务边界，再改代码

确认可修改/构建/部署的代码范围、请求输入与终态、线程/队列交接，以及时延预算。未经许可不修改生产服务。先读 [埋点契约](references/01-contract.md)；只读所需的 [SDK 集成](references/02-sdk.md)、[分析规则](references/03-analysis.md)。

四种场景使用同一方案：已埋点函数墙钟耗时、请求生命周期、异步流水线、帧间抖动。没有观测到的内部阶段不编造。

业务主键是 `(run_id, stream_id, request_id)`；阶段主键再加 `stage_instance_id`。跨进程传递完整上下文。重试编号不代替实例 ID。采用包内 `latency.v1` 或先明确一对一字段映射；不按裸 frame_id/函数名合并。

## 2. 实现与采集

- 从 [C++ 示例](examples/cpp/README.md) 取最小接入；SDK 固定 v58.2，SDK 文件不捆绑。先检查已有 SDK，再按许可执行 `scripts/prepare_sdk.py --help`；不在单元测试中联网。
- 同步函数/阶段用线程 Track；跨线程生命周期使用同一显式 Track。**同一逻辑 Slice 的 BEGIN/END 分属不同进程**时，先读 [SDK 跨进程指南](references/02-sdk.md)：评估 `Track::Global()` + 同一 System 会话，不把 `Flow::Global()` 当作跨进程 Slice 配对 API。Flow 用于不同事件间真实交接；扇出使用不同边 ID。身份不可证时标 UNKNOWN，不能按时间最近补配。
- 配置：`python3 scripts/make_config.py --output app.pbtxt`。需与调度关联才加 `--with-sched --events available_events.txt`。
- `python3 scripts/validate_config.py app.pbtxt --check-resources`；没有同版本官方 descriptor，Schema 标 UNKNOWN。策略检查不等于 Schema，也不等于采集成功。
- 纯应用 TrackEvent 可以用 SDK InProcess 做最小验证；与 ftrace 联合必须使用 System backend 和同一个可达 producer socket。两者是 TrackEvent 的部署方式，不是两种业务入口。
- 板端按 [执行说明](references/04-platforms.md) 用 `scripts/record.sh`，有限时、独立输出目录。只管理本次 collector，不自动停止/重启/改业务。禁止混用私有/系统 socket 后假称联合成功。

## 3. 分析与证据

先执行 `00-inventory.sql` 和质量检查。用
`python3 scripts/analyze.py --tp /abs/TP --trace /abs/app.pftrace --out /abs/NEW_DIR`
保存 SQL/原始结果/退出码/三个哈希，再得到请求、阶段、Flow 和帧间隔分析。

- `integrity_status` 与 `outcome_status` 分开。缺 END 不等于 TIMEOUT，开放 Slice 不填零；有明确边界见证才标 CENSORED。
- 默认时延分布仅纳入 COMPLETE + SUCCESS + 无全局数据丢失的请求；DROP/ERROR/TIMEOUT 单列。报告样本量、排除数量、分位数定义。
- 墙钟耗时不等于 CPU；custom Track 不自动绑定执行线程。排队、处理、异步等待是不同维度。
- 显式 Flow 也不保证业务依赖全集已采到；本版不自动推导任意 DAG 关键路径。不将最长 Slice 叫根因。
- 发现 Running 热点时转 CPU；出现 Runnable/锁等疑点时转 Scheduling；涉及分配回收再用 Memory。共享 Trace、目标身份和窗口，不自动重采三套数据。

## 4. 交付和停止

交付埋点补丁/构建方法、实际配置、产物、数值与可复核 SQL、[手动 UI 步骤](references/05-ui.md)和证据边界。没有真实采集不写实测结论。发现足够证据后交付；只为明确缺口补采，不扩展大量压力/故障实验，不默认 UI 自动化。

首次集成/平台迁移时执行 [验收与开销](tests/SCENARIOS.md)，不要把 A/B/C 开销实验变成每次诊断的必经流程。已验证与未验证范围见 [测试报告](TEST_REPORT.md)。
