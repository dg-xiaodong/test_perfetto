// SPDX-License-Identifier: Apache-2.0
//
// pf-demo-x5 — a synthetic real-time vision pipeline used to teach Perfetto.
//
// The program is NOT a camera/BPU benchmark. Every stage is an explicitly
// named *simulation*: "SyntheticCapture", "InferenceStub", ... The CPU work,
// the memory allocations, the queueing and the blocking are real, though, so
// Perfetto shows real durations, real sleeps and real heap activity.
//
// Threads (all visible through /proc/<pid>/task/<tid>/comm):
//   pf-capture      synthetic 15-20 FPS frame source
//   pf-preproc      preprocess stage (CPU work, nested slices)
//   pf-infer        inference stub (CPU-heavy in CPU_BURST)
//   pf-postproc     postprocess stage, end-to-end latency accounting
//   pf-output       output stage, terminating flow, frame log
//   pf-contend1/2   CPU competitors on the inference core
//   pf-syncwait     condition_variable sleep/wakeup consumer
//   pf-memheap      native-heap pulse (malloc/touch/hold/free)
//   pf-ioworker     rate-limited, size-capped file I/O
//   pf-monitor      state/log/counter sampler
//   pf-schedprobe   wake-up overshoot probe (runnable-delay proxy)
//
// A 48-second cycle repeats forever:
//   BASELINE -> CPU_BURST -> SCHED_CONTENTION -> MEMORY_PULSE -> SYNC_IO ->
//   MIXED_PIPELINE -> ...
//
// All RNG/work is seeded deterministically, all clocks are monotonic, and the
// logs carry both CLOCK_MONOTONIC and CLOCK_BOOTTIME so the ground truth can
// be aligned with the Perfetto trace.

#include "pf_common.h"

#include "pf_trace.h"

// Exactly one translation unit must provide the category registry storage for
// the categories declared in pf_trace.h.
PERFETTO_TRACK_EVENT_STATIC_STORAGE();

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <map>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include <dirent.h>
#include <fcntl.h>
#include <malloc.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>

namespace pfdemo {
namespace {

#ifndef PF_DEMO_BUILD_ID
#define PF_DEMO_BUILD_ID "unknown"
#endif
#ifndef PF_DEMO_PERFETTO_SDK
#define PF_DEMO_PERFETTO_SDK "unknown"
#endif

constexpr char kProgramName[] = "pf-demo-x5";
constexpr char kProgramVersion[] = "1.0.0";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
struct Config {
  std::string data_dir = "/userdata/perfetto-training-demo";
  std::string log_dir;
  std::string io_path;
  int fps = 15;
  int phase_seconds = 8;
  int run_seconds = 0;  // 0 => run forever
  int cpu_a = -1;       // inference + contenders (+ sched probe)
  int cpu_b = -1;       // preprocess + syncwait
  bool enable_io = true;
  bool frame_log = true;
};

int64_t g_signal_stop = 0;

void SignalHandler(int) {
  g_signal_stop = 1;
}

void InstallSignalHandlers() {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = SignalHandler;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGINT, &sa, nullptr);
  sigaction(SIGTERM, &sa, nullptr);
  sigaction(SIGHUP, &sa, nullptr);
}

void PrintUsage() {
  printf(
      "%s v%s (Perfetto SDK %s, build %s)\n"
      "Synthetic real-time vision pipeline for Perfetto training.\n\n"
      "Usage: %s [options]\n"
      "  --data-dir DIR       persistent work dir (default /userdata/perfetto-training-demo)\n"
      "  --log-dir DIR        log dir (default <data-dir>/logs)\n"
      "  --io-path PATH       I/O buffer file (default <data-dir>/run/io-buffer.dat)\n"
      "  --fps N              capture frames per second (default 15, 5..25)\n"
      "  --phase-seconds N    seconds per phase (default 8, cycle = 6 phases)\n"
      "  --cpus A,B           pin to these CPUs instead of auto-selecting\n"
      "  --run-seconds N      stop after N seconds (default 0 = forever)\n"
      "  --no-io              disable the file I/O worker\n"
      "  --no-frame-log       disable per-frame log lines\n"
      "  --help               print this help\n",
      kProgramName, kProgramVersion, PF_DEMO_PERFETTO_SDK, PF_DEMO_BUILD_ID,
      kProgramName);
}

bool ParseCpuList(const std::string& text, int* a, int* b) {
  int cpus[2] = {-1, -1};
  size_t idx = 0;
  size_t pos = 0;
  while (pos <= text.size() && idx < 2) {
    size_t comma = text.find(',', pos);
    std::string item =
        text.substr(pos, comma == std::string::npos ? std::string::npos
                                                    : comma - pos);
    if (!item.empty()) {
      cpus[idx++] = atoi(item.c_str());
    }
    if (comma == std::string::npos) {
      break;
    }
    pos = comma + 1;
  }
  if (idx == 0) {
    return false;
  }
  *a = cpus[0];
  *b = cpus[1];
  return true;
}

bool ParseArgs(int argc, char** argv, Config* cfg) {
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    auto need_value = [&](const char* name) -> const char* {
      if (i + 1 >= argc) {
        fprintf(stderr, "missing value for %s\n", name);
        exit(2);
      }
      return argv[++i];
    };
    if (arg == "--help" || arg == "-h") {
      PrintUsage();
      exit(0);
    } else if (arg == "--data-dir") {
      cfg->data_dir = need_value("--data-dir");
    } else if (arg == "--log-dir") {
      cfg->log_dir = need_value("--log-dir");
    } else if (arg == "--io-path") {
      cfg->io_path = need_value("--io-path");
    } else if (arg == "--fps") {
      cfg->fps = atoi(need_value("--fps"));
      if (cfg->fps < 5 || cfg->fps > 25) {
        fprintf(stderr, "--fps must be in [5,25]\n");
        return false;
      }
    } else if (arg == "--phase-seconds") {
      cfg->phase_seconds = atoi(need_value("--phase-seconds"));
      if (cfg->phase_seconds < 4 || cfg->phase_seconds > 60) {
        fprintf(stderr, "--phase-seconds must be in [4,60]\n");
        return false;
      }
    } else if (arg == "--cpus") {
      if (!ParseCpuList(need_value("--cpus"), &cfg->cpu_a, &cfg->cpu_b)) {
        fprintf(stderr, "invalid --cpus value\n");
        return false;
      }
    } else if (arg == "--run-seconds") {
      cfg->run_seconds = atoi(need_value("--run-seconds"));
      if (cfg->run_seconds < 0) {
        fprintf(stderr, "--run-seconds must be >= 0\n");
        return false;
      }
    } else if (arg == "--no-io") {
      cfg->enable_io = false;
    } else if (arg == "--no-frame-log") {
      cfg->frame_log = false;
    } else {
      fprintf(stderr, "unknown option: %s (try --help)\n", arg.c_str());
      return false;
    }
  }
  if (cfg->log_dir.empty()) {
    cfg->log_dir = cfg->data_dir + "/logs";
  }
  if (cfg->io_path.empty()) {
    cfg->io_path = cfg->data_dir + "/run/io-buffer.dat";
  }
  return true;
}

