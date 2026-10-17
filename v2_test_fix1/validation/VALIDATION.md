# 静态验证记录

本文件记录本轮交付物在**本机**做过的静态/离线验证，以及明确未验证的部分。
验证时间：2026-10-17；所有结果均可复现，命令与输出见下。

## 1. Skill 候选版完整性

```text
路径: /root/github_test/x5_heapprofd_traces/v1_modify/candidate-v1.0.1
版本: 1.0.1 (MANIFEST.json)
提交: f16f68ae1e3f112794af3b953881d1b18fa8415e
```

- 工作树 HEAD 为 `3dcef36`；`git diff f16f68a HEAD -- v1_modify/candidate-v1.0.1` 为空，
  候选目录与该提交一致。
- `SKILL.md` sha256 `70371e5b...`、`references/02-native.md` sha256 `21b8bd7a...`、
  `scripts/validate_config.py` sha256 `98c2f8f6...`，均与 `MANIFEST.json` 一致。
- 未使用部署的 v1.0.0：`/root/.dsh/skills/perfetto-memory-debugging/MANIFEST.json`
  版本为 `1.0.0`，`SKILL.md` sha256 `4f5f6ae9...`，与候选版不同。

## 2. 资源预检

```bash
cd /root/github_test/x5_heapprofd_traces/v1_modify/candidate-v1.0.1
python3 scripts/validate_config.py --check-resources
```

输出：

```text
[PASS] resources: 27 required files + 10 configs readable
[NOTE] runtime not verified by preflight: pass/fail above covers only static premises; readiness/injection/stop/flush still need runtime evidence
```

## 3. TraceConfig schema 校验

descriptor 由本机 Perfetto v58.2 源码生成：

```bash
cd /root/perfetto-csdk
protoc -I . --include_imports \
  --descriptor_set_out=/root/code_1.0.20/tmp/perfetto-worker-app/trace_config-v58.2.desc \
  protos/perfetto/config/trace_config.proto
```

sha256：

```text
6e11baf4cd7718a8f0fe8e48ade0bf7298bfb76fc0b0691d9415bdb7f3481e74  trace_config-v58.2.desc
```

与既有 `/root/code_1.0.20/tmp/trace_config.desc` 的 sha256 完全一致，说明该
descriptor 确为本地 v58.2 源码生成。

逐份校验：

```bash
cd /root/github_test/x5_heapprofd_traces/v1_modify/candidate-v1.0.1
for c in C1-worker-timeline C2-worker-native-alloc C3-worker-cpu-profile; do
  python3 scripts/validate_config.py \
    /root/code_1.0.20/tmp/perfetto-worker-app/configs/$c.pbtxt \
    --descriptor-set /root/code_1.0.20/tmp/perfetto-worker-app/trace_config-v58.2.desc
done
```

输出（三份相同）：

```text
[PASS] schema: parsed with supplied descriptor (runtime support NOT tested)
[NOTE] runtime not verified by preflight: pass/fail above covers only static premises; readiness/injection/stop/flush still need runtime evidence
```

**边界**：这是 v58.2 descriptor 的静态语法校验，不是 v57.1 采集器的 schema 校验，
也不证明板端数据源/事件存在或实际采到数据。

## 4. SQL 语法/表存在性验证

使用本机 v58.2 Trace Processor：

```text
/root/code_1.0.20/tmp/perfetto582/linux-amd64/trace_processor_shell
Perfetto v58.2-add693d8b
```

对本地已有 trace 执行新增 SQL，确认：

- `sched_slice`、`thread_state`、`perf_sample`、`heap_profile`、
  `heap_profile_allocation`、`stats`、`ftrace_event`、`trace_bounds` 等表/视图存在；
- 查询语法可解析，列名正确；
- 空结果不报错（例如目标 UPID 不存在时）。

用途仅限语法/表存在性验证；**没有**用这些 trace 对 `worker_app` 得出任何结论。

## 5. 板端能力静态检查（未上板）

