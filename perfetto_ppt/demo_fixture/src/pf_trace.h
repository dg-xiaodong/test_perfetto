// SPDX-License-Identifier: Apache-2.0
// pf-demo-x5 — Perfetto SDK integration points.
//
// Uses the official Perfetto C++ SDK (TrackEvent) with the *system* backend, so
// the application's user-space slices/flows/counters land in the same trace as
// the kernel-side data sources recorded by traced/traced_probes.
//
// The SDK is compiled directly into the binary (single amalgamated
// perfetto.cc), which is the supported way to instrument a Linux C++ program.
#pragma once

#include <cstdint>
#include <cstdio>

#include "perfetto.h"

// Compile-time category registry. Window B's trace config can either enable all
// categories (default when track_event has no category filter) or name them
// explicitly:
//   pipeline  - frame stage slices + FramePipeline end-to-end spans
//   memory    - heap pulse slices
//   sync      - queue waits / condition-variable waits
//   io        - file I/O slices
//   demo      - phase changes and every counter
PERFETTO_DEFINE_CATEGORIES(perfetto::Category("pipeline"),
                           perfetto::Category("memory"),
                           perfetto::Category("sync"),
                           perfetto::Category("io"),
                           perfetto::Category("demo"));

namespace pfdemo {

// Track uuid space for the per-frame "FramePipeline" async spans. Global
// (process-independent) uuids are used because the span begins on the capture
// thread and ends on the output thread.
constexpr uint64_t kFramePipelineTrackBase = 0x70665f7069706560ULL;
constexpr int kFramePipelineTracks = 16;
constexpr uint64_t kFramePipelineSampleEvery = 8;  // frame id % 8 == 0

inline perfetto::Track FramePipelineTrack(uint64_t frame_id) {
  const uint64_t slot =
      (frame_id / kFramePipelineSampleEvery) % kFramePipelineTracks;
  return perfetto::Track::Global(kFramePipelineTrackBase + slot);
}

// Initialises the SDK against the system tracing service. Safe to call when no
// tracing session is active: events are dropped cheaply until a session starts.
inline void PerfettoInit() {
  perfetto::TracingInitArgs args;
  args.backends = perfetto::kSystemBackend;
  args.shmem_size_hint_kb = 2048;
  perfetto::Tracing::Initialize(args);
  perfetto::TrackEvent::Register();
}

inline void PerfettoSetProcessName(const char* name) {
  auto track = perfetto::ProcessTrack::Current();
  auto desc = track.Serialize();
  desc.set_name(name);
  desc.mutable_process()->set_process_name(name);
  perfetto::TrackEvent::SetTrackDescriptor(track, desc);
}

// Names the calling thread's Perfetto track. The OS comm is set separately via
// pthread_setname_np(); doing both keeps the trace self-describing even if no
// process_stats data source is enabled.
inline void PerfettoSetCurrentThreadName(const char* name) {
  auto track = perfetto::ThreadTrack::Current();
  auto desc = track.Serialize();
  desc.set_name(name);
  desc.mutable_thread()->set_thread_name(name);
  perfetto::TrackEvent::SetTrackDescriptor(track, desc);
}

inline void PerfettoInitFramePipelineTracks() {
  for (int i = 0; i < kFramePipelineTracks; ++i) {
    auto track = perfetto::Track::Global(kFramePipelineTrackBase + i);
    auto desc = track.Serialize();
    char name[64];
    snprintf(name, sizeof(name), "FramePipeline/%02d", i);
    desc.set_name(name);
    perfetto::TrackEvent::SetTrackDescriptor(track, desc);
  }
}

// ---------------------------------------------------------------------------
// Counter tracks. Names are string literals so the "must outlive" contract of
// CounterTrack is trivially satisfied.
// ---------------------------------------------------------------------------
inline const perfetto::CounterTrack& QueueDepthTrack() {
  static const perfetto::CounterTrack t("QueueDepth", "frames");
  return t;
}
inline const perfetto::CounterTrack& InflightFramesTrack() {
  static const perfetto::CounterTrack t("InflightFrames", "frames");
  return t;
}
inline const perfetto::CounterTrack& CompletedFramesTrack() {
  static const perfetto::CounterTrack t("CompletedFrames", "frames");
  return t;
}
inline const perfetto::CounterTrack& EndToEndLatencyTrack() {
  static const perfetto::CounterTrack t("EndToEndLatencyMs", "ms");
  return t;
}
inline const perfetto::CounterTrack& LiveAllocatedBytesTrack() {
  static const perfetto::CounterTrack t("LiveAllocatedBytes", "bytes");
  return t;
}

// Extra, real-sampled counters. They are not part of the required list but make
// the memory / scheduling pages of the training deck readable without ftrace.
inline const perfetto::CounterTrack& RssKbTrack() {
  static const perfetto::CounterTrack t("RssKb", "kB");
  return t;
}
inline const perfetto::CounterTrack& ThreadsRunningTrack() {
  static const perfetto::CounterTrack t("ThreadsRunning", "threads");
  return t;
}
inline const perfetto::CounterTrack& ThreadsBlockedTrack() {
  static const perfetto::CounterTrack t("ThreadsBlocked", "threads");
  return t;
}
inline const perfetto::CounterTrack& WakeupOvershootTrack() {
  static const perfetto::CounterTrack t("SchedWakeupOvershootMs", "ms");
  return t;
}
inline const perfetto::CounterTrack& IoFileBytesTrack() {
  static const perfetto::CounterTrack t("IoFileBytes", "bytes");
  return t;
}
inline const perfetto::CounterTrack& CpuPctInferTrack() {
  static const perfetto::CounterTrack t("cpu.pf-infer", "pct");
  return t;
}
inline const perfetto::CounterTrack& CpuPctContend1Track() {
  static const perfetto::CounterTrack t("cpu.pf-contend1", "pct");
  return t;
}
inline const perfetto::CounterTrack& CpuPctContend2Track() {
  static const perfetto::CounterTrack t("cpu.pf-contend2", "pct");
  return t;
}

inline void EmitCounter(const perfetto::CounterTrack& track, double value) {
  TRACE_COUNTER("demo", track, value);
}

}  // namespace pfdemo
