// Compare output from one x86 binary across runs. Covers result bits and MXCSR exception flags in all rounding, DAZ and
// FTZ modes, with PE sticky and not, plus upper lanes, EFLAGS and shuffles. Each `op=` line names what differed.
//   xcrun clang -arch x86_64 -mmacosx-version-min=10.9 -O1 Source/probes/tcg-sse-differential.c -o tcg-sse-differential
// The check that matters is the same guest with the fast paths on and off, which must match exactly:
//   PVG_TCG_INLINE_FP=0 PVG_TCG_INLINE_SSE_PACKED=0 PVG_TCG_NATIVE_EXACT_FP=0
//   PVG_TCG_NATIVE_PACKED_FP=0
// Rosetta is a second opinion only. QEMU's SSE uses x87 NaN propagation (a TODO in fpu_helper.c), so it differs from
// hardware in lines with two NaN inputs whichever path runs.
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <emmintrin.h>

static uint64_t rng = 0xbadc0ffeedead123ULL;
static uint64_t next(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}
static uint64_t mix(uint64_t h, uint64_t v) { return (h ^ v) * 1099511628211ULL; }
#define OP(insn)                                                                                                       \
    __asm__ volatile("ldmxcsr %2\n\t" insn " %3,%0\n\tstmxcsr %1"                                                      \
                     : "+x"(a), "=m"(flags)                                                                            \
                     : "m"(mode), "x"(b)                                                                               \
                     : "memor"                                                                                         \
                       "y")

// Inputs on the boundaries the fast paths test: zeros, denormals, the smallest normals, values whose products and
// quotients land on them, rounding halfway points, integer conversion limits, the largest finites, infinity and NaNs.
static const uint64_t edge64[] = {
    0x0000000000000000ULL, 0x0000000000000001ULL, 0x000fffffffffffffULL, 0x0010000000000000ULL, 0x0010000000000001ULL,
    0x001fffffffffffffULL, 0x0020000000000000ULL, 0x1ff0000000000000ULL, 0x2000000000000000ULL, 0x3690000000000000ULL,
    0x36a0000000000000ULL, 0x380fffffffffffffULL, 0x380ffffff0000000ULL, 0x3810000000000000ULL, 0x3fe0000000000000ULL,
    0x3fefffffffffffffULL, 0x3ff0000000000000ULL, 0x3ff0000000000001ULL, 0x3ff8000000000000ULL, 0x4000000000000000ULL,
    0x4330000000000000ULL, 0x4340000000000001ULL, 0x41dfffffffc00000ULL, 0x41dfffffffffffffULL, 0x41e0000000000000ULL,
    0x41e0000000200000ULL, 0x43dfffffffffffffULL, 0x43e0000000000000ULL, 0x47efffffe0000000ULL, 0x47effffff0000000ULL,
    0x47f0000000000000ULL, 0x7fdfffffffffffffULL, 0x7fefffffffffffffULL, 0x7ff0000000000000ULL, 0x7ff0000000000001ULL,
    0x7ff8000000000000ULL, 0x7fffffffffffffffULL,
};
static const uint32_t edge32[] = {
    0x00000000, 0x00000001, 0x007fffff, 0x00800000, 0x00800001, 0x00ffffff, 0x01000000, 0x1f800000, 0x20000000,
    0x3f000000, 0x3f7fffff, 0x3f800000, 0x3f800001, 0x3fc00000, 0x40000000, 0x4b000000, 0x4b800001, 0x4effffff,
    0x4f000000, 0x4f000001, 0x5effffff, 0x5f000000, 0x7f7fffff, 0x7f800000, 0x7f800001, 0x7fc00000, 0x7fffffff,
};
#define COUNT(a) (sizeof(a) / sizeof(*(a)))

typedef struct {
    uint64_t lo, hi;
} xmm;

// A nonzero upper half on every register proves that scalar results leave it alone.
#define UPPER 0x5a5a5a5a5a5a5a5aULL
#define LOWER32 0xa5a5a5a500000000ULL

// insn xmm1, xmm0: result is all of xmm0.
#define VECTOR2(insn)                                                                                                  \
    __asm__ volatile("ldmxcsr %[mode]\n\tmovdqu %[in],%%xmm0\n\tmovdqu %[other],%%xmm1\n\t" insn                       \
                     " %%xmm1,%%xmm0\n\tstmxcsr %[flags]\n\tmovdqu %%xmm0,%[out]"                                      \
                     : [out] "=m"(result), [flags] "=m"(flags)                                                         \
                     : [mode] "m"(mode), [in] "m"(x), [other] "m"(y)                                                   \
                     : "memory", "xmm0", "xmm1")
