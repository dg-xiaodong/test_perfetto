# 占用、尖峰、mmap 与内核压力

依据：[S02/S03](sources.md)、[S19–S21](sources.md)、[S23/S26](sources.md)。X5 CMA 联合排障为工程扩展，不宣称官方提供 X5 专用分析器。

## 1. 先分清统计对象

| 指标 | 读法 | 不要推出 |
|---|---|---|
| RSS anon/file/shmem | 进程驻留页面的分类 | malloc 请求字节数；共享页独占量 |
| PSS / private dirty | smaps/dumpsys 中的共享分摊或私有脏页口径 | PSS = RSS；普通 process_stats 默认就有精确 PSS |
| VmHWM | 进程历史 RSS 高水位 | 峰值发生时刻或分配调用栈 |
| MemAvailable | 内核估算无需换出即可供新负载使用的量 | 无条件可满足任意高阶连续分配 |
| CmaFree | CMA 区域当前空闲页面量 | CMA 只服务相机、普通可迁移页绝不会使用 CMA |
| vmstat | 累计事件数或页面数，按字段分别解释 | 全部都能直接转成 MiB |

`/proc/*/status` 中的 kB 通常按 1024 字节换算；Perfetto 的 RSS 标准库输出是 bytes。KiB=1024 bytes，MiB=1048576 bytes。`nr_free_pages` 要乘**实际 page size**，不是把页数当 MiB。

### baseline 生成

```bash
python3 scripts/make_config.py overview --platform linux --duration-ms 30000 > memory.pbtxt
```

包含 `linux.process_stats` 和 `linux.sys_stats`。默认每 1000ms 轮询；采集全部进程的基础元数据后，分析按目标 UPID 过滤。只对确有必要的字段提高频率；stat/sys polling 周期关系遵循版本 proto。CMA 或某些 vmstat 字段在内核不存在时可能没有点，不能把缺失当零。

默认没有 ftrace：适合不需要内核事件的第一轮占用分析。要 PSS 或映射归属，再采 smaps/smaps_rollup 或 Android dumpsys；这些快照与 trace 的时钟需要明确对应。

## 2. 短时 RSS 尖峰

```bash
# 在目标机运行并把输出带回主机
sh survey.sh --events > available_events.txt
# 在主机生成
python3 scripts/make_config.py rss-spike --platform linux \
  --events available_events.txt --duration-ms 10000 > spike.pbtxt
```

增加 `linux.ftrace` 的 `kmem/rss_stat`，保留 process metadata。不要把毫秒级事件间隔说成“保证 1ms 分辨率”。事件在内核 RSS 记账路径产生，可能有批处理、记录丢失及地址空间关联问题。

分析优先使用 Trace Processor 解析后的进程 RSS 轨道与 `linux.memory.process`；确需读原始事件，再检查本机 `events/kmem/rss_stat/format`。

- `size`：该 member 的绝对记账字节数；同一地址空间/类别取观测最大值，**不能 sum(size)**。
- 常见 member：0=file、1=anon、2=swap、3=shmem；以对应内核的定义和解析器为准。swap 不加入 RSS。
- `curr`：当前任务和被更新地址空间是否相同的关联信息，不是内存量。
- `mm_id`：地址空间关联键；不能无条件把事件发出线程 PID 当成内存所属进程，尤其 curr=0。进程重启/PID 复用要按 UPID 区分。
- 总 RSS 要将同一时刻的分类值对齐后相加；`max(anon)+max(file)+max(shmem)` 可能拼出一个从未出现过的峰值。

轮询与事件可能被解析成同名/合并的 counter 轨道。先查看 track ID 和实际输入；不能承诺同一 trace 天然有“独立轮询曲线”和“独立事件曲线”。需要严格证明轮询盲区时做两种配置的可重复对照，或另行明确标记轮询样本来源。

### 可控测试

使用 `examples/memprobe.c` 的 `spike` 模式：malloc→逐页写入→短时保持→free。不要用向 tmpfs 写文件来模拟进程 anon 增长；也不要只 malloc 而不触页。150ms 保持不保证每次都落在 1s 轮询点之间，循环时记录真实单调时钟并检查相位；触页本身也耗时。

## 3. 从“涨了”到“为什么卡”

