// Guest test of adjacent 16-byte SSE accesses in one translation block: data across page boundaries, precise faults on
// a later access after earlier ones hit the same or a neighboring page, a faulting load leaving its destination alone,
// misaligned movaps, and stores into code. Prints `ok` or the first failure, then a state hash to compare with
// PVG_TCG_SSE_DIRECT_LOAD=0 PVG_TCG_LOAD_DEPENDENCY=0. Rosetta does not enforce movaps alignment, so it stops at that
// last check.
//   xcrun clang -arch x86_64 -mmacosx-version-min=10.9 -O1 Source/probes/tcg-same-page-fault.c -o tcg-same-page-fault
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ucontext.h>

#define PAGE 4096

static sigjmp_buf resume;
static volatile uintptr_t fault_addr;
static volatile int fault_signal;
static uint64_t fault_xmm[4][2];
static uint64_t state = 1469598103934665603ULL;

static void mix(uint64_t v) { state = (state ^ v) * 1099511628211ULL; }

static void on_fault(int signal, siginfo_t *info, void *context) {
    ucontext_t *uc = context;
    fault_signal = signal;
    fault_addr = (uintptr_t)info->si_addr;
    memcpy(fault_xmm[0], &uc->uc_mcontext->__fs.__fpu_xmm0, 16);
    memcpy(fault_xmm[1], &uc->uc_mcontext->__fs.__fpu_xmm1, 16);
    memcpy(fault_xmm[2], &uc->uc_mcontext->__fs.__fpu_xmm2, 16);
    memcpy(fault_xmm[3], &uc->uc_mcontext->__fs.__fpu_xmm3, 16);
    siglongjmp(resume, 1);
}

static int failed(const char *what) {
    printf("FAILED: %s\n", what);
    return 1;
}

// Four loads then four stores with no branch between them, so each set shares a block and each second access shares a
// page.
static void copy64(const void *from, void *to) {
    __asm__ volatile("movups (%0),%%xmm0\n\tmovups 16(%0),%%xmm1\n\tmovups 32(%0),%%xmm2\n\tmovups 48(%0),%%xmm3\n\t"
                     "movups %%xmm0,(%1)\n\tmovups %%xmm1,16(%1)\n\tmovups %%xmm2,32(%1)\n\tmovups %%xmm3,48(%1)"
                     :
                     : "r"(from), "r"(to)
                     : "memory", "xmm0", "xmm1", "xmm2", "xmm3");
}

static int boundaries(unsigned char *base) {
    static unsigned char expect[PAGE * 3];
    for (size_t i = 0; i < sizeof(expect); i++)
        base[i] = expect[i] = (unsigned char)(i * 167 + (i >> 8));
    // Every source and target position near a page boundary, so that any access can be the one that crosses.
    for (int from = PAGE - 80; from < PAGE + 16; from++)
        for (int to = 2 * PAGE - 80; to < 2 * PAGE + 16; to += 7) {
            copy64(base + from, base + to);
            memcpy(expect + to, expect + from, 64);
            if (memcmp(base, expect, sizeof(expect)))
                return failed("copy across a page boundary");
        }
    return 0;
}

// A load in the next page faults after loads in this page completed.
static int load_fault(unsigned char *base) {
    mprotect(base + PAGE, PAGE, PROT_NONE);
    memset(base, 0x11, PAGE);
    __asm__ volatile("pxor %%xmm0,%%xmm0\n\tpxor %%xmm1,%%xmm1" : : : "xmm0", "xmm1");
    for (int gap = 16; gap <= 32; gap += 16) {
        unsigned char *p = base + PAGE - gap;
        memset(fault_xmm, 0, sizeof(fault_xmm));
        fault_signal = 0;
        if (!sigsetjmp(resume, 1)) {
            // All ones in the two later destinations, which a load that faults must not touch.
            __asm__ volatile("pcmpeqd %%xmm1,%%xmm1\n\tpcmpeqd %%xmm2,%%xmm2\n\t"
                             "movups (%0),%%xmm0\n\tmovups 16(%0),%%xmm1\n\tmovups 32(%0),%%xmm2"
                             :
                             : "r"(p)
                             : "memory", "xmm0", "xmm1", "xmm2");
            return failed("load past the page did not fault");
        }
        if (!fault_signal || fault_addr < (uintptr_t)base + PAGE || fault_addr >= (uintptr_t)base + 2 * PAGE)
            return failed("load fault address");
        if (fault_xmm[0][0] != 0x1111111111111111ULL)
            return failed("first load lost");
        if (gap == 32 && fault_xmm[1][0] != 0x1111111111111111ULL)
            return failed("second load lost");
        if (gap == 16 && (fault_xmm[1][0] != ~0ULL || fault_xmm[1][1] != ~0ULL))
            return failed("faulting load changed its destination");
        if (fault_xmm[2][0] != ~0ULL || fault_xmm[2][1] != ~0ULL)
            return failed("faulting load changed its destination or a later one");
        mix(fault_addr - (uintptr_t)base);
        mix(fault_xmm[1][1]);
        mix(fault_xmm[2][0]);
    }
    mprotect(base + PAGE, PAGE, PROT_READ | PROT_WRITE);
    return 0;
}