// insn m, xmm0: the same with a memory source.
#define VECTORM(insn, source)                                                                                          \
    __asm__ volatile("ldmxcsr %[mode]\n\tmovdqu %[in],%%xmm0\n\t" insn                                                 \
                     " %[other],%%xmm0\n\tstmxcsr %[flags]\n\tmovdqu %%xmm0,%[out]"                                    \
                     : [out] "=m"(result), [flags] "=m"(flags)                                                         \
                     : [mode] "m"(mode), [in] "m"(x), [other] "m"(source)                                              \
                     : "memory", "xmm0")
// insn gpr, xmm0.
#define FROM_INT(insn, reg, value)                                                                                     \
    __asm__ volatile("ldmxcsr %[mode]\n\tmovdqu %[in],%%xmm0\n\t" insn " %" reg "[v],%%xmm0\n\t"                       \
                     "stmxcsr %[flags]\n\tmovdqu %%xmm0,%[out]"                                                        \
                     : [out] "=m"(result), [flags] "=m"(flags)                                                         \
                     : [mode] "m"(mode), [in] "m"(x), [v] "r"(value)                                                   \
                     : "memory", "xmm0")
// insn xmm1, gpr: the destination starts dirty to prove a 32-bit result zero-extends.
#define TO_INT(insn, reg)                                                                                              \
    __asm__ volatile("ldmxcsr %[mode]\n\tmovdqu %[other],%%xmm1\n\tmov %[dirty],%q[out]\n\t" insn " %%xmm1,%" reg      \
                     "[out]\n\tstmxcsr %[flags]"                                                                       \
                     : [out] "=&r"(result.lo), [flags] "=m"(flags)                                                     \
                     : [mode] "m"(mode), [other] "m"(y), [dirty] "r"(UPPER)                                            \
                     : "memory", "xmm1")
// insn xmm1, xmm0, then all of EFLAGS. Skipping the red zone lets pushfq stay in a leaf function.
#define COMPARE(insn)                                                                                                  \
    __asm__ volatile("ldmxcsr %[mode]\n\tmovdqu %[in],%%xmm0\n\tmovdqu %[other],%%xmm1\n\t" insn                       \
                     " %%xmm1,%%xmm0\n\tstmxcsr %[flags]\n\tlea -128(%%rsp),%%rsp\n\tpushfq\n\tpopq %[out]\n\t"        \
                     "lea 128(%%rsp),%%rsp"                                                                            \
                     : [out] "=r"(result.lo), [flags] "=m"(flags)                                                      \
                     : [mode] "m"(mode), [in] "m"(x), [other] "m"(y)                                                   \
                     : "memory", "cc", "xmm0", "xmm1")

enum {
    ADDSD,
    SUBSD,
    MULSD,
    DIVSD,
    SQRTSD,
    ADDSS,
    SUBSS,
    MULSS,
    DIVSS,
    SQRTSS,
    ADDSD_M,
    MULSD_M,
    DIVSS_M,
    SQRTSS_M,
    CVTSS2SD,
    CVTSD2SS,
    CVTSI2SD_32,
    CVTSI2SD_64,
    CVTSI2SS_32,
    CVTSI2SS_64,
    CVTTSD2SI_32,
    CVTTSD2SI_64,
    CVTTSS2SI_32,
    CVTTSS2SI_64,
    COMISD,
    UCOMISD,
    COMISS,
    UCOMISS,
    EDGE_OPS
};
static const char *const edge_names[EDGE_OPS] = {
    "addsd",        "subsd",        "mulsd",        "divsd",       "sqrtsd",      "addss",       "subss",
    "mulss",        "divss",        "sqrtss",       "addsd_m",     "mulsd_m",     "divss_m",     "sqrtss_m",
    "cvtss2sd",     "cvtsd2ss",     "cvtsi2sd_32",  "cvtsi2sd_64", "cvtsi2ss_32", "cvtsi2ss_64", "cvttsd2si_32",
    "cvttsd2si_64", "cvttss2si_32", "cvttss2si_64", "comisd",      "ucomisd",     "comiss",      "ucomiss",
};

