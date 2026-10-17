# RDK X5 `worker_app`：Perfetto 调试与分析方案

> **版本：v2_modify2（v2_modify 的增量修正）**
> 首轮 `v2_test/` 与已提交的 `v2_modify/` 均原样保留；本目录只修 PLAN 执行路径
> 和 `v2_modify2/sql/20-jitter-cycles.sql` 的 1 秒桶区间交集。
> 这不是新的盲测成绩，不把修正后的表现冒充首轮首次交付质量。
>
> 方案只做设计与静态/离线验证，未连接开发板、未修改业务程序、未采集任何真实 trace。
> 文中所有“预期/待验证”均未标注为已实测结果。

## 0. Skill 加载记录

- 实际加载入口（仓库根相对）：`v1_modify/candidate-v1.0.1/SKILL.md`
- 版本：`1.0.1`（`MANIFEST.json`），Git 提交：`f16f68ae1e3f112794af3b953881d1b18fa8415e`
- 工作树 HEAD：`3dcef36`；`git diff f16f68a HEAD -- v1_modify/candidate-v1.0.1` 为空，候选目录与该提交一致。
- 完整性：`SKILL.md` sha256 `70371e5b...`、`v1_modify/candidate-v1.0.1/references/02-native.md` sha256 `21b8bd7a...`、`v1_modify/candidate-v1.0.1/scripts/validate_config.py` sha256 `98c2f8f6...` 均与 `MANIFEST.json` 一致。
- 资源预检：`python3 v1_modify/candidate-v1.0.1/scripts/validate_config.py --check-resources` → PASS（27 个必需文件 + 10 个配置可读）。
- 未使用已部署的 v1.0.0：`/root/.dsh/skills/perfetto-memory-debugging/MANIFEST.json` 版本为 `1.0.0`，`SKILL.md` sha256 `4f5f6ae9...`，与候选版不同；本方案未以它为依据。
- 使用的主要参考：
  `v1_modify/candidate-v1.0.1/references/00-routing.md`、`01-counters.md`、`02-native.md`、`04-ui.md`、`05-platforms.md`、`06-quality.md`、`07-internals-and-pprof.md`、`08-worked-examples.md`、`09-advanced-configs.md`、`sources.md`；
  `v1_modify/candidate-v1.0.1/scripts/survey.sh`、`v1_modify/candidate-v1.0.1/scripts/make_config.py --help`、`v1_modify/candidate-v1.0.1/scripts/validate_config.py`；
  `v1_modify/candidate-v1.0.1/sql/00-inventory.sql`、`01-rss-timeline.sql`、`03-native-live.sql`、`04-native-callstacks.sql`、`07-kernel-events.sql`、`10-native-dump-capability.sql`；
  `v1_modify/candidate-v1.0.1/configs/overview.pbtxt`、`native.pbtxt`、`kernel-pressure.pbtxt`、`rss-spike.pbtxt`。
- 未读取 `TEST_REPORT.md`、`tests/agent_ab/`、`agent_records/`、`verify/`、`AGENT_AB.md` 等开发/纠错/A-B 评分材料。

## 1. 问题分析与假设

已知事实：

- RSS 180–200 MB 稳定，MemAvailable 未持续下降，无 OOM、无明显回收压力。
- 业务线程每隔几秒 CPU 上升，同时处理延迟抖动。
- 程序频繁创建/销毁临时对象（用户怀疑，尚无直接证据）。

第一结论：**现有证据不支持“内存泄漏/系统内存压力是根因”**。RSS 稳定不等于没有分配抖动；`Total Malloc` 可以很高而 `live` 接近零。反之，CPU 抖动也可能完全与内存无关。因此先证伪“内存/分配是原因”，再定位代码路径。

| 假设 | 预期证据 | 证伪条件 | 主要数据源 |
|---|---|---|---|
| H0 观测/工具伪影 | 只在采样/统计窗口出现，独立计数器不一致 | `sched_slice`/`process_stats` 也显示同样周期性；换采样率仍存在 | 计数器 + sched |
| H1 周期性业务批量 | 固定周期、固定线程、固定函数集合；分配/系统事件随之 | 周期不固定、热点分散、无重复函数 | sched + perf |
| H2 临时对象分配/释放开销 | `Total Malloc Size/Count` 在抖动窗上升；perf 中 allocator/free 占比上升；与延迟有剂量关系 | 抖动窗与安静窗分配率相同；allocator 占比不变 | heapprofd + perf + sched |
| H3 内核回收/规整/缺页 | `vmscan`/`compaction`/`rss_stat` 与 D 状态、MemAvailable 变化同窗 | 无事件、RSS 平、D 状态为零 | sched + ftrace + sys_stats |
| H4 DVFS/热限制 | CPU 频率下降、CPU 时间上升但工作量不变 | 频率稳定、cycles/instructions 不变 | `power/cpu_frequency`、`cpufreq` |
| H5 调度争用/其他进程 | runnable 时间上升、被抢占、其他进程同 CPU 忙 | runnable≈0、无抢占、目标独占 CPU | sched + perf |
| H6 采集器自身扰动 | 开启 profiler 才出现；关闭后消失 | 低开销 C1 也复现；与 profiler 开关无关 | C1 对照 |

## 2. 选路：三遍采集，不做一个“大而全”配置

| 遍 | 配置 | 目的 | 为什么需要 | 不覆盖 |
|---|---|---|---|---|
| C1 | `C1-worker-timeline.pbtxt` | 抖动形状/周期、RSS/缺页/回收/DVFS/调度上下文 | 低开销，先判断“内存是否参与”，避免 profiler 制造抖动 | 无分配调用栈、无 CPU 调用栈 |
| C2 | `C2-worker-native-alloc.pbtxt` | 哪条调用栈分配/释放、Total vs live、抖动窗 vs 安静窗 | 唯一能把分配量归因到 C++ 调用栈的数据源 | 不是 CPU 时间；不是逐次 malloc；不覆盖直接 mmap/自定义 pool 内部 |
| C3 | `C3-worker-cpu-profile.pbtxt` | 抖动时 CPU 花在哪些函数；allocator 占比 | 直接回答“代码路径”，并与 C2 互补 | 无分配字节数；采样有偏差；需要符号/perf 权限 |

选路理由：

