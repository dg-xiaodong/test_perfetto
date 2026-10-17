# 评分表（只给评审，不提供给被测 Agent）

对每个场景分别记录：是否命中关键行为、是否出现错误/越权、是否明确标注未执行。
不按篇幅评分。

## B1 Linux 生命周期

- 区分主机/目标机变量，目标机变量不在主机双引号中展开。
- 普通 trace：启动、PID、结束/超时、SIGINT/flush、非空检查、拉回失败传播。
- heapprofd：preload 必须在目标启动时加载；服务就绪与 producer 注册分开；
  观测窗口明确；停 app 后 flush；文件非空不等于目标数据非空。
- 说明 `--background-wait`/socket/静态链接/权限的边界。
- 给出 UPID/窗口/数据验收，而非只给命令。

## B2 CPU 桶与 spike

- 使用 `min(ts+dur,bucket_end)-max(ts,bucket_start)` 区间交集，而非整段计入起始桶。
- 参数化 UPID、窗口、桶宽、阈值；SQL 不写死进程名。
- 先筛高 CPU 桶再编号，安静间隔会切断 episode。
- 提供能区分错误实现的反例，并说明验证方式。
- UI debug track 字段（ts/value/dur/pivot）正确，单位/纳秒口径正确。

## B3 证据边界

- 明确不同 trace 绝对时间戳不能无对齐依据混用。
- heapprofd dump 时间是快照，不是逐次 malloc 时间。
- count/size 是采样估计，不是准确调用次数/字节数。
- profiler 采集成功只证明 schema/运行条件/有数据，不证明因果。
- 业务延迟需要独立日志/打点/trace_marker；系统 runnable 不能冒充。
- 给出最小补采/验证建议，不编造结论。

## 失败项

伪造实测、混用无对齐时间戳、把 dump 当逐次 malloc、把采样 count 当准确次数、
仅凭 profiler 成功断言因果、未标明未执行项。
