# 首轮错误与 Skill 规则/实现缺口

本文件只做归因，不修改或部署 `perfetto-memory-debugging` Skill，也不把修正版表现
当作首轮盲测成绩。

分类口径：

- **规则未落实**：Skill 参考文档已经写了该约束，首轮交付没有照做。
- **缺少可复用实现**：Skill 有原则/片段，但没有可直接运行、可回归的脚本或 SQL；
  首轮只能自行实现，因而出现缺陷。
- 两者可以同时成立。

| # | 首轮问题 | Skill 中已有的规则/片段 | 归因 |
|---|---|---|---|
| 1 | `$TRACEBOX` 未定义；SSH 双引号导致 `$!`/`$(...)` 在主机展开 | `05-platforms.md` 要求区分【主机】/【目标机】并给完整执行顺序；但没有可复用的远程执行器/变量作用域封装 | **规则未落实 + 缺少实现**：没有 runner，首轮又直接拼双引号命令 |
| 2 | C2 启动 app 后缺少观测/停止/flush，可能立即杀进程 | `05-platforms.md` 3.2 给出 Linux heapprofd 的 preload/`--background-wait` 流程，并写明“只有上一步返回成功才继续”；但没有 start→producer→observe→stop→flush 状态机 | **规则未落实 + 缺少实现**：原则存在，首轮没有生命周期；Skill 无脚本 |
| 3 | C1/C3 后台采集完成条件、PID、SCP 失败仍宣称成功 | `06-quality.md` 明确四级验收、采集后检查、不能只看文件存在；但没有 host pull/失败传播脚本 | **规则未落实 + 缺少实现**：首轮未按验收规则；Skill 无 pull 脚本 |
| 4 | `10/11` 把完整 `dur` 计入起始桶 | `01-counters.md` 强调 `rss_stat` 是绝对量、不能 sum，但没有“把任意区间按 100 ms 桶切分”的可复用 SQL | **缺少实现**：Skill 无 bucket-intersection SQL；首轮自行实现错误 |
| 5 | `20` 先编号后筛高 CPU，安静间隔被合并 | Skill 没有 jitter/episode 分组规则或 SQL；`01-counters.md` 只提醒轮询/事件可能合流 | **缺少实现**：无 episode 归并 SQL；首轮自行实现错误 |
| 6 | `16` 直接用 C1 绝对时间戳筛 C3 | `06-quality.md` 要求窗口/UPID/时间口径一致；`00-routing.md` 强调关联不等于因果；但没有跨 trace 对齐检查工具 | **规则未落实 + 缺少实现**：首轮忽略时间口径；Skill 无 window guard |
| 7 | 把 heapprofd `count` 当精确调用次数；业务延迟无独立证据 | `02-native.md` 明确随机采样、`Total` 不证明 CPU/延迟；`00-routing.md` 要求业务标记/延迟证据 | **规则未落实**：规则写得很清楚，首轮 SQL/PLAN 没有把口径带下去 |

## 结论

- 第 4/5/6 条主要是**首轮 SQL/实现缺陷**；其中 4/5 也暴露 Skill 缺少可复用的区间/事件 SQL。
- 第 1/2/3 条主要是**执行流程实现缺陷**；Skill 的原则存在，但没有 runner/生命周期/pull 脚本，
  首轮在落地时放大了风险。
- 第 7 条是**明确的 Skill 规则未落实**，不是 Skill 规则缺失。

本修正版新增的 `scripts/`、`sql/16a`、`validation/tests/` 只是本交付的补丁，
不代表 Skill 已获得这些能力，也没有修改 Skill。