- **不以 heapprofd 为首遍**：用户主诉是 CPU/延迟，RSS 稳定；先证明内存是否参与，避免把分配活动误当根因。
- **不默认同时开高频 sched、全系统 heap、perf、全部 vmstat**：采集本身可能造成 CPU/内存/调度扰动（Skill 的 00-routing 明确要求节制）。
- **C2 与 C3 分开**：heapprofd 的 unwind/记账与 perf 的采样/展开都会增加负载；分开采集才能用 C1 作为无 profiler 对照。
- **不用 ART/heap graph**：目标是 C++ native，不涉及 Java 对象图。

数据源覆盖与局限：

- `linux.process_stats`：进程/线程 RSS、VM、utime/stime；1 s 轮询，漏掉亚秒尖峰；无调用栈。
- `linux.sys_stats`：MemAvailable、vmstat、CPU times、cpufreq；系统级，不能直接归因到线程。
- `linux.ftrace`：
  - `sched/sched_switch`、`sched/sched_wakeup`：on/off CPU、runnable 等待；高频，需控制 buffer。
  - `kmem/rss_stat`：亚秒 RSS 记账；`size` 是该类别绝对量，**不能 sum(size)**，同刻分类值才可相加。
  - `vmscan`/`compaction`/`oom`：回收/规整/被杀；有事件才说明发生，没有不自动等于“零压力”。
  - `power/cpu_frequency`、`power/cpu_idle`：DVFS/ idle 混淆因素。
  - `ftrace/print`：只捕获程序**已有**的 trace_marker；不改造程序就没有新标记。
- `android.heapprofd`：native allocation 采样归因；默认 1/4096 或 1/8192 字节采样；`Total` 是累计分配流量，`Unreleased` 是追踪范围内未配对释放的估计；**不是 RSS，不是 CPU 时间，不是逐次 malloc 时间线**。
- `linux.perf`：CPU 采样调用栈；回答“CPU 花在哪”，不回答“分配了多少”；需要 `perf_event_open` 权限、符号/展开信息。
- `mmap/munmap/brk/madvise` syscall：只覆盖分配器的 backing/直接映射；glibc tcache 的小对象临时分配通常不产生这些 syscall，因此不能拿它替代 heapprofd。

### 2.3 heapprofd count 的采样估计语义

- `heap_profile_allocation.count` / `size` 是**随机字节采样后的估计值**，不是精确
  malloc/free 调用次数或精确字节数；`Total Malloc Count` 也是估计，不是逐调用日志。
- 分析表的 `count` 已经过采样估计处理，**不要**再乘 `sampling_interval_bytes`。
- `Unreleased` 是追踪范围内“分配未配对释放”的估计，不是 RSS；高 `Total` 只说明
  分配流量活跃，不能单独证明 CPU 开销或延迟。
- heapprofd 和 `linux.perf` 都**不记录业务级延迟**。业务延迟必须来自独立证据：
  应用日志/打点、`trace_marker`、业务帧/请求时间戳，或与这些事件同 trace 的标记。
  `thread_state` 的 runnable/D 状态只是系统级等待代理，不能冒充业务处理延迟。

## 3. TraceConfig

三个配置均位于 `v2_modify/configs/`（本增量目录不复制配置）。
Markdown 文件链接按本文件所在目录解析（`../v2_modify/`）；第 4 节命令按仓库根解析（`v2_modify/`）。

已用本地 v58.2 源码生成的 descriptor 做静态 schema 校验（PASS）；**未做 v57.1 descriptor 校验，也未在板端解析**。

### 3.1 C1：低开销时间线

完整文件：[C1-worker-timeline.pbtxt](../v2_modify/configs/C1-worker-timeline.pbtxt)

关键参数依据：

- `duration_ms: 30000`：每隔几秒一次抖动，30 s 可覆盖约 6–15 次；先短后长，避免 tmpfs 压力。
- `buffers` 16/4/4 MB：ftrace 高频单独 buffer；process/sys stats 分开，避免被 ftrace 挤掉。
- `proc_stats_poll_ms: 1000`、`record_process_runtime: true`：1 s 进程 RSS/utime/stime；与 CPU bucket 对齐。
- `meminfo/vmstat/stat/cpufreq` 1 s：系统压力与 DVFS；不把所有 vmstat 全开。
- `buffer_size_kb: 2048`：ftrace 是**每 CPU** ring；2048 KiB × N CPU，需按板端 `nproc` 和 `/data` 余量调整。
- `sched_switch` + `sched_wakeup`：CPU 占用与 runnable 延迟；`sched_wakeup` 是高频事件，若丢事件先减它。
- `rss_stat`、direct reclaim、compaction：验证 H3；若 `available_events` 没有这些事件，按预检结果删除对应行。
- `ftrace/print`：只读已有 trace_marker，不要求改代码。

### 3.2 C2：native allocation 归因

完整文件：[C2-worker-native-alloc.pbtxt](../v2_modify/configs/C2-worker-native-alloc.pbtxt)

关键参数依据：

- `sampling_interval_bytes: 8192`：先稀疏采样，控制目标进程开销；小对象热点有方差，需重复相同 workload；要更细可改 4096，但先看丢包/CPU。
- `process_cmdline: "worker_app"`：精确 basename；同名多进程/预加载 fork 子进程要在 `00-inventory.sql` 中按 `data_bearing` 解析，不能静默取第一行。
- `heaps: "libc.malloc"`：Linux glibc 默认 heap；若该字段在目标版本导致空数据，去掉它，默认仍采 malloc。
- `shmem_size_bytes: 8388608`：默认 8 MiB；高频分配若溢出，`block_client:false` 会提前停止或丢数据，需用 stats/log 判读，必要时升到 16/32 MiB。
- `block_client: false`：不把 profiler 压力变成目标线程阻塞；代价是可能丢数据/提前结束。
- `continuous_dump_config`：`dump_phase_ms:500`、`dump_interval_ms:2000`；2 s 快照与“几秒一次”抖动同量级。若周期约 3 s，可改 1000 ms 以获得相位分辨率，但 trace 更大。
- `duration_ms: 90000`：只是安全上限，不是观测时长。`remote_c2.sh` 在
  producer 注册、`OBSERVE_S` 观测、停止 app 和 flush 后主动 SIGINT；90 s 让
  “服务等待 + app 启动 + 30 s 观测 + 停止/ flush”不会先撞上 duration 上限。
- **重要版本事实**：v57.1 采集端不发 `ProfilePacket.ProcessHeapSamples.start_timestamp`，v58.2 TP 上常见 `heap_profile.dur = 0`。这不等于采集失败，只意味着“精确持有区间”不可判；总量、分配/释放、dump 数仍可判。用 `v1_modify/candidate-v1.0.1/sql/10-native-dump-capability.sql` 检查，不要用 `dur=0` 否定总量结论。

