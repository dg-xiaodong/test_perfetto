# v2_test — RDK X5 `worker_app` Perfetto 性能调试交付

本目录是 2026-10 一轮独立方案的全部交付物：针对 RDK X5 上 C++ 进程 `worker_app`
“RSS 稳定 180–200 MB、每隔几秒 CPU 上升且延迟抖动、怀疑临时对象频繁创建/销毁”的问题，
给出一套可执行的 Perfetto 采集、验收、SQL 与 UI 分析方案。

**本次只做方案与静态验证：未连接开发板、未修改业务程序、未采集真实 trace。**
文中所有“预期/待验证”都不是实测结果。

## 1. Skill 来源

- Skill：`perfetto-memory-debugging`
- 版本：`1.0.1` Candidate
- Git 提交：`f16f68ae1e3f112794af3b953881d1b18fa8415e`
- 候选目录：`v1_modify/candidate-v1.0.1`（本仓库）
- `SKILL.md` sha256：`70371e5bcbe06e8efdc9c47578111989001ad33d787106de649430bab53275d0`
- 未使用部署的 v1.0.0（`SKILL.md` sha256 为 `4f5f6ae9...`，与候选版不同）。

## 2. 目录

```text
v2_test/
├── README.md
├── PLAN.md                      完整方案：假设、选路、配置、操作、验收、SQL、UI、因果判据、降级
├── configs/
│   ├── C1-worker-timeline.pbtxt      低开销时间线（sched/RSS/DVFS/reclaim）
│   ├── C2-worker-native-alloc.pbtxt  heapprofd native allocation 归因
│   └── C3-worker-cpu-profile.pbtxt   linux.perf CPU 调用栈归因
├── sql/
│   ├── 10-cpu-thread-buckets.sql
│   ├── 11-runnable-and-blocked.sql
│   ├── 12-native-dump-timeline.sql
│   ├── 13-native-callsite-hotspots.sql
│   ├── 14-perf-hot-functions.sql
│   ├── 15-perf-allocator-share.sql
│   ├── 16-perf-spike-vs-quiet.sql
│   ├── 17-alloc-vs-cpu.sql
│   ├── 18-data-quality.sql
│   ├── 19-cpu-frequency.sql
│   └── 20-jitter-cycles.sql
├── validation/
│   ├── VALIDATION.md                   本次静态验证记录
│   └── trace_config-v58.2.desc         本机 v58.2 源码生成的 TraceConfig descriptor
└── SHA256SUMS
```

## 3. 建议阅读顺序

1. `PLAN.md` 第 1–2 节：问题、假设、数据源选路。
2. `PLAN.md` 第 3 节：三份完整 TraceConfig 与参数依据。
3. `PLAN.md` 第 4–5 节：主机/板端执行、验收。
4. `PLAN.md` 第 6–8 节：SQL、UI、因果判据。
5. `PLAN.md` 第 9–11 节：降级、已验证/未验证、最小下一步。

## 4. 最小执行顺序

- **C1**（30 s）：先确认抖动是否真实、周期多少、是否有 reclaim/compaction/DVFS 混淆。
- **C3**（30 s）：若 C1 指向用户态 CPU，找热点函数与 allocator 占比。
- **C2**（45 s）：若 C3 显示 allocator 占比在抖动窗上升，重启**测试实例**并在
  `LD_PRELOAD` 下采集 heapprofd，归因到 callsite。

C1/C3 可对已运行进程采集；C2 需要 preload 在进程启动时加载，只能用于允许重启的测试实例。

## 5. 静态验证状态

| 项 | 状态 |
|---|---|
| Skill 候选版路径/版本/commit/sha | 已验证 |
| `validate_config.py --check-resources` | PASS（27 个必需文件 + 10 个配置） |
| C1/C2/C3 对 v58.2 descriptor 的 schema 校验 | PASS |
| v57.1 descriptor 校验 | **未执行**（本地无 v57.1 descriptor） |
| SQL 语法在本机 v58.2 TP 上执行 | 已执行（仅表/语法，不用于 worker_app 结论） |
| 板端 tracebox/survey/heapprofd/perf 运行 | **未执行** |
| Perfetto UI 截图/实际显示 | **未执行** |
| 实际性能因果 | **未证明** |

详见 `validation/VALIDATION.md`。

## 6. 版本与能力注意

- 板端 tracebox v57.1；主机 Trace Processor v58.2；UI 版本可能更新。
- v57.1 采集端不发布 heapprofd `start_timestamp`，v58.2 TP 上常见
  `heap_profile.dur = 0`。这不等于采集失败，只意味着精确持有区间不可判；
  总量、分配/释放、dump 数仍可判。使用 `sql/10-native-dump-capability.sql` 检查。
- Linux 上 `android.heapprofd` 由 `libheapprofd_glibc_preload.so` fork 的
  kChild producer 注册；`tracebox` 二进制本身不注册该数据源，不需要单独
  heapprofd daemon，但需要与 tracebox 匹配的 preload 版本。
- `linux.perf` 需要 perf_event_open 权限；无权限时退回 sched + process runtime，
  只能做等待/CPU 归因，不能做函数级火焰图。

## 7. 明确边界

- 不包含任何真实采集结果、性能数字或 UI 截图。
- 不包含对 `worker_app` 的代码修改。
- 不声称已在 X5 上跑通 C1/C2/C3。
- 配置中的 `worker_app`、事件名、buffer 大小需按实际板端 `available_events`、
  `nproc`、`/data` 余量与 target cmdline 调整。
