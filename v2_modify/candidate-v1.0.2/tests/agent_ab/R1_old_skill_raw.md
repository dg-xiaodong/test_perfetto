# 旧版（v1.0.0）首轮原始输出

加载声明：读取 SKILL.md、references 02/04/05/06/07/08/09、sql 00/03/04、configs；未读 skill_candidate、历史会话、诊断报告。

## T1 执行前提
(1) 检查分层：
- 只能静态完成（主机、不碰板端）：file/readelf 确认 aarch64 ELF、经 INTERP 动态链接、malloc/free 为动态未定义符号（静态链接程序不走 LD_PRELOAD）；preload .so 的架构、GLIBC_* 需求 ≤2.35、NEEDED 可解析；用与**板端采集器同版本**的 proto descriptor 跑 validate_config.py（语法通过≠数据源存在）；编译期 -g -O1 -fno-omit-frame-pointer -fno-optimize-sibling-calls。
- 必须运行期证据：/data 挂载类型与余量（tmpfs 文件本身吃 RAM：32MiB trace + 8MiB shmem + 输出）；tracebox 版本与 heapprofd producer 真实存在（tracebox perfetto --query）；preload 是否真加载进目标进程；BLOCKING_INIT 是否生效且首次 malloc 不阻塞；目标 argv 是否真被匹配；采集后真有该 UPID 的 heap 行/符号/非零 stats。“映射了 glibc”只是必要条件，不证明 unwind/socket/daemon/ABI。
(2) 实际名 memprobe_arm64 而配置写 process_cmdline: "memprobe" → 精确匹配不命中，trace 只剩系统 counters、heap 为空；这是**静默失败**，必须靠运行期验收（UPID 有无 heap 行）发现，绝不能把空 profile 读成“没有分配”。改名或改配置为 memprobe_arm64；不要拿 glob 当跨版本通用能力。
(3) 命令：
静态
  file memprobe_arm64; readelf -h memprobe_arm64 | grep -E 'Class|Machine'
  readelf -l memprobe_arm64 | grep INTERP
  nm -D --undefined-only memprobe_arm64 | grep -wE 'malloc|free|calloc'
  readelf -d libheapprofd_glibc_preload.so | grep NEEDED
  readelf --version-info libheapprofd_glibc_preload.so | grep -o 'GLIBC_2\.[0-9]*' | sort -u
  python3 scripts/validate_config.py native.pbtxt --descriptor-set trace_config.desc
运行期（板端只读）
  mount | grep ' /data '; df -h /data; df -i /data
  /data/tracebox --version; /data/tracebox perfetto --query | grep -i heapprofd
  P=$(pgrep -f memprobe | head -1); tr '\0' ' ' < /proc/$P/cmdline; echo
  tr '\0' '\n' < /proc/$P/maps | grep -c heapprofd
采集后必查 heap_profile_allocation 有该 UPID+libc.malloc、stats 无 data loss/断开、符号状态。

## T2 目标发现与 SQL 参数
(1) 候选发现 SQL：
SELECT p.upid, p.pid, p.name, p.start_ts, p.end_ts,
       COUNT(a.size) AS n_rows, COUNT(DISTINCT a.ts) AS dumps,
       SUM(CASE WHEN a.size>0 THEN a.size ELSE 0 END)/1048576.0 AS alloc_mib,
       SUM(CASE WHEN a.size<0 THEN -a.size ELSE 0 END)/1048576.0 AS free_mib,
       MIN(a.ts) first_ts, MAX(a.ts) last_ts
FROM process p LEFT JOIN heap_profile_allocation a
  ON a.upid=p.upid AND a.heap_name='libc.malloc'
WHERE p.name GLOB '*memprobe*'
GROUP BY p.upid,p.pid,p.name ORDER BY p.upid;
另查歧义：SELECT name,COUNT(*) FROM process WHERE name GLOB '*memprobe*' GROUP BY name;
本例：191 有 1 dump/4 rows；193 n_rows=0（preload fork 的 heapprofd 子进程，同名不同 UPID）。
(2) 解析规则：仅当 n_rows>0 且能唯一确定 UPID 才填参数；UPID 是 trace 内标识、跨 trace 不可复用，PID 复用须按 start_ts/end_ts 核对实例；“无 heap 行”只说明本次未被采样，≠没有分配。同名多进程即歧义：不能只用名字当键，按 pid+时间窗+复现动作对齐，或补采时用显式 pid:（配 no_startup:true），不猜。用户已给 PID/UPID 时以用户为准，但须校验该 UPID 存在、在 trace 窗口内、确有 heap 行；若它无数据，报告“该 UPID 无 heap rows/可能选错”，不要静默替换成另一个 UPID。
(3) target_upid 填 191、target_heap='libc.malloc'，start_ts/end_ts 留 0..max（03 的前缀和发生在窗口过滤前，保留基线；04 必须先过滤再递归聚合）。留 -1 返回 0 行只说明占位符未替换（upid=-1 不存在），**不能当作“没有分配”**；即使真填无数据的 193 得 0 行，也只能说“这份 trace 该 UPID 无 heap 数据”。

## T3 A/B 数据判读
先定口径：dur=0 是 native 快照/增量表的正常属性（dump 是聚合快照，不是逐次 malloc 事件），dur 不承担时间含义 → 不能用它否定结论，也不能用它算区间；时间依据是各份 dump 的 ts。
- dump 数与 interval：B PASS / A FAIL。启动必有一份 dump（phase 不能推迟首份），phase 3000+interval 2000 在约 11s 会话应为 1+5=6 份，B 吻合（仍须用实际 ts 差核对≈2000ms）；A 仅 1 份 = 只有启动 dump，连续 dump 未生效或会话早停/匹配过晚，A 不可当正常基线。
- 总量与 free：PASS（两者）。28 vs 28.23MiB 差 ~0.8%，在采样估计方差内，不算显著差异；alloc≈free 说明配对释放，窗口内净变化≈0。
- live 持有与回落：B PASS / A UNKNOWN。B 的 8,8,8,0,0,0 是 dump 级证据，支持“持有 8MiB→后来释放”；A max live=0 只是只有一份 dump、看不到持有过程，不是“没有持有/没有分配”。
- 符号/调用栈：UNKNOWN（题目无 frame/mapping 证据）。查：SELECT COUNT(*) n, SUM(f.name IS NULL) unnamed, SUM(m.name IS NULL) unmapped FROM stack_profile_frame f LEFT JOIN stack_profile_mapping m ON m.id=f.mapping; 有名 ≠ 帧全解析。
- 精确持有区间 8s：FAIL。2s 粒度只能给界：分配落在首份 live>0 的 dump 之前一个 interval 内，释放落在 8→0 那两份 dump 之间 → 持有 ∈ (4s, 8s)，8s 是上界候选而非实测值。
下一步：要精确区间用程序自身 CLOCK_MONOTONIC 日志与 trace 时钟对齐，或缩短 dump_interval_ms / 用 peak 模式；并在同一会话内重跑 A，判定 1 份 dump 是配置未生效还是会话太短。
