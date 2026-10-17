/* Tiny optional test target. Do NOT run on customer production workload. */
#define _POSIX_C_SOURCE 200809L
#include <time.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
int main(int argc,char **argv) {
    int busy = argc>1 && strcmp(argv[1],"busy")==0;
    struct timespec t0,now,nap={0,10000000};
    clock_gettime(CLOCK_MONOTONIC,&t0);
    volatile uint64_t x=1;
    do {
        if(busy) for(int i=0;i<100000;i++)x=(x*1664525u+1013904223u)%4294967291u;
        else nanosleep(&nap,0);
        clock_gettime(CLOCK_MONOTONIC,&now);
    } while((now.tv_sec-t0.tv_sec)<2);
    printf("cpu_probe mode=%s checksum=%llu\n",busy?"busy":"sleep",(unsigned long long)x);
    return 0;
}
