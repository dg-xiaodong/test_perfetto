# X5 ISP/SIF 四项时延测量 — 设计、埋点与静态自验（imx678 linear offline）

本目录是 **perfetto-latency-debugging v0.1.0 Candidate** 在 X5 相机链路上的一次测量设计交付：
目标场景为 imx678 linear **offline**（SIF→DDR→ISP）。**本轮没有采集任何 trace，也没有任何实测 ms 数值**——
板上不存在 imx678（见下），按用户确认只交付方法学 + 可复审埋点补丁 + 静态自验。

## 五个关键事实

1. **目标硬件不在本环境**：板（192.168.1.10，`6.1.83-DR-PL5.1_V1.0.20`）在挂传感器是 **sc230ai ×4**
   （i2c `1/2/4/7-0030`）；rootfs 无 `imx678.ko`，kernel 树无 `imx678.c`，tuning 配置无 imx678。
   因此本轮**不产出 imx678 数值**，也不拿 sc230ai 数值外推。
2. **T3/T4 已有现成埋点**：运行中的 `vs_sif_nat.ko`/`vs_isp_nat.ko` 已含 `camsys.sif.frame`、`camsys.isp.frame`
   字符串，可直接采 SIF/ISP 内核帧窗口；只有 T1（SIF 入队→ISP 出队）需要新补丁。
3. **T1 的 frame id 传递链已核对**：`sif_set_frame_des()`(FS) → `vio_frame_done()` 写入
   `frame->frameinfo.frameid` → ISP `cam_dqbuf_irq()` 拷回 vnode，两端 `cam_ctx_frame_id()` 同 id；
   因此 async Slice 与计数行可双向互证。
4. **T2 只能在用户态观测**：cam-service HAL 的 `ISP_MSG_MCM_SCH`→`ISP_MSG_FRAME_DONE`，**含内核→用户态消息往返**，
   不是硬件 FS→FE；若 offline 流由 `isp_tuning`/`vpm_gtest` 驱动，用户态没有逐帧“开始”边界，T2 不成立。
5. **静态自验通过，但没有一项等于“采集成功”**：内核模块编译成功（vermagic 与板上一致）；
   cam-service 默认构建无回归；`CAM_TRACE_TRACK_EVENT=ON` 且无真实 SDK 时显式失败；8 个 SQL 在 TP v57.1 语法通过。

## 四项测量边界

| 编号 | 边界 | 事件 |
|---|---|---|
| T1 主 | SIF FE `cam_qbuf_irq()` 前 → ISP `new_frame()` `cam_dqbuf_irq()` 成功后 | 新增 `camsys.sif2isp.queue` + `enq/deq` |
| T1 次 | SIF 入队 → ISP FS(BIT6) | 新增 `camsys.sif2isp.enq` + `camsys.isp.fs` |
| T2 | 用户态 `ISP_MSG_MCM_SCH` → `ISP_MSG_FRAME_DONE` | 新增 `camsys.isp.user`（TrackEvent） |
| T3 | 内核 ISP FS(BIT6) → FE(BIT1) | 现有 `camsys.isp.frame` |
| T4 | 内核 SIF FS → FE | 现有 `camsys.sif.frame` |

## 目录

| 路径 | 说明 |
|---|---|
| `REPORT.md` | 主报告：四项定义、埋点地图、构建/部署/采集/分析步骤、证据边界、自检清单 |
| `docs/build-verification.md` | 静态自验：编译命令与结果、artifacts 哈希、配置策略、SQL 语法、补丁状态 |
| `docs/imx678-prerequisites.md` | imx678 linear + offline 前置条件（驱动、vpm 字段、`enable_frame_id` 等） |
| `config/isp-latency-kernel.pbtxt` | 主配置：`ftrace/print` + `track_event(camsys)` + `process_stats` |
| `config/isp-latency-trackevent-only.pbtxt` | 仅 T2 的 TrackEvent 配置（Skill `POLICY_PASS`） |
| `patches/0001-…patch` | 内核 SIF→ISP 队列埋点（`vs_sif_nat`/`vs_isp_nat`，可 `git apply`） |
| `patches/0002-…patch` | cam-service HAL TrackEvent 埋点（可选开关 + 真实 SDK 门控） |
| `sql/00…13` | inventory、质量检查、T1 两种口径、T2、T3、T4 的 PerfettoSQL |
| `scripts/record-remote.sh` | 后续采集用封装（push 配置 + Skill `record.sh`；本轮未执行） |
| `SQL 验证` | 8 个 SQL 均在 Trace Processor v57.1 空 trace 上通过语法检查 |

## 版本

- Skill：`perfetto-latency-debugging v0.1.0 Candidate`（安装路径 `/root/.dsh/skills/perfetto-latency-debugging`）
- 板上采集器：`tracebox v57.1-c59f57dd4`（`/userdata/cpu-lab/perfetto-session/tracebox`）
- 分析端：Trace Processor `v57.1-c59f57dd4`
- 目标 kernel：`6.1.83-DR-PL5.1_V1.0.20`

## 结果声明

**0 条真实 trace、0 个实测数值。** 本轮所有“结果”都是静态验证（编译、策略、SQL 语法、补丁可应用性），
不等于采集成功，也不等于 imx678 性能结论。后续上板步骤见 `REPORT.md` §3–§5 与 `docs/imx678-prerequisites.md`。
