# pf-demo-x5 — Perfetto training fixture

A long-running, deterministic C++17 workload for the *Perfetto Agent Skills*
training deck. It simulates a real-time vision pipeline and emits real
Perfetto SDK slices, flows and counters. The trace is recorded on a real
RDK X5 board and opened in <https://ui.perfetto.dev>.

**Honesty note.** This is **not** a camera / BPU / ISP benchmark. Every pipeline
stage is a named simulation (`SyntheticCapture`, `InferenceStub`, ...). What is
real: the CPU work, the heap allocations, the queueing, the blocking, the
wake-ups and every timestamp in the trace and the logs.

- Program version: `1.0.0` (build id `895e724-dirty`, binary sha256
  `f89d9ed5...`, ELF build id `48afa3c3...`)
- Perfetto C++ SDK: `v58.2` (official amalgamated `perfetto.h` + `perfetto.cc`)
- Target: RDK X5, aarch64, glibc 2.35 (buildroot, kernel 6.1.83)
- Toolchain: Arm GNU Toolchain 11.3.rel1 (`aarch64-none-linux-gnu-g++`)

---

## 1. Directory layout

```
perfetto_ppt/demo_fixture/
├── src/
│   ├── pf_demo.cpp      # threads, phases, workload, monitor, logs
│   ├── pf_common.h      # clocks, bounded queue, rotating log, thread helpers
│   └── pf_trace.h       # Perfetto SDK init, categories, tracks, counters
├── build/
│   ├── build.sh                 # cross-compile (or --host)
│   └── build-heapprofd-preload.sh  # optional heapprofd preload build
├── configs/
│   ├── trace_smoke.cfg    # trace config that works on the X5 kernel (no ftrace)
│   ├── trace_ftrace.cfg   # same + sched/block/cpufreq ftrace (needs CONFIG_FTRACE)
│   └── heap_profile.cfg   # android.heapprofd session
├── scripts/
│   ├── install.sh         # host -> board deployment (run from the host)
│   ├── start.sh / stop.sh / status.sh
│   ├── run-supervisor.sh  # crash-limited restart loop
│   ├── autostart-enable.sh / autostart-disable.sh / autostart.sh
│   ├── perfetto-service.sh# traced / traced_probes lifecycle
│   ├── trace.sh           # record a trace with tracebox --system-sockets
│   ├── heap-profile.sh    # dedicated LD_PRELOAD heap-profiling run
│   ├── verify.sh          # on-board evidence collector (RSS/CPU/threads/frames)
│   └── uninstall.sh
├── logs/                  # filled by SELF_TEST_REPORT's evidence runs
├── README.md              # this file
├── RUNNING_BRIEF.md       # public instructions for the analysis window
├── PRIVATE_GROUND_TRUTH.md# what the load really does (not for the UI window)
└── SELF_TEST_REPORT.md    # what was verified, how, and what was not
```

Board deployment: `/userdata/perfetto-training-demo/` (separate ext4
`userdata` partition, mounted rw, persistent across reboots — verified with
`mount`/`fstab` and `df` on the board).

---

## 2. How to build

```bash
cd perfetto_ppt/demo_fixture
./build/build.sh                 # cross build  -> build/out/pf-demo-x5
./build/build.sh --host          # native build -> build/out/pf-demo-x5-host
```

`build.sh` downloads the official Perfetto C++ SDK `v58.2` into
`build/third_party/` (SHA256 pinned) and compiles it into the binary. The binary
is **dynamically linked** and built with:

```
-std=c++17 -O2 -g -fno-omit-frame-pointer -rdynamic -pthread
```

so that:

* `perf`/`traced_perf` can unwind user-space callstacks (frame pointers),
* `-rdynamic` + `-g` keep symbol names and debug info for symbolisation,
* a GNU build-id is present in the ELF (check with
  `readelf -n build/out/pf-demo-x5`).

### Optional: heapprofd preload library

Native heap profiling on non-Android Linux needs
`libheapprofd_glibc_preload.so`. It is **not** part of the C++ SDK and must
match the Perfetto version of the tracing service. Build it from the matching
Perfetto checkout:

```bash
git clone https://github.com/google/perfetto ~/perfetto
cd ~/perfetto && git checkout v58.2 && tools/install-build-deps --linux-arm
PERFETTO_SRC=~/perfetto \
  perfetto_ppt/demo_fixture/build/build-heapprofd-preload.sh
```

Then pass `--preload build/out/libheapprofd_glibc_preload.so` to `install.sh`
(or place the file at `build/out/libheapprofd_glibc_preload.so`; `install.sh`
picks it up automatically).

---

## 3. Deploy / start / stop

From the host, with SSH access to the board:

```bash
cd perfetto_ppt/demo_fixture
SSHPASS=root ./scripts/install.sh            # deploy + autostart + start
SSHPASS=root ./scripts/install.sh --no-start # deploy only
```

