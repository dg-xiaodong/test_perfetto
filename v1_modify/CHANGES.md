# 候选版 v1.0.1 变更摘要

基线：`baseline-v1.0.0/`（只读快照，校验见 `baseline-v1.0.0.SHA256SUMS`）。
候选：`candidate-v1.0.1/`。完整 diff：`diff-baseline-to-candidate.patch`（842 行，20 个文件块，未含 `__pycache__`）。

## 1. 改了什么（按诊断的四类）

### A. 执行前提与资源复用
- `SKILL.md` 新增 **§2.1 资源完整性与复用**：先检查路线依赖的 references/sql/scripts 是否完整可读；缺失时列出缺失项与降级范围；优先复用包内已验证实现。
- `scripts/validate_config.py` 新增三个**静态**预检开关（不新建部署框架）：
  - `--check-resources`：27 个必需文件 + ≥10 份 configs 可读性；
  - `--deploy-name NAME`：`config.process_cmdline` 与**实际启动名 basename** 比对（不是主机产物名），不一致时提示 `BLOCKING_INIT` 可能挂起；
  - `--binary PATH`：解析 ELF program headers 的 `PT_INTERP`，判定动态/静态链接（静态 → 拒绝 LD_PRELOAD 路线）。
  - 所有预检结尾固定输出 `[UNKNOWN] runtime: preflight cannot prove readiness/injection/stop/flush`。
- `README.md`：补充三条预检用法。

### B. Native dump 可见性与能力检查
- `references/02-native.md` 新增 **“Dump 可见性、去重与旧采集端元数据”**：`window_end` 只随分配推进（`bookkeeping.cc` 的 `CommitOperation`）、`free` 以 timestamp=0 提交（`HandleFreeRecord`）、TP 按 `(upid, window_end, heap_name)` 去重（`profile_module.cc`）、旧采集端无 `start_timestamp` → `dur=0`；并区分“采集端字段 / 分析器表 / 实际 trace 数据”三层。
- 新增 `sql/10-native-dump-capability.sql`：表能力、dump 轴（含 `alloc_rows`）、汇总（`dumps` / `distinct_ts_end` / `zero_dur_dumps`）、v57.1 无 `heap_profile` 时的降级（只统计活动 dump）。

### C. 目标发现与 SQL 参数
- `sql/00-inventory.sql` 新增 `[CANDIDATES]` 查询：`upid/pid/name/alloc_rows/alloc_pos_rows/activity_dumps/dumps/data_bearing/ambiguous`；名称按 `name='X' OR name GLOB '*/X'` 匹配（带路径与不带路径都命中）；同名 preload 子进程自然显示为 `data_bearing=0`。
- `sql/03-native-live.sql`、`sql/04-native-callstacks.sql` 头部新增参数规则：`target_upid` 必须来自 `[CANDIDATES]`；**仅唯一 data-bearing 可用**；用户已给 PID/UPID 时沿用；`-1` 表示未解析，**返回 0 行不代表“没有分配”**。

### D. 验收与修复回归
- `references/06-quality.md` 新增 **§7 判定三态与回归义务**：`PASS/FAIL/UNKNOWN` 逐项判定；`dur=0` 只让“精确持有区间”变 UNKNOWN，其余项仍可判；回归按改动类型（SQL→真实 TP 正常例+反例；脚本→退出码；文档→Agent 行为测试）。
- `tests/scenarios.md` 新增 **A29–A33** 五个行为回归场景（资源缺失、部署名一致/不一致、候选歧义、A/B 三态判读）。
- `tests/agent_ab/`：三份任务输入 + 判据 + 执行说明。

## 2. 测试

- 单测：**51 项通过**（原 35 + 新增 16：`test_targets.py`、`test_dump_capability.py`、`PreflightTests`）。命令与输出见 `TEST_RECORD.md`。
- 真实 TP（v58.2）回归：X5 A/B 两条**未修改**的真实 trace 上，`[CANDIDATES]` 各返回 2 行（唯一 data-bearing 191/192）；`sql/10` 在 A 报 `dumps=1, zero_dur=1`、B 报 `dumps=6, zero_dur=6`；`sql/03` 用解析出的 upid 得到 A `[0.0]`、B `[8,8,8,0,0,0]`。
- 预检：正确部署名 PASS、`memprobe_arm64` FAIL(rc=1)、动态 ELF PASS、静态 ELF FAIL。
- 未执行：Perfetto UI 打开、X5 现场采集、官方 descriptor 校验、Android/kCentral 与其他 interval 的适用性。

## 3. 行为变化（一句话）

| 改动 | 下一次会变成什么行为 |
|---|---|
| SKILL.md §2.1 | 资源缺失时先报缺失与降级，不再默认“包是完整的” |
| validate_config 预检 | 名称/动态链接在采集前被机械拦住，不再靠人工比对产物名 |
| 02-native + sql/10 | 看到 dump 少/`dur=0` 时先做能力检查，不再把 interval 当 dump 数、也不再据此否定全部结论 |
| 00-inventory + 03/04 | 目标必须显式解析；同名辅助进程、路径名、歧义都有确定处理；`-1` 不再被误读成“没有分配” |
| 06-quality §7 | 验收输出逐项三态；“测量缺失”不再写成“行为不符合” |

## 4. 未扩大范围

- 未改 10 份 configs、`make_config.py`、`survey.sh`（除 README 引用）。
- 未改 SQL 的判据/阈值，只新增能力检查与参数规则。
- 未新增采集脚本或部署框架。
