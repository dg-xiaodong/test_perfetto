# v1.0.2 独立 Agent 行为测试

用途：比较 v1.0.1 与 v1.0.2 在相同输入下的首轮行为。被测 Agent 只加载指定候选目录的
`SKILL.md` 及其 `references/`、`sql/`、`scripts/`、`tests/`，**不接收**历史纠错记录、
`v2_test/`、`v2_modify/`、`v2_modify2/` 或预期答案。

## 三个场景

- `B1_linux_lifecycle.md`：普通 Linux trace 与 native heapprofd 的采集生命周期。
- `B2_cpu_bucket_sql.md`：CPU 时间桶与 spike episode 的参数化 SQL。
- `B3_evidence_causality.md`：跨 trace 时间戳、dump 时间、采样 count 与因果边界。

## 运行方式

对每个场景分别启动**新的独立会话**，把 `{{SKILL_DIR}}` 替换为：

- v1.0.1：`v1_modify/candidate-v1.0.1`
- v1.0.2：`v1_modify/candidate-v1.0.2`

被测 Agent 不得读取其他候选目录或历史报告。把原始回答保存到
`results/v101_B1.md`、`results/v102_B1.md` 等；不在场景文本中提供评分答案。
评分使用 `rubric.md`，但 rubric 不提供给被测 Agent。

## 状态

已执行 6 个独立子会话（B1/B2/B3 × v1.0.1/v1.0.2），原始输出在 `results/`，
对照见 `results/COMPARISON.md`。同模型/同编排、单次运行、无温度控制；这是行为烟雾测试，
不是统计基准。没有运行的结果必须标为“未执行”，不能用推测代替。
