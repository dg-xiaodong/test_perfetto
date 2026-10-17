# Agent 行为对照（独立会话）

三份任务输入：`T1_execution_prereq.md`、`T2_target_discovery.md`、`T3_ab_interpretation.md`。
评分判据：`rubric.md`。

执行方式（有独立新会话工具时）：
- 两组使用相同模型与工具条件；
- 旧版组加载已部署的 perfetto-memory-debugging；新版组加载本候选目录（读 `SKILL.md` 及其引用文件）；
- 被测 Agent 不接收历史纠错记录与预期答案，不读取本仓库的诊断报告；
- 保存首轮原始输出与实际加载/调用记录。

**若没有独立新会话工具：只交付上述输入与判据，并标记"行为回归未执行"**，不在维护会话内自问自答冒充独立测试。
