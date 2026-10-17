# 测试记录（候选版 v1.0.1，2026-10-17 第二轮定点修复）

## 0. 环境与输入
```
python3: Python 3.10.12
TP: Perfetto v58.2-add693d8b (add693d8b338ba9599dbcbc3e300b1ab8c000897)
traces（仓库内，未修改）:
  ec392840ae22bd8e0937b95e229000c1e5f30c488921e0041f2cbaf01a837dbb  x5_heapprofd_traces/x5_heapprofd_A_no_tick.pftrace
  6bd51270c1c87e09b5971ebef54dfd468d67b6ec6ec980da0f2fc844b2fabc11  x5_heapprofd_traces/x5_heapprofd_B_tick_200ms.pftrace
```

## 1. 本轮修复一：validate_config 目标字段解析

复现用例（修复前 PASS，修复后必须 FAIL）：
```
[FAIL] deploy-name: launched basename='memprobe' not in config targets ['other_app']; heapprofd will not match this process and BLOCKING_INIT may hang
[NOTE] runtime not verified by preflight: pass/fail above covers only static premises; readiness/injection/stop/flush still need runtime evidence
rc=1
```

解析/归一化行为矩阵：
```
similar field (UNKNOWN): rc=2  [UNKNOWN] deploy-name: no process_cmdline inside heapprofd_config (cannot verify)
inside string (UNKNOWN): rc=2  [UNKNOWN] deploy-name: no process_cmdline inside heapprofd_config (cannot verify)
unbalanced (UNKNOWN):    rc=2  [UNKNOWN] deploy-name: unbalanced "{" in config
outside block (UNKNOWN): rc=2  [UNKNOWN] deploy-name: process_cmdline found only outside heapprofd_config; cannot verify
multi-target (PASS):     rc=0  [PASS] deploy-name: launched basename='memprobe' matches target(s) ['a', 'memprobe']
@ suffix (PASS):         rc=0  [PASS] deploy-name: launched basename='app_process' matches target(s) ['/system/bin/app_process@/system/bin/app_process64']
same-line (PASS):        rc=0  [PASS] deploy-name: launched basename='memprobe' matches target(s) ['memprobe']
```
规则：只接受 `heapprofd_config` 块内的 `process_cmdline`；跳过注释与字符串；
标识符按整词匹配；括号/字符串不闭合或字段在块外 → UNKNOWN(rc=2)。
归一化按 `NormalizeCmdLine`：截断首个 `@`，再取 basename。

## 2. 本轮修复二：tp_check 的 Live 三列结构校验

```
test_a_candidates_empty_fails (test_tp_check_faults.FaultTests) ... ok
test_a_negative_live_fails (test_tp_check_faults.FaultTests) ... ok
test_a_wrong_axis_count_fails (test_tp_check_faults.FaultTests) ... ok
test_a_wrong_dump_count_fails (test_tp_check_faults.FaultTests) ... ok
test_bad_ts_fails (test_tp_check_faults.FaultTests) ... ok
test_empty_series_fails (test_tp_check_faults.FaultTests) ... ok
test_helper_with_data_fails (test_tp_check_faults.FaultTests) ... ok
test_missing_series_column_fails (test_tp_check_faults.FaultTests) ... ok
test_normal_passes (test_tp_check_faults.FaultTests) ... ok
test_rc_error_fails (test_tp_check_faults.FaultTests) ... ok
test_ts_not_matching_axis_fails (test_tp_check_faults.FaultTests) ... ok
test_unsorted_ts_fails (test_tp_check_faults.FaultTests) ... ok
test_zero_dur_wrong_fails (test_tp_check_faults.FaultTests) ... ok
Ran 13 tests in 0.008s
OK
```
新增反例：ts 非整数、缺 series 列、ts 非递增、ts 与 dump 轴不一致、series 为空。

## 3. 真实 TP 正例（X5 A/B，v58.2）
```
traces=/root/github_test/x5_heapprofd_traces/x5_heapprofd_traces
########## A: x5_heapprofd_A_no_tick.pftrace
 candidates: [['191', '1062', '/data/memprobe', '4', '2', '1', '1', '1', '0'], ['193', '1065', '/data/memprobe', '0', '0', '0', '0', '0', '0']]
  live values (MiB): [0.0] -> PASS
########## B: x5_heapprofd_B_tick_200ms.pftrace
 candidates: [['192', '1123', '/data/memprobe', '16', '8', '6', '6', '1', '0'], ['194', '1126', '/data/memprobe', '0', '0', '0', '0', '0', '0']]
  live values (MiB): [8.0, 8.0, 8.0, 0.0, 0.0, 0.0] -> PASS
SUMMARY: PASS
```

## 4. 单元测试
```
Ran 65 tests in 0.053s
OK
```

## 5. 未验证
- 故障注入使用假 runner，不覆盖真实 TP 的解析差异；
- 真实 TP 只验证了 v58.2 与两条 X5 trace（A/B）；其他版本/配置未测；
- UI、板端现场、descriptor 校验仍未执行；
- Agent A/B 评分为上一轮结果，本轮未重新做行为测试（不称为新行为测试）。
