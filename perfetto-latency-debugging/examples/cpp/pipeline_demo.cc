// Bounded three-worker application; not a sensor, daemon or auto-start installer.
// Primary correctness evidence comes from real TrackEvent output after SDK build.
#include "latency_trace.h"
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <deque>
#include <fcntl.h>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>
#include <unistd.h>

using namespace std::chrono;
static std::atomic<bool> stopped{false};
static_assert(std::atomic<bool>::is_always_lock_free, "signal stop flag must be lock-free");
static void Signal(int){stopped=1;}
static std::mutex output_mu;
static std::atomic<uint64_t> sink{0};
static std::atomic<unsigned> completed{0};
static std::atomic<bool> worker_failed{false};

struct Task { latency::Request trace; unsigned index=0; };
class Queue {
 public:
  Queue(const char* name,const char* dest):name_(name),dest_(dest){}
  bool Push(std::shared_ptr<Task> t) {
    std::unique_lock<std::mutex> l(m_);
    while(q_.size()>=16&&!closed_&&!stopped) cv_.wait_for(l,milliseconds(20));
    if(closed_||stopped)return false;
    latency::BeginQueue(t->trace,name_,dest_);q_.push_back(std::move(t));
    latency::QueueDepth(name_,static_cast<int64_t>(q_.size()));cv_.notify_all();return true;
  }
  std::shared_ptr<Task> Pop() {
    std::unique_lock<std::mutex> l(m_);
    while(q_.empty()&&!closed_&&!stopped)cv_.wait_for(l,milliseconds(20));
    if(q_.empty()||stopped)return {};
    auto t=q_.front();q_.pop_front();latency::EndQueue(t->trace);
    latency::QueueDepth(name_,static_cast<int64_t>(q_.size()));cv_.notify_all();return t;
  }
  void Close(){std::lock_guard<std::mutex> l(m_);closed_=true;cv_.notify_all();}
 private:
  const char* name_;const char* dest_;std::mutex m_;std::condition_variable cv_;
  std::deque<std::shared_ptr<Task>> q_;bool closed_=false;
};

