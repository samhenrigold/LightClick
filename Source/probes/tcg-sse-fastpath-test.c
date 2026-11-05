// Host-only differential: gen_sse_*_fast's guards and host instructions (emit.c.inc) against QEMU's softfloat, over edge
// cases and random bits. Whenever the guards accept, the result and x86-visible flags must equal softfloat's. The
// guards are transcribed here, so this proves the logic; probes/tcg-sse-differential.c covers the generated code.
//
// Arm64 only. Run scripts/test-sse-fastpath.
#include "qemu/osdep.h"
#include "fpu/softfloat.h"

#define EXPONENT(bits) ((bits) == 64 ? UINT64_C(0xffe0000000000000) : UINT64_C(0xff00000000000000))
#define VISIBLE                                                                                                        \
    (float_flag_invalid | float_flag_divbyzero | float_flag_overflow | float_flag_underflow | float_flag_inexact |     \
     float_flag_input_denormal_used | float_flag_output_denormal_flushed)

static uint64_t magnitude(uint64_t value, int bits) { return value << (65 - bits); }
static bool is_small(uint64_t m, int bits) { return !((m - 1) & EXPONENT(bits)); }
static bool is_special(uint64_t m, int bits) { return !(~m & EXPONENT(bits)); }

enum { ADD, SUB, MUL, DIV, SQRT, NARROW, WIDEN, COMIS, UCOMIS, CVTT32, CVTT64, SI32, SI64, OPS };
static const char *const names[OPS] = {"add", "sub", "mul", "div",   "sqrt", "cvtsd2ss", "cvtss2sd",
                                       "comis", "ucomis", "cvtt32", "cvtt64", "cvtsi32", "cvtsi64"};
static unsigned long accepted[OPS][2], rejected[OPS][2], failures;

#define S_OP(insn) __asm__ volatile(insn " %s0,%s1,%s2" : "=w"(r) : "w"(x), "w"(y))
#define D_OP(insn) __asm__ volatile(insn " %d0,%d1,%d2" : "=w"(r) : "w"(x), "w"(y))

static uint32_t host32(int op, uint32_t a, uint32_t b) {
    float x, y, r;
    uint32_t out;
    memcpy(&x, &a, 4);
    memcpy(&y, &b, 4);
    switch (op) {
        case ADD: S_OP("fadd"); break;
        case SUB: S_OP("fsub"); break;
        case MUL: S_OP("fmul"); break;
        case DIV: S_OP("fdiv"); break;
        default: __asm__ volatile("fsqrt %s0,%s1" : "=w"(r) : "w"(x)); break;
    }
    memcpy(&out, &r, 4);
    return out;
}

static uint64_t host64(int op, uint64_t a, uint64_t b) {
    double x, y, r;
    uint64_t out;
    memcpy(&x, &a, 8);
    memcpy(&y, &b, 8);
    switch (op) {
        case ADD: D_OP("fadd"); break;
        case SUB: D_OP("fsub"); break;
        case MUL: D_OP("fmul"); break;
        case DIV: D_OP("fdiv"); break;
        default: __asm__ volatile("fsqrt %d0,%d1" : "=w"(r) : "w"(x)); break;
    }
    memcpy(&out, &r, 8);
    return out;
}

static float_status sse_status(int sticky) {
    float_status s;
    memset(&s, 0, sizeof(s));
    set_float_2nan_prop_rule(float_2nan_prop_x87, &s);
    set_float_rounding_mode(float_round_nearest_even, &s);
    set_float_exception_flags(sticky ? float_flag_inexact : 0, &s);
    set_float_detect_tininess(float_tininess_after_rounding, &s);
    set_float_default_nan_pattern(0b11000000, &s);
    return s;
}

static void report(const char *name, int bits, uint64_t a, uint64_t b, uint64_t host, uint64_t soft, int flags) {
    if (failures++ < 20)
        printf("FAIL %s/%d a=%llx b=%llx host=%llx softfloat=%llx flags=%x\n", name, bits, (unsigned long long)a,
               (unsigned long long)b, (unsigned long long)host, (unsigned long long)soft, flags);
}