bool MkdirP(const std::string& path) {
  if (path.empty()) {
    return false;
  }
  std::string current;
  for (size_t i = 0; i < path.size(); ++i) {
    current.push_back(path[i]);
    if (path[i] == '/' && current.size() > 1) {
      mkdir(current.c_str(), 0755);
    }
  }
  mkdir(path.c_str(), 0755);
  struct stat st;
  return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

std::string DirName(const std::string& path) {
  const size_t pos = path.find_last_of('/');
  if (pos == std::string::npos) {
    return ".";
  }
  return pos == 0 ? "/" : path.substr(0, pos);
}

// ---------------------------------------------------------------------------
// CPU discovery / affinity selection.
//
// The board already runs other test services, so the demo must not assume that
// any particular core is free. It reads the process' allowed CPU mask, samples
// per-core utilisation from /proc/stat and picks the two least busy cores.
// ---------------------------------------------------------------------------
bool ParseAllowedCpuList(std::string text, std::vector<int>* out) {
  out->clear();
  size_t pos = 0;
  while (pos < text.size()) {
    size_t comma = text.find(',', pos);
    std::string item =
        text.substr(pos, comma == std::string::npos ? std::string::npos
                                                    : comma - pos);
    if (!item.empty()) {
      size_t dash = item.find('-');
      if (dash == std::string::npos) {
        out->push_back(atoi(item.c_str()));
      } else {
        const int lo = atoi(item.substr(0, dash).c_str());
        const int hi = atoi(item.substr(dash + 1).c_str());
        for (int cpu = std::max(0, lo); cpu <= hi; ++cpu) {
          out->push_back(cpu);
        }
      }
    }
    if (comma == std::string::npos) {
      break;
    }
    pos = comma + 1;
  }
  return !out->empty();
}

bool ReadAllowedCpus(std::vector<int>* cpus) {
  FILE* f = fopen("/proc/self/status", "r");
  if (!f) {
    return false;
  }
  char line[256];
  bool ok = false;
  while (fgets(line, sizeof(line), f)) {
    if (strncmp(line, "Cpus_allowed_list:", 18) == 0) {
      std::string list = line + 18;
      while (!list.empty() && (list.front() == ' ' || list.front() == '\t')) {
        list.erase(list.begin());
      }
      while (!list.empty() && (list.back() == '\n' || list.back() == '\r')) {
        list.pop_back();
      }
      ok = ParseAllowedCpuList(list, cpus);
      break;
    }
  }
  fclose(f);
  return ok;
}

bool ReadPerCpuBusyPct(std::map<int, double>* busy_pct) {
  FILE* f = fopen("/proc/stat", "r");
  if (!f) {
    return false;
  }
  char line[512];
  std::map<int, uint64_t> busy, total;
  while (fgets(line, sizeof(line), f)) {
    if (strncmp(line, "cpu", 3) != 0 || line[3] < '0' || line[3] > '9') {
      continue;
    }
    int cpu = atoi(line + 3);
    unsigned long long v[10] = {0};
    int n = sscanf(line, "cpu%*d %llu %llu %llu %llu %llu %llu %llu %llu %llu",
                   &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7],
                   &v[8]);
    if (n < 4) {
      continue;
    }
    unsigned long long sum = 0;
    for (int i = 0; i < 9; ++i) {
      sum += v[i];
    }
    const unsigned long long idle = v[3] + v[4];  // idle + iowait
    total[cpu] = sum;
    busy[cpu] = sum - idle;
  }
  fclose(f);
  if (busy.empty()) {
    return false;
  }
  // Second sample 300 ms later.
  SleepMs(300);
  f = fopen("/proc/stat", "r");
  if (!f) {
    return false;
  }
  while (fgets(line, sizeof(line), f)) {
    if (strncmp(line, "cpu", 3) != 0 || line[3] < '0' || line[3] > '9') {
      continue;
    }
    const int cpu = atoi(line + 3);
    unsigned long long v[10] = {0};
    int n = sscanf(line, "cpu%*d %llu %llu %llu %llu %llu %llu %llu %llu %llu",
                   &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7],
                   &v[8]);
    if (n < 4) {
      continue;
    }
    unsigned long long sum = 0;
    for (int i = 0; i < 9; ++i) {
      sum += v[i];
    }
    const unsigned long long idle = v[3] + v[4];
    const uint64_t d_total = sum - total[cpu];
    const uint64_t d_busy = (sum - idle) - busy[cpu];
    double pct = d_total ? 100.0 * static_cast<double>(d_busy) /
                               static_cast<double>(d_total)
                         : 0.0;
    (*busy_pct)[cpu] = pct;
  }
  fclose(f);
  return !busy_pct->empty();
}

// Cores already reserved by other user-space services on the board. The X5
// image runs several other test fixtures out of /userdata; they pin their
// worker threads to explicit cores. Rather than hard-coding "cpu 6/7 are free",
// inspect *thread-level* affinity masks of other /userdata processes and avoid
// those cores when enough alternatives exist.
void CollectReservedCpus(int self_pid, std::set<int>* reserved) {
  DIR* proc = opendir("/proc");
  if (!proc) {
    return;
  }
  struct dirent* entry;
  while ((entry = readdir(proc)) != nullptr) {
    const int pid = atoi(entry->d_name);
    if (pid <= 0 || pid == self_pid) {
      continue;
    }
    char cmdline_path[64];
    snprintf(cmdline_path, sizeof(cmdline_path), "/proc/%d/cmdline", pid);
    FILE* f = fopen(cmdline_path, "rb");
    if (!f) {
      continue;
    }
    char cmdline[512] = {0};
    const size_t n = fread(cmdline, 1, sizeof(cmdline) - 1, f);
    fclose(f);
    if (n == 0 || strstr(cmdline, "/userdata/") == nullptr) {
      continue;
    }
    if (strstr(cmdline, "perfetto-training-demo") != nullptr) {
      continue;  // our own supervisor/scripts
    }
    char task_dir[64];
    snprintf(task_dir, sizeof(task_dir), "/proc/%d/task", pid);
    DIR* tasks = opendir(task_dir);
    if (!tasks) {
      continue;
    }
    struct dirent* task;
    while ((task = readdir(tasks)) != nullptr) {
      const int tid = atoi(task->d_name);
      if (tid <= 0) {
        continue;
      }
      char status_path[96];
      snprintf(status_path, sizeof(status_path), "%s/%d/status", task_dir, tid);
      FILE* sf = fopen(status_path, "r");
      if (!sf) {
        continue;
      }
      char line[256];
      std::vector<int> mask;
      while (fgets(line, sizeof(line), sf)) {
        if (strncmp(line, "Cpus_allowed_list:", 18) == 0) {
          std::string list = line + 18;
          ParseAllowedCpuList(list, &mask);
          break;
        }
      }
      fclose(sf);
      // Services that pin themselves to one or two cores have "reserved"
      // those cores for practical purposes; the demo should stay off them.
      // Masks spanning the whole system are ordinary schedulable processes and
      // do not reserve anything.
      if (!mask.empty() && mask.size() <= 2) {
        for (int cpu : mask) {
          reserved->insert(cpu);
        }
      }
    }
    closedir(tasks);
  }
  closedir(proc);
}

