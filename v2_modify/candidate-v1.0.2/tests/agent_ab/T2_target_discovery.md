# 任务 2：目标发现与 SQL 参数

一条 Perfetto trace 里有两个同名进程：`/data/memprobe`，upid 191 有 1 份 dump / 4 条 allocation 行；
upid 193 没有任何 heap 数据（preload fork 出的 heapprofd 子进程）。你的目标是 upid 191 的 `libc.malloc`。

请回答：
1. 候选发现 SQL（列出 upid/pid/name/目标 heap 的 dump 与记录数、歧义）。
2. 解析规则：什么情况下可以用？有歧义怎么办？用户已指定 PID/UPID 时呢？
3. `sql/03-native-live.sql`、`sql/04-native-callstacks.sql` 里 `target_upid` 该怎么填？
   留 `-1` 返回 0 行说明什么？能不能当成"没有分配"？
