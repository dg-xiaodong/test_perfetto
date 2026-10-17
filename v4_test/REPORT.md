# RDK X5 `/data/rdk_mem_case.sh` 内存行为定位报告（Perfetto 实测）

- **板卡**：RDK X5 EVB，`192.168.1.10`，`6.1.83-DR-PL5.1_V1.0.20` aarch64，8 核，`MemTotal 1336028 kB`，**SwapTotal = 0**
- **被测脚本**：`/data/rdk_mem_case.sh`，235 B，md5 `2d70ea97dfe637757f23638063503047`（本次实跑前核对，日志中记录）
- **采集**：板载 `tracebox` v57.1-c59f57dd4 → `.pftrace`；主机 `trace_processor_shell` v57.1（同一 build）分析
- **数据源**：`linux.sys_stats`（meminfo 250 ms）+ `linux.process_stats`（250 ms）+ `linux.ftrace`（`kmem/rss_stat`）
- **结论时间**：本报告所有数字均来自本次 trace，不引用历史报告或推断
- **本目录结构**：原始 trace 在 `traces/`，配置 `configs/`，SQL 与输出 `sql/`、`sql_out/`，日志 `logs/`，图表 `charts/`；总览见 [README.md](README.md)

---

## 0. 结论：**不是内存泄漏**

`/data` 是 **tmpfs（RAM 支持的内存文件系统）**。脚本用 `dd` 写入 **24 MiB（25165824 B）** 文件，这 24 MiB 直接变成**物理内存中的 shmem 页**；脚本 `rm` 后立即释放。整个过程：

| 事件 | MemAvailable | Shmem | Cached | 进程 anon RSS | Slab |
|---|---|---|---|---|---|
| dd 前 | 1086.6 MiB | 0.3 MiB | 51.4 MiB | 12.9 MiB | 81.7 MiB |
| 24 MiB 文件驻留期间 | **1062.6（−24.0）** | **24.3（+24.0）** | **75.4（+24.0）** | 12.9（**不变**） | 81.7（不变） |
| rm 之后 | 1086.5（回到基线） | 0.4 | 51.5 | 13.0 | 81.7 |

- **下降量 = 文件大小 = 24 MiB**，全部记在 **Shmem**，**没有任何进程的匿名/堆内存增长**；
- `rm` 后 **MemAvailable 立即回到基线**（1086.5 vs dd 前 1086.6）；
- 10 轮写/删（每轮驻留 3 s）与 20 轮写/删（累计写入 **480 MiB**）都**没有累积**，最终仍回到基线；
- 对照实验：同样 24 MiB 写到 **ext4**（`/userdata`）时，Cached 同样 +24 MiB、MemFree 同样下降，但 **MemAvailable 只降 0.5 MiB** —— 说明“可用内存下降”是 **tmpfs 特性**，不是 `dd`/脚本/泄漏。

> 唯一会看到“内存一直不回来”的情况：**脚本被 `SIGKILL` 杀掉**（`trap` 捕获不到 KILL），`/data` 里的 24 MiB 文件变成孤儿文件一直占内存，直到手工删除（见 4.5）。这仍不是泄漏，是**残留文件**。

本结论的限定：下降幅度就是 **24 MiB ≈ 1.3 GiB 的 1.8%**。如果你现场看到的下降远大于此（比如上百 MiB），那部分**不由本脚本的 dd 解释**，需要另外取证（见 §9）。

---

## 1. 测试对象与环境实测

```text
uname -a          Linux buildroot 6.1.83-DR-PL5.1_V1.0.20 #3 SMP PREEMPT aarch64
mount             tmpfs on /data  type tmpfs (rw,relatime)      <-- 关键
                  /dev/block/platform/by-name/userdata on /userdata type ext4 (rw)  <-- 对照盘
df -h /data       tmpfs 653M 4.0K 653M 1%
/proc/meminfo     MemTotal 1336028 kB, SwapTotal 0 kB, Shmem 216 kB（空闲基线）
tracefs           /sys/kernel/debug/tracing（真实挂载点）, kmem:rss_stat 存在
板上 Perfetto     无；本次从主机推 v57.1 到 /userdata/perfetto-debug/（见 §6）
业务进程          cam-service 一直在运行，本次未重启、未注入、未修改其配置
```

脚本逻辑（`set -eu`，`mktemp` 在 `/data`，`trap` 清理）：