### 3.3 C3：CPU 调用栈归因

完整文件：[C3-worker-cpu-profile.pbtxt](../v2_modify/configs/C3-worker-cpu-profile.pbtxt)

关键参数依据：

- `timebase { frequency: 500 }`：默认 `SW_CPU_CLOCK`，每 CPU 500 Hz，再按 `target_cmdline` 过滤；30 s 约 1.5 万样本（单线程量级），足以看热点，但不保证每个短尖峰都有样本。丢样本可降到 250 Hz。
- `callstack_sampling.scope.target_cmdline: "worker_app"`：只保留目标进程样本；同名多进程会混合，必要时改用 `target_pid`。
- `kernel_frames: false`：只看用户态代码；要看 syscall/reclaim 内核栈需 `kptr_restrict` 允许，另行评估。
- 默认使用 libunwindstack/DWARF；若 `worker_app` 用 `-fno-omit-frame-pointer -fno-optimize-sibling-calls` 编译，可加 `user_frames: UNWIND_FRAME_POINTER` 降低展开开销。
- `ring_buffer_pages: 256`：每 CPU 1 MiB perf ring；出现 `perf_cpu_lost_records` 时升到 512 或降频。
- `max_daemon_memory_kb` / `max_enqueued_footprint_kb`：限制展开队列内存，防止 profiler 自己造成内存压力；代价是可能丢样本，必须看 stats。

## 4. 主机与板端操作

> **修正版 r1 重点**：首轮稿里 `$TRACEBOX` 未定义、SSH 双引号让 `$!`/`$(cat ...)`
> 在主机侧展开。本版把板端动作收进 `v2_modify/scripts/remote_*.sh`，由板端 shell 自己解析
> 变量；主机只负责 scp/ssh/等待/拉回。以下命令仍未在本次会话上板执行。

### 4.1 变量与执行位置

| 变量 | 定义/展开位置 | 说明 |
|---|---|---|
| `BOARD` | 主机 | `ssh`/`scp` 目标，如 `root@192.168.1.10` |
| `HOST` | 主机 | 本地结果目录，如 `$PWD/output` |
| `WORK` | **板端** | `/data/perfetto-worker`；由 remote 脚本使用 |
| `TRACEBOX` | **板端** | remote_lib.sh 用 `command -v tracebox` 或 `/data/tracebox` 解析；**主机不定义** |
| `APP_DIR` | **板端** | C2 测试程序工作目录（绝对路径） |
| `APP_CMD` | **板端** | C2 测试程序/包装脚本（绝对路径，动态链接） |
| `APP_ARGS` | **板端** | C2 可选参数，单个字符串，按空白拆分 |
| `OBSERVE_S` | **板端** | C2 观测秒数，默认 30 |

规则：

- 远程命令里不要出现需要板端展开的 `$!`、`$?`、`$(...)`、`$TRACEBOX`。
- 主机变量只用于拼绝对路径，并显式作为参数/环境传给 remote 脚本。
- `remote_lib.sh` 在板端执行；它负责 `WORK`、`TRACEBOX`、PID、超时、SIGINT/flush。
- 失败即停：任何 remote 脚本非 0 退出，都不得继续“拉回并宣称成功”。

反例（首轮的错误形态，不要使用）：

```bash
# 主机侧 $! 会被立即展开；$TRACEBOX 在主机未定义
ssh "$BOARD" "cd $WORK && $TRACEBOX ... --background & echo $! > app.pid"
```

### 4.2 准备（主机 → 板端）

```bash
# 所有主机命令都从 GitHub 仓库根目录执行。
R=$(git rev-parse --show-toplevel)
cd "$R"

BOARD=root@<x5-ip>
WORK=/data/perfetto-worker
HOST=$R/output
TP=/path/to/trace_processor_shell        # 主机 v58.2
mkdir -p "$HOST"

ssh "$BOARD" "mkdir -p $WORK"
scp v2_modify/configs/*.pbtxt "$BOARD:$WORK/"
scp v2_modify/scripts/remote_lib.sh v2_modify/scripts/remote_c1.sh \
    v2_modify/scripts/remote_c2.sh v2_modify/scripts/remote_c3.sh \
    v2_modify/scripts/remote_stop.sh "$BOARD:$WORK/"
scp v1_modify/candidate-v1.0.1/scripts/survey.sh "$BOARD:$WORK/"
ssh "$BOARD" "chmod +x $WORK/remote_*.sh $WORK/survey.sh"
```

`v2_modify/scripts/host_pull.sh` 留在主机，不上板。

预检（远程只读命令用单引号，避免主机展开）：

```bash
ssh "$BOARD" "sh $WORK/survey.sh" > "$HOST/survey.txt"
ssh "$BOARD" "sh $WORK/survey.sh --events" > "$HOST/available_events.txt"
ssh "$BOARD" 'tracebox --version; command -v tracebox; uname -a; getconf PAGESIZE; nproc; free -m'
ssh "$BOARD" 'cat /proc/sys/kernel/perf_event_paranoid; cat /proc/sys/kernel/kptr_restrict'
ssh "$BOARD" 'df -h /data; mount | grep " /data "; touch /tmp/.perfetto_wtest 2>/dev/null && rm -f /tmp/.perfetto_wtest && echo /tmp-writable || echo /tmp-NOT-writable'
```

若 `tracebox` 不在 PATH，remote_lib.sh 会尝试 `/data/tracebox`；两者都不存在时脚本以 127 退出，
不要继续。

目标/符号：

```bash
ssh "$BOARD" 'for p in $(pidof worker_app 2>/dev/null); do
  echo "== pid $p"; tr "\0" " " < /proc/$p/cmdline; echo; readlink /proc/$p/exe;
  grep -E "^(VmRSS|VmHWM|Threads):" /proc/$p/status; done'
# 若板端没有 pidof：ssh "$BOARD" 'ps -eo pid,comm,args | grep "[w]orker_app"'

readelf -n /path/to/worker_app | grep -A1 'Build ID'
readelf -S /path/to/worker_app | grep -E '(symtab|debug_)'
readelf -l /path/to/worker_app | grep INTERP   # 无 PT_INTERP 则不能 LD_PRELOAD
```

事件检查：

```bash
for e in sched/sched_switch sched/sched_wakeup power/cpu_frequency power/cpu_idle \
         kmem/rss_stat vmscan/mm_vmscan_direct_reclaim_begin \
         compaction/mm_compaction_begin ftrace/print; do
  a=$(echo "$e" | tr '/' ':')
  grep -qx "$a" "$HOST/available_events.txt" && echo "OK   $e" || echo "MISS $e"
done
```

