# UI 复核说明（手动 Perfetto UI）

本文件只描述**在真实 Trace 存在的数据上**如何手动复核；本轮未执行 UI 自动化；文末截图 `p19/p20-1/p20-2.png` 为用户侧 UI 复核证据（Skill 不默认 UI 自动化）。
打开的文件：`traces/cap-main-90s.pftrace`（应用采集）与 `traces/cap-sched-70s.pftrace`（含 sched）。

## 0. 先确认对象存在（不是承诺视图）

主 Trace 中实际存在的对象：

- 进程：`/userdata/perfetto-skill-lab/latency/pf-lat-case`（upid 1，pid 6692）。
- 线程：`pf-lat-0`(utid 2)、`pf-lat-1`(utid 3，preprocess)、`pf-lat-2`(utid 4，work)、`pf-lat-3`(utid 5，output)。
- 自定义 Track：`request lane 00` … `request lane 51`（52 条）、`q-pre lane 00`…、`q-work lane 00`…、`q-out lane 00`…。
- 事件：`lat.request.begin` / `lat.request` / `lat.request.end` / `lat.stage` / `lat.stage.result` / `lat.queue` / `lat.send` / `lat.receive`（各 1,800 或 5,400 条）。
- Counter：`lat.queue_depth.q_pre` / `lat.queue_depth.q_work` / `lat.queue_depth.q_out` 各 3,600 点（q_pre/q_work 恒 ≤1；q_out severe 期三角形、峰值 51）。UI 截图样例（用户侧提供）：`traces/p19.png`（q_out 三角形峰值 51）、`traces/p20-1.png`（severe 慢 output Slice = 85ms 66µs 750ns）、`traces/p20-2.png`（mild 慢 work Slice = 22ms 06µs）。

## 1. 复核 severe：慢 output 与超长 E2E

1. 打开 `cap-main-90s.pftrace`，定位 `pf-lat-3` 线程轨道。
2. 时间轴跳到 trace 开始后 ≈17.5 s（绝对 ts ≈7,606,814,332,511 ns；app 1116.0 s，severe 窗口起点；另两个 severe 窗口在 ≈47.5 s / ≈77.5 s，mild 窗口在 ≈1.5 s / ≈31.5 s / ≈61.5 s）。
3. 展开 `lat.stage`：可见一串 `output` Slice，每个 **≈85.07 ms**；窗口外同阶段为 **≈5.02 ms**。选中一个，详情中应看到 `stage_id=output`、`stage_instance_id=out-<rid>`、`request_id=<rid>`。
4. 到 `request lane NN` 找同 `request_id` 的 `lat.request`：窗口末请求（rid 22991）生命周期 **2.565 s**。
5. 到 `q-out lane NN` 找同请求的 `lat.queue`：**≈2.4696 s**。慢 Slice 只是 85 ms，真正的 2.47 s 在队列 Slice 上。再展开 `lat.queue_depth.q_out`：三角形峰值 51 在慢消化结束点（窗口#1 ≈ trace+23.5 s），随后 ≈5.1 ms 减 1 排空——与截图 `traces/p19.png` 一致（y 轴顶格 55 是刻度）。
6. 选中 `lat.send`（Instant）应出现 Flow 箭头指向对应 `lat.receive`；每请求 3 条。用 SQL 交叉：

```sql
-- analysis/custom-sql/flow-probe-1/query.sql（示例，读出 send→receive 的 flow）
SELECT f.id, f.slice_out, f.slice_in FROM flow f
JOIN slice a ON a.id=f.slice_out JOIN slice b ON b.id=f.slice_in
WHERE a.category='rdk.latency' OR b.category='rdk.latency' LIMIT 20;
```

## 2. 复核 severe：线程状态（cap-sched）

1. 打开 `cap-sched-70s.pftrace`，选中 `pf-lat-3` 上一个 dur>50 ms 的 `output` Slice。
2. 打开 CPU / Thread State 轨道（或执行 `analysis/custom-sql/v58-slice_states-sched/query.sql` 对应查询），应看到：
   - 先 `Running` ≈5 ms；
   - 然后 `S` ≈5.04 ms → `R` ≈40 µs → `Running` ≈35 µs，重复约 16 次；
   - 期间没有长 `Running`、没有长 `R`。
3. 同一 Trace 中选 `pf-lat-2` 上 dur>15 ms 的 `work` Slice：几乎全程 `Running`（≈21.85 ms），对比明显。

## 3. 复核 mild：work 变慢但队列不变

1. 主 Trace 跳到 trace 开始后 ≈1.5–4.5 s（绝对 ts ≈7,590,814,332,511 … 7,593,814,332,511 ns；app 1100.0–1103.0 s，mild 窗口）。
2. `pf-lat-2` 上 `work` Slice 变成 **≈22.01 ms**（平时 8.02 ms）；`q_pre/q_work/q_out` 仍 ≈0.03–0.2 ms，`output` 仍 5.0 ms。
3. 同请求 E2E ≈29.3 ms。

## 4. SQL 面板复核（避免把模板当已执行 SQL）

- 用 `analysis/main582/00-inventory/query.sql`、`01-events/query.sql`、`02-flow/query.sql`、`03-quality/query.sql`、`04-counters/query.sql`（`${CATEGORY}` 已被脚本替换为 `rdk.latency`）。
- 用 `analysis/main582/ui-request-track.sql`：Execute → Add debug track → Slice（ts/dur/name，单位 ns）。它只含严格合格请求，是派生视图，不是新测量。
- 自定义窗口/阶段/状态叠加 SQL 在 `analysis/custom-sql/`（每条都带 `query.sql`/`stdout.csv`/`stderr.txt`/`run.json`，可复算）。

## 5. 看图纪律（Skill 要求）

- Slice 长度 = 墙钟；`lat.request`/`lat.stage` 所在 Track（自定义 / 线程）不同，不能拿“最长 Slice”当关键路径。
- 队列等待、阶段墙钟、CPU/Running 是不同维度，不相加当 E2E。
- 队列深度直接看现成的 `lat.queue_depth.*` Counter（q_out 峰值 51；q_pre/q_work ≤1）。
- 阶段在自定义 Track 上时不要虚构唯一执行线程；本 Trace 的 `lat.stage` 确实在 `thread_track` 上（`thread_utid` 非空），可直接与 Thread State 对齐。
