# pf-mem-case v2.0.0 内存排查报告（RDK X5 / Perfetto）

- 目标：`/userdata/perfetto-skill-lab/memory/pf-mem-case`，**v2.0.0**，SHA256 `7a5290c2d400c21b0b43aaf334bf989c1d9a6035de8582afa0cdd5a528509fcf`，BuildID `849a52c2…`
- 板卡：X5，`6.1.83-DR-PL5.1_V1.1.1` aarch64，glibc 2.35
- 采集器：`tracebox v57.1-c59f57dd4`；分析器：`trace_processor_shell v57.1`（主机）
- 结论：**确认是真泄漏（无上限匀速增长）**，不是缓存预热后平台化；函数级调用链由 heapprofd 与静态分析互证

> 与 v1.0.0 报告的关系：v1 的“三个容量上限、爬升后平台化”结论**不适用**于 v2.0.0。本文件是新结论。

---

## 1. 结论

`pf-mem-case` v2.0.0 的 RSS 以 **≈0.2 MiB/s（12 MiB/min）** 持续上升，没有平台期。增长来源是一个**指针被丢弃的 1 MiB 分配**：

```
SessionChannel::Run()         每 5 s 唤醒
  └─ SessionChannel::ExpireWindow()
       └─ CompletionRouter::Dispatch(true)
            └─ heap::Acquire(1 MiB)   →  malloc(1MiB+16) + memset('Z')
                 └─ 返回值丢弃：不保存、不 Release，只把计数器 +1
```

即 **每 5 s 泄漏 1 MiB，永不回收**（21 次/105 s 实测无一条释放记录）。进程只会在两种情况下停止：
① 默认 `--max-seconds 360`（6 min，日志 `stop reason=time limit`）；
② 活跃堆超过 **256 MiB**（`LiveBytes() > 0x10000000`）触发内置 guard，打印 `memory guard reached` 并以 `rc=3` 退出。

另外两处分配是**有界或瞬态**，不是泄漏来源：
| 路径 | 行为 | 结论 |
|---|---|---|
| `ObjectCache::Insert()`（cache 线程） | 16 项 × 512 KiB = **8 MiB**，约 11 s 填满；之后每 1.5 s `Touch` 一项 | 有界，进程退出才释放 |
| `FrameSpool::BuildBatch()`（spool 线程） | 每 11 s 申请 **6 × 1 MiB**，保持 2 s 后 `ReleaseBatch()` 全部释放 | 瞬态，RSS 摆动 6–8 MiB |

### 1.1 默认运行的实际结局（实测，断电重启后重跑）

```
pf-mem-case 2.0.0 start pid=1081 max_seconds=360
… heartbeat 30…330
pf-mem-case stop reason=time limit
pf-mem-case exit uptime_s=360 rc=0
```

- RSS 轨迹：启动 6.4 MiB → 45 s 时 20.2 MiB → 314 s 时 72.3 MiB → **峰值 88,000 KiB（85.9 MiB）**，随后到 360 s 自行退出（退出时全部释放，所以事后看“内存又正常了”）。
- 与泄漏速率对账：`(360 s / 5 s) × 1 MiB ≈ 70 MiB`，加 cache 8 MiB + 解释器/库开销 ≈ **86 MiB**，与实测 85.9 MiB 吻合。
- 若用户把它当常驻服务（`--max-seconds` 调大或改死循环），增长不会停：约 21 min 后撞 256 MiB guard（`memory guard reached`, `rc=3`），或被系统 OOM 杀掉。

---

## 2. 证据链

### 2.1 计数器：真增长，不是抖动（`v2-overview.pftrace`，90 s）

按 upid 聚合的 anon RSS，按 10 s 窗口统计 min/max：

| 窗口(s) | min(MiB) | max(MiB) | swing |
|---|---|---|---|
| 0–10 | 26.10 | 34.04 | 7.94 |
| 10–20 | 28.16 | 36.10 | 7.94 |
| 20–30 | 30.22 | 37.95 | 7.73 |
| 30–40 | 32.29 | 39.76 | 7.47 |
| 40–50 | 34.09 | 39.96 | 5.88 |
| 50–60 | 36.15 | 42.03 | 5.88 |
| 60–70 | 38.21 | 45.12 | 6.91 |
| 70–80 | 40.28 | 47.18 | 6.91 |
| 80–90 | 42.08 | 48.99 | 6.91 |

- **谷底单调上升 +1.98 MiB/10 s ≈ 0.2 MiB/s** → 泄漏（不是平台化）；
- **摆动 6–8 MiB** → spool 每 11 s 的 6 × 1 MiB 批次（保持 2 s）。

### 2.2 heapprofd：函数级定位（`v2-heap2.pftrace`，120 s，断电重启后重采）

配置：`android.heapprofd`（`process_cmdline: pf-mem-case`、`sampling_interval_bytes: 4096`、`continuous_dump_config{dump_phase_ms:5000,dump_interval_ms:5000}`、`all_heaps:true`）+ `linux.process_stats`。
启动方式：`tracebox --system-sockets --background-wait …`，目标直接 `LD_PRELOAD=./libheapprofd_glibc_preload.so ./pf-mem-case`（**不要**再套 `nohup/setsid`）。

47 行 `heap_profile_allocation`，按 callsite 聚合后三条链清晰分离：