```sh
F=$(mktemp /data/.memcase.XXXXXX)
trap 'rm -f "$F"' EXIT ; trap 'exit 1' HUP INT TERM
echo TEST START ; sleep 10
dd if=/dev/zero of="$F" bs=1048576 count=24   # 24 MiB 写入 tmpfs
sleep 25 ; rm -f "$F" ; sleep 10 ; echo TEST END
```

独立的文件事实核对（trace 之外单独跑一次脚本，驻留期抓取）：

```text
tmpfs  653M  25M  629M   4% /data
-rw------- 1 root root 25165824 /data/.memcase.6Ov0eb      # 恰好 24 MiB
MemFree 984300 kB  MemAvailable 1099356 kB  Cached 77620 kB  Shmem 24800 kB
```

---

## 2. 实验设计（5 组 + 1 空载基线）

所有组用**同一份配置**（仅 duration 不同），trace 写在 `/userdata`（ext4），**不写 `/data`**，避免采集自身占用 tmpfs。

| 组 | 目的 | 负载 | trace |
|---|---|---|---|
| run0 | **空载基线**：量化 Perfetto 自身开销 | 无 | mem1 (120 s) |
| run1 | **主复现**：原脚本，`/data` tmpfs | 原脚本 45 s | mem1 (120 s) |
| run2 | **对照**：同样 dd/sleep/rm，文件改到 `/userdata` ext4 | 改路径的同一脚本 45 s | mem2 (100 s) |
| run5 | **累积/泄漏测试**：10 轮（写 24 MiB → 驻留 3 s → rm → 1 s） | 10 × 24 MiB | mem2 (100 s) |
| run3 | **累积/泄漏测试（快节奏）**：20 轮（写 → 立即 rm → 1 s） | 20 × 24 MiB | mem3 (120 s) |
| run4 | **孤儿文件**：原脚本跑到驻留期后 `SIGKILL`，观察 10 s 再手工 `rm` | 原脚本 + kill | mem1 (120 s) |

每组都以 `workload_start_uptime`（板端 `/proc/uptime`，与 trace 同为 boottime 时钟）作为对齐锚点。

> 数据谱系说明：第一次执行时板上 `/data/rdk_mem_case.sh` 仍是 heredoc 包装文本（执行后自写成真脚本），那次运行无效；其后每轮都在日志里记录脚本 `md5/size` 并确认 `TEST START`/`TEST END`，**本报告只采用核对后的 run0–run5 数据**。

---

## 3. run1 主复现（原脚本，`/data` = tmpfs）

![X5 24MiB tmpfs vs ext4](mem_timeline.png)

逐 250 ms 采样的关键点（MiB）：

| 相对时刻 | 事件 | MemAvailable | MemFree | Shmem | Cached | AnonPages | Slab |
|---|---|---|---|---|---|---|---|
| +0.0 s | TEST START | 1087.6 | 976.0 | 0.3 | 51.3 | 12.5 | 81.7 |
| +10.0 s | 紧邻 dd | 1086.6 | 975.0 | 0.3 | 51.4 | 12.9 | 81.7 |
| +12.5 s | 文件已写入（24 MiB） | **1062.6** | **950.9** | **24.3** | **75.4** | 12.9 | 81.7 |
| +25.0 s | 驻留中 | 1062.6 | 950.9 | 24.4 | 75.4 | 13.0 | 81.7 |
| +35.0 s | 紧邻 rm | 1062.6 | 950.9 | 24.4 | 75.5 | 13.0 | 81.7 |
| +37.5 s | rm 后 | **1086.5** | **974.8** | **0.4** | **51.5** | 13.0 | 81.7 |
| +58.0 s | 结束前 | 1086.5 | 974.8 | 0.5 | 51.6 | 12.8 | 81.7 |

**变化量**：MemAvailable −24.0、MemFree −24.1、Shmem **+24.0**、Cached **+24.0**、AnonPages 0.0、Slab 0.0（MiB）。

进程侧证据（同一 trace 的 `process_stats`，31 个进程合计）：

| 指标 | dd 前 | 驻留期 |
|---|---|---|
| 全进程 `mem.rss.anon` 合计 | 11.57 MiB | 11.55 MiB（**−0.02**） |
| 脚本 shell `sh` 的最大 anon RSS | — | 0.30 MiB |

