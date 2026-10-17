# v2_modify2 测试记录

- 日期：2026-10-17
- 主机 Trace Processor：`Perfetto v58.2-add693d8b`
- 测试 trace（仅用于 SQL 逻辑，不是 `worker_app`）：
  - `combined_traceput.pftrace` sha256 `56b42293e757f273c182091c8cf8517eededc9d9b7de2112518930e4cbba8663`
- 原始输出：`validation/tests/outputs/`。

## 1. 仓库根执行路径 dry-run

```bash
sh v2_modify2/validation/tests/path_dryrun.sh
```

实际输出：

```text
PASS: repo-root paths exist
== C1 via v2_modify/scripts from repo root ==
C1 started tracebox_pid=...
C1 DONE size_bytes=14
PASS: C1 root-relative script/config
== host_pull via v2_modify/scripts from repo root ==
PULL OK: C1.pftrace ...
PULL OK: C1.log ...
PULL OK: C1.status ...
PASS: host_pull root-relative script
```

验证点：

- 从 clone 根目录能找到 `v2_modify/configs/`、`v2_modify/scripts/`、
  `v1_modify/candidate-v1.0.1/`、`v2_modify2/sql/20-jitter-cycles.sql`；
- `remote_c1.sh` 从根目录执行成功；
- `host_pull.sh` 从根目录执行成功。

边界：mock tracebox，不是板端采集。

## 2. 20 的 900–1100 ms / 200 ms / 150 ms 反例

```bash
TP query -f v2_modify2/validation/tests/jitter_bucket_intersection_test.sql \
  combined_traceput.pftrace
```

实际输出：

```text
"logic","name","bucket","ms","spike"
"FIXED","A_200ms_900_1100",0,100.000000,0
"FIXED","A_200ms_900_1100",1,100.000000,0
"OLD","A_200ms_900_1100",0,200.000000,1
"FIXED","B_350ms_900_1250",0,100.000000,0
"FIXED","B_350ms_900_1250",1,250.000000,1
"OLD","B_350ms_900_1250",0,350.000000,1

"case_name","old_spike","fixed_spike"
"A_200ms",1,0
"B_350ms",1,1
```

期望/实际：

- 200 ms 跨 900–1100 ms：FIXED 两个桶各 100 ms，均不 spike；OLD 在第 0 秒
  记 200 ms，产生假 spike。
- 350 ms 跨 900–1250 ms：FIXED 第 1 秒 250 ms，正确 spike；OLD 整段记第 0 秒。

## 3. 修正后 20 在真实 trace 上的正例

```bash
# target=cam-service, spike_cpu_ms=5
TP query -f /tmp/q20r2.sql combined_traceput.pftrace
```

实际输出：

```text
"ts","dur","first_bucket_s","last_bucket_s","buckets_in_episode","peak_cpu_ms","avg_cpu_ms"
133248075771,12000000000,0,11,12,59.316875,53.688805
```

说明：查询能按区间交集得到每秒 CPU，并输出一个 episode。该 trace 不是 `worker_app`，
不能用于性能结论。

## 4. 未验证

- 未上板，未运行真实 tracebox/heapprofd/perf。
- 合成反例不经过真实 `sched_slice` 表，只验证与 `sql/20` 相同的区间数学和旧/新逻辑。
- 未验证 v57.1 descriptor、C2 真实生命周期、UI。
- 未修改或部署 Skill。
