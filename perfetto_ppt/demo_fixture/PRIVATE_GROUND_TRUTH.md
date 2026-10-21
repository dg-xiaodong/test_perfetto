# PRIVATE GROUND TRUTH — pf-demo-x5 (window A only)

> Do **not** hand this file to the Perfetto analysis window. The public brief is
> `RUNNING_BRIEF.md`. This file records what the workload really does, what the
> trace should show, and the exact values measured on the board.

## 1. Identity

| item | value |
|---|---|
| program | `pf-demo-x5` v1.0.0 |
| source | `src/pf_demo.cpp`, `src/pf_common.h`, `src/pf_trace.h` |
| binary sha256 | `f89d9ed5f509868f968eac7072abe4aa2c499417f2fb48e3cfb379195c24c9b5` |
| ELF build id | `48afa3c3dcc7ac719a0063997012aaf29a1db983` |
| build id string | `895e724-dirty` (repo was dirty when built; same files as the fixture commit) |
| Perfetto SDK | v58.2, official C++ amalgamation, **system backend** |
| deployment | `/userdata/perfetto-training-demo/` |
| steady-state threads | 12 worker threads + 1 SDK thread (`TracingMuxer`) |

## 2. Time base

Every log line carries `mono_ns` (CLOCK_MONOTONIC) and, where it matters,
`boot_ns` (CLOCK_BOOTTIME). Perfetto trace timestamps on Linux use
CLOCK_BOOTTIME. On this board the two clocks differ by a constant
(~0–10 µs, visible in `PHASE ... mono_ns=... boot_ns=...`), so align by taking
one `PHASE` line as the origin.

## 3. Cycle layout

`--phase-seconds 8` → **48 s cycle**, six phases, repeated forever:

| idx | name | seconds into cycle |
|---|---|---|
| 0 | `BASELINE` | 0–7 |
| 1 | `CPU_BURST` | 8–15 |
| 2 | `SCHED_CONTENTION` | 16–23 |
| 3 | `MEMORY_PULSE` | 24–31 |
| 4 | `SYNC_IO` | 32–39 |
| 5 | `MIXED_PIPELINE` | 40–47 |

Phase transitions are logged as `PHASE cycle=N idx=I name=... mono_ns=...` and
emitted to the trace as `PhaseChange` instants on the `demo` category.

## 4. Per-phase ground truth (values measured on the X5)

Measurements below are from the recorded trace (`logs/trace-analysis.txt`) and
from `logs/frames.log` / `logs/pf-demo-x5.log` on the final build. The CPU runs
at 300 MHz–1.5 GHz depending on load (`cpufreq` counter in the trace), so
wall-time numbers vary by tens of percent with frequency; the *relative*
signature of each phase is stable.

### BASELINE (idx 0)
- capture 15 FPS; 32 KiB synthetic buffer per frame
- preprocess ≈ 3 ms, inference ≈ 12–15 ms, postprocess ≈ 1 ms
- end-to-end ≈ 30 ms when clean; RSS ≈ 4 MB; cpu_a mostly idle
- counters: `InflightFrames` 0–1, `QueueDepth` 0–1
- **spill-over:** the first 1–3 s of a BASELINE that follows MIXED_PIPELINE
  still drain the MIXED backlog (measured e2e up to 1.3 s, `QueueDepth` up to
  19). A "clean" baseline is the middle/end of the phase.

### CPU_BURST (idx 1)
- inference CPU work raised to 4 M + 4 M deterministic iterations:
  measured **42 ms avg / 136 ms max** wall on cpu_a (≈65–70 % of one core)
- the two hot leaves are `infer.kernel_conv3x3` and `infer.kernel_gemm`
  (nested in `InferenceStub`); symbolised CPU profile: `CpuWork` 3248,
  `InferenceConv3x3` 1864, `InferenceGemm` 1614 samples
- end-to-end ≈ 56 ms; capture stays at 15 FPS; queues stay near empty
- visible: `cpu.pf-infer` counter up to ≈63 %, `cpufreq` rises to 1.5 GHz,
  perf samples concentrate on the two kernel functions

### SCHED_CONTENTION (idx 2)
- `pf-contend1` and `pf-contend2` spin (100 ms on / 5 ms off) pinned to the
  *same* cpu as `pf-infer`; inference does 4.4 M deterministic iterations
  (≈25 ms of CPU work)
