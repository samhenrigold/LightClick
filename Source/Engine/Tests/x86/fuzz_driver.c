// Differential fuzz driver: for each generated form, run with deterministic random inputs and print one line per form with a hash
// of every output. Comparing transcripts between engines finds divergence; `flat_main(form, 1)` prints each round of one form.
#include "flatlibc.h"

typedef struct {
    uint64_t r[16];
    uint64_t x[16][2];
    uint64_t rflags, mxcsr, rsp_delta;
} State;
extern State fuzz_st;
extern void fuzz_call(const void *form);
typedef struct {
    const void *entry;
    const char *name;
    uint32_t mask, fp;
} Form;
extern const Form fuzz_table[];

#define BUF_BYTES 8192
static uint64_t buffer[BUF_BYTES / 8] __attribute__((aligned(4096)));

static uint64_t rng_state;
static uint64_t rnd(void) {
    uint64_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return rng_state = x;
}

static uint64_t special_int(void) {
    static const uint64_t v[] = {0, 1, 2, 0x7f, 0x80, 0xff, 0x7fff, 0x8000, 0xffff, 0x7fffffff, 0x80000000, 0xffffffff,
                                 0x100000000, 0x7fffffffffffffff, 0x8000000000000000, ~0ULL, 0x0f, 0x10, 0x4040404040404040};
    uint64_t p = rnd();
    if ((p & 3) == 0)
        return v[(p >> 8) % (sizeof v / sizeof v[0])];
    if ((p & 3) == 1)
        return rnd() & 0xff;
    return rnd();
}

static uint64_t fp_pattern64(void) {
    static const uint64_t v[] = {0,
                                 0x8000000000000000,
                                 0x3ff0000000000000,
                                 0xbff0000000000000,
                                 0x7ff0000000000000,
                                 0xfff0000000000000,
                                 0x7ff8000000000000,
                                 0xfff8000000000000,
                                 0x7ff0000000000001, // SNaN
                                 0x0000000000000001, // denormal
                                 0x800fffffffffffff,
                                 0x0010000000000000,
                                 0x41e0000000000000, // 2^31
                                 0xc1e0000000000000,
                                 0x43e0000000000000, // 2^63
                                 0xc3e0000000000000,
                                 0x4000000000000000,
                                 0x3fe0000000000000,
                                 0x4008000000000000};
    uint64_t p = rnd();
    if ((p & 3) == 0)
        return v[(p >> 8) % (sizeof v / sizeof v[0])];
    // A normal number of modest magnitude, so that arithmetic is meaningful.
    return (rnd() & 0x800fffffffffffff) | ((1023 + (rnd() % 64) - 32) << 52);
}
static uint32_t fp_pattern32(void) {
    static const uint32_t v[] = {0, 0x80000000, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc00000, 0xffc00000, 0x7f800001,
                                 0x00000001, 0x807fffff, 0x00800000, 0x4f000000, 0xcf000000, 0x5f000000, 0xdf000000, 0x40000000, 0x3f000000};
    uint64_t p = rnd();
    if ((p & 3) == 0)
        return v[(p >> 8) % (sizeof v / sizeof v[0])];
    return ((uint32_t)rnd() & 0x807fffff) | ((uint32_t)(127 + (rnd() % 32) - 16) << 23);
}

static void fp_pair(uint64_t out[2]) {
    uint64_t kind = rnd() & 3;
    if (kind == 0) {
        out[0] = fp_pattern64();
        out[1] = fp_pattern64();
    } else if (kind == 1) {
        out[0] = (uint64_t)fp_pattern32() << 32 | fp_pattern32();
        out[1] = (uint64_t)fp_pattern32() << 32 | fp_pattern32();
    } else {
        out[0] = special_int();
        out[1] = special_int();
    }
}

static uint64_t hash;
static void mix(uint64_t v) {
    hash ^= v;
    hash *= 0x100000001b3ULL;
    hash ^= hash >> 29;
}

static const uint64_t mxcsr_choices[] = {0x1F80, 0x1F80, 0x1F80, 0x1F80, 0x3F80, 0x5F80, 0x7F80, 0x9F80, 0x1FC0, 0x9FC0};

