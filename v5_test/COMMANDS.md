# 本次实际执行命令（首轮完整诊断留档）

> 板卡口令已脱敏为 `<PW>`（原环境为测试板默认口令，不落盘）。
> `sshpass`/`scp` 仅用于本次只读查看与取证文件拉回；未改动业务、系统配置、启动脚本或他人 tracing。

## 0. Skill 核验

```sh
cd /root/.dsh/skills/perfetto-scheduling-debugging
python3 scripts/verify_package.py
# -> PACKAGE_PASS version=0.1.0 status=candidate hashes=54 resources=44

python3 -m unittest discover -s tests
# -> Ran 59 tests in 9.323s / OK (skipped=1)
```

## 1. 只读侦察（板端）

```sh
sshpass -p <PW> scp scripts/survey.sh root@192.168.1.10:/tmp/survey.sh
sshpass -p <PW> ssh root@192.168.1.10 'sh /tmp/survey.sh report'
# TRACEFS=/sys/kernel/debug/tracing, 0-7, perf_event_paranoid=2, kptr_restrict=0,
# trace_clock=[local] ... boot ..., tracing_on=1, events/enable=0；无 perfetto/traced，只有 /usr/bin/perf

sshpass -p <PW> ssh root@192.168.1.10 '/userdata/sched-case/sched-case-ctl status'
# -> state running, pid 977, threads 13, cores 1-2, helper 987
#    （RUNNING_BRIEF 里是 pid 3471：板卡已重启，PID/TID 全部重新读取）

sshpass -p <PW> ssh root@192.168.1.10 'for t in /proc/977/task/*; do echo "$(basename $t) $(cat $t/comm)"; done'
# -> 977 sched-case-daem / 988 req-dispatch / 989 worker-one / 990 worker-two / 991..993 stage-*
#    994 compute-1 / 995 compute-2 / 996 ipc-client / 997 echo-one / 998 timer-one / 999 decoy-one
#    helper 987 sched-case-help；线程级亲和性：977=1-2, 988/994/995=2, 其余=1, 987=1-2

sshpass -p <PW> ssh root@192.168.1.10 'sh /tmp/survey.sh --events > /tmp/events.txt'
sshpass -p <PW> ssh root@192.168.1.10 'sh /tmp/survey.sh --formats /tmp/fmts'
sshpass -p <PW> scp root@192.168.1.10:/tmp/events.txt data/available_events.txt
sshpass -p <PW> scp root@192.168.1.10:/tmp/fmts/sched_switch.format data/formats/
sshpass -p <PW> scp root@192.168.1.10:/tmp/fmts/sched_waking.format data/formats/
```

## 2. 已有 trace 复用性检查（结论：不可复用）

```sh
sshpass -p <PW> scp root@192.168.1.10:/userdata/cpu-diag-1018-013326/cpu.pftrace data/
sshpass -p <PW> scp root@192.168.1.10:/userdata/cpu-lab/perfetto-session/cpu.pftrace data/
/root/.cache/perfetto-skill/trace_processor_shell query <trace> \
  "select count(*) from process where name like '%sched%'"
# -> 0 （两份历史 trace 均属于另一套 cpu fixture，不含 sched-case-daemon/helper，不能回答本案）
```

## 3. 主采集 C1（仅调度数据，60 s，相位对齐到突发窗口）

```sh
python3 scripts/make_config.py overview --cpu-count 8 --duration-ms 60000 \
  --events <work>/data/available_events.txt --trace-buffer-kib 16384 \
  --output <work>/capture1/overview.pbtxt
python3 scripts/validate_config.py <work>/capture1/overview.pbtxt --check-resources
# -> RESOURCES_PASS / POLICY_PASS / SCHEMA_UNKNOWN（当时未给 descriptor）

sshpass -p <PW> ssh root@192.168.1.10 'mkdir -p /userdata/sched-diag'
sshpass -p <PW> scp scripts/record.sh <work>/capture1/overview.pbtxt root@192.168.1.10:/userdata/sched-diag/

# 等 uptime>=175 s 再启动，使突发窗口落在 trace 中段
sshpass -p <PW> ssh root@192.168.1.10 \
 'while [ "$(cut -d. -f1 /proc/uptime)" -lt 175 ]; do sleep 0.5; done; \
  TRACEBOX=/userdata/cpu-lab/perfetto-session/tracebox \
  sh /userdata/sched-diag/record.sh /userdata/sched-diag/overview.pbtxt /userdata/sched-diag/cap1 85'
# -> READY pid=1420 / RECORDED_DATA_UNCHECKED size_bytes=1856154 / collector_rc=0 timeout=0
#    trace 区间 175.900–235.425 s

# 拉回（pull.sh 需 SSH key；本会话用口令认证，按同样的 .partial → 校验 → mv 语义手工执行）
sshpass -p <PW> scp root@192.168.1.10:/userdata/sched-diag/cap1/{trace.pftrace,config.pbtxt,status.txt,exit.txt,collector.log} capture1/host/
sha256sum capture1/host/trace.pftrace   # 42d885fe…d6693，与板端一致
```

