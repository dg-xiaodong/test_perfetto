# 修正版测试记录

- 日期：2026-10-17
- 主机 Trace Processor：`Perfetto v58.2-add693d8b`
- 测试目的：验证本轮 7 项修正中的 SQL 与脚本控制流；**不用于 worker_app 结论**。
- 原始输出：`validation/tests/outputs/`。
- 测试 trace 仅用于表/语法和区间数学验证，不是 `worker_app` 采集：
  - `combined_traceput.pftrace` sha256 `56b42293e757f273c182091c8cf8517eededc9d9b7de2112518930e4cbba8663`
  - `perf_cpu.pftrace` sha256 `27d2008ffe00dee75d3ff456625d0d453dd94338f1d13723553e2371ea111487`

## 1. Schema（v58.2 descriptor）

```bash
python3 <candidate>/scripts/validate_config.py configs/C1-worker-timeline.pbtxt \
  --descriptor-set validation/trace_config-v58.2.desc
# C2/C3 同样
```

结果：三份均 `[PASS] schema: parsed with supplied descriptor`。
边界：这不是 v57.1 descriptor 校验，也不证明运行期数据源存在。

原始输出：`outputs/schema_validation.txt`。

## 2. 10/11 区间交集：90/120 ms 跨 100 ms 边界（正例）

```bash
TP query -f validation/tests/bucket_overlap_test.sql combined_traceput.pftrace
```

实际输出（节选）：

```text
"A_90ms_cross",0,5000000
"A_90ms_cross",1,85000000
"B_120ms_cross",0,5000000
"B_120ms_cross",1,100000000
"B_120ms_cross",2,15000000
"C_exact_100ms",1,100000000
"D_250ms_span",0,50000000
"D_250ms_span",1,100000000
"D_250ms_span",2,100000000
"E_1ns_edge",0,1
"E_1ns_edge",1,999999

"name","dur","total_overlap_ns","diff_ns"
"A_90ms_cross",90000000,90000000,0
"B_120ms_cross",120000000,120000000,0
"C_exact_100ms",100000000,100000000,0
"D_250ms_span",250000000,250000000,0
"E_1ns_edge",1000000,1000000,0
```

期望：每个区间 `sum(overlap)==dur`，`diff_ns=0`；90/120 ms 均跨边界拆分。
实际：全部满足。

## 3. 10/11 旧逻辑 vs 修正逻辑（反例）

```bash
TP query -f validation/tests/bucket_overlap_old_vs_new.sql combined_traceput.pftrace
```

实际输出：

```text
"logic","bucket","ms"
"FIXED",0,5.000000
"FIXED",1,85.000000
"OLD",0,90.000000
```

期望：旧逻辑把 90 ms 全记到起始桶；修正逻辑拆成 5 ms + 85 ms。实际一致。

## 4. 真实 trace 的 90–120 ms sched slice

```bash
TP query -f validation/tests/real_trace_overlap_test.sql combined_traceput.pftrace
```

实际输出：

```text
"id","ts","dur","total_overlap_ns","diff_ns"
330,134020026855,98948542,98948542,0
683,134247831855,100901292,100901292,0
697,134251485230,113173708,113173708,0
1127,134503817855,92436584,92436584,0
5533,137146273106,115747459,115747459,0
```

期望：5 条跨桶 slice 的 `sum(overlap)==dur`。实际全部 `diff_ns=0`。
该测试只说明区间数学正确，不代表 `worker_app` 的 CPU 分布。

## 5. 20 抖动 episode：含安静间隔的反例

```bash
TP query -f validation/tests/jitter_cycles_counterexample.sql combined_traceput.pftrace
```

输入：1 s 桶 `0,1` 高；`2,3` 低；`4,5` 高；`6` 低。

实际输出：

```text
"logic","first_bucket_s","last_bucket_s"
"FIXED_splits",0,1
"FIXED_splits",4,5
"OLD_merges",0,5

"old_episode_count","fixed_episode_count"
1,2
```

期望：旧逻辑合并成 1 段（0–5），修正逻辑拆成 2 段（0–1、4–5）。实际一致。
`sql/20` 已改为先 `WHERE spike=1` 再 `ROW_NUMBER()`。

## 6. 16/16a：窗口必须属于被查询的 trace

### 6.1 合成窗口检查

```bash
TP query -f validation/tests/perf_window_guard_test.sql combined_traceput.pftrace
```

实际：

```text
"name","window_check"
"inside","OK"
"outside","OUT_OF_TRACE"
```

### 6.2 真实 trace 的有效窗口

```text
16a with offsets 1000/2000/3000/4000 ms
"window_check"
"OK"
```

### 6.3 真实 trace 的越界窗口

```text
16a with offsets 20000/21000/22000/23000 ms
"window_check"
"OUT_OF_TRACE"
```

### 6.4 16 在 perf trace 上按本 trace 相对窗口取样

```bash
# target 改为测试进程 dd；窗口为 1000-2000 ms / 3000-4000 ms
TP query -f /tmp/q16test.sql perf_cpu.pftrace
```

实际输出含 `spike` / `quiet` 两组函数样本（见 `outputs/16_perf_sample.txt`）。
这只验证查询能按本 trace 窗口筛选；具体热点属于测试 trace 的 `dd`，与 `worker_app` 无关。

## 7. Shell 生命周期 dry-run（mock，不上板）

```bash
sh validation/tests/shell_lifecycle_dryrun.sh
```

实际输出：

```text
== C2 lifecycle dry run ==
C2 started tracebox_pid=...
C2 started app_pid=...
C2 heapprofd producer visible
C2 DONE size_bytes=11
PASS: C2 lifecycle, trace non-empty
== C1/C3 completion dry run ==
C1 DONE size_bytes=21
C3 DONE size_bytes=21
PASS: C1/C3 completion, non-empty outputs
== remote_stop dry run ==
STOP OK: C1 size_bytes=21
STOP FAIL: missing .../MISSING.pid
PASS: missing pid propagated
== host_pull success ==
PULL OK: C1.pftrace size=21 sha256=...
PASS: pull success
== host_pull missing file ==
PULL FAIL: scp ...
PASS: pull failure propagated
== host_pull empty file ==
PULL FAIL: .../EMPTY.pftrace is missing or empty
PASS: empty file rejected
```

验证点：

- C2 不立即杀 app：先服务查询、起 app、等 `heapprofd`、`OBSERVE_S=2`、停 app、flush、
  SIGINT tracebox、非空检查。
- C1/C3 的后台 PID、完成、非空文件。
- `remote_stop.sh` 对已有 PID 成功 flush；对缺失 PID 返回非零。
- `host_pull.sh` 对成功文件返回 0；对 scp 失败返回非 0；空文件也返回非 0。

边界：mock 不是真实 tracebox；不能证明板端 `--system-sockets`、heapprofd 注册、
SIGINT flush 时序。真实板端仍标记未验证。

## 8. 未验证

- 未上板，未运行真实 `tracebox`/`survey.sh`/heapprofd/perf。
- 未验证 C2 `heapprofd` producer 真实可见性、flush 时长、`--system-sockets` 在 `/tmp`
  只读时的行为。
- 未验证 v57.1 descriptor。
- 未验证 `worker_app` 的真实 trace、符号、UI。
- 未证明任何性能因果关系。