__attribute__((noinline)) static void Compute(unsigned micros) {
  TRACE_EVENT("rdk.latency","compute_kernel");
  auto end=steady_clock::now()+microseconds(micros);uint64_t x=1;
  while(!stopped&&steady_clock::now()<end){for(unsigned i=0;i<128;i++) x=(x^(x<<7))+0x9e3779b97f4a7c15ULL;}
  sink.fetch_xor(x,std::memory_order_relaxed);
}
static void Finish(std::shared_ptr<Task> t,const char* status,int omit_terminal) {
  uint64_t now=perfetto::TrackEvent::GetTraceTimeNs();
  if(static_cast<int>(t->index)!=omit_terminal) latency::EndRequest(t->trace,status);
  // Independent instrumentation-accounting log for the test operator, NOT a log-conversion entry.
  std::lock_guard<std::mutex> l(output_mu);
  std::cout<<"{\"run_id\":\""<<t->trace.run_id<<"\",\"stream_id\":\""<<t->trace.stream_id
           <<"\",\"request_id\":\""<<t->trace.request_id<<"\",\"status\":\""<<status
           <<"\",\"stages\":"<<t->trace.stage_count<<",\"queues\":"<<t->trace.queue_count
           <<",\"links\":"<<t->trace.link_count<<",\"wall_ns\":"<<(now-t->trace.input_ts)<<"}\n";
  ++completed;
}
static unsigned Number(const std::string& s,unsigned maximum) {
  if(s.empty()||s.find_first_not_of("0123456789")!=std::string::npos)throw std::invalid_argument("numeric argument required");
  auto v=std::stoull(s);if(v>maximum)throw std::out_of_range("argument outside bounded range");return static_cast<unsigned>(v);
}
int main(int argc,char** argv) {
  std::string backend="inprocess",output,run_id;unsigned frames=24,interval=33,wait_ms=30000;int omit=-1;
  try {
    for(int i=1;i<argc;i++) {
      std::string a=argv[i];
      if(a=="--help") {std::cout<<"--backend inprocess|system|off --output NEW.pftrace --run-id ID --frames 1..300 --interval-ms 0..100 --wait-ms 100..60000 --omit-terminal INDEX\n";return 0;}
      if(i+1==argc)throw std::invalid_argument("missing option value");
      std::string v=argv[++i];
      if(a=="--backend")backend=v;else if(a=="--output")output=v;else if(a=="--run-id")run_id=v;
      else if(a=="--frames")frames=Number(v,300);else if(a=="--interval-ms")interval=Number(v,100);
      else if(a=="--wait-ms")wait_ms=Number(v,60000);else if(a=="--omit-terminal")omit=static_cast<int>(Number(v,299));
      else throw std::invalid_argument("unknown option: "+a);
    }
    if(frames==0||wait_ms<100||(backend!="off"&&backend!="system"&&backend!="inprocess"))throw std::invalid_argument("invalid backend/bounds");
    if(backend=="inprocess"&&output.empty())throw std::invalid_argument("inprocess requires --output NEW.pftrace");
    if(run_id.empty())run_id="run-"+std::to_string(::getpid())+"-"+std::to_string(steady_clock::now().time_since_epoch().count());
    if(run_id.size()>120||run_id.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")!=std::string::npos)throw std::invalid_argument("run-id must be a safe nonempty token");
    std::signal(SIGTERM,Signal);std::signal(SIGINT,Signal);
    int out_fd=-1;
    if(backend=="inprocess") {out_fd=open(output.c_str(),O_WRONLY|O_CREAT|O_EXCL,0600);if(out_fd<0)throw std::runtime_error("output exists or cannot be created");}
    perfetto::TracingInitArgs args;args.backends=backend=="system"?perfetto::kSystemBackend:perfetto::kInProcessBackend;
    perfetto::Tracing::Initialize(args);perfetto::TrackEvent::Register();
    std::unique_ptr<perfetto::TracingSession> session;
    if(backend=="inprocess") {
      perfetto::TraceConfig cfg;cfg.add_buffers()->set_size_kb(8192);
      auto* ds=cfg.add_data_sources()->mutable_config();ds->set_name("track_event");
      perfetto::protos::gen::TrackEventConfig te;te.add_disabled_categories("*");te.add_enabled_categories("rdk.latency");
      ds->set_track_event_config_raw(te.SerializeAsString());
      session=perfetto::Tracing::NewTrace(perfetto::kInProcessBackend);session->Setup(cfg);session->StartBlocking();
    }
    if(backend!="off") {
      auto deadline=steady_clock::now()+milliseconds(wait_ms);
      while(!TRACE_EVENT_CATEGORY_ENABLED("rdk.latency")&&!stopped&&steady_clock::now()<deadline)std::this_thread::sleep_for(milliseconds(10));
      if(!TRACE_EVENT_CATEGORY_ENABLED("rdk.latency")) {if(out_fd>=0)close(out_fd);throw std::runtime_error("CATEGORY_NOT_ENABLED: SDK producer/socket/category/start readiness not established");}
    }
    Queue pre("pre","pre-1"),infer("infer","infer-1"),post("post","post-1");
    auto guard=[&](auto body) {try {body();} catch(const std::exception& e){worker_failed=true;stopped=1;std::lock_guard<std::mutex> l(output_mu);std::cerr<<"WORKER_FAILED: "<<e.what()<<'\n';}};
    struct ThreadGroup {
      Queue& pre;Queue& infer;Queue& post;std::vector<std::thread> threads;
      ~ThreadGroup(){
        bool pending=false;for(auto& t:threads)pending=pending||t.joinable();
        if(pending){stopped=1;pre.Close();infer.Close();post.Close();for(auto& t:threads)if(t.joinable())t.join();}
      }
    } group{pre,infer,post,{}};
    group.threads.emplace_back([&]{guard([&]{
      while(auto t=pre.Pop()) {
        {latency::Stage s(t->trace,"preprocess","pre-1");Compute(500);}
        if(t->index%11==10) {Finish(t,"DROP",omit);continue;}
        if(!infer.Push(t)){Finish(t,"CANCELLED",omit);break;}
      } infer.Close();
    });infer.Close();});
    group.threads.emplace_back([&]{guard([&]{
      while(auto t=infer.Pop()) {
        bool retry=t->index%7==6;
        {latency::Stage s(t->trace,"inference","infer-1",1);Compute(1000);if(retry)s.Outcome("ERROR");
          if(t->index%5==4)std::this_thread::sleep_for(milliseconds(25));}
        if(retry) {
          t->trace.edge_id=latency::NextId();t->trace.to_instance="infer-2";latency::Send(t->trace);latency::Receive(t->trace);
          {latency::Stage s(t->trace,"inference","infer-2",2);Compute(500);}
        }
        if(t->index%13==12){Finish(t,"TIMEOUT",omit);continue;}
        if(!post.Push(t)){Finish(t,"CANCELLED",omit);break;}
      } post.Close();
    });post.Close();});
    group.threads.emplace_back([&]{guard([&]{while(auto t=post.Pop()){
      {latency::Stage s(t->trace,"postprocess","post-1");Compute(300);}
      Finish(t,"SUCCESS",omit);
    }});});
    auto start=steady_clock::now();unsigned sent=0;
    for(unsigned i=0;i<frames&&!stopped;i++) {
      // Avoid backfill bursts: schedule the next input after actual progress.
      if(i)std::this_thread::sleep_for(milliseconds(interval));
      auto t=std::make_shared<Task>();t->index=i;t->trace.run_id=run_id;t->trace.stream_id="camera-"+std::to_string(i%2);
      t->trace.frame_seq=i/2;t->trace.request_id=std::to_string(i/2);
      t->trace.process_instance_id=std::to_string(getpid())+"-"+std::to_string(start.time_since_epoch().count());
      latency::BeginRequest(t->trace);if(!pre.Push(t)){Finish(t,"CANCELLED",omit);break;}++sent;
    }
    pre.Close();for(auto& t:group.threads)t.join();
    perfetto::TrackEvent::Flush();
    if(session) {
      session->StopBlocking();auto bytes=session->ReadTraceBlocking();
      size_t offset=0;
      while(offset<bytes.size()) {ssize_t n=write(out_fd,bytes.data()+offset,bytes.size()-offset);if(n<0&&errno==EINTR)continue;if(n<=0){close(out_fd);throw std::runtime_error("trace write failed");}offset+=static_cast<size_t>(n);}
      if(close(out_fd)!=0)throw std::runtime_error("trace close failed");
      if(bytes.empty())throw std::runtime_error("EMPTY_TRACE");
    }
    std::cerr<<"SUMMARY sent="<<sent<<" completed="<<completed<<" stopped="<<stopped<<" worker_failed="<<worker_failed<<'\n';
    return (stopped||worker_failed)?3:0;
  } catch(const std::exception& e) {std::cerr<<"ERROR: "<<e.what()<<'\n';return 2;}
}
