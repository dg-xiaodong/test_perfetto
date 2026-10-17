# x5_memory_visual_test — perfetto-memory-debugging v1.0.2 第二次 X5 板端验证

日期：2026-10-17。本目录是一次独立场景验证的完整记录：真实 `.pftrace` 采集 + Trace Processor v58.2 SQL 分析 + Perfetto UI 打开尝试。**没有修改冻结版 Skill，没有修改生产业务/内核配置。**

- 冻结候选：`v2_modify/candidate-v1.0.2/` @ `0fa17e08eb8b93a9944232e380c7ddb39666fcf2`
- 板端采集器：tracebox / heapprofd preload **v57.1-c59f57dd4**（ARM64，来自 SDK 预编译）
- 主机分析器：Perfetto Trace Processor **v58.2-add693d8b**（Ubuntu host）
- Perfetto UI：https://ui.perfetto.dev/（当前 stable v58.3，headless Chrome 实测打开）

## 结论速览

| 验收项 | 结论 |
|---|---|
| 数据采集 | **PASS** |
| RSS 时间线 | **PASS** |
| Native 分配归因 | **PASS** |
| malloc / mmap 覆盖差异 | **PASS** |
| Perfetto UI 展示 | **UNKNOWN** |

详见 [VISUAL_REPORT.md](VISUAL_REPORT.md)。

## 目录

| 路径 | 内容 |
|---|---|
| `src/memphase.c` | 测试程序源码（malloc 32 MiB / mmap 32 MiB 两阶段） |
| `build/memphase_arm64` | ARM64 构建产物（未 strip，供 heapprofd 符号化） |
| `BUILD.md` | 构建、部署、运行、拉回说明 |
| `configs/memphase-joint.pbtxt` | 实际使用的联合 TraceConfig（4 类数据源） |
| `scripts/frozen/` | 本次实际执行的冻结版脚本原样副本（`linux_heapprofd_session.sh`、`linux_session_lib.sh`、`host_pull.sh`） |
| `scripts/bin/scp` | 本次 host 侧测试包装（sshpass + legacy scp，不属于 Skill） |
| `scripts/run_analysis.sh` | 一次性运行全部 SQL 并落盘结果 |
| `traces/heap.pftrace` | **实际采集**的 trace（89,233 B） |
| `traces/memphase.log` | 程序阶段日志（CLOCK_BOOTTIME 标记 + RSS 采样） |
| `traces/heap.app.log` | 会话脚本捕获的程序 stdout/stderr（含 heapprofd 初始化日志） |
| `traces/heap.query.txt` | 采集时 tracebox `perfetto --query --long` 输出 |
| `traces/heap.status` / `heap.log` | 会话状态与 tracebox 日志 |
| `logs/` | 采集命令、板卡/主机环境、heapprofd 原始 dump 证据 |
| `sql/` | 实际执行的 SQL（冻结版 SQL 仅替换目标参数） |
| `sql_out/` | SQL 原始输出、1 s RSS CSV、TP 版本与 trace SHA |
| `charts/rss_curve_from_sql.png` | 由 SQL 数据绘制的 RSS 曲线（**不是 UI 截图**） |
| `ui/` | 真实 UI 打开证据截图与 UI 说明 |
| `SHA256SUMS.txt` / `SHA256_TRACE_CONFIG.txt` | 全目录与关键产物哈希 |

## 复现步骤

```bash
# 1) 构建 + 部署（见 BUILD.md）
# 2) 板端采集（见 BUILD.md；得到 /data/perf102v2/work/heap.pftrace）
# 3) 拉回
export SSHPASS=<password>; PATH=$PWD/scripts/bin:$PATH \
  sh scripts/frozen/host_pull.sh root@<board> /data/perf102v2/work traces \
  heap.pftrace memphase.log heap.app.log heap.log heap.status heap.query.txt
# 4) 分析（主机 TP v58.2）
TP=/root/code_1.0.20/tmp/perfetto582/linux-amd64/trace_processor_shell sh scripts/run_analysis.sh
# 5) UI
#    打开 https://ui.perfetto.dev/ → Open trace file → 选择 traces/heap.pftrace
```

## 边界声明

- 本目录中的 `.pftrace` 是板端真实 trace，仅保存在本机/私有目录；按任务要求，未上传公开 GitHub。
- 采样估计（heapprofd `count`）不等于精确 malloc 次数；dump 的 `ts` 不是逐次 malloc 时间。本 trace 的 dump 窗口塌缩（`dur=0`）属于 v57.1 采集器行为，已与分析能力分开评价。
- UI 只完成了“真实打开”，RSS 曲线/火焰图/SQL debug track 的自动操作未能可靠完成，整体标 **UNKNOWN**，不作为 Skill 缺陷。
