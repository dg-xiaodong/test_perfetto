# 平台、启动顺序与离线 X5

依据：[S01/S07/S13/S14/S22](sources.md)。命令示例中的主机变量先填真实值；Agent给用户最终执行稿时应填好已知值，不要求用户修改一堆无关模板。

## 1. Android：系统已有Perfetto的路线

【主机】选定设备并确认环境：

```bash
adb devices -l
adb shell getprop ro.build.version.sdk
adb shell getprop ro.build.type
adb shell ps -A
adb shell perfetto --help
```

多设备时设置明确的ANDROID_SERIAL。Native与graph分别检查目标app的profileable/debuggable条件；不同系统服务可能另有限制，root也不等于所有SELinux路径开放。

【主机】生成配置后：

```bash
adb push memory.pbtxt /data/local/tmp/memory.pbtxt
adb shell perfetto --txt -c /data/local/tmp/memory.pbtxt \
  -o /data/misc/perfetto-traces/memory.pftrace
# 采集期间在另一个终端/设备上复现；有限duration结束后再拉回
adb pull /data/misc/perfetto-traces/memory.pftrace ./memory.pftrace
```

该输出目录沿用系统Perfetto常见写入方式；产品权限不同时根据报错选择允许目录，不猜测任意/data路径均可写。保留终端日志；完整配置包含duration或trigger结束条件。

启动阶段需要先使会话就绪再启动目标。在实际版本支持时可用 `--background-wait`；它等待数据源就绪/超时并返回状态，不等于证明目标进程随后已被采样。不要使用普通 `-b` 后立即启动就宣称已无启动竞态。

只采heap可以优先使用官方helper（在主机运行，负责adb）：

```bash
python3 heap_profile android -n com.example.app -i 4096 -c 5000 \
  -d 30000 --no-block-client
```

这些是当前helper参数，先核对本机脚本help；保留它打印的raw-trace目录。`-o`目录在当前实现中应预先存在且为空；不应覆盖他人的输出。普通trace联合多数据源时使用完整配置路线。

## 2. 普通Linux：官方host模式

在**运行被测程序的Linux机器**上：

```bash
python3 heap_profile host -i 4096 -c 5000 --no-block-client -- ./memprobe heap 16 6000 2
```

官方helper会选择本机架构并准备工具、开启会话、通过LD_PRELOAD运行目标及导出结果。`host`指本机，不是把命令运行在x86 PC就能远程注入ARM X5。需要网的首次自动下载应在合适环境完成；可以使用help支持的`--preload-library`、`--tracebox-binary`等本地覆盖参数。

只读根文件系统不一定妨碍采集，但输出、运行时socket、共享内存、库依赖、目标权限与挂载noexec分别要检查。动态链接glibc只是必要条件之一。静态或自定义allocator的替代方案见02-native。

## 3. X5离线部署：用户报告的环境，不是本包实测

用户在本次对话报告：aarch64、Linux6.1.83、glibc2.35；板上tracebox v57.1基础内存采集已跑通；无网络/无Python；`/`只读；`/data`可写但为tmpfs；实际tracefs为`/sys/kernel/debug/tracing`。heapprofd全链路与真实相机CMA场景尚未验证。

所以：主机负责生成配置、版本检查与分析，目标仅需shell、匹配ARM64的工具和获准运行的测试进程。不要把主机helper自动选中的x86二进制直接推到X5。

### 3.1 基础采集完整路径

【主机，已填真实登录目标】

```bash
BOARD='user@board-address'
# 替换为你SDK中已核实架构/版本的文件
TRACEBOX_ARM64='/absolute/sdk/path/tracebox'
scp "$TRACEBOX_ARM64" scripts/survey.sh "$BOARD:/data/"
ssh "$BOARD" 'chmod +x /data/tracebox; sh /data/survey.sh' > survey.txt
ssh "$BOARD" 'sh /data/survey.sh --events' > available_events.txt
python3 scripts/make_config.py rss-spike --platform linux \
  --events available_events.txt --duration-ms 10000 > memory.pbtxt
scp memory.pbtxt "$BOARD:/data/"
ssh "$BOARD" '/data/tracebox --txt -c /data/memory.pbtxt -o /data/memory.pftrace' \
  > collect.log 2>&1
scp "$BOARD:/data/memory.pftrace" ./memory.pftrace
```