// Every packed form with a fast path, on edge values placed in each lane, in every MXCSR mode. Results cover all 128
// bits, and the MXCSR flags show whether any lane reached softfloat with the wrong answer.
#define PACKED_FORMS(X)                                                                                                \
    X("sqrtps") X("sqrtpd") X("cvtps2pd") X("cvtdq2pd") X("cmpeqpd") X("cmpltpd") X("cmplepd") X("cmpunordpd")         \
        X("cmpneqpd") X("cmpnltpd") X("cmpnlepd") X("cmpordpd") X("cmpeqsd") X("cmpltsd") X("cmplesd") X("cmpunordsd") \
            X("cmpneqsd") X("cmpnltsd") X("cmpnlesd") X("cmpordsd") X("cmpeqss") X("cmpltss") X("cmpless")             \
                X("cmpunordss") X("cmpneqss") X("cmpnltss") X("cmpnless") X("cmpordss") X("addps") X("addpd")          \
                    X("mulps") X("mulpd") X("divps") X("divpd") X("cmpltps") X("cvtdq2ps") X("cvttps2dq")
#define PACKED_NAME(insn) insn,
static const char *const packed_names[] = {PACKED_FORMS(PACKED_NAME)};
#define PACKED_CASE(insn) \
    case __COUNTER__ - packed_base: \
        VECTOR2(insn);                 \
        break;

enum { packed_base = __COUNTER__ + 1 };
static void packed_op(unsigned op, unsigned mode, xmm x, xmm y, uint64_t *h) {
    xmm result = {0, 0};
    unsigned flags = 0;
    switch (op) { PACKED_FORMS(PACKED_CASE) }
    *h = mix(mix(mix(*h, result.lo), result.hi), flags);
}

static uint64_t edge_lanes32(uint32_t a, uint32_t b) { return (uint64_t)a << 32 | b; }

static void packed_cases(unsigned saved) {
    for (unsigned op = 0; op < COUNT(packed_names); op++)
        for (unsigned controls = 0; controls < 32; controls++) {
            unsigned mode = 0x1f80 | ((controls & 3) << 13) | ((controls & 4) ? 0x40 : 0) |
                            ((controls & 8) ? 0x8000 : 0) | ((controls & 16) ? 0x20 : 0);
            uint64_t h = 1469598103934665603ULL;
            // One special lane among ordinary ones proves that a late lane cannot leave earlier results stored.
            for (size_t i = 0; i < COUNT(edge32); i++)
                for (unsigned lane = 0; lane < 4; lane++) {
                    uint32_t v[4] = {0x3fc00000, 0x40490fdb, 0x3f800000, 0x41200000};
                    uint32_t w[4] = {0x40000000, 0x3f000000, 0xbfc00000, 0x41200000};
                    v[lane] = edge32[i];
                    xmm x, y;
                    x.lo = edge_lanes32(v[1], v[0]);
                    x.hi = edge_lanes32(v[3], v[2]);
                    y.lo = edge_lanes32(w[1], w[0]);
                    y.hi = edge_lanes32(w[3], w[2]);
                    packed_op(op, mode, x, y, &h);
                    packed_op(op, mode, y, x, &h);
                }
            for (size_t i = 0; i < COUNT(edge64); i++)
                for (size_t j = 0; j < COUNT(edge64); j++) {
                    xmm x = {edge64[i], 0x3ff8000000000000ULL}, y = {edge64[j] | (uint64_t)(i & 1) << 63, edge64[i]};
                    packed_op(op, mode, x, y, &h);
                }
            for (unsigned i = 0; i < 2000; i++) {
                xmm x = {next(), next()}, y = {next(), next()};
                if (i & 1) {
                    // Small integers and ordinary floats, so that many lanes take the fast path.
                    x.lo = edge_lanes32((uint32_t)(int32_t)(x.lo >> 48) | 0x3f800000, (uint32_t)x.lo & 0x3fffffff);
                    y.lo = edge_lanes32((uint32_t)y.lo & 0x7fffff | 0x40000000, (uint32_t)(y.lo >> 20) & 0x3fffffff);
                }
                packed_op(op, mode, x, y, &h);
            }
            _mm_setcsr(saved);
            printf("op=%s mxcsr=%04x hash=%016llx\n", packed_names[op], mode, (unsigned long long)h);
        }
}

