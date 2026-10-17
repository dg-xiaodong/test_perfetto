# 任务 3：A/B 数据判读

X5 上两条 trace，同一配置（`dump_phase_ms: 3000`、`dump_interval_ms: 2000`）：

- A（无 tick）：`heap_profile` 1 份 dump，`dur=0`；alloc=free=28 MiB；max live=0；
- B（tick 200ms）：6 份 dump，`dur` 全为 0；alloc=free=28.23 MiB；max live=8 MiB；live 曲线 `8,8,8,0,0,0`。

请逐项给出判定（PASS / FAIL / UNKNOWN）并说明依据：
1. dump 数与配置 interval 的关系；
2. 总量与 free 匹配；
3. live 持有与回落；
4. 符号/调用栈；
5. 精确持有区间（8 秒）。
不要因为 `dur=0` 就把全部结论判未知。
