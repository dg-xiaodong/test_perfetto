# v4_test — RDK X5 `/data/rdk_mem_case.sh` 内存行为定位（Perfetto 实测）

日期：2026-10-18。本目录是一次完整场景记录：**真实板端采集 + 真实 trace 分析**，回答“脚本运行时可用内存明显下降，是否内存泄漏”。

- 板卡：RDK X5 EVB `192.168.1.10`，`6.1.83-DR-PL5.1_V1.0.20` aarch64，8 核，`MemTotal 1336028 kB`，**SwapTotal = 0**
- 被测脚本：`/data/rdk_mem_case.sh`（235 B，md5 `2d70ea97dfe637757f23638063503047`，`mktemp` 到 `/data`、`dd` 写 24 MiB、驻留 25 s、`rm`）
- 采集器：板载 `tracebox` **v57.1-c59f57dd4**（ARM64，SDK 预编译，主机推送到 `/userdata`）
- 分析器：`trace_processor_shell` **v57.1-c59f57dd4**（同一 build）
- 数据源：`linux.sys_stats`（meminfo @250 ms）+ `linux.process_stats`（@250 ms）+ `linux.ftrace`（`kmem/rss_stat`）
- trace 全部写在 `/userdata`（ext4），**不写 `/data`**，避免采集自身占用 tmpfs

## 结论速览

**不是内存泄漏。** `/data` 是 tmpfs（RAM 支持、本板无 swap → 不可回收），脚本 `dd` 写入的 **24 MiB 文件 = 24 MiB 物理内存页（Shmem）**，`rm` 后立即释放。

| 实验 | 结果 | 判定 |
|---|---|---|
| run1 原脚本（`/data` tmpfs） | MemAvailable 1086.6 → **1062.6（−24.0）**；Shmem 0.3 → **24.3**；Cached 51.4 → 75.4；AnonPages/Slab 不动；rm 后回 1086.5 | 非泄漏，tmpfs 页 |
| run2 对照（同 24 MiB 写 `/userdata` ext4） | Cached +24.0、MemFree −25.1，但 **MemAvailable 仅 −0.5** | 下降是 tmpfs 特性，不是 dd/脚本 |
| run5 10 轮写/驻留/删 | 每轮 +24.3…24.6 MiB，rm 后回 0.3–0.6；**无累积** | 非泄漏 |
| run3 20 轮快速写/删（累计 480 MiB） | 结束 1086.2 vs 首样本 1087.2；峰值 24.5 | 非泄漏 |
| run4 `kill -9`（孤儿文件） | 进程死后 18 s 内存仍占 24.4 MiB，手工 `rm` 后回 1086.3 | **残留文件**，仍非泄漏 |
| run0 空载基线（同配置 120 s） | MemAvailable 漂移 −0.3 MiB | 采集自身开销可忽略 |

进程侧：run1 全进程 `mem.rss.anon` 合计 11.57 → 11.55 MiB（−0.02）；被执行的 shell（pid 11131 / 11153）RSS ≤2.46 MiB、`shmem = 0`；`dd` 存活 <250 ms 未被轮询采到（预期，不影响 shmem 归因）。

完整证据、采集配置、验收与边界见 **[REPORT.md](REPORT.md)**。

**归因（哪个进程/哪条命令）**：`run0–run5` 只采了计数器，UI 里没有 slice 可点。为此补采了 `attribution/traces/run6.pftrace`（加 `sched_switch` + `sched_process_exec` + `filemap` 页删除事件），把 24 MiB 定位到 **`/usr/bin/dd`（tid 11792，CPU slice 40.8 ms @ +10.023 s）创建**、**`/usr/bin/rm`（tid 11796）unlink 时 6,144 次页删除（24.00 MiB，单 inode，index 0–6143）释放**。方法与证据见 **[attribution/ATTRIBUTION.md](attribution/ATTRIBUTION.md)**。

## 目录