采集命令运行期间通过另一个终端复现。已有可用tracebox不重复覆盖；示例传工具的步骤只在首次准备时执行。建议产物用不同会话目录/文件名，避免覆盖未拉回的证据。

`/data`为tmpfs时，trace和测试文件本身吃RAM并可能抬高shmem。短时采集、控制buffer/文件预算、及时拉回；掉电前不拉回会丢失。不要用在tmpfs写300MiB文件来“制造anon尖峰”。

### 3.2 heapprofd手动路径：先测试，后业务

下面是根据官方host启动流程整理的**待目标版本验证**方案。它不是“复制.so就必定跑通”的承诺。

先确认SDK的tracebox构建具备相应Linux heap支持、preload依赖全部可解析、两者版本/ABI相容、socket可访问。用tracebox原生applet向**本次实际服务**查询：`tracebox perfetto --query`；不要用另一次私有autostart查询误判现有服务。某些heap producer按需出现，需结合当前构建和真实启动日志判断，而非只凭一次空查询断言支持/不支持。

【主机】生成匹配测试程序名称的native配置并推送：

```bash
python3 scripts/make_config.py native --platform linux --process memprobe \
  --duration-ms 30000 --dump-ms 5000 > native.pbtxt
# 将匹配的arm64 preload、memprobe和配置推到/data；不要自动改cam-service启动项
```

【目标机，仅在实际help支持这些参数且没有系统socket冲突时】

```bash
/data/tracebox --system-sockets --background-wait --txt \
  -c /data/native.pbtxt -o /data/native.pftrace > /data/native.log 2>&1
# 只有上一步返回成功才继续；先确认测试程序超时控制工具存在
command -v timeout
# timeout放在env外层，避免让timeout本身也被预加载/阻塞初始化
# 只运行已获准的独立测试程序；25秒应小于本次30秒会话剩余时长
timeout 25s env LD_PRELOAD=/data/libheapprofd_glibc_preload.so \
  PERFETTO_HEAPPROFD_BLOCKING_INIT=1 /data/memprobe heap 16 6000 2
```

这两条命令是逐步执行示意，不是忽略前一步失败的脚本。没有timeout则提供其他明确测试看门狗后再用blocking init。`--system-sockets`是官方host流程的关键之一，但会与既有系统服务产生资源/命名冲突；遇到冲突应复用或按对应实现调整端点，不擅自pkill其他会话。

--background-wait需要该版本/构建验证；不支持就走官方helper等价的notify-fd就绪握手，或先明确升级同套工具。不能改成随便sleep一下后仍宣称覆盖全部启动分配。分析器升级不等于采集端升级。

等待有限会话真正结束并完成flush后拉回native.pftrace和native.log；检查heap_profile_allocation有目标UPID数据、符号和采样质量。之后才考虑在可重启的测试环境运行cam-service；用户报告的“前提具备”不能升级成“业务已实测”。

## 4. 通用 Linux 采集生命周期（普通 trace / native heapprofd）

本节给两种可复用的生命周期。它们不绑定某个应用名，也不假设 `/data` 或
`/data/perfetto-worker`；所有路径、目标名和配置由调用者填入。X5 的离线约束仍见第 3 节。

### 4.0 主机/目标变量与完成条件

- 【主机】负责生成配置、推送、启动远程命令、拉回与 Trace Processor 分析。
- 【目标机】负责 tracebox 会话、preload、目标进程和输出文件；`TRACEBOX`、`WORK`、
  PID、超时、SIGINT/flush 都在目标机解析，不能把 `$!`、`$(...)` 放进主机双引号里展开。
