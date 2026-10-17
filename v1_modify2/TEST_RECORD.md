# 测试记录（候选版 v1.0.1，2026-10-17 修订）

## 0. 环境与输入
```
python3: Python 3.10.12
TP: Perfetto v58.2-add693d8b (add693d8b338ba9599dbcbc3e300b1ab8c000897)
traces（仓库内，未修改）:
  ec392840ae22bd8e0937b95e229000c1e5f30c488921e0041f2cbaf01a837dbb  x5_heapprofd_traces/x5_heapprofd_A_no_tick.pftrace
  6bd51270c1c87e09b5971ebef54dfd468d67b6ec6ec980da0f2fc844b2fabc11  x5_heapprofd_traces/x5_heapprofd_B_tick_200ms.pftrace
```

## 1. 单元测试（候选版自带，58 项）
```
Ran 58 tests in 0.054s
OK
```

## 2. tp_check 故障注入（verify/test_tp_check_faults.py，8 例）
```
test_a_candidates_empty_fails (test_tp_check_faults.FaultTests) ... ok
test_a_negative_live_fails (test_tp_check_faults.FaultTests) ... ok
test_a_wrong_axis_count_fails (test_tp_check_faults.FaultTests) ... ok
test_a_wrong_dump_count_fails (test_tp_check_faults.FaultTests) ... ok
test_helper_with_data_fails (test_tp_check_faults.FaultTests) ... ok
test_normal_passes (test_tp_check_faults.FaultTests) ... ok
test_rc_error_fails (test_tp_check_faults.FaultTests) ... ok
test_zero_dur_wrong_fails (test_tp_check_faults.FaultTests) ... ok
Ran 8 tests in 0.005s
OK
```

## 3. 真实 TP 回归（X5 A/B 正例，v58.2）
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
断言范围（每条查询都检查 rc、列数、行数与关键值）：
- 候选：9 列、恰一个 data_bearing=1、辅助进程 0 rows/0 activity；
- sql10：4 条语句；tables 含两表；axis 行数=dump 数、dur=0、每 dump alloc_rows≥1；
  summary 的 dumps/distinct/zero_dur 均等于预期；fallback 的 activity_dumps 与 alloc/free 字节精确匹配；
- sql03：行数=dump 数、非负、A=[0.0]、B=[8,8,8,0,0,0]。

## 4. validate_config 静态预检（退出码约定 0/1/2）
```
resources:        rc=0  [PASS] resources: 27 required files + 10 configs readable
same-line PASS:   rc=0  [PASS] deploy-name: launched basename='memprobe' matches target(s) ['memprobe']
multi targets:    rc=0  [PASS] deploy-name: launched basename='memprobe' matches target(s) ['a', 'memprobe']
mismatch FAIL:    rc=1  [FAIL] deploy-name: launched basename='memprobe_arm64' not in config targets ['memprobe']; heapprofd will not match this process and BLOCKING_INIT may hang
glob UNKNOWN:     rc=2  [UNKNOWN] deploy-name: target 'memprobe*' contains a glob; heapprofd matches exact basename
no cmdline UNKN:  rc=2  [UNKNOWN] deploy-name: config has no process_cmdline (not a heapprofd target config)
truncated ELF:    rc=2  [UNKNOWN] binary: /tmp/trunc.elf is not a readable/complete ELF; cannot judge dynamic linking
static ELF FAIL:  rc=1  [FAIL] binary: /tmp/st_elf has no PT_INTERP: statically linked targets ignore LD_PRELOAD
dynamic ELF PASS: rc=0  [PASS] binary: /root/code_1.0.20/tmp/heapprofd-minimal/memprobe_arm64 is a dynamic ELF (PT_INTERP present)
```
约定：0=全部 PASS；1=有 FAIL；2=有 UNKNOWN/无法完成；运行期未验证只打印 `[NOTE]`，不改变退出码。

## 5. 本轮定点修复
| 项 | 变更 | 验证 |
|---|---|---|
| tp_check | 每条查询校验 rc/列/行/关键值；A 组改为恰等于 `[0.0]`（原 `[0.0] >= vals` 是错误比较）；拒绝空结果、负 Live、dump 数错误 | 正例 PASS + 8 个故障注入例全部被拒绝 |
| validate_config | 支持同行/多目标/路径归一化；glob、无 cmdline、非 ELF、截断 ELF → UNKNOWN(rc=2)；静态结果与运行期提示分离（`[NOTE]` 不影响退出码）；configs 检查可读且非空 | 9 条退出码/行为实测 + 单测 58 项 |
| 判据 | 符号无数据接受 UNKNOWN；UNKNOWN 后禁用 interval 断言"不符" | 重新评分 6/9 vs 8/9，见 `AGENT_AB.md` |
| 文档 | `references/02-native.md` 增"上界证据不得断言不符"；`tests/scenarios.md` A33 增纪律项 | 文档级，无设备行为测试 |

## 6. 未执行 / 未验证
- Perfetto UI 打开；X5 现场采集；官方 TraceConfig descriptor 校验；
- Android / kCentral / 其他 `dump_interval_ms` 的适用性；
- 独立第三方评分（`AGENT_AB.md` 由维护者按 rubric 评分，样本量 1）；
- tp_check 的故障注入是**假 runner**，不覆盖真实 TP 的解析差异。