// Sticky inexact is required, so accepted paths must leave exactly that flag behind.
static void check(int op, int bits, uint64_t host, uint64_t soft, const float_status *s, uint64_t a, uint64_t b) {
    int flags = get_float_exception_flags(s) & VISIBLE;
    if (host != soft || flags != float_flag_inexact)
        report(names[op], bits, a, b, host, soft, flags);
}

static void arithmetic(int op, int bits, uint64_t a, uint64_t b) {
    uint64_t a2 = magnitude(a, bits), b2 = magnitude(b, bits), r, r2, soft;
    bool unary = op == SQRT;
    float_status s = sse_status(1);
    if (is_small(a2, bits) || (!unary && is_small(b2, bits))) {
        rejected[op][bits == 64]++;
        return;
    }
    r = bits == 64 ? host64(op, a, b) : host32(op, (uint32_t)a, (uint32_t)b);
    r2 = magnitude(r, bits);
    if (is_special(r2, bits) || is_small(r2, bits) || (op == MUL && !r2 && a2 && b2) || (op == DIV && !r2 && a2)) {
        rejected[op][bits == 64]++;
        return;
    }
    accepted[op][bits == 64]++;
    if (bits == 64) {
        soft = op == ADD ? float64_add(a, b, &s) : op == SUB ? float64_sub(a, b, &s) : op == MUL ? float64_mul(a, b, &s) :
               op == DIV ? float64_div(a, b, &s) : float64_sqrt(a, &s);
    } else {
        soft = op == ADD ? float32_add(a, b, &s) : op == SUB ? float32_sub(a, b, &s) : op == MUL ? float32_mul(a, b, &s) :
               op == DIV ? float32_div(a, b, &s) : float32_sqrt(a, &s);
    }
    check(op, bits, r, soft, &s, a, b);
}

