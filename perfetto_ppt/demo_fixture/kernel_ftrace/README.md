# Kernel scheduling data for the Perfetto fixture (optional kexec mode)

## Why this directory exists

The RDK X5 image under training is built with **`CONFIG_FTRACE=n`**:

```
# CONFIG_FTRACE is not set
$ mount -t tracefs tracefs /tmp/tr
mount: mounting tracefs on /tmp/tr failed: No such device
$ ls /sys/kernel/debug/tracing   -> does not exist
# CONFIG_SCHEDSTATS is not set, no /proc/schedstat
```

so a stock boot can never produce Perfetto's scheduling tracks
(`sched_switch`, Runnable/Sleeping, wakeup chains, block-I/O, ftrace
`cpu_frequency`). Perfetto's perf producer does not consume
`PERF_RECORD_SWITCH` either (checked in the v58.2 source), so userspace cannot
reconstruct those tracks without ftrace.

This directory contains the verified way to get **real kernel scheduling data**
anyway, without writing anything to the board's flash:

1. rebuild the *same* kernel source with tracing enabled, starting from the
   board's exact config (`board.config`, byte-identical to `/proc/config.gz`);
2. boot that kernel once via **`kexec_file_load`** (available on this kernel:
   `CONFIG_KEXEC_FILE=y`, arm64 `machine_kexec_file.c` builds the DTB from the
   current FDT and accepts an initramfs);
3. boot with a small initramfs that mounts tracefs, runs `pf-demo-x5` +
   `tracebox` for N seconds, writes the `.pftrace` to `/userdata`, and reboots
   back to the stock kernel;
4. the hardware watchdog (armed by the loader before kexec) guarantees a reset
   back to the stock boot if anything hangs.

Nothing on `mmcblk0` is modified: `reboot -f` returns to the stock kernel.

## Evidence (already recorded, see ../logs/)

`kernel-ftrace-full-52s.pftrace` — one near-full 48 s cycle, 9.9 MB:

| data | count / value |
|---|---|
| `sched_switch` rows | 33 652 |
| `sys_enter` / `sys_exit` | 100 254 / 100 249 |
| `cpu_frequency` events | 2 672 (300 MHz … 1.5 GHz) |
| block I/O events | 470 |
| SDK slices / flows / perf samples | 119 072 / 3 280 / 10 144 |
| perf CPU samples on `pf-infer` | top thread |

Kernel-level Runnable waits (`thread_state.state='R' AND cpu IS NULL`):

| thread | runnable segments | total | max |
|---|---|---|---|
| pf-contend1 | 750 | 5 033 ms | 40.0 ms |
| pf-contend2 | 752 | 4 927 ms | 42.2 ms |
| **pf-infer** | **1 685** | **3 448 ms** | **40.0 ms** |
| pf-preproc | 1 478 | 1 385 ms | 14.5 ms |
| pf-syncwait | 1 344 | 1 140 ms | 15.3 ms |

`pf-infer` runnable wait per phase: **SCHED_CONTENTION 3 392 ms**, all other
phases 5–15 ms. This is the kernel-level proof that the contention phase really
puts the inference thread on the runqueue.

Wakeup chains (`thread_state.waker_utid`, from `sched_waking`):

```
pf-postproc -> pf-output     811 times  (avg runnable wait 0.034 ms)
pf-capture  -> pf-syncwait   810 times  (1.339 ms)
pf-capture  -> pf-preproc    750 times  (1.799 ms)
pf-preproc  -> pf-infer      661 times  (0.342 ms)
pf-infer    -> pf-postproc   640 times  (0.038 ms)
```

## Build the pieces