- 完成条件不是“命令返回 0”或“文件存在”：还要求目标 UPID/窗口真实存在、
  目标数据非空、没有影响结论的数据丢失；SCP 失败必须非零退出。
- `scripts/linux_trace_session.sh` 与 `scripts/linux_heapprofd_session.sh` 的目标机参数：
  `WORK`（可写目录）、`TRACEBOX`（可执行文件）；heapprofd 还要
  `OBSERVE_S`（默认 30）与可选 `PERFETTO_*_SOCK_NAME`。
- 对应主机拉回脚本：`scripts/host_pull.sh BOARD REMOTE_DIR DEST FILE...`。

### 4.1 普通 Linux trace（无 LD_PRELOAD）

适用于 process/sys counters、ftrace、mmap、perf 等不需要目标进程预加载的路线。

```bash
# 【主机】在 Skill 目录执行
BOARD='user@linux-host'
WORK='/data/perfetto-session'
TRACEBOX='/data/tracebox'          # 目标机上的 tracebox
HOST_OUT='./captures'
CFG='overview.pbtxt'               # 由 make_config.py 生成
OUT='overview'                     # 目标机输出前缀

ssh "$BOARD" "mkdir -p $WORK"
scp "configs/$CFG" scripts/linux_session_lib.sh \
    scripts/linux_trace_session.sh "$BOARD:$WORK/"
ssh "$BOARD" "WORK=$WORK TRACEBOX=$TRACEBOX \
  sh $WORK/linux_trace_session.sh $WORK/$CFG $WORK/$OUT 60"
sh scripts/host_pull.sh "$BOARD" "$WORK" "$HOST_OUT" \
  "$OUT.pftrace" "$OUT.log" "$OUT.status"
```

目标机脚本行为：后台启动 tracebox，记录 PID；等待会话结束或超时；SIGINT 后等待
flush；输出文件为空或 tracebox 不退时非零退出，并写 `.status`。
`DONE` 才是正常完成；`TIMEOUT_STOPPED` 表示已停止但超时，`.pftrace` 保留，退出码
为 10，验收应标 UNKNOWN/补采；`TIMEOUT_STOP_FAILED`/`EMPTY` 同样不能算成功。
宿主侧拉回脚本对 scp 失败/空文件立即非零退出。

采集期间在另一个终端复现业务；需要提前停止时只对本会话 PID 发 SIGINT，不要
`pkill traced` 或杀其他会话。

### 4.2 Native heapprofd（LD_PRELOAD）

适用于 malloc/new 的调用栈归因。普通 Linux 上 heapprofd 需要目标进程**启动时**
加载匹配的 preload；已运行且未预加载的进程不能靠设置环境变量回溯。

```bash
# 【主机】先完成 4.0 与 02-native 的版本/ABI/preload 检查
BOARD='user@linux-host'
WORK='/data/perfetto-session'
TRACEBOX='/data/tracebox'
PRELOAD='./libheapprofd_glibc_preload.so'   # 与采集器匹配的 ARM64/x86_64 版本
APP_DIR='/path/to/test-app'
APP_CMD='./test-app'
APP_NAME=$(basename "$APP_CMD")            # 必须等于实际启动 argv[0] basename
OBSERVE_S=30
HOST_OUT='./captures'

# 不要直接复制 configs/native.pbtxt：目标名/时长必须匹配本次测试。
# 总时长 90 s > OBSERVE_S 30 s + 启动/producer 等待/停止/flush 余量。
python3 scripts/make_config.py native --platform linux --process "$APP_NAME" \
  --duration-ms 90000 --dump-ms 2000 > native.pbtxt
python3 scripts/validate_config.py native.pbtxt --deploy-name "$APP_NAME"

ssh "$BOARD" "mkdir -p $WORK"
scp native.pbtxt scripts/linux_session_lib.sh \
    scripts/linux_heapprofd_session.sh "$PRELOAD" "$BOARD:$WORK/"
ssh "$BOARD" "WORK=$WORK TRACEBOX=$TRACEBOX OBSERVE_S=$OBSERVE_S \
  sh $WORK/linux_heapprofd_session.sh $WORK/native.pbtxt \
  $WORK/libheapprofd_glibc_preload.so $APP_DIR $APP_CMD"
sh scripts/host_pull.sh "$BOARD" "$WORK" "$HOST_OUT" \
  heap.pftrace heap.log heap.status heap.query.txt heap.app.log
```