`MISS` 的事件从配置删除；`sched/sched_switch` 必须存在。

### 4.3 C1：低开销时间线

```bash
ssh "$BOARD" "WORK=$WORK sh $WORK/remote_c1.sh"
```

脚本行为：

1. `tracebox --txt -c C1... -o C1.pftrace --background`，把 PID 写入 `C1.pid`。
2. 等待 PID 退出，最长 45 s（配置 `duration_ms=30000` + 15 s 余量）。
3. 45 s 未退出则 SIGINT，等待 flush；仍不退再 SIGTERM。
4. 最后要求 `C1.pftrace` 非空；否则退出 4。
5. 成功时写 `C1.status`，退出 0。

观测期间在另一个终端执行业务复现；不要在脚本里 sleep 后直接宣称完成。

### 4.4 C2：测试实例 + heapprofd 的完整生命周期

```bash
APP_DIR=/path/to/worker_app_dir
APP_CMD=$APP_DIR/worker_app
APP_ARGS='<your args>'          # 可为空；不要包含单引号
OBSERVE_S=30

ssh "$BOARD" "WORK=$WORK OBSERVE_S=$OBSERVE_S sh $WORK/remote_c2.sh '$APP_DIR' '$APP_CMD' '$APP_ARGS'"
```

脚本按顺序执行，任何一步失败都非 0 退出：

1. `tracebox --system-sockets --txt -c C2... -o C2.pftrace --background`；
   配置 `duration_ms=90000` 只是**安全上限**，不是观测时长。
2. 轮询 `tracebox perfetto --query` 直到服务可查询（最多 10 s）。
3. 检查 `libheapprofd_glibc_preload.so` 存在；在 `APP_DIR` 下以
   `LD_PRELOAD=... PERFETTO_HEAPPROFD_BLOCKING_INIT=1` 启动 `APP_CMD`，PID 写 `app.pid`。
4. `sleep 2` 确认 app 还活着；否则打印 `app.log` 尾部并失败。
5. 轮询 `tracebox perfetto --query --long`，等待 `heapprofd` producer/data source 出现
   （最多 10 s）。不出现则停止 app/trace 并失败。出现只说明注册/连接，不等于已有样本；
   最终仍以 TP 中 `heap_profile_allocation` 非空为准。
6. `sleep OBSERVE_S` 观测多个抖动周期；期间若 tracebox 提前退出，失败。
7. `kill -TERM app`，最多等 10 s；不退再 `kill -KILL`。
8. `sleep 2` 给 heapprofd flush。
9. 回到 `WORK`，SIGINT tracebox，最多等 10 s；不退再 SIGTERM。
10. 要求 `C2.pftrace` 非空（等待最多 5 s，避免文件晚于 PID 出现）；成功写 `C2.status`。

若 `/tmp` 不可写，`--system-sockets` 可能失败；用显式 socket（tracebox 与 app 必须同一环境）：

```bash
ssh "$BOARD" "WORK=$WORK \
  PERFETTO_PRODUCER_SOCK_NAME=$WORK/traced_producer \
  PERFETTO_CONSUMER_SOCK_NAME=$WORK/traced_consumer \
  OBSERVE_S=30 sh $WORK/remote_c2.sh '$APP_DIR' '$APP_CMD' '$APP_ARGS'"
```

`remote_c2.sh` 检测到 `PERFETTO_*_SOCK_NAME` 后不再传 `--system-sockets`。

`PERFETTO_HEAPPROFD_BLOCKING_INIT=1` 可能在 preload 初始化时阻塞；若 app 2 s 内未起来，
先用同一测试实例去掉该变量做一次短 smoke，确认能启动，再把“启动期漏采”标为 UNKNOWN。

### 4.5 C3：CPU 采样

```bash
ssh "$BOARD" "WORK=$WORK sh $WORK/remote_c3.sh"
```

行为与 C1 相同：后台采集、PID、45 s 完成/超时、SIGINT flush、非空文件、`C3.status`。
C3 可对已运行进程采集，不需要重启业务。

### 4.6 停止与 flush

优先让 C1/C3 的 `duration_ms` 自然结束；C2 由 `remote_c2.sh` 在观测结束后主动停止。
手工提前停止只用本次 PID：

```bash
ssh "$BOARD" "WORK=$WORK sh $WORK/remote_stop.sh C1"
# 或 C2、C3
```

`remote_stop.sh` 读取 `$WORK/<name>.pid`，SIGINT，等待 flush，最后检查文件非空。
不要 `pkill traced` / `pkill traced_probes`，也不要杀别人的会话。

### 4.7 拉回：SCP 失败不得宣称成功

```bash
WORK=$WORK sh v2_modify/scripts/host_pull.sh "$BOARD" "$HOST" C1.pftrace C1.log C1.status
# C2 追加：C2.pftrace C2.status C2.query.txt app.log
```

`host_pull.sh` 对每个文件：

- `scp -q` 返回非 0 → 立即 `exit 1`；
- 本地文件不存在/0 字节 → `exit 1`；
- 成功打印 size 与 sha256。

拉回成功后再用主机 TP 做一次硬校验：

```bash
"$TP" query "$HOST/C1.pftrace" "SELECT * FROM trace_bounds;"
"$TP" query "$HOST/C1.pftrace" "SELECT name, value FROM stats WHERE value<>0;"
```

只有 remote 脚本退出 0 **且** `host_pull.sh` 退出 0 **且** TP 能读出一个覆盖预期时长的
`trace_bounds`，才可写“采集成功”。任一失败写“采集失败/UNKNOWN”，不得用文件存在代替。

## 5. 采集验收（先验收，后分析）

按 Skill 的四级口径，**四级不能互相替代**：

1. **Schema**：配置能被采集器对应版本的 proto 解析。本次已用 v58.2 descriptor PASS；v57.1 descriptor 未获得，标记 UNKNOWN。
2. **运行条件**：数据源/事件/权限/注入路径就绪。看 `tracebox perfetto --query --long`、`C*.log`、`C2.query.txt`、`app.log`。
3. **数据**：正确 UPID/窗口、非空样本、无影响结论的丢失。运行 `v2_modify/sql/18-data-quality.sql`、`v1_modify/candidate-v1.0.1/sql/10-native-dump-capability.sql`、`v1_modify/candidate-v1.0.1/sql/00-inventory.sql`。
4. **分析/UI**：单位、UPID、窗口、图与 SQL 一致；相关性仍不等于因果。

逐遍检查：