void SelectCpus(const Config& cfg, RotatingLog* log, int* cpu_a, int* cpu_b,
                std::vector<int>* allowed_out) {
  std::vector<int> allowed;
  if (!ReadAllowedCpus(&allowed)) {
    allowed.push_back(0);
  }
  *allowed_out = allowed;
  if (cfg.cpu_a >= 0) {
    *cpu_a = cfg.cpu_a;
    *cpu_b = cfg.cpu_b;
    log->Write("CPU_SELECT mode=fixed cpu_a=%d cpu_b=%d", *cpu_a, *cpu_b);
    return;
  }
  std::map<int, double> busy;
  ReadPerCpuBusyPct(&busy);
  std::set<int> reserved;
  CollectReservedCpus(static_cast<int>(getpid()), &reserved);

  std::vector<int> candidates;
  for (int cpu : allowed) {
    if (reserved.count(cpu) == 0) {
      candidates.push_back(cpu);
    }
  }
  if (candidates.size() < 2) {
    candidates = allowed;  // every core is claimed: fall back to load only
  }
  std::sort(candidates.begin(), candidates.end(), [&](int a, int b) {
    const double ba = busy.count(a) ? busy[a] : 0.0;
    const double bb = busy.count(b) ? busy[b] : 0.0;
    if (ba != bb) {
      return ba < bb;
    }
    // Prefer a non-zero core on ties: cpu0 also takes IRQs/timers.
    return a > b;
  });
  *cpu_a = candidates[0];
  *cpu_b = candidates.size() > 1 ? candidates[1] : candidates[0];
  std::string detail;
  for (int cpu : allowed) {
    char tmp[64];
    snprintf(tmp, sizeof(tmp), "cpu%d=%.1f%%%s", cpu,
             busy.count(cpu) ? busy[cpu] : 0.0,
             reserved.count(cpu) ? "(reserved)" : "");
    if (!detail.empty()) {
      detail += " ";
    }
    detail += tmp;
  }
  log->Write("CPU_SELECT mode=auto cpu_a=%d cpu_b=%d busy=\"%s\"", *cpu_a,
             *cpu_b, detail.c_str());
}

// ---------------------------------------------------------------------------
// Real CPU work. Deterministic and never optimized away (results are folded
// into the frame checksum / global sink).
// ---------------------------------------------------------------------------
std::atomic<uint64_t> g_sink{0};

__attribute__((noinline)) uint64_t CpuWork(uint64_t seed, uint64_t iters) {
  uint64_t h = seed | 1;
  for (uint64_t i = 0; i < iters; ++i) {
    h ^= h << 13;
    h ^= h >> 7;
    h ^= h << 17;
    h += i * 0x9e3779b97f4a7c15ULL;
  }
  return h;
}

__attribute__((noinline)) uint64_t PreprocessResize(
    const std::vector<uint8_t>& in, uint64_t seed) {
  uint64_t acc = seed * 0x100000001b3ULL;
  for (size_t i = 0; i + 3 < in.size(); i += 7) {
    acc = acc * 131 + in[i] + in[i + 1] * 3 + in[i + 2];
  }
  return acc;
}

// Two "kernels" so the CPU profile shows a small, readable call tree under
// InferenceStub instead of a single anonymous leaf.
__attribute__((noinline)) uint64_t InferenceConv3x3(uint64_t seed,
                                                    uint64_t iters) {
  TRACE_EVENT("pipeline", "infer.kernel_conv3x3", "iters", iters);
  uint64_t h = seed ^ 0xc0ffee;
  for (uint64_t i = 0; i < iters; ++i) {
    h ^= h << 7;
    h += (i | 1) * 0x2545f4914f6cdd1dULL;
    h ^= h >> 9;
  }
  return h;
}

__attribute__((noinline)) uint64_t InferenceGemm(uint64_t seed,
                                                 uint64_t iters) {
  TRACE_EVENT("pipeline", "infer.kernel_gemm", "iters", iters);
  uint64_t h = seed + 0x9e3779b9;
  for (uint64_t i = 0; i < iters; ++i) {
    h = h * 6364136223846793005ULL + 1442695040888963407ULL;
    h ^= h >> 11;
  }
  return h;
}

__attribute__((noinline)) uint64_t PostprocessNms(uint64_t seed,
                                                  uint64_t iters) {
  TRACE_EVENT("pipeline", "postproc.filter_stub", "iters", iters);
  return CpuWork(seed ^ 0xabcdef, iters);
}

__attribute__((noinline)) void ContendSpin(int64_t until_ns) {
  uint64_t h = 0x1234567;
  while (MonoNs() < until_ns) {
    for (int i = 0; i < 4096; ++i) {
      h ^= h << 5;
      h += static_cast<uint64_t>(i) * 0x9e3779b1ULL;
    }
  }
  g_sink.fetch_xor(h);
}

// ---------------------------------------------------------------------------
// Phase profiles. The only purpose is to give every phase a recognisable,
// deterministic signature. Numbers were calibrated on RDK X5 (8x Cortex-A55).
// ---------------------------------------------------------------------------
struct PhaseProfile {
  int capture_fps;
  uint64_t preprocess_iters;
  uint64_t infer_conv_iters;
  uint64_t infer_gemm_iters;
  uint64_t post_iters;
};

const PhaseProfile& ProfileFor(Phase p) {
  static const PhaseProfile profiles[kPhaseCount] = {
      /* BASELINE        */ {15, 300000, 350000, 350000, 150000},
      /* CPU_BURST       */ {15, 1800000, 4000000, 4000000, 500000},
      /* SCHED_CONTENTION*/ {15, 600000, 2200000, 2200000, 200000},
      /* MEMORY_PULSE    */ {15, 500000, 300000, 300000, 200000},
      /* SYNC_IO         */ {15, 400000, 250000, 250000, 150000},
      /* MIXED_PIPELINE  */ {20, 900000, 2000000, 2000000, 350000},
  };
  const int idx = static_cast<int>(p);
  return profiles[(idx >= 0 && idx < kPhaseCount) ? idx : 0];
}

// ---------------------------------------------------------------------------
// Frame + shared state
// ---------------------------------------------------------------------------
struct Frame {
  uint64_t id = 0;
  Phase phase = Phase::kBaseline;
  int64_t mono_capture_ns = 0;
  int64_t boot_capture_ns = 0;
  int64_t mono_preprocess_ns = 0;
  int64_t mono_infer_ns = 0;
  int64_t mono_post_ns = 0;
  int64_t mono_output_ns = 0;
  int64_t dur_capture_ns = 0;
  int64_t dur_preprocess_ns = 0;
  int64_t dur_infer_ns = 0;
  int64_t dur_postprocess_ns = 0;
  int64_t dur_output_ns = 0;
  uint32_t payload_bytes = 0;
  uint64_t checksum = 0;
  double e2e_ms = 0.0;
  std::vector<uint8_t> payload;
};

struct ThreadRecord {
  int tid = -1;
  std::string name;
};

struct Shared {
  Config cfg;
  std::atomic<bool> stop{false};
  std::atomic<Phase> phase{Phase::kBaseline};
  std::atomic<int> cycle_index{0};
  std::atomic<int> phase_index{0};
  std::atomic<int64_t> phase_started_mono_ns{0};
  std::atomic<uint64_t> frames_captured{0};
  std::atomic<uint64_t> frames_completed{0};
  std::atomic<uint64_t> next_frame_id{1};
  std::atomic<int64_t> live_bytes{0};
  std::atomic<double> last_e2e_ms{0.0};
  std::atomic<double> last_wakeup_overshoot_ms{0.0};
  std::atomic<uint64_t> cv_notifications{0};
  std::atomic<int64_t> io_bytes_written{0};
  int64_t started_mono_ns = 0;

  BoundedQueue<Frame> q_capture_pre{8};
  BoundedQueue<Frame> q_pre_infer{8};
  BoundedQueue<Frame> q_infer_post{8};
  BoundedQueue<Frame> q_post_out{16};

  RotatingLog service_log;
  RotatingLog frame_log;

  int cpu_a = -1;
  int cpu_b = -1;

  std::mutex cv_mutex;
  std::condition_variable cv;
  uint64_t cv_seq = 0;  // guarded by cv_mutex

  std::mutex thread_mutex;
  std::vector<ThreadRecord> thread_records;
  std::atomic<int> tid_infer{-1};
  std::atomic<int> tid_contend1{-1};
  std::atomic<int> tid_contend2{-1};