static void edge_op(int op, unsigned mode, uint64_t av, uint64_t bv, uint32_t a32, uint32_t b32, uint64_t *h) {
    xmm x, y, result = {0, 0};
    unsigned flags = 0;
    const int wide_input = op <= SQRTSD || op == ADDSD_M || op == MULSD_M || op == CVTSD2SS || op == CVTTSD2SI_32 ||
                           op == CVTTSD2SI_64 || op == COMISD || op == UCOMISD;
    x.lo = wide_input ? av : LOWER32 | a32;
    y.lo = wide_input ? bv : LOWER32 | b32;
    x.hi = y.hi = UPPER;
    // Integer sources get raw bits, which reach every sign and magnitude.
    int64_t int64 = (int64_t)bv;
    int32_t int32 = (int32_t)bv;
    switch (op) {
        case ADDSD:
            VECTOR2("addsd");
            break;
        case SUBSD:
            VECTOR2("subsd");
            break;
        case MULSD:
            VECTOR2("mulsd");
            break;
        case DIVSD:
            VECTOR2("divsd");
            break;
        case SQRTSD:
            VECTOR2("sqrtsd");
            break;
        case ADDSS:
            VECTOR2("addss");
            break;
        case SUBSS:
            VECTOR2("subss");
            break;
        case MULSS:
            VECTOR2("mulss");
            break;
        case DIVSS:
            VECTOR2("divss");
            break;
        case SQRTSS:
            VECTOR2("sqrtss");
            break;
        case ADDSD_M:
            VECTORM("addsd", bv);
            break;
        case MULSD_M:
            VECTORM("mulsd", bv);
            break;
        case DIVSS_M:
            VECTORM("divss", b32);
            break;
        case SQRTSS_M:
            VECTORM("sqrtss", b32);
            break;
        case CVTSS2SD:
            VECTOR2("cvtss2sd");
            break;
        case CVTSD2SS:
            VECTOR2("cvtsd2ss");
            break;
        case CVTSI2SD_32:
            FROM_INT("cvtsi2sdl", "k", int32);
            break;
        case CVTSI2SD_64:
            FROM_INT("cvtsi2sdq", "q", int64);
            break;
        case CVTSI2SS_32:
            FROM_INT("cvtsi2ssl", "k", int32);
            break;
        case CVTSI2SS_64:
            FROM_INT("cvtsi2ssq", "q", int64);
            break;
        case CVTTSD2SI_32:
            TO_INT("cvttsd2si", "k");
            break;
        case CVTTSD2SI_64:
            TO_INT("cvttsd2si", "q");
            break;
        case CVTTSS2SI_32:
            TO_INT("cvttss2si", "k");
            break;
        case CVTTSS2SI_64:
            TO_INT("cvttss2si", "q");
            break;
        case COMISD:
            COMPARE("comisd");
            break;
        case UCOMISD:
            COMPARE("ucomisd");
            break;
        case COMISS:
            COMPARE("comiss");
            break;
        default:
            COMPARE("ucomiss");
            break;
    }
    *h = mix(mix(mix(*h, result.lo), result.hi), flags);
}

static void edge_cases(unsigned saved) {
    uint64_t a[COUNT(edge64) * 2 + 400], b[COUNT(edge64) * 2 + 400];
    uint32_t c[COUNT(a)], d[COUNT(a)];
    size_t n = 0;
    for (int sign = 0; sign < 2; sign++)
        for (size_t i = 0; i < COUNT(edge64); i++) {
            a[n] = b[n] = edge64[i] | (uint64_t)sign << 63;
            c[n] = d[n] = edge32[i % COUNT(edge32)] | (uint32_t)sign << 31;
            n++;
        }
    // Boundary-seeking random values, with short significands sometimes so that many results are exact.
    for (; n < COUNT(a); n++) {
        uint64_t r = next();
        a[n] = (next() & 0x800fffffffffffffULL) | (r & 0x7ffULL) << 52;
        b[n] = (next() & 0x800fffffffffffffULL) | (((r >> 11) & 1 ? (r & 0x7ff) : (r >> 16 & 0x7ff)) + (r >> 32 & 7))
                                                      << 52;
        c[n] = ((uint32_t)next() & 0x807fffff) | (uint32_t)(r & 0xff) << 23;
        d[n] = ((uint32_t)next() & 0x807fffff) | (uint32_t)((r >> 40 & 0xff) & 0xff) << 23;
        if (r & (1ULL << 12)) {
            a[n] &= 0xfff0ff0000000000ULL;
            b[n] &= 0xfff0ff0000000000ULL;
            c[n] &= 0xff8ff000;
            d[n] &= 0xff8ff000;
        }
    }
    const size_t edges = COUNT(edge64) * 2;
    for (int op = 0; op < EDGE_OPS; op++)
        for (unsigned controls = 0; controls < 32; ++controls) {
            unsigned mode = 0x1f80 | ((controls & 3) << 13) | ((controls & 4) ? 0x40 : 0) |
                            ((controls & 8) ? 0x8000 : 0) | ((controls & 16) ? 0x20 : 0);
            uint64_t h = 1469598103934665603ULL;
            for (size_t i = 0; i < edges; i++)
                for (size_t j = 0; j < edges; j++)
                    edge_op(op, mode, a[i], b[j], c[i], d[j], &h);
            for (size_t i = edges; i < n; i++)
                edge_op(op, mode, a[i], b[i], c[i], d[i], &h);
            _mm_setcsr(saved);
            printf("op=%s mxcsr=%04x hash=%016llx\n", edge_names[op], mode, (unsigned long long)h);
        }
}