| callsite | 业务链（帧名） | 行数 | 合计 | 判读 |
|---|---|---|---|---|
| **21** | `…::Dispatch ← SessionChannel::ExpireWindow ← SessionChannel::Run ← thread` | 21 | **+23,069,024 B** | 每 5 s 一行 `1,048,592 B`（1 MiB + 16 B 头），**窗口内无对应负值行** = 未释放 |
| 12 | `ObjectCache::Insert ← Store ← CacheChannel::WarmStep ← CacheChannel::Run` | 4 | +8,388,864 / −8,388,864 | 16 × 524,304 B，唯一一次释放出现在 **t=100 s（进程被杀/退出）** = 有界缓存 |
| 30 | `FrameSpool::BuildBatch ← SpoolChannel::Cycle ← SpoolChannel::Run` | 22 | 0（+6,291,552 / −6,291,552 成对） | 每轮 6 MiB，2 s 后释放 = 瞬态 |

callsite 21 的逐行时间戳（相对首行）：`0, 5, 10, 15, 23, 25, 34, 35, 45, 45, 50, 56, 60, 67, 70, 78, 80, 89, 90, 100, 100` —— **严格 5 s 节奏、只增不减**，与 §1 的代码路径完全一致（首行 `2,097,184 B` 是两次分配被 dump 合并）。

### 2.3 静态确认（反汇编，v2.0.0）

```
SessionChannel::Run:     周期常量 0x1_2A05_F200 = 5,000,000,000 ns (5 s)
SessionChannel::ExpireWindow → CompletionRouter::Dispatch(1)
CompletionRouter::Dispatch(bool):
    x0 = router->size (构造参数 0x100000 = 1 MiB)
    bl heap::Acquire
    cbz w20, .free_path      ; flag==false → 写 0x33 后 heap::Release
    ; flag==true  → [router+16] += 1，函数返回，指针丢失  ← 泄漏点
ObjectCache 构造: ObjectCache(0x10, 0x80000) = 16 项 × 512 KiB = 8 MiB
FrameSpool 构造:  FrameSpool(0x6, 0x100000)  = 6 批 × 1 MiB
SpoolChannel::Cycle: BuildBatch → nanosleep(2 s) → ReleaseBatch
CacheChannel::Run: 16 × 0.7 s 暖机（Insert）后，1.5 s 周期 Maintain/Touch
main: LiveBytes() > 0x10000000 (256 MiB) → "memory guard reached", rc=3；默认 max_seconds=360
heap::Acquire: malloc(size+16)，头部存 size，memset('Z')，原子累加 LiveBytes/TotalAcquired
```

---

## 3. 复现与采集（可直接照抄）

```bash
# 【目标机】同一时刻只能有一个 system-sockets tracing 实例
rm -rf /tmp/perfetto-*
tracebox --system-sockets --background-wait --txt \
  -c /userdata/pfwork/v2-heap.pbtxt -o /userdata/pfwork/v2-heap2.pftrace
# 关键：不要再套 nohup/setsid，也不要加 BLOCKING_INIT
LD_PRELOAD=./libheapprofd_glibc_preload.so ./pf-mem-case &
sleep 3; grep -c libheapprofd /proc/$!/maps     # 期望 7
```

> **踩坑记录**：`PERFETTO_HEAPPROFD_BLOCKING_INIT=1` 配合 `nohup`/`setsid` 会把**包装进程自己**卡在 preload 初始化（包装进程的 cmdline 不匹配 `process_cmdline`，服务端不会给它配置数据源），于是目标永远不会 exec，表现为“pgrep 找不到目标、trace 里没有该进程、日志里只有一串 `Disconnected from tracing service`”。去掉包装/blocking init 后一次通过。

分析 SQL（主机）：

```sql
SELECT callsite_id, COUNT(*) n, SUM(size) bytes FROM heap_profile_allocation GROUP BY 1 ORDER BY bytes DESC;
-- 再用 stack_profile_callsite 的 parent 链展开到函数名
```

---

## 4. 建议

1. **修 `CompletionRouter::Dispatch(true)`**：`heap::Acquire` 的返回值必须被持有（放进最近窗口队列并在 deadline 到期 `heap::Release`），否则每次调用就是 1 MiB 永久泄漏。
2. 若语义确实是“保留最近一个窗口的响应”，请加**容量上限 + 淘汰**（例如只保留 1–2 个），并复用 `ResponseBuffer` 而不是每次新建。
3. 把内置 guard 的 256 MiB 阈值降到设备预算内（当前默认 6 min 运行会涨到约 80 MiB 且用户看不到任何告警，只在 256 MiB 才打印一条）。
4. 长跑验证：`--max-seconds 1800` 应能看到 live 堆线性增长直至 `memory guard reached`（rc=3），以此确认 leak 与 guard 行为。

## 5. 证据等级

| 结论 | 等级 | 来源 |
|---|---|---|
| RSS 线性增长（谷底 +0.2 MiB/s，无平台） | 观测 | `v2-overview.pftrace`（`mem.rss.anon` 每 1 s） |
| 每 5 s 泄漏 1 MiB、窗口内无释放 | 观测 | heapprofd `heap_profile_allocation` callsite 21 |
| 泄漏路径 `Dispatch ← ExpireWindow ← Run` | 观测（heapprofd 调用栈） | `v2-heap2.pftrace` |
| cache 8 MiB 有界、spool 6 MiB 瞬态 | 观测 | callsite 12 / 30 的 ± 行配对 |
| guard 阈值 256 MiB、默认 360 s | 静态 | `main` 反汇编 + 字符串 |