static void conversions(uint64_t bits64, uint32_t bits32) {
    // cvtsd2ss: arithmetic guards and result checks.
    {
        uint64_t a2 = magnitude(bits64, 64), r2;
        double in;
        float out;
        uint32_t r;
        memcpy(&in, &bits64, 8);
        if (is_small(a2, 64)) {
            rejected[NARROW][1]++;
        } else {
            __asm__ volatile("fcvt %s0,%d1" : "=w"(out) : "w"(in));
            memcpy(&r, &out, 4);
            r2 = magnitude(r, 32);
            if (is_special(r2, 32) || is_small(r2, 32) || (!r2 && a2)) {
                rejected[NARROW][1]++;
            } else {
                float_status s = sse_status(1);
                accepted[NARROW][1]++;
                check(NARROW, 64, r, float64_to_float32(bits64, &s), &s, bits64, 0);
            }
        }
    }
    // cvtss2sd: no guard, and it must raise nothing, even with PE clear.
    {
        uint64_t a2 = magnitude(bits32, 32);
        if (is_small(a2, 32) || is_special(a2, 32)) {
            rejected[WIDEN][0]++;
        } else {
            float in;
            double out;
            uint64_t r;
            float_status s = sse_status(0);
            memcpy(&in, &bits32, 4);
            __asm__ volatile("fcvt %d0,%s1" : "=w"(out) : "w"(in));
            memcpy(&r, &out, 8);
            accepted[WIDEN][0]++;
            uint64_t soft = float32_to_float64(bits32, &s);
            if (r != soft || (get_float_exception_flags(&s) & VISIBLE))
                report("cvtss2sd", 32, bits32, 0, r, soft, get_float_exception_flags(&s));
        }
    }
    // cvtt: integer magnitude bound and denormal test, sticky PE.
    {
        uint64_t a2 = magnitude(bits64, 64);
        if (is_small(a2, 64) || a2 >= UINT64_C(0x83c0000000000000)) {
            rejected[CVTT32][1]++;
        } else {
            double in;
            int32_t r;
            float_status s = sse_status(1);
            memcpy(&in, &bits64, 8);
            __asm__ volatile("fcvtzs %w0,%d1" : "=r"(r) : "w"(in));
            accepted[CVTT32][1]++;
            check(CVTT32, 64, (uint32_t)r, (uint32_t)float64_to_int32_round_to_zero(bits64, &s), &s, bits64, 0);
        }
        if (is_small(a2, 64) || a2 >= UINT64_C(0x87c0000000000000)) {
            rejected[CVTT64][1]++;
        } else {
            double in;
            int64_t r;
            float_status s = sse_status(1);
            memcpy(&in, &bits64, 8);
            __asm__ volatile("fcvtzs %x0,%d1" : "=r"(r) : "w"(in));
            accepted[CVTT64][1]++;
            check(CVTT64, 64, r, float64_to_int64_round_to_zero(bits64, &s), &s, bits64, 0);
        }
        uint64_t b2 = magnitude(bits32, 32);
        if (is_small(b2, 32) || b2 >= UINT64_C(0x9e00000000000000)) {
            rejected[CVTT32][0]++;
        } else {
            float in;
            int32_t r;
            float_status s = sse_status(1);
            memcpy(&in, &bits32, 4);
            __asm__ volatile("fcvtzs %w0,%s1" : "=r"(r) : "w"(in));
            accepted[CVTT32][0]++;
            check(CVTT32, 32, (uint32_t)r, (uint32_t)float32_to_int32_round_to_zero(bits32, &s), &s, bits32, 0);
        }
        if (is_small(b2, 32) || b2 >= UINT64_C(0xbe00000000000000)) {
            rejected[CVTT64][0]++;
        } else {
            float in;
            int64_t r;
            float_status s = sse_status(1);
            memcpy(&in, &bits32, 4);
            __asm__ volatile("fcvtzs %x0,%s1" : "=r"(r) : "w"(in));
            accepted[CVTT64][0]++;
            check(CVTT64, 32, r, float32_to_int64_round_to_zero(bits32, &s), &s, bits32, 0);
        }
    }
    // cvtsi2sd from 32 bits takes no guard at all: exact in every rounding mode, with no flags.
    {
        int32_t in = (int32_t)bits32;
        double out;
        uint64_t r;
        __asm__ volatile("scvtf %d0,%w1" : "=w"(out) : "r"(in));
        memcpy(&r, &out, 8);
        static const FloatRoundMode modes[] = {float_round_nearest_even, float_round_down, float_round_up,
                                               float_round_to_zero};
        for (int m = 0; m < 4; m++) {
            float_status s = sse_status(0);
            set_float_rounding_mode(modes[m], &s);
            uint64_t soft = int32_to_float64(in, &s);
            accepted[SI32][1]++;
            if (r != soft || (get_float_exception_flags(&s) & VISIBLE))
                report("cvtsi2sd", 32, bits32, m, r, soft, get_float_exception_flags(&s));
        }
    }
    // The remaining int-to-float forms can round, so they need nearest and sticky PE.
    {
        int32_t in32 = (int32_t)bits32;
        int64_t in64 = (int64_t)bits64;
        float f;
        double d;
        uint32_t r32;
        uint64_t r64;
        float_status s = sse_status(1);
        __asm__ volatile("scvtf %s0,%w1" : "=w"(f) : "r"(in32));
        memcpy(&r32, &f, 4);
        accepted[SI32][0]++;
        check(SI32, 32, r32, int32_to_float32(in32, &s), &s, bits32, 0);
        s = sse_status(1);
        __asm__ volatile("scvtf %s0,%x1" : "=w"(f) : "r"(in64));
        memcpy(&r32, &f, 4);
        accepted[SI64][0]++;
        check(SI64, 32, r32, int64_to_float32(in64, &s), &s, bits64, 0);
        s = sse_status(1);
        __asm__ volatile("scvtf %d0,%x1" : "=w"(d) : "r"(in64));
        memcpy(&r64, &d, 8);
        accepted[SI64][1]++;
        check(SI64, 64, r64, int64_to_float64(in64, &s), &s, bits64, 0);
    }
}

