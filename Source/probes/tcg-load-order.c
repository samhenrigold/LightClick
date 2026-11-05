// Litmus tests of the x86 orders that PVG_TCG_LOAD_DEPENDENCY must keep. In message passing, one thread writes x then y
// and the other reads y then x with nothing between; a new y with an older x breaks store-to-store or load-to-load
// order. In load buffering, each thread reads one variable then writes the other, and neither may see a value that
// depended on its own later write. Run in a guest with at least 2 vCPUs and expect 0 on every line.
//   xcrun clang -arch x86_64 -mmacosx-version-min=10.9 -O1 Source/probes/tcg-load-order.c -o tcg-load-order
// Built for arm64 and run on the host, `plain` shows this test can see reordering at all, `dependency` shows the host
// keeps the order that TCG's dependency relies on, and `barrier` is the reference. A nonzero exit is expected there.
//   xcrun clang -arch arm64 -O1 Source/probes/tcg-load-order.c -o tcg-load-order-host
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define ROUNDS 100000000ULL
#define LB_ROUNDS 4000000

// A line apart, so that the two can leave the writer's cache and reach the reader in either order.
static struct {
    volatile uint64_t x[2] __attribute__((aligned(128)));
    volatile uint64_t y[2] __attribute__((aligned(128)));
    volatile int stop __attribute__((aligned(128)));
} shared;

static void *writer(void *unused) {
    (void)unused;
    for (uint64_t i = 1; !shared.stop; i++) {
#if defined(__x86_64__)
        if (i & 0x10000)
            __asm__ volatile("movq %2,%%xmm0\n\tmovups %%xmm0,(%0)\n\tmovups %%xmm0,(%1)"
                             :
                             : "r"(&shared.x[0]), "r"(&shared.y[0]), "r"(i)
                             : "memory", "xmm0");
        else
            __asm__ volatile("movq %2,(%0)\n\tmovq %2,(%1)"
                             :
                             : "r"(&shared.x[0]), "r"(&shared.y[0]), "r"(i)
                             : "memory");
#else
        __atomic_store_n(&shared.x[0], i, __ATOMIC_RELEASE);
        __atomic_store_n(&shared.y[0], i, __ATOMIC_RELEASE);
#endif
    }
    return NULL;
}

#if defined(__x86_64__)
#define READ_8 "movq (%2),%0\n\tmovq (%3),%1"
#define READ_4 "movl (%2),%k0\n\tmovl (%3),%k1"
#define READ_16 "movups (%2),%%xmm0\n\tmovups (%3),%%xmm1\n\tmovq %%xmm0,%0\n\tmovq %%xmm1,%1"
#define READ_MIXED "movups (%2),%%xmm0\n\tmovq (%3),%1\n\tmovq %%xmm0,%0"
#define CLOBBER "xmm0", "xmm1"
static const char *const names[] = {"movq", "movl", "movups", "movups_movq"};
#else
#define READ_8 "ldr %0,[%2]\n\tldr %1,[%3]"
#define READ_4 "ldr %0,[%2]\n\tdmb ishld\n\tldr %1,[%3]"
#define READ_16 "ldp %0,xzr,[%2]\n\teor x9,%0,%0\n\tldr %1,[%3,x9]"
#define READ_MIXED "ldr %0,[%2]\n\teor x9,%0,%0\n\tadd x10,%3,x9\n\tldp %1,xzr,[x10]"
#define CLOBBER "x9", "x10"
static const char *const names[] = {"plain", "barrier", "dependency", "dependency_ldp"};
#endif

#define TEST(index, sequence)                                                                                          \
    do {                                                                                                               \
        uint64_t violations = 0;                                                                                       \
        for (uint64_t i = 0; i < ROUNDS; i++) {                                                                        \
            uint64_t seen_y, seen_x;                                                                                   \
            __asm__ volatile(sequence                                                                                  \
                             : "=&r"(seen_y), "=&r"(seen_x)                                                            \
                             : "r"(&shared.y[0]), "r"(&shared.x[0])                                                    \
                             : "memory", CLOBBER);                                                                     \
            violations += index == 1 ? (uint32_t)seen_y > (uint32_t)seen_x : seen_y > seen_x;                          \
        }                                                                                                              \
        printf("%s %llu\n", names[index], (unsigned long long)violations);                                             \
        failed |= violations != 0;                                                                                     \
    } while (0)

static uint32_t *lb_seen[2];
static volatile int lb_ready[2];

static void *lb_thread(void *arg) {
    long me = (long)arg;
    volatile uint64_t *from = me ? &shared.y[0] : &shared.x[0], *to = me ? &shared.x[0] : &shared.y[0];
    lb_ready[me] = 1;
    while (!lb_ready[!me]) {
    }
    for (uint32_t i = 1; i <= LB_ROUNDS; i++) {
        uint64_t seen, value = i;
#if defined(__x86_64__)
        if (i & 0x10000)
            __asm__ volatile("movq %3,%%xmm0\n\tmovq (%1),%0\n\tmovups %%xmm0,(%2)"
                             : "=&r"(seen)
                             : "r"(from), "r"(to), "r"(value)
                             : "memory", "xmm0");
        else
            __asm__ volatile("movq (%1),%0\n\tmovq %3,(%2)" : "=&r"(seen) : "r"(from), "r"(to), "r"(value) : "memory");
#else
        __asm__ volatile("ldr %0,[%1]\n\tstr %3,[%2]" : "=&r"(seen) : "r"(from), "r"(to), "r"(value) : "memory");
#endif
        lb_seen[me][i] = (uint32_t)seen;
    }
    return NULL;
}

// A thread in round i read j, so the other's round j wrote first and that round's read came before this thread's write
// of round i. Having read i or later would need a cycle.
static int load_buffering(void) {
    pthread_t threads[2];
    uint64_t violations = 0;
    shared.x[0] = shared.y[0] = 0;
    for (long me = 0; me < 2; me++) {
        lb_seen[me] = calloc(LB_ROUNDS + 1, sizeof(uint32_t));
        if (!lb_seen[me])
            return 2;
    }
    for (long me = 0; me < 2; me++)
        if (pthread_create(&threads[me], NULL, lb_thread, (void *)me))
            return 2;
    for (long me = 0; me < 2; me++)
        pthread_join(threads[me], NULL);
    for (int me = 0; me < 2; me++)
        for (uint32_t i = 1; i <= LB_ROUNDS; i++) {
            uint32_t j = lb_seen[me][i];
            if (j && lb_seen[!me][j] >= i)
                violations++;
        }
    printf("load_buffering %llu\n", (unsigned long long)violations);
    return violations != 0;
}

int main(void) {
    pthread_t thread;
    int failed = 0;
    if (pthread_create(&thread, NULL, writer, NULL))
        return 2;
    TEST(0, READ_8);
    TEST(1, READ_4);
    TEST(2, READ_16);
    TEST(3, READ_MIXED);
    shared.stop = 1;
    pthread_join(thread, NULL);
    failed |= load_buffering();
    return failed;
}