// Immediates must be literal, so each runs through a macro: separate registers, destination as source, and memory.
#define SHUFFLES(imm)                                                                                                  \
    __asm__ volatile("movdqu %[p],%%xmm1\n\tpshufd $" #imm ",%%xmm1,%%xmm0\n\tmovdqu %%xmm0,%[r]"                      \
                     : [r] "=m"(out)                                                                                   \
                     : [p] "m"(in[0])                                                                                  \
                     : "xmm0", "xmm1");                                                                                \
    h = mix(mix(h, out.lo), out.hi);                                                                                   \
    __asm__ volatile("movdqu %[p],%%xmm0\n\tpshufd $" #imm ",%%xmm0,%%xmm0\n\tmovdqu %%xmm0,%[r]"                      \
                     : [r] "=m"(out)                                                                                   \
                     : [p] "m"(in[0])                                                                                  \
                     : "xmm0");                                                                                        \
    h = mix(mix(h, out.lo), out.hi);                                                                                   \
    __asm__ volatile("pshufd $" #imm ",%[q],%%xmm0\n\tmovdqu %%xmm0,%[r]"                                              \
                     : [r] "=m"(out)                                                                                   \
                     : [q] "m"(aligned)                                                                                \
                     : "xmm0");                                                                                        \
    h = mix(mix(h, out.lo), out.hi);                                                                                   \
    __asm__ volatile("movdqu %[p],%%xmm0\n\tmovdqu %[q],%%xmm1\n\tshufps $" #imm                                       \
                     ",%%xmm1,%%xmm0\n\tmovdqu %%xmm0,%[r]"                                                            \
                     : [r] "=m"(out)                                                                                   \
                     : [p] "m"(in[0]), [q] "m"(in[1])                                                                  \
                     : "xmm0", "xmm1");                                                                                \
    h = mix(mix(h, out.lo), out.hi);                                                                                   \
    __asm__ volatile("movdqu %[p],%%xmm0\n\tshufps $" #imm ",%%xmm0,%%xmm0\n\tmovdqu %%xmm0,%[r]"                      \
                     : [r] "=m"(out)                                                                                   \
                     : [p] "m"(in[0])                                                                                  \
                     : "xmm0");                                                                                        \
    h = mix(mix(h, out.lo), out.hi);                                                                                   \
    __asm__ volatile("movdqu %[p],%%xmm0\n\tshufps $" #imm ",%[q],%%xmm0\n\tmovdqu %%xmm0,%[r]"                        \
                     : [r] "=m"(out)                                                                                   \
                     : [p] "m"(in[0]), [q] "m"(aligned)                                                                \
                     : "xmm0");                                                                                        \
    h = mix(mix(h, out.lo), out.hi);