- measured **wall inflation: 65 ms avg / 82 ms max ≈ 2.6× the CPU work**;
  `cpu.pf-contend1/2` counters reach ~34 % each (1 s sample average), cpu_a
  reaches 100 % busy (verify: `cpu5 peak_busy_pct=100`)
- end-to-end ≈ 194 ms; queue depth stays small (~1.9 avg) because the wall time
  is just below the 66 ms frame period
- `contend.spin1/2` slices are 100 ms long, ~95 % duty, `ThreadsRunning` rises
  to 3–4
- **Honest caveat:** this kernel's wake-up preemption is aggressive, so
  `SchedWakeupOvershootMs` stays ≤ 0.85 ms even while cpu_a is saturated by two
  runnable spinners (~0.06 ms outside the phase). The runnable evidence is
  (a) two threads in `R` state for ~95 % of the phase (`ThreadsRunning`
  counter, `/proc` samples: 21/110 and 19/110 samples in `R`) and (b) inference
  wall time ≫ inference CPU time. Do not expect a big overshoot spike.

### MEMORY_PULSE (idx 3)
- `pf-memheap` allocates **12 MiB** with `malloc`, `memset` touches every page,
  holds 4 s, frees it (`malloc_trim(0)`), waits 1.5 s, repeats inside the phase
- RSS measured: 3 984 kB idle → **16 412 kB** while held → 12 328 kB delta,
  reproducible every cycle (verify and trace agree: `RssKb` 3 984→16 412)
- `LiveAllocatedBytes` counter: 0 → 12 582 912 → 0 (bytes)
- `malloc_trim` + a pinned `M_MMAP_THRESHOLD` are required: without them glibc
  raises its dynamic mmap threshold after the first 12 MiB free, moves the
  pulse onto the retained brk heap and the RSS pulse disappears (observed once
  during tuning: RSS stayed at 16.7 MB for minutes).
- trace also carries `mem.rss`, `mem.rss.anon`, `meminfo` counters from
  `linux.process_stats` / `linux.sys_stats`
- the allocation call stack is
  `MemoryThread → MemoryPulse.alloc (slice) → malloc`, which is what heapprofd
  attributes when the preload mode is used

### SYNC_IO (idx 4)
- `pf-syncwait` blocks in `std::condition_variable::wait_for` (real futex);
  `pf-capture` notifies once per frame → ~15 wake-ups/s, visible as repeated
  `CvWait` slices (1 360 per 52 s trace) and `CvWakeupWork` slices; a few
  `CvTimeout` (540 per trace) from coalesced notifications
- `pf-ioworker`: one 256-byte `write` + `fsync` + `pread` every **200 ms**
  (1/s in other phases), file capped at 512 KiB (truncated in place, measured
  458–474 kB)
- slices `IoWrite`, `IoFsync`, `IoRead`; occasional `CvTimeout`

### MIXED_PIPELINE (idx 5)
- capture raises to **20 FPS** (50 ms period); inference 2 M + 2 M (≈25 ms) and
  postprocess adds a deterministic simulated tail
  (`40 + (frame_id % 4) * 10` ms sleep), so **postprocess (~40–70 ms) is the
  bottleneck stage**
- measured: e2e **602 ms avg / 1 122 ms max**, `QueueDepth` **9.7 avg / 18 max**,
  `InflightFrames` up to 22 — a sustained backlog that builds through the phase
- the backlog drains into the following BASELINE phase (1–3 s), see above
- `FramePipeline` spans and flow chains are longest here

## 5. Instrumentation map (what should be in the trace)

