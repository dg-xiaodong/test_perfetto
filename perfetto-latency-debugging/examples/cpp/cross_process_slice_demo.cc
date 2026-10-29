// SPDX-License-Identifier: Apache-2.0
// Perfetto SDK v58.2 System Backend smoke test, NOT a latency.v1 pipeline.
// Two INDEPENDENT processes use one Global Track ID: one BEGIN, one END.
// Use a fresh sync directory; the marker files order events, not correlate IDs.
#include "perfetto.h"
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <unistd.h>

PERFETTO_DEFINE_CATEGORIES(
    perfetto::Category("rdk.latency").SetDescription("Latency cross-process demonstration"));
PERFETTO_TRACK_EVENT_STATIC_STORAGE();

namespace {
using Clock = std::chrono::steady_clock;
namespace fs = std::filesystem;

void WaitForFile(const fs::path& p, std::chrono::seconds timeout) {
  const auto deadline = Clock::now() + timeout;
  while (!fs::exists(p) && Clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  if (!fs::exists(p)) throw std::runtime_error("HANDSHAKE_TIMEOUT: " + p.string());
}

void WaitForCategory() {
  const auto deadline = Clock::now() + std::chrono::seconds(30);
  while (!TRACE_EVENT_CATEGORY_ENABLED("rdk.latency") && Clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  if (!TRACE_EVENT_CATEGORY_ENABLED("rdk.latency"))
    throw std::runtime_error("CATEGORY_NOT_ENABLED: both producers need one system tracing session");
}

void Mark(const fs::path& p) {
  std::ofstream out(p, std::ios::out | std::ios::trunc);
  if (!out) throw std::runtime_error("CANNOT_WRITE_MARKER: " + p.string());
  out << "ok\n";
  out.flush();
  if (!out) throw std::runtime_error("MARKER_WRITE_FAILED: " + p.string());
}
}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 5) {
      std::cerr << "Usage: latency_xproc_demo begin|end|end-omit GLOBAL_UUID SYNC_DIR REQUEST_ID\n";
      return 2;
    }
    const std::string role = argv[1];
    if (role != "begin" && role != "end" && role != "end-omit")
      throw std::invalid_argument("role must be begin/end/end-omit");
    const std::string input_id = argv[2];
    size_t parsed = 0;
    const uint64_t uuid = std::stoull(input_id, &parsed, 0);
    if (parsed != input_id.size() || uuid == 0)
      throw std::invalid_argument("GLOBAL_UUID must be nonzero, valid uint64");
    const fs::path dir(argv[3]);
    const std::string request = argv[4];
    if (!fs::is_directory(dir) || request.empty() || request.size() > 100)
      throw std::invalid_argument("sync directory must exist and request ID must be bounded");
    const auto begin_sent = dir / "begin.sent";
    const auto end_sent = dir / "end.sent";
    // A new sync directory is required per capture; the two roles can start in either order.
    if ((role == "begin" && fs::exists(begin_sent)) ||
        (role != "begin" && fs::exists(end_sent)))
      throw std::runtime_error("STALE_MARKER: use a fresh sync directory");

    perfetto::TracingInitArgs init;
    init.backends = perfetto::kSystemBackend;
    perfetto::Tracing::Initialize(init);
    perfetto::TrackEvent::Register();
    WaitForCategory();

    const auto tr = perfetto::Track::Global(uuid);
    if (role == "begin") {
      TRACE_EVENT_BEGIN("rdk.latency", "xproc.global_track.demo", tr,
                        "request_id", request.c_str());
      perfetto::TrackEvent::Flush();
      Mark(begin_sent);
      WaitForFile(end_sent, std::chrono::seconds(10));
    } else {
      WaitForFile(begin_sent, std::chrono::seconds(10));
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      if (role == "end")
        TRACE_EVENT_END("rdk.latency", tr, "request_id", request.c_str());
      // end-omit intentionally omits END as a negative/censored test.
      perfetto::TrackEvent::Flush();
      Mark(end_sent);
    }
    perfetto::TrackEvent::Flush();
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    std::cerr << "XPROC_DEMO role=" << role << " pid=" << ::getpid()
              << " uuid=" << uuid << " request=" << request << " status=emitted\n";
    return 0;
  } catch (const std::exception& ex) {
    std::cerr << "XPROC_DEMO_FAIL " << ex.what() << '\n';
    return 3;
  }
}