- **C1**：`remote_c1.sh` 退出 0；`C1.status` 存在；`host_pull.sh` 退出 0；
  `trace_bounds` 覆盖 30 s；`sched_slice`/`thread_state` 非空；目标 PID 正确；
  `ftrace_event` 有 `sched_switch`、`sched_wakeup`；`stats` 无
  `ftrace_cpu_overrun`/`traced_buf_*` 数据丢失；目标进程 CPU bucket 非空。
- **C2**：`remote_c2.sh` 退出 0；`C2.status` 存在；app 已停止；`host_pull.sh` 退出 0；
  `C2.query.txt` 中能看到 `heapprofd` producer/data source；
  `heap_profile_allocation` 中目标 UPID + `libc.malloc` 行数 >0；`heap_profile` dump 数合理；
  `stats` 无 heapprofd 错误。**`dur=0` 不是失败**，按 `v1_modify/candidate-v1.0.1/sql/10-native-dump-capability.sql` 判读。
- **C3**：`remote_c3.sh` 退出 0；`C3.status` 存在；`host_pull.sh` 退出 0；
  `perf_sample` 中目标 utid 样本 >0；`stats` 中 `perf_cpu_lost_records`/
  `perf_samples_dropped` 为 0 或可解释；`unwind_error` 比例可接受；符号解析比例可接受。

三态判定：PASS / FAIL / UNKNOWN。缺数据必须写 UNKNOWN，不能用“没看到”代替“没有发生”。

## 6. SQL

包内已有（直接复用，先填参数）：

包内已有（路径均以仓库根为起点）：

- `v1_modify/candidate-v1.0.1/sql/00-inventory.sql`：trace bounds、UPID、track、stats、native 候选解析。
- `v1_modify/candidate-v1.0.1/sql/01-rss-timeline.sql`：RSS 分类时间线（MiB）。
- `v1_modify/candidate-v1.0.1/sql/03-native-live.sql`：dump 级 live 估计。
- `v1_modify/candidate-v1.0.1/sql/04-native-callstacks.sql`：祖先调用栈累计。
- `v1_modify/candidate-v1.0.1/sql/07-kernel-events.sql`：回收/规整/CMA/OOM/rss_stat 事件标记。
- `v1_modify/candidate-v1.0.1/sql/10-native-dump-capability.sql`：v58.2 `heap_profile` 与 v57.1 降级检查。

本方案新增（未修改的 10–19、16a 仍在 `v2_modify/sql/`；本轮只改 20）：

- `v2_modify/sql/10-cpu-thread-buckets.sql`：每线程 100 ms CPU；区间与桶取交集。
- `v2_modify/sql/11-runnable-and-blocked.sql`：Running/Runnable/D；区间交集。
- `v2_modify/sql/12-native-dump-timeline.sql`：dump end 的 alloc/free bytes/count（采样估计）。
- `v2_modify/sql/13-native-callsite-hotspots.sql`：leaf callsite 分配/释放热点。
- `v2_modify/sql/14-perf-hot-functions.sql`：perf self 样本按函数聚合。
- `v2_modify/sql/15-perf-allocator-share.sql`：allocator/free 样本占比。
- `v2_modify/sql/16-perf-spike-vs-quiet.sql`：本 trace 相对窗口对比。
- `v2_modify/sql/16a-perf-window-check.sql`：窗口越界检查。
- `v2_modify/sql/17-alloc-vs-cpu.sql`：分配快照与 CPU 高/低桶交叉筛查。
- `v2_modify/sql/18-data-quality.sql`：trace bounds、stats、事件/表行数。
- `v2_modify/sql/19-cpu-frequency.sql`：cpufreq 时间线。
- **`v2_modify2/sql/20-jitter-cycles.sql`**：本轮修正版；1 秒桶也用区间交集，
  先筛高 CPU 桶再编号。

> 下文 `sql/10`、`sql/20` 等是简写；完整路径见本列表。

核心查询（完整文件见上）：

### 6.1 目标解析

```sql
-- 先运行 v1_modify/candidate-v1.0.1/sql/00-inventory.sql 的 [CANDIDATES]，
-- 把 target_name 改成 worker_app。
-- 仅当恰好一个 data_bearing=1 时采用；ambiguous=1 或 0 个候选都要停下来报“未解析”。
```

### 6.2 CPU 线程桶（区间交集）

完整实现见 `v2_modify/sql/10-cpu-thread-buckets.sql`。核心不是
`GROUP BY ts/100ms`，而是对每个 `[ts, ts+dur)` 与每个桶求正交集：

```sql
WITH RECURSIVE
params AS (SELECT 'worker_app' AS target_name),
target_threads AS (
  SELECT th.utid, th.tid, th.name AS thread_name, p.upid, p.pid
  FROM thread th JOIN process p USING(upid), params
  WHERE p.name = params.target_name OR p.name GLOB '*/' || params.target_name
),
bounds AS (SELECT start_ts, end_ts FROM trace_bounds),
buckets(bucket) AS (
  SELECT 0
  UNION ALL
  SELECT bucket + 1 FROM buckets
  WHERE bucket + 1 <
        (SELECT CAST((end_ts - start_ts + 99999999) / 100000000 AS INTEGER) FROM bounds)
)
SELECT t.utid, t.tid, t.thread_name,
       b.start_ts + bk.bucket * 100000000 AS ts_ns,
       SUM(
         MIN(s.ts + s.dur, b.start_ts + (bk.bucket + 1) * 100000000)
         - MAX(s.ts, b.start_ts + bk.bucket * 100000000)
       ) / 1000000.0 AS cpu_ms,
       COUNT(*) AS overlapping_slices
FROM sched_slice s
JOIN target_threads t USING(utid)
CROSS JOIN bounds b
JOIN buckets bk
  ON s.ts < b.start_ts + (bk.bucket + 1) * 100000000
 AND s.ts + s.dur > b.start_ts + bk.bucket * 100000000
WHERE s.dur > 0 AND s.ts < b.end_ts
GROUP BY t.utid, t.tid, t.thread_name, ts_ns, bk.bucket
ORDER BY ts_ns, cpu_ms DESC;
```

UI：`Counter Track`，Timestamp=`ts_ns`，Value=`cpu_ms`，Pivot=`thread_name`。
90 ms/120 ms 跨 100 ms 边界的正例、反例见
`v2_modify/validation/tests/bucket_overlap_test.sql` 与 `real_trace_overlap_test.sql`。

### 6.3 分配 dump 时间线

