# v2_test_fix1 — 首轮 `v2_test` 的范围受限技术修正

本目录是第二轮独立场景测试首轮交付 `v2_test` 的**独立修正版**。
首轮 `v2_test/` 原样保留，不覆盖、不改写 history；本版只修本轮明确列出的确定性问题
及其直接关联的文档、配置、SQL、脚本。

> 这是一次技术修正，不是新的盲测成绩。不得把本版表现冒充首轮独立 Agent 的首交付质量。

## 1. 修正范围

1. **变量作用域**：消除未定义的 `$TRACEBOX`；把板端动作收进 `scripts/remote_*.sh`，
   由板端 shell 解析变量，避免 SSH 双引号在主机侧展开 `$!`/`$(...)`。
2. **C2 生命周期**：服务就绪 → 起测试进程（preload）→ 等 `heapprofd` producer →
   观测 `OBSERVE_S` → 停 app → flush → SIGINT tracebox → 非空校验；不再启动后立即杀进程。
3. **C1/C3 完成条件**：后台 PID、超时、SIGINT/SIGTERM、文件非空；
   `host_pull.sh` 对 scp 失败或空文件立即非零退出，不再“拉回失败仍宣称成功”。
4. **`10`/`11` 跨桶**：用 `min(ts+dur,bucket_end)-max(ts,bucket_start)` 做区间交集，
   不再把完整 `dur` 记到起始桶；用 90/120 ms 跨 100 ms 边界样本测试。
5. **`20` 抖动 episode**：先筛高 CPU 桶再 `ROW_NUMBER()`，安静间隔不会把两段合并；
   提供含安静间隔的反例。
6. **`16` 时间窗口**：改为相对当前 trace `trace_bounds.start_ts` 的毫秒偏移；
   新增 `16a` 检查窗口是否在本 trace。C1 的绝对 ns 不得直接用于 C3。
7. **采样语义**：明确 heapprofd `count/size` 是采样估计，不是精确调用次数；
   业务延迟需要独立日志/打点/trace_marker 证据。

未修改：`worker_app`、既有实验数据、Skill 的安装/部署、首轮 `v2_test/` 内容。

## 2. 目录

```text
v2_test_fix1/
├── README.md
├── PLAN.md                      完整方案（已替换第 4 节执行流程，补充版本边界/测试）
├── CHANGES.diff                 相对 v2_test 的 unified diff
├── configs/
│   ├── C1-worker-timeline.pbtxt
│   ├── C2-worker-native-alloc.pbtxt   duration 改为 90 s 安全上限
│   └── C3-worker-cpu-profile.pbtxt
├── scripts/
│   ├── remote_lib.sh            板端：WORK/TRACEBOX/PID/超时/stop
│   ├── remote_c1.sh             板端：C1 后台采集与完成条件
│   ├── remote_c2.sh             板端：C2 完整生命周期
│   ├── remote_c3.sh             板端：C3 后台采集与完成条件
│   ├── remote_stop.sh           板端：手工 SIGINT + flush + 非空检查
│   └── host_pull.sh             主机：scp + 非空 + sha256，失败即非零
├── sql/
│   ├── 10-cpu-thread-buckets.sql        区间交集
│   ├── 11-runnable-and-blocked.sql      区间交集
│   ├── 12-native-dump-timeline.sql      采样估计说明
│   ├── 13-native-callsite-hotspots.sql  采样估计说明
│   ├── 14-perf-hot-functions.sql
│   ├── 15-perf-allocator-share.sql
│   ├── 16-perf-spike-vs-quiet.sql       本 trace 相对窗口
│   ├── 16a-perf-window-check.sql        窗口越界检查（新增）
│   ├── 17-alloc-vs-cpu.sql              采样估计说明
│   ├── 18-data-quality.sql
│   ├── 19-cpu-frequency.sql
│   └── 20-jitter-cycles.sql             先筛后编号
├── validation/
│   ├── VALIDATION.md
│   ├── SKILL_GAP.md                首轮错误 vs Skill 规则/实现缺口
│   ├── trace_config-v58.2.desc
│   └── tests/
│       ├── bucket_overlap_test.sql
│       ├── bucket_overlap_old_vs_new.sql
│       ├── real_trace_overlap_test.sql
│       ├── jitter_cycles_counterexample.sql
│       ├── perf_window_guard_test.sql
│       ├── shell_lifecycle_dryrun.sh
│       ├── TEST_RECORD.md
│       └── outputs/                    原始测试输出
└── SHA256SUMS
```

## 3. 快速使用

1. `PLAN.md` 第 3 节：三份配置与参数依据。
2. `PLAN.md` 第 4 节：变量作用域、预检、C1/C2/C3 生命周期、停止/拉回。
3. `PLAN.md` 第 6–8 节：SQL、UI、因果判据。
4. `validation/SKILL_GAP.md`：区分“Skill 规则未落实”与“Skill 缺少可复用实现”。
5. `validation/tests/TEST_RECORD.md`：本轮实际执行的 SQL/流程测试记录。

## 4. 验证状态

| 项 | 状态 |
|---|---|
| 首轮 `v2_test/` 未被修改 | 是（独立目录） |
| Skill 候选版路径/版本/commit/sha | 与首轮一致，未改 Skill |
| C1/C2/C3 对 v58.2 descriptor 静态 schema | PASS |
| v57.1 descriptor 校验 | **未执行** |
| 10/11 区间交集：90/120 ms 跨桶正例 | PASS（diff=0） |
| 10/11 真实 trace 90–120 ms slice | PASS（5 条，diff=0） |
| 20 含安静间隔反例 | OLD=1 段，FIXED=2 段 |
| 16/16a 本 trace 窗口检查 | `OK` / `OUT_OF_TRACE` 均验证 |
| shell 生命周期 dry-run（mock） | C2 生命周期、C1/C3 完成、pull 失败传播均 PASS |
| 板端 tracebox/heapprofd/perf 实跑 | **未执行** |
| worker_app 真实 trace / UI 截图 | **未执行** |
| 性能因果 | **未证明** |

## 5. 版本边界（摘要）

- 板端 tracebox v57.1；主机 Trace Processor v58.2。
- v57.1 heapprofd 不发布 `start_timestamp`，v58.2 上 `dur=0` 常见；精确窗口 UNKNOWN，
  总量/分配/释放/dump 数仍可判。
- SQL 使用 v58.2 表名；换 v57.1 TP 时先用 `00-inventory.sql`/`10-native-dump-capability.sql`
  检查并降级。
- v58.2 descriptor 只做静态校验，不等于 v57.1 运行期验证。
- heapprofd count/size 是采样估计；业务延迟需独立事件/日志证据。