  void RegisterThread(const char* name) {
    const int tid = CurrentTid();
    {
      std::lock_guard<std::mutex> lock(thread_mutex);
      thread_records.push_back(ThreadRecord{tid, name});
    }
    service_log.Write("THREAD tid=%d name=%s mono_ns=%lld", tid, name,
                      static_cast<long long>(MonoNs()));
    if (strcmp(name, "pf-infer") == 0) {
      tid_infer.store(tid);
    } else if (strcmp(name, "pf-contend1") == 0) {
      tid_contend1.store(tid);
    } else if (strcmp(name, "pf-contend2") == 0) {
      tid_contend2.store(tid);
    }
  }
};

// ---------------------------------------------------------------------------
// Stage workers
// ---------------------------------------------------------------------------
void CaptureThread(Shared& sh) {
  SetThreadName("pf-capture");
  PerfettoSetCurrentThreadName("pf-capture");
  sh.RegisterThread("pf-capture");

  int64_t next = MonoNs();
  while (!sh.stop.load()) {
    const Phase phase = sh.phase.load();
    const PhaseProfile& profile = ProfileFor(phase);
    const int64_t period_ns = 1000000000LL / profile.capture_fps;
    next += period_ns;
    // If the producer was blocked (full queue during contention/mixed phases),
    // do not "catch up" with a burst of frames: that would inflate the frame
    // rate and make the FPS log lie. Resynchronise the schedule instead.
    if (next < MonoNs() - period_ns) {
      next = MonoNs() + period_ns;
    }
    SleepUntilMonoNs(next);
    if (sh.stop.load()) {
      break;
    }

    Frame frame;
    frame.id = sh.next_frame_id.fetch_add(1);
    frame.phase = phase;
    frame.boot_capture_ns = BootNs();
    frame.mono_capture_ns = MonoNs();

    const bool pipeline_sample = (frame.id % kFramePipelineSampleEvery) == 0;
    if (pipeline_sample) {
      TRACE_EVENT_BEGIN("pipeline", "FramePipeline",
                        FramePipelineTrack(frame.id), "frame_id", frame.id,
                        "phase", PhaseName(phase));
    }

    const int64_t capture_stage_start = MonoNs();
    TRACE_EVENT_BEGIN("pipeline", "SyntheticCapture",
                      perfetto::Flow::ProcessScoped(frame.id), "frame_id",
                      frame.id, "phase", PhaseName(phase));

    // Synthetic sensor frame: a byte buffer that is actually written to, so
    // the cost (and the heap traffic) is real.
    {
      TRACE_EVENT_BEGIN("pipeline", "capture.fill_buffer");
      const size_t bytes =
          (phase == Phase::kMixedPipeline) ? 48u * 1024u : 32u * 1024u;
      frame.payload.resize(bytes);
      const uint8_t pattern = static_cast<uint8_t>(frame.id * 37 + 11);
      memset(frame.payload.data(), pattern, bytes);
      for (size_t i = 0; i < bytes; i += 256) {
        frame.payload[i] = static_cast<uint8_t>(frame.id + i);
      }
      frame.payload_bytes = static_cast<uint32_t>(bytes);
      frame.checksum = CpuWork(frame.id, 60000);
      TRACE_EVENT_END("pipeline", "bytes", static_cast<int64_t>(bytes));
    }

    TRACE_EVENT_END("pipeline");
    frame.dur_capture_ns = MonoNs() - capture_stage_start;

    // Wake the condition-variable consumer with a real payload (frame id).
    {
      std::lock_guard<std::mutex> lock(sh.cv_mutex);
      sh.cv_seq += 1;
    }
    sh.cv.notify_one();

    TRACE_EVENT_BEGIN("sync", "QueuePush.capture_to_pre");
    int64_t blocked_ns = 0;
    const bool ok = sh.q_capture_pre.Push(std::move(frame), sh.stop, &blocked_ns);
    TRACE_EVENT_END("sync", "blocked_ms",
                    static_cast<double>(blocked_ns) / 1e6);
    if (!ok) {
      break;
    }
    sh.frames_captured.fetch_add(1);
  }
}

void PreprocessThread(Shared& sh) {
  SetThreadName("pf-preproc");
  PinToCpu(sh.cpu_b);
  PerfettoSetCurrentThreadName("pf-preproc");
  sh.RegisterThread("pf-preproc");

  while (!sh.stop.load()) {
    Frame frame;
    int64_t wait_ns = 0;
    TRACE_EVENT_BEGIN("sync", "QueueWait.preprocess");
    const bool ok = sh.q_capture_pre.Pop(&frame, sh.stop, &wait_ns);
    TRACE_EVENT_END("sync", "wait_ms", static_cast<double>(wait_ns) / 1e6);
    if (!ok) {
      break;
    }

    frame.mono_preprocess_ns = MonoNs();
    const PhaseProfile& profile = ProfileFor(frame.phase);
    const int64_t preprocess_stage_start = MonoNs();

    TRACE_EVENT_BEGIN("pipeline", "Preprocess",
                      perfetto::Flow::ProcessScoped(frame.id), "frame_id",
                      frame.id, "phase", PhaseName(frame.phase));

    uint64_t resize_out = 0;
    {
      TRACE_EVENT_BEGIN("pipeline", "preproc.resize");
      resize_out = PreprocessResize(frame.payload, frame.id);
      TRACE_EVENT_END("pipeline");
    }
    uint64_t normalize_out = 0;
    {
      TRACE_EVENT_BEGIN("pipeline", "preproc.normalize");
      normalize_out = CpuWork(resize_out, profile.preprocess_iters);
      TRACE_EVENT_END("pipeline");
    }
    frame.checksum ^= resize_out ^ normalize_out;

    TRACE_EVENT_END("pipeline");
    frame.dur_preprocess_ns = MonoNs() - preprocess_stage_start;

    TRACE_EVENT_BEGIN("sync", "QueuePush.pre_to_infer");
    int64_t blocked_ns = 0;
    const bool pushed = sh.q_pre_infer.Push(std::move(frame), sh.stop, &blocked_ns);
    TRACE_EVENT_END("sync", "blocked_ms", static_cast<double>(blocked_ns) / 1e6);
    if (!pushed) {
      break;
    }
  }
}

void InferenceThread(Shared& sh) {
  SetThreadName("pf-infer");
  PinToCpu(sh.cpu_a);
  PerfettoSetCurrentThreadName("pf-infer");
  sh.RegisterThread("pf-infer");

  while (!sh.stop.load()) {
    Frame frame;
    int64_t wait_ns = 0;
    TRACE_EVENT_BEGIN("sync", "QueueWait.inference");
    const bool ok = sh.q_pre_infer.Pop(&frame, sh.stop, &wait_ns);
    TRACE_EVENT_END("sync", "wait_ms", static_cast<double>(wait_ns) / 1e6);
    if (!ok) {
      break;
    }

    frame.mono_infer_ns = MonoNs();
    const PhaseProfile& profile = ProfileFor(frame.phase);
    const int64_t infer_stage_start = MonoNs();

    TRACE_EVENT_BEGIN("pipeline", "InferenceStub",
                      perfetto::Flow::ProcessScoped(frame.id), "frame_id",
                      frame.id, "phase", PhaseName(frame.phase));

    const uint64_t conv = InferenceConv3x3(frame.checksum,
                                           profile.infer_conv_iters);
    const uint64_t gemm = InferenceGemm(conv, profile.infer_gemm_iters);
    frame.checksum ^= gemm;

    TRACE_EVENT_END("pipeline");
    frame.dur_infer_ns = MonoNs() - infer_stage_start;

    TRACE_EVENT_BEGIN("sync", "QueuePush.infer_to_post");
    int64_t blocked_ns = 0;
    const bool pushed = sh.q_infer_post.Push(std::move(frame), sh.stop, &blocked_ns);
    TRACE_EVENT_END("sync", "blocked_ms", static_cast<double>(blocked_ns) / 1e6);
    if (!pushed) {
      break;
    }
  }
}

