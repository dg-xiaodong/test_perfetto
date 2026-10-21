# RUNNING BRIEF — pf-demo-x5 Perfetto fixture (for the analysis window)

This is the public hand-off note for the Perfetto recording/analysis window.
It tells you what is running, how to locate it, and how to record non-destructively.
It deliberately does **not** describe what the workload is expected to show.

## 1. What is running

| item | value |
|---|---|
| program | `pf-demo-x5` v1.0.0 (simulated real-time vision pipeline, C++17) |
| host | RDK X5, aarch64, buildroot, kernel `6.1.83-DR-PL5.1_V1.1.1`, glibc 2.35 |
| binary | `/userdata/perfetto-training-demo/bin/pf-demo-x5` (dynamically linked, unstripped, build-id present) |
| binary sha256 | `f89d9ed5f509868f968eac7072abe4aa2c499417f2fb48e3cfb379195c24c9b5` |
| ELF build id | `48afa3c3dcc7ac719a0063997012aaf29a1db983` |
| deployment | `/userdata/perfetto-training-demo/` |
| service mode | resident, started by a crash-limited supervisor, **no heap preload** |
| Perfetto SDK | official C++ SDK v58.2, **system backend** (`/tmp/perfetto-producer`) |
| log dir | `/userdata/perfetto-training-demo/logs/` (`pf-demo-x5.log`, `frames.log`) |

The program is not a hardware benchmark: every stage is a named simulation.
It runs continuously and repeats its internal phase sequence on its own; no
manual trigger is needed.

## 2. Locating the process and its threads

```bash
D=/userdata/perfetto-training-demo
$D/scripts/status.sh                 # deployment, pid, thread list, service health
cat $D/run/app.pid                   # application pid
cat $D/run/supervisor.pid            # supervisor pid
```