`validate_config.py --deploy-name` 失败时（目标名不匹配）停止，不要继续推送/采集。
若 `APP_CMD` 是 wrapper，`APP_NAME` 必须取最终 exec 的 argv[0] basename，不能取 wrapper 名。
`linux_heapprofd_session.sh` 还会读取配置的 `duration_ms`，要求
`duration_ms >= OBSERVE_S*1000 + 30000`；不足时在启动 trace 前失败。

目标机脚本行为：

1. 启动 tracebox（默认 `--system-sockets`）；若显式提供 `PERFETTO_*_SOCK_NAME`
   则改用该端点。`duration_ms` 只是安全上限，不是观测时长。
2. 轮询 `tracebox perfetto --query` 等服务可查询；这只证明服务在，不证明目标已采样。
3. 在 `APP_DIR` 下以 `LD_PRELOAD` + `PERFETTO_HEAPPROFD_BLOCKING_INIT=1` 启动测试进程。
4. 等 `heapprofd` producer/data source 可见；不出现则停止 app/trace 并失败。
5. `OBSERVE_S` 观测后停 app，等待 flush，再 SIGINT tracebox；文件为空/不退出则失败。
6. 写 `heap.status`；主机拉回后再用 `00-inventory.sql` 核对 UPID，用
   `10-native-dump-capability.sql` 检查 dump 可见性，用
   `03/04-native-*.sql` 检查分配数据与符号。

注意：

- `--background-wait` 在“heapprofd producer 尚未注册”时可能等不到全部数据源；
  不要先等它再启动 preload 进程。用本脚本的“起 trace → 起 app → 等 producer”顺序，
  或使用官方 helper 的等价握手。
- `PERFETTO_HEAPPROFD_BLOCKING_INIT=1` 可能在初始化时阻塞；若目标启动超时，
  先用同一测试实例做短 smoke，再把启动期漏采标为 UNKNOWN，不要伪称已覆盖。
- 目标进程是静态链接、preload 依赖不满足、socket 冲突或权限不足时，退回普通
  trace/perf 路线，不把“文件非空”当成 heapprofd 成功。
- heapprofd dump 的时间是快照/窗口信息，不是每次 malloc 的真实时间；采样 count
  是估计值。详见 02-native 与 06-quality。

### 4.3 主机分析入口

普通 trace 与 heapprofd trace 拉回后，先用 `sql/00-inventory.sql` 解析 UPID；
CPU 时间桶/ spike 用 `sql/11-cpu-time-buckets.sql` 与
`sql/12-cpu-spike-episodes.sql`，参数为 UPID、窗口、桶宽和阈值。
时间窗口必须来自被查询的同一 trace；跨 trace 绝对时间戳只有在有明确时钟对齐
证据时才可用。

## 5. 主机分析工具版本

先执行`trace_processor --help`或`trace_processor_shell --help`。最省版本歧义的交付方式是直接在UI Query(SQL)执行本包SQL；CLI使用该版本帮助列出的query/SQL文件参数，不能把统一trace_processor的子命令套到老trace_processor_shell上。

采集结束仅恢复**本次会话实际改动且仍由本次拥有**的设置。survey脚本不改任何设置；不要在共享板上无条件清空trace、关全部事件或把buffer恢复成硬编码1410KiB。维护人员的历史状态不是所有设备的默认值。
