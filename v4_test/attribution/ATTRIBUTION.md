# 归因补充：从“没有 slice 轨道”到“定位到 dd / rm 这两个进程”

本文补上 v4_test 的一个方法缺口：`run0–run5` 的配置只采了 **计数器 + `kmem/rss_stat`**，没有 `sched_switch`/`track_event`，所以 Perfetto UI 里 **slice 表是空的**，无法直接“点某个 pid 的 slice”。这不影响“是不是泄漏”的结论，但影响“谁在什么时候做了什么”的定位。

本目录的 `run6` 是补采的**归因专用 trace**，把链路补到可点、可查的粒度。

## 1. run0–run5 为什么没有 slice

| 数据源 | 产出 |
|---|---|
| `linux.sys_stats` | 全局 counter 轨道（`MemAvailable`/`Shmem`/`Cached`…），无 pid |
| `linux.process_stats` | 每进程 `mem.rss.*` counter 轨道，无 slice |
| `linux.ftrace`（仅 `kmem/rss_stat`） | 112…11k 条**事件**，不是 slice |

`SELECT count(*) FROM slice` = 0，`sched_slice` 也不存在（未开 `sched/sched_switch`）。所以 UI 里“进程行下面没有 slice 可点”是配置结果，不是 trace 坏了。

## 2. 不补采也能做到的归因（run1 的证据）

**(a) 进程生命周期**：`process_stats` 给每个 UPID 留下 `mem.rss.*` 采样区间，可反推进程存活窗口（相对 `workload_start`）：

| PID | 进程 | 存活窗口 | 说明 |
|---|---|---|---|
| 11153 | `sh`（`rdk_mem_case.sh`） | +0.007 … +45.106 s | 脚本本体 |
| 11155 | `sleep` | +0.016 … +10.019 s | 第 1 段 `sleep 10` |
| 11157 | `sleep` | +10.064 … +35.073 s | 第 2 段 `sleep 25`（**dd 写入 → 驻留 → rm 前**） |
| 11160 | `sleep` | +35.092 … +45.101 s | 第 3 段 `sleep 10`（rm 之后） |

三个 `sleep` 子进程把脚本切成 **0–10 s / 10–35 s / 35–45 s** 三段；`Shmem` 的 +24 MiB 阶跃恰好落在第 2 段起点，回落在第 3 段起点。

**(b) 排除进程侧**：pid 11131/11153 的 `mem.rss.anon` 全程 0.29–0.30 MiB、`mem.rss.shmem = 0`；全进程 anon 合计 11.57 → 11.55 MiB。

**(c) 对照**：run0（同配置空载）无阶跃、run2（同字节写 ext4）`MemAvailable` 只 −0.5 MiB → 阶跃只可能来自 `/data` 上的 tmpfs 文件。

这三点足以回答“是不是泄漏”，但回答不了“哪个进程写的、哪个进程删的”。

## 3. run6：补采后的精确归因

**配置**：`mem6.pbtxt` = 原计数器配置 + `kmem/rss_stat` + `sched/sched_switch` + `sched/sched_process_exec` + `filemap/mm_filemap_add_to_page_cache` + `filemap/mm_filemap_delete_from_page_cache`（trace 780,550 B，90 s，359 个 meminfo 样本，非 info 级错误 0）。事件量：`sched_switch` 8,510 / `mm_filemap_delete_from_page_cache` 6,144 / `rss_stat` 1,113 / `sched_process_exec` 13 / `mm_filemap_add_to_page_cache` 24（全部来自 `jbd2`，见 §4）。

`exec` 事件直接给出被测脚本的每条命令、时刻与线程（相对 `workload_start`，`traces/run6.pftrace`）：

| 时刻 | 进程 | 线程 (utid/tid) | 作用 |
|---|---|---|---|
| +0.010 | `/usr/bin/sh` | 210 / 11789 | 脚本本体（存活到 +45.106） |
| +0.015 | `/usr/bin/mktemp` | 211 / 11790 | 在 `/data` 建空文件 |
| **+10.024** | **`/usr/bin/dd`** | **213 / 11792** | **写入 24 MiB** |
| **+35.077** | **`/usr/bin/rm`** | **217 / 11796** | **删除文件** |
| +45.104 | `/usr/bin/rm` | 219 / 11798 | 收尾清理 |