```bash
# 1) tracing kernel (tracing-only delta from kernel_ftrace/board.config)
STOCK_CONFIG=.../kernel_ftrace/board.config \
  perfetto_ppt/demo_fixture/build/build-ftrace-kernel.sh
# -> build/out/Image-ftrace (+ Image-ftrace.txt with sha256 / release)

# 2) initramfs (stock SDK recovery ramfs + pf-demo-x5 + tracebox + configs)
INITRAMFS_BASE=/root/sdk_ly_x5_1.1.1/out/deploy/boot/initramfs \
TRACEBOX=/path/to/tracebox \
  perfetto_ppt/demo_fixture/build/build-kexec-initramfs.sh
# -> build/out/initramfs-pf.cpio.gz

# 3) loader (runs on the stock kernel)
aarch64-none-linux-gnu-gcc -O2 -o kexec_pf kernel_ftrace/kexec_pf.c

# 4) stage on the board
scp Image-ftrace initramfs-pf.cpio.gz kexec_pf root@board:/userdata/pf-kernel-test/
```

## Run a capture (one shot, ~2 minutes)

On the board (or over SSH):

```bash
cd /userdata/pf-kernel-test
./kexec_pf Image-ftrace initramfs-pf.cpio.gz \
  "console=ttyS0,921600n8 pf.mode=trace pf.duration=52000"
# SSH drops here. The board spends ~52 s capturing, reboots itself, and comes
# back on the stock kernel. Results:
#   /userdata/pf-kernel-test/logs/ftrace-full-<stamp>.pftrace   (rich config)
#   /userdata/pf-kernel-test/logs/ftrace-<stamp>.pftrace        (selected one)
#   /userdata/pf-kernel-test/logs/platform-<stamp>.txt          (tracefs diag)
#   /userdata/pf-kernel-test/logs/tracebox-*-<stamp>.log
```

`pf.duration` is parsed from the cmdline (5 s … 240 s); no initramfs rebuild
needed. `pf.mode=dry` validates the boot path without capturing.

The initramfs first tries `trace_full.cfg` (sched + block + power + syscalls)
and falls back to `trace_min.cfg` (sched only) if the kernel rejects any event.

## Critical safety / recovery notes

* **tracefs must be mounted by the initramfs.** Perfetto's `FtraceController`
  only detects an existing mount; without it the `linux.ftrace` data source
  fails with `Failed to create FtraceController` (this happened on the first
  attempt and is fixed in `initramfs-init.sh`).
* The loader arms `/dev/watchdog` (120 s) before `RB_KEXEC`. If the kexec'd
  kernel/initramfs hangs, hardware resets the board back to the stock boot.
* The initramfs disarms the watchdog only right before its final `reboot -f`.
* **Known incident (2026-10-21):** after the 5th consecutive kexec boot the
  board stopped responding on the network (no ARP, host NIC also flapped) and
  needed a physical power cycle. The first four kexec boots (dry-run, two
  captures incl. this 52 s trace) completed and self-recovered normally. Root
  cause is **not** confirmed; leading hypotheses are the bootloader's A/B
  boot-attempt bookkeeping reacting to repeated non-standard boots, or a
  watchdog state left armed across a warm reboot. Consequences:
  * treat this mode as a **supervised, single-shot** action, not something to
    run in a loop or from window B's routine captures;
  * keep physical access (power cycle / UART console) available;
  * between runs, verify the board came back on the stock kernel before
    starting another one.
* The capture runs the fixture inside the initramfs: camera/BPU modules are not
  loaded (they are ABI-incompatible with a tracing kernel anyway, see below),
  and the board is offline for ~2 minutes.

## Why not make the tracing kernel persistent yet

Enabling `CONFIG_TRACING` adds `trace_recursion` to `struct task_struct`
(`include/linux/sched.h`), i.e. it **changes the module ABI**. The stock
`/lib/modules` tree was built against the stock config; booting the tracing
kernel with it can corrupt camera/BPU/other driver state. A persistent tracing
kernel therefore requires replacing the kernel **and all modules together**
(boot image / initramfs / rootfs `/lib/modules`), i.e. a boot-partition update
with rollback — a system-level change that needs explicit approval and a
physical recovery plan. That work has **not** been done.
