# Perfetto Memory Debugging Skill

把内存问题转成：**场景选路 → 采集配置 → 执行与拉回 → 数据验收 → SQL分析 → Perfetto UI视图**。

适用Linux和Android；包含X5离线/只读rootfs部署参考。来源是用户列出的11篇官方内存文档，并补充官方proto、CLI、SQL标准库和UI说明。核心入口保持短小，按场景加载参考，不把全部文档塞进每次上下文。

## 开始使用

将整个`perfetto-memory-debugging/`目录放到你的Agent支持的skills目录，或让Agent直接读取[SKILL.md](SKILL.md)。不要只复制入口而丢掉references/scripts/sql。此包是可交付文件，没有自动安装到任何Agent、设备或GitHub仓库。

可直接向Agent提出：

> 使用perfetto-memory-debugging。X5上cam-service每隔一段时间卡顿，怀疑内存尖峰。请检查已有环境信息，给我完整采集配置、主机和板端执行步骤、验收SQL以及Perfetto UI图表操作。不要重启正在运行的业务。

其他可用请求：

> Android页面退出后Activity没有释放，帮我采对象图并查谁持有它。
>
> 我怀疑C++程序每帧反复malloc/free，RSS却很稳定；我要找到分配最频繁的调用栈。
>
> 我已有一个pprof，指导我在Perfetto UI按正确指标看火焰图；不要要求重新采集。
>
> 帮我检查这份Perfetto trace是否足以证明内存上涨导致掉帧，并给出能在UI显示的SQL。

## 覆盖什么

| 路线 | 常见场景 | 最终主要视图 |
|---|---|---|
| 内存计数器 | RSS分类、系统压力、短尖峰、file/shmem、LMK | 原生counter、SQL debug tracks |
| Native allocation | 启动分配、保留量、疑似泄漏、分配抖动、heap峰值 | Native火焰图、dump级live曲线 |
| ART allocation | Java/Kotlin对象创建热点 | Total Allocation Size/Count |
| ART graph | Activity泄漏、root路径、对象持有、OOME | Heap Dump Explorer、Dominators |
| 完整ART HPROF | 字符串/数组/位图内容、重复对象 | Strings、Arrays、Bitmaps |
| syscall/perf与内核事件 | 直接mmap、CMA重试、回收/规整、OOM | syscall/perf调用栈、事件/延迟同轴 |
| 现有pprof/符号 | 聚合profile导入、符号缺失 | Aggregate Profiles、符号化火焰图 |

完整场景见[路由表](references/00-routing.md)，11篇来源及扩展来源见[来源索引](references/sources.md)。

## 三个日常操作

### 1. 只读探测设备

```bash
# 在目标设备，只有shell依赖
sh survey.sh
sh survey.sh --events > available_events.txt
```

不会自动mount、修改sysctl、开启trace或改变生产服务。传到板上的脚本来自`scripts/survey.sh`。

### 2. 在主机生成完整配置

```bash
python3 scripts/make_config.py overview --platform linux > memory.pbtxt

python3 scripts/make_config.py rss-spike --platform linux \
  --events available_events.txt --duration-ms 10000 > spike.pbtxt

python3 scripts/make_config.py native --platform linux --process memprobe \
  --duration-ms 30000 --dump-ms 5000 > native.pbtxt

python3 scripts/make_config.py java-graph --platform android --api 34 \
  --process com.example.app --dump-ms 10000 > graph.pbtxt
```

生成器只依赖Python标准库，在主机运行。十个入口是overview、rss-spike、native、native-peak、java-alloc、java-graph、java-oom、kernel-pressure、android-lmk、mmap。它们不是能力全集，高级变体另由参考文档指导。

`configs/`内的10份pbtxt是可查看的参考产物；其中memprobe/com.example.app和事件清单是示例，不代表你的设备实测。正式使用应根据真实平台、目标、事件清单重新生成。`examples/available_events.example.txt`明确是fixture，不可当设备能力证明。

### 3. 按实际采集器版本验证，再录制

```bash
python3 scripts/validate_config.py memory.pbtxt \
  --descriptor-set /absolute/work/trace_config.desc --binary-out memory.pb
```

descriptor来自与采集器匹配的Perfetto源码，生成方法在[验收指南](references/06-quality.md)。该验证器需要主机Python protobuf；设备不需要。没有descriptor时不会假装schema已验证。

Linux/Android/X5命令、启动顺序与拉回见[平台指南](references/05-platforms.md)。取得trace后，在UI先运行SQL inventory定位实际UPID，再将后续SQL的参数填成实际值。文件中的`-1`是有意保留的安全空查询，不是进程ID；Agent生成最终分析稿时应替换它。

## 为什么能在 UI 中继续分析

每条路线都给出了对应的原生轨道/面板与判读口径；SQL时间序列明确保留纳秒ts，并指定Add debug track的类型、value与pivot。比如RSS输出MiB的anon/file/shmem/total轨道，heap输出Native火焰图与dump级live估计，graph使用对象/引用/支配树。详见[UI配方](references/04-ui.md)。

“能打开trace”不等于“问题采到了”，图表漂亮也不等于因果成立。Skill会检查目标进程、数据条数、窗口、丢失/截断、符号和单位；缺数据时给最小补采而不是编造图形。Memscope/Memory Overview是可选新版入口，不强制要求旧X5支持。

## 文件结构

```text
perfetto-memory-debugging/
├── SKILL.md                 Agent入口与交付约束
├── README.md                使用说明
├── TEST_REPORT.md           本次验证范围及未验证项
├── references/              场景、平台、原理、UI与官方来源
├── configs/                 10份参考TraceConfig
├── scripts/                 配置生成、只读探测、schema验证
├── sql/                     9份发现/分析/展示查询
├── examples/                有界C测试程序、示例事件清单
└── tests/                   契约/统计测试、28项Agent行为回归场景
```

## 验证与维护

本次验证详情见[TEST_REPORT.md](TEST_REPORT.md)。配置生成逻辑、统计口径fixture、校验器严格性和本机测试程序可在本环境测试；真实Perfetto schema、Trace Processor、UI、X5/Android端到端采集需要对应工具/设备另行验证。没有把文档核对称为板端成功。

重新运行单元测试：

```bash
python3 -m unittest discover -s tests -v
sh -n scripts/survey.sh
```

无protobuf时，校验器fixture测试会明确skip；正式schema验证仍需安装该主机依赖。Agent行为场景见[tests/scenarios.md](tests/scenarios.md)，供独立Agent回归，不声称已完成全部模型行为测试。

维护时优先核对采集器版本的proto和真实CLI帮助。官方main/UI持续演进，来源核对日期不代表未来每个版本都无条件兼容。
