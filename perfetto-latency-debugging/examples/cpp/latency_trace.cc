#include "latency_trace.h"
#include <stdexcept>
PERFETTO_TRACK_EVENT_STATIC_STORAGE();

namespace latency {
uint64_t NextId() {
  static std::atomic<uint64_t> counter{1};
  auto n=counter.fetch_add(1,std::memory_order_relaxed);
  if(n>=0x0000ffffffffffffULL) throw std::overflow_error("trace id exhausted");
  // IDs share one allocator within this process. Perfetto Track/ProcessScoped
  // incorporates process scoping; do not use these values directly across hosts.
  return 0x4c41000000000000ULL+n;
}
void StringField(perfetto::EventContext& ctx,const char* name,const std::string& value) {
  auto* a=ctx.event()->add_debug_annotations();a->set_name(name);a->set_string_value(value);
}
void IntField(perfetto::EventContext& ctx,const char* name,uint64_t value) {
  auto* a=ctx.event()->add_debug_annotations();a->set_name(name);a->set_uint_value(value);
}
void Fields(perfetto::EventContext& ctx,const Request& r) {
  StringField(ctx,"contract_version","latency.v1");
  StringField(ctx,"run_id",r.run_id);StringField(ctx,"stream_id",r.stream_id);
  StringField(ctx,"request_id",r.request_id);StringField(ctx,"process_instance_id",r.process_instance_id);
  StringField(ctx,"object_type","frame");IntField(ctx,"frame_seq",r.frame_seq);
}
void BeginRequest(Request& r) {
  r.request_track=NextId();r.input_ts=perfetto::TrackEvent::GetTraceTimeNs();
  perfetto::Track track(r.request_track);
  auto d=track.Serialize();d.set_name("Request lifecycle");perfetto::TrackEvent::SetTrackDescriptor(track,d);
  TRACE_EVENT_INSTANT("rdk.latency","lat.request.begin",[&](perfetto::EventContext ctx){Fields(ctx,r);});
  TRACE_EVENT_BEGIN("rdk.latency","lat.request",track,[&](perfetto::EventContext ctx){Fields(ctx,r);});
}
void EndRequest(Request& r,const char* status) {
  // END uses the SAME explicit track, even when called by another worker.
  perfetto::Track track(r.request_track);
  TRACE_EVENT_END("rdk.latency",track);
  TRACE_EVENT_INSTANT("rdk.latency","lat.request.end",[&](perfetto::EventContext ctx){
    Fields(ctx,r);StringField(ctx,"status",status);
    IntField(ctx,"expected_stage_count",r.stage_count);
    IntField(ctx,"expected_queue_count",r.queue_count);
    IntField(ctx,"expected_link_count",r.link_count);
  });
  perfetto::TrackEvent::EraseTrackDescriptor(track);
}
void Send(Request& r) {
  ++r.link_count;
  TRACE_EVENT_INSTANT("rdk.latency","lat.send",perfetto::Flow::ProcessScoped(r.edge_id),[&](perfetto::EventContext ctx){
    Fields(ctx,r);StringField(ctx,"link_id",std::to_string(r.edge_id));StringField(ctx,"flow_scope","process");
    StringField(ctx,"from_instance",r.from_instance);StringField(ctx,"to_instance",r.to_instance);
  });
}
void Receive(Request& r) {
  TRACE_EVENT_INSTANT("rdk.latency","lat.receive",perfetto::TerminatingFlow::ProcessScoped(r.edge_id),[&](perfetto::EventContext ctx){
    Fields(ctx,r);StringField(ctx,"link_id",std::to_string(r.edge_id));StringField(ctx,"flow_scope","process");
    StringField(ctx,"from_instance",r.from_instance);StringField(ctx,"to_instance",r.to_instance);
  });
}
void BeginQueue(Request& r,const char* queue,const char* destination) {
  r.queue_track=NextId();r.edge_id=NextId();r.queue_id=queue;r.queue_visit_id=std::to_string(r.queue_track);r.to_instance=destination;
  ++r.queue_count;
  perfetto::Track tr(r.queue_track);auto d=tr.Serialize();d.set_name(queue);perfetto::TrackEvent::SetTrackDescriptor(tr,d);
  TRACE_EVENT_BEGIN("rdk.latency","lat.queue",tr,[&](perfetto::EventContext ctx){
    Fields(ctx,r);StringField(ctx,"queue_id",r.queue_id);StringField(ctx,"queue_visit_id",r.queue_visit_id);
  });
  Send(r);
}
void EndQueue(Request& r) {
  perfetto::Track tr(r.queue_track);TRACE_EVENT_END("rdk.latency",tr);
  Receive(r);perfetto::TrackEvent::EraseTrackDescriptor(tr);
}
void QueueDepth(const char* queue,int64_t value) {
  // Three constant counter names; never generate one name per request.
  if(std::string(queue)=="pre") {TRACE_COUNTER("rdk.latency","lat.queue_depth.pre",value);}
  else if(std::string(queue)=="infer") {TRACE_COUNTER("rdk.latency","lat.queue_depth.infer",value);}
  else {TRACE_COUNTER("rdk.latency","lat.queue_depth.post",value);}
}
Stage::Stage(Request& r,const char* stage,std::string instance,uint64_t attempt)
 :r_(r),stage_(stage),instance_(std::move(instance)),attempt_(attempt) {
  ++r_.stage_count;
  TRACE_EVENT_BEGIN("rdk.latency","lat.stage",[&](perfetto::EventContext ctx){
    Fields(ctx,r_);StringField(ctx,"stage_id",stage_);StringField(ctx,"stage_instance_id",instance_);
    IntField(ctx,"attempt_id",attempt_);
  });
}
Stage::~Stage() {
  TRACE_EVENT_END("rdk.latency");
  TRACE_EVENT_INSTANT("rdk.latency","lat.stage.result",[&](perfetto::EventContext ctx){
    Fields(ctx,r_);StringField(ctx,"stage_id",stage_);StringField(ctx,"stage_instance_id",instance_);
    IntField(ctx,"attempt_id",attempt_);StringField(ctx,"status",status_);
  });
  r_.from_instance=instance_;
}
}  // namespace latency