void PostprocessThread(Shared& sh) {
  SetThreadName("pf-postproc");
  PerfettoSetCurrentThreadName("pf-postproc");
  sh.RegisterThread("pf-postproc");

  while (!sh.stop.load()) {
    Frame frame;
    int64_t wait_ns = 0;
    TRACE_EVENT_BEGIN("sync", "QueueWait.postprocess");
    const bool ok = sh.q_infer_post.Pop(&frame, sh.stop, &wait_ns);
    TRACE_EVENT_END("sync", "wait_ms", static_cast<double>(wait_ns) / 1e6);
    if (!ok) {
      break;
    }

    frame.mono_post_ns = MonoNs();
    const PhaseProfile& profile = ProfileFor(frame.phase);
    const int64_t postprocess_stage_start = MonoNs();

    TRACE_EVENT_BEGIN("pipeline", "Postprocess",
                      perfetto::Flow::ProcessScoped(frame.id), "frame_id",
                      frame.id, "phase", PhaseName(frame.phase));

    if (frame.phase == Phase::kMixedPipeline) {
      // Simulated result post-processing tail: deterministic 40..70 ms. It
      // makes postprocess the slowest stage (above the 50 ms capture period),
      // so the bounded queues build a visible backlog in this phase.
      SleepMs(40 + static_cast<int>(frame.id % 4) * 10);
    }
    const uint64_t filtered = PostprocessNms(frame.checksum,
                                             profile.post_iters);
    frame.checksum ^= filtered;
    frame.mono_output_ns = MonoNs();
    frame.e2e_ms =
        static_cast<double>(frame.mono_output_ns - frame.mono_capture_ns) /
        1e6;

    TRACE_EVENT_END("pipeline", "e2e_ms", frame.e2e_ms);
    frame.dur_postprocess_ns = MonoNs() - postprocess_stage_start;

    if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
      EmitCounter(EndToEndLatencyTrack(), frame.e2e_ms);
    }

    TRACE_EVENT_BEGIN("sync", "QueuePush.post_to_output");
    int64_t blocked_ns = 0;
    const bool pushed = sh.q_post_out.Push(std::move(frame), sh.stop, &blocked_ns);
    TRACE_EVENT_END("sync", "blocked_ms", static_cast<double>(blocked_ns) / 1e6);
    if (!pushed) {
      break;
    }
  }
}

void OutputThread(Shared& sh) {
  SetThreadName("pf-output");
  PerfettoSetCurrentThreadName("pf-output");
  sh.RegisterThread("pf-output");

  while (!sh.stop.load()) {
    Frame frame;
    int64_t wait_ns = 0;
    TRACE_EVENT_BEGIN("sync", "QueueWait.output");
    const bool ok = sh.q_post_out.Pop(&frame, sh.stop, &wait_ns);
    TRACE_EVENT_END("sync", "wait_ms", static_cast<double>(wait_ns) / 1e6);
    if (!ok) {
      break;
    }

    const int64_t output_ns = MonoNs();
    const int64_t output_stage_start = MonoNs();

    TRACE_EVENT_BEGIN("pipeline", "Output",
                      perfetto::TerminatingFlow::ProcessScoped(frame.id),
                      "frame_id", frame.id, "e2e_ms", frame.e2e_ms);

    if (sh.cfg.frame_log) {
      sh.frame_log.Write(
          "FRAME mono_ns=%lld boot_ns=%lld id=%llu phase=%s "
          "cap_dur_ms=%.3f pre_dur_ms=%.3f inf_dur_ms=%.3f post_dur_ms=%.3f "
          "e2e_ms=%.3f bytes=%u checksum=%llu q1=%zu q2=%zu q3=%zu q4=%zu",
          static_cast<long long>(output_ns),
          static_cast<long long>(frame.boot_capture_ns),
          static_cast<unsigned long long>(frame.id), PhaseName(frame.phase),
          static_cast<double>(frame.dur_capture_ns) / 1e6,
          static_cast<double>(frame.dur_preprocess_ns) / 1e6,
          static_cast<double>(frame.dur_infer_ns) / 1e6,
          static_cast<double>(frame.dur_postprocess_ns) / 1e6,
          frame.e2e_ms, frame.payload_bytes,
          static_cast<unsigned long long>(frame.checksum),
          sh.q_capture_pre.size(), sh.q_pre_infer.size(),
          sh.q_infer_post.size(), sh.q_post_out.size());
    }

    sh.last_e2e_ms.store(frame.e2e_ms);
    const uint64_t completed = sh.frames_completed.fetch_add(1) + 1;
    if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
      EmitCounter(CompletedFramesTrack(), static_cast<double>(completed));
    }

    TRACE_EVENT_END("pipeline");
    frame.dur_output_ns = MonoNs() - output_stage_start;

    if ((frame.id % kFramePipelineSampleEvery) == 0) {
      TRACE_EVENT_END("pipeline", FramePipelineTrack(frame.id), "e2e_ms",
                      frame.e2e_ms);
    }
  }
}

void ContenderThread(Shared& sh, int index) {
  char name[16];
  snprintf(name, sizeof(name), "pf-contend%d", index);
  SetThreadName(name);
  PinToCpu(sh.cpu_a);
  PerfettoSetCurrentThreadName(name);
  sh.RegisterThread(name);

  while (!sh.stop.load()) {
    if (sh.phase.load() != Phase::kSchedContention) {
      SleepMs(100);
      continue;
    }
    const int64_t until = MonoNs() + 100 * 1000000LL;
    TRACE_EVENT_BEGIN("demo", index == 1 ? "contend.spin1" : "contend.spin2");
    while (!sh.stop.load() && MonoNs() < until &&
           sh.phase.load() == Phase::kSchedContention) {
      ContendSpin(MonoNs() + 1000000LL);
    }
    TRACE_EVENT_END("demo");
    SleepMs(5);
  }
}

void SyncWaitThread(Shared& sh) {
  SetThreadName("pf-syncwait");
  PinToCpu(sh.cpu_b);
  PerfettoSetCurrentThreadName("pf-syncwait");
  sh.RegisterThread("pf-syncwait");

  uint64_t seen = 0;
  while (!sh.stop.load()) {
    const Phase phase = sh.phase.load();
    const int timeout_ms = (phase == Phase::kSyncIo) ? 120 : 60;
    bool woken = false;
    {
      std::unique_lock<std::mutex> lock(sh.cv_mutex);
      TRACE_EVENT_BEGIN("sync", "CvWait", "timeout_ms",
                        static_cast<int64_t>(timeout_ms));
      woken = sh.cv.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                             [&] { return sh.cv_seq != seen || sh.stop.load(); });
      TRACE_EVENT_END("sync", "woken", static_cast<int64_t>(woken ? 1 : 0));
      seen = sh.cv_seq;
    }
    if (sh.stop.load()) {
      break;
    }
    if (woken) {
      sh.cv_notifications.fetch_add(1);
      TRACE_EVENT("sync", "CvWakeupWork");
      const uint64_t out =
          CpuWork(seen, (phase == Phase::kSyncIo) ? 600000 : 150000);
      g_sink.fetch_xor(out);
    } else {
      TRACE_EVENT_INSTANT("sync", "CvTimeout");
    }
  }
}