static void run_round(const Form *f, bool verbose) {
    for (int i = 0; i < BUF_BYTES / 8; i++)
        buffer[i] = 0;
    // The first kilobyte is what forms touch.
    for (int i = 0; i < 128; i++)
        buffer[i] = f->fp && (i >= 4 && i < 8) ? 0 : special_int();
    uint64_t mem[2];
    fp_pair(mem);
    if (f->fp) {
        buffer[4] = mem[0];
        buffer[5] = mem[1];
    }
    for (int i = 0; i < 16; i++)
        fuzz_st.r[i] = special_int();
    fuzz_st.r[15] = (uint64_t)buffer;
    fuzz_st.r[13] = (uint64_t)buffer + 256;
    fuzz_st.r[11] &= 7;
    for (int i = 0; i < 16; i++)
        fp_pair(fuzz_st.x[i]);
    fuzz_st.rflags = (rnd() & 0x8D5) | 2 | 0x200;
    fuzz_st.mxcsr = f->fp ? mxcsr_choices[rnd() % (sizeof mxcsr_choices / sizeof mxcsr_choices[0])] : 0x1F80;
    uint64_t in_rax = fuzz_st.r[0], in_rbx = fuzz_st.r[3], in_rcx = fuzz_st.r[1], in_flags = fuzz_st.rflags, in_mx = fuzz_st.mxcsr;
    uint64_t in_x1[2] = {fuzz_st.x[1][0], fuzz_st.x[1][1]}, in_x2[2] = {fuzz_st.x[2][0], fuzz_st.x[2][1]};
    fuzz_call(f->entry);
    uint64_t base = (uint64_t)buffer;
    for (int i = 0; i < 16; i++) {
        uint64_t v = fuzz_st.r[i];
        if (v >= base && v < base + BUF_BYTES)
            v -= base; // addresses differ only by nothing today, but keep the transcript address-free
        mix(v);
    }
    mix(fuzz_st.rflags & f->mask);
    if (f->fp) {
        static const int kept[] = {0, 1, 2, 3, 4, 9, 12};
        for (unsigned i = 0; i < sizeof kept / sizeof kept[0]; i++) {
            mix(fuzz_st.x[kept[i]][0]);
            mix(fuzz_st.x[kept[i]][1]);
        }
        mix(fuzz_st.mxcsr);
    }
    mix(fuzz_st.rsp_delta);
    for (int i = 0; i < BUF_BYTES / 8; i++)
        mix(buffer[i]);
    if (verbose) {
        printf(" regs");
        for (int i = 0; i < 16; i++)
            printf(" %016lx", fuzz_st.r[i] >= base && fuzz_st.r[i] < base + BUF_BYTES ? fuzz_st.r[i] - base : fuzz_st.r[i]);
        printf("\n");
        uint64_t bh = 0;
        for (int i = 0; i < BUF_BYTES / 8; i++)
            bh = bh * 31 + buffer[i];
        printf(" buffer %016lx\n", bh);
        printf(" in rax=%016lx rbx=%016lx rcx=%016lx fl=%04lx mx=%04lx x1=%016lx%016lx x2=%016lx%016lx mem=%016lx%016lx\n", in_rax, in_rbx, in_rcx,
               in_flags, in_mx, in_x1[1], in_x1[0], in_x2[1], in_x2[0], mem[1], mem[0]);
        printf(" out rax=%016lx rbx=%016lx rcx=%016lx rdx=%016lx fl=%04lx/%04lx mx=%04lx x1=%016lx%016lx rsp=%lx mem8=%016lx\n", fuzz_st.r[0],
               fuzz_st.r[3], fuzz_st.r[1], fuzz_st.r[2], fuzz_st.rflags & f->mask, fuzz_st.rflags, fuzz_st.mxcsr, fuzz_st.x[1][1], fuzz_st.x[1][0],
               fuzz_st.rsp_delta, buffer[1]);
    }
}

// a0: 0 all forms in order, n+1 only form n. a1: nonzero prints each round.
int flat_main(unsigned long a0, unsigned long a1) {
    int rounds = 64;
    for (int i = 0; fuzz_table[i].entry; i++) {
        if (a0 && (unsigned long)i != a0 - 1)
            continue;
        const Form *f = &fuzz_table[i];
        rng_state = 0x9E3779B97F4A7C15ULL ^ ((uint64_t)(i + 1) * 0xDEADBEEF);
        hash = 0xcbf29ce484222325ULL;
        for (int r = 0; r < rounds; r++) {
            uint64_t h0 = hash;
            run_round(f, a1 != 0);
            if (a1)
                printf("round %d hash %016lx from %016lx\n", r, hash, h0);
        }
        printf("%4d %016lx %s\n", i, hash, f->name);
    }
    return 0;
}
