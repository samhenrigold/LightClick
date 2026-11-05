// Self-checking guest test of REP MOVS/STOS: overlaps in both directions and precise registers when a fault lands
// mid-copy. Prints `ok` or the first failure; needs no reference run.
//   xcrun clang -arch x86_64 -mmacosx-version-min=10.9 -O1 Source/probes/tcg-rep-fault.c -o tcg-rep-fault
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <unistd.h>

static sigjmp_buf back;
static uint64_t fault_rcx, fault_rsi, fault_rdi, fault_address;

static void on_fault(int signal, siginfo_t *info, void *context) {
    (void)signal;
    _STRUCT_X86_THREAD_STATE64 *state = &((ucontext_t *)context)->uc_mcontext->__ss;
    fault_rcx = state->__rcx;
    fault_rsi = state->__rsi;
    fault_rdi = state->__rdi;
    fault_address = (uint64_t)info->si_addr;
    state->__rflags &= ~UINT64_C(0x400); // leave DF clear for the C code the signal returns to
    __asm__ volatile("cld");
    siglongjmp(back, 1);
}

// Element size selects the mnemonic; DF is set only around the instruction.
#define REP(insn)                                                                                                      \
    __asm__ volatile("test %[down],%[down]\n\tjz 1f\n\tstd\n1:\n\trep; " insn "\n\tcld"                                \
                     : "+c"(count), "+S"(src), "+D"(dst)                                                               \
                     : [down] "r"(down), "a"(value)                                                                    \
                     : "memory", "cc")

static void run(int movs, unsigned size, int down, uint8_t *dst, const uint8_t *src, uint64_t count, uint64_t value,
                uint64_t *left, uint64_t *rsi, uint64_t *rdi) {
    if (movs) {
        switch (size) {
            case 1:
                REP("movsb");
                break;
            case 2:
                REP("movsw");
                break;
            case 4:
                REP("movsl");
                break;
            default:
                REP("movsq");
                break;
        }
    } else {
        switch (size) {
            case 1:
                REP("stosb");
                break;
            case 2:
                REP("stosw");
                break;
            case 4:
                REP("stosl");
                break;
            default:
                REP("stosq");
                break;
        }
    }
    *left = count;
    *rsi = (uint64_t)src;
    *rdi = (uint64_t)dst;
}

static int failures;
static void fail(const char *what, unsigned size, int down, uint64_t a, uint64_t b) {
    printf("FAIL %s size=%u down=%d %llx %llx\n", what, size, down, (unsigned long long)a, (unsigned long long)b);
    failures++;
}

#define SPACE (1024 * 1024)
static uint8_t *space, *model;

static void reset(void) {
    for (size_t i = 0; i < SPACE; i++)
        space[i] = model[i] = (uint8_t)(i * 167 + 13);
}

static void overlaps(void) {
    static const int64_t gaps[] = {0, 1, 2, 3, 4, 7, 8, 9, 16, 17, 64, 4095, 4096, 4097, 20000};
    static const uint64_t counts[] = {1, 15, 16, 17, 100, 4096, 70000};
    for (unsigned s = 0; s < 4; s++)
        for (int down = 0; down < 2; down++)
            for (int sign = 0; sign < 2; sign++)
                for (unsigned g = 0; g < sizeof(gaps) / sizeof(*gaps); g++)
                    for (unsigned c = 0; c < sizeof(counts) / sizeof(*counts); c++) {
                        unsigned size = 1u << s;
                        uint64_t count = counts[c], left, rsi, rdi, n = count * size;
                        size_t src = 300000, dst = sign ? src - gaps[g] : src + gaps[g];
                        reset();
                        for (uint64_t e = 0; e < count; e++) {
                            uint64_t i = down ? (count - 1 - e) * size : e * size;
                            uint8_t held[8];
                            memcpy(held, model + src + i, size);
                            memcpy(model + dst + i, held, size);
                        }
                        // String instructions start at the first element, the top one going down.
                        uint64_t first = down ? n - size : 0;
                        run(1, size, down, space + dst + first, space + src + first, count, 0, &left, &rsi, &rdi);
                        if (memcmp(space, model, SPACE))
                            fail("overlap data", size, down, gaps[g], count);
                        uint64_t want_s = (uint64_t)space + src + (down ? (uint64_t)-(int64_t)size : n);
                        uint64_t want_d = (uint64_t)space + dst + (down ? (uint64_t)-(int64_t)size : n);
                        if (left || rsi != want_s || rdi != want_d)
                            fail("overlap regs", size, down, rsi, want_s);
                    }
}

