/*
 * memphase.c - independent ARM64 Linux memory-phase test workload for
 * perfetto-memory-debugging v1.0.2 second X5 board validation.
 *
 * Scenario (single process, single thread):
 *   baseline (5 s)
 *   Phase A : malloc(32 MiB) -> touch every page -> hold 6 s -> free -> idle 5 s
 *   Phase B : mmap(MAP_PRIVATE|MAP_ANONYMOUS, 32 MiB) -> touch every page
 *             -> hold 6 s -> munmap -> idle 5 s
 *   tail    : keep the process alive so the frozen heapprofd session script can
 *             stop/flush the trace and never hits rc=6 (target died early).
 *
 * Markers are written with CLOCK_BOOTTIME (the same clock Perfetto uses for
 * trace ts on Linux), so log lines can be aligned to the trace without any
 * heuristic. Markers are also pushed to ftrace trace_marker (best effort).
 *
 * No business process, kernel setting, or production service is touched.
 * Build: see BUILD.md.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define PHASE_BYTES   (32u * 1024u * 1024u)
#define PAGE_BYTES    4096u
#define BASELINE_S    5
#define HOLD_S        6
#define IDLE_S        5
#define TAIL_MAX_S    180
#define SAMPLE_MS     500

static int g_logfd = -1;
static int g_markfd = -1;
static int g_stdout = 1;

static int64_t boot_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

static int64_t real_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

/* One line per marker: "<boot_ns> <realtime_ns> EVENT <detail>" */
static void emit(const char *event, const char *fmt, ...)
{
    char detail[256];
    char line[512];
    va_list ap;

    detail[0] = '\0';
    if (fmt && *fmt) {
        va_start(ap, fmt);
        vsnprintf(detail, sizeof(detail), fmt, ap);
        va_end(ap);
    }
    int n = snprintf(line, sizeof(line), "%lld %lld EVENT %s %s\n",
                     (long long)boot_ns(), (long long)real_ns(),
                     event, detail);
    if (n < 0)
        return;
    if (n > (int)sizeof(line) - 1)
        n = (int)sizeof(line) - 1;
    if (g_logfd >= 0) {
        ssize_t ignored = write(g_logfd, line, (size_t)n);
        (void)ignored;
    }
    if (g_stdout >= 0) {
        ssize_t ignored = write(g_stdout, line, (size_t)n);
        (void)ignored;
    }
    if (g_markfd >= 0) {
        /* trace_marker: "MEMPHASE <event> <detail>" */
        char mark[384];
        int m = snprintf(mark, sizeof(mark), "MEMPHASE %s %s\n", event, detail);
        if (m > 0) {
            if (m > (int)sizeof(mark) - 1)
                m = (int)sizeof(mark) - 1;
            ssize_t ignored = write(g_markfd, mark, (size_t)m);
            (void)ignored;
        }
    }
}

/* VmRSS from /proc/self/status, in KiB; -1 when unavailable. */
static long rss_kib(void)
{
    char buf[4096];
    int fd = open("/proc/self/status", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0)
        return -1;
    buf[n] = '\0';
    char *p = strstr(buf, "VmRSS:");
    if (!p)
        return -1;
    return strtol(p + 6, NULL, 10);
}

static void log_rss(const char *tag)
{
    emit("RSS_SAMPLE", "tag=%s rss_kib=%ld", tag, rss_kib());
}

/* Sleep while sampling RSS, so the log carries an independent RSS series. */
static void sleep_sampling(int seconds, const char *tag)
{
    int64_t end = boot_ns() + (int64_t)seconds * 1000000000LL;
    while (boot_ns() < end) {
        struct timespec req;
        req.tv_sec = 0;
        req.tv_nsec = (long)SAMPLE_MS * 1000000L;
        nanosleep(&req, NULL);
        log_rss(tag);
        if (boot_ns() >= end)
            break;
    }
}

static void touch_pages(unsigned char *p, size_t bytes)
{
    for (size_t off = 0; off < bytes; off += PAGE_BYTES)
        p[off] = 0xA5;
    /* Make sure the compiler keeps every page write. */
    __asm__ __volatile__("" : : "r"(p) : "memory");
}

