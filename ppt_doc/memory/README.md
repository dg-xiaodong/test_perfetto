# pf-mem-case 内存排查（RDK X5 / Perfetto）

对 perfetto skill lab 测试程序 `pf-mem-case` 两个版本的内存问题排查存档：报告、heapprofd/计数器 trace、采集配置。

采集环境：RDK X5（`6.1.83-DR-PL5.1_V1.1.1`，aarch64，glibc 2.35）+ `tracebox v57.1-c59f57dd4`（arm64）+ `libheapprofd_glibc_preload.so`；主机侧 `trace_processor_shell v57.1` 分析。

## 结论速览

| 版本 | 现象 | 结论 |
|---|---|---|
| **v1.0.0** | RSS 约 90 s 内爬到 46 MiB | **不是泄漏**：三个容量有上限的累积点（ObjectCache 16×512 KiB=8 MiB、DeferredStore 28×1 MiB=28 MiB、FrameSpool 8 MiB 瞬态），到顶后长期稳定，进程退出才释放。详见 [REPORT.md](REPORT.md) |
| **v2.0.0** | RSS 以 ≈0.2 MiB/s（12 MiB/min）持续上升，无平台 | **真泄漏**：`SessionChannel::Run`(5 s) → `ExpireWindow()` → `CompletionRouter::Dispatch(true)` → `heap::Acquire(1 MiB)`，返回值被丢弃、从不 Release。默认 360 s 退出前峰值 85.9 MiB；内置 guard 为 LiveBytes>256 MiB。详见 [REPORT-v2.md](REPORT-v2.md) |

## 目录

```
ppt_doc/memory/
├── REPORT.md            v1.0.0 排查报告（有界缓存 → 平台化）
├── REPORT-v2.md         v2.0.0 排查报告（真泄漏，heapprofd 函数级定位）
├── rss_curve.svg        v1 实测 RSS 曲线（爬升→平台期）
├── traces/
│   ├── v1.0.0/
│   │   ├── overview60.pftrace   60 s 增长段：process_stats(1s)+sys_stats+kmem/rss_stat
│   │   ├── growth.pftrace       120 s 全程：rss_stat+syscalls(mmap/brk/madvise)+sched+perf
│   │   ├── growth2.pftrace      180 s：rss_stat+mprotect（证明增长期只有 arena 扩容、无新 mmap）
│   │   └── plateau60.pftrace    平台期对照：61 个采样点 RSS 方差为 0
│   └── v2.0.0/
│       ├── v2-overview.pftrace  90 s 增长段：RSS 谷底 +1.98 MiB/10 s，叠加 6–8 MiB spool 摆动
│       └── v2-heap2.pftrace     120 s heapprofd：22 个 dump，泄漏 callsite
│                               (Dispatch ← ExpireWindow ← SessionChannel::Run) 21×1 MiB 无释放
└── configs/             与 trace 同名对应的采集 pbtxt
```

## UI 复看

1. 打开 <https://ui.perfetto.dev>，拖入 `.pftrace`。
2. v2 泄漏：搜 `pf-mem-case` → 选 `./pf-mem-case`（v2-heap2 里选 **PID 1059**）→ `Native heap profile` 轨道点 dump 切片 → 火焰图 metric 选 **Unreleased Malloc Size** → 最宽路径即泄漏链。
3. RSS 趋势：`Memory > mem.rss / mem.rss.anon`（watermark 单调上升也是泄漏的旁证）。

## 采集要点（X5 standalone Linux + heapprofd）

1. `tracebox` 必须 **`--system-sockets`**，否则 preload 连不上服务（`Disconnected from tracing service`）。
2. 同一时刻**只能有一个** system-sockets tracing 实例；失败后先清 `/tmp/perfetto-*`。
3. 目标启动**不要套 `nohup`/`setsid` 包装，也不要 `PERFETTO_HEAPPROFD_BLOCKING_INIT=1`**：包装进程自己会加载 preload 并卡在 init（cmdline 不匹配 `process_cmdline`），目标永远不会 exec。直接 `LD_PRELOAD=./libheapprofd_glibc_preload.so ./pf-mem-case &`，用 `/proc/<pid>/maps` 命中 preload 7 段确认。
4. 采集配置见 `configs/`；heapprofd 关键字段：`process_cmdline`、`sampling_interval_bytes: 4096`、`continuous_dump_config{dump_phase_ms:5000, dump_interval_ms:5000}`、`all_heaps: true`。
