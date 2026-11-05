// Freestanding workload compiled three ways: x86-64 for the spike, x86-64 under Rosetta, native arm64.
// No libc, no globals: the same object runs flat in the spike VM. Each function returns a checksum
// that the three runs must agree on.
#include "workload.h"

#define NOINLINE __attribute__((noinline))

// Integer-only register work: no memory, mixed ALU, a data-dependent branch.
u64 w_int(u64 n) {
    u64 x = 0x123456789abcdefULL, s = 0;
    for (u64 i = 0; i < n; i++) {
        x = x * 31 + i;
        x ^= x >> 7;
        if (x & 16)
            s += x;
        else
            s -= i;
    }
    return s ^ x;
}

// Sequential load, add, store, the shape where a software TLB check costs most relative to the work.
u64 w_mem(u64 *a, u64 words, u64 n) {
    u64 s = 1;
    for (u64 r = 0; r < n; r++) {
        for (u64 i = 0; i < words; i++) {
            s += a[i];
            a[i] = s;
        }
    }
    return s;
}

// Sattolo cycle at 64-byte stride, so every element sits on its own cache line.
void w_chase_init(void *buf, u64 bytes) {
    u64 count = bytes / 64, x = 88172645463325252ULL;
    char *base = buf;
    for (u64 i = 0; i < count; i++)
        *(u64 *)(base + i * 64) = (u64)(base + i * 64);
    for (u64 i = count - 1; i > 0; i--) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        u64 j = x % i;
        u64 *a = (u64 *)(base + i * 64), *b = (u64 *)(base + j * 64);
        u64 t = *a;
        *a = *b;
        *b = t;
    }
}

u64 w_chase(void *buf, u64 n) {
    void **p = buf;
    for (u64 i = 0; i < n; i++)
        p = (void **)*p;
    return (u64)p - (u64)buf;
}

static NOINLINE u64 leaf(u64 a) {
    __asm__("");
    return a * 3 + 1;
}
static NOINLINE u64 mid(u64 a) {
    __asm__("");
    return leaf(a) ^ leaf(a + 1);
}

// Two return sites, perfectly predictable with either a return stack or a BTB.
u64 w_call(u64 n) {
    u64 s = 1;
    for (u64 i = 0; i < n; i++)
        s = mid(s) + i;
    return s;
}

// Four pseudo-random call sites: a return stack predicts these rets, a BTB on `br` may not.
u64 w_callrand(u64 n) {
    u64 x = 88172645463325252ULL, s = 1;
    for (u64 i = 0; i < n; i++) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        u64 k = x & 3;
        if (k == 0)
            s = leaf(s) + 1;
        else if (k == 1)
            s = leaf(s) + 2;
        else if (k == 2)
            s = leaf(s) + 3;
        else
            s = leaf(s) + 4;
    }
    return s;
}

// Self-check, not a benchmark: drives signed, unsigned, narrow and shift flag consumers.
u64 w_flags(u64 n) {
    u64 x = 0x9e3779b97f4a7c15ULL, y = 0xdeadbeefcafef00dULL, s = 0;
    for (u64 i = 0; i < n; i++) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        y = y * 5 + 7;
        long long a = (long long)x, b = (long long)y;
        int c = (int)x, d = (int)y;
        unsigned e = (unsigned)x, f = (unsigned)y;
        signed char g = (signed char)x, h = (signed char)y;
        unsigned char k = (unsigned char)x, l = (unsigned char)y;
        short m = (short)x, o = (short)y;
        s += (a < b) + 2 * (a >= b) + 3 * (x < y) + 4 * (x >= y);
        s += 5 * (c < d) + 6 * (c > d) + 7 * (e <= f) + 8 * (e > f);
        s += 9 * (g < h) + 10 * (k < l) + 11 * (m > o) + 12 * (c == d);
        s = (s << (x & 7)) | (s >> ((-x) & 63));
        s ^= (a >> (y & 31)) + ((u64)x >> (y & 15));
        s = (a < 0) ? s + 1 : s - 1;
        s += (x + y < x) ? 13 : 17;
        s += (u64)(c + d);
    }
    return s;
}