```bash
python3 scripts/make_config.py kernel-pressure --platform linux \
  --events available_events.txt --sched --duration-ms 10000 > pressure.pbtxt
```

生成器只选目标确有的 cma、oom、直接回收、部分 compaction 事件；sched_switch 是显式额外开销。没有所需事件时退回 counters+日志/快照，不伪造事件名。其他 vmstat、PSI、buddyinfo 只有经该版本 proto 与内核确认才扩展。

需要构成的证据链：同一业务窗口的内存行为 → 特定分配/回收/规整操作 → 相关线程的等待或执行代价 → 帧完成时间/延迟。sched_switch 只能说明调度状态的一部分，不能独自说明所有等待原因。内存富余时出现短尖峰也可能完全无害；无 reclaim 也不排除高阶分配失败或外部 buffer 问题。

应用侧可增加经过授权的帧号/阶段标记，或使用已有日志。没有厂商 tracepoint 不等于没法记录应用标记；但自定义标记属于额外集成，不能说已有现成厂商轨道。

### CMA / ION / dma-buf

先保存实际 `cma` 事件 format。start/finish 配对要考虑地址区、进程/线程、并发与事件字段；不要在并发 trace 中简单把相邻 start 和 finish 凑成一次分配。count、pfn、ret 等字段是否存在与单位都依据目标格式。

`busy_retry` 是排查线索，不单独证明最终失败或掉帧。检查总耗时、最终结果和业务帧时间。ION client/dma-buf debugfs 快照可以补充对象归属，不能自动变成 malloc 调用栈；映射的设备页面也不保证以普通 RSS 方式记账。对多个进程共享同一 dma-buf，应按对象身份去重。

## 4. mmap / munmap / madvise

先用 smaps 判断是否为直接映射路径。malloc 分配器内部用 mmap 取得 backing memory，不意味着这一笔 malloc 对 heapprofd 不可见；绕过被 hook 分配 API 的直接 mmap 才是不同观测路线。

```bash
python3 scripts/make_config.py mmap --platform linux --process memprobe \
  --arch aarch64 --events available_events.txt --perf-confirmed > mmap.pbtxt
```

`--perf-confirmed` 不是开启权限的开关，而是表示**已实际验证 linux.perf producer 和 tracepoint perf 采样可用**。Linux perf_event_paranoid=2 不能简单解读为“tracepoint perf 加 kernel_frames:false 就必定可用”。不自动修改它。

模板组合：ftrace syscall_events 的 mmap/munmap/madvise + 对 `raw_syscalls:sys_enter` 的 mmap perf 调用栈采样。AArch64 mmap ID=222，x86_64=9；其他架构不能套用。参数采集/调用栈支持各有条件：本模板在 Android 上要求 API34（14）满足完整参数路线；更早系统可提供降级的调用栈观察，但必须明确缺少参数。

只采 mmap 入口调用栈不会自动说明申请成功。应核对返回值、映射标志、长度、重映射、部分 munmap、madvise 等；`mmap(length)` 是虚拟映射请求，不是新增 RSS。不同线程可能同时调用；用正确 syscall enter/exit 配对和 TID，不用相邻行猜。

## 5. Android LMK、Linux OOM、Java OOME

`android-lmk` 加入可用的 legacy lowmemorykiller 事件、`oom/oom_score_adj_update` 与 `atrace_apps:"lmkd"`。现代 lmkd 数据需要设备真的启用并产出对应 atrace；仅配置这一行不保证有内容。

UI 的 lmkd counter 值可能是**受害者 PID**，不是释放内存字节。按事件时间解析该 PID 对应的进程实例，查看其此前 RSS/anon+swap/oom_score_adj 与系统压力。oom_score_adj 是可被杀优先级相关信息，不是 OOM 已发生的证明。不要把历史 Android 的固定 adj 分类表当成所有产品当前策略。

Linux `oom:*` 是另一条路线，结合内核日志与受害者；ART `OutOfMemoryError` 用 Managed 章节的触发式 dump。三者不要混成一类故障。

厂商 `mm_event/mm_event_record` 仅在设备实际支持时显式加入 ftrace，可出现 fault、swap、IO、compaction、reclaim 的 count/avg_lat/max_lat 轨道。缺少它不表示缺少所有内存事件，也不应为了它默认要求改内核。