| kind | name | notes |
|---|---|---|
| slice | `SyntheticCapture` | flow origin (`Flow::ProcessScoped(frame_id)`) |
| slice | `Preprocess` (+ `preproc.resize`, `preproc.normalize`) | flow continues |
| slice | `InferenceStub` (+ `infer.kernel_conv3x3`, `infer.kernel_gemm`) | flow continues; CPU hotspots |
| slice | `Postprocess` (+ `postproc.filter_stub`) | flow continues, carries `e2e_ms` |
| slice | `Output` | `TerminatingFlow::ProcessScoped(frame_id)` |
| async slice | `FramePipeline` on 16 rotating tracks, every 8th frame | end-to-end span; sampled to avoid one track per frame (documented) |
| flow | 5 stage events carry one flow id per frame | `flow` table has 4 links/frame (capture→pre→infer→post→output) |
| counter | `QueueDepth`, `InflightFrames` | monitor, 2 Hz |
| counter | `CompletedFrames` | per completed frame |
| counter | `EndToEndLatencyMs` | per frame, real value |
| counter | `LiveAllocatedBytes` | on every alloc/free |
| counter | `RssKb`, `ThreadsRunning`, `ThreadsBlocked`, `cpu.pf-infer`, `cpu.pf-contend1/2` | monitor, 1 Hz |
| counter | `SchedWakeupOvershootMs` | 20 Hz, wake-up overshoot proxy |
| counter | `IoFileBytes` | per I/O sample |
| sync slices | `QueueWait.*`, `QueuePush.*` | real blocking time |
| sync slices | `CvWait`, `CvWakeupWork`, `CvTimeout` | real futex sleep/wake-up |
| io slices | `IoWrite`, `IoFsync`, `IoRead`, `IoTruncate` | capped I/O |

## 6. Frame accounting

- frame id = monotonically increasing `uint64_t`, starts at **1 per process
  run** (a service restart resets it; `pf-demo-x5.log` has a `BOOT` line with
  the new pid before the new ids, and `frames.log` keeps appending until it
  rotates — take a clean window after the last `BOOT` when ids matter)
- `frames.log` has one line per completed frame with
  `cap_dur_ms pre_dur_ms inf_dur_ms post_dur_ms e2e_ms bytes checksum q1..q4`
- one 52 s trace contained 820 frames (~15.8 fps average across the cycle)
- `frames.log` / `pf-demo-x5.log` rotate at 8 MiB (one `.1` backup) — bounded

## 7. Board facts (measured, not assumed)

- `uname -a`: `6.1.83-DR-PL5.1_V1.1.1`, aarch64, buildroot 2022.08, glibc 2.35
- init: BusyBox/SysV `/etc/init.d/S*`; `/etc/init.d/S99auto_startup` executes
  `/userdata/startup.sh`; `/etc/init.d/S90cam-service` is the reference service
- `/` (ext2, 161 592 KiB) is **100 % full, 0 KiB free → no new rootfs init
  script**; autostart therefore lives in `/userdata/startup.sh`
- `/userdata` is a 28 GiB ext4 partition, rw, persistent (separate by-name
  partition; `lost+found` present)
- kernel config: `CONFIG_FTRACE` **not set** (no tracefs, no
  sched/block tracepoints); `CONFIG_PERF_EVENTS=y`, `perf_event_paranoid=2`
- perf event sources available: `armv8_pmuv3`, `software` (no `tracepoint`)
- other resident fixtures (do not disturb): `sched-case-daemon` on cpu1/2,
  `task-service` on cpu6/7, `cam-service` on ISP, `traced`/`traced_probes` in
  `/userdata/bin`
- CPU selection at boot: reads the allowed mask, samples per-CPU utilisation,
  and treats cores pinned by other `/userdata` services as reserved. It is
  dynamic: the evidence run used `cpu_a=5 cpu_b=4`, the final hand-off instance
  `cpu_a=5 cpu_b=0` (log line `CPU_SELECT ... reserved`). The analysis must not
  assume fixed cores; read the `BOOT`/`CPU_SELECT` lines of the log or the
  trace's `cpu.pf-infer` thread track.

## 8. Heap profiling (heapprofd) facts

- preload library built from Perfetto **v58.2** source, `out/arm64`,
  `gn args: is_debug=false target_cpu="arm64"`; stripped to 1.5 MiB;
  ELF aarch64, NEEDED libs: libpthread/librt/libdl/libm/libgcc_s/libc
- `scripts/heap-profile.sh` starts a tracebox session with `android.heapprofd`
  **before** launching the target with `LD_PRELOAD`, runs a dedicated instance
  for N seconds, then restarts the resident service
- blocking init is opt-in (`PF_HEAPPROF_BLOCKING_INIT=1`); the resident service
  never uses preload, so a missing/broken library cannot break it
- the running resident service CANNOT be heap-profiled retroactively (glibc
  preload only works at process start) — this is stated in the brief as a
  precondition, not a test outcome