// A store in a read-only next page faults and leaves earlier stores in place.
static int store_fault(unsigned char *base) {
    mprotect(base + PAGE, PAGE, PROT_READ);
    memset(base, 0, PAGE);
    unsigned char *p = base + PAGE - 32;
    memset(fault_xmm, 0, sizeof(fault_xmm));
    fault_signal = 0;
    if (!sigsetjmp(resume, 1)) {
        static const uint64_t value[2] = {0x2222222222222222ULL, 0x2222222222222222ULL};
        __asm__ volatile("movups (%1),%%xmm0\n\tmovups %%xmm0,(%0)\n\tmovups %%xmm0,16(%0)\n\tmovups %%xmm0,32(%0)"
                         :
                         : "r"(p), "r"(value)
                         : "memory", "xmm0");
        return failed("store past the page did not fault");
    }
    if (!fault_signal || fault_addr < (uintptr_t)base + PAGE)
        return failed("store fault address");
    for (int i = 0; i < 32; i++)
        if (p[i] != 0x22)
            return failed("earlier store lost");
    mprotect(base + PAGE, PAGE, PROT_READ | PROT_WRITE);
    mix(fault_addr - (uintptr_t)base);
    return 0;
}

// movaps after a passing movaps in the same page still checks alignment.
static int misaligned(unsigned char *base) {
    memset(base, 0x33, PAGE);
    unsigned char *p = base + 64;
    fault_signal = 0;
    if (!sigsetjmp(resume, 1)) {
        __asm__ volatile("pcmpeqd %%xmm1,%%xmm1\n\tmovaps (%0),%%xmm0\n\tmovaps 17(%0),%%xmm1\n\tmovaps %%xmm0,(%0)"
                         :
                         : "r"(p)
                         : "memory", "xmm0", "xmm1");
        return failed("misaligned movaps did not fault");
    }
    if (!fault_signal)
        return failed("misaligned movaps signal");
    if (fault_xmm[0][0] != 0x3333333333333333ULL)
        return failed("load before misaligned movaps lost");
    if (fault_xmm[1][0] != ~0ULL || fault_xmm[1][1] != ~0ULL)
        return failed("misaligned movaps changed its destination");
    mix((uint64_t)fault_signal);
    fault_signal = 0;
    if (!sigsetjmp(resume, 1)) {
        __asm__ volatile("movaps %%xmm0,(%0)\n\tmovaps %%xmm0,17(%0)" : : "r"(p) : "memory", "xmm0");
        return failed("misaligned store did not fault");
    }
    return fault_signal ? 0 : failed("misaligned store signal");
}

// Stores that land on translated code must take effect, also when an earlier store passed the check for this page.
static int code_writes(void) {
    unsigned char *code = mmap(NULL, PAGE, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (code == MAP_FAILED) {
        printf("# skip code writes: no RWX mapping\n");
        return 0;
    }
    int (*call)(void) = (int (*)(void))(void *)(code + 16);
    for (int i = 0; i < 64; i++) {
        // mov $i, %eax ; ret, padded with nops.
        unsigned char body[16] = {0xb8, (unsigned char)i, 0, 0, 0, 0xc3};
        memset(body + 6, 0x90, 10);
        __asm__ volatile("movups (%2),%%xmm0\n\tmovups %%xmm0,(%0)\n\tmovups %%xmm0,(%1)"
                         :
                         : "r"(code + 256), "r"(code + 16), "r"(body)
                         : "memory", "xmm0");
        if (call() != i)
            return failed("stale code after a same-page store");
    }
    munmap(code, PAGE);
    return 0;
}

int main(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = on_fault;
    action.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);
    unsigned char *base = mmap(NULL, PAGE * 4, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (base == MAP_FAILED)
        return failed("mmap");
    if (boundaries(base) || load_fault(base) || store_fault(base) || code_writes() || misaligned(base))
        return 1;
    printf("ok hash=%016llx\n", (unsigned long long)state);
    return 0;
}