// Mirrors gen_sse_fp_ordered: the sign moves to bit 63, then sign-magnitude becomes signed.
static int64_t ordered(uint64_t value, int bits) {
    uint64_t top = value << (64 - bits), abs = top & INT64_MAX;
    return (int64_t)top < 0 ? -(int64_t)abs : (int64_t)abs;
}

static void compare(int bits, uint64_t a, uint64_t b) {
    uint64_t a2 = magnitude(a, bits), b2 = magnitude(b, bits), infinity = EXPONENT(bits);
    if (a2 > infinity || b2 > infinity || is_small(a2, bits) || is_small(b2, bits)) {
        rejected[COMIS][bits == 64]++;
        return;
    }
    int64_t x = ordered(a, bits), y = ordered(b, bits);
    int fast = x < y ? float_relation_less : x == y ? float_relation_equal : float_relation_greater;
    // No guard, so these must raise nothing even with every flag clear.
    float_status s = sse_status(0), q = sse_status(0);
    int soft = bits == 64 ? float64_compare(a, b, &s) : float32_compare(a, b, &s);
    int quiet = bits == 64 ? float64_compare_quiet(a, b, &q) : float32_compare_quiet(a, b, &q);
    accepted[COMIS][bits == 64]++;
    if (fast != soft || fast != quiet || (get_float_exception_flags(&s) & VISIBLE) ||
        (get_float_exception_flags(&q) & VISIBLE))
        report("comis", bits, a, b, fast, soft, get_float_exception_flags(&s));
}

static uint64_t rng = UINT64_C(0x9e3779b97f4a7c15);
static uint64_t next(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}

static void pair(uint64_t a, uint64_t b, uint32_t c, uint32_t d) {
    for (int op = ADD; op <= DIV; op++) {
        arithmetic(op, 64, a, b);
        arithmetic(op, 32, c, d);
    }
    arithmetic(SQRT, 64, a, 0);
    arithmetic(SQRT, 32, c, 0);
    conversions(a, c);
    compare(64, a, b);
    compare(32, c, d);
}