Thread names (also visible in Perfetto's process/thread tracks) are the Linux
`comm` values:

```
pf-capture   pf-preproc   pf-infer   pf-postproc   pf-output
pf-contend1  pf-contend2  pf-syncwait  pf-memheap  pf-ioworker
pf-monitor   pf-schedprobe
```

`/proc/<pid>/task/<tid>/comm` and `/proc/<pid>/task/<tid>/stat` are the
authoritative source. Log lines use `mono_ns` (CLOCK_MONOTONIC) and `boot_ns`
(CLOCK_BOOTTIME) timestamps; `PHASE` lines mark the internal phase boundaries
and can be used to align logs with trace timestamps. Frame ids restart at 1
whenever the service restarts; a `BOOT ... pid=...` line in
`logs/pf-demo-x5.log` marks each restart.

## 3. Recording a trace (non-destructive)

Preferred:

```bash
cd /userdata/perfetto-training-demo
./scripts/trace.sh 15                     # 15 s trace -> logs/pf-demo-<ts>.pftrace
./scripts/trace.sh 30 /userdata/perfetto-training-demo/logs/mine.pftrace
```

Manual equivalent (must use the system sockets):

```bash
/userdata/perfetto-training-demo/bin/perfetto/tracebox \
  --system-sockets --txt \
  -c /userdata/perfetto-training-demo/configs/trace_smoke.cfg \
  -o /userdata/perfetto-training-demo/logs/mine.pftrace
```

Then pull the trace and open it at <https://ui.perfetto.dev>:

```bash
scp root@<board>:/userdata/perfetto-training-demo/logs/mine.pftrace .
```

For CPU-profile symbolisation, also pull the unstripped binary and load it in
the UI (or keep it next to the trace for `trace_processor`):

```bash
scp root@<board>:/userdata/perfetto-training-demo/bin/pf-demo-x5 .
```

### Preconditions and constraints

1. **System backend + system sockets.** `pf-demo-x5` connects to
   `/tmp/perfetto-producer`. `tracebox` **without** `--system-sockets` uses
   private sockets and will not see the application's TrackEvent stream. Use
   `--system-sockets` (scripts already do).
2. **Root is required.** `/proc/sys/kernel/perf_event_paranoid` is `2`; CPU
   sampling and ftrace-style probes need root.
3. **Kernel limitation on this image:** the kernel is built with
   `CONFIG_FTRACE` unset (no tracefs, no sched/block tracepoints). Perfetto's
   Scheduling/CPU-idle/ftrace-CPU-frequency tracks therefore cannot be produced
   here. CPU sampling (`linux.perf`), process stats, sys_stats (meminfo/vmstat/
   per-CPU times/**cpufreq**) and the SDK's trace_event all work. Use
   `configs/trace_smoke.cfg` (not `trace_ftrace.cfg`) on this board.
4. **`tracebox` (not `perfetto`) for CPU samples.** The deployed
   `traced_probes` binary has no perf producer; tracebox bundles `traced_perf`.
   `perfetto` CLI captures still work for process_stats/sys_stats/track_event.
5. **Do not disturb the service.** Captures are read-only: do not stop,
   restart, reconfigure, redeploy or reboot. Do not edit files under the
   deployment directory while capturing. If you need to change something,
   coordinate with window A first.
6. **Freeze on first capture.** Once you start collecting data for the deck,
   the program version and its deployment are frozen; a program restart shifts
   the phase origin and invalidates log/trace alignment.
7. **Heap (native) profiling needs a dedicated run.** the resident process was
   started **without** `LD_PRELOAD`, and glibc heapprofd cannot attach to an
   already-running process. Ask window A to run
   `scripts/heap-profile.sh <seconds>`; that briefly stops the resident service,
   profiles a dedicated instance with the preload library, and restarts the
   service. It is not part of the day-to-day capture flow.

### Optional: traces that contain kernel scheduling data

On this image the stock boot has no ftrace (see §3), so ordinary captures have
empty Scheduling tracks. A separate, verified way to obtain real kernel sched
data exists (`kernel_ftrace/README.md`): a tracing kernel is booted once via
kexec with a small initramfs, the fixture runs and the trace is written to
`/userdata/pf-kernel-test/logs/`, then the board reboots itself to the stock
kernel. Nothing is flashed.

This mode is **supervised single-shot only**: the board is offline for about
two minutes, needs physical recovery access in the worst case, and there is an
unresolved incident where the board stopped answering after repeated kexec
boots. Do not run it unattended; coordinate with window A; verify `uname -r`
shows the stock kernel (`6.1.83-DR-PL5.1_V1.1.1`) before any further capture.
Reference traces: `logs/kernel-ftrace-full-52s.pftrace` (sched + block + cpufreq
+ syscalls, one 52 s capture) and `logs/kernel-ftrace-45s.pftrace`.

## 4. Instrumentation you can rely on (names in the trace)

Categories: `pipeline`, `memory`, `sync`, `io`, `demo`.

Slices: `FramePipeline` (async), `SyntheticCapture`, `Preprocess`
(+`preproc.resize`, `preproc.normalize`), `InferenceStub`
(+`infer.kernel_conv3x3`, `infer.kernel_gemm`), `Postprocess`
(+`postproc.filter_stub`), `Output`, `QueueWait.*`, `QueuePush.*`, `CvWait`,
`CvWakeupWork`, `CvTimeout`, `IoWrite`, `IoFsync`, `IoRead`, `contend.spin1/2`,
`MemoryPulse.alloc/hold/free`, `MemoryChurn`.

Flows: one flow id per frame, attached to the five stage slices
(`Flow::ProcessScoped` / `TerminatingFlow::ProcessScoped`).

Counters: `QueueDepth`, `InflightFrames`, `CompletedFrames`,
`EndToEndLatencyMs`, `LiveAllocatedBytes`, `RssKb`, `ThreadsRunning`,
`ThreadsBlocked`, `SchedWakeupOvershootMs`, `IoFileBytes`, `cpu.pf-infer`,
`cpu.pf-contend1`, `cpu.pf-contend2`.

Phase changes are `PhaseChange` instants on category `demo`; the phase name is a
debug annotation on many slices and every log line (`PHASE`, `MON`, `FRAME`).

## 5. What to hand back

For each recorded trace, keep:

- the `.pftrace` file,
- the matching slice of `logs/pf-demo-x5.log` and `logs/frames.log`
  (they rotate at 8 MiB, so copy the window you care about),
- the exact capture command and duration,
- the program build id (`grep build_git_build_id logs/../build_info.txt` or
  `sha256sum bin/pf-demo-x5`).

If a capture looks empty, check `scripts/perfetto-service.sh status` and the
socket presence (`/tmp/perfetto-consumer`, `/tmp/perfetto-producer`) before
retrying; do not restart the service.
