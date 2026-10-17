// cpu_spike_fixture.cpp — controlled periodic CPU load for perfetto-cpu-debugging board test.
//
// Profile intended by the task:
//   - spike-worker : sleeps, then burns ~300 ms CPU every ~3000 ms (periodic spike)
//   - bg-light     : ~3 ms CPU every 100 ms (low steady background, ~3% of one core)
//   - main         : sleeps/wait only
// Runs for TOTAL_MS (default 30000).
//
// Every tick start/end is printed with CLOCK_MONOTONIC ns so the trace can be
// cross-checked against the process's own view (marker<->sched_slice alignment).
// Built static for aarch64 buildroot; no external deps.

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <pthread.h>
#include <thread>
#include <unistd.h>
#include <sys/syscall.h>

using clk = std::chrono::steady_clock;

static std::atomic<bool> g_stop{false};
static std::atomic<uint64_t> g_sink{0};

static int64_t now_ns() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             clk::now().time_since_epoch())
      .count();
}

static int64_t realtime_ns() {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static pid_t tid() { return (pid_t)syscall(SYS_gettid); }

static void setname(const char* name) {
  pthread_setname_np(pthread_self(), name);
}

// LCG burn: deterministic, unpredictable to the compiler, no syscalls, no alloc.
static void burn(int64_t dur_ns, uint64_t seed) {
  const int64_t end = now_ns() + dur_ns;
  uint64_t x = seed | 1u;
  do {
    for (int i = 0; i < 4096; ++i) {
      x = x * 6364136223846793005ULL + 1442695040888963407ULL;
      x ^= x >> 33;
    }
  } while (now_ns() < end);
  g_sink.fetch_add(x, std::memory_order_relaxed);
}

int main(int argc, char** argv) {
  const int64_t total_ms = argc > 1 ? atoll(argv[1]) : 30000;
  const int64_t period_ms = argc > 2 ? atoll(argv[2]) : 3000;
  const int64_t burn_ms = argc > 3 ? atoll(argv[3]) : 300;

  printf("fixture pid=%d total_ms=%lld period_ms=%lld burn_ms=%lld\n",
         (int)getpid(), (long long)total_ms, (long long)period_ms,
         (long long)burn_ms);
  fflush(stdout);

  const int64_t t0 = now_ns();

  std::thread spike([&] {
    setname("spike-worker");
    printf("thread_start name=spike-worker tid=%d\n", (int)tid());
    fflush(stdout);
    int idx = 0;
    while (!g_stop.load(std::memory_order_relaxed)) {
      const int64_t due = t0 + (int64_t)(idx + 1) * period_ms * 1000000LL;
      const int64_t sleep_ns = due - now_ns();
      if (sleep_ns > 0) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(sleep_ns));
      }
      if (g_stop.load(std::memory_order_relaxed)) break;
      const int64_t s = now_ns();
      printf("EVENT tick_start idx=%d mono_ns=%lld real_ns=%lld tid=%d\n", idx,
             (long long)s, (long long)realtime_ns(), (int)tid());
      fflush(stdout);
      burn(burn_ms * 1000000LL, (uint64_t)s);
      const int64_t e = now_ns();
      printf("EVENT tick_end   idx=%d mono_ns=%lld real_ns=%lld tid=%d dur_ms=%.3f\n",
             idx, (long long)e, (long long)realtime_ns(), (int)tid(),
             (e - s) / 1e6);
      fflush(stdout);
      ++idx;
    }
  });

  std::thread light([&] {
    setname("bg-light");
    printf("thread_start name=bg-light tid=%d\n", (int)tid());
    fflush(stdout);
    while (!g_stop.load(std::memory_order_relaxed)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      if (g_stop.load(std::memory_order_relaxed)) break;
      burn(3 * 1000000LL, 0x9e3779b97f4a7c15ULL);
    }
  });

  // main: sleep only (it must show no meaningful CPU in the trace)
  std::this_thread::sleep_for(std::chrono::milliseconds(total_ms));
  g_stop.store(true);
  spike.join();
  light.join();

  printf("fixture done mono_ns=%lld sink=%llu\n", (long long)now_ns(),
         (unsigned long long)g_sink.load());
  return 0;
}
