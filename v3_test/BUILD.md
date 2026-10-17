# memphase — 构建与运行说明

独立 ARM64 Linux 测试程序，用于本次 X5 板端 Perfetto 内存场景验证。不修改任何生产业务、内核配置或冻结版 Skill。

## 1. 源文件

`src/memphase.c`，单进程单线程，无第三方依赖，只用 glibc + Linux 系统调用。

时间线（程序自身墙钟）：

| 阶段 | 内容 | 目标时长 |
|---|---|---|
| baseline | 保持基线 | 5 s |
| A malloc | `malloc(32 MiB)` → 逐 4 KiB 页写入 0xA5（确保物理驻留）→ 保持 → `free` | 保持 6 s |
| A idle | 空闲 | 5 s |
| B mmap | `mmap(MAP_PRIVATE\|MAP_ANONYMOUS, 32 MiB)` → 逐页写入 → 保持 → `munmap` | 保持 6 s |
| B idle | 空闲 | 5 s |
| tail | 保持存活（最多 180 s），供会话脚本观测结束后统一停止/flush | — |

每个阶段边界写一行日志，同时尽力写 ftrace `trace_marker`（本板 tracebox v57.1 的 ftrace 数据源未把 `trace_marker` 收进 trace，故对齐以日志为准）：

```
<CLOCK_BOOTTIME ns> <CLOCK_REALTIME ns> EVENT <NAME> <detail...>
```

`CLOCK_BOOTTIME` 与 Perfetto Linux trace 的 `ts` 同钟（boot time ns），所以日志时间戳可直接与 trace `ts` 对齐，无需估算时钟偏移。hold/idle 期间每 500 ms 采样一次 `/proc/self/status:VmRSS` 写入 `RSS_SAMPLE`，作为独立于 trace 的旁证。

## 2. 交叉编译（主机 x86_64 → ARM64）

工具链：Arm GNU Toolchain 11.3.Rel1（`aarch64-none-linux-gnu-gcc`）。

```bash
TC=/opt/arm-gnu-toolchain-11.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-gcc
$TC -O1 -g -fno-inline -fno-omit-frame-pointer -Wall -Wextra \
    -o build/memphase_arm64 src/memphase.c
```

- `-fno-inline`：保证 `phase_a` / `phase_b` 保留为真实栈帧，便于 heapprofd 调用栈里区分 malloc 阶段（首轮 `-O1` 构建被内联，调用栈只到 `main`）。
- `-g` + 不 strip：板上 heapprofd 端符号化需要可读的 symtab/调试信息。
- 动态链接（`PT_INTERP=/lib/ld-linux-aarch64.so.1`）是 `LD_PRELOAD` 注入 heapprofd 的前提。

构建产物：`build/memphase_arm64`（ELF 64-bit ARM aarch64, dynamically linked, not stripped）。

本机逻辑自测（可选）：同一源码用 x86_64 gcc 构建并运行 40 s，确认阶段顺序、6 s/5 s 保持、RSS 先 +32 MiB 再回落：

```bash
gcc -O1 -g -o /tmp/memphase_x86_64 src/memphase.c
timeout 40 /tmp/memphase_x86_64 /tmp/memphase_x86.log
```

## 3. 板上部署（只写 /data tmpfs）

```bash
ssh root@<board>
mkdir -p /data/perf102v2/{bin,app,cfg,scripts,work}
# 从本目录上传：
#   build/memphase_arm64                        -> /data/perf102v2/app/memphase
#   <arm64 tracebox v57.1>                      -> /data/perf102v2/bin/tracebox
#   <arm64 libheapprofd_glibc_preload.so v57.1> -> /data/perf102v2/bin/libheapprofd_glibc_preload.so
#   configs/memphase-joint.pbtxt                -> /data/perf102v2/cfg/memphase-joint.pbtxt
#   scripts/frozen/linux_heapprofd_session.sh   -> /data/perf102v2/scripts/
#   scripts/frozen/linux_session_lib.sh         -> /data/perf102v2/scripts/
chmod +x /data/perf102v2/bin/tracebox /data/perf102v2/app/memphase /data/perf102v2/scripts/*.sh
```

运行：

```bash
cd /data/perf102v2
WORK=/data/perf102v2/work TRACEBOX=/data/perf102v2/bin/tracebox OBSERVE_S=45 \
  sh /data/perf102v2/scripts/linux_heapprofd_session.sh \
     /data/perf102v2/cfg/memphase-joint.pbtxt \
     /data/perf102v2/bin/libheapprofd_glibc_preload.so \
     /data/perf102v2/app ./memphase /data/perf102v2/work/memphase.log
```

程序从启动到两个阶段结束共约 27 s，之后进入 tail；`OBSERVE_S=45` 保证脚本在程序仍存活时先杀程序、再停止并 flush tracebox，不会出现 rc=6（目标提前退出）。冻结脚本要求 `duration_ms >= OBSERVE_S*1000 + 30000`，本配置 `duration_ms=90000` 满足。

## 4. 拉回

```bash
export SSHPASS=<board password>
PATH=$PWD/scripts/bin:$PATH sh scripts/frozen/host_pull.sh \
  root@<board> /data/perf102v2/work traces \
  heap.pftrace memphase.log heap.app.log heap.log heap.status heap.query.txt
```

`scripts/bin/scp` 是本次测试的 host 侧包装（sshpass + legacy scp），不属于冻结 Skill；冻结的 `host_pull.sh` 本身未修改。

## 5. 退出码与判读

- 会话脚本 stdout 最后一行 `DONE size_bytes=89233`，SSH 返回 0。
- `heap.status` 内容相同；说明走的是 DONE 分支，而不是 `TIMEOUT_STOPPED` / `EMPTY`。
- 程序自身在 A/B 阶段失败会返回 20/21/22；本次未出现。