```sql
WITH params AS (SELECT -1 AS target_upid, 'libc.malloc' AS target_heap)
SELECT a.ts AS dump_end_ts,
       SUM(CASE WHEN a.size>0 THEN a.size ELSE 0 END) AS alloc_bytes,
       SUM(CASE WHEN a.size>0 THEN a.count ELSE 0 END) AS alloc_count,
       SUM(CASE WHEN a.size<0 THEN -a.size ELSE 0 END) AS free_bytes
FROM heap_profile_allocation a, params p
WHERE a.upid=p.target_upid AND a.heap_name=p.target_heap
GROUP BY a.ts ORDER BY a.ts;
```

注意：`ts` 是 **dump 结束时刻**，v57.1 常常没有窗口起点；不能把它当逐次 malloc 时间。
`alloc_count`/`free_count`/bytes 是 heapprofd 采样估计，不是精确调用次数。

### 6.4 分配热点

```sql
WITH params AS (SELECT -1 AS target_upid, 'libc.malloc' AS target_heap)
SELECT a.callsite_id, COALESCE(f.name,'<unknown>') AS frame_name,
       COALESCE(m.name,'<unknown>') AS mapping_name,
       SUM(CASE WHEN a.size>0 THEN a.size ELSE 0 END) AS alloc_bytes,
       SUM(CASE WHEN a.size>0 THEN a.count ELSE 0 END) AS alloc_count,
       SUM(CASE WHEN a.size<0 THEN -a.size ELSE 0 END) AS free_bytes
FROM heap_profile_allocation a
LEFT JOIN stack_profile_callsite c ON c.id=a.callsite_id
LEFT JOIN stack_profile_frame f ON f.id=c.frame_id
LEFT JOIN stack_profile_mapping m ON m.id=f.mapping, params p
WHERE a.upid=p.target_upid AND a.heap_name=p.target_heap
GROUP BY a.callsite_id, frame_name, mapping_name
ORDER BY alloc_bytes DESC LIMIT 50;
```

### 6.5 perf 热点与 allocator 占比

```sql
WITH params AS (SELECT 'worker_app' AS target_name),
t AS (SELECT th.utid FROM thread th JOIN process p USING(upid), params
      WHERE p.name=params.target_name OR p.name GLOB '*/'||params.target_name)
SELECT COALESCE(f.name,'<unknown>') AS frame_name,
       COALESCE(m.name,'<unknown>') AS mapping_name, COUNT(*) AS samples
FROM perf_sample ps JOIN t USING(utid)
JOIN stack_profile_callsite c ON c.id=ps.callsite_id
JOIN stack_profile_frame f ON f.id=c.frame_id
LEFT JOIN stack_profile_mapping m ON m.id=f.mapping
GROUP BY frame_name, mapping_name ORDER BY samples DESC LIMIT 50;
```

allocator 占比见 `15-perf-allocator-share.sql`；spike/quiet 对比见 `16`，
窗口必须来自**当前 C3 trace** 的相对偏移，先用 `16a` 检查，不能直接粘贴 C1 的绝对 ns。

### 6.6 分配与 CPU 的交叉筛查

`17-alloc-vs-cpu.sql` 把每个 dump 归到 1 s CPU 高/低桶，输出各 callsite 的 `spike/quiet` 分配量。它是**筛查**：dump 结束时刻 vs 1 s 桶、v57.1 无窗口起点、2 s dump 间隔都会造成错位；count/bytes 仍是采样估计。只有结合 `10/11` 的周期和 `14/16` 的 CPU 归因，才能谈关联。

### 6.7 `20` 的 1 秒桶与 episode

`v2_modify2/sql/20-jitter-cycles.sql` 使用与 10/11 相同的区间交集：

```text
overlap = min(s.ts + s.dur, bucket_end) - max(s.ts, bucket_start)
```

再按 `spike_cpu_ms` 标记桶，**先 `WHERE spike=1`，再 `ROW_NUMBER()`** 形成连续
episode。反例：

- Running slice 900–1100 ms，dur=200 ms，阈值 150 ms；
- 正确：bucket0=100 ms、bucket1=100 ms，均不 spike；
- 旧实现：bucket0=200 ms，产生假 spike。

测试见 `v2_modify2/validation/tests/jitter_bucket_intersection_test.sql`。

## 7. Perfetto UI 操作

打开 <https://ui.perfetto.dev/> → “Open trace file” 选择本地 `.pftrace`。UI 在浏览器本地解析，不需要上传；主机需能加载 UI。

1. **先验收**：左侧 `Info and stats` / `Query (SQL)`，运行 `18-data-quality.sql`；确认 `trace_bounds`、`stats`、`ftrace_event` 行数。
2. **定位进程**：搜索 `worker_app`，展开进程；核对 PID/UPID 与采集时一致。只 pin 相关轨道。
3. **线程/CPU**：
   - 展开 `Threads`，看每个线程的 `State` 轨道（Running/Runnable/Sleeping/D）。
   - 看 `CPU` 轨道：抖动时目标线程在哪些 CPU；是否被其他进程抢占。
   - 看 `CPU frequency` / `cpufreq`：排除 DVFS 下降造成的 CPU 时间上升。
4. **Add debug track**：
   - 运行 `10`，`Add debug track` → `Counter Track`：Timestamp `ts_ns`、Value `cpu_ms`、Pivot `thread_name`。
   - 运行 `11` 同样做 `runnable_ms`。
   - 运行 `12` 做 `alloc_bytes` / `alloc_count`，单位 bytes/count。
   - 运行 `20` → `Slice Track`：Timestamp `ts`、Duration `dur`；得到抖动 episode 色块。
5. **Native 火焰图**（C2）：
   - 展开进程下的 `Heap profile` / `Native heap`；点击一个 dump slice。
   - 指标切换：`Unreleased Malloc Size` 看保留，`Total Malloc Size` 看累计流量，`Total Malloc Count` 看频次，`Unreleased Malloc Count` 看小对象积累。
   - 搜索 `operator new`、`malloc`、`free`、业务模块/函数；点击宽栈看调用者。火焰图宽度是**所选指标**，不是函数耗时。
   - 用时间选择器比较“抖动窗”和“安静窗”的火焰图；注意 dump 窗口/去重限制。
6. **CPU 样本**（C3）：
   - v58.2 UI 的 StackSamples 插件会在目标进程/线程下显示 `Perf Samples` 轨道；点击样本看 details panel 的 callstack/flamegraph。
   - 选中一个抖动时间范围 → area selection → `Perf Samples Sample Flamegraph`，与安静段对比。
   - 若当前 UI 没有该轨道：用 `14/16` SQL 出表，`Add debug track` 只能做计数；或 `trace_processor convert profile --perf` 导出 pprof，再用 `Aggregate Profiles` 看聚合火焰图（失去时间轴）。
