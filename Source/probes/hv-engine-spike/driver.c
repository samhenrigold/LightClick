// Host driver for the comparison runs: same workload object, same plan, no VM.
// Built x86_64 (runs under Rosetta) and arm64 (native).
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/mman.h>
#include "plan.h"

static double tick_ns;
static double now(void) { return mach_absolute_time() * tick_ns; }

#define BENCH(name, n, expr)                                                                                           \
    do {                                                                                                               \
        volatile u64 sum = (expr);                                                                                     \
        double best = 1e30;                                                                                            \
        for (int r = 0; r < REPS; r++) {                                                                               \
            double t = now();                                                                                          \
            sum = (expr);                                                                                              \
            t = now() - t;                                                                                             \
            if (t < best)                                                                                              \
                best = t;                                                                                              \
        }                                                                                                              \
        printf("%-10s %8.3f ns/iter  checksum %016llx\n", name, best / (n), (u64)sum);                                 \
    } while (0)

int main(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    tick_ns = (double)tb.numer / tb.denom;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    u64 *mem = mmap(0, BUF16K, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    char *c16 = mmap(0, BUF16K, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    char *c64 = mmap(0, BUF64M, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (mem == MAP_FAILED || c16 == MAP_FAILED || c64 == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    w_chase_init(c16, BUF16K);
    w_chase_init(c64, BUF64M);

    BENCH("int", N_INT, w_int(N_INT));
    BENCH("mem16k", MEM_WORDS * MEM_ROUNDS, w_mem(mem, MEM_WORDS, MEM_ROUNDS));
    BENCH("chase16k", N_CHASE16K, w_chase(c16, N_CHASE16K));
    BENCH("chase64m", N_CHASE64M, w_chase(c64, N_CHASE64M));
    BENCH("call", N_CALL, w_call(N_CALL));
    BENCH("callrand", N_CALLRAND, w_callrand(N_CALLRAND));
    BENCH("flags", N_FLAGS, w_flags(N_FLAGS));
#ifdef __x86_64__
    BENCH("flagasm", N_FLAGASM, w_flagasm(N_FLAGASM));
#endif
    return 0;
}