| 路径 | 内容 |
|---|---|
| `traces/run0.pftrace` … `run5.pftrace` | 6 次实际采集（run1 为主证据，共 3.6 MB） |
| `attribution/traces/run6.pftrace` | 归因专用补采（sched_switch + exec + filemap 页删除，90 s） |
| `attribution/ATTRIBUTION.md` | 从“没有 slice”到“定位到 dd/rm 两个进程”的方法与证据 |
| `attribution/sql/10-attribution.sql` | exec 链 / dd、rm slice / 页删除 burst 查询与 debug track 映射 |
| `configs/mem1.pbtxt` `mem2.pbtxt` `mem3.pbtxt` | 实际使用的 TraceConfig（120 s / 100 s / 120 s） |
| `scripts/run_case.sh` | 板端编排：起 tracebox → 8 s 后跑工作负载 → 收尾（`tmpfs`/`ext4`/`cycles`/`cycles_hold`/`kill`） |
| `scripts/driver.sh` | 主机侧顺序跑 6 组并拉回 |
| `scripts/gen_cfg.py` | 生成配置（基于 skill 的 rss-spike 配方，扩展 meminfo 分类计数器） |
| `scripts/analysis.py` / `svg_gen.py` / `gen_sql_out.py` | 汇总分析、绘图、生成 `sql_out/` |
| `sql/00-inventory.sql` … `03-ftrace-rss-stat.sql` | 采集验收 / 内存时间线 / 进程 RSS / rss_stat 事件 |
| `sql_out/` | 上述 SQL 的实际输出：`summary.csv`、`quality.txt`、`meminfo_run*.csv`、`cycles_run5.csv`、`process_anon_run1.txt`、`trace_sha256.txt` |
| `charts/mem_timeline.png` / `.svg` | 由真实 trace 数据绘制的 tmpfs vs ext4 对比图（**不是 UI 截图**） |
| `logs/run*.run.log` | 每组的 `workload_start_uptime` 锚点、脚本 md5、`TEST START/END`、起止 meminfo |
| `logs/board_environment.txt` `tool_versions.txt` `capture_command.txt` | 只读环境勘查与工具/命令 provenance |
| `REPORT.md` | 完整分析报告（逐组数据、配置、验收、UI 配方、边界） |
| `SHA256SUMS.txt` | 目录内全部文件哈希 |

## 如何看 trace

1. 打开 <https://ui.perfetto.dev> → Open trace file → 选 `traces/run1.pftrace`。
2. Timeline 搜索 `MemAvailable`、`Shmem`、`Cached`（全局 counter，不需要选 PID）；缩放到 `+10 s … +40 s`（相对 `workload_start`）。
3. 期望：`Shmem` 在 +10 s 阶跃 +24 MiB，+35 s 回落；`MemAvailable` 反向阶跃；`AnonPages`/`Slab` 平坦。
4. 要按进程/命令归因：打开 `attribution/traces/run6.pftrace`，搜 `11792`（dd 的 slice）/ `11796`（rm 的 slice），或跑 `attribution/sql/10-attribution.sql` 生成 exec 与页删除 debug track（详见 ATTRIBUTION.md）。
4. 命令行分析：

```bash
TP=/path/to/trace_processor_shell
$TP query traces/run1.pftrace "$(cat sql/00-inventory.sql)"
$TP query traces/run1.pftrace "$(cat sql/01-meminfo-timeline.sql)"
python3 scripts/analysis.py   # 需先把 traces/ 的 trace 与 logs/ 的 run.log 放到脚本同目录
```

## 复现步骤（简）

```bash
# 1) 推工具与配置（板无外网、rootfs 只读）
ssh root@<board> 'mkdir -p /userdata/perfetto-debug'
scp <sdk>/perfetto/linux-arm64/linux-arm64/tracebox <board>:/userdata/perfetto-debug/
scp configs/*.pbtxt scripts/run_case.sh <board>:/userdata/perfetto-debug/
# 2) 板端采集（trace 落 ext4）
ssh root@<board> 'sh /userdata/perfetto-debug/run_case.sh run1 /userdata/perfetto-debug/mem1.pbtxt tmpfs'
# 3) 拉回
scp root@<board>:/userdata/perfetto-debug/run1.pftrace .
# 4) 分析（见上）
```

## 边界声明

- 只采 `meminfo` / `process_stats` / `kmem/rss_stat`；**未用 heapprofd**（本项目内存不在 malloc heap，且 `dd` 生命周期 <250 ms）。
- 无 smaps/PSS/映射级归属、无 cgroup/memcg 细分；`meminfo` 是全局口径。
- 未构造内存压力（24 MiB 对 1.3 GiB 很小，本板无 swap），未验证小时级行为。
- 配置 schema 用 Perfetto 源码 checkout `2a2c7394`（2026-06-02）的 descriptor 校验为 `SCHEMA OK`，与采集器 `c59f57dd4` 非同一 commit；最终以本次实跑数据为准（6 份 trace 数据完整、无非 info 错误）。
