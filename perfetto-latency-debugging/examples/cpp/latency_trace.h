#pragma once
// Original minimal adapter for Perfetto C++ SDK (target baseline v58.2).
// Explicit Track lifetimes may cross threads; Stage defaults are thread-scoped.
#include "perfetto.h"
#include <atomic>
#include <cstdint>
#include <string>
#include <utility>

PERFETTO_DEFINE_CATEGORIES(perfetto::Category("rdk.latency").SetDescription("Request, stage, queue and handoff latency"));

namespace latency {
struct Request {
  std::string run_id, stream_id, request_id, process_instance_id;
  uint64_t frame_seq=0;
  uint64_t request_track=0, queue_track=0, edge_id=0;
  std::string queue_id, queue_visit_id, from_instance="input", to_instance;
  uint64_t stage_count=0, queue_count=0, link_count=0;
  uint64_t input_ts=0;
};
uint64_t NextId();
void Fields(perfetto::EventContext& ctx,const Request& r);
void StringField(perfetto::EventContext& ctx,const char* name,const std::string& value);
void IntField(perfetto::EventContext& ctx,const char* name,uint64_t value);
void BeginRequest(Request& r);
void EndRequest(Request& r,const char* status);
void BeginQueue(Request& r,const char* queue,const char* destination);
void EndQueue(Request& r);
void Send(Request& r);
void Receive(Request& r);
void QueueDepth(const char* queue,int64_t value);
class Stage {
 public:
  Stage(Request& r,const char* stage,std::string instance,uint64_t attempt=1);
  ~Stage();
  void Outcome(const char* status) { status_=status; }
  Stage(const Stage&)=delete;
  Stage& operator=(const Stage&)=delete;
 private:
  Request& r_;const char* stage_;std::string instance_;uint64_t attempt_;const char* status_="SUCCESS";
};
}  // namespace latency