- 板端 `tracebox` v57.1（本地 SDK 副本）二进制包含：
  `linux.perf`、`traced_perf`、`sched/sched_switch`、`power/cpu_frequency`、
  `cpufreq_period_ms`、`record_process_runtime` 等字符串；
  不包含 `android.heapprofd` 注册串。
- 同版本 `libheapprofd_glibc_preload.so` 包含：
  `v57.1-c59f57dd4`、`android.heapprofd`，并导出 malloc/free/calloc/realloc hook。
- 结论：Linux 上 heapprofd 由 preload 的 kChild producer 注册，不需要单独 daemon；
  但必须使用与 tracebox 匹配的 preload 版本。

## 6. 未验证项

- 未连接 X5；未执行 `tracebox`、`survey.sh` 或任何采集。
- 未获得 v57.1 TraceConfig descriptor；未做 v57.1 schema 校验。
- 未验证板端 `available_events`、perf 权限、preload 注入、heapprofd 数据源注册、
  C2 端到端。
- 未验证 `worker_app` 的符号、Build ID、frame pointer、启动参数。
- 未打开 Perfetto UI 查看本次采集结果；未生成截图/曲线。
- 未证明任何性能因果关系。

## 7. 修正版 r1 增补验证

本节只覆盖本轮 7 项修正，不改变首轮 `v2_test`。

### 7.1 配置 schema

C2 的 `duration_ms` 从 45000 改为 90000（安全上限），三份配置重新用 v58.2 descriptor
校验，均 PASS。原始输出：`tests/outputs/schema_validation.txt`。

### 7.2 SQL 正例/反例

| 测试 | 正例/反例 | 结果 |
|---|---|---|
| `tests/bucket_overlap_test.sql` | 90/120 ms 跨 100 ms 边界正例 | 每个区间 `sum(overlap)==dur`，`diff_ns=0` |
| `tests/real_trace_overlap_test.sql` | 真实 trace 5 条 90–120 ms slice | 5 条 `diff_ns=0` |
| `tests/bucket_overlap_old_vs_new.sql` | 旧逻辑全记起始桶 | OLD 90 ms@bucket0；FIXED 5+85 ms |
| `tests/jitter_cycles_counterexample.sql` | 含安静间隔反例 | OLD 1 段；FIXED 2 段 |
| `tests/perf_window_guard_test.sql` | 窗口在/不在 trace | `OK` / `OUT_OF_TRACE` |
| `16a` 真实 trace 偏移 | 有效/越界 | `OK` / `OUT_OF_TRACE` |
| `16` perf trace | 本 trace 相对窗口 | 正常输出 spike/quiet 样本 |

原始输出在 `tests/outputs/`；测试 trace 不是 `worker_app`，只用于 SQL 逻辑验证。

### 7.3 Shell 生命周期 dry-run

`tests/shell_lifecycle_dryrun.sh` 用 mock tracebox/app 验证：

- C2：服务查询 → 起 app → 等 heapprofd → 观测 → 停 app → flush → SIGINT → 非空；
- C1/C3：后台 PID、完成、非空输出；
- `host_pull.sh`：成功返回 0；scp 失败/空文件返回非零。

原始输出：`tests/outputs/shell_lifecycle_dryrun.txt`。
这只是脚本控制流测试，**不证明**板端真实 tracebox/heapprofd 行为。

### 7.4 版本边界（修正后仍适用）

- v57.1 采集端不发布 heapprofd `start_timestamp`，v58.2 上 `dur=0` 常见；精确窗口 UNKNOWN。
- 本方案 SQL 使用 v58.2 表名；v57.1 TP 无 `heap_profile` 时用 `10-native-dump-capability.sql` 降级。
- 仅 v58.2 descriptor 静态校验；v57.1 运行期未验证。
- heapprofd `count/size` 是采样估计；业务延迟需独立日志/打点/trace_marker。

### 7.5 仍未验证

- 未上板；未运行真实 tracebox/survey/heapprofd/perf。
- 未验证 C2 producer 注册与 SIGINT flush 的真实时序。
- 未验证 `worker_app` trace、符号、UI、性能因果。