## 4. 定向补采 C2（有过滤的事件栈 + futex syscall，60 s）

```sh
python3 scripts/make_config.py block-wake --cpu-count 8 --duration-ms 60000 --page-size 4096 \
  --tid 977 --tid 988 --tid 987 --tid 994 --tid 995 --tid 996 \
  --events <work>/data/available_events.txt --formats <work>/data/formats \
  --with-futex --trace-buffer-kib 16384 --output <work>/capture2/block-wake.pbtxt
python3 scripts/validate_config.py <work>/capture2/block-wake.pbtxt --check-resources
# -> RESOURCES_PASS / POLICY_PASS

sshpass -p <PW> scp <work>/capture2/block-wake.pbtxt root@192.168.1.10:/userdata/sched-diag/
sshpass -p <PW> ssh root@192.168.1.10 \
 'while [ "$(cut -d. -f1 /proc/uptime)" -lt 416 ]; do sleep 0.5; done; \
  TRACEBOX=/userdata/cpu-lab/perfetto-session/tracebox \
  sh /userdata/sched-diag/record.sh /userdata/sched-diag/block-wake.pbtxt /userdata/sched-diag/cap2 85'
# -> READY pid=1847 / RECORDED_DATA_UNCHECKED size_bytes=2750785 / collector_rc=0 timeout=0
#    trace 区间 416.951–476.808 s；突发窗口 436.039–436.171 s

sshpass -p <PW> scp root@192.168.1.10:/userdata/sched-diag/cap2/{trace.pftrace,config.pbtxt,status.txt,exit.txt,collector.log,targets-before.txt} capture2/host/
sha256sum capture2/host/trace.pftrace   # fd34cfd8…50e6，与板端一致
```

## 5. 官方 schema 校验（v57.1 descriptor）

```sh
# protos 取自公开 v57.1 tag（raw.githubusercontent.com/google/perfetto/v57.1 递归抓取 56 个 .proto）
protoc -I protos_v571 --include_imports \
  --descriptor_set_out=capture2/config.desc \
  protos_v571/protos/perfetto/config/trace_config.proto
# -> config.desc sha256 a0c13f5e…3d463e34；metadata 写入 config.desc.json

python3 scripts/validate_config.py capture1/overview.pbtxt \
  --descriptor capture2/config.desc --descriptor-metadata capture2/config.desc.json \
  --collector-version v57.1-c59f57dd4
# -> POLICY_PASS + SCHEMA_PASS

python3 scripts/validate_config.py capture2/block-wake.pbtxt \
  --descriptor capture2/config.desc --descriptor-metadata capture2/config.desc.json \
  --collector-version v57.1-c59f57dd4
# -> POLICY_PASS + SCHEMA_PASS
```

## 6. 查询（每个 SQL 独立执行，输出到独立目录）

`run_query.py` 会把渲染后的 SQL、stdout、stderr、退出码与 trace/TP/SQL 的 SHA256 一起写入输出目录（`run.json`）。