// A CR3 reload and a sweep of `pages` 4 KB pages, so the refill cost of each invalidation scheme shows.
u64 w_cr3(u64 n, u64 cr3a, u64 cr3b, volatile char *buf, u64 pages) {
    u64 s = 0;
    for (u64 i = 0; i < n; i++) {
#ifdef __x86_64__
        if (cr3a)
            __asm__ volatile("mov %0, %%cr3" : : "r"(i & 1 ? cr3b : cr3a));
#endif
        for (u64 p = 0; p < pages; p++)
            s += buf[p * 4096];
    }
    return s;
}

// First-touch sweep at page stride, for the per-page shadow fill cost.
u64 w_touch(volatile char *buf, u64 pages, u64 write) {
    u64 s = 0;
    for (u64 p = 0; p < pages; p++) {
        if (write)
            buf[p * 4096] = (char)p;
        else
            s += buf[p * 4096];
    }
    return s;
}

// Self-check for flag paths compilers rarely emit: x86-only, its checksum is compared between spike and Rosetta.
// Reads every defined flag right after each operation. OF after a multi-bit shift is undefined, so it is not read.
#ifdef __x86_64__
#define READ_FLAGS "\n setc %b[c]\n sets %b[n]\n setz %b[z]"
#define OPS [a] "+r"(a), [c] "=&q"(c), [n] "=&q"(sf), [z] "=&q"(z), [o] "=&q"(o)
#define FL(text)                                                                                                       \
    __asm__ volatile(text READ_FLAGS "\n seto %b[o]" : OPS : [b] "r"(b) : "cc", "r11");                                \
    MIX()
#define FM(text)                                                                                                       \
    __asm__ volatile(text READ_FLAGS "\n seto %b[o]"                                                                   \
                     : [m] "+m"(mem), [c] "=&q"(c), [n] "=&q"(sf), [z] "=&q"(z), [o] "=&q"(o)                          \
                     : [b] "r"(b)                                                                                      \
                     : "cc");                                                                                          \
    MIX();                                                                                                             \
    s += mem
#define FN(text)                                                                                                       \
    __asm__ volatile(text READ_FLAGS "\n xor %k[o], %k[o]" : OPS : [b] "r"(b) : "cc");                                 \
    MIX()
#define MIX() s = s * 31 + (c | sf << 1 | z << 2 | o << 3)
u64 w_flagasm(u64 count) {
    u64 x = 0x9e3779b97f4a7c15ULL, y = 0xdeadbeefcafef00dULL, s = 0;
    for (u64 i = 0; i < count; i++) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        y = y * 5 + 7;
        u64 a = x, b = (i & 8) ? y : x; // equal operands sometimes, so ZF and carry edges are hit
        unsigned char c, sf, z, o;
        FL("add %[b], %[a]");
        FL("sub %[b], %[a]");
        FL("cmp %[b], %[a]");
        FL("add %k[b], %k[a]");
        FL("sub %k[b], %k[a]");
        FL("cmp %k[b], %k[a]");
        FL("test %[b], %[a]");
        FL("and %[b], %[a]");
        a ^= x;
        FL("or %[b], %[a]");
        FL("xor %[b], %[a]");
        a ^= y;
        FL("neg %[a]");
        FL("add %[b], %[a]\n inc %[a]"); // inc must keep CF from the add
        FL("sub %[b], %[a]\n dec %[a]"); // dec must keep CF from the sub
        FL("add %b[b], %b[a]");
        FL("sub %b[b], %b[a]");
        FL("cmp %b[b], %b[a]");
        FL("test %b[b], %b[a]");
        FL("neg %b[a]");
        FL("add %w[b], %w[a]");
        FL("cmp %w[b], %w[a]");
        FL("add $0x7f, %[a]");
        FL("cmp $-1, %[a]");
        FL("and $0xff00, %[a]");
        a ^= x;
        FN("shl $7, %[a]");
        FN("shr $3, %[a]");
        a ^= y;
        FN("sar $5, %[a]");
        FN("shl $9, %k[a]");
        a ^= x;
        FN("shr $11, %k[a]");
        a ^= y;
        FN("sar $2, %k[a]");
        // Read-modify-write memory forms.
        u64 mem = x;
        FM("addq %[b], %[m]");
        FM("subq %[b], %[m]");
        FM("incq %[m]");
        FM("xorq %[b], %[m]");
        // NZCV must survive the indirect-branch cache: the flags are read at the target.
        FL("add %[b], %[a]\n lea 1f(%%rip), %%r11\n jmp *%%r11\n 1:");
        u64 (*volatile fn)(u64) = leaf;
        s += fn(s);
        s ^= a;
    }
    return s;
}
#endif