即：**24 MiB 不挂在任何进程的 RSS/堆上**，只出现在系统 `Shmem`。内核 `kmem/rss_stat` 事件在 run1 只有 1108 条（无采样进程时很低），也未见任何进程 RSS 阶跃。

---

## 4. 对照与累积实验

### 4.1 run2：同样 24 MiB 写到 ext4（`/userdata`）——`MemAvailable` 几乎不动

| 窗口 | MemAvailable | MemFree | Shmem | Cached |
|---|---|---|---|---|
| dd 前 | 1086.9 | 974.5 | 0.3 | 51.9 |
| 驻留期 | **1086.4（−0.5）** | **949.4（−25.1）** | 0.3（不变） | **75.9（+24.0）** |
| rm 后 | 1086.5 | 974.0 | 0.4 | 52.0 |

同一个 24 MiB 写入，ext4 上只是**可回收的页缓存**：MemFree 同样掉 25 MiB，但 `MemAvailable` 只掉 **0.5 MiB**。
**这直接排除**“dd 写 24 MiB 本身让可用内存掉 24 MiB”的解释——差异来自 `/data` 是 tmpfs。

### 4.2 run5：10 轮写/驻留/删 —— 每轮精确回到基线，无累积

| 轮次 | dd 前 avail | 驻留期 avail | 驻留期 Shmem | rm 后 avail | rm 后 Shmem |
|---|---|---|---|---|---|
| 0 | 1087.4 | 1062.8 | 24.3 | 1086.4 | 0.3 |
| 1 | 1086.4 | 1062.4 | 24.3 | 1086.6 | 0.3 |
| 2 | 1086.6 | 1062.4 | 24.4 | 1086.0 | 0.4 |
| 3 | 1086.0 | 1063.0 | 24.4 | 1086.8 | 0.4 |
| 4 | 1086.8 | 1061.5 | 24.4 | 1085.5 | 0.4 |
| 5 | 1085.5 | 1061.8 | 24.5 | 1085.5 | 0.5 |
| 6 | 1085.5 | 1062.0 | 24.5 | 1085.5 | 0.5 |
| 7 | 1085.5 | 1061.5 | 24.5 | 1085.4 | 0.6 |
| 8 | 1085.4 | 1061.8 | 24.6 | 1085.9 | 0.6 |
| 9 | 1085.9 | 1061.3 | 24.6 | 1085.2 | 0.6 |

10 轮共写入 240 MiB：**每轮都 +24.3…24.6 MiB / −24…−26 MiB，rm 后全部回到 0.3–0.6 MiB Shmem**。
trace 结束时（再空转 ~45 s）剩余偏差约 **−2.2 MiB**（1085.2 vs 1087.4），其中 Shmem 自身因 trace 环形缓冲从 0.3 涨到 0.6 MiB，其余是本底抖动；**不是 24 MiB 量级的线性增长**。

### 4.3 run3：20 轮快速写/删（累计 480 MiB）——同样无累积

- 峰值 Shmem 24.5 MiB、最低 MemAvailable 1061.2 MiB（第 1 轮）；
- 20 轮后 trace 结束：MemAvailable 1086.2 vs 轮前 1087.2（**−1.0 MiB**）；
- 单轮文件生命周期约 0.1 s，短于 250 ms 轮询，所以不是每轮都能采到峰值（这本身说明观测粒度，而不是“没有变化”）。

### 4.4 run4：`SIGKILL` → 孤儿 tmpfs 文件 → 内存不回来（唯一“像泄漏”的路径）

| 相对时刻 | 事件 | MemAvailable | Shmem |
|---|---|---|---|
| +14 s | 文件驻留 | 1062.9 | 24.4 |
| **+18 s** | **`kill -9` 脚本进程**（文件 25165824 B 仍在） | 1062.9 | 24.4 |
| +18…+36 s | 进程已死 **18 s** | **1062.9 ~ 1063.2** | **24.4 ~ 24.5** |
| +36.1 s | 手工 `rm` 孤儿文件 | **1086.3** | **0.5** |

`trap 'rm -f "$F"' EXIT` 对 `SIGKILL` 无效。**如果你们的测试框架会超时 `kill -9` 脚本、或在 `rm` 前中断测试，就会看到 24 MiB 一直不释放**——那是残留文件，`rm`/重启即恢复，不是内核或进程泄漏。

### 4.5 run0：空载基线（量化“采集本身”的开销）

