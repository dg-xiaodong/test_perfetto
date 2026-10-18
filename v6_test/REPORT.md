# X5 ISP/SIF 四项时延测量 — 方法学与埋点补丁（未采集）

> 目标：perfetto-latency-debugging v0.1.0 Candidate；X5 / imx678 linear **offline**（SIF→DDR→ISP）。
> 本轮范围（用户确认）：**只交付方法学与可复审埋点补丁，不做任何采集/实测**；代码改动与重编仅用于静态自验。
> 本文件不含任何实测数值；所有“结果”都必须由后续采集产生。

## 0. 一句话结论与阻塞

本机可访问的 X5 板（192.168.1.10，`6.1.83-DR-PL5.1_V1.0.20`）**没有 imx678**：

- 在挂传感器为 **sc230ai ×4**（i2c `1-0030 / 2-0030 / 4-0030 / 7-0030`），`lsmod` 无任何 imx 模块；
- rootfs `/lib/modules/.../media/i2c/` 只有 `sc230ai.ko`，无 `imx678.ko`；
- 本仓库 kernel 树无 `imx678.c`（`drivers/media/i2c/` 只到 imx355 等）；
- 板上 tuning 配置只有 `imx415/imx586/os08c10/sc*`，无 imx678。

所以本次**无法产出 imx678 的真实数值**。补丁与方法学是传感器无关的；换到真实 imx678 offline 环境（或先在 sc230ai offline 上跑通流程）即可执行。前置条件见 [docs/imx678-prerequisites.md](docs/imx678-prerequisites.md)。

## 1. 四项测量的精确定义

所有时间都来自同一份 Perfetto trace（kernel ftrace `print` atrace + userspace TrackEvent），统一用 boot 时间轴。

| 编号 | 用户表述 | 精确边界（本方案） | 事件来源 | 包含什么 / **不**包含什么 |
|---|---|---|---|---|
| T1 主 | SIF 写 queue → ISP 实际读取 queue | SIF FE 把完成帧 `cam_qbuf_irq()` 前 → ISP `new_frame()` 里 `cam_dqbuf_irq()` 成功后 | 新增 `camsys.sif2isp.queue`（async S/F）+ `camsys.sif2isp.enq/deq` 计数 | 队列驻留 + 调度延迟；不含 ISP 处理本身，也不含硬件读 DDR 的完成时间 |
| T1 次 | （同上，读到硬件开始） | SIF 入队 → ISP FS（MIS BIT6）中断处理 | 新增 `camsys.sif2isp.enq` + `camsys.isp.fs` 计数 | 入队到硬件真正开始读的交接；含 IRQ 分发延迟 |
| T2 | 用户态开启一帧 ISP 处理 → 结束 | cam-service HAL 收到 `ISP_MSG_MCM_SCH` → 收到 `ISP_MSG_FRAME_DONE` | 新增 userspace TrackEvent `camsys.isp.user`（category `camsys`） | **含内核→用户态消息往返**（Skill 明确提示约 +1 ms 量级）；不是 FS→FE；不含用户态取帧/释放 buffer |
| T3 | 内核态 ISP 一帧开始→结束 | `isp_irq_handler` FS(BIT6) → FE(BIT1) | 现有 `camsys.isp.frame`（已在运行模块中） | 含 IRQ 处理延迟；不含调度排队（T1 次覆盖） |
| T4 | SIF 模块一帧内核开始→结束 | `sif_handle_frame_start()` FS → `sif_handle_frame_done()` FE | 现有 `camsys.sif.frame`（已在运行模块中） | SIF 帧接收→DDR 写完；不是曝光时间，也不是 ISP 处理 |

派生关系（可用于一致性检查，不是因果结论）：

- `T1主 ≤ T1次`：先软件出队，后硬件 FS。
- `T4` 的 FE 早于 `T3` 的 FS（offline：SIF 写入 DDR 后 ISP 才可能读），`T1主` 应落在两者之间的交接窗口。
- `T2 ≳ T3`：T2 额外包含两次消息投递与用户态调度。

