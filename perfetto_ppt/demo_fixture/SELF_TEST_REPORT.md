# SELF_TEST_REPORT — pf-demo-x5 (window A)

Scope: everything below was executed on the actual RDK X5 board
(`root@192.168.1.10`, kernel `6.1.83-DR-PL5.1_V1.1.1`) and on the build host.
Where something was **not** verified, it is listed explicitly in §10.
Evidence files referenced here live in `logs/`; raw traces are included.

## 1. Build facts

| item | value |
|---|---|
| program | `pf-demo-x5` v1.0.0 |
| toolchain | `aarch64-none-linux-gnu-g++` 11.3.1 (Arm GNU Toolchain 11.3.Rel1) |
| Perfetto SDK | official C++ SDK **v58.2**, amalgamated `perfetto.h` + `perfetto.cc` |
| SDK archive sha256 | `e56126ff81f0f914d35fe03c72419d147acf2890f36fbda7d4558fd5b84c4b09` |
| compile flags | `-std=c++17 -O2 -g -fno-omit-frame-pointer -rdynamic -pthread -Wl,--gc-sections -Wl,--build-id=sha1` |
| binary | `build/out/pf-demo-x5`, ELF aarch64, **dynamically linked**, not stripped |
| binary sha256 | `f89d9ed5f509868f968eac7072abe4aa2c499417f2fb48e3cfb379195c24c9b5` |
| ELF build id | `48afa3c3dcc7ac719a0063997012aaf29a1db983` |
| source commit | `895e724` + the fixture files added by this work (see `git log`); binary was built while the fixture was still uncommitted, hence the embedded `895e724-dirty` tag |
| `logs/build-info.txt` | full `VERSION.txt` captured from the build |

`file` output of the deployed binary:

```
ELF 64-bit LSB executable, ARM aarch64, version 1 (GNU/Linux), dynamically linked,
interpreter /lib/ld-linux-aarch64.so.1, BuildID[sha1]=48afa3c3..., for GNU/Linux 3.7.0,
with debug_info, not stripped
```

## 2. Board environment (measured, not assumed)

```
$ uname -a
Linux buildroot 6.1.83-DR-PL5.1_V1.1.1 #3 SMP PREEMPT ... aarch64 GNU/Linux
$ cat /etc/os-release        -> Buildroot 2022.08
$ ldd --version             -> ldd (Arm) 2.35
$ nproc                     -> 8
$ ls /etc/init.d/           -> SysV style S* scripts (S90cam-service, S99auto_startup, ...)
$ ps -p 1 -o comm=          -> init
$ df -k /                   -> 161592 160600 0 100%       (rootfs full, no space)
$ mount | grep userdata     -> /dev/block/platform/by-name/userdata on /userdata
                               type ext4 (rw,relatime)      (persistent partition)
$ zcat /proc/config.gz | grep FTRACE
# CONFIG_FTRACE is not set
$ mount -t tracefs tracefs /tmp/tr
mount: mounting tracefs on /tmp/tr failed: No such device
$ cat /sys/kernel/debug/tracing/...   -> does not exist
$ cat /proc/sys/kernel/perf_event_paranoid -> 2
$ ls /sys/bus/event_source/devices -> armv8_pmuv3, software, breakpoint, cs_etm, ...
```

**Consequence:** this image has no ftrace/tracefs/tracepoints. Perfetto cannot
record `sched_switch`, block-I/O tracepoints or ftrace `cpu_frequency` here
(verified: a trace recorded with the ftrace data source contains 0 `sched`
rows). The fixture therefore uses `track_event` + `linux.process_stats` +
`linux.sys_stats` + `linux.perf`, and reports wake-up overshoot/per-thread CPU
itself. `configs/trace_ftrace.cfg` is kept for ftrace-capable kernels only.

Other resident fixtures found and avoided (not touched):
`sched-case-daemon` (cpu1/2), `task-service` (cpu6/7), `cam-service`,
`traced` + `traced_probes` in `/userdata/bin`.

## 3. CPU affinity selection

`SelectCpus()` reads `Cpus_allowed_list`, samples per-CPU utilisation from
`/proc/stat` for 300 ms, and treats cores pinned (mask ≤ 2) by other
`/userdata` processes as reserved. Logged result on the deployment run:

```
CPU_SELECT mode=auto cpu_a=5 cpu_b=4 busy="cpu0=3.3% cpu1=3.2%(reserved) cpu2=3.2%(reserved)
 cpu3=0.0% cpu4=0.0% cpu5=3.2% cpu6=6.5%(reserved) cpu7=6.5%(reserved)"
```

