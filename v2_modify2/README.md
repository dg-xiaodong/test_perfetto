# v2_modify2 — 最后两项定点修正（增量）

本目录是 `v2_modify/` 的**独立增量修正**，只处理两个已审核问题：

1. `PLAN.md` 的主机执行路径统一到 GitHub 仓库根目录。
2. `20-jitter-cycles.sql` 的 1 秒 CPU 桶改为区间交集。

`v2_test/` 与 `v2_modify/` 原样保留；本目录不重做性能方案，不修改 Skill，不上板。

## 1. 内容

```text
v2_modify2/
├── README.md
├── PLAN.md                        从仓库根执行的完整方案（路径已修正）
├── CHANGES.diff                   相对 v2_modify 的 unified diff
├── sql/
│   └── 20-jitter-cycles.sql       1 秒桶区间交集 + 先筛 spike 后编号
└── validation/
    └── tests/
        ├── jitter_bucket_intersection_test.sql
        ├── path_dryrun.sh
        ├── TEST_RECORD.md
        └── outputs/
```

未修改的配置、脚本、10–19/16a SQL 仍位于 `v2_modify/`。

## 2. 执行路径约定

所有主机命令从 **GitHub 仓库根目录** 开始：

- 配置：`v2_modify/configs/`
- 执行脚本：`v2_modify/scripts/`
- Skill 脚本/参考/SQL：`v1_modify/candidate-v1.0.1/`
- 本增量修改的 SQL：`v2_modify2/sql/20-jitter-cycles.sql`
- 本增量测试：`v2_modify2/validation/tests/`

`PLAN.md` 第 4 节以 `R=$(git rev-parse --show-toplevel); cd "$R"` 开头；
预检、scp、采集、拉回命令均按上述根相对路径书写。

## 3. 20 的修正

`sched_slice` 不再整段记到 `s.ts` 所在秒桶，而是：

```text
overlap = min(ts + dur, bucket_end) - max(ts, bucket_start)
```

然后按 `spike_cpu_ms` 标记，**先筛 spike 桶，再按 `bucket_s - ROW_NUMBER()` 编号**，
连续高 CPU 桶才合并为 episode。

反例：Running slice 900–1100 ms，dur=200 ms，阈值 150 ms：

```text
OLD:   bucket0 = 200 ms -> 假 spike
FIXED: bucket0 = 100 ms, bucket1 = 100 ms -> 无 spike
```

350 ms 正例：bucket0=100、bucket1=250 → 只有 bucket1 是 spike。

## 4. 已执行测试

| 测试 | 结果 |
|---|---|
| 900–1100 ms、200 ms、阈值 150 ms 反例 | OLD spike=1；FIXED 100+100，spike=0 |
| 900–1250 ms、350 ms 正例 | FIXED bucket1=250，spike=1 |
| 修正后 20 在真实 trace（cam-service，阈值 5） | 正常输出 episode |
| 仓库根路径 dry-run | 路径存在；C1 + host_pull 从根目录通过 |
| v2_test / v2_modify 未修改 | 是（独立目录） |

详见 `validation/tests/TEST_RECORD.md` 与 `validation/tests/outputs/`。

## 5. 未验证

- 未连接 X5，未运行真实 `tracebox`/heapprofd/perf。
- 合成反例只验证区间数学与旧/新逻辑，不是 `worker_app` 数据。
- 未验证 v57.1 descriptor、真实 C2 生命周期、UI。
- 未修改或部署 Skill；不把本次修正表现冒充首轮盲测成绩。
