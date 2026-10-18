# 静态自验记录（无采集、无部署）

日期：2026-10-18。范围：补丁可编译性、配置策略检查、SQL 语法。**未连接流、未加载模块、未抓 trace。**

## 1. 环境

| 项 | 值 |
|---|---|
| 工作区 | `/root/code_1.0.20` |
| 交叉编译器 | `/opt/arm-gnu-toolchain-11.3.rel1-x86_64-aarch64-none-linux-gnu/bin` |
| 内核输出目录 | `out/build/kernel`（已有 `.config`，`CONFIG_TRACING=y`） |
| 板上 kernel | `6.1.83-DR-PL5.1_V1.0.20` |
| Trace Processor | `/root/.cache/perfetto-skill/trace_processor_shell` v57.1-c59f57dd4 |
| 板上 tracebox | `/userdata/cpu-lab/perfetto-session/tracebox` v57.1-c59f57dd4 |

## 2. 内核模块编译 ✅

```sh
cd /root/code_1.0.20
export PATH=/opt/arm-gnu-toolchain-11.3.rel1-x86_64-aarch64-none-linux-gnu/bin:$PATH
export CROSS_COMPILE=aarch64-none-linux-gnu-
export OUTPUT_BUILD_DIR=$PWD/out/build/kernel ARCH=arm64
make -C kernel O=$PWD/out/build/kernel M=drivers/media/platform/horizon/camsys modules -j8
```

- 结果：`LD [M] .../vs_sif_nat.ko`、`LD [M] .../vs_isp_nat.ko` 等全部成功，退出码 0；补丁涉及文件 `CC` 无 warning/error。
- 说明：`M=.../vsi_cam` 单目录构建会缺少父目录 `subdir-ccflags-y`（ion/vin_node 头路径），因此按 parent `camsys` 构建；这是构建入口选择，不是源码问题。

产物：

| 文件 | sha256 | vermagic |
|---|---|---|
| `vs_sif_nat.ko` | `534c920b504f9b9887a9b57b6cd75b4bff5a59a96d8dc64903b21ede238b6947` | `6.1.83-DR-PL5.1_V1.0.20 SMP preempt mod_unload aarch64` |
| `vs_isp_nat.ko` | `5b98126f73b6e1775ee71fd82635d02e6ca804189437157f6e3d22195046852a` | 同上 |

符号/字符串核对：

- `nm vs_sif_nat.ko | grep cam_ctx_frame_id` → `T cam_ctx_frame_id`（新符号）；
- `vs_sif_nat.ko` 含 `camsys.sif2isp.enq`、`camsys.sif2isp.queue`；
- `vs_isp_nat.ko` 含 `camsys.sif2isp.deq`、`camsys.sif2isp.queue`、`camsys.isp.fs`；
- 运行中板卡模块已含 `camsys.sif.frame`、`camsys.isp.frame`（`strings` 核实），T3/T4 可先用现有模块。

## 3. cam-service 构建（默认 OFF）✅

```sh
CCACHE_DISABLE=1 ./bd.sh hbre x5_camsys
```

- 退出码 0；`cam-service`、`libhal.so` 重建成功（`libhal.so` 23:14，`cam-service` 23:15）。
- `CMakeCache.txt`: `CAM_TRACE_TRACK_EVENT:BOOL=OFF`，即默认构建与改动前一致；`hal.c` 的埋点被 `#ifdef` 编译掉。

## 4. 用户态 TrackEvent 开关行为 ✅（无 SDK 时不静默降级）

```sh
cmake -S prebuilts/hbre/source/x5_camsys/cam_service -B out/build/hbre/x5_camsys/build \
      -DCAM_TRACE_TRACK_EVENT=ON
```

实际输出（节选）：

```
CMake Error at service/isc/CMakeLists.txt:18 (message):
  CAM_TRACE_TRACK_EVENT=ON requires -DPERFETTO_SDK_DIR=<dir> containing
  perfetto.h and libperfetto.a
```

随后以 `-DCAM_TRACE_TRACK_EVENT=OFF` 恢复，cache 已确认回到 OFF。

**未编译**：`rr_perfetto.cc` / `trace_categories.cc` / `hal.c` 的 ON 分支。本机无真实 Perfetto SDK（无 `perfetto.h`/`libperfetto.a`），按约定不下载、不伪造依赖，因此该项如实记为未验证。

## 5. 配置策略检查

| 配置 | 结果 |
|---|---|
| `config/isp-latency-trackevent-only.pbtxt` | `POLICY_PASS (recipe checks, NOT official schema)` + `SCHEMA_UNKNOWN` |
| `config/isp-latency-kernel.pbtxt` | `FAIL: unexpected/missing sched event` |

第二条是**预期的范围边界**：Skill 的 `validate_config.py` 只接受 `linux.ftrace` 配 `sched/sched_switch + sched/sched_waking`（应用级联合采集），不接受 `ftrace/print`（内核 atrace）。本方案未修改 Skill 校验器来“凑过”，而是明确记录：主配置的合法性只能由采集时的 collector 验证；策略检查通过 ≠ schema 通过 ≠ 采集成功。

## 6. SQL 语法验证 ✅（空 trace，仅语法）

用 TP v57.1 加载 0 字节 trace，逐条执行 `sql/*.sql`：

| 文件 | 结果列数 | 状态 |
|---|---|---|
| `00-inventory.sql` | 11 | OK |
| `01-quality.sql` | 5 | OK |
| `10-test1-queue.sql` | 8 | OK |
| `10b-test1-counters.sql` | 5 | OK |
| `11-test2-userspace.sql` | 6 | OK |
| `11b-test2-userspace-aggregate.sql` | 8 | OK |
| `12-test3-kernel-isp.sql` | 8 | OK |
| `13-test4-kernel-sif.sql` | 8 | OK |

修正记录：v57.1 的 `counter` 表没有 `name` 列（名称在 `counter_track`），初版计数 SQL 已改为 `counter JOIN counter_track`；多语句文件会触发 “Result rows were returned for multiples queries”，已拆成单语句文件 / `UNION ALL`。

## 7. 补丁状态

- 内核补丁已应用到 `kernel` 树（`git apply -R --check` 通过，表示补丁与工作区完全一致）。注意 `drivers/media/platform/horizon/camsys` 被 kernel `.gitignore` 忽略，因此补丁由“重建原始文件 + unified diff”生成，而非 `git diff`。
- cam_service 补丁已应用到工作区（`hal.c`、`isc/CMakeLists.txt` 修改 + 4 个 shim 文件）。
- 回滚：`git apply -R patches/0001-...`（kernel 根）；cam_service 用 `git checkout -- service/hal/isp/hal.c service/isc/CMakeLists.txt` 并删除 4 个 shim 文件。

## 8. 仍未验证（后续采集阶段）

- 新模块在板上 `insmod`、与现有 `vs_vse_nat` 依赖顺序、`dmesg` 无错；
- collector 接受主配置并产出非空 trace；`ftrace/print` 能被 v57.1 正确解析为 async slice/counter；
- T1 的 frame id 两端一致（采集后按 README §5 检查）；
- 用户态 T2 的 TrackEvent 实际落盘与 track 命名；
- imx678 硬件/驱动/配置本身。