#define SHUFPD(imm)                                                                                                    \
    __asm__ volatile("movdqu %[p],%%xmm0\n\tmovdqu %[q],%%xmm1\n\tshufpd $" #imm                                       \
                     ",%%xmm1,%%xmm0\n\tmovdqu %%xmm0,%[r]"                                                            \
                     : [r] "=m"(out)                                                                                   \
                     : [p] "m"(in[0]), [q] "m"(in[1])                                                                  \
                     : "xmm0", "xmm1");                                                                                \
    h = mix(mix(h, out.lo), out.hi);                                                                                   \
    __asm__ volatile("movdqu %[p],%%xmm0\n\tshufpd $" #imm ",%%xmm0,%%xmm0\n\tmovdqu %%xmm0,%[r]"                      \
                     : [r] "=m"(out)                                                                                   \
                     : [p] "m"(in[0])                                                                                  \
                     : "xmm0");                                                                                        \
    h = mix(mix(h, out.lo), out.hi);

// Forms that take no MXCSR: separate registers, then the destination as its own source, then a memory source.
#define BYTE_FORM(insn)                                                                                                \
    __asm__ volatile("movdqu %[p],%%xmm0\n\tmovdqu %[q],%%xmm1\n\t" insn " %%xmm1,%%xmm0\n\tmovdqu %%xmm0,%[r]"          \
                     : [r] "=m"(out)                                                                                   \
                     : [p] "m"(in[0]), [q] "m"(in[1])                                                                  \
                     : "xmm0", "xmm1");                                                                                \
    h = mix(mix(h, out.lo), out.hi);                                                                                   \
    __asm__ volatile("movdqu %[p],%%xmm0\n\t" insn " %%xmm0,%%xmm0\n\tmovdqu %%xmm0,%[r]"                               \
                     : [r] "=m"(out)                                                                                   \
                     : [p] "m"(in[0])                                                                                  \
                     : "xmm0");                                                                                        \
    h = mix(mix(h, out.lo), out.hi);                                                                                   \
    __asm__ volatile("movdqu %[p],%%xmm0\n\t" insn " %[q],%%xmm0\n\tmovdqu %%xmm0,%[r]"                                 \
                     : [r] "=m"(out)                                                                                   \
                     : [p] "m"(in[0]), [q] "m"(aligned)                                                                \
                     : "xmm0");                                                                                        \
    h = mix(mix(h, out.lo), out.hi);
#define WORD_SHUFFLE(imm)                                                                                              \
    __asm__ volatile("movdqu %[p],%%xmm1\n\tpshuflw $" #imm ",%%xmm1,%%xmm0\n\tpshufhw $" #imm                          \
                     ",%%xmm1,%%xmm2\n\tmovdqu %%xmm0,%[r]\n\tmovdqu %%xmm2,%[s]"                                         \
                     : [r] "=m"(out), [s] "=m"(other)                                                                  \
                     : [p] "m"(in[0])                                                                                  \
                     : "xmm0", "xmm1", "xmm2");                                                                        \
    h = mix(mix(mix(mix(h, out.lo), out.hi), other.lo), other.hi);                                                     \
    __asm__ volatile("movdqu %[p],%%xmm0\n\tpshuflw $" #imm ",%%xmm0,%%xmm0\n\tpshufhw $" #imm                          \
                     ",%%xmm0,%%xmm0\n\tmovdqu %%xmm0,%[r]\n\tpshuflw $" #imm ",%[q],%%xmm1\n\tmovdqu %%xmm1,%[s]"         \
                     : [r] "=m"(out), [s] "=m"(other)                                                                  \
                     : [p] "m"(in[0]), [q] "m"(aligned)                                                                \
                     : "xmm0", "xmm1");                                                                                \
    h = mix(mix(mix(mix(h, out.lo), out.hi), other.lo), other.hi);