**边界声明**：这些是帧级硬件流水线指标，**不适用** Skill 的 `latency.v1` 请求契约（`run_id/stream_id/request_id/stage_instance_id`）。本方案复用 Skill 的采集/质量纪律（有界采集、数据丢失检查、开放 Slice 不填零、样本量/分位数口径、无观测不下结论），但不套用其请求生命周期分析器 `analyze.py`。

## 2. 埋点地图

### 2.1 已存在、无需改动（T3/T4）

| 事件 | 位置 | 语义 |
|---|---|---|
| `camsys.sif.frame` S/F | `sif/sif_handler.c: sif_handle_frame_start/done` | SIF FS→FE |
| `camsys.isp.frame` S/F | `isp/isp_handler.c: isp_irq_handler` BIT6/BIT1 | ISP FS→FE |

均通过 `include/camsys_trace.h` 的 `trace_puts("S|0|<name>|<cookie>")` 输出，cookie=`(dev_id<<8)|inst`，Perfetto 以 `ftrace/print` → systrace async slice 解析。**已核实运行中的 `vs_sif_nat.ko`/`vs_isp_nat.ko` 内含这两个字符串**，所以 T3/T4 可先用现有模块采。

### 2.2 新增（T1）

| 事件 | 位置 | 说明 |
|---|---|---|
| `camsys.sif2isp.queue` S | `sif_handler.c`，`cam_qbuf_irq(buf_ctx, *buf, true)` 前 | 以硬件 frame id 为 cookie |
| `camsys.sif2isp.enq` C | 同上，紧随 `cam_qbuf_irq` | value=frame id，供 SQL 交叉核对 |
| `camsys.sif2isp.queue` F | `isp_handler.c`，`new_frame()` 中 `cam_dqbuf_irq()` 成功后 | 同一 cookie 关闭 |
| `camsys.sif2isp.deq` C | 同上 | value=frame id |
| `camsys.isp.fs` C | `isp_irq_handler` BIT6 分支（仅 offline 源） | value=frame id，得 T1 次 |

frame id 传递链已核对：`sif_set_frame_des()`(FS) 写 `vnode->frameid` → `vio_frame_done()` 在 SIF FE 把它写进 `frame->frameinfo.frameid`（`vpf/vio_video_api.c`）→ ISP `cam_dqbuf_irq()` 再拷回 ISP vnode（`native/cam_buf.c`）。因此两端 `cam_ctx_frame_id()` 返回同一 id。若现场发现 enq/deq 的 frame id 集合不一致，见 §5 的一致性检查，按“配对失败”处理，不得直接出数。

### 2.3 新增（T2，用户态）

| 事件 | 位置 | 说明 |
|---|---|---|
| `camsys.isp.user` async begin | `cam_service/service/hal/isp/hal.c`，`case ISP_MSG_MCM_SCH` 入口 | track=`0xCA5E…｜dev_id<<8｜inst` |
| `camsys.isp.user` async end | 同文件，`case ISP_MSG_FRAME_DONE` 入口 | 配对失败映射路径也会关闭 |

`rr_perfetto.cc` 已存在（`kSystemBackend`，连接 `traced`），但此前**未接入构建**；本补丁把 `rr_perfetto.cc`/`trace_categories.cc` 以可选开关接入 `libisc`，并给 `hal.c` 加埋点。默认 `CAM_TRACE_TRACK_EVENT=OFF`，构建行为与原来完全一致。

## 3. 构建与部署（本轮未执行部署）

### 3.1 内核模块（已做构建自验，未部署）