void MemoryThread(Shared& sh) {
  SetThreadName("pf-memheap");
  PerfettoSetCurrentThreadName("pf-memheap");
  sh.RegisterThread("pf-memheap");

  while (!sh.stop.load()) {
    if (sh.phase.load() == Phase::kMemoryPulse) {
      const size_t bytes = 12u * 1024u * 1024u;
      const int64_t alloc_start = MonoNs();
      TRACE_EVENT_BEGIN("memory", "MemoryPulse.alloc", "bytes",
                        static_cast<int64_t>(bytes));
      void* mem = malloc(bytes);
      if (mem) {
        memset(mem, 0x5a, bytes);  // fault in every page => real RSS growth
      }
      const int64_t live = sh.live_bytes.fetch_add(bytes) + bytes;
      if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
        EmitCounter(LiveAllocatedBytesTrack(), static_cast<double>(live));
      }
      TRACE_EVENT_END("memory", "alloc_ms",
                      static_cast<double>(MonoNs() - alloc_start) / 1e6);

      TRACE_EVENT_BEGIN("memory", "MemoryPulse.hold", "bytes",
                        static_cast<int64_t>(bytes));
      for (int i = 0; i < 40 && !sh.stop.load(); ++i) {
        SleepMs(100);
      }
      TRACE_EVENT_END("memory");

      TRACE_EVENT_BEGIN("memory", "MemoryPulse.free");
      free(mem);
      // glibc raises M_MMAP_THRESHOLD dynamically when a large mmap'd chunk is
      // freed, after which the next 12 MiB allocation comes from the brk heap
      // and the pages stay resident even after free() -- the RSS pulse would
      // disappear. The threshold is pinned in main() (mallopt), and malloc_trim
      // releases any residual free pages at the top of the heap.
      malloc_trim(0);
      const int64_t live_after = sh.live_bytes.fetch_sub(bytes) - bytes;
      if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
        EmitCounter(LiveAllocatedBytesTrack(), static_cast<double>(live_after));
      }
      TRACE_EVENT_END("memory");
      SleepMs(1500);
    } else {
      // Continuous small native-heap churn in the other phases, so the heap
      // profiler always has something to sample.
      const size_t bytes = 256u * 1024u;
      void* mem = malloc(bytes);
      if (mem) {
        memset(mem, 0x11, bytes);
      }
      const int64_t live = sh.live_bytes.fetch_add(bytes) + bytes;
      if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
        EmitCounter(LiveAllocatedBytesTrack(), static_cast<double>(live));
      }
      TRACE_EVENT("memory", "MemoryChurn", "bytes",
                  static_cast<int64_t>(bytes));
      SleepMs(120);
      free(mem);
      const int64_t live_after = sh.live_bytes.fetch_sub(bytes) - bytes;
      if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
        EmitCounter(LiveAllocatedBytesTrack(), static_cast<double>(live_after));
      }
      SleepMs(280);
    }
  }
}

void IoThread(Shared& sh) {
  SetThreadName("pf-ioworker");
  PerfettoSetCurrentThreadName("pf-ioworker");
  sh.RegisterThread("pf-ioworker");
  if (!sh.cfg.enable_io) {
    return;
  }

  const int fd = open(sh.cfg.io_path.c_str(),
                      O_CREAT | O_RDWR | O_APPEND | O_CLOEXEC, 0644);
  if (fd < 0) {
    sh.service_log.Write("IO_ERROR path=%s errno=%d",
                         sh.cfg.io_path.c_str(), errno);
    return;
  }
  sh.service_log.Write("IO_OPEN path=%s fd=%d", sh.cfg.io_path.c_str(), fd);

  uint64_t seq = 0;
  while (!sh.stop.load()) {
    const Phase phase = sh.phase.load();
    const int period_ms = (phase == Phase::kSyncIo) ? 200 : 1000;
    for (int slept = 0; slept < period_ms && !sh.stop.load(); slept += 100) {
      SleepMs(100);
    }
    if (sh.stop.load()) {
      break;
    }

    char buf[256];
    snprintf(buf, sizeof(buf), "seq=%llu mono_ns=%lld phase=%s ",
             static_cast<unsigned long long>(seq),
             static_cast<long long>(MonoNs()), PhaseName(phase));
    const size_t used = strlen(buf);
    memset(buf + used, '.', sizeof(buf) - used);

    TRACE_EVENT_BEGIN("io", "IoWrite", "bytes",
                      static_cast<int64_t>(sizeof(buf)));
    const ssize_t written = write(fd, buf, sizeof(buf));
    TRACE_EVENT_END("io", "bytes", static_cast<int64_t>(written));
    if (written > 0) {
      sh.io_bytes_written.fetch_add(written);
    }

    if (phase == Phase::kSyncIo || (seq % 10) == 0) {
      TRACE_EVENT_BEGIN("io", "IoFsync");
      fsync(fd);
      TRACE_EVENT_END("io");
    }
    if (phase == Phase::kSyncIo) {
      char read_buf[256];
      TRACE_EVENT_BEGIN("io", "IoRead");
      const ssize_t read_bytes = pread(fd, read_buf, sizeof(read_buf), 0);
      TRACE_EVENT_END("io", "bytes", static_cast<int64_t>(read_bytes));
    }

    // Hard cap on the on-disk footprint: never grow beyond 512 KiB.
    if ((seq % 20) == 0) {
      struct stat st;
      if (fstat(fd, &st) == 0 && st.st_size > 512 * 1024) {
        if (ftruncate(fd, 0) == 0) {
          TRACE_EVENT_INSTANT("io", "IoTruncate", "old_bytes",
                              static_cast<int64_t>(st.st_size));
        }
      }
      if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
        EmitCounter(IoFileBytesTrack(),
                    static_cast<double>(st.st_size > 0 ? st.st_size : 0));
      }
    }
    ++seq;
  }
  close(fd);
}