```sh
TP=/root/.cache/perfetto-skill/trace_processor_shell
run() { python3 scripts/run_query.py --tp $TP --trace "$1" --sql "$2" --out "$3"; }

# 清点
run capture1/host/trace.pftrace sql/00-threads.sql  analysis/00-threads
run capture1/host/trace.pftrace sql/00a-bounds.sql   analysis/00a-bounds
run capture1/host/trace.pftrace sql/00b-quality.sql  analysis/00b-quality
run capture1/host/trace.pftrace sql/00c-schema.sql   analysis/00c-schema
run capture2/host/trace.pftrace sql/08-perf-streams.sql analysis2/08-perf-streams
run capture2/host/trace.pftrace sql/08a-perf-tracks.sql analysis2/08a-perf-tracks   # session→timebase 反查

# 渲染 + 状态窗口（cap1 / cap2 各一组）
python3 scripts/render_sql.py sql/01-state-window.sql --utid 226 \
  --start-ns 196039000000 --end-ns 196171000000 --output sql_custom/01-226-burst.sql
python3 scripts/render_sql.py sql/01-state-window.sql --utid 2 \
  --start-ns 436039000000 --end-ns 436171000000 --output sql_custom/01b-utid2-burst.sql
python3 scripts/render_sql.py sql/02-wait-episodes.sql --utid 2 \
  --start-ns 436000000000 --end-ns 436210000000 --output sql_custom/02-utid2-burst.sql
python3 scripts/render_sql.py sql/03-cpu-competitors.sql --cpu 2 \
  --start-ns 436039000000 --end-ns 436171000000 --output sql_custom/03b-cpu2.sql
python3 scripts/render_sql.py sql/04-runnable.sql --utid 2 \
  --start-ns 436039000000 --end-ns 436172000000 --output sql_custom/04-utid2-burst.sql
python3 scripts/render_sql.py sql/09-futex-slices.sql --utid 2 --output sql_custom/09-u2.sql

# E2：先核对来源与时钟，再逐个等待关联（tolerance 150 µs 有实测依据，见 REPORT §6.1）
for w in 60401 60642 61093 61257 61509 61896; do
  python3 scripts/render_sql.py sql/05-event-pair.sql --utid 2 --wait-id $w \
    --switch-session 1 --waking-session 0 --clock-verified 1 --streams-verified 1 \
    --tolerance-ns 150000 --output sql_custom/05-w$w.sql
  run capture2/host/trace.pftrace sql_custom/05-w$w.sql analysis2/05-w$w
done

# 调用栈（对选定的真实 callsite，不做整 trace 汇总）
for cs in 3 164 10 15 18 21 203 209 214 217 223 257; do
  python3 scripts/render_sql.py sql/06-callstack.sql --callsite-id $cs --output sql_custom/06-cs$cs.sql
  run capture2/host/trace.pftrace sql_custom/06-cs$cs.sql analysis2/06-cs$cs
done
```

自定义查询（`sql/` 目录内，均为本次写的最小查询）：

- `burst-states.sql` — cap1 窗口内 req-dispatch 原始状态区间（发现 10 ms Running / 34 ms Runnable 结构）
- `thread-state-burst.sql` / `thread-state-all.sql` — 全部目标线程状态分解（窗口 / 全 trace）
- `target-rail.sql` — 目标进程 + helper 的完整状态时间线
- `top-runnable.sql` — 最大 Runnable 区间排行（含对全 trace 的判读）
- `cpu2-timeline.sql` — CPU 1/2 的 5 ms 桶占用时间线
- `wake-edges.sql` / `wake-edges2.sql` / `cross-wake-edges.sql` — 唤醒边（含跨进程、irq_context 区分）
- `request-accounting.sql` — 用日志请求边界与 trace 状态求交，逐请求分解 queue/S/R/Running
- `perf-by-utid.sql` — perf 样本归属审计（session × cpu × utid）
- `perf-vs-ftrace-offset.sql` / `align-check.sql` — perf 样本与 ftrace 事件的时间偏差/对齐核对
- `cross-process` / futex 包含关系直接用内联查询（见 REPORT §7；查询语句保存在 `results/` 对应 `query.sql`）

## 7. 交付与推送

```sh
mkdir -p x5_sched_debugging/{traces,configs,logs,results,data,sql}
cp capture1/host/trace.pftrace x5_sched_debugging/traces/cap1-overview.pftrace
cp capture2/host/trace.pftrace x5_sched_debugging/traces/cap2-blockwake.pftrace
# …（REPORT.md / README.md / logs / results / sql / data / configs）
sha256sum $(find x5_sched_debugging -type f) > x5_sched_debugging/SHA256SUMS

cd /root/github_test/x5_heapprofd_traces        # origin = git@github.com:dg-xiaodong/test_perfetto.git
git pull --rebase
cp -a <work>/deliverable/x5_sched_debugging .
git add x5_sched_debugging
git commit -m "Add X5 sched-case-daemon scheduling/sync diagnosis (Perfetto E1/E2/E3)"
git push origin main
```