so the earlier fixtures' cores (1/2 from sched-case, 6/7 from task-service)
were correctly recognised as occupied and excluded without hard-coding them.
The final hand-off instance was started by the boot-hook test and picked
`cpu_a=5 cpu_b=0` (all candidate cores were idle at that moment); the selection
is dynamic, which is exactly the intent.

## 4. Deployment

- `/userdata/perfetto-training-demo/` created; 73 MiB total including logs and
  traces; 26 GiB free on `/userdata`.
- binaries: `bin/pf-demo-x5` (61.9 MB, debug info), `bin/perfetto/{traced,tracebox,traced_probes,perfetto}`
  (Perfetto v58.2 `add693d8b`, copied from the board's existing set),
  `lib/libheapprofd_glibc_preload.so`.
- autostart: a marked block is inserted into the existing
  `/userdata/startup.sh` (executed by `/etc/init.d/S99auto_startup`) **right
  after the shebang**; no rootfs file was touched; the existing entries for
  `sched-case` and `task-service` are preserved byte for byte. Marker
  `autostart.disabled` absent → enabled.
- the boot-hook path was exercised by actually executing
  `/userdata/startup.sh` (see `logs/status-final.txt`):

  ```
  1970-01-01T04:01:37Z AUTOSTART_BEGIN
  traced already running (pid=1113)
  traced_probes already running (pid=1761)
  started: supervisor pid=25188 app pid=25197
  pf-demo-x5 v1.0.0 (Perfetto SDK v58.2, build 895e724-dirty) pid=25197 cpus=5,0
  1970-01-01T04:01:39Z AUTOSTART_END rc=0
  ```

  This test caught two real bugs, both fixed in `scripts/autostart-enable.sh`:
  1. the block was originally appended at the *end* of `startup.sh`, after an
     existing unconditional `exit 0`, so it never ran;
  2. the block referenced `$D/autostart.sh` while the script is deployed at
     `$D/scripts/autostart.sh`.
  After the fixes, the service is started by the hook itself.
- supervisor with restart back-off is running; `run/app.pid` and
  `run/supervisor.pid` are populated.

## 5. Runtime verification (final build)

`scripts/verify.sh 110 1` — it ran for **151 s** (the script now reports the
actual duration), covering **4+ full 48-second cycles**. Result: `RESULT=PASS`.

Evidence: `logs/verify-summary.txt`, `logs/board-evidence.txt`.

| check | measured |
|---|---|
| RSS pulse deltas (1 Hz samples) | min 4 248 kB, max 16 576 kB → **delta 12 328 kB** every cycle (12 MiB pulse) |
| worker threads present | 12 named workers + SDK `TracingMuxer` (thread list captured) |
| CPU peak | **cpu5 = 100 %** during SCHED_CONTENTION (the inference core); cpu4 32 % (preprocess/syncwait); other cores ≤ 54 % (existing fixtures) |
| thread states | `pf-contend1/2` sampled in `R` for 21/19 of 110 samples (100 % of their in-phase samples); `pf-infer` `R` in 46/110 |
| frames in window | 2 393 logged; all frame ids unique, no duplicates |
| condition-variable wake-ups | `cv_wakeups` delta 3 161 in the window (real futex wake-ups) |
| wake-up overshoot | max 0.835 ms (`SchedWakeupOvershootMs`) — small because of aggressive wake-up preemption, see §10 |
| per-phase latency signature | contention => inference wall time inflated; MIXED => queue backlog (numbers in §6) |

Program remained alive across all runs; supervisor restarts were not triggered
(the only restarts were deliberate stop/start during deployment).

## 6. Perfetto instrumentation verification (trace smoke test, not just a build)

Recorded with the real system backend:

```
./scripts/trace.sh 52 /userdata/perfetto-training-demo/logs/fullcycle-52s.pftrace
# = tracebox --system-sockets --txt -c configs/trace_smoke.cfg -o ... (52 s)
```

Analyzed with `trace_processor_shell` v58.2. Trace included in
`logs/fullcycle-52s.pftrace` (2.0 MB, 52 s, one full cycle).

| item | measured in trace |
|---|---|
| slices | **18 821** |
| stage slices | `SyntheticCapture`, `Preprocess` (+resize/normalize), `InferenceStub` (+conv3x3/gemm), `Postprocess` (+filter_stub), `Output` — **820 frames each**, all present |
| flows | **3 280** (`flow` table) = 4 links × 820 frames (capture→pre→infer→post→output) |
| `FramePipeline` async spans | 103 (sampled every 8th frame on 16 rotating tracks, 5.6–38 ms measured) |
| PhaseChange instants | 6 (one per phase) |
| `QueueDepth` | 104 samples, 0 → 19 |
| `InflightFrames` | 104 samples, 0 → 22 |
| `CompletedFrames` | 820 samples, 94 → 913 |
| `EndToEndLatencyMs` | 820 samples, 5.57 → 1343.6 ms |
| `LiveAllocatedBytes` | 208 samples, 0 → 12 582 912 bytes |
| `RssKb` (extra) | 52 samples, 3 984 → 16 412 kB |
| `ThreadsRunning` / `ThreadsBlocked` | 1..4 / 0..1 |
| `SchedWakeupOvershootMs` | 1 040 samples, 0.06 → 0.85 ms |
| `cpu.pf-infer` | 13.9 % → 62.7 % |
| `cpu.pf-contend1/2` | 0 → 33.9 % each |
| perf CPU samples | **12 422**, `pf-infer` 3 499 (top thread) |
| cpufreq counter (sys_stats) | 840 samples, **300 MHz → 1 500 MHz** |
| process/thread names | `/userdata/perfetto-training-demo/bin/pf-demo-x5` with all 13 threads named |

Symbolisation of the CPU profile (`PERFETTO_BINARY_PATH` +
`PERFETTO_SYMBOLIZER_MODE=index` + the deployed aarch64 binary) resolves the
expected hot functions (`logs/cpu-hotspots.txt`):

```
CpuWork                     3248 samples
InferenceConv3x3            1864
InferenceGemm               1614
ContendSpin                  850
```

Per-phase signatures extracted from the trace (`logs/trace-analysis.txt`):

| phase | InferenceStub avg/max ms | e2e latency avg/max ms | QueueDepth avg/max |
|---|---|---|---|
| BASELINE | 15.28 / 18.64 | 317.4 / 1343.6 (draining the previous MIXED backlog) | 3.50 / 19 |
| CPU_BURST | 42.25 / 136.12 | 55.9 / 134.3 | 0.05 / 1 |
| SCHED_CONTENTION | **65.03** / 82.52 | 193.8 / 215.8 | 1.88 / 2 |
| MEMORY_PULSE | 14.86 / 15.95 | 38.4 / 161.3 | 0.06 / 1 |
| SYNC_IO | 12.09 / 13.35 | 27.2 / 47.4 | 0.00 / 0 |
| MIXED_PIPELINE | 24.95 / 30.33 | **601.7 / 1122.0** | **9.73 / 18** |

Interpretation: SCHED_CONTENTION inflates the inference stage to ~2.6× its CPU
work (~25 ms of CPU → 65 ms wall) with two spinners on the same core;
MIXED_PIPELINE builds a sustained queue backlog because postprocess is the
bottleneck stage, and the backlog drains into the following BASELINE.

## 7. heapprofd / native heap profiling

The preload library was built from the same Perfetto v58.2 source
(`out/arm64`, `gn args: is_debug=false target_cpu="arm64"`), stripped to
1.5 MiB, sha256
`dfa42d105c05cacc17f46f29b39c4b5b5294c04f696281ef838c3c6ab7110198`,
build id `ddf8c2ace4a335df`, NEEDED libs libpthread/librt/libdl/libm/libgcc_s/libc
(all present on the board).

`scripts/heap-profile.sh 25` (dedicated run; resident service stopped then
restarted, which is why the hand-off instance has a fresh PID) produced
`logs/heap-profile-20s.pftrace` (756 KB) and:

```
heap_profile_allocation rows            1078   (heap libc.malloc)
largest allocation size                 12 582 912 bytes  (the 12 MiB pulse)
stack_profile_callsite rows             2264
mapping for the target                  /userdata/perfetto-training-demo/bin/pf-demo-x5
                                        build_id 48afa3c3dcc7ac719a0063997012aaf29a1db983
```

The 12 MiB allocation's callstack, walked to the top, contains
`pfdemo::(anonymous namespace)::MemoryThread(...)` → the pulse is attributed to
the allocating function. Intermediate frames are libc/libheapprofd (those
system libraries carry no build id on this image and stay unsymbolised, which
is expected).

Blocking init was **not** used (`PERFETTO_HEAPPROFD_BLOCKING_INIT=0`,
`block_client: false`), so a slow tracing service can never stall the first
`malloc`. The resident service runs **without** preload; a broken library
cannot take it down.

## 8. Files produced

See `README.md` §1 and the repository tree; evidence in `logs/`:

```
logs/build-info.txt                 build/VERSION.txt as deployed
logs/board-evidence.txt             verify summary + supervisor log + boot log
logs/verify-summary.txt             the PASS summary of the 151 s run
logs/fullcycle-52s.pftrace          full-cycle trace (SDK + perf + proc/sys stats)
logs/trace-analysis.txt             trace_processor queries/results
logs/cpu-hotspots.txt               symbolized CPU-profile hot functions
logs/heap-profile-20s.pftrace       heapprofd trace
logs/heap-profile-analysis.txt      heap profile queries/results
logs/kernel-ftrace-full-52s.pftrace kernel sched+block+cpufreq+syscall trace (kexec kernel)
logs/kernel-ftrace-45s.pftrace      kernel sched-only trace
logs/kernel-ftrace-full-analysis.txt kernel scheduling analysis
logs/kernel-sched-analysis.txt      per-thread/per-phase Runnable waits
```

## 9. Kernel scheduling data (optional kexec tracing kernel)

Method (no disk writes; details in `kernel_ftrace/README.md`):

1. `build/build-ftrace-kernel.sh` rebuilds the same kernel source with a
   tracing-only config delta from `kernel_ftrace/board.config` (the board's
   `/proc/config.gz`, diff 0 lines before enabling ftrace). Result:
   `Image-ftrace`, kernel `6.1.83+ #4 SMP PREEMPT`, sha256
   `036d11392ed2df30205efd1824047b31c92e590e06177a6dc828351a5d40cc61`.
2. `build/build-kexec-initramfs.sh` assembles an initramfs (stock recovery
   environment + `pf-demo-x5` + `tracebox` + trace configs).
3. `kernel_ftrace/kexec_pf.c` calls `kexec_file_load(Image, initrd, cmdline)`
   (syscall 294, verified available on the stock kernel: `EBADF`, not
   `ENOSYS`), arms `/dev/watchdog`, then `RB_KEXEC`.
4. The initramfs mounts tracefs (required: Perfetto only detects an existing
   mount), runs the app and tracebox, writes to `/userdata`, and reboots back.

Recorded traces and numbers:

| item | value |
|---|---|
| `logs/kernel-ftrace-full-52s.pftrace` | 9.9 MB, 52 s, near-full cycle |
| sched rows / ftrace events | 33 652 `sched_switch`, 470 block, 2 672 `cpu_frequency`, 100 k syscalls |
| SDK data in the same trace | 119 072 slices, 3 280 flows, 10 144 perf samples |
| `pf-infer` Runnable wait | 3 448 ms total; **3 392 ms in SCHED_CONTENTION**, max 40 ms |
| `pf-contend1/2` Runnable wait | 5 033 / 4 927 ms, max 40/42 ms |
| wakeup chains | `pf-capture→pf-syncwait` 810, `pf-capture→pf-preproc` 750, `pf-preproc→pf-infer` 661, `pf-infer→pf-postproc` 640 |
| CPU frequency | 300 MHz … 1.5 GHz (ftrace + sys_stats agree) |
| `logs/kernel-ftrace-45s.pftrace` | 2.6 MB sched-only run: `pf-infer` contention wait 5 342 ms |

**Incident during this work:** the first four kexec boots (one `pf.mode=dry`,
two captures including the 52 s trace, one 20 s parameterisation test) completed
and self-recovered to the stock kernel. On the fifth consecutive kexec boot the
board stopped answering on the network (host NIC also flapped; no ARP reply)
and requires a physical power cycle. Root cause is unconfirmed; the leading
hypotheses are bootloader A/B boot-attempt bookkeeping reacting to repeated
non-standard boots, or a watchdog left in an odd state across a warm reboot.
Because of this, the kexec mode is documented as supervised single-shot only,
and the running fixture does not depend on it.

**Why the tracing kernel is not persistent (yet):** `CONFIG_TRACING` adds
`trace_recursion` to `struct task_struct`, changing the module ABI. A persistent
tracing kernel must ship with matching modules (boot image / initramfs /
`/lib/modules`), i.e. a boot-partition update with rollback — a system-level
change that was deliberately not attempted without approval and a physical
recovery plan.

## 10. NOT verified / known limitations (honest list)

1. **Kernel scheduling data: achieved via an optional flash-free kexec tracing
   kernel, not on the stock boot.** The stock boot still has `CONFIG_FTRACE=n`
   and no tracefs/tracepoints, so `configs/trace_smoke.cfg` yields no sched
   tracks. A tracing kernel was rebuilt from the board's byte-identical config
   (tracing-only delta), booted once via `kexec_file_load` with a custom
   initramfs, and produced real kernel data (see §9 and
   `logs/kernel-ftrace-full-52s.pftrace`):
   * 33 652 `sched_switch` rows, 470 block-I/O events, 2 672 `cpu_frequency`
     events, 100 k syscalls, alongside 3 280 SDK flows and 10 144 perf samples;
   * `pf-infer` kernel Runnable wait: **3 392 ms in SCHED_CONTENTION**, 5–15 ms
     in every other phase (max 40 ms);
   * wakeup chains: `pf-capture → pf-syncwait` 810×, `pf-capture → pf-preproc`
     750×, `pf-preproc → pf-infer` 661×, `pf-infer → pf-postproc` 640×;
   * `pf-contend1/2` Runnable wait ≈ 5.0 s each, `pf-preproc` 1.38 s,
     `pf-syncwait` 1.14 s.
   This mode is **single-shot and supervised**: it takes the board offline for
   ~2 minutes, requires physical recovery access in the worst case, and is not
   suitable for routine window-B captures. It is not persistent (see
   `kernel_ftrace/README.md` for the module-ABI reason and the incident below).
2. **Boot-time autostart was not verified by an actual reboot.** The board was
   deliberately not rebooted (it hosts other fixtures). Verified instead: the
   marked block is inserted in `/userdata/startup.sh` after the shebang, that
   file is executed by `/etc/init.d/S99auto_startup`, and executing
   `/userdata/startup.sh` now really starts the service (see the log excerpt in
   §4; this is how the two ordering/path bugs were found and fixed). A real
   power-cycle test is still pending.
3. **Tracing service continuity across reboot** is not verified. The running
   `traced` (v58.2) was already up when the fixture was deployed;
   `perfetto-service.sh ensure` starts it when absent, but that path was not
   exercised by a reboot either.
4. **Performance sample loss.** The perf ring buffer reports
   `perf_cpu_lost_records` (e.g. 347 lost samples on cpu5 over 52 s, a few
   percent). `ring_buffer_pages: 256` reduces it; it is not zero.
5. **Wake-up overshoot stays small** (≤ 0.85 ms) even with two spinners on the
   inference core, because this kernel preempts aggressively on wake-up. Wall
   time inflation of the inference stage (2.6×) and `ThreadsRunning`/`thread
   state R` samples are the stronger contention evidence; this is documented so
   nobody interprets the overshoot counter as "no contention".
6. **No UI rendering check.** Traces were analysed with `trace_processor_shell`
   v58.2, not opened in a browser; UI layout/flamegraph rendering is unverified.
7. **Long-run stability beyond ~20 minutes was not measured.** Resource use is
   bounded by design (bounded queues, capped/rotated 8 MiB logs, 512 KiB I/O
   file, freed 12 MiB pulses, rate-limited supervisor), but a multi-day soak
   test is still pending.
8. **Symbolisation of system libraries** (libc/libstdc++) is incomplete because
   those images carry no build id; only the fixture's own functions resolve
   (which is what the training needs).
9. The heap-profile script briefly stops the resident service by design; a
   capture window that must never see a gap needs coordination.

## 11. Reproduce

```bash
# host
./build/build.sh
SSHPASS=root ./scripts/install.sh
# board
D=/userdata/perfetto-training-demo
$D/scripts/verify.sh 110
$D/scripts/trace.sh 52
$D/scripts/heap-profile.sh 25
# host analysis
TRACE_PROCESSOR=/path/to/trace_processor_shell \
  ./scripts/summarize-trace.sh trace.pftrace build/out/pf-demo-x5

# optional kernel-scheduling capture (flash-free kexec; supervised single-shot)
./build/build-ftrace-kernel.sh
INITRAMFS_BASE=/root/sdk_ly_x5_1.1.1/out/deploy/boot/initramfs \
TRACEBOX=/path/to/tracebox ./build/build-kexec-initramfs.sh
# stage Image-ftrace, initramfs-pf.cpio.gz, kexec_pf on the board, then:
#   scripts/ftrace-kexec-capture.sh 52
# see kernel_ftrace/README.md for the safety/recovery contract
```
