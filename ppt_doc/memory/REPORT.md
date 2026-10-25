# pf-mem-case 内存排查报告（RDK X5 / Perfetto）

- 目标：`/userdata/perfetto-skill-lab/memory/pf-mem-case`（X5，Linux 6.1.83 aarch64，glibc 2.35）
- 采集器：`tracebox v57.1-c59f57dd4`（aarch64 Linux 预编译）
- 分析器：`trace_processor_shell v57.1`（x86_64 主机）
- 结论状态：**已定位到调用点（函数级）**，并由**两条独立链路互证**：① `android.heapprofd`（`traced` 内置 producer + `libheapprofd_glibc_preload.so`，本次已端到端跑通）；② 自写 malloc 拦截器 + aarch64 `x29` 帧指针链。两者给出的三条业务链**完全一致**。

> 更正记录（2026-10，本节保留错误轨迹）：本报告早期版本曾断言“本机 heapprofd 服务端不可用”，**该结论是错的**。错误来自两点：① 用 `tracebox` applet 列表与“没有 `heapprofd` 二进制”推断能力，而 v57.1 的 **`traced` 已内置 `HeapprofdProducer`**（`src/traced/service/builtin_producer.cc`，数据源名 `android.heapprofd`），不需要独立守护进程；② 我漏用了 skill 文档 §3.2 明确要求的 **`--system-sockets`**，导致 preload 连不上服务、目标卡在 `BLOCKING_INIT`（现象：`approfd_producer.cc:257 Disconnected from tracing service`）。补上 `--system-sockets` 后一次通过。另：v57.1 的 `trace_processor_shell` **有** `heap_profile_allocation` 视图（本次实测 11 行），只是没有 dump 级 `heap_profile` 表。

---

## 1. 结论（先说结果）

`pf-mem-case` 的 RSS 从启动阶梯式爬升到 **≈46 MiB**，**在 t≈136 s 停止增长**，之后**长期稳定不再增长**
（干净运行实测：t=+136 s 进入平台期，随后 282 s 内 84 个采样点恒定 47216 KiB；另一次运行平台期 ≥ 5 min）。
136 s ≈ 28 项 × 5 s，正好等于最慢的那个累积点（`DeferredStore` 的 1 MiB 记录）填满的时间，这是“有容量上限”最直接的证据。
爬升由三个**容量有上限**的累积点造成，全部经 `memcase::heap::Acquire()` → `malloc()` + `memset('Z')` 立即触页：

| 调用点 | 单次大小 | 触发节奏 | 容量上限 | 稳态占用 |
|---|---|---|---|---|
| `memcase::ObjectCache::AddEntry()` | 64 KiB | 500 ms（2 次/s） | 128 项 | 8 MiB |
| `memcase::DeferredStore::Attach()` | 1 MiB | 5 s（1 次/5 s） | 28 项 | 28 MiB |
| `memcase::FrameSpool::RunPass()` | 8 MiB | 12 s（3 s 后 `Drain()` 释放） | 1 次瞬态 | 8 MiB（glibc arena 保留） |

账面核对：`8 MiB（缓存） + 28 MiB（延迟记录） + 8 MiB（spool arena 保留） + 约 2 MiB（进程自身/库） ≈ 46 MiB`，与实测 46.1 MiB 吻合。

判读：

