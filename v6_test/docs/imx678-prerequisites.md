# imx678 linear + offline 前置条件清单

本方案的内核/用户态埋点与传感器无关，换到 imx678 不需要改补丁；但**环境必须真的具备**以下条件，否则只能采到空/错误数据。当前板卡逐条不满足（见 README §0），因此本轮未采集。

## 1. 硬件与驱动

- [ ] imx678 模组实际接在目标 MIPI 口（rx_index 与 dts 一致），供电/时钟/复位正常。
- [ ] kernel 有 imx678 sensor 驱动并在 dts 中注册；`/sys/bus/i2c/devices/<bus>-<addr>/name` 可见 `imx678`，`lsmod` 有对应模块（若为模块）。
- [ ] 驱动支持 **linear** 模式（非 DOL/HDR）：单一 exposure，RAW10/12，无长/短帧拼接。
- [ ] `dmesg` 无 sensor probe/通信错误；`v4l2-ctl --list-formats` 或 vnode 查询能看到期望分辨率/帧率。

当前板对照：i2c 只有 sc230ai×4；rootfs 无 `imx678.ko`；kernel 树无 `imx678.c`。

## 2. 采集配置（offline 的关键字段）

以 offline vpm 配置（参考 `app/qualitytest/.../res/cfg/isp_cfg/1v_raw10_sen_sif_ddr_isp_960p/vpm_config.json`）为准，imx678 需要等价的一份：

- `vin_node0.cim.input.mipi`: `width/height/format/rx_index/vc_index/channels` 与 imx678 输出一致；
- `vin_node0.cim.output.cim_isp`: **`cim_isp_flyby: 0`**（不走 flyby 在线直连）、**`ddr_enable: 1`**（SIF 写 DDR）；
- `isp_node0`: **`input_mode: 2`**（offline/ DDR 输入）、**`ddr_en: 1`**；
- `vin_node0.cim.input.mipi.function`: **`enable_frame_id: 1`**（T1 用硬件 frame id 做 S/F cookie；关闭则配对失效）；
- `bind`: `vin_node0 → isp_node0`，`src_out_channel/dst_input_channel` 对应；
- `buf_num` 与帧率/分辨率匹配，避免因 buffer 饥饿把“队列驻留”测成“等 buffer”；
- 帧率固定（如 30fps），关闭任何动态跳帧/降帧策略。

若用 cam-service 驱动 offline 流：确认其 ISP 配置走 `ddr in offline` 分支（`hal_func.c` 有该日志），并确认 HAL 会收到 `ISP_MSG_MCM_SCH`/`ISP_MSG_FRAME_DONE`；否则 T2 只能在 kernel 侧测（见 README §2.3）。

## 3. 采集工具链

- [ ] 板上 `traced`/`tracebox`（本板：`/userdata/cpu-lab/perfetto-session/tracebox` v57.1）可用；
- [ ] `tracebox --help` 含 `--system-sockets` 与 `--notify-fd`（`record.sh` 会先检查）；
- [ ] `/sys/kernel/debug/tracing` 可读写，采集前 `tracing_on=0`、`events/enable=0`（避免抢占别人的采集）；
- [ ] 本方案主配置使用 `ftrace/print` + `track_event(camsys)`；确认 collector 能同时开启两类数据源；
- [ ] 用户态 T2 需要 `traced` 运行 + libisc 以 `CAM_TRACE_TRACK_EVENT=ON` 构建（需要真实 Perfetto SDK，未随包提供）。

## 4. 落地后先做的“非数值”验证

1. `00-inventory.sql`：`sif_frame_slices`、`isp_frame_slices`、`sif2isp_slices` 均 > 0，`open_camsys_slices` 可解释。
2. `01-quality.sql`：无数据丢失行。
3. 相邻 `camsys.sif.frame` 起点间隔 ≈ 1/fps；否则先查帧率/丢帧，不要出分位数。
4. `T1主 ≤ T1次`、`T4 FE ≤ T3 FS`、`T2 ≥ T3`；不满足先查事件语义/配对，不要“调参凑结论”。
5. 记录传感器型号、分辨率、帧率、曝光/增益、offline 模式、kernel/module 版本；sc230ai 的数值不得外推到 imx678。

## 5. 如果暂时只能在 sc230ai 上验证流程

可用板上现成的 offline 场景（`1v_raw10_sen_sif_ddr_isp_960p` 等）跑通 T1/T3/T4 的采集与分析链路，用来验证补丁与 SQL；T2 取决于是否由 cam-service 驱动。此时所有结论必须标注 **sensor=sc230ai、分辨率、offline、非 imx678**，且不得作为 imx678 性能结论。