7. **统计结果**：
   - `Current selection` 看选中窗口的线程状态/切片统计；不要用“面积”替代 SQL 的 `cpu_ms`。
   - 每个结论都写：UPID、窗口、数据源、单位、采样/快照间隔、丢失/符号情况。

## 8. 如何判断与 CPU 抖动的关系

支持“分配抖动是贡献因素”的最小证据链：

1. **时间**：C1 只负责建立抖动周期/形状；在 **C2 自己的 trace** 内，分配/释放高峰要与
   同 trace 的 CPU/runnable 变化同相（多次重复，不是一次）。不要把 C1 的绝对 ns 直接
   套到 C2；两次采集没有共同时钟证据。
2. **剂量**：C2 内估计的 count/bytes 越大，同 trace 的 CPU/runnable 越高；安静窗分配率低。
   若业务延迟来自独立日志/标记，再用它做剂量关系。
3. **机制**：C3 在抖动窗的 allocator/free self 样本占比上升；或 `sched_slice` 显示目标线程
   在 allocator 路径上占用 CPU。
4. **特异性**：控制 DVFS、其他进程、采样开销后仍成立；同样分配率但无抖动，或同样抖动但
   无分配峰，都要解释。
5. **可干预性**（后续，不在本次执行）：减少临时对象/复用池后抖动下降；这是最强的因果
   证据，但需要改代码和 A/B。

不足以证明因果的证据：

- 仅“同一秒内 CPU 高、分配高”（1 s/2 s 聚合）。
- 仅一个抖动周期；或只看到 `Total Malloc` 高，没有 CPU/延迟证据。
- RSS 稳定但 `rss_stat` 有短尖峰：只说明占用变化，不说明有害。
- 没有符号/调用栈，只有“malloc 很宽”。
- 内核帧缺失时，把用户态 allocator 占比当作全部原因。
- C2/C3 是两次独立采集，不能做逐点时间对齐；只能比较模式和分布。
- profiler 开启后才出现的抖动：先怀疑观测扰动。

**采样估计与业务延迟的边界**：

- `heap_profile_allocation.count`/`size` 是采样估计；不能把“count 增加 100”写成
  “多调用了 100 次 malloc”，也不能用估计值算精确优化收益。
- heapprofd 与 `linux.perf` 都不提供业务处理延迟。业务延迟必须来自独立日志、打点、
  `trace_marker` 或同 trace 的业务时间戳；`thread_state` 的 runnable/D 只是系统级代理。
- C1/C2/C3 是独立采集；C2 与 C3 之间也不能做逐点时间对齐，除非有共同标记/时钟证据。
  跨 trace 只能比较模式、分布和重复实验，不能把两条时间轴硬拼。

判读矩阵：

| 观察 | 结论方向 |
|---|---|
| RSS 平、无 reclaim/compaction、无 D 状态；C3 热点在业务计算 | 内存不是驱动；转向算法/锁/IO |
| C2 分配峰与 C1 抖动同相；C3 allocator 占比同相上升；剂量关系成立 | 分配抖动是**候选贡献因素**，需干预验证 |
| C2 分配峰存在，但 C3 抖动窗热点不在 allocator；剂量关系不成立 | 分配活动是伴随现象，不能归因 |
| C1 有 reclaim/compaction/D 状态，C2 有大块分配/直接 mmap | 走内核内存/大块分配路径，heapprofd 可能不覆盖 |
| C1 runnable 高、CPU 频率下降、其他进程忙 | 调度/DVFS 混淆，不是分配 |
| 只有 C3 采样高、`sched_slice` 不支持、无重复 | 证据不足，UNKNOWN |

## 9. 降级方案

| 不可用/失败 | 降级 | 仍然不能回答 |
|---|---|---|
| preload 缺失/版本不匹配/静态链接/不能重启 | 只做 C1+C3；用 `15` 看 allocator 占比、`mmap/brk` syscall 计数；把“对象数/字节”标 UNKNOWN | 精确分配量/对象数 |
| `android.heapprofd` 数据源未注册 | 检查 preload 版本/`--system-sockets`/target cmdline；退回 C3 | 分配归因 |
| `perf_event_open` 被拒 | 用 `sched_slice` + `record_process_runtime` 算 CPU/等待；不做调用栈 | 函数级热点 |
| `power/cpu_frequency` 等事件不存在 | 从配置删除；用 sysfs `cpufreq` 采样或 `sys_stats.cpufreq_period_ms` 替代 | 高频 DVFS 细节 |
| `/data` 空间不足 | 缩短 duration、减小 buffer、采集后立刻拉回；或 `tracebox -o -` 通过 SSH 流式落主机 | 长时连续采集 |
| `/tmp` 也不可写，`--system-sockets` 起不来 | 显式设置 `PERFETTO_PRODUCER_SOCK_NAME`/`PERFETTO_CONSUMER_SOCK_NAME` 到 `/data`，tracebox 与 app 使用同一环境 | 跨进程 socket 自动发现 |
| 符号缺失 | `trace_processor bundle --symbol-paths <unstripped>`；至少按 mapping/地址归因 | 源码行号/内联 |
| UI 无 StackSamples | SQL 表 + `Aggregate Profiles`（pprof）或升级 UI；板端不升级 | 时间轴火焰图 |
| 已有系统 traced | 不启动第二个 autostart 抢占；复用现有服务或用独立 socket 并显式导出 producer socket | 取决于现有配置 |
| v57.1 `dur=0` | 用 `v1_modify/candidate-v1.0.1/sql/10-native-dump-capability.sql` 降级：只统计活动 dump/总量；精确持有区间标 UNKNOWN | 精确窗口 |
| v57.1 descriptor 不可得 | 用 v58.2 descriptor 只做静态语法检查；板端以实际解析/log 为准 | 版本级 schema 保证 |

## 10. 版本适用边界与本次验证

### 10.1 Perfetto v57.1 / v58.2 边界

- **采集端 v57.1**：tracebox 支持 `linux.ftrace`、`linux.process_stats`、`linux.sys_stats`、
  `linux.perf`/`traced_perf`、`--background`、`--system-sockets`；`android.heapprofd` 由
  匹配版本的 preload kChild producer 注册，不是 tracebox 内建 applet。