1. **不是无界泄漏**：128×64 KiB=8 MiB 与 28×1 MiB=28 MiB 都是代码里的硬上限（`ObjectCache(0x80, 0x10000)`、`DeferredStore(0x1c, 0x100000)`），到顶后不再分配。实测 168 s 运行里 64 KiB 恰好 128 次、1 MiB 恰好 28 次、8 MiB 每 12 s 一次，之后停止。
2. **但运行期没有任何释放路径**：`DeferredStore::ReleaseAll()` 只被析构函数调用；`DeadlineArbiter::Sweep()` 的实现只是 `DeferredStore::Attach()`（只挂载、不回收）。因此这 28 MiB 在进程退出前一直驻留（退出时一次性释放，实测 dump 到 21 MiB 全部 free）。
3. “内存占用异常”的观感来自**前 ~140 s 的持续爬升**（≈0.32 MiB/s，其中 0.12 MiB/s 来自缓存、0.2 MiB/s 来自 5 s 一次的 1 MiB 记录），以及 **RSS 到达 46 MiB 后不回落**（`madvise`/`munmap`/`free` 到 OS 都没有：实测运行期无 `mmap/brk/madvise/munmap`，只有 glibc arena 的 `mprotect` 扩容）。
4. 另一处需要业务确认的**功能性风险**（非内存泄漏）：`DeferredStore` 达到 28 项后 `Attach()` 返回 0，即静默丢弃新记录、不打印任何日志。

### 1.1 证据等级与工具边界（重要）

| 结论 | 证据等级 | 来源 |
|---|---|---|
| RSS 阶梯上升、平台期恒定 46.1 MiB | **观测** | Perfetto `kmem/rss_stat` + `process_stats`（`mem.rss.anon`） |
| 增长期间无新 `mmap/munmap/brk`，只有 `mprotect` | **观测**（有 per-CPU buffer 覆盖风险） | `linux.ftrace` `syscall_events` |
| 8/28/128 次、64 KiB/1 MiB/8 MiB、0.5 s/5 s/12 s 节奏 | **观测** | 拦截器（`CLOCK_BOOTTIME`，与 trace 同钟） |
| `Acquire ← ObjectCache::AddEntry ← Store ← CacheChannel::WarmStep ← Run`<br>`Acquire ← DeferredStore::Attach ← DeadlineArbiter::Sweep ← SessionChannel::ExpireWindow ← Run`<br>`Acquire ← FrameSpool::RunPass ← SpoolChannel::Run` | **观测**（帧指针链 + `addr2line` 符号） | 拦截器 FP-walk，每种大小**只有一条调用链，零歧义** |
| 128/28/8 MiB 是代码硬上限 | **观测（行为）+ 静态确认** | 运行停止点 + 反汇编常量 `ObjectCache(0x80,0x10000)`、`DeferredStore(0x1c,0x100000)`、`FrameSpool(0x800000)` |
| heapprofd 可在本板做函数级归因 | **观测（已端到端跑通，并与 FP-walk 互证）** | `android.heapprofd` + `--system-sockets` + `libheapprofd_glibc_preload.so`（BuildID `b0ea68ab44155f67`）；11 行 `heap_profile_allocation`、5.70 MiB 采样量、三条业务链完整解析 |
| `linux.perf` 用户态调用栈 | **不可用**（与 heapprofd 无关） | 1972 个样本，用户栈 0 帧（只到 kernel/loader 帧）；因此 heapprofd 是本次函数级的正确路线 |

> 结论：本环境下 **heapprofd 路线可用且已验证**，函数级归因不依赖猜测。使用约束（对任何采集方都成立）：
> ① 目标必须由 `LD_PRELOAD=libheapprofd_glibc_preload.so` + `PERFETTO_HEAPPROFD_BLOCKING_INIT=1` 启动；
> ② 采集端必须加 **`--system-sockets`**（standalone Linux 下 preload 通过系统 socket 找服务）；
> ③ **同一时刻只允许一个 tracebox/`system-sockets` tracing 实例**，并发会争用 socket（表现为目标卡在 blocking init、trace 无数据），必要时先清 `/tmp/perfetto-*`。

---

## 2. 定位路线

| 项 | 内容 |
|---|---|
| 问题 | 运行一段时间后内存占用异常 |
| 待验证假设 | ① 缓慢无界泄漏 ② 周期性分配未配对释放 ③ 缓存/池预热到上限后稳定 ④ 映射（mmap/shmem）增长 |
| 数据源 | `linux.ftrace`：`kmem/rss_stat`（RSS 事件级变化）、`syscall_events`（mmap/munmap/brk/madvise/mprotect）；`linux.process_stats`（每进程 RSS 分类）；`linux.sys_stats`（系统内存）；`linux.perf`（mmap syscall 调用栈，用于启动阶段） |
| 不覆盖 | 自定义 allocator 内部对象（本程序 `memcase::heap` 只是 `malloc+memset`，因此 `malloc` 层可见）；ART/Java（本机无）；CMA/dma-buf（与本程序无关） |