static void integer_shuffles(void) {
    const xmm in[2] = {{0x0123456789abcdefULL, 0xfedcba9876543210ULL}, {0x8899aabbccddeeffULL, 0x0011223344556677ULL}};
    static const xmm aligned __attribute__((aligned(16))) = {0x1032547698badcfeULL, 0xefcdab8967452301ULL};
    xmm out, other;
    uint64_t h = 1469598103934665603ULL;
    BYTE_FORM("punpcklbw")
    BYTE_FORM("punpcklwd")
    BYTE_FORM("punpckldq")
    BYTE_FORM("punpcklqdq")
    BYTE_FORM("punpckhbw")
    BYTE_FORM("punpckhwd")
    BYTE_FORM("punpckhdq")
    BYTE_FORM("punpckhqdq")
    BYTE_FORM("unpcklps")
    BYTE_FORM("unpckhps")
    BYTE_FORM("unpcklpd")
    BYTE_FORM("unpckhpd")
    WORD_SHUFFLE(0x00)
    WORD_SHUFFLE(0x1b)
    WORD_SHUFFLE(0x39)
    WORD_SHUFFLE(0x4e)
    WORD_SHUFFLE(0x93)
    WORD_SHUFFLE(0xb1)
    WORD_SHUFFLE(0xd8)
    WORD_SHUFFLE(0xe4)
    WORD_SHUFFLE(0xff)
    printf("op=integer_shuffles hash=%016llx\n", (unsigned long long)h);
    h = 1469598103934665603ULL;
    for (unsigned i = 0; i < 4096; i++) {
        xmm x = {next(), next()};
        uint64_t ps = 0xdeadbeefdeadbeefULL, pd = 0xdeadbeefdeadbeefULL;
        __asm__ volatile("movdqu %[p],%%xmm0\n\tmovmskps %%xmm0,%k[a]\n\tmovmskpd %%xmm0,%k[b]"
                         : [a] "+r"(ps), [b] "+r"(pd)
                         : [p] "m"(x)
                         : "xmm0");
        h = mix(mix(h, ps), pd);
    }
    printf("op=movmsk hash=%016llx\n", (unsigned long long)h);
}

static void shuffles(void) {
    const xmm in[2] = {{0x1111111122222222ULL, 0x3333333344444444ULL}, {0x5555555566666666ULL, 0x7777777788888888ULL}};
    static const xmm aligned __attribute__((aligned(16))) = {0x99999999aaaaaaaaULL, 0xbbbbbbbbccccccccULL};
    xmm out;
    uint64_t h = 1469598103934665603ULL;
    SHUFFLES(0x00)
    SHUFFLES(0x1b) SHUFFLES(0x39) SHUFFLES(0x44) SHUFFLES(0x4e) SHUFFLES(0x93) SHUFFLES(0xb1) SHUFFLES(0xd8)
        SHUFFLES(0xe4) SHUFFLES(0xee) SHUFFLES(0xff) SHUFPD(0) SHUFPD(1) SHUFPD(2) SHUFPD(3)
            printf("op=shuffles hash=%016llx\n", (unsigned long long)h);
}

int main(void) {
    unsigned saved = _mm_getcsr();
    for (unsigned controls = 0; controls < 32; ++controls) {
        unsigned mode = 0x1f80 | ((controls & 3) << 13) | ((controls & 4) ? 0x40 : 0) | ((controls & 8) ? 0x8000 : 0) |
                        ((controls & 16) ? 0x20 : 0);
        uint64_t h = 1469598103934665603ULL;
        for (unsigned i = 0; i < 10000; ++i) {
            uint64_t av = next(), bv = next();
            // Include many ordinary/exact numbers, alongside arbitrary bits.
            if (i & 1) {
                double x = (int)(av & 0xffff) - 32768;
                double y = (int)(bv & 0xffff) - 32768;
                memcpy(&av, &x, 8);
                memcpy(&bv, &y, 8);
            }
            for (unsigned op = 0; op < 4; ++op) {
                double a, b;
                unsigned flags;
                uint64_t result;
                memcpy(&a, &av, 8);
                memcpy(&b, &bv, 8);
                switch (op) {
                    case 0:
                        OP("addsd");
                        break;
                    case 1:
                        OP("subsd");
                        break;
                    case 2:
                        OP("mulsd");
                        break;
                    default:
                        OP("divsd");
                        break;
                }
                memcpy(&result, &a, 8);
                h = mix(mix(h, result), flags);
            }
            for (unsigned op = 0; op < 4; ++op) {
                float a, b;
                unsigned flags;
                uint32_t result;
                uint32_t aa = av, bb = bv;
                memcpy(&a, &aa, 4);
                memcpy(&b, &bb, 4);
                switch (op) {
                    case 0:
                        OP("addss");
                        break;
                    case 1:
                        OP("subss");
                        break;
                    case 2:
                        OP("mulss");
                        break;
                    default:
                        OP("divss");
                        break;
                }
                memcpy(&result, &a, 4);
                h = mix(mix(h, result), flags);
            }
        }
        _mm_setcsr(saved);
        printf("mxcsr=%04x hash=%016llx\n", mode, (unsigned long long)h);
    }
    edge_cases(saved);
    packed_cases(saved);
    shuffles();
    integer_shuffles();
    _mm_setcsr(saved);
}
