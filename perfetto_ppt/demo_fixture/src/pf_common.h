// SPDX-License-Identifier: Apache-2.0
// pf-demo-x5 — shared primitives: clocks, logging, bounded queues, threads.
//
// This file is part of the Perfetto training fixture. Everything here is a
// deliberately small, dependency-free re-implementation of what the demo
// needs, so the whole program can be cross-compiled for RDK X5 with nothing
// but a C++17 toolchain.
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <deque>
#include <mutex>
#include <string>
#include <utility>

#include <pthread.h>
#include <sched.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace pfdemo {

// ---------------------------------------------------------------------------
// Test-cycle phases. One cycle = kPhaseCount * phase_seconds (48 s by default).
// The names are what the trace and the logs use; keep them stable because the
// ground-truth document and window B's analysis refer to them.
// ---------------------------------------------------------------------------
constexpr int kPhaseCount = 6;

enum class Phase : int {
  kBaseline = 0,
  kCpuBurst = 1,
  kSchedContention = 2,
  kMemoryPulse = 3,
  kSyncIo = 4,
  kMixedPipeline = 5,
};

constexpr const char* kPhaseNames[kPhaseCount] = {
    "BASELINE",       "CPU_BURST",     "SCHED_CONTENTION",
    "MEMORY_PULSE",   "SYNC_IO",       "MIXED_PIPELINE",
};

inline const char* PhaseName(Phase p) {
  const int i = static_cast<int>(p);
  return kPhaseNames[(i >= 0 && i < kPhaseCount) ? i : 0];
}

// ---------------------------------------------------------------------------
// Clocks. Perfetto traces on Linux use CLOCK_BOOTTIME timestamps by default,
// while CLOCK_MONOTONIC is what the program uses internally. Both are logged
// for every phase change / frame / monitor sample so that the ground truth can
// be aligned with the trace without guessing.
// ---------------------------------------------------------------------------
inline int64_t ClockNs(clockid_t clk) {
  timespec ts{};
  clock_gettime(clk, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}
inline int64_t MonoNs() {
  return ClockNs(CLOCK_MONOTONIC);
}
inline int64_t BootNs() {
  return ClockNs(CLOCK_BOOTTIME);
}
inline int64_t RealtimeNs() {
  return ClockNs(CLOCK_REALTIME);
}

inline void SleepNs(int64_t ns) {
  timespec ts{};
  ts.tv_sec = static_cast<time_t>(ns / 1000000000LL);
  ts.tv_nsec = static_cast<long>(ns % 1000000000LL);
  clock_nanosleep(CLOCK_MONOTONIC, 0, &ts, nullptr);
}
inline void SleepMs(int ms) {
  SleepNs(static_cast<int64_t>(ms) * 1000000LL);
}
// Absolute monotonic sleep: does not drift when the caller wakes up late.
inline void SleepUntilMonoNs(int64_t deadline_ns) {
  timespec ts{};
  ts.tv_sec = static_cast<time_t>(deadline_ns / 1000000000LL);
  ts.tv_nsec = static_cast<long>(deadline_ns % 1000000000LL);
  clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, nullptr);
}

// ---------------------------------------------------------------------------
// Thread helpers. Linux comm is limited to 15 characters + NUL, so all names
// below are <= 15 chars and are what /proc/<pid>/task/<tid>/comm shows.
// ---------------------------------------------------------------------------
inline void SetThreadName(const char* name) {
  pthread_setname_np(pthread_self(), name);
}
inline void PinToCpu(int cpu) {
  if (cpu < 0) {
    return;
  }
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  sched_setaffinity(0, sizeof(set), &set);
}
inline int CurrentTid() {
  return static_cast<int>(syscall(SYS_gettid));
}

// ---------------------------------------------------------------------------
// Bounded queue.
//
// Every pipeline hand-off goes through one of these. Two condition variables
// mean a full queue makes the producer genuinely block (futex sleep), which is
// exactly the behaviour the scheduling/latency pages need to show. Queues are
// hard-bounded so the program can run for days without growing memory.
// ---------------------------------------------------------------------------
template <typename T>
class BoundedQueue {
 public:
  explicit BoundedQueue(size_t capacity) : capacity_(capacity) {}