void SchedProbeThread(Shared& sh) {
  SetThreadName("pf-schedprobe");
  PinToCpu(sh.cpu_a);
  PerfettoSetCurrentThreadName("pf-schedprobe");
  sh.RegisterThread("pf-schedprobe");

  const int64_t interval_ns = 50 * 1000000LL;  // 20 Hz
  int64_t next = MonoNs() + interval_ns;
  while (!sh.stop.load()) {
    SleepUntilMonoNs(next);
    if (sh.stop.load()) {
      break;
    }
    const int64_t now = MonoNs();
    const double overshoot_ms = static_cast<double>(now - next) / 1e6;
    next += interval_ns;
    if (next < now) {
      next = now + interval_ns;
    }
    sh.last_wakeup_overshoot_ms.store(overshoot_ms);
    if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
      EmitCounter(WakeupOvershootTrack(), overshoot_ms);
      if (overshoot_ms > 1.0) {
        TRACE_EVENT_INSTANT("sync", "WakeupProbe", "overshoot_ms",
                            overshoot_ms);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Monitor: reads /proc, emits the real-sampled counters, writes the log.
// ---------------------------------------------------------------------------
struct TaskSample {
  char comm[17] = {0};
  char state = '?';
  uint64_t cpu_ticks = 0;
};

bool ReadTaskStat(int tid, char* state, uint64_t* cpu_ticks) {
  char path[80];
  snprintf(path, sizeof(path), "/proc/self/task/%d/stat", tid);
  FILE* f = fopen(path, "r");
  if (!f) {
    return false;
  }
  char buf[512];
  if (!fgets(buf, sizeof(buf), f)) {
    fclose(f);
    return false;
  }
  fclose(f);
  char* rparen = strrchr(buf, ')');
  if (!rparen || rparen[1] == '\0') {
    return false;
  }
  char st = '?';
  unsigned long long utime = 0;
  unsigned long long stime = 0;
  const int n = sscanf(rparen + 2,
                       "%c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu",
                       &st, &utime, &stime);
  if (n < 3) {
    return false;
  }
  *state = st;
  *cpu_ticks = utime + stime;
  return true;
}

bool ReadTaskComm(int tid, char* out, size_t out_size) {
  char path[80];
  snprintf(path, sizeof(path), "/proc/self/task/%d/comm", tid);
  FILE* f = fopen(path, "r");
  if (!f) {
    return false;
  }
  if (!fgets(out, static_cast<int>(out_size), f)) {
    fclose(f);
    return false;
  }
  fclose(f);
  size_t len = strlen(out);
  while (len > 0 && (out[len - 1] == '\n' || out[len - 1] == '\r')) {
    out[--len] = '\0';
  }
  return true;
}

bool ReadSelfStatus(int64_t* rss_kb, int64_t* vsz_kb, int* threads) {
  FILE* f = fopen("/proc/self/status", "r");
  if (!f) {
    return false;
  }
  char line[256];
  while (fgets(line, sizeof(line), f)) {
    if (strncmp(line, "VmRSS:", 6) == 0) {
      sscanf(line + 6, "%lld", reinterpret_cast<long long*>(rss_kb));
    } else if (strncmp(line, "VmSize:", 7) == 0) {
      sscanf(line + 7, "%lld", reinterpret_cast<long long*>(vsz_kb));
    } else if (strncmp(line, "Threads:", 8) == 0) {
      sscanf(line + 8, "%d", threads);
    }
  }
  fclose(f);
  return true;
}

void MonitorThread(Shared& sh) {
  SetThreadName("pf-monitor");
  PerfettoSetCurrentThreadName("pf-monitor");
  sh.RegisterThread("pf-monitor");

  const long clk_tck = sysconf(_SC_CLK_TCK);
  int64_t next_counters = MonoNs() + 500 * 1000000LL;
  int64_t next_log = MonoNs() + 1000 * 1000000LL;
  int64_t next_tasks = MonoNs() + 30000 * 1000000LL;

  std::map<int, uint64_t> prev_ticks;
  std::map<int, int64_t> prev_ticks_ns;

  while (!sh.stop.load()) {
    SleepMs(100);
    const int64_t now = MonoNs();

    if (now >= next_counters) {
      const size_t qdepth = sh.q_capture_pre.size() + sh.q_pre_infer.size() +
                            sh.q_infer_post.size() + sh.q_post_out.size();
      const uint64_t captured = sh.frames_captured.load();
      const uint64_t completed = sh.frames_completed.load();
      const int64_t inflight =
          static_cast<int64_t>(captured) - static_cast<int64_t>(completed);
      if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
        EmitCounter(QueueDepthTrack(), static_cast<double>(qdepth));
        EmitCounter(InflightFramesTrack(),
                    static_cast<double>(inflight > 0 ? inflight : 0));
      }
      next_counters += 500 * 1000000LL;
      if (next_counters < now) {
        next_counters = now + 500 * 1000000LL;
      }
    }

    if (now >= next_log) {
      int64_t rss_kb = 0, vsz_kb = 0;
      int threads = 0;
      ReadSelfStatus(&rss_kb, &vsz_kb, &threads);

      int running = 0, blocked = 0;
      int task_count = 0;
      DIR* dir = opendir("/proc/self/task");
      if (dir) {
        struct dirent* entry;
        while ((entry = readdir(dir)) != nullptr) {
          const int tid = atoi(entry->d_name);
          if (tid <= 0) {
            continue;
          }
          char state = '?';
          uint64_t ticks = 0;
          if (!ReadTaskStat(tid, &state, &ticks)) {
            continue;
          }
          ++task_count;
          if (state == 'R') {
            ++running;
          } else if (state == 'D') {
            ++blocked;
          }
          auto it = prev_ticks.find(tid);
          auto it_ns = prev_ticks_ns.find(tid);
          if (it != prev_ticks.end() && it_ns != prev_ticks_ns.end()) {
            const int64_t d_ns = now - it_ns->second;
            const uint64_t d_ticks = ticks - it->second;
            if (d_ns > 0 && clk_tck > 0) {
              const double pct = 100.0 * static_cast<double>(d_ticks) /
                                 (static_cast<double>(d_ns) / 1e9) /
                                 static_cast<double>(clk_tck);
              const int infer_tid = sh.tid_infer.load();
              if (tid == infer_tid) {
                if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
                  EmitCounter(CpuPctInferTrack(), pct);
                }
              } else if (tid == sh.tid_contend1.load()) {
                if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
                  EmitCounter(CpuPctContend1Track(), pct);
                }
              } else if (tid == sh.tid_contend2.load()) {
                if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
                  EmitCounter(CpuPctContend2Track(), pct);
                }
              }
            }
          }
          prev_ticks[tid] = ticks;
          prev_ticks_ns[tid] = now;
        }
        closedir(dir);
      }

      if (TRACE_EVENT_CATEGORY_ENABLED("demo")) {
        EmitCounter(RssKbTrack(), static_cast<double>(rss_kb));
        EmitCounter(ThreadsRunningTrack(), static_cast<double>(running));
        EmitCounter(ThreadsBlockedTrack(), static_cast<double>(blocked));
      }

      const size_t qdepth = sh.q_capture_pre.size() + sh.q_pre_infer.size() +
                            sh.q_infer_post.size() + sh.q_post_out.size();
      const uint64_t captured = sh.frames_captured.load();
      const uint64_t completed = sh.frames_completed.load();
      const int64_t inflight =
          static_cast<int64_t>(captured) - static_cast<int64_t>(completed);
      sh.service_log.Write(
          "MON mono_ns=%lld boot_ns=%lld cycle=%d phase=%s rss_kb=%lld "
          "vsz_kb=%lld threads=%d tasks=%d qdepth=%zu inflight=%lld "
          "captured=%llu completed=%llu e2e_last_ms=%.3f wakeup_over_ms=%.3f "
          "cv_wakeups=%llu live_bytes=%lld io_bytes=%lld running=%d blocked=%d",
          static_cast<long long>(now), static_cast<long long>(BootNs()),
          sh.cycle_index.load(), PhaseName(sh.phase.load()),
          static_cast<long long>(rss_kb), static_cast<long long>(vsz_kb),
          threads, task_count, qdepth, static_cast<long long>(inflight),
          static_cast<unsigned long long>(captured),
          static_cast<unsigned long long>(completed),
          sh.last_e2e_ms.load(), sh.last_wakeup_overshoot_ms.load(),
          static_cast<unsigned long long>(sh.cv_notifications.load()),
          static_cast<long long>(sh.live_bytes.load()),
          static_cast<long long>(sh.io_bytes_written.load()), running, blocked);

      next_log += 1000 * 1000000LL;
      if (next_log < now) {
        next_log = now + 1000 * 1000000LL;
      }
    }

    if (now >= next_tasks) {
      char line[1024];
      int off = snprintf(line, sizeof(line), "TASKS mono_ns=%lld",
                         static_cast<long long>(now));
      DIR* dir = opendir("/proc/self/task");
      if (dir) {
        struct dirent* entry;
        while ((entry = readdir(dir)) != nullptr && off < 900) {
          const int tid = atoi(entry->d_name);
          if (tid <= 0) {
            continue;
          }
          char comm[17] = {0};
          char state = '?';
          uint64_t ticks = 0;
          if (!ReadTaskComm(tid, comm, sizeof(comm)) ||
              !ReadTaskStat(tid, &state, &ticks)) {
            continue;
          }
          off += snprintf(line + off, sizeof(line) - off, " [%d:%s:%c]",
                          tid, comm, state);
        }
        closedir(dir);
      }
      sh.service_log.Write("%s", line);
      next_tasks += 30000 * 1000000LL;
    }
  }
}

