# 三线程 TrackEvent 示例

`latency_trace.h/.cc` 是最小接入适配器，`pipeline_demo.cc` 是可控工作负载。
业务线程 pre → infer → post 通过有界队列交接。输入分两个 stream，同帧号不会合并。
每第 7 个输入包含 inference 重试（不同 stage_instance）；每第 11 个在 pre 后显式 DROP；每第 13 个在 infer 后显式 TIMEOUT。发生重叠条件时按实际代码前置终态结束。终态是测试程序显式制造，不是分析器从时长猜出的结果。

每第 5 个输入的 infer 阶段 sleep 25 ms，便于查看 Wall Time 与 CPU 的区别。trace 中只有埋点，不提供系统调度除非使用 System 联合采集。此例不是硬件推理；不得把该 stage 名称解释成真实 BPU 时间。

## 主机构建

```sh
# 从包根运行；SDK_DEST 的父目录需存在，目录自身必须是新的。
python3 scripts/prepare_sdk.py --dest /absolute/NEW_SDK_DEST
cmake -S examples/cpp -B /absolute/NEW_BUILD \
  -DPERFETTO_SDK_DIR=/absolute/NEW_SDK_DEST
cmake --build /absolute/NEW_BUILD --parallel 2
/absolute/NEW_BUILD/latency_demo --backend inprocess \
  --output /absolute/NEW_TRACE.pftrace --frames 24 --interval-ms 33
python3 scripts/analyze.py --tp /absolute/trace_processor_shell \
  --trace /absolute/NEW_TRACE.pftrace --out /absolute/NEW_ANALYSIS
```

默认输入是总流约每 33 ms 一帧，两个 stream 轮转；不是每个 stream 都 30 FPS。队列拥塞会阻塞生产者，实际输入 FPS 必须从事件计算，不能用参数直接当测量。

## ARM64 交叉构建

```sh
cmake -S examples/cpp -B /absolute/NEW_ARM64_BUILD \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/examples/cpp/aarch64-toolchain.cmake" \
  -DCMAKE_CXX_COMPILER=/absolute/compatible-aarch64-g++ \
  -DPERFETTO_SDK_DIR=/absolute/SDK_DIR
cmake --build /absolute/NEW_ARM64_BUILD --parallel 2
```

readelf/file 核实架构、解释器、GLIBC/GLIBCXX 最低符号版本和 Build ID 后再部署。CMake 不自动把二进制拷到板子，不修改启动项。

## 三种 backend 控制同一个埋点应用

- `--backend off`：同一带埋点二进制，Tracing 不开启，用于开销基线（不是未埋点原版）。
- `--backend inprocess --output NEW`：应用自管会话，保存纯 TrackEvent；文件 O_EXCL，不覆盖。
- `--backend system --wait-ms 30000`：producer 注册后等待 category 实际启用；外部 collector 负责输出。参见 references/04-platforms.md。

`--omit-terminal N` 是唯一漏事件开关：让第 N 个输入完成业务却不写 terminal 和 async END；应被判 INCOMPLETE，不允许猜成 timeout。默认关闭。其它反例使用离线 fixtures，不主动制造 Trace 数据丢失。

stdout 的每请求 JSON 是测试操作者核对计数的辅助证据，不是本 Skill 的日志转 Trace 入口；它使用与示例相同的业务上下文，不能当作独立 profiler。保存 rc 和 stderr 的 SUMMARY。

保留官方 SDK 两个源码文件的许可头。样例本次未用真实 SDK 编译或上板；功能应在首次集成测试验证，不能用 CMake 缺依赖错误测试代替编译通过。

## 已知首版边界

主流水线示例仍是单进程多线程；新增 `latency_xproc_demo` 是独立双进程的验证配方，真实 SDK/System/TP 结果仍待验证；并行分支和跨进程身份还须实际反例测试。生产场景的长驻 Track 数量、中途启停、fork、异常退出均需单独评估，不把有限帧示例当万能生产运行时。

## 跨进程 Global Track 最小示例（v0.1.1，真实运行待验）

`cross_process_slice_demo.cc` 使用两个**独立进程**发出同一 Global Track 的 Begin/End；不会修改原先的三线程示例。该例仅用于验证跨进程 `Track::Global()`，**不是完整的 `latency.v1` 请求事件**，不能用 `analyze.py` 的请求完整性状态来替代本例的 Slice 检查。

在有真实配对的 Perfetto SDK v58.2 环境完成上文 CMake 构建后：

```sh
mkdir -p /tmp/latency-xproc-test
SYNC=$(mktemp -d /tmp/latency-xproc-test/handshake.XXXXXX)
UUID=0x5850524f43abcdef  # 测试独占 UUID；另一次采集应使用不同 ID
/absolute/BUILD/latency_xproc_demo begin "$UUID" "$SYNC" demo-req-1 &
P_BEGIN=$!
/absolute/BUILD/latency_xproc_demo end "$UUID" "$SYNC" demo-req-1 &
P_END=$!
# 两个 producer 此时等候 Category enabled。第三个终端启动一次 system-sockets 采集：
# 例：使用本 Skill 的 record.sh + track-event.pbtxt（不要启动独立 InProcess 会话）。
# 等待该采集会话结束，然后回到这里：
wait "$P_BEGIN"; echo "begin_rc=$?"
wait "$P_END"; echo "end_rc=$?"
```

双方在类别实际 enabled 后才输出；`begin.sent` / `end.sent` 为测试握手文件，**不是关联依据**。两个进程的日志应报告不同 PID。必须用外部同一 System Backend 实际采集；本示例不负责启动 traced/tracebox，也不能默认板端具备两个 Producer 的条件。

通过 `trace_processor_shell -q` 运行以下 SQL（由真实 TP 确认语法与结果）：

```sql
SELECT s.id, s.track_id, s.ts, s.dur, s.dur / 1e6 AS dur_ms, t.name AS track_name
FROM slice s JOIN track t ON t.id = s.track_id
WHERE s.name = 'xproc.global_track.demo'
ORDER BY s.ts;
```

PASS 前提：输出恰好一条目标 Slice，`dur > 0`，请求标识与两端日志一致，Trace 数据无导致本例失真的丢失，源/终点确实由不同进程发送。为了验证不完整分支，可在**全新握手目录及新的 UUID**用 `end-omit` 代替 `end`，核对未闭合事件不会被报告为完成时延。并发、重用 UUID、进程重启和板端 SO 加载需要另做有界反例，不能用这一个冒烟用例宣布全面安全。

**本包没有真实 SDK/System/Trace Processor 运行证据**；与实际板端结果不同或解析器拒绝跨 Producer 合并时，必须如实报告失败及当前环境版本，不推断“官方接口存在就已验证”。