同一配置空跑 120 s：MemAvailable 1087.1 → 1086.8（**−0.3 MiB**）、Shmem 0.2→0.7 MiB、AnonPages 12.5→12.7 MiB、Slab 81.6 平稳。
即本轮 Perfetto 采集自身只有**亚 MiB 级**影响，不能解释 24 MiB；同时说明 run1 的 +24 MiB 不是采集器造成。

---

## 5. 为什么“可用内存”会 1:1 地掉

1. `/data` 是 **tmpfs**：文件内容不是写盘，而是**物理内存页**（meminfo 里算 `Shmem`，同时也被计入 `Cached`——**同一批页，两项都给，绝不能相加**）。
2. 本板 **`SwapTotal = 0`**：tmpfs 页没有 swap 可换出，属于**不可回收内存**，所以内核把它从 `MemAvailable` 里直接扣掉；而 ext4 的页缓存是**可回收**的，只扣 `MemFree`、几乎不扣 `MemAvailable`（run2 实证）。
3. `dd` 写完立即 `rm`，最后一个 `/data` 中引用该 inode 的进程退出，tmpfs 页**当拍释放**；所以驻留期一结束，`MemAvailable`/`Shmem`/`Cached` 同步回到基线（run1、run5 实证）。
4. 因此：**没有“分配后不释放”的进程侧对象**（anon RSS 合计 11.57→11.55 MiB、Slab 不变、无增长进程）。按定义这不构成内存泄漏。

---

## 6. 采集配置与执行（可复现）

### 6.1 TraceConfig（完整，`mem1.pbtxt`，120 s 版）

```protobuf
# 基于 skill 的 rss-spike 配方，扩展 meminfo 分类计数器
buffers { size_kb: 8192 fill_policy: RING_BUFFER }
buffers { size_kb: 4096 fill_policy: DISCARD }
duration_ms: 120000
data_sources {
  config {
    name: "linux.process_stats"
    target_buffer: 1
    process_stats_config { scan_all_processes_on_start: true proc_stats_poll_ms: 250 }
  }
}
data_sources {
  config {
    name: "linux.sys_stats"
    target_buffer: 0
    sys_stats_config {
      meminfo_period_ms: 250
      meminfo_counters: MEMINFO_MEM_TOTAL  meminfo_counters: MEMINFO_MEM_FREE
      meminfo_counters: MEMINFO_MEM_AVAILABLE  meminfo_counters: MEMINFO_BUFFERS
      meminfo_counters: MEMINFO_CACHED  meminfo_counters: MEMINFO_SWAP_CACHED
      meminfo_counters: MEMINFO_DIRTY  meminfo_counters: MEMINFO_WRITEBACK
      meminfo_counters: MEMINFO_ANON_PAGES  meminfo_counters: MEMINFO_MAPPED
      meminfo_counters: MEMINFO_SHMEM  meminfo_counters: MEMINFO_SLAB
      meminfo_counters: MEMINFO_SLAB_RECLAIMABLE  meminfo_counters: MEMINFO_SLAB_UNRECLAIMABLE
      meminfo_counters: MEMINFO_KERNEL_STACK  meminfo_counters: MEMINFO_PAGE_TABLES
      meminfo_counters: MEMINFO_SWAP_TOTAL  meminfo_counters: MEMINFO_SWAP_FREE
      meminfo_counters: MEMINFO_CMA_TOTAL  meminfo_counters: MEMINFO_CMA_FREE
      vmstat_period_ms: 1000
      vmstat_counters: VMSTAT_NR_FREE_PAGES  vmstat_counters: VMSTAT_PGFAULT
      vmstat_counters: VMSTAT_PGMAJFAULT  vmstat_counters: VMSTAT_PSWPIN
      vmstat_counters: VMSTAT_PSWPOUT
    }
  }
}
data_sources {
  config {
    name: "linux.ftrace"
    target_buffer: 1
    ftrace_config {
      buffer_size_kb: 1024
      drain_period_ms: 250
      ftrace_events: "kmem/rss_stat"
    }
  }
}
```

- Schema 级校验：`validate_config.py` + 用 Perfetto 源码 checkout(`2a2c7394`, 2026-06-02) 生成的 `trace_config.desc` → `SCHEMA OK`（**注意**：该 checkout 与板端 `v57.1-c59f57dd4` 不是同一 commit，故只算“构造已校验”，最终以本机实跑为准；本次实跑数据完整，见 §7）。
- 预算：traced buffers 12 MiB + ftrace 1 MiB/CPU×8 ≈ 20 MiB 峰值，实测 trace 仅 0.5–0.85 MB/次，无丢包。