Installed tree on the board:

```
/userdata/perfetto-training-demo/
├── bin/pf-demo-x5              # unstripped aarch64 binary (symbols for the UI)
├── bin/perfetto/{traced,tracebox,traced_probes,perfetto}
├── lib/libheapprofd_glibc_preload.so
├── scripts/*.sh  configs/*.cfg
├── logs/        # service.log, frames.log, supervisor.log, traces
├── run/         # pid files, io-buffer.dat, trace configs
├── build_info.txt
└── autostart.disabled          # present => boot start disabled
```

Common operations (on the board):

```bash
D=/userdata/perfetto-training-demo
$D/scripts/start.sh            # idempotent; starts the crash-limited supervisor
$D/scripts/stop.sh             # graceful SIGTERM, threads join, logs flushed
$D/scripts/status.sh           # pids, thread list (comm/state), frames, service
$D/scripts/verify.sh 100       # 100 s evidence collection
$D/scripts/trace.sh 15         # record a 15 s trace
$D/scripts/heap-profile.sh 20  # 20 s native heap profile run
```

### Boot start

The root filesystem is **100 % full and read-only** on this image
(`df -k /` → `161592 160600 0 100%`), so no `/etc/init.d/S*` script can be
added. The image already supports the standard hook:

* `/etc/init.d/S99auto_startup` runs `/userdata/startup.sh` in the background.
* `scripts/autostart-enable.sh` inserts **one clearly marked block right after
  the shebang** of that existing file (the previous fixtures' content ends with
  an unconditional `exit 0`, so appending at the end would never run); other
  entries are preserved byte-for-byte. This mirrors how
  `/etc/init.d/S90cam-service` starts `cam-service`.

Disable / re-enable / remove:

```bash
$D/scripts/autostart-disable.sh   # boot start off; running instance untouched
$D/scripts/autostart-enable.sh    # boot start on
$D/scripts/uninstall.sh           # stop + remove the startup block (logs kept)
$D/scripts/uninstall.sh --purge   # also delete the deployment directory
```

Crash restarts are rate-limited by `run-supervisor.sh` (2–60 s exponential
back-off, gives up after 10 consecutive failures shorter than 30 s).

---

## 4. Recording a trace

On the board:

```bash
$D/scripts/trace.sh 15 /userdata/perfetto-training-demo/logs/demo.pftrace
```

then pull and open it:

```bash
scp root@<board>:/userdata/perfetto-training-demo/logs/demo.pftrace .
# open https://ui.perfetto.dev and load build/out/pf-demo-x5 for symbols
```

Why `tracebox --system-sockets`:

* The Perfetto SDK in `pf-demo-x5` uses the **system backend**, i.e. it connects
  to `/tmp/perfetto-producer`. `tracebox` in its default mode creates *private*
  sockets inside its own directory and therefore cannot record such producers —
  `--system-sockets` is mandatory and was verified on the board.
* `tracebox` also bundles `traced_perf` (CPU callstack sampling). The
  `traced_probes` binary deployed with the existing board tooling does **not**
  include the perf producer, so `perfetto` CLI captures would miss CPU samples.

`perfetto` CLI still works for everything that `traced_probes` provides
(process_stats, sys_stats, track_event). `trace.sh` prefers tracebox for the
reason above.

---

## 5. What the trace contains

Slices (`pipeline` category):

| slice | thread | meaning |
|---|---|---|
| `FramePipeline` | async, 16 rotating tracks | end-to-end span, sampled every 8th frame (avoids one track per frame) |
| `SyntheticCapture` | pf-capture | frame creation + 32/48 KiB synthetic buffer fill |
| `Preprocess` (+ nested `preproc.resize`, `preproc.normalize`) | pf-preproc | preprocess stage |
| `InferenceStub` (+ nested `infer.kernel_conv3x3`, `infer.kernel_gemm`) | pf-infer | inference simulation |
| `Postprocess` (+ nested `postproc.filter_stub`) | pf-postproc | postprocess stage |
| `Output` | pf-output | output stage, terminating flow |

Flows: `perfetto::Flow::ProcessScoped(frame_id)` on each stage slice and
`perfetto::TerminatingFlow::ProcessScoped(frame_id)` on `Output` — one arrow per
frame between every pair of consecutive stages, on a unique frame id.

Counters (`demo` category): `QueueDepth`, `InflightFrames`, `CompletedFrames`,
`EndToEndLatencyMs`, `LiveAllocatedBytes` plus real-sampled extras `RssKb`,
`ThreadsRunning`, `ThreadsBlocked`, `SchedWakeupOvershootMs`, `IoFileBytes`,
`cpu.pf-infer`, `cpu.pf-contend1`, `cpu.pf-contend2`.

