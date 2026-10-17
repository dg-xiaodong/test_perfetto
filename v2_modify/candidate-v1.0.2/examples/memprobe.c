#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
/* Small bounded test workload, not a benchmark or a leak detector.
 * Compile with -g -O1 -fno-omit-frame-pointer -fno-optimize-sibling-calls.
 * CLOCK_MONOTONIC log timestamps require clock correlation with the trace.
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static long page_size;
static uint64_t now_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) { perror("clock_gettime"); exit(1); }
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}
static void mark(const char *event, size_t bytes) {
    printf("monotonic_ns=%llu pid=%ld event=%s bytes=%zu\n",
           (unsigned long long)now_ns(), (long)getpid(), event, bytes);
    fflush(stdout);
}
static void hold_ms(long ms) {
    struct timespec req = {ms / 1000, (ms % 1000) * 1000000L};
    while (nanosleep(&req, &req) != 0) {
        if (errno != EINTR) { perror("nanosleep"); exit(1); }
    }
}
static void touch(void *ptr, size_t n) {
    volatile unsigned char *p = ptr;
    for (size_t i = 0; i < n; i += (size_t)page_size) p[i] = 0x5a;
    p[n - 1] = 0x5a;
}
__attribute__((noinline)) static void *allocate_live_pool(size_t n) {
    void *p = malloc(n);
    if (!p) { perror("malloc"); exit(1); }
    touch(p, n);
    mark("pool_touched", n);
    return p;
}
__attribute__((noinline)) static void short_lived_block(size_t n, long ms) {
    void *p = malloc(n);
    if (!p) { perror("malloc"); exit(1); }
    touch(p, n); mark("spike_touched", n);
    hold_ms(ms); free(p); mark("spike_freed", n);
}
__attribute__((noinline)) static void churn_blocks(size_t total) {
    const size_t n = total / 64;
    for (int i = 0; i < 64; ++i) {
        void *p = malloc(n);
        if (!p) { perror("malloc"); exit(1); }
        touch(p, n); free(p);
    }
    mark("churn_batch_freed", n * 64);
}
static long number(const char *s, long low, long high) {
    char *end = NULL;
    errno = 0;
    long value = strtol(s, &end, 10);
    if (errno || !s[0] || *end || value < low || value > high) {
        fprintf(stderr, "Invalid bounded argument: %s (allowed %ld..%ld)\n", s, low, high);
        exit(2);
    }
    return value;
}
int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "heap";
    if (argc > 5 || (strcmp(mode,"heap") && strcmp(mode,"spike") &&
                    strcmp(mode,"churn") && strcmp(mode,"mmap"))) {
        fprintf(stderr, "usage: %s [heap|spike|churn|mmap] [MiB:1..256] [hold_ms:1..10000] [cycles:1..20]\n", argv[0]);
        return 2;
    }
    const long mib = argc > 2 ? number(argv[2],1,256) : 16;
    const long ms = argc > 3 ? number(argv[3],1,10000) : 6000;
    const long cycles = argc > 4 ? number(argv[4],1,20) : 2;
    if (!strcmp(mode,"heap") && mib * cycles > 256) {
        fprintf(stderr,"Retained test memory is capped at 256 MiB total\n"); return 2;
    }
    page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) { fprintf(stderr,"Cannot determine page size\n"); return 1; }
    const size_t bytes = (size_t)mib * 1024 * 1024;
    void *blocks[20] = {0};
    mark("begin",0);
    for (long i=0; i<cycles; ++i) {
        if (!strcmp(mode,"heap")) {
            blocks[i]=allocate_live_pool(bytes); hold_ms(ms);
        } else if (!strcmp(mode,"spike")) {
            short_lived_block(bytes,ms); hold_ms(200);
        } else if (!strcmp(mode,"churn")) {
            churn_blocks(bytes); hold_ms(ms);
        } else {
            void *p=mmap(NULL,bytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
            if (p==MAP_FAILED) { perror("mmap"); return 1; }
            touch(p,bytes); mark("direct_mmap_touched",bytes); hold_ms(ms);
            if (munmap(p,bytes)) { perror("munmap"); return 1; }
            mark("direct_mmap_unmapped",bytes);
        }
    }
    for (long i=0; i<cycles; ++i) if (blocks[i]) free(blocks[i]);
    mark("end_all_freed",0);
    return 0;
}