`heapprofd` 说明：v57.1 的 `tracebox` **没有独立 `heapprofd` applet/二进制**，但它的 `traced` 内置了 `HeapprofdProducer`，对外提供数据源 **`android.heapprofd`**（源码：`src/traced/service/builtin_producer.cc` + `src/profiling/memory/heapprofd_producer.cc`），因此**不需要单独守护进程**。关键调用姿势与 Android 不同的一点是必须加 **`--system-sockets`**，否则 preload 连不上服务（现象见 §1 更正记录）。`linux.perf` 的用户态回溯在本机构建上不可用（样本有、用户栈恒 0 帧），所以函数级归因走 heapprofd；自写拦截器（`malloc_log.c`，同 `CLOCK_BOOTTIME`）作为**第二条独立链路**做交叉验证。

---

## 3. 采集与验收

### 3.1 增长阶段 trace（60 s）

```bash
# 【目标机】/userdata/pfwork/overview60.pbtxt：process_stats(1s) + sys_stats(1s) + kmem/rss_stat
tracebox --txt -c overview60.pbtxt -o overview60.pftrace
```

验收（`trace_processor_shell query`）：

- 目标进程：`upid=184, pid=3449, ./pf-mem-case`
- trace 边界：`3496936284042 … 3556416782695` ns（≈59.5 s）
- `rss_stat` 事件 5641 条；`stats` 无 buffer overrun 记录（`traced_buf_bytes_read` 正常）
- 逐进程 RSS：`mem.rss.anon/file/shmem` 轨道齐全（见 4.1）

### 3.2 归因采集 A：heapprofd（主路线）

```bash
# 【目标机】同一时刻只跑这一个 tracing 实例
tracebox --system-sockets --background-wait --txt \
  -c /userdata/pfwork/heapprofd.pbtxt -o /userdata/pfwork/heapprofd.pftrace
LD_PRELOAD=/userdata/perfetto-skill-lab/memory/libheapprofd_glibc_preload.so \
  PERFETTO_HEAPPROFD_BLOCKING_INIT=1 ./pf-mem-case
# 20 s 后正常结束采集并 kill -TERM 目标
```

配置要点（`heapprofd.pbtxt`）：`android.heapprofd` + `process_cmdline: "pf-mem-case"` + `sampling_interval_bytes: 4096` + `shmem_size_bytes: 8388608` + `all_heaps: true` + `continuous_dump_config { dump_phase_ms: 5000 dump_interval_ms: 5000 }`；另加 `linux.process_stats` 提供 UPID。

验收（本次实测）：

| 项 | 值 |
|---|---|
| 会话 | `tracebox rc=0`；目标日志 `Connected to the service, mode [child]` + `Setting up datasource: non-statsd initiator` |
| preload 注入 | `/proc/<pid>/maps` 命中 7 段 `libheapprofd_glibc_preload.so` |
| 目标 | `pid=1547`，20 s 内正常退出（`SIGTERM`） |
| heap 数据 | 11 行 `heap_profile_allocation`，合计 5,709,824 B 采样量，`upid=191 / pid=1547` |
| 路径归因 | 8 MiB×1（spool）、1 MiB×3（session）、64 KiB 聚合行 640 KiB×3 + 576 KiB×1（cache）——与构造一致 |
| 符号化 | 三条业务链均解析到函数名（mangled），含 `heap::Acquire ← … ← *Channel::Run` |

### 3.2b 归因采集 B：拦截器 + 长窗口 trace（交叉验证）