static void fills(void) {
    for (unsigned s = 0; s < 4; s++)
        for (int down = 0; down < 2; down++)
            for (unsigned misalign = 0; misalign < 2; misalign++)
                for (uint64_t value = 0; value < 2; value++) {
                    unsigned size = 1u << s;
                    uint64_t count = 20000, n = count * size, left, rsi, rdi;
                    uint64_t pattern = value ? UINT64_C(0x8877665544332211) : 0;
                    size_t dst = 100003 + misalign * 4093;
                    reset();
                    for (uint64_t e = 0; e < count; e++)
                        memcpy(model + dst + e * size, &pattern, size);
                    uint64_t first = down ? n - size : 0;
                    run(0, size, down, space + dst + first, NULL, count, pattern, &left, &rsi, &rdi);
                    if (memcmp(space, model, SPACE))
                        fail("fill data", size, down, dst, count);
                    if (left || rdi != (uint64_t)space + dst + (down ? (uint64_t)-(int64_t)size : n))
                        fail("fill regs", size, down, left, rdi);
                }
}

// The destination or source runs into a PROT_NONE page after `before` whole elements fit.
static void faults(void) {
    const size_t page = (size_t)getpagesize();
    uint8_t *map = mmap(NULL, page * 64, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    uint8_t *other = mmap(NULL, page * 64, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    uint8_t *hole = map + page * 32;
    mprotect(hole, page, PROT_NONE);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = on_fault;
    action.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);

    for (unsigned s = 0; s < 4; s++)
        for (int down = 0; down < 2; down++)
            for (int fault_in_src = 0; fault_in_src < 2; fault_in_src++)
                for (unsigned misalign = 0; misalign < (s ? 2 : 1); misalign++) {
                    unsigned size = 1u << s;
                    uint64_t before = 10000 / size + 3, count = before + 5000;
                    // Going up the run ends at the hole; going down it starts just above and descends into it.
                    uint8_t *edge = down ? hole + page : hole;
                    uint8_t *at = down ? edge + misalign : edge - misalign;
                    uint8_t *near_hole = down ? at + (before - 1) * size : at - before * size;
                    uint8_t *far = other + page * 20 + (down ? (before - 1) * size : 0) + 8;
                    uint8_t *src = fault_in_src ? near_hole : far, *dst = fault_in_src ? far : near_hole;
                    memset(other, 0x11, page * 64);
                    if (sigsetjmp(back, 1) == 0) {
                        uint64_t left, rsi, rdi;
                        run(1, size, down, dst, src, count, 0, &left, &rsi, &rdi);
                        fail("no fault", size, down, fault_in_src, misalign);
                        continue;
                    }
                    // `before` elements fit whole; a misaligned next one straddles the hole and must not count.
                    uint64_t finished = before;
                    uint64_t step = finished * size;
                    uint64_t want_s = down ? (uint64_t)src - step : (uint64_t)src + step;
                    uint64_t want_d = down ? (uint64_t)dst - step : (uint64_t)dst + step;
                    if (fault_rcx != count - finished || fault_rsi != want_s || fault_rdi != want_d)
                        fail(fault_in_src ? "fault regs src" : "fault regs dst", size, down, fault_rcx,
                             count - finished);
                    uint64_t page_mask = ~(uint64_t)(page - 1);
                    if ((fault_address & page_mask) != (uint64_t)hole)
                        fail("fault address", size, down, fault_address, (uint64_t)hole);
                }
}

int main(void) {
    space = mmap(NULL, SPACE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    model = mmap(NULL, SPACE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    overlaps();
    fills();
    faults();
    puts(failures ? "FAILED" : "ok");
    return failures != 0;
}