- **v57.1 heapprofd**：不发布 `ProfilePacket.ProcessHeapSamples.start_timestamp`；
  v58.2 TP 上 `heap_profile.dur` 常见为 0。精确持有区间 UNKNOWN；总量/分配释放/dump 数
  仍可判。TP 还会按 `(upid, window_end, heap_name)` 去重，配置的 dump 间隔不等于可见 dump 数。
- **分析端 v58.2**：本方案 SQL 使用 `sched_slice`、`thread_state`、`perf_sample`、
  `heap_profile`、`heap_profile_allocation`、`stats`、`ftrace_event` 等 v58.2 表/视图。
  若换用 v57.1 TP，`heap_profile` 可能不存在，需用 `v1_modify/candidate-v1.0.1/sql/10-native-dump-capability.sql`
  的降级语句；其他表名/列也可能不同，先跑 `00-inventory.sql`。
- **配置 schema**：本次只对 v58.2 descriptor 做静态校验；v57.1 实际解析/运行未验证。
  配置中使用的字段在 v57.1 二进制中有对应字符串，但不等于正式 schema 验证。
- **采样语义**：`heap_profile_allocation.count/size` 是估计值，v57.1/v58.2 都成立；
  不要因分析表有 `count` 就当成精确 malloc 次数。
- **UI**：v58.2 的 StackSamples/perf 火焰图可用；更旧 UI 可能没有该轨道，需退回 SQL
  或 pprof 聚合。

### 10.2 本次已验证 / 未验证

已验证（本地、静态/离线）：

- 候选版路径、commit、MANIFEST 版本与关键文件 sha256 一致；资源预检 PASS。
- 未使用部署的 v1.0.0（sha 不同）。
- C1/C2/C3 配置用本地 v58.2 源码生成的 descriptor 做 `validate_config.py` 静态校验，均 PASS；该 descriptor 与既有 `trace_config.desc` sha256 一致。
- SQL 语法在本机 v58.2 Trace Processor 上对现有 trace 执行过（只验证表/语法，不从这些 trace 得出 worker_app 结论）。
- 区间交集：合成 90/120 ms 跨 100 ms 边界样本、真实 trace 的 90–120 ms sched slice 均验证
  `sum(overlap) == dur`、`diff=0`（`v2_modify/validation/tests/`）。
- jitter episode：含安静间隔的合成反例验证旧逻辑合并、新逻辑拆成 2 段。
- 20 的 1 秒桶区间交集：900–1100 ms、dur=200 ms、阈值 150 ms 反例验证
  旧逻辑第 0 秒 200 ms 假 spike、修正后 100+100 ms 无 spike；350 ms 正例验证
  正确桶产生 spike（`v2_modify2/validation/tests/`）。
- 16/16a：合成窗口与真实 trace 偏移验证 `OK` / `OUT_OF_TRACE`。
- shell 生命周期 dry-run：mock tracebox/app 验证 C2 启动→producer→观测→停止→flush，
  C1/C3 完成条件，`remote_stop.sh` 成功/缺失 PID，`host_pull.sh` 对 scp 失败/空文件
  的非零退出。
- 仓库根执行路径 dry-run：从 clone 根目录检查 `v2_modify/configs/`、
  `v2_modify/scripts/`、`v1_modify/candidate-v1.0.1/`、`v2_modify2/sql/20...`，
  并实际跑 C1 + host_pull。
- 板端 tracebox v57.1 二进制包含 `linux.perf`、`traced_perf`、`sched_switch`、`power/cpu_frequency`、`cpufreq_period_ms`、`record_process_runtime` 等字符串；不包含 `android.heapprofd` 注册串。
- 同版本 `libheapprofd_glibc_preload.so` 包含 `v57.1-c59f57dd4`、`android.heapprofd`，并导出 malloc/free/calloc/realloc hook。
- 本机 v58.2 TP 存在并可使用 `sched_slice`、`thread_state`、`perf_sample`、`heap_profile`、`heap_profile_allocation`、`stats`、`ftrace_event`。
- v58.2 UI 源码存在 StackSamples/perf 火焰图相关插件。

未验证（明确标记）：

- 未连接 X5；未在板端执行 `tracebox`/`survey.sh`/任何采集；shell dry-run 只是 mock。
- 未验证真实 C2 `heapprofd` 注册与 flush 时序；mock 只能证明脚本控制流与失败传播。
- 未验证 v57.1 的 TraceConfig descriptor；仅 v58.2 静态校验。
- 未验证板端实际 `available_events`、perf 权限、preload 注入、heapprofd 数据源注册、C2 端到端。
- 未验证 `worker_app` 的符号、Build ID、frame pointer、启动参数。
- 未打开 Perfetto UI 查看任何本次采集结果；未生成截图/曲线。
- 未证明任何性能因果关系；所有判读都是预期规则，需真实 trace 验证。

### 10.3 首轮错误归因（规则未落实 vs 缺少实现）

详见 `v2_modify/validation/SKILL_GAP.md`。摘要：

- **Skill 规则已写、首轮未落实**：主机/目标变量与执行位置、采集验收、heapprofd 采样估计、
  业务延迟需独立证据。
- **Skill 有原则但缺可复用实现**：远程 runner/变量作用域、C2 生命周期状态机、C1/C3
  完成与 pull 失败传播、区间交集 SQL、jitter episode SQL、跨 trace 窗口检查。
- **首轮 SQL/实现缺陷**：`10/11` 整段计入起始桶、`20` 先编号后筛、`16` 跨 trace 绝对时间戳。
  其中 `10/11/20` 也说明 Skill 没有对应的可复用 SQL。

本修正版补了 `v2_modify/scripts/`、`16a` 和测试，但**没有修改或部署 Skill**；这些补丁不能算作
Skill 已具备的能力。

## 11. 建议的最小下一步

1. 跑 4.1 预检，拿到 `survey.txt`、`available_events.txt`、`worker_app` 的 PID/命令行/构建信息。
2. 只跑 C1（30 s），用 `00/01/10/11/18/20`（完整路径见第 6 节）确认：
   抖动是否真实、周期多少、是否有 reclaim/compaction/DVFS 混淆。
3. 若 C1 指向用户态 CPU 且无内存压力，跑 C3（30 s），用 `14/15/16` 找热点函数与 allocator 占比。
4. 若 C3 显示 allocator 占比在抖动窗上升，再跑 C2（测试实例 + preload，
   `OBSERVE_S=30`；配置 90 s 只是安全上限），用 `10/12/13/17` 归因到 callsite。
5. 只有 C2+C3+C1 的证据链成立，才讨论“临时对象复用/池化”的修改；修改后用同一套配置做 A/B，才算因果闭环。