```bash
# 【目标机】PFLOG 与 trace 同时开始，进程退出时 atexit 落盘
tracebox --background-wait --txt -c growth2.pbtxt -o growth2.pftrace
PFLOG=/userdata/pfwork/malloc.log LD_PRELOAD=/userdata/pfwork/malloc_log.so ./pf-mem-case
kill -TERM <pid>          # 程序优雅退出 → 拦截器 atexit dump + 析构释放记录
```

验收：

- `malloc.log`：`ready 1 head 149…`，146 条 alloc/free 记录，`exe_base 0`（ET_EXEC）
- 每记录含 `ts(CLOCK_BOOTTIME ns) / kind / addr / size / depth / P0(调用点)` + 回溯帧
- 165 s 运行统计：`65536×256`（128 次分配 + 128 次释放）、`1048576×56`（28+28）、`8388608×28`（14+14）
- 调用点 `P0=0x4037FC` = `memcase::heap::Acquire()` 中 `bl malloc@plt` 的返回地址（全部记录一致）

> 两条自动回溯都断在同一处：`bl malloc@plt` 的返回地址落在无 `.eh_frame` 的 PLT 桩上，
> `_Unwind_Backtrace` 只回溯到 libgcc/自写 .so 帧，`__builtin_return_address(1/2)` 返回 0。
> 最终改用 **`x29` 帧指针链手工回溯**（exe 内各函数均保留帧指针）拿到完整业务链（见 4.3），
> 每条链与分配大小一一对应，无歧义。

---

## 4. 证据链

### 4.1 RSS 阶梯：每 5 s 一簇、每簇约 1 MiB

`sql/01-rss-timeline.sql`（本 trace 改写为 `memory_rss_and_swap_per_process`）：

```
ts(相对)  anon(MiB)
 0.000    37.05      ← trace 开始时已在爬升
 3.701    37.05      轮询点（1 s）
 4.701    37.05
 5.579    37.31  ┐
 5.580    37.57  │ 4 个 rss_stat 事件，间隔约 1 ms
 5.581    37.83  │ 每步 +0.26 MiB
 5.582    38.09  ┘
 6.700    38.09
 ...
```

- 形态：**平台期 + 每 5 s 一簇 4 连升**，每簇 +1.04 MiB，即约 **0.2 MiB/s**
- 分类：`file_rss`、`shmem_rss` 全程不变（2.09 MiB / 0），增长全部在 **anon**
- 系统侧 `MemTotal 1304 MiB`、`MemAvailable` 仅轻微下降，无回收/压力事件 → 不涉及 OOM/LMK

### 4.2 增长期间没有新的映射：只有 glibc arena 的 `mprotect`

`growth2.pftrace`（88 s，覆盖启动到平台期）：

- `sys_enter`：`mprotect` 1004 次（id=226），**无 `mmap/munmap/brk/madvise`**
  （注意：8 个 per-CPU ftrace buffer 可能覆盖最早期事件；但“只有 mprotect、没有新 mmap”与 4.1 的 `VmSize` 恒定、smaps 的 arena 形态三点互证）
- `VmSize` 全程恒为 229528 KiB（无 preload 时）→ 虚拟地址空间在启动时就已预留，之后只是“已映射区的页被逐个访问”

`/proc/<pid>/smaps`（平台期快照）：

```
      Rss      Size     
   25608 kB  25608 kB  rw-p  ffff98000000-ffff99902000     ← glibc arena 1（28×1 MiB 记录主要落在这里）
   8200 kB   8200 kB  rw-p  ffffa0000000-ffffa0802000      ← arena 2（ObjectCache 8 MiB）
   8196 kB   8196 kB  rw-p  ffff9c000000-ffff9c801000      ← arena 3（FrameSpool 8 MiB 瞬态后保留）
   2056 kB   2056 kB  rw-p  ffffa64de000-ffffa66e0000
   ...
   57340 kB     0 kB  ---p  ffff9c801000-ffffa0000000      ← 未提交的 arena 保留（PROT_NONE）
```

每个 arena 是 64 MiB 的 `HEAP_MAX_SIZE` 预留 + 已提交前缀，符合 glibc 非主 arena 的 `mprotect` 扩容形态。