### 6.2 执行步骤（本次实际执行）

【目标机】只读勘查：`survey.sh`、`available_events`（1170 个事件，含 `kmem:rss_stat`、`cma:*`、`vmscan:*`）。

【主机 → 板】推工具与配置（板无外网、根分区只读）：

```bash
BOARD=root@192.168.1.10
SRC=/root/sdk_md_x5_1.1.1/perfetto/linux-arm64/linux-arm64
ssh $BOARD 'mkdir -p /userdata/perfetto-debug'
scp $SRC/tracebox $SRC/trace_processor_shell $BOARD:/userdata/perfetto-debug/
scp mem1.pbtxt mem2.pbtxt mem3.pbtxt run_case.sh $BOARD:/userdata/perfetto-debug/
```

【目标机】采集（trace 落 ext4，**不落 /data**）：

```bash
/userdata/perfetto-debug/tracebox --txt -c /userdata/perfetto-debug/mem1.pbtxt \
  -o /userdata/perfetto-debug/run1.pftrace        # 先起采集，8 s 后再起业务
sh /data/rdk_mem_case.sh                          # 被测脚本（原样运行）
# 脚本结束再空转 25 s，等 duration 到期自动 flush
```

【主机】拉回并分析：

```bash
scp $BOARD:/userdata/perfetto-debug/run1.pftrace .
trace_processor_shell query run1.pftrace "SELECT * FROM trace_bounds"
```

### 6.3 采集验收（逐项）

| 项 | 结果 |
|---|---|
| trace 覆盖 | run1: 36474876605017 → 36594515646949 ns（119.6 s）；workload 在锚点 +0…+45 s |
| meminfo 样本 | 480 个 / 119.6 s ≈ 4/s，符合 250 ms 配置 |
| 目标进程 | `sh`、`cam-service`、`tracebox` 等 31 个进程的 `mem.rss.*` 轨道齐全；`dd` 存活 <250 ms，未被 250 ms 轮询采到（预期，不影响 shmem 归因） |
| 数据丢失 | `stats` 表中非 info 级错误：无；`tracebox_exit=0`，flush 后写出 542417 B（trace 无截断；开头/结尾均覆盖到复现窗口） |
| ftrace | `kmem/rss_stat` 实际产出 1108 条（run1），字段 `member/size/mm_id/curr` 可读 |
| 符号 | 本报告只用到内核计数器与进程级 RSS 聚合，无调用栈需求，不涉及符号缺失问题 |

---

## 7. Perfetto UI 复现（`run1.pftrace`）

1. 打开 `run1.pftrace`（本目录），Timeline 搜索 `MemAvailable` / `Shmem` / `Cached`，选中这三条 Counter Track（可先 Hide 其它轨道）。
2. 在 `+10 s` 附近 `Shmem` 应有 **24 MiB 阶跃**，`+35 s`（`rm` 后）回落；同窗口 `MemAvailable` 反向阶跃、`AnonPages`/`Slab` 平坦。
3. 展开任意进程 → `mem.rss.anon` 轨道：驻留期与 dd 前基本重合（不要把该进程 RSS 当作 24 MiB 的来源）。
4. Query(SQL) 里跑 `analysis.sql`，或用下面的 debug track 映射：

```sql
-- Add debug track: Counter Track, Timestamp=ts, Value=value, Pivot on series
SELECT c.ts AS ts, c.value / 1048576.0 AS value, ct.name AS series
FROM counter c JOIN counter_track ct ON ct.id = c.track_id
WHERE ct.name IN ('MemAvailable','MemFree','Shmem','Cached','AnonPages','Slab')
ORDER BY series, ts;
```

口径提示：`counter.value` 是 **bytes**，除以 1048576 得 MiB；`Cached` 与 `Shmem` 对 tmpfs 页重叠，**不可相加**；`MemAvailable` 是内核估算值，不是“可分摊给任意进程的私有内存”。

---

## 8. 本次证据覆盖不到的内容（不夸大）

