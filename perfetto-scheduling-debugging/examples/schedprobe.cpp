// Bounded ground-truth helper, not a production workload or an on-board claim.
// c1: condition variable; c2: same-CPU competition; c3: cross-process futex wake.
// Usage: schedprobe c1|c2|c3 [start_delay_ms=3000] [hold_ms=100] [cycles=3]
// Source and logs are FOR THE CONSTRUCTOR. Do not show them to a blind diagnostician.
#define _GNU_SOURCE 1
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>
#include <time.h>
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
#include <linux/futex.h>

static std::atomic<unsigned long long> sink{0};
static long long ns(clockid_t c) { timespec t{}; if(clock_gettime(c,&t)) std::abort(); return static_cast<long long>(t.tv_sec)*1000000000LL+t.tv_nsec; }
static void sleep_ms(long long ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }
static void label(const char* n) { pthread_setname_np(pthread_self(),n); }
static void event(const char* e,int seq=0) {
 char b[256];const int n=snprintf(b,sizeof(b),"{\"event\":\"%s\",\"seq\":%d,\"pid\":%d,\"tid\":%ld,\"mono_ns\":%lld,\"boot_ns\":%lld,\"cpu_ns\":%lld}\n",e,seq,getpid(),syscall(SYS_gettid),ns(CLOCK_MONOTONIC),ns(CLOCK_BOOTTIME),ns(CLOCK_THREAD_CPUTIME_ID));
 if(n>0) { const ssize_t written=write(STDOUT_FILENO,b,static_cast<size_t>(n)); (void)written; }
}
extern "C" __attribute__((noinline)) void schedprobe_compute(long long duration_ns,bool cpu_budget) {
 auto clock=cpu_budget?CLOCK_THREAD_CPUTIME_ID:CLOCK_MONOTONIC;
 const auto end=ns(clock)+duration_ns;unsigned long long x=17;
 do { for(int i=0;i<1024;++i)x=x*6364136223846793005ULL+1; } while(ns(clock)<end);
 sink.fetch_add(x,std::memory_order_relaxed);
}
static int allowed_cpu() {
 cpu_set_t s;CPU_ZERO(&s);if(sched_getaffinity(0,sizeof(s),&s))return -1;
 for(int i=0;i<CPU_SETSIZE;++i)if(CPU_ISSET(i,&s))return i;
 return -1;
}
static bool pin(int cpu) { cpu_set_t s;CPU_ZERO(&s);CPU_SET(cpu,&s);return sched_setaffinity(0,sizeof(s),&s)==0; }
static int local_case(bool competition,int delay,int hold,int cycles) {
 std::mutex mu;std::condition_variable cv;int announced=0,released=0;std::atomic<int> busy_round{0};std::atomic<bool> stop{false};std::atomic<bool> failed{false};
 const int cpu=competition?allowed_cpu():-1;if(competition&&cpu<0)return 3;
 std::vector<std::thread> competitors;
 if(competition)for(int k=0;k<2;++k)competitors.emplace_back([&,k] {
   label(k?"sp-job-b":"sp-job-a");if(!pin(cpu)){failed=true;return;}event("THREAD_READY");int last=0;
   while(!stop){const int r=busy_round.load();if(r>last){last=r;schedprobe_compute(200000000LL,false);}else sleep_ms(1);}
 });
 std::thread worker([&] {
  label("sp-wait");if(competition&&!pin(cpu)){failed=true;return;}event("THREAD_READY");
  for(int i=1;i<=cycles;++i){
   std::unique_lock<std::mutex> lk(mu);announced=i;cv.notify_all();event("WAIT_BEGIN",i);
   if(!cv.wait_for(lk,std::chrono::seconds(12),[&]{return released>=i;})){failed=true;return;}
   event("WAIT_END",i);lk.unlock();
   if(competition){event("WORK_BEGIN",i);schedprobe_compute(40000000LL,true);event("WORK_END",i);}
  }
 });
 label("sp-wake");event("THREAD_READY");
 for(int i=1;i<=cycles;++i){
  {std::unique_lock<std::mutex> lk(mu);if(!cv.wait_for(lk,std::chrono::seconds(2),[&]{return announced>=i;})){failed=true;break;}}
  if(i==1)sleep_ms(delay);
  if(competition){busy_round=i;sleep_ms(30);}else sleep_ms(hold);
  {std::lock_guard<std::mutex> lk(mu);released=i;event("WAKE",i);cv.notify_all();}
  if(competition)sleep_ms(230);else sleep_ms(40);
 }
 {std::lock_guard<std::mutex> lk(mu);released=cycles;cv.notify_all();}
 worker.join();stop=true;for(auto& t:competitors)t.join();event("DONE");return failed?3:0;
}
struct Shared { alignas(4) int ready;alignas(4) int released; };
static int cross_case(int delay,int hold,int cycles) {
 auto* m=static_cast<Shared*>(mmap(nullptr,sizeof(Shared),PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANONYMOUS,-1,0));
 if(m==MAP_FAILED)return 3;
 m->ready=0;m->released=0;
 const pid_t child=fork();if(child<0){munmap(m,sizeof(Shared));return 3;}
 if(child==0){
  label("sp-wait");event("THREAD_READY");
  for(int i=1;i<=cycles;++i){
   event("WAIT_BEGIN",i);__atomic_store_n(&m->ready,i,__ATOMIC_RELEASE);
   const auto deadline=ns(CLOCK_MONOTONIC)+12000000000LL;
   while(__atomic_load_n(&m->released,__ATOMIC_ACQUIRE)<i){
    int v=__atomic_load_n(&m->released,__ATOMIC_RELAXED);timespec timeout{1,0};
    long r=syscall(SYS_futex,&m->released,FUTEX_WAIT,v,&timeout,nullptr,0);
    if(r<0&&errno!=EAGAIN&&errno!=EINTR&&errno!=ETIMEDOUT)_exit(3);
    if(ns(CLOCK_MONOTONIC)>deadline)_exit(3);
   }
   event("WAIT_END",i);
  }
  event("DONE");_exit(0);
 }
 label("sp-wake");event("THREAD_READY");bool bad=false;
 for(int i=1;i<=cycles;++i){
  auto end=ns(CLOCK_MONOTONIC)+2000000000LL;
  while(__atomic_load_n(&m->ready,__ATOMIC_ACQUIRE)<i){if(ns(CLOCK_MONOTONIC)>end){bad=true;break;}sleep_ms(1);}
  if(bad)break;
  if(i==1) sleep_ms(delay);
  sleep_ms(hold);
  event("WAKE",i);__atomic_store_n(&m->released,i,__ATOMIC_RELEASE);
  if(syscall(SYS_futex,&m->released,FUTEX_WAKE,1,nullptr,nullptr,0)<0){bad=true;break;}
 }
 if(bad){__atomic_store_n(&m->released,cycles,__ATOMIC_RELEASE);syscall(SYS_futex,&m->released,FUTEX_WAKE,1,nullptr,nullptr,0);}
 int status=0;if(waitpid(child,&status,0)!=child)bad=true;
 munmap(m,sizeof(Shared));event("DONE");return bad||!WIFEXITED(status)||WEXITSTATUS(status)?3:0;
}
static bool number(const char* s,int* v,int max) { char* e=nullptr;errno=0;long x=strtol(s,&e,10);if(errno||e==s||*e||x<0||x>max)return false;*v=static_cast<int>(x);return true; }
int main(int argc,char** argv) {
 int delay=3000,hold=100,cycles=3;
 if(argc<2||argc>5||(strcmp(argv[1],"c1")&&strcmp(argv[1],"c2")&&strcmp(argv[1],"c3"))||(argc>2&&!number(argv[2],&delay,8000))||(argc>3&&!number(argv[3],&hold,1000))||(argc>4&&!number(argv[4],&cycles,5))||hold<10||cycles<1){fprintf(stderr,"usage: schedprobe c1|c2|c3 [delay_ms 0..8000] [hold_ms 10..1000] [cycles 1..5]\n");return 2;}
 if(!strcmp(argv[1],"c3"))return cross_case(delay,hold,cycles);
 return local_case(!strcmp(argv[1],"c2"),delay,hold,cycles);
}