```sh
cd /root/code_1.0.20
export PATH=/opt/arm-gnu-toolchain-11.3.rel1-x86_64-aarch64-none-linux-gnu/bin:$PATH
export CROSS_COMPILE=aarch64-none-linux-gnu-
export OUTPUT_BUILD_DIR=$PWD/out/build/kernel ARCH=arm64
make -C kernel O=$PWD/out/build/kernel M=drivers/media/platform/horizon/camsys modules -j8
```

产物：`out/build/kernel/drivers/media/platform/horizon/camsys/vsi_cam/vs_sif_nat.ko`、`vs_isp_nat.ko`（vermagic 与板上 `6.1.83-DR-PL5.1_V1.0.20` 一致，可免刷内核替换）。

部署（**未执行**；只在真正要采集时做）：

1. 推两个 `.ko` 到 `/userdata/isp-lat/`；
2. 停流：`/etc/init.d/S90cam-service stop`；
3. 按 `lsmod` 依赖顺序卸载：先 `vs_vse_nat`（它用 `vs_isp_nat`），再 `vs_isp_nat`、`vs_sif_nat`；
4. `insmod /userdata/isp-lat/vs_sif_nat.ko`、`insmod /userdata/isp-lat/vs_isp_nat.ko`，用 `lsmod`/`dmesg` 确认；
5. 需要回滚就重新 `insmod` 原 rootfs 模块（同一 vermagic）。

约束：只管理本次 collector 与这两个模块；不自动重启业务、不改 `/usr/hobot` 只读分区。

### 3.2 cam-service（TrackEvent，T2）

```sh
# 需要真实 Perfetto SDK（perfetto.h + libperfetto.a），本机未下载、未伪造
cmake -S prebuilts/hbre/source/x5_camsys/cam_service -B out/build/hbre/x5_camsys/build \
      -DCAM_TRACE_TRACK_EVENT=ON -DPERFETTO_SDK_DIR=/abs/path/to/sdk
make -C out/build/hbre/x5_camsys/build -j4
```

无 SDK 时 `CAM_TRACE_TRACK_EVENT=ON` 会**显式 FATAL_ERROR**，不会静默降级（已实测，见 build-verification）。部署走 `/userdata` + `LD_LIBRARY_PATH`，不覆盖只读 rootfs。若目标 offline 流由 `isp_tuning`/`vpm_gtest` 驱动而不是 cam-service，则**用户态没有逐帧“开始”边界**（用户态只拿完成帧），T2 在该路径上不可测，只能报 T3 + 消息/调度开销，不能编造用户态数值。

### 3.3 采集

```sh
# 板上 tracebox v57.1 在 /userdata/cpu-lab/perfetto-session/tracebox
TRACEBOX=/userdata/cpu-lab/perfetto-session/tracebox \
  sh ~/.dsh/skills/perfetto-latency-debugging/scripts/record.sh \
     config/isp-latency-kernel.pbtxt /userdata/trace/isp-run1 75
```

`record.sh` 只录不启停业务；输出目录必须是新目录；`TIMEOUT_DATA_UNTRUSTED`/`CAPTURE_FAILED`/`EMPTY` 一律不得当 PASS。

若不想手工 push 配置，可用同一目录下的 `scripts/record-remote.sh`（封装 ssh/scp + 同样的 record.sh，本轮未执行）：

```sh
BOARD=root@192.168.1.10 ./scripts/record-remote.sh config/isp-latency-kernel.pbtxt /userdata/trace/isp-run1 75
```

## 4. 分析

```sh
TP=/root/.cache/perfetto-skill/trace_processor_shell   # v57.1，与板上 tracebox 同版本
$TP -q sql/00-inventory.sql  run/trace.pftrace
$TP -q sql/01-quality.sql    run/trace.pftrace   # 任何非零行先处理，再谈数值
$TP -q sql/10-test1-queue.sql run/trace.pftrace
$TP -q sql/10b-test1-counters.sql run/trace.pftrace
$TP -q sql/11-test2-userspace.sql run/trace.pftrace
$TP -q sql/11b-test2-userspace-aggregate.sql run/trace.pftrace
$TP -q sql/12-test3-kernel-isp.sql run/trace.pftrace
$TP -q sql/13-test4-kernel-sif.sql run/trace.pftrace
```