Sync/log slices: `QueueWait.*`, `QueuePush.*` (real blocking), `CvWait` /
`CvWakeupWork` / `CvTimeout` (real futex sleeps + wake-ups), `IoWrite` /
`IoFsync` / `IoRead` (rate- and size-capped).

---

## 6. Board limitations that shape the trace

These were measured on the board, not assumed:

1. **No ftrace / tracepoints.** `zcat /proc/config.gz` reports
   `# CONFIG_FTRACE is not set`; `mount -t tracefs tracefs /tmp/tr` fails with
   `No such device`; `/sys/kernel/debug/tracing` does not exist. Consequently
   Perfetto cannot record `sched_switch` / block-I/O tracepoints / ftrace
   `cpu_frequency` on this image, and the Perfetto *Scheduling* state tracks
   will be empty. `configs/trace_ftrace.cfg` is provided for kernels that have
   ftrace; it is **not** usable on this board.
2. **What does work on the stock boot:** `track_event` (SDK),
   `linux.process_stats` (thread/RSS), `linux.sys_stats` (meminfo, vmstat,
   per-CPU times, **cpufreq**), `linux.perf` (perf_event CPU sampling with
   user-space callstacks). `perf_event_paranoid=2`, so captures must run as
   root. Real kernel scheduling data requires the optional kexec tracing kernel
   described in §7.
3. **Runnable-wait evidence without sched_switch:** the fixture records real
   wake-up overshoot of a 20 Hz absolute-timer thread pinned to the contended
   core (`SchedWakeupOvershootMs`), per-thread CPU% from `/proc`, thread states
   sampled by `pf-monitor`, and every blocking point as a slice. This is
   app-level evidence, clearly labelled as such — not kernel scheduler state.

---

## 7. Real kernel scheduling data (optional kexec tracing kernel)

The stock X5 image is built with `CONFIG_FTRACE=n` (no tracefs, no sched/block
tracepoints, no `/proc/schedstat`), so a stock boot cannot produce Perfetto's
Scheduling tracks. `kernel_ftrace/` contains a verified, **flash-free** way to
get them anyway:

1. `build/build-ftrace-kernel.sh` rebuilds the same kernel source with tracing
   enabled, starting from the board's exact config (`kernel_ftrace/board.config`,
   byte-identical to `/proc/config.gz`);
2. the tracing kernel is booted **once via `kexec_file_load`** (available on the
   stock kernel) with a small initramfs (`build/build-kexec-initramfs.sh`);
3. the initramfs mounts tracefs, runs `pf-demo-x5` + `tracebox` for N seconds,
   writes the `.pftrace` to `/userdata`, and reboots back to the stock kernel;
4. a hardware watchdog is armed before `RB_KEXEC`, so a failed boot resets the
   board back to the stock kernel. **No partition is written.**

Recorded evidence (in `logs/`):

| trace | kernel data |
|---|---|
| `kernel-ftrace-full-52s.pftrace` | 33 652 `sched_switch`, 100 k syscalls, 2 672 `cpu_frequency`, 470 block events, 3 280 SDK flows, 10 144 perf samples |
| `kernel-ftrace-45s.pftrace` | sched-only variant with `pf-infer` Runnable wait 5.34 s, of which 5.34 s in SCHED_CONTENTION |

Kernel-level Runnable waits for `pf-infer`: SCHED_CONTENTION **3.39 s** total
(max 40 ms), every other phase 5–15 ms; wakeup chains are real
(`pf-capture → pf-syncwait` 810 times, `pf-preproc → pf-infer` 661 times).
Full details and the exact commands are in `kernel_ftrace/README.md` and
`logs/kernel-ftrace-full-analysis.txt`.

**Operational warning:** this mode takes the board offline for ~2 minutes and
needs physical access in the worst case. During development, after five
consecutive kexec boots the board stopped answering on the network and needed a
power cycle (first four boots self-recovered normally; root cause unconfirmed).
Run it as a supervised single-shot, verify `uname -r` shows the stock kernel
afterwards, and do not use it for routine window-B captures. Making the tracing
kernel persistent requires replacing kernel + modules together (a
`struct task_struct` ABI change) and has **not** been done.

## 8. Verification

```bash
$D/scripts/verify.sh 100
```

produces `logs/verify-<timestamp>/` with `rss.csv`, `cpu.csv`, `threads.csv`,
`phases.txt`, `mon.txt`, `summary.txt` and PASS/FAIL checks (RSS pulse, frame
count, phases observed, condition-variable wake-ups). See
`SELF_TEST_REPORT.md` for the run log of this build.

Ground truth for the analysis window (phase layout, expected phenomena) is in
`PRIVATE_GROUND_TRUTH.md`. `RUNNING_BRIEF.md` intentionally contains only what
the analysis window may know in advance.