  // Pushes |value|. Returns false if |stop| was set while waiting for space.
  // |blocked_ns| receives how long the producer had to wait for space.
  bool Push(T value, const std::atomic<bool>& stop, int64_t* blocked_ns) {
    const int64_t start = MonoNs();
    std::unique_lock<std::mutex> lock(mutex_);
    while (queue_.size() >= capacity_ && !stop.load()) {
      not_full_.wait_for(lock, std::chrono::milliseconds(50));
    }
    if (blocked_ns) {
      *blocked_ns = MonoNs() - start;
    }
    if (stop.load() && queue_.size() >= capacity_) {
      return false;
    }
    queue_.push_back(std::move(value));
    not_empty_.notify_one();
    return true;
  }

  // Pops a value. Returns false when |stop| was set and the queue drained.
  // |blocked_ns| receives how long the consumer waited for data.
  bool Pop(T* out, const std::atomic<bool>& stop, int64_t* blocked_ns) {
    const int64_t start = MonoNs();
    std::unique_lock<std::mutex> lock(mutex_);
    while (queue_.empty() && !stop.load()) {
      not_empty_.wait_for(lock, std::chrono::milliseconds(50));
    }
    if (blocked_ns) {
      *blocked_ns = MonoNs() - start;
    }
    if (queue_.empty()) {
      return false;
    }
    *out = std::move(queue_.front());
    queue_.pop_front();
    not_full_.notify_one();
    return true;
  }

  size_t size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return queue_.size();
  }

  void WakeAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    not_empty_.notify_all();
    not_full_.notify_all();
  }

 private:
  mutable std::mutex mutex_;
  std::condition_variable not_empty_;
  std::condition_variable not_full_;
  std::deque<T> queue_;
  const size_t capacity_;
};

// ---------------------------------------------------------------------------
// Rotating text log. Writers are multi-threaded; each line is written under a
// mutex. The file is capped and rotated once so a multi-day run cannot fill
// the persistent partition.
// ---------------------------------------------------------------------------
class RotatingLog {
 public:
  RotatingLog() = default;
  ~RotatingLog() { Close(); }

  bool Open(const std::string& path, size_t max_bytes) {
    std::lock_guard<std::mutex> lock(mutex_);
    path_ = path;
    max_bytes_ = max_bytes;
    file_ = fopen(path.c_str(), "a");
    if (!file_) {
      return false;
    }
    written_ = static_cast<size_t>(ftell(file_));
    return true;
  }

  void Write(const char* fmt, ...) __attribute__((format(printf, 2, 3))) {
    char line[1024];
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    if (n <= 0) {
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!file_) {
      return;
    }
    if (n > static_cast<int>(sizeof(line)) - 1) {
      n = static_cast<int>(sizeof(line)) - 1;
    }
    fwrite(line, 1, static_cast<size_t>(n), file_);
    fputc('\n', file_);
    written_ += static_cast<size_t>(n) + 1;
    if (written_ >= max_bytes_) {
      RotateLocked();
    }
  }

  void Flush() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (file_) {
      fflush(file_);
    }
  }

  void Close() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (file_) {
      fclose(file_);
      file_ = nullptr;
    }
  }

 private:
  void RotateLocked() {
    if (!file_) {
      return;
    }
    fclose(file_);
    file_ = nullptr;
    const std::string old_path = path_ + ".1";
    remove(old_path.c_str());
    rename(path_.c_str(), old_path.c_str());
    file_ = fopen(path_.c_str(), "a");
    written_ = 0;
    if (file_) {
      // Restart the rotated-away file with a marker so readers know why the
      // sequence jumps.
      const char* marker = "LOG_ROTATED\n";
      fwrite(marker, 1, strlen(marker), file_);
      written_ = strlen(marker);
    }
  }

  std::mutex mutex_;
  FILE* file_ = nullptr;
  std::string path_;
  size_t max_bytes_ = 8u * 1024u * 1024u;
  size_t written_ = 0;
};

}  // namespace pfdemo