口径：

- 只统计 `dur >= 0` 的完整 Slice；`dur = -1` 单独计 `open_slices`，**不填零**。
- 分位数用顺序统计量：p50=`rn=(n+1)/2`，p90=`rn=⌊0.90n⌋`，p99=`rn=⌊0.99n⌋`。
- 报告必须同时给样本量、排除量、采集窗口长度与 `stats` 数据丢失结果。
- 墙钟耗时不等于 CPU 时间；本方案不声明“根因”，最长帧不等于根因。

## 5. 采集后必须先过的自检

1. **计数与 Slice 同量级**：`00-inventory` 中 enq/deq 数 ≈ sif2isp Slice 数；差值大说明 S/F 配对或丢帧。
2. **frame id 配对率**：`10b` 的 `pairs` 应接近 enq 数；若明显偏低，frame id 未按预期传播，**T1 主结论作废**（可退回异步 Slice 结果，但要标注配对未经交叉验证）。
3. **两种 T1 口径互证**：`10` 的 Slice 分位数与 `10b` 的 enq→deq 分位数应在时钟分辨率内一致。
4. **时序合理性**：`T1主 ≤ T1次`；`T4` 的 FE 不晚于 `T3` 的 FS；`T2 ≥ T3`。
5. **帧率合理性**：相邻 `camsys.sif.frame` 起点间隔 ≈ 1/fps。
6. **数据丢失**：`01-quality` 全零；出现 `ftrace_overrun`/丢片时该段数值不可用。
7. **frame id 必须开启**：vpm 配置需 `enable_frame_id: 1`；否则两端 cookie 恒为 0，异步 Slice 无法按帧配对（此时只能用计数行，且要先证明 id 非零）。
8. **重启/帧号回绕**：传感器 restart 或 `set_init_frame_id` 会让 frame id 归零；Perfetto 的 async S/F 对同名同 cookie 是“不可嵌套”的，旧 slice 未关时新的同号 S 会被忽略。遇到重启，截断窗口或丢弃重启后的前若干帧，不要用这些样本。

## 6. 能证明 / 不能证明

- 能证明：在声明窗口与配置下，上述四个边界之间的墙钟时间分布（含 IRQ/消息/调度开销）。
- 不能证明：ISP 内部哪一级模块耗时、CPU 占用、业务因果、跨在线/离线模式的可比性；也不能把 sc230ai 数值外推到 imx678。
- 未观测即不写：没有真实 trace 就不产出任何“实测 ms”。

## 7. 产物与自验

- 补丁：`patches/0001-camsys-sif2isp-queue-atrace.patch`（已应用到 kernel 树，可 `git apply -R` 复核）、`patches/0002-cam-service-isp-userspace-trackevent.patch`（已应用到 cam_service 工作区）。
- 配置：`config/isp-latency-kernel.pbtxt`（主）、`config/isp-latency-trackevent-only.pbtxt`（仅 T2，POLICY_PASS）。
- SQL：`sql/00…13`，已在 TP v57.1 空 trace 上逐条通过语法验证。
- 构建自验记录：[docs/build-verification.md](docs/build-verification.md)。
- imx678 前置条件：[docs/imx678-prerequisites.md](docs/imx678-prerequisites.md)。

## 8. 明确未验证

- 未在板上加载新模块、未改运行中的 cam-service、未起流、未抓 trace。
- 用户态 TrackEvent 补丁未编译（本机无真实 Perfetto SDK；按约定不下载、不伪造）。
- 配置的“策略检查”不等于官方 schema，也不等于采集成功；采集时仍需 collector 接受配置并产出非空 trace。
- imx678 offline 的驱动/配置/模式本身未在本环境存在，见前置条件文档。
