# RESULT — X5 Perfetto v58.2 快速采集验证

目的：在 RDK X5 上复用 `v3_test/` 的测试程序、TraceConfig 与冻结采集脚本，仅把板端
`tracebox` / `libheapprofd_glibc_preload.so` 换成官方 **v58.2 ARM64** 版本，采一份
`.pftrace`，与 v57.1 的窗口行为做最小对比。

## 1. 版本与文件

| 项 | 值 |
|---|---|
| 板卡 | RDK X5 `Linux buildroot 6.1.83-DR-PL5.1_V1.0.20 aarch64` |
| 板端采集器 | `tracebox` **Perfetto v58.2-add693d8b**，ELF 64-bit ARM aarch64 |
| tracebox SHA-256 | `2d21883e9c55818f851fd8c391afb9b366032b3110076b4fd41f31f30b5849fa` |
| 板端 preload | `libheapprofd_glibc_preload.so` **v58.2-add693d8b**，ELF ARM aarch64 |
| preload SHA-256 | `4ca10d32455973389d0f772f1c9ad8616b61eb46edc3b995a2825dee9fab2662` |
| 主机分析器 | Trace Processor **v58.2-add693d8b** |
| 测试程序 | 复用 `v3_test/build/memphase_arm64`，SHA-256 `455fd5292ec3e0689e5e1482b70d829a1eaeea2340f702eec095af8eaaf23b01` |
| TraceConfig | 复用 `v3_test/configs/memphase-joint.pbtxt`，SHA-256 `d696e85414dc712cd33c5b2a6c3feeac705b928daf84aea74fb958eeb6731d85` |
| 采集脚本 | 复用 `v3_test/scripts/frozen/linux_heapprofd_session.sh`（未修改） |

下载来源：

- https://commondatastorage.googleapis.com/perfetto-luci-artifacts/v58.2/linux-arm64/tracebox
- https://commondatastorage.googleapis.com/perfetto-luci-artifacts/v58.2/linux-arm64/libheapprofd_glibc_preload.so

两个文件下载后经 `file` 确认为 ARM aarch64、`strings` 确认为 `v58.2-add693d8b`；板端
`tracebox --version` 再次确认 v58.2。

## 2. 采集

参数与 v3_test 完全一致：`duration_ms=90000`、`OBSERVE_S=45`、
`sampling_interval_bytes=4096`、`dump_interval_ms=5000`；程序流程仍为
baseline → malloc 32 MiB（逐页写入、保持 6 s、free）→ idle 5 s →
mmap 32 MiB（逐页写入、保持 6 s、munmap）→ idle 5 s → tail。

板端独立目录 `/data/v58quick/`（tmpfs），未覆盖任何 v57.1 文件。

```bash
sshpass -p <BOARD_PASSWORD> ssh root@<BOARD_IP> 'cd /data/v58quick && \
  WORK=/data/v58quick/work TRACEBOX=/data/v58quick/bin/tracebox OBSERVE_S=45 \
  sh /data/v58quick/scripts/linux_heapprofd_session.sh \
     /data/v58quick/cfg/memphase-joint.pbtxt \
     /data/v58quick/bin/libheapprofd_glibc_preload.so \
     /data/v58quick/app ./memphase /data/v58quick/work/memphase.log'
```

采集结果：

| 项 | 值 |
|---|---|
| SSH 退出码 | **0** |
| 会话脚本输出 | `tracebox_pid=3421` / `DONE size_bytes=90728` |
| 失败码 | 无（非 rc=6/7/8） |
| Trace 大小 | **90,728 B** |
| Heap trace SHA-256 | `3232c4552a88b6bdc98d22387b9e28c3afaed089639d17ba13efd65b5cc75b73` |
| 板端/主机哈希一致性 | 一致（板端 `sha256sum` 已核对后删除板端目录） |

## 3. Trace Processor v58.2 最小检查

### 3.1 解析与范围

```sql
SELECT start_ts, end_ts, (end_ts - start_ts) / 1e9 AS dur_s FROM trace_bounds;
```

| start_ts | end_ts | dur_s |
|---|---|---|
| 34224596399486 | 34273476487301 | **48.880088** |

Trace 可正常解析，无解析错误。

### 3.2 目标进程

```sql
SELECT upid, pid, name FROM process WHERE name LIKE '%memphase%' ORDER BY upid;
```

| upid | pid | name |
|---|---|---|
| **186** | **3432** | `./memphase`（目标） |
| 188 | 3435 | `./memphase`（preload fork 的 heapprofd 辅助子进程） |

### 3.3 heap_profile 行数与 dur

```sql
SELECT ts, ts_end, dur, upid, heap_name FROM heap_profile;
```

| ts | ts_end | dur | upid | heap_name |
|---|---|---|---|---|
| 34224180976110 | 34229190976112 | **5,010,000,002 ns ≈ 5.010 s** | 186 | `libc.malloc` |

行数 **1**，`dur` **5,010,000,002 ns**（≈ 一个 `dump_interval_ms=5000` 的窗口）。

### 3.4 heap_profile_allocation

```sql
SELECT COUNT(*) AS rows,
       SUM(CASE WHEN size > 0 THEN size ELSE 0 END) AS pos_bytes,
       SUM(CASE WHEN size < 0 THEN -size ELSE 0 END) AS neg_bytes
FROM heap_profile_allocation;
```

| rows | pos_bytes | neg_bytes |
|---|---|---|
| **2** | **33,554,432** | **33,554,432** |

即 32 MiB 分配与释放各一条记录，与 v3_test 的 workload 一致。

### 3.5 采集端 dump 计数（补充）

`heapprofd_unwind_samples = 9`，即采集器仍发出 9 份 dump；因 `window_end` 仍只随分配推进
（本场景 malloc 后不新分配，free 不推进），`(upid, window_end, heap_name)` 去重后可见 1 行。

## 4. 与 v57.1 的最小对比

| 项 | v57.1（v3_test） | v58.2（本次） |
|---|---|---|
| `heap_profile` 行数 | 1 | **1** |
| `heap_profile.dur` | **0**（无窗口起点） | **5,010,000,002 ns** |
| `heap_profile_allocation` 行数 | 2 | 2 |
| 正/负字节 | ±33,554,432 | ±33,554,432 |
| Trace 大小 | 89,233 B | 90,728 B |

结论：v58.2 采集器提供了窗口起点，`dur` 由 0 变为约 5.01 s；行数仍为 1 是
`window_end` 未前进导致的去重，不是采集失败。本次只做版本对比，不扩展分析。

## 5. 文件

| 文件 | 说明 |
|---|---|
| `heap.pftrace` | 真实采集的 v58.2 trace（90,728 B） |
| `heap.log` | 会话脚本 tracebox 日志 |
| `heap.app.log` | 程序 stdout/stderr（含 heapprofd 初始化日志） |
| `memphase-joint.pbtxt` | 实际使用的 TraceConfig（与 v3_test 相同） |
| `capture_console.txt` | 采集 SSH 输出（退出码/DONE 证据） |
| `SHA256SUMS.txt` | 本目录文件 SHA-256（不含自身） |

采集完成后已删除板端 `/data/v58quick/`，未保留重复副本。