static void phase_a(void)
{
    emit("A_MALLOC_START", "path=malloc bytes=%u", PHASE_BYTES);
    unsigned char *p = (unsigned char *)malloc(PHASE_BYTES);
    if (!p) {
        emit("A_MALLOC_FAIL", "errno=%d", errno);
        exit(20);
    }
    emit("A_MALLOC_DONE", "ptr=%p bytes=%u rss_kib=%ld",
         (void *)p, PHASE_BYTES, rss_kib());

    emit("A_TOUCH_START", "pages=%u", PHASE_BYTES / PAGE_BYTES);
    touch_pages(p, PHASE_BYTES);
    emit("A_TOUCH_DONE", "rss_kib=%ld", rss_kib());

    emit("A_HOLD_START", "hold_s=%d", HOLD_S);
    sleep_sampling(HOLD_S, "A_HOLD");
    emit("A_HOLD_END", "rss_kib=%ld", rss_kib());

    free(p);
    emit("A_FREE_DONE", "rss_kib=%ld", rss_kib());

    emit("A_IDLE_START", "idle_s=%d", IDLE_S);
    sleep_sampling(IDLE_S, "A_IDLE");
    emit("A_IDLE_END", "rss_kib=%ld", rss_kib());
}

static void phase_b(void)
{
    emit("B_MMAP_START", "path=mmap bytes=%u", PHASE_BYTES);
    void *m = mmap(NULL, PHASE_BYTES, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) {
        emit("B_MMAP_FAIL", "errno=%d", errno);
        exit(21);
    }
    unsigned char *p = (unsigned char *)m;
    emit("B_MMAP_DONE", "ptr=%p bytes=%u rss_kib=%ld",
         m, PHASE_BYTES, rss_kib());

    emit("B_TOUCH_START", "pages=%u", PHASE_BYTES / PAGE_BYTES);
    touch_pages(p, PHASE_BYTES);
    emit("B_TOUCH_DONE", "rss_kib=%ld", rss_kib());

    emit("B_HOLD_START", "hold_s=%d", HOLD_S);
    sleep_sampling(HOLD_S, "B_HOLD");
    emit("B_HOLD_END", "rss_kib=%ld", rss_kib());

    if (munmap(m, PHASE_BYTES) != 0) {
        emit("B_MUNMAP_FAIL", "errno=%d", errno);
        exit(22);
    }
    emit("B_MUNMAP_DONE", "rss_kib=%ld", rss_kib());

    emit("B_IDLE_START", "idle_s=%d", IDLE_S);
    sleep_sampling(IDLE_S, "B_IDLE");
    emit("B_IDLE_END", "rss_kib=%ld", rss_kib());
}

int main(int argc, char **argv)
{
    const char *logpath = (argc > 1) ? argv[1] : "memphase.log";

    g_logfd = open(logpath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    g_markfd = open("/sys/kernel/debug/tracing/trace_marker",
                    O_WRONLY | O_CLOEXEC);
    if (g_markfd < 0)
        g_markfd = open("/sys/kernel/tracing/trace_marker", O_WRONLY | O_CLOEXEC);

    emit("PROC_START", "pid=%ld log=%s trace_marker=%s",
         (long)getpid(), logpath, g_markfd >= 0 ? "yes" : "no");
    log_rss("proc_start");

    emit("BASELINE_START", "seconds=%d", BASELINE_S);
    sleep_sampling(BASELINE_S, "baseline");
    emit("BASELINE_END", "rss_kib=%ld", rss_kib());

    phase_a();
    phase_b();

    emit("TAIL_START", "tail_max_s=%d", TAIL_MAX_S);
    /* Stay alive; the session script terminates this process after OBSERVE_S. */
    for (int i = 0; i < TAIL_MAX_S; i++) {
        sleep(1);
        if ((i % 5) == 4)
            log_rss("tail");
    }
    emit("TAIL_END", "rss_kib=%ld", rss_kib());
    return 0;
}
