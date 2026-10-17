# 测试记录（候选版 v1.0.1）

## 0. 环境与输入
```
python3: Python 3.10.12
TP: Perfetto v58.2-add693d8b (add693d8b338ba9599dbcbc3e300b1ab8c000897)
baseline: v1.0.0（44 文件，SHA256SUMS 见 ../baseline-v1.0.0.SHA256SUMS）
traces（未修改）:
  ec392840ae22bd8e0937b95e229000c1e5f30c488921e0041f2cbaf01a837dbb  /root/code_1.0.20/tmp/x5_heapprofd_validation/x5_heapprofd_A_no_tick.pftrace
  6bd51270c1c87e09b5971ebef54dfd468d67b6ec6ec980da0f2fc844b2fabc11  /root/code_1.0.20/tmp/x5_heapprofd_validation/x5_heapprofd_B_tick_200ms.pftrace
```

## 1. 单元测试（保留原有 35 + 新增 16）
```
Ran 51 tests in 0.047s
OK
```

## 2. 静态预检（validate_config.py）
```
$ --check-resources
[PASS] resources: 27 required files + 10 configs readable
[UNKNOWN] runtime: preflight cannot prove readiness/injection/stop/flush; require notify-fd byte, trace content, stats and logs
$ memprobe 部署名（应为 PASS）
[PASS] deploy-name: process_cmdline='memprobe' == launched basename='memprobe'
[UNKNOWN] runtime: preflight cannot prove readiness/injection/stop/flush; require notify-fd byte, trace content, stats and logs
$ memprobe_arm64 部署名（应为 FAIL, rc=1）
[FAIL] deploy-name: config process_cmdline='memprobe' != launched basename='memprobe_arm64'; heapprofd will not match this process and BLOCKING_INIT may hang
[UNKNOWN] runtime: preflight cannot prove readiness/injection/stop/flush; require notify-fd byte, trace content, stats and logs
$ 动态 ELF（应为 PASS）
[PASS] binary: /root/code_1.0.20/tmp/heapprofd-minimal/memprobe_arm64 is a dynamic ELF (PT_INTERP present)
[UNKNOWN] runtime: preflight cannot prove readiness/injection/stop/flush; require notify-fd byte, trace content, stats and logs
$ 静态 ELF（应为 FAIL）
[FAIL] binary: /tmp/st_elf has no PT_INTERP: statically linked targets ignore LD_PRELOAD
[UNKNOWN] runtime: preflight cannot prove readiness/injection/stop/flush; require notify-fd byte, trace content, stats and logs
```

## 3. 真实 Trace Processor 回归（X5 A/B，v58.2）
```
########## A: x5_heapprofd_A_no_tick.pftrace
 candidates: [['191', '1062', '/data/memprobe', '4', '2', '1', '1', '1', '0'], ['193', '1065', '/data/memprobe', '0', '0', '0', '0', '0', '0']]
  sql10 -> [['heap_profile'], ['heap_profile_allocation']]  rc=0  [SELECT name FROM sqlite_master WHERE name IN ('heap_profile'...]
  sql10 -> [['1766874047884', '1766874047884', '0', '191', 'libc.malloc', '4']]  rc=0  [WITH params AS (SELECT 191 AS target_upid, 'libc.malloc' AS ...]
  sql10 -> [['1', '1', '1', '1766874047884', '1766874047884']]  rc=0  [WITH params AS (SELECT 191 AS target_upid, 'libc.malloc' AS ...]
  sql10 -> [['1', '1766874047884', '1766874047884', '29360128', '29360128']]  rc=0  [WITH params AS (SELECT 191 AS target_upid, 'libc.malloc' AS ...]
  live values (MiB): [0.0]
  live expectation: PASS
########## B: x5_heapprofd_B_tick_200ms.pftrace
 candidates: [['192', '1123', '/data/memprobe', '16', '8', '6', '6', '1', '0'], ['194', '1126', '/data/memprobe', '0', '0', '0', '0', '0', '0']]
  sql10 -> [['heap_profile'], ['heap_profile_allocation']]  rc=0  [SELECT name FROM sqlite_master WHERE name IN ('heap_profile'...]
  sql10 -> [['1789933857853', '1789933857853', '0', '192', 'libc.malloc', '5'], ['1791943857854', '1791943857854', '0', '192', 'libc.malloc', '2']]  rc=0  [WITH params AS (SELECT 192 AS target_upid, 'libc.malloc' AS ...]
  sql10 -> [['6', '6', '6', '1789933857853', '1799953857858']]  rc=0  [WITH params AS (SELECT 192 AS target_upid, 'libc.malloc' AS ...]
  sql10 -> [['6', '1789933857853', '1799953857858', '29605888', '29605888']]  rc=0  [WITH params AS (SELECT 192 AS target_upid, 'libc.malloc' AS ...]
  live values (MiB): [8.0, 8.0, 8.0, 0.0, 0.0, 0.0]
  live expectation: PASS
SUMMARY: PASS
```

## 4. 反例覆盖（对应四项改动）
| 改动 | 反例/正常例 | 结果 |
|---|---|---|
| A 资源完整性与预检 | 完整树 PASS；缺 references/sql 的临时树 FAIL；部署名不一致 FAIL；静态 ELF FAIL；非 ELF UNKNOWN | 全部按预期 |
| B dump 可见性 | X5 A：dumps=1、dur=0；X5 B：dumps=6、dur=0；v57.1 降级语句仅统计活动 dump | PASS |
| C 目标候选 | 同名双进程（1 带数据）解析为唯一 data-bearing；再加一个带数据进程 → ambiguous=1；`-1` 占位返回 0 行且文档说明“不代表没有分配” | PASS |
| D 三态验收 | 文档规则：精确持有区间在 dur=0 时 UNKNOWN，其余项 PASS/FAIL 可判 | 文档级，行为测试见 agent_ab |

## 5. 未执行
- Perfetto UI 实际打开（本轮不要求；skill 中原有 UI 配方未改）
- X5 现场采集（本轮禁止）
- 官方 TraceConfig descriptor 校验（无匹配版本 descriptor）
- Android / kCentral / 其他 dump_interval 的适用性

## 6. Agent 行为对照
见 ../AGENT_AB.md（独立会话；两版同题同条件）
