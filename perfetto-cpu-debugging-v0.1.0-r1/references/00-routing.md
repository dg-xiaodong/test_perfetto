# 场景路由

| 症状 | 首个数据源 | 需要排除 | 最小下一层 |
|---|---|---|---|
| CPU 总使用率高 | sched_switch → sched_slice | 线程名重复、idle、观测窗口不全 | 以 UPID/UTID 定位线程，`08-core-busy.sql` 查看每核近似忙碌比例；必须找代码热点才启用 perf |
| 周期尖峰 | sched_switch → 时间桶/spike | 跨桶整段计入起始桶、时间区间未裁剪 | 工作负载标记/CPU 采样 |
| 低 CPU 却有业务超时 | sched_switch + sched_waking → thread_state | Sleeping 误判 Runnable；缺唤醒事件 | Runnable 排队、waker，必要时结合业务标记 |
| 怀疑频率限制 | linux.sys_stats(cpufreq) + power/cpu_frequency | 没有变化事件误判为 0；cpu_idle | 调度同窗，必要时平台功耗/温度事实 |
| 哪个函数耗 CPU | linux.perf sampled callstacks | perf 权限/数据缺失/符号缺失/采样偏差 | 控制样本率、匹配目标、离线符号化 |

首轮优先 10–20 秒短 trace。已经获得足够结论就停止。不可为了“更确定”自行扩展多轮压力与故障注入测试。