int main(int argc, char **argv) {
    static const uint64_t doubles[] = {
        0, 1, 2, UINT64_C(0x000fffffffffffff), UINT64_C(0x0010000000000000), UINT64_C(0x0010000000000001),
        UINT64_C(0x001fffffffffffff), UINT64_C(0x0020000000000000), UINT64_C(0x1ff0000000000000),
        UINT64_C(0x2000000000000000), UINT64_C(0x3fe0000000000000), UINT64_C(0x3fefffffffffffff),
        UINT64_C(0x3ff0000000000000), UINT64_C(0x3ff0000000000001), UINT64_C(0x3ff8000000000000),
        UINT64_C(0x4000000000000000), UINT64_C(0x4330000000000000), UINT64_C(0x4340000000000001),
        UINT64_C(0x41dfffffffc00000), UINT64_C(0x41dfffffffffffff), UINT64_C(0x41e0000000000000),
        UINT64_C(0x41e0000000200000), UINT64_C(0x43dfffffffffffff), UINT64_C(0x43e0000000000000),
        UINT64_C(0x36a0000000000000), UINT64_C(0x3690000000000000), UINT64_C(0x47efffffe0000000),
        UINT64_C(0x47effffff0000000), UINT64_C(0x47f0000000000000), UINT64_C(0x3810000000000000),
        UINT64_C(0x380fffffffffffff), UINT64_C(0x380ffffff0000000), UINT64_C(0x7fdfffffffffffff),
        UINT64_C(0x7fefffffffffffff), UINT64_C(0x7ff0000000000000), UINT64_C(0x7ff0000000000001),
        UINT64_C(0x7ff8000000000000), UINT64_C(0x7fffffffffffffff),
    };
    static const uint32_t floats[] = {
        0, 1, 2, 0x007fffff, 0x00800000, 0x00800001, 0x00ffffff, 0x01000000, 0x1f800000, 0x20000000, 0x3f000000,
        0x3f7fffff, 0x3f800000, 0x3f800001, 0x3fc00000, 0x40000000, 0x4b000000, 0x4b800001, 0x4effffff, 0x4f000000,
        0x4f000001, 0x5effffff, 0x5f000000, 0x7f7fffff, 0x7f800000, 0x7f800001, 0x7fc00000, 0x7fffffff,
    };
    const size_t nd = sizeof(doubles) / sizeof(*doubles), nf = sizeof(floats) / sizeof(*floats);
    unsigned long rounds = argc > 1 ? strtoul(argv[1], NULL, 0) : 3000000;

    for (int signs = 0; signs < 4; signs++) {
        uint64_t sa = (uint64_t)(signs & 1) << 63, sb = (uint64_t)(signs >> 1) << 63;
        for (size_t i = 0; i < nd; i++)
            for (size_t j = 0; j < nd; j++) {
                uint32_t c = floats[i % nf] | (uint32_t)(sa >> 32), d = floats[j % nf] | (uint32_t)(sb >> 32);
                pair(doubles[i] | sa, doubles[j] | sb, c, d);
            }
        // The arrays differ in length, so also cross every float pair.
        for (size_t i = 0; i < nf; i++)
            for (size_t j = 0; j < nf; j++)
                pair(doubles[i] | sa, doubles[j] | sb, floats[i] | (uint32_t)(sa >> 32), floats[j] | (uint32_t)(sb >> 32));
    }
    for (unsigned long i = 0; i < rounds; i++) {
        uint64_t a = next(), b = next(), r = next();
        // Half the time steer exponents close together or to the extremes, where results land near the boundaries.
        if (r & 1)
            b = (b & UINT64_C(0x800fffffffffffff)) | ((a & UINT64_C(0x7ff0000000000000)) + ((r >> 8 & 0x7f) << 52));
        if (r & 2)
            a = (a & UINT64_C(0x800fffffffffffff)) | ((r >> 16 & 0x3f) << 52);
        if (r & 4)
            b = (b & UINT64_C(0x800fffffffffffff)) | ((UINT64_C(0x7ff) - (r >> 24 & 0x3f)) << 52);
        uint32_t c = next(), d = next();
        if (r & 8)
            d = (d & 0x807fffff) | ((c & 0x7f800000) + ((uint32_t)(r >> 32 & 0xf) << 23));
        if (r & 16)
            c = (c & 0x807fffff) | ((uint32_t)(r >> 40 & 0x1f) << 23);
        if (r & 32)
            d = (d & 0x807fffff) | ((0xffu - (uint32_t)(r >> 48 & 0x1f)) << 23);
        // Exact results matter too, since flags differ there: use short significands sometimes.
        if (r & 64) {
            a &= UINT64_C(0xfff0ff0000000000);
            b &= UINT64_C(0xfff0ff0000000000);
            c &= 0xff8ff000;
            d &= 0xff8ff000;
        }
        pair(a, b, c, d);
    }

    for (int op = 0; op < OPS; op++) {
        if (op == UCOMIS)
            continue;
        printf("%-9s f32 accepted %10lu rejected %10lu | f64 accepted %10lu rejected %10lu\n", names[op],
               accepted[op][0], rejected[op][0], accepted[op][1], rejected[op][1]);
    }
    // A guard that rejects everything would pass trivially.
    for (int op = 0; op < OPS; op++)
        for (int wide = 0; wide < 2; wide++) {
            bool applicable = op != UCOMIS && !(op == NARROW && !wide) && !(op == WIDEN && wide);
            if (applicable && !accepted[op][wide]) {
                printf("FAIL %s width %d never accepted\n", names[op], wide);
                failures++;
            }
        }
    printf(failures ? "FAILED %lu\n" : "ok\n", failures);
    return failures != 0;
}