**写入侧归因**（dd）：

- 线程 11792 的唯一 CPU slice：**+10.023 s、40.798 ms、CPU0**（`sched_switch` 记录，slice 内 comm 仍是 fork 时的 `sh`，`exec` 事件证明它就是 `/usr/bin/dd`）；
- 同一窗口 `Shmem`：+9.881 s **0.34 MiB** → +10.631 s **24.34 MiB**；`Cached` 37.26 → 61.27 MiB；`MemAvailable` 1078.05 → 1054.42 MiB。

**释放侧归因**（rm，逐页事件）：

| 字段 | 值 |
|---|---|
| 页删除事件数 | **6,144** |
| 折算容量 | 6,144 × 4 KiB = **24.00 MiB** |
| `i_ino` | **1 个**（确认是同一个文件） |
| `index` 范围 | **0 … 6143**（连续，正好 24 MiB） |
| 时间窗 | +35.079 … +35.098 s（19 ms 内完成） |
| 上下文 | utid 217 / tid 11796 的 `rm`（slice 22.328 ms @ +35.076） |
| 同时段 `Shmem` | +34.382 s 24.48 MiB → +35.631 s **0.66 MiB** |

结论：**24 MiB 的创建发生在 dd 的 40.8 ms CPU slice 内，释放发生在 rm 的 unlink 路径（6,144 次页删除，同一个 inode，index 0–6143）**。两侧都落到具体 pid/tid 与时刻，且总量与文件大小严格对齐（6144×4 KiB = 24 MiB）。

## 4. 已知限制（必须说明）

- **本内核的 tmpfs 不产生 `mm_filemap_add_to_page_cache`**：run6 里 24 条 add 事件全部来自 `jbd2`（把 trace 写到 `/data` 之外的 ext4 时的日志/页缓存），没有一条属于 `/data` 上的文件。因此**创建侧**只能靠 `exec dd` + dd 的 CPU slice + 计数器阶跃关联；**释放侧**有逐页事件，可直接归因。
- `dd` 生命周期约 40–50 ms，`process_stats` 250 ms 轮询采不到，所以 UI 里 **`dd` 不会作为 process 轨道出现**；它的 `sched` slice 挂在 fork 时的线程名 `sh`（tid 11792）下。请用 §5 的方式定位。
- `sched_switch` 会带来额外开销（8,510 条/90 s、8 核），只建议在需要归因时开启；判断“是否泄漏”用 run0–run5 的轻量配置即可。

## 5. 在 UI 里怎么点（run6）

1. 打开 `traces/run6.pftrace`；
2. 勾选全局 counter：`MemAvailable`、`Shmem`、`Cached`（+10 s 阶跃、+35 s 回落）；
3. 归因轨道：搜索 **`11792`**（dd 的 slice）与 **`11796`**（rm 的 slice）——注意线程名显示为 `sh`，因为 comm 取自 fork 时刻，`exec` 路径在 SQL/原始事件里；
4. 用 `sql/10-attribution.sql` 生成两个 debug track（Slice Track，`ts`/`dur`/`name`/`series`）：
   - `exec` 链：`/usr/bin/dd` @ +10.024、`/usr/bin/rm` @ +35.077；
   - 页删除 burst：+35.079…+35.098 的 6,144 次删除（按 10 ms 分桶）。
5. 命令行等价查询：

```bash
TP=/path/to/trace_processor_shell
$TP query traces/run6.pftrace "$(sed -n '1,40p' sql/10-attribution.sql)"
```

## 6. 结论不变

不是内存泄漏：24 MiB 是 `/data`（tmpfs）上测试文件的页，写在 dd、释放在 rm；**进程堆（anon）全程不增长**，20 轮写/删无累积，唯一“内存不回来”的情形是 `kill -9` 留下的孤儿文件（见 `REPORT.md` §4.4）。