### 4.3 分配归因：三个调用点、两种节奏、三个上限

拦截器记录（`tmp/pf-mem-case/malloc.log`，65 s 片段）：

```
t(s)  alloc(MiB) free(MiB)  net_live(MiB)
  0       0.13     0.00      0.13
  1       0.12     0.00      0.26      ← 每 0.5 s 一块 64 KiB
  5       1.12     0.00      1.76      ← 1 MiB（5 s 周期）
 12       8.12     0.00     11.63      ← 8 MiB（12 s 周期）
 15       1.12     8.00      5.01      ← 8 MiB 在 3 s 后被 Drain 释放
 ...
 65       1.00     0.00     21.07
 68       0.00    21.00      0.07      ← SIGTERM：析构一次性释放
```

168 s 运行的分配次数（含配对释放）：`65536×256`、`1048576×56`、`8388608×28`
→ 即 **128 次 64 KiB、28 次 1 MiB、14 次 8 MiB**。

**调用链是实测的，不是推断的**（`x29` 帧指针链 + `addr2line`，`malloc6.log`，每种大小只有 1 条链）：

```
8388608 B x14 : heap::Acquire <- FrameSpool::RunPass <- SpoolChannel::Run <- thread
1048576 B x28 : heap::Acquire <- DeferredStore::Attach <- DeadlineArbiter::Sweep
                              <- SessionChannel::ExpireWindow <- SessionChannel::Run <- thread
  65536 B x128: heap::Acquire <- ObjectCache::AddEntry <- ObjectCache::Store
                              <- CacheChannel::WarmStep <- CacheChannel::Run <- thread
```

**heapprofd 独立复现同一组链**（`heapprofd.pftrace`，20 s，`upid=191`）：

```
heap::Acquire <- ObjectCache::AddEntry <- ObjectCache::Store <- CacheChannel::WarmStep
              <- CacheChannel::Run <- thread_entry          (64 KiB 聚合行 640 KiB x3 + 576 KiB)
heap::Acquire <- DeferredStore::Attach <- DeadlineArbiter::Sweep <- SessionChannel::ExpireWindow
              <- SessionChannel::Run <- thread_entry        (1 MiB x3)
heap::Acquire <- FrameSpool::RunPass <- SpoolChannel::Run <- thread_entry   (8 MiB x1)
```

两条链路（heapprofd / 自写拦截器 x29 链）给出的业务调用链**逐帧一致**，这是本次函数级归因可信的直接依据。

三者再与下面的容量常量互证：

| 依据（二进制静态事实） | 运行期事实 |
|---|---|
| `CacheChannel::CacheChannel()`：`ObjectCache(0x80, 0x10000)` = cap 128、entry 64 KiB | 64 KiB 恰好 128 次后停止（128×64 KiB = 8 MiB） |
| `SessionChannel::SessionChannel()`：`DeferredStore(0x1c, 0x100000)` = cap 28、payload 1 MiB；`Run()` 每 5 s 调 `ExpireWindow()` → `DeadlineArbiter::Sweep()` → `DeferredStore::Attach()` | 1 MiB 每 5 s 一次，恰好 28 次后停止（28 MiB） |
| `SpoolChannel::SpoolChannel()`：`FrameSpool(0x800000)`；`Run()` 每 12 s `RunPass()`（8 MiB），3 s 后 `Drain()` | 8 MiB 每 12 s 一次，每次 3 s 后释放；168 s 内 14 次 |

`heap::Acquire(size)` 的实现是 `malloc(size)` 后立刻 `memset(ptr, 0x5a, size)`：

```
4037f8:  bl  malloc@plt
403804:  mov x2, x19        ; size
403808:  mov w1, #0x5a      ; 'Z'
40380c:  bl  memset@plt
```

所以 **RSS 增长 = 分配字节数**（不存在“只 malloc 不触页”的延迟），这也是 `rss_stat` 一簇 4 个事件就吃掉 1 MiB 的原因。

### 4.4 平台期：到上限后完全静止

