# 候选版（v1.0.1）首轮原始输出

加载声明：读取 candidate-v1.0.1 的 SKILL.md + references/02-native.md、05-platforms.md、06-quality.md、09-advanced-configs.md、sql/00、03、04、10、scripts/validate_config.py、make_config.py、survey.sh；未读 candidate 外的诊断/历史/预期答案。

## T1 执行前提
(1) 静态 preflight（只证明静态一致，不证明运行期）：`validate_config.py --check-resources`；部署名 basename 必须 == `process_cmdline`（`--deploy-name`）；`--binary` 须有 PT_INTERP（静态链接忽略 LD_PRELOAD）；有匹配 descriptor 才做 schema 校验，否则标"已构造未验证"；`sh scripts/survey.sh` 确认 glibc 2.35、/data tmpfs 余量、真实 tracefs、tracebox 存在；make_config 只接受精确名（无 glob）。
运行期才能证明：--background-wait/notify-fd 就绪、trace 内目标 UPID 的 heap_profile_allocation 行、stats+collector 日志（buffer_overran/disconnected/并发拒绝/权限）、dump 窗口是否前进、unwind/符号。
(2) 启动名 memprobe_arm64 而配置 "memprobe"：heapprofd 按 argv[0] basename 匹配 → 不匹配，永不被 profile；叠加 BLOCKING_INIT=1 时首次 malloc 等待初始化，可能永久阻塞。修：统一名或改 process_cmdline:"memprobe_arm64" 重新生成。
(3) 命令：
python3 scripts/validate_config.py --check-resources
python3 scripts/make_config.py native --platform linux --process memprobe --duration-ms 30000 --dump-ms 5000 > native.pbtxt
python3 scripts/validate_config.py native.pbtxt --deploy-name memprobe_arm64   # 期望 FAIL
python3 scripts/validate_config.py native.pbtxt --binary ./memprobe_arm64      # 期望 PASS(PT_INTERP)
scp native.pbtxt scripts/survey.sh "$BOARD:/data/"
ssh "$BOARD" 'sh /data/survey.sh; command -v timeout; /data/tracebox perfetto --query'
/data 为 tmpfs：trace+shmem 都吃 RAM，短采、控 buffer、及时拉回。

## T2 目标发现与 SQL 参数
(1) 直接跑 sql/00-inventory.sql 的 [CANDIDATES]：params target_name='memprobe', target_heap='libc.malloc'。预期两行：upid191 alloc_rows=4/activity_dumps=1/dumps=1/data_bearing=1；upid193 全 0/data_bearing=0（preload fork 的 heapprofd 子进程，同名属常态）。ambiguous=1 仅指"多于一个候选持有该 heap 数据"。
(2) 解析规则：仅当恰好一个候选 data_bearing=1 时采用它（本题→191）；否则报"未解析"，不静默取第一行；用户已给 PID/UPID 时沿用该值并核 identity，不因另一条有数据而改选；v57.1 TP 无 heap_profile 时删 dumps 子查询用 activity_dumps。
(3) target_upid 填 191（heap 'libc.malloc'，start_ts/end_ts 用纳秒窗口）；留 -1 时 0 行 = 未解析哨兵，不代表"没有分配"，必须先解析目标；193 的 0 行也只是无数据，不是无分配。

## T3 A/B 判读（逐项）
| 项 | 判定 | 依据 |
|---|---|---|
| dump 数与 interval | PASS（A=1 可解释，不判失败）；期望份数 UNKNOWN | 触发=floor((运行时长-phase)/interval)+1，可见行还要求 window_end 前进（free 用 ts=0，窗口只随非零 ts 分配推进；TP 按 (upid,window_end,heap) 去重）。A 全分配全释放→窗不前→1 份；B tick 200ms→窗前进→6 份（与参考实测 6 dump 一致）。缺总时长故不校验 6 是否恰为触发数。 |
| 总量与 free | PASS | A alloc=free=28MiB→净 0、无未释放；B 28.23MiB 为采样估计，0.23MiB 差在估计误差内，不是精确泄漏；heap live≠RSS。 |
| live 持有与回落 | PASS | B live 8,8,8,0,0,0（前缀和、快照分辨率）先持有后回落，符合持有→清理语义；A max live=0 只说明追踪窗口内净变化 0，不回溯 attach 前。 |
| 符号/调用栈 | UNKNOWN | 题面无 stack_profile_frame/04 结果与 Build ID 证据；dur=0 不影响符号判读，需实跑 sql/04 + 符号化。 |
| 精确持有区间(8s) | UNKNOWN | dur 全 0（旧采集端无 start_timestamp）→窗口不可知；仅上界证据：8MiB 于前 3 份 dump 出现、第 4 份起 0，按 2s interval 跨度约 4–6s，故"精确 8 秒"不可证且与序列不符；要精确需采集侧让窗口前进或升级发布 start_timestamp 的采集器。 |
不因 dur=0 否定总量/free/dump/符号结论（06-quality 三态要求）。
