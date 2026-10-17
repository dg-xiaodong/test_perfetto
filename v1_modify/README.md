# perfetto-memory-debugging v1.0.1 候选交付

本目录是**已完成的实际产物**（不是摘要）：只读基线、候选版、补丁、验证脚本、测试与 Agent 行为记录。
两份 X5 真实 trace 已在仓库的 [`../x5_heapprofd_traces/`](../x5_heapprofd_traces/)，本目录的脚本按参数引用它们。

## 目录

| 路径 | 内容 |
|---|---|
| `baseline-v1.0.0/` | v1.0.0 只读基线快照（44 文件） |
| `baseline-v1.0.0.SHA256SUMS` | 基线校验（相对 `baseline-v1.0.0/`，不含 `__pycache__`） |
| `candidate-v1.0.1/` | 候选版（54 文件，含全部测试与 `tests/agent_ab/`） |
| `candidate-v1.0.1.SHA256SUMS` | 候选校验（相对 `candidate-v1.0.1/`，不含 `__pycache__`） |
| `diff-baseline-to-candidate.patch` | 基线→候选统一 diff（不含 `__pycache__`） |
| `verify/tp_check.py` | 真实 Trace Processor 回归脚本（参数化路径；每条查询校验 rc/列/行/关键值） |
| `verify/test_tp_check_faults.py` | tp_check 的故障注入测试（空结果/负 Live/错 dump 数/rc 错误/零宽错误/辅助进程被算数据） |
| `agent_records/` | 两组 Agent 的**实际工具调用**记录 + 原始回答指引（含缺失说明） |
| `CHANGES.md` | 四项改动与"改变什么行为" |
| `TEST_RECORD.md` | 单测/预检/真实 TP 回归/反例覆盖/未执行项 |
| `AGENT_AB.md` | 旧版 vs 候选的行为对照（评分、差异引用、样本量说明） |

## 快速核验（在仓库根执行）

```bash
# 1) 校验和（各自在目录内执行；SHA256SUMS 用 ./ 相对路径）
(cd v1_modify/baseline-v1.0.0   && sha256sum -c ../baseline-v1.0.0.SHA256SUMS)
(cd v1_modify/candidate-v1.0.1  && sha256sum -c ../candidate-v1.0.1.SHA256SUMS)

# 2) 候选版单元测试（51 项，不需要设备/网络）
(cd v1_modify/candidate-v1.0.1 && python3 -m unittest discover -s tests)

# 3) 真实 TP 回归（需要本机有 v58.2 trace_processor_shell）
python3 v1_modify/verify/tp_check.py --tp /path/to/trace_processor_shell
#    默认：skill=v1_modify/candidate-v1.0.1，traces=<repo>/x5_heapprofd_traces
#    也可用 $PERFETTO_TP，或把 trace_processor_shell 放进 PATH

# 3b) 故障注入（不接真实 TP，验证异常不会 PASS）
(cd v1_modify/verify && python3 -m unittest test_tp_check_faults)

# 4) 静态预检（候选版的 validate_config.py）
cd v1_modify/candidate-v1.0.1
python3 scripts/validate_config.py --check-resources
python3 scripts/validate_config.py configs/native.pbtxt --deploy-name memprobe   # 名称一致性
python3 scripts/validate_config.py --binary /path/to/memprobe_arm64              # PT_INTERP
```

> 预检只证明**静态**前提；运行期就绪/注入/停止/flush 仍需运行期证据（notify-fd 字节、trace 内容、stats/日志）。
> 退出码约定：`0`=全部 PASS，`1`=有 FAIL，`2`=有 UNKNOWN/无法完成；运行期未验证只打印 `[NOTE]`，**不改变**退出码。

## 为进入本仓库做的脚本改动

### 1) `verify/tp_check.py` 参数化 + 断言加固

原脚本硬编码 `/root/...` 路径，现改为三个参数：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--tp` | `$PERFETTO_TP` 或 PATH 中的 `trace_processor_shell` | 分析器二进制 |
| `--skill-dir` | `<本目录>/candidate-v1.0.1` | 被测 Skill |
| `--traces-dir` | `<仓库根>/x5_heapprofd_traces` | 两份真实 trace |

并在 2026-10-17 修订中加固断言：每条查询检查 returncode/列数/行数，sql/10 的 dump 数、零宽窗口、
alloc/free 字节与 sql/03 的 live 序列都做实际比对；A 组由错误的 `[0.0] >= vals` 改为**恰等于** `[0.0]`。
故障注入见 `verify/test_tp_check_faults.py`（8 例，全部应被判失败）。

### 2) `candidate-v1.0.1/scripts/validate_config.py` 静态预检修复

- `process_cmdline` 不再要求独占一行（支持同一行/紧凑写法），支持多条目标并按 basename 归一化；
- glob、无 `process_cmdline`、非 ELF、截断 ELF → `UNKNOWN`（退出码 2），不再抛异常或误判 FAIL；
- `--check-resources` 检查文件**可读且非空**，不再只数 glob 条目；
- 静态结论与"运行期未验证"分离：后者只打印 `[NOTE]`，不改变退出码。

候选版 Skill 的验收阈值为**未改动**；本次只修正静态预检与验证脚本。

## 校验和覆盖范围

- 两个 `*.SHA256SUMS` 均为**纯 sha256sum 输出**（`./` 相对路径），可直接 `sha256sum -c`；
- 覆盖目录下全部交付文件，**排除** `__pycache__/`、`*.pyc` 等运行时缓存；
- 未覆盖：仓库根的两份 X5 trace（它们有各自的提交记录，不属本目录）。

## 未包含 / 缺失（不补造）

- 完整会话历史与逐 step 的 token 统计：**未上传**（只保留 `agent_records/` 的工具调用清单）；
- 官方 TraceConfig descriptor 校验：**未执行**（无匹配版本 descriptor）；
- Perfetto UI 操作记录：**未包含**（本轮不涉及 UI 验证）；
- 独立第三方评分：**没有**；`AGENT_AB.md` 的评分由维护者按 `rubric.md` 完成，样本量 1，已如实标注；
- 候选版**未部署**到任何 Skill 目录；本目录只是交付副本。