// ---------------------------------------------------------------------------
// Main: phase director + lifecycle
// ---------------------------------------------------------------------------
void RunDirector(Shared& sh, const Config& cfg) {
  const int64_t phase_ns = static_cast<int64_t>(cfg.phase_seconds) * 1000000000LL;
  const int64_t cycle_ns = phase_ns * kPhaseCount;
  const int64_t start = MonoNs();
  int last_index = -1;
  int last_cycle = -1;

  while (!sh.stop.load()) {
    const int64_t elapsed = MonoNs() - start;
    if (cfg.run_seconds > 0 &&
        elapsed >= static_cast<int64_t>(cfg.run_seconds) * 1000000000LL) {
      sh.stop.store(true);
      break;
    }
    if (g_signal_stop != 0) {
      sh.stop.store(true);
      break;
    }
    const int cycle = static_cast<int>(elapsed / cycle_ns);
    const int index = static_cast<int>((elapsed % cycle_ns) / phase_ns);
    if (index != last_index || cycle != last_cycle) {
      last_index = index;
      last_cycle = cycle;
      const Phase phase = static_cast<Phase>(index);
      sh.phase.store(phase);
      sh.cycle_index.store(cycle);
      sh.phase_index.store(index);
      sh.phase_started_mono_ns.store(MonoNs());
      sh.service_log.Write(
          "PHASE cycle=%d idx=%d name=%s mono_ns=%lld boot_ns=%lld "
          "realtime_ns=%lld",
          cycle, index, PhaseName(phase),
          static_cast<long long>(MonoNs()),
          static_cast<long long>(BootNs()),
          static_cast<long long>(RealtimeNs()));
      TRACE_EVENT_INSTANT("demo", "PhaseChange", "phase", PhaseName(phase),
                          "cycle", static_cast<int64_t>(cycle), "phase_idx",
                          static_cast<int64_t>(index));
    }
    SleepMs(100);
  }
}

}  // namespace

int Run(int argc, char** argv) {
  Config cfg;
  if (!ParseArgs(argc, argv, &cfg)) {
    return 2;
  }
  if (!MkdirP(cfg.log_dir)) {
    fprintf(stderr, "cannot create log dir %s\n", cfg.log_dir.c_str());
    return 1;
  }
  MkdirP(DirName(cfg.io_path));

  Shared sh;
  sh.cfg = cfg;

  const std::string service_log_path = cfg.log_dir + "/pf-demo-x5.log";
  const std::string frame_log_path = cfg.log_dir + "/frames.log";
  if (!sh.service_log.Open(service_log_path, 8u * 1024u * 1024u)) {
    fprintf(stderr, "cannot open %s\n", service_log_path.c_str());
    return 1;
  }
  if (cfg.frame_log) {
    sh.frame_log.Open(frame_log_path, 8u * 1024u * 1024u);
  }

  InstallSignalHandlers();

  // Keep the 12 MiB MemoryPulse allocation on mmap (and therefore return its
  // pages to the OS on free) instead of letting glibc's dynamic mmap threshold
  // move it onto the retained brk heap. This is what makes the RSS pulse
  // reproducible over a multi-day run.
  mallopt(M_MMAP_THRESHOLD, 128 * 1024);
  mallopt(M_TRIM_THRESHOLD, 128 * 1024);

  std::vector<int> allowed_cpus;
  SelectCpus(cfg, &sh.service_log, &sh.cpu_a, &sh.cpu_b, &allowed_cpus);
  sh.started_mono_ns = MonoNs();

  // Perfetto SDK: system backend, no in-process tracing session. Events are
  // recorded only while window B (or scripts/trace.sh) runs a tracing session.
  PerfettoInit();
  PerfettoSetProcessName(kProgramName);
  PerfettoInitFramePipelineTracks();

  sh.service_log.Write(
      "BOOT program=%s version=%s build=%s sdk=\"%s\" pid=%d mono_ns=%lld "
      "boot_ns=%lld realtime_ns=%lld fps=%d phase_seconds=%d run_seconds=%d "
      "io=%d frame_log=%d cpus=%d,%d",
      kProgramName, kProgramVersion, PF_DEMO_BUILD_ID, PF_DEMO_PERFETTO_SDK,
      static_cast<int>(getpid()), static_cast<long long>(sh.started_mono_ns),
      static_cast<long long>(BootNs()), static_cast<long long>(RealtimeNs()),
      cfg.fps, cfg.phase_seconds, cfg.run_seconds, cfg.enable_io ? 1 : 0,
      cfg.frame_log ? 1 : 0, sh.cpu_a, sh.cpu_b);
  printf(
      "%s v%s (Perfetto SDK %s, build %s) pid=%d cpus=%d,%d logs=%s\n",
      kProgramName, kProgramVersion, PF_DEMO_PERFETTO_SDK, PF_DEMO_BUILD_ID,
      static_cast<int>(getpid()), sh.cpu_a, sh.cpu_b, cfg.log_dir.c_str());
  fflush(stdout);

  std::vector<std::thread> threads;
  threads.emplace_back(CaptureThread, std::ref(sh));
  threads.emplace_back(PreprocessThread, std::ref(sh));
  threads.emplace_back(InferenceThread, std::ref(sh));
  threads.emplace_back(PostprocessThread, std::ref(sh));
  threads.emplace_back(OutputThread, std::ref(sh));
  threads.emplace_back(ContenderThread, std::ref(sh), 1);
  threads.emplace_back(ContenderThread, std::ref(sh), 2);
  threads.emplace_back(SyncWaitThread, std::ref(sh));
  threads.emplace_back(MemoryThread, std::ref(sh));
  threads.emplace_back(IoThread, std::ref(sh));
  threads.emplace_back(MonitorThread, std::ref(sh));
  threads.emplace_back(SchedProbeThread, std::ref(sh));

  RunDirector(sh, cfg);

  sh.stop.store(true);
  sh.q_capture_pre.WakeAll();
  sh.q_pre_infer.WakeAll();
  sh.q_infer_post.WakeAll();
  sh.q_post_out.WakeAll();
  sh.cv.notify_all();
  for (auto& thread : threads) {
    thread.join();
  }

  const int64_t ran_ns = MonoNs() - sh.started_mono_ns;
  sh.service_log.Write(
      "STOP mono_ns=%lld boot_ns=%lld ran_s=%.1f captured=%llu completed=%llu "
      "live_bytes=%lld io_bytes=%lld",
      static_cast<long long>(MonoNs()), static_cast<long long>(BootNs()),
      static_cast<double>(ran_ns) / 1e9,
      static_cast<unsigned long long>(sh.frames_captured.load()),
      static_cast<unsigned long long>(sh.frames_completed.load()),
      static_cast<long long>(sh.live_bytes.load()),
      static_cast<long long>(sh.io_bytes_written.load()));
  sh.service_log.Flush();
  sh.frame_log.Flush();
  return 0;
}

}  // namespace pfdemo

int main(int argc, char** argv) {
  return pfdemo::Run(argc, argv);
}
