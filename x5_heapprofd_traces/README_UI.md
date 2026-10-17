# 在 Perfetto UI 查看这两份 X5 trace

交付目录里有：
- `x5_heapprofd_A_no_tick.pftrace`（实验 A：无 tick）
- `x5_heapprofd_B_tick_200ms.pftrace`（实验 B：持有期每 200 ms 一次 4 KiB malloc/free）
- `A_heap_live.csv` / `B_heap_live.csv`（可直接用于 Add debug track 的数据）
- `A_accept_results.txt` / `B_accept_results.txt`（accept.sql S1–S8 结果）
- `A_memprobe.log` / `B_memprobe.log`（程序自身事件日志）

数据来源：X5（`6.1.83-DR-PL5.1_V1.0.20`，aarch64，glibc 2.35），tracebox **v57.1**，heapprofd preload v57.1。
分析基线：**Trace Processor v58.2**（`v58.2-add693d8b`）。

---

## 1. 打开 trace

1. 浏览器打开 <https://ui.perfetto.dev/>
2. 左侧 **Open trace file**（或直接把 `.pftrace` 拖进页面）。
3. 文件在本地解析，**不会上传**。
4. 打开后先看 Timeline 顶部时间范围；A 组约 12.7 s，B 组约 13.6 s。

## 2. 找到 memprobe 进程与 Native Heap Profile

1. 在 Timeline 左上角搜索框输入 `memprobe`。
2. 会看到**两个同名进程**（都是 `/data/memprobe`）：这是 preload 客户端 fork 出的 heapprofd 子进程继承了 cmdline，**属正常现象**。
   - A 组：有 heap 数据的是 **UPID 191**（pid 1062）
   - B 组：有 heap 数据的是 **UPID 192**（pid 1123）
   - 另一个同名的没有 heap 数据（可在 `accept.sql [S1]` 输出里看到 `dumps` / `alloc_rows` 为 0）。
3. 展开有数据的那个进程，找 **`Native heap profile`** 轨道：
   - A 组：**只有 1 个 slice**
   - B 组：**6 个 slice**（每 ~2 s 一个）

## 3. 选择指标看 Flamegraph

点击 `Native heap profile` 轨道里的一个 slice，右上角/顶部会出现指标选择器：

- **Unreleased Malloc Size** —— "到该 dump 结束为止仍未被 free 的分配"估计值（最接近"持有量"）
- **Total Malloc Size** —— 累计分配量（含后来已释放），用于看"分配流量"
- 另有 `Unreleased/Total Malloc Count`（按次数）
- 火焰图：**X 轴宽度 = 所选指标的字节/次数**（不是耗时），**Y 轴 = 调用栈深度**

预期能看到（实测已确认）：
- A/B 组都能看到 `probe_live_block`、`probe_churn_cycle`；
- B 组还能看到 `probe_tick_alloc`（每 200 ms 的 4 KiB 对照分配）；
- 其上方是 `main` → `__libc_start_main` → `_start`；叶子层是 `libheapprofd_glibc_preload.so` 里的 malloc hook 帧（部分无名）。

## 4. 用 SQL → Add debug track 绘制 Heap Live 曲线

1. 左侧 **Query (SQL)**。
2. 粘贴 `heap_live_timeline.sql` 的内容（v58.2 版本），执行（`Ctrl/Cmd+Enter`）。
3. 结果区 → **Add debug track** → **Counter Track**：
   - Timestamp column = `ts`
   - Value column = `value`
   - Pivot on = `series`
4. `ts` 保持纳秒，不要转秒；`value` 单位 MiB。

也可以直接用交付的 CSV（把 Query 结果替换成 CSV 导入的 track 时，注意 `ts` 列是纳秒整数）。

**预期曲线**：
- A 组：**1 个点，0 MiB**（不是"内存没分配"，而是只有 1 份 dump，详见第 6 节）
- B 组：`8 → 8 → 8 → 0 → 0 → 0` MiB（3 个平台点 + 3 个回落点）

## 5. A/B 两组应重点观察的差异

| 观察项 | A（无 tick） | B（tick 200 ms） |
|---|---|---|
| `Native heap profile` slice 数 | **1** | **6** |
| Heap Live 曲线 | 单点 0 MiB | **8 MiB 平台 → 0** |
| `Total Malloc Size` | 28 MiB | 28.23 MiB（多出 60 次 × 4 KiB） |
| `Unreleased Malloc Size` | 0 | 峰值 8 MiB |
| 火焰图业务帧 | `probe_live_block` / `probe_churn_cycle` | 同上 + `probe_tick_alloc` |
| 程序日志 `ticks` | 0 | **60** |

## 6. 每张图能证明什么 / 不能证明什么

**Heap Live 曲线（SQL → Counter Track）**
- 能证明：在**有 dump 覆盖**的时间段内，`libc.malloc` 的未释放估计值随时间的变化。
- 不能证明：真实物理内存（RSS）；也不能证明"某个时刻没有内存"——**没有 dump 的时间段曲线是断的**，不能当 0 读。
- 注意：X5 用 tracebox **v57.1** 采集，v58.2 TP 下 `heap_profile.dur` 恒为 **0**（旧 producer 不 emit `start_timestamp`）。所以 dump 的**窗口区间不可知**，只有窗口结束时刻可用。这也是 `accept.sql` 的 `hold_bounds` 在 X5 上退化为零宽度的原因。

**Flamegraph（Total / Unreleased）**
- 能证明：哪些调用路径贡献了累计分配 / 未释放量（采样估计）。
- 不能证明：函数耗时（宽度不是时间）；也不能把祖先帧的累计量相加当总量（祖先会重复计入）。
- A 组即使曲线为空，**Flamegraph 仍能看到 `probe_live_block` 的 8 MiB**（因为分配确实发生了，只是一次 dump 内被 alloc+free 抵消）。

**dump 数量本身**
- 能证明采集侧确实产生了多少份 dump。
- 不能证明"持有期间内存没变化"——A 组只有 1 份 dump 是 heapprofd 的 `window_end` 只随**分配**推进所致（free 以 timestamp=0 提交），不是内存行为异常。

## 7. 如果看不到 Heap Profile 或 dump 缺失，怎么排查

1. **进程名**：`process_cmdline` 必须等于可执行文件名（basename）。本实验部署为 `/data/memprobe`，配置写 `memprobe`。
2. **preload 是否生效**：板上 `grep libheapprofd_glibc_preload /proc/<pid>/maps`；`board_run.sh` 第 5 步会打印。
3. **同名双进程**：确认看的是**有 dump 的那个 UPID**（另一个是 heapprofd 子进程）。
4. **会话与统计**：`accept.sql [S7]` 与 `stats` 表检查 `heapprofd_buffer_overrun*`、`heapprofd_client_error*`、`data_loss`；本实验这两个为 0。
5. **dump 太少**：若持有期没有持续分配，dump 会被去重成 1 份（A 组现象）。需要多 dump 时，在持有期保留**低开销周期分配**（B 组做法，`MEMPROBE_TICK_MS=200`，共 60 次 × 4 KiB）。
6. **dur=0**：这是 v57.1 producer 不写 `start_timestamp` 的已知现象；升级到 v58.2 采集侧才会出现非零 dur（x86 v58.2 实测 dur≈2000 ms）。
7. **SQL 包不存在/报错**：本目录 SQL 只用 `heap_profile` / `heap_profile_allocation` / `stack_profile_*` / `stats`，不含 `INCLUDE PERFETTO MODULE`，v58.2 TP 直接可跑。