干净运行（无 preload）的 `/proc` 5 s 采样曲线见 `rss_curve.svg`：爬升 136 s → 平台期 282 s（数值恒定）。

平台期单独采了 60 s trace（`plateau60.pftrace`），按 upid 聚合：

```
upid  min_mib  max_mib  span_kib  samples
 185   46.109   46.109     0.000       61     ← 60 s 内 RSS 方差为 0
```

- 干净运行（无 preload）稳定在 **47192–47216 KiB**（三次独立运行一致：47192 / 47216 / 47216）
- 平台期实测：run#1 ≥ 5 min（58 个采样点不变）、run#3 282 s（84 个采样点不变，且仍在持续）
- 平台期 `mprotect` 停止（增长窗口内 1004 次，平台期 0 次），无 `mmap/munmap/madvise`

---

## 5. 结论与判读口径

- **能说的**：增长到 46 MiB 是三个有上限的累积点造成的，函数级可定位；到顶后不再增长；运行期无内存归还路径（`free` 只发生在进程退出）。
- **不能说的**：不能把这条曲线叫“泄漏”；也不能说“free 了内存就一定还给了系统”——`FrameSpool::Drain()` 的 `free()` 之后，glibc 把 8 MiB 留在 arena 里（无 `madvis`e/`munmap` 归还），所以 RSS 不降。
- **与业务的相关性**：`DeferredStore` 第 29 次 `Attach()` 起返回失败（静默丢弃），如果业务依赖“记录不丢”，这是比 RSS 更值得先确认的问题。

## 6. 下一步（按价值排序）

1. 长跑 30 min 复核（当前已观测约 10 min 平台期、零波动；采样脚本 `/userdata/pfwork/rssmon.sh` 每 5 s 记录）。若长跑出现二次爬升，说明还有第四个累积点，需要重新开 trace。
2. 若业务期望“deadline 到期即释放”，检查 `DeadlineArbiter` 的实现：目前 `Sweep()` 只 `Attach()`，没有任何 `Release/ReleaseAll` 调用点；`ReleaseAll()` 仅在 `~DeferredStore()` 中出现。
3. 若 46 MiB 的稳态不可接受：给 `ObjectCache`/`DeferredStore` 增加运行期回收（按 deadline 出队并 `heap::Release`），或把 cap 按设备内存预算调小（1 MiB × 28 是主要项）。
4. 释放后如需真正归还 OS：对 `FrameSpool` 的 8 MiB 用 `madvise(MADV_DONTNEED)`/`malloc_trim`，否则 arena 会保留。

## 7. Perfetto UI 复看配方

1. 打开 `tmp/pf-mem-case/overview60.pftrace`；搜索 `pf-mem-case`。
2. 展开 `Memory > RSS Anon`（进程计数器）+ `System > MemAvailable`；选区 0–60 s。
3. Query 里执行 `sql/01-rss-timeline.sql`（把 `-1` 换成 `upid 184`），结果用 Add debug track：Counter Track / ts / value / pivot=series。
4. 打开 `growth2.pftrace`：`ftrace sys_enter` 轨道按 `id=226 (mprotect)` 过滤，确认增长窗口内只有 arena 扩容。
5. 对齐手段：拦截器记录与 trace 同为 `CLOCK_BOOTTIME`，可直接按时间戳比对（板卡 wall clock 不可信，见附录）。

## 附录：环境异常记录（与本次结论无关，但影响跨次对齐）

- 板卡 wall clock 为 `1970-01-01`；`CLOCK_BOOTTIME` 与 `/proc/uptime` 不一致，且跨采集会话发生大幅跳变（4.37e6 s → 4.77e6 s）。**同一次采集内**（trace + 拦截器）时钟一致，跨次请勿直接比较绝对时间戳。
- `stats_data_source` 报告 `/proc/pressure/*`、`/proc/slabinfo` 缺失；`synthetic:rss_stat_throttled` trigger 设置失败（内核不支持），不影响 rss_stat 原始事件。
- `/userdata` 为真实块设备（27 GB 可用），trace 文件不占 RAM。