- **无 smaps/PSS/映射级归属**：本配置没有 smaps/rollup，因此不宣称“24 MiB 具体挂在某个 inode 的哪个偏移”；结论来自 `Shmem` 分类 + 文件事实 + 对照实验。
- **未用 heapprofd**：本项目内存不在 malloc heap 上（且 `dd` 生命周期 <250 ms、`/bin/sh` 为 busybox）。heapprofd 只能回答“谁 malloc 没 free”，在这里既无必要也无法解释 tmpfs 页；所以没有把它当作证据。
- **无 cgroup/memcg 细分**：`meminfo` 是全局口径。
- **未构造内存压力**：本测试 24 MiB 对 1.3 GiB 很小，没有触发 direct reclaim/swap（本板也无 swap），因此不能回答“高压下 tmpfs 与回收的交互”。
- **未验证长时间（小时级）行为**：run1/run3/run5 覆盖 100–120 s；按 20 轮无累积的趋势，不支持小时级泄漏结论，但严格说未测。

---

## 9. 建议（如果目标是“别让测试看起来像内存泄漏”）

1. **首选**：把大文件写到 **`/userdata`（ext4）** 而不是 `/data`（tmpfs）。run2 已证明同样写入下 `MemAvailable` 只降 0.5 MiB。
   - 注意 `/tmp` 在本板**也是 tmpfs**，不是替代品。
2. **如果必须用 `/data`**：
   - 保留 `trap` 清理（已覆盖 HUP/INT/TERM），并**在脚本开头加一行 `rm -f /data/.memcase.*`**，避免上次异常退出的残留；
   - 加显式上限：`du`/`df` 检查或写入前预检 `/data` 余量；
   - 测试超时用 `TERM` 而不是 `KILL`（KILL 无法触发 trap，run4 已实证会留下 24 MiB）。
3. **监控口径**：判断“谁占了内存”看 `Shmem`（tmpfs/共享页）与进程 `mem.rss.anon`，不要只看 `free` 的 `used`（`used` 不含 page cache，容易被误读）；本板 `Cached` 里也含 shmem 页。
4. **如果现场观察到的下降远大于 24 MiB**：按怀疑顺序查（本次未取证）：
   - `/data` 里是否有历史残留文件（`ls -la /data`、`df /data`）；
   - 是否有工具把 trace/日志写到 `/data`（tmpfs）；
   - 相机/VPU 的 CMA：本板 `CmaTotal 391168 kB`，`CmaFree` 会随业务分配波动，与 dd 无关；
   - 内核 slab（`-1` 或未命名对象）与 dma-buf。

---

## 10. 产物与板端清理

本目录（`v4_test/`）：

| 文件 | 说明 |
|---|---|
| `traces/run1.pftrace` | **主证据**：原脚本 + `/data` tmpfs，120 s |
| `traces/run2.pftrace` | 对照：同内容写 `/userdata` ext4，100 s |
| `traces/run5.pftrace` | 10 轮写/驻留/删累积测试，100 s |
| `traces/run3.pftrace` | 20 轮快速写/删（累计 480 MiB），120 s |
| `traces/run4.pftrace` | SIGKILL → 孤儿文件 → 手工 rm，120 s |
| `traces/run0.pftrace` | 空载基线，120 s |
| `configs/mem1.pbtxt` `mem2.pbtxt` `mem3.pbtxt` | 采集配置（120/100/120 s） |
| `sql/00-inventory.sql` … `03-ftrace-rss-stat.sql` | UI / trace_processor_shell 查询（验收、时间线、RSS、rss_stat） |
| `sql_out/summary.csv` `quality.txt` `meminfo_run*.csv` `cycles_run5.csv` | 实际查询输出与哈希清单 |
| `charts/mem_timeline.svg` / `.png` | 由真实 trace 数据绘制的 tmpfs vs ext4 对比图 |
| `logs/run*.run.log` | 每组的时间锚点、脚本输出、起止 meminfo |
| `scripts/driver.sh` `run_case.sh` `gen_cfg.py` `analysis.py` `svg_gen.py` `gen_sql_out.py` | 本次复现脚本 |
| `SHA256SUMS.txt` | 目录内全部文件哈希 |

板端：`/userdata/perfetto-debug/` 下的 trace 与脚本已全部拉回并删除；`/data` 无残留文件；`cam-service` 未被重启/注入，仍正常运行；ftrace 已由 tracebox 恢复（`current_tracer=nop`、`tracing_on=0`、无实例）。本次**未修改任何 sysctl、未关闭 SELinux（本板无）、未清缓存、未杀其它会话**。
