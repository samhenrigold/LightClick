// Minimal x86-64 to AArch64 translator running its output inside an HVF VM at EL0.
// See DESIGN.md. Standalone probe: compile with build.sh, never linked into the app.
//
// x86 regs are pinned: rax,rcx,rdx,rbx,rsp,rbp,rsi,rdi,r8-r15 = x0-x15. x16,x17,x20,x22,x23,x24 are scratch,
// x19 is the indirect-branch table, x21 holds the last flag-setting result (the cost of lazy PF is paid; no
// consumer is translated). NZCV is canonical with C = !CF, the polarity ARM's subs produces.
#include <Hypervisor/Hypervisor.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "plan.h"

typedef uint8_t u8;
typedef uint32_t u32;
typedef int64_t i64;

#define CHECK(call)                                                                                                    \
    do {                                                                                                               \
        hv_return_t r_ = (call);                                                                                       \
        if (r_) {                                                                                                      \
            fprintf(stderr, "%s failed: 0x%x\n", #call, r_);                                                           \
            exit(1);                                                                                                   \
        }                                                                                                              \
    } while (0)
#define DIE(...)                                                                                                       \
    do {                                                                                                               \
        fprintf(stderr, "spike stop: " __VA_ARGS__);                                                                   \
        fprintf(stderr, "\n");                                                                                         \
        exit(2);                                                                                                       \
    } while (0)

// Guest layout. x86 physical memory is IPA 0..RAM_SIZE. Private memory (vectors, code cache, tables) sits in
// the x86 non-canonical hole, bit 47 set in TTBR0, so it never collides with a canonical x86 address.
#define RAM_SIZE (192ULL << 20)
#define PRIV_IPA 0x40000000ULL
#define PRIV_SIZE (64ULL << 20)
#define HOLE_VA 0xF00000000000ULL
#define STUBS_OFF 0ULL
#define HASH_OFF (2ULL << 20)
#define LIT_OFF (4ULL << 20)
#define CC_OFF (8ULL << 20)
#define CC_SIZE (16ULL << 20)
#define PT_OFF (24ULL << 20) // the first pages are the static hole tables, then the shadow pool
#define HASH_BITS 12
#define PTE_VALID 3ULL
#define PTE_AF (1ULL << 10)
#define PTE_SH (3ULL << 8)
#define PTE_NG (1ULL << 11)
#define PTE_UXN (1ULL << 54)
#define PTE_PXN (1ULL << 53)
#define AP_EL0_RW (1ULL << 6)
#define AP_RO (3ULL << 6)
#define PA_MASK 0x0000FFFFFFFFF000ULL
#define X86_P 1ULL
#define X86_RW 2ULL
#define X86_US 4ULL
#define X86_A 0x20ULL
#define X86_D 0x40ULL
#define X86_NX (1ULL << 63)

enum { EXIT_DIRECT = 1, EXIT_TAKEN, EXIT_IND, EXIT_HLT, EXIT_CR3, EXIT_ERR, EXIT_LITMUS, EXIT_CR3_FAST = 0x8000 };

// Vector table and EL1 helpers, assembled here and copied into the guest. Never executed on the host.
__asm__(
    ".text\n.p2align 11\n.globl _guest_stubs\n_guest_stubs:\n"
    ".set vi, 0\n.rept 8\n.p2align 7\nhvc #vi\n.set vi, vi+1\n.endr\n"
    // 0x400: synchronous exception from EL0. CR3 fast path stays in the guest, all else reports via HVC.
    ".p2align 7\n"
    "msr tpidr_el1, x17\n mrs x17, esr_el1\n ubfx x17, x17, #26, #6\n cmp x17, #0x15\n b.ne 1f\n"
    "mrs x17, esr_el1\n tbz x17, #15, 1f\n ubfx x17, x16, #12, #4\n adr x16, Lcr3tab\n"
    "ldr x16, [x16, x17, lsl #3]\n msr ttbr0_el1, x16\n mrs x17, tpidr_el1\n eret\n"
    "1: mrs x17, tpidr_el1\n hvc #8\n"
    ".set vi, 9\n.rept 7\n.p2align 7\nhvc #vi\n.set vi, vi+1\n.endr\n"
    ".p2align 11\n" // +0x800
    "_guest_eret: eret\n"
    ".p2align 4\n_guest_tlbi_all: tlbi vmalle1\n dsb nsh\n isb\n eret\n"
    ".p2align 4\n_guest_tlbi_va: msr tpidr_el1, x16\n mrs x16, tpidrro_el0\n tlbi vale1, x16\n"
    "mrs x16, tpidr_el1\n dsb nsh\n isb\n eret\n"
    ".p2align 10\nLcr3tab:\n_guest_cr3tab: .space 128\n" // +0xC00, host writes the live copy
    // +0x1000: message-passing litmus at EL0. x0 data, x1 flag, x2 iterations; the reader counts violations in x3.
    ".p2align 12\n_guest_lit_writer: mov x3, #1\n"
    "2: str x3, [x0]\n str x3, [x1]\n add x3, x3, #1\n cmp x3, x2\n b.ne 2b\n svc #7\n"
    ".p2align 4\n_guest_lit_reader: mov x3, #0\n mov x5, #0\n"
    "3: ldr x4, [x1]\n ldr x6, [x0]\n cmp x6, x4\n cinc x3, x3, lo\n add x5, x5, #1\n cmp x5, x2\n b.ne 3b\n svc #7\n"
    // SPIKE_EL2: every exception reaching virtual EL2 goes on to the host as the usual report. HVC at vEL2 would only re-enter vEL2.
    ".p2align 11\n_guest_vel2_vectors:\n.rept 16\n.p2align 7\nsmc #8\n.endr\n"
    ".p2align 12\n_guest_stubs_end:\n");
extern char guest_stubs[], guest_stubs_end[], guest_eret[], guest_tlbi_all[], guest_tlbi_va[], guest_cr3tab[],
    guest_lit_writer[], guest_lit_reader[], guest_vel2_vectors[];
#define STUB_VA(sym) (HOLE_VA + STUBS_OFF + (u64)((sym) - guest_stubs))

static u8 *ram, *priv;
static hv_vcpu_t vcpu;
static hv_vcpu_exit_t *vexit;
static double tick_ns;
static double now(void) { return mach_absolute_time() * tick_ns; }
static u64 el2_s2_root; // non-zero under SPIKE_EL2: translated code runs under a guest stage 2 and a stub vEL2

// ---- AArch64 encoders ----
static u32 *cc_base, *cc;
static inline void E(u32 v) { *cc++ = v; }
#define S0 16
#define S1 17
#define AD 20
#define RS 22
#define S2 23
#define S3 24
#define PF 21
#define XZR 31

static void add_imm(int sf, int sub, int s, int rd, int rn, u32 imm) {
    E((u32)sf << 31 | sub << 30 | s << 29 | 0x11u << 24 | imm << 10 | rn << 5 | rd);
}
static void add_reg(int sf, int sub, int s, int rd, int rn, int rm, int lsl) {
    E((u32)sf << 31 | sub << 30 | s << 29 | 0x0Bu << 24 | rm << 16 | lsl << 10 | rn << 5 | rd);
}
static void logic_reg(int sf, int opc, int n, int rd, int rn, int rm) {
    E((u32)sf << 31 | opc << 29 | 0x0Au << 24 | n << 21 | rm << 16 | rn << 5 | rd);
}
static void mov_reg(int sf, int rd, int rm) { logic_reg(sf, 1, 0, rd, XZR, rm); }
static void bitfield(int sf, int opc, int rd, int rn, int immr, int imms) {
    E((u32)sf << 31 | opc << 29 | 0x26u << 23 | sf << 22 | immr << 16 | imms << 10 | rn << 5 | rd);
}
static void lsl_imm(int sf, int rd, int rn, int n) {
    int sz = sf ? 64 : 32;
    bitfield(sf, 2, rd, rn, (sz - n) % sz, sz - 1 - n);
}
static void bfi_low(int rd, int rn, int bits) { bitfield(1, 1, rd, rn, 0, bits - 1); }
static void var_shift(int sf, int op2, int rd, int rn, int rm) {
    E(0x1AC02000u | (u32)sf << 31 | rm << 16 | op2 << 10 | rn << 5 | rd);
}
static void csel(int sf, int rd, int rn, int rm, int cond) {
    E(0x1A800000u | (u32)sf << 31 | rm << 16 | cond << 12 | rn << 5 | rd);
}
static void cset(int rd, int cond) { // csinc rd, xzr, xzr, !cond
    E(0x9A800400u | XZR << 16 | (cond ^ 1) << 12 | XZR << 5 | rd);
}
static void movimm(int rd, u64 v) {
    int zeros = 0, ones = 0;
    for (int i = 0; i < 4; i++) {
        u32 h = (v >> (i * 16)) & 0xffff;
        zeros += h == 0;
        ones += h == 0xffff;
    }
    if (zeros == 4) {
        mov_reg(1, rd, XZR);
        return;
    }
    bool inv = ones > zeros, first = true;
    for (int i = 0; i < 4; i++) {
        u32 h = (v >> (i * 16)) & 0xffff;
        if (h == (inv ? 0xffffu : 0))
            continue;
        if (first)
            E((inv ? 0x92800000u : 0xD2800000u) | i << 21 | (inv ? ~h & 0xffff : h) << 5 | rd);
        else
            E(0xF2800000u | i << 21 | h << 5 | rd);
        first = false;
    }
    if (first)
        E(0x92800000u | rd); // all ones
}
static void cfinv(void) { E(0xD500401Fu); }
static void rmif(int rn, int shift, int mask) { E(0xBA000400u | shift << 15 | rn << 5 | mask); }
static void svc(u32 imm) { E(0xD4000001u | imm << 5); }
static void cbz(int nz, int sf, int rt, int words) {
    E((u32)sf << 31 | 0x34000000u | nz << 24 | ((u32)words & 0x7ffff) << 5 | rt);
}

static bool logimm(u64 v, int sf, u32 *out) {
    if (!sf)
        v = (v & 0xffffffffULL) | (v << 32);
    if (v == 0 || v == ~0ULL)
        return false;
    int size = 64;
    while (size > 2) {
        int half = size / 2;
        u64 mask = (1ULL << half) - 1;
        if ((v & mask) != ((v >> half) & mask))
            break;
        size = half;
    }
    u64 mask = size == 64 ? ~0ULL : (1ULL << size) - 1, elt = v & mask;
    for (int r = 0; r < size; r++) {
        u64 rot = r ? ((elt >> r) | (elt << (size - r))) & mask : elt;
        if ((rot & (rot + 1)) == 0) {
            int ones = __builtin_popcountll(rot), immr = (size - r) % size;
            int imms = ((~(size * 2 - 1)) & 0x3f) | (ones - 1);
            *out = (size == 64) << 22 | immr << 16 | imms << 10;
            return true;
        }
    }
    return false;
}

// ---- x86 decoder ----
enum { F_V = 1, F_C = 2, F_Z = 4, F_N = 8, F_ALL = 15 };
enum { ALU_ADD = 0, ALU_OR = 1, ALU_AND = 4, ALU_SUB = 5, ALU_XOR = 6, ALU_CMP = 7, ALU_TEST = 8 };
enum { SH_SHL = 4, SH_SHR = 5, SH_SAR = 7 };
enum {
    OP_BAD,
    OP_NOP,
    OP_ALU,
    OP_MOV,
    OP_LEA,
    OP_MOVZX,
    OP_MOVSX,
    OP_PUSH,
    OP_POP,
    OP_SHIFT,
    OP_NEG,
    OP_NOT,
    OP_DIV,
    OP_IMUL,
    OP_CMOV,
    OP_SETCC,
    OP_JCC,
    OP_JMP,
    OP_CALL,
    OP_JMPI,
    OP_CALLI,
    OP_RET,
    OP_HLT,
    OP_CR3
};
typedef struct {
    u8 op, sz, srcsz, alu, cc, rm, reg, base, index, scale, reads, writes;
    bool rm_reg; // rm is a register, not memory
    bool to_reg; // the destination is `reg`, the source is rm or imm
    bool has_imm, by_cl, preserve_c;
    bool riprel, no_base, no_index;
    i64 disp, imm;
    u64 rip, next, target;
    const char *why;
} Insn;

static const signed char x86_to_arm_cc[16] = {6, 7, 3, 2, 0, 1, 9, 8, 4, 5, -1, -1, 11, 10, 13, 12};
static const u8 cc_reads[16] = {F_V, F_V, F_C,   F_C,   F_Z,       F_Z,       F_C | F_Z,       F_C | F_Z,
                                F_N, F_N, F_ALL, F_ALL, F_N | F_V, F_N | F_V, F_N | F_V | F_Z, F_N | F_V | F_Z};

static u64 cur_cr3;

// Software x86 walk: returns the leaf PTE pointer, or NULL if not present.
static u64 *x86_walk(u64 cr3, u64 va, u64 *gpa) {
    u64 table = cr3;
    for (int level = 3; level >= 0; level--) {
        u64 *e = (u64 *)(ram + table + (((va >> (12 + 9 * level)) & 0x1ff) * 8));
        if (!(*e & X86_P))
            return NULL;
        if (!level) {
            *gpa = (*e & PA_MASK) | (va & 0xfff);
            return e;
        }
        table = *e & PA_MASK;
    }
    return NULL;
}
static bool fetch(u64 va, u8 *out, int n) {
    for (int i = 0; i < n; i++) {
        u64 gpa;
        if (!x86_walk(cur_cr3, va + i, &gpa))
            return i > 0;
        out[i] = ram[gpa];
    }
    return true;
}

static void set_bad(Insn *in, const char *why) {
    in->op = OP_BAD;
    in->why = why;
    in->reads = F_ALL;
    in->writes = 0;
}

// Decodes one instruction. Anything outside the subset becomes OP_BAD, which stops at runtime only if reached.
static void decode(u64 rip, Insn *in) {
    u8 b[16] = {0};
    memset(in, 0, sizeof *in);
    in->rip = rip;
    in->no_index = true;
    if (!fetch(rip, b, 15)) {
        set_bad(in, "instruction fetch from unmapped page");
        in->next = rip + 1;
        return;
    }
    const u8 *p = b;
    int rex = 0, sz = 4;
    bool has_rex = false;
    for (;; p++) {
        if (*p == 0x66)
            sz = 2;
        else if (*p == 0x2E)
            continue; // branch hint or the padding in nopw %cs:
        else if (*p == 0x64 || *p == 0x65) {
            set_bad(in, "fs/gs segment override");
            in->next = rip + 1;
            return;
        } else if (*p == 0x67) {
            set_bad(in, "address-size override");
            in->next = rip + 1;
            return;
        } else if (*p == 0xF0 || *p == 0xF2 || *p == 0xF3) {
            set_bad(in, "lock/rep prefix");
            in->next = rip + 1;
            return;
        } else
            break;
    }
    if ((*p & 0xF0) == 0x40) {
        rex = *p++ & 15;
        has_rex = true;
    }
    if (rex & 8)
        sz = 8;
    int w = sz;
    u8 opc = *p++;
    bool two = false;
    if (opc == 0x0F) {
        two = true;
        opc = *p++;
    }

#define MODRM()                                                                                                        \
    do {                                                                                                               \
        u8 m_ = *p++;                                                                                                  \
        int mod_ = m_ >> 6, rm_ = m_ & 7;                                                                              \
        in->reg = ((m_ >> 3) & 7) | ((rex & 4) << 1);                                                                  \
        if (mod_ == 3) {                                                                                               \
            in->rm_reg = true;                                                                                         \
            in->rm = rm_ | ((rex & 1) << 3);                                                                           \
            break;                                                                                                     \
        }                                                                                                              \
        if (rm_ == 4) {                                                                                                \
            u8 s_ = *p++;                                                                                              \
            int idx_ = ((s_ >> 3) & 7) | ((rex & 2) << 2), bs_ = s_ & 7;                                               \
            if (idx_ != 4) {                                                                                           \
                in->no_index = false;                                                                                  \
                in->index = idx_;                                                                                      \
                in->scale = s_ >> 6;                                                                                   \
            }                                                                                                          \
            if (bs_ == 5 && mod_ == 0) {                                                                               \
                in->no_base = true;                                                                                    \
                in->disp = *(int32_t *)p;                                                                              \
                p += 4;                                                                                                \
            } else                                                                                                     \
                in->base = bs_ | ((rex & 1) << 3);                                                                     \
        } else if (rm_ == 5 && mod_ == 0) {                                                                            \
            in->riprel = true;                                                                                         \
            in->disp = *(int32_t *)p;                                                                                  \
            p += 4;                                                                                                    \
        } else                                                                                                         \
            in->base = rm_ | ((rex & 1) << 3);                                                                         \
        if (mod_ == 1) {                                                                                               \
            in->disp = *(int8_t *)p;                                                                                   \
            p++;                                                                                                       \
        } else if (mod_ == 2) {                                                                                        \
            in->disp = *(int32_t *)p;                                                                                  \
            p += 4;                                                                                                    \
        }                                                                                                              \
    } while (0)
#define IMM(n)                                                                                                         \
    do {                                                                                                               \
        in->has_imm = true;                                                                                            \
        if ((n) == 1) {                                                                                                \
            in->imm = *(int8_t *)p;                                                                                    \
            p += 1;                                                                                                    \
        } else if ((n) == 2) {                                                                                         \
            in->imm = *(int16_t *)p;                                                                                   \
            p += 2;                                                                                                    \
        } else if ((n) == 4) {                                                                                         \
            in->imm = *(int32_t *)p;                                                                                   \
            p += 4;                                                                                                    \
        } else {                                                                                                       \
            in->imm = *(i64 *)p;                                                                                       \
            p += 8;                                                                                                    \
        }                                                                                                              \
    } while (0)
#define IMMSZ(s) ((s) == 8 ? 4 : (s))
// Without REX, byte registers 4-7 mean ah,ch,dh,bh, which the pinned mapping cannot name directly.
#define HIGH8(r) (w == 1 && !has_rex && (r) >= 4 && (r) <= 7)

    if (!two && opc < 0x40 && (opc & 7) < 6) {
        int alu = opc >> 3, form = opc & 7;
        if (alu == 2 || alu == 3) {
            set_bad(in, "adc/sbb outside the subset");
            goto done;
        }
        in->op = OP_ALU;
        in->alu = alu;
        in->writes = F_ALL;
        if (form < 4) {
            w = (form & 1) ? sz : 1;
            MODRM();
            in->to_reg = form >= 2;
        } else {
            w = (form & 1) ? sz : 1;
            in->rm_reg = true;
            in->rm = 0;
            in->reg = 0;
            IMM(IMMSZ(w));
        }
    } else if (!two && (opc == 0x80 || opc == 0x81 || opc == 0x83)) {
        w = opc == 0x80 ? 1 : sz;
        MODRM();
        int alu = in->reg & 7;
        if (alu == 2 || alu == 3) {
            set_bad(in, "adc/sbb outside the subset");
            goto done;
        }
        in->op = OP_ALU;
        in->alu = alu;
        in->writes = F_ALL;
        IMM(opc == 0x81 ? IMMSZ(w) : 1);
    } else if (!two && (opc == 0x84 || opc == 0x85)) {
        w = opc == 0x84 ? 1 : sz;
        MODRM();
        in->op = OP_ALU;
        in->alu = ALU_TEST;
        in->writes = F_ALL;
    } else if (!two && (opc == 0xA8 || opc == 0xA9)) {
        w = opc == 0xA8 ? 1 : sz;
        in->rm_reg = true;
        IMM(IMMSZ(w));
        in->op = OP_ALU;
        in->alu = ALU_TEST;
        in->writes = F_ALL;
    } else if (!two && (opc == 0xF6 || opc == 0xF7)) {
        w = opc == 0xF6 ? 1 : sz;
        MODRM();
        int sub = in->reg & 7;
        if (sub == 0) {
            in->op = OP_ALU;
            in->alu = ALU_TEST;
            in->writes = F_ALL;
            IMM(IMMSZ(w));
        } else if (sub == 2)
            in->op = OP_NOT;
        else if (sub == 3) {
            in->op = OP_NEG;
            in->writes = F_ALL;
        } else if (sub == 6 && w == 8)
            in->op = OP_DIV;
        else {
            set_bad(in, "mul/imul/idiv/narrow div outside the subset");
            goto done;
        }
    } else if (!two && opc == 0xFF) {
        MODRM();
        int sub = in->reg & 7;
        if (sub == 0 || sub == 1) {
            w = sz;
            in->op = OP_ALU;
            in->alu = sub ? ALU_SUB : ALU_ADD;
            in->preserve_c = true;
            in->has_imm = true;
            in->imm = 1;
            in->writes = F_N | F_Z | F_V;
        } else if (sub == 2) {
            w = 8;
            in->op = OP_CALLI;
        } else if (sub == 4) {
            w = 8;
            in->op = OP_JMPI;
        } else if (sub == 6) {
            set_bad(in, "push r/m outside the subset");
            goto done;
        } else {
            set_bad(in, "FF group entry outside the subset");
            goto done;
        }
    } else if (!two && (opc == 0x88 || opc == 0x89 || opc == 0x8A || opc == 0x8B)) {
        w = (opc & 1) ? sz : 1;
        MODRM();
        in->op = OP_MOV;
        in->to_reg = opc & 2;
    } else if (!two && (opc == 0xC6 || opc == 0xC7)) {
        w = opc == 0xC6 ? 1 : sz;
        MODRM();
        in->op = OP_MOV;
        IMM(IMMSZ(w));
    } else if (!two && opc >= 0xB8 && opc <= 0xBF) {
        in->op = OP_MOV;
        in->to_reg = true;
        in->rm_reg = true;
        in->reg = (opc & 7) | ((rex & 1) << 3);
        IMM(sz);
    } else if (!two && opc == 0x8D) {
        MODRM();
        if (in->rm_reg || sz < 4) {
            set_bad(in, "invalid lea");
            goto done;
        }
        in->op = OP_LEA;
    } else if (!two && opc == 0x63) {
        MODRM();
        in->op = OP_MOVSX;
        in->srcsz = 4;
    } else if (two && (opc == 0xB6 || opc == 0xB7 || opc == 0xBE || opc == 0xBF)) {
        MODRM();
        if (sz < 4) {
            set_bad(in, "16-bit movzx/movsx destination");
            goto done;
        }
        in->op = opc < 0xBE ? OP_MOVZX : OP_MOVSX;
        in->srcsz = (opc & 1) ? 2 : 1;
        if (in->srcsz == 1 && !has_rex && in->rm_reg && in->rm >= 4 && in->rm <= 7) {
            set_bad(in, "ah/ch/dh/bh operand");
            goto done;
        }
    } else if (!two && opc >= 0x50 && opc <= 0x5F) {
        in->op = opc < 0x58 ? OP_PUSH : OP_POP;
        in->reg = (opc & 7) | ((rex & 1) << 3);
        w = 8;
        if (in->reg == 4) {
            set_bad(in, "push/pop rsp");
            goto done;
        }
    } else if (!two && (opc == 0xC1 || opc == 0xD3 || opc == 0xD1)) {
        MODRM();
        int k = in->reg & 7;
        if (w < 4 || (k != SH_SHL && k != SH_SHR && k != SH_SAR)) {
            set_bad(in, "shift outside the subset");
            goto done;
        }
        in->op = OP_SHIFT;
        in->alu = k;
        if (opc == 0xD3)
            in->by_cl = true; // flags untouched when the masked count is zero
        else {
            in->has_imm = true;
            if (opc == 0xC1) {
                in->imm = *p++;
            } else
                in->imm = 1;
            in->imm &= w == 8 ? 63 : 31;
            if (in->imm)
                in->writes = F_ALL;
        }
    } else if (two && opc == 0xAF) {
        MODRM();
        if (sz < 4) {
            set_bad(in, "16-bit imul");
            goto done;
        }
        in->op = OP_IMUL;
        in->writes = F_ALL;
    } else if (two && opc >= 0x40 && opc <= 0x4F) {
        MODRM();
        if (sz < 4) {
            set_bad(in, "16-bit cmov");
            goto done;
        }
        in->op = OP_CMOV;
        in->cc = opc & 15;
        in->reads = cc_reads[in->cc];
    } else if (two && opc >= 0x90 && opc <= 0x9F) {
        w = 1;
        MODRM();
        in->op = OP_SETCC;
        in->cc = opc & 15;
        in->reads = cc_reads[in->cc];
    } else if (two && opc >= 0x80 && opc <= 0x8F) {
        in->op = OP_JCC;
        in->cc = opc & 15;
        in->reads = cc_reads[in->cc];
        IMM(4);
    } else if (!two && opc >= 0x70 && opc <= 0x7F) {
        in->op = OP_JCC;
        in->cc = opc & 15;
        in->reads = cc_reads[in->cc];
        IMM(1);
    } else if (!two && opc == 0xE9) {
        in->op = OP_JMP;
        IMM(4);
    } else if (!two && opc == 0xEB) {
        in->op = OP_JMP;
        IMM(1);
    } else if (!two && opc == 0xE8) {
        in->op = OP_CALL;
        IMM(4);
    } else if (!two && opc == 0xC3)
        in->op = OP_RET;
    else if (!two && opc == 0x90)
        in->op = OP_NOP;
    else if (two && opc == 0x1F) {
        MODRM();
        in->op = OP_NOP;
    } else if (!two && opc == 0xF4)
        in->op = OP_HLT;
    else if (two && opc == 0x22) {
        MODRM();
        if ((in->reg & 7) != 3) {
            set_bad(in, "mov to cr other than cr3");
            goto done;
        }
        in->op = OP_CR3;
    } else if (two && opc == 0x0B)
        set_bad(in, "ud2");
    else {
        static char msg[64];
        snprintf(msg, sizeof msg, "untranslated opcode %s%02x", two ? "0f " : "", opc);
        set_bad(in, strdup(msg)); // shortcut: leaks a few bytes per decode, fine in a probe
    }
    if (in->op == OP_ALU || in->op == OP_MOV) {
        if (HIGH8(in->reg) && !(in->has_imm && in->op == OP_ALU && !in->to_reg))
            set_bad(in, "ah/ch/dh/bh operand");
        if (in->rm_reg && HIGH8(in->rm))
            set_bad(in, "ah/ch/dh/bh operand");
    }
    if (in->op == OP_SETCC && in->rm_reg && !has_rex && in->rm >= 4 && in->rm <= 7)
        set_bad(in, "ah/ch/dh/bh operand");
    if ((in->op == OP_JCC || in->op == OP_CMOV || in->op == OP_SETCC) && x86_to_arm_cc[in->cc] < 0)
        set_bad(in, "PF consumer (jp/setp/cmovp) outside the subset");
done:
    in->sz = w;
    in->next = rip + (p - b);
    if (in->op == OP_JCC || in->op == OP_JMP || in->op == OP_CALL)
        in->target = in->next + in->imm;
}

static bool is_terminator(int op) {
    return op == OP_JCC || op == OP_JMP || op == OP_CALL || op == OP_JMPI || op == OP_CALLI || op == OP_RET ||
           op == OP_HLT || op == OP_BAD;
}

// Bounded look-ahead for which flags a successor can read before overwriting them.
static int flags_needed_at(u64 rip, int depth) {
    int need = 0, written = 0;
    for (int i = 0; i < 32; i++) {
        Insn in;
        decode(rip, &in);
        need |= in.reads & ~written;
        written |= in.writes;
        if (written == F_ALL)
            return need;
        if (in.op == OP_JCC) {
            if (!depth)
                return need | (F_ALL & ~written);
            return need | ((flags_needed_at(in.target, depth - 1) | flags_needed_at(in.next, depth - 1)) & ~written);
        }
        if (in.op == OP_JMP || in.op == OP_CALL) {
            rip = in.target;
            continue;
        }
        if (is_terminator(in.op))
            return need | (F_ALL & ~written);
        rip = in.next;
    }
    return need | (F_ALL & ~written);
}

// ---- Block map ----
#define MAP_SIZE (1 << 16)
static struct {
    u64 rip, arm;
} block_map[MAP_SIZE];
static int block_count;
static u64 stat_insns, stat_arm_words;
static u64 map_lookup(u64 rip) {
    for (u32 h = (u32)(rip * 0x9E3779B1u) >> 16;; h = (h + 1) % MAP_SIZE) {
        if (!block_map[h].arm)
            return 0;
        if (block_map[h].rip == rip)
            return block_map[h].arm;
    }
}
static void map_insert(u64 rip, u64 arm) {
    u32 h = (u32)(rip * 0x9E3779B1u) >> 16;
    while (block_map[h].arm)
        h = (h + 1) % MAP_SIZE;
    block_map[h].rip = rip;
    block_map[h].arm = arm;
    block_count++;
}

// Runtime errors are keyed by x86 rip, so an untranslated opcode only stops the run if it is actually reached.
static struct {
    u64 rip;
    const char *why;
} errs[256];
static int err_count;
static void emit_error(u64 rip, const char *why) {
    if (err_count < 256) {
        errs[err_count].rip = rip;
        errs[err_count].why = why;
        err_count++;
    }
    movimm(S0, rip);
    svc(EXIT_ERR);
}

// ---- Emitters ----
typedef struct {
    int base, index, shift;
    i64 imm;
    bool reg_form;
} Addr;

static int log2sz(int sz) { return sz == 8 ? 3 : sz == 4 ? 2 : sz == 2 ? 1 : 0; }

static Addr addr_prepare(const Insn *in, int access) {
    Addr a = {0};
    if (in->riprel) {
        movimm(AD, in->next + in->disp);
        a.base = AD;
        return a;
    }
    if (in->no_base && in->no_index) {
        movimm(AD, in->disp);
        a.base = AD;
        return a;
    }
    if (in->no_base) {
        add_reg(1, 0, 0, AD, XZR, in->index, in->scale);
        a.base = AD;
        a.imm = in->disp;
        return a;
    }
    if (in->no_index) {
        a.base = in->base;
        a.imm = in->disp;
        return a;
    }
    if (!in->disp && (in->scale == 0 || in->scale == log2sz(access))) {
        a.base = in->base;
        a.index = in->index;
        a.shift = in->scale;
        a.reg_form = true;
        return a;
    }
    add_reg(1, 0, 0, AD, in->base, in->index, in->scale);
    a.base = AD;
    a.imm = in->disp;
    return a;
}

// opc: 0 store, 1 load, 2 signed load to 64, 3 signed load to 32.
static void ldst(int opc, int sz, int rt, Addr a) {
    u32 s = log2sz(sz);
    if (a.reg_form) {
        E(s << 30 | 0x38200800u | opc << 22 | a.index << 16 | 3u << 13 | (a.shift ? 1u : 0) << 12 | a.base << 5 | rt);
    } else if (a.imm >= 0 && !(a.imm & (sz - 1)) && (a.imm >> s) < 4096) {
        E(s << 30 | 0x39000000u | opc << 22 | (u32)(a.imm >> s) << 10 | a.base << 5 | rt);
    } else if (a.imm >= -256 && a.imm < 256) {
        E(s << 30 | 0x38000000u | opc << 22 | ((u32)a.imm & 0x1ff) << 12 | a.base << 5 | rt);
    } else {
        movimm(S3, a.imm);
        E(s << 30 | 0x38200800u | opc << 22 | S3 << 16 | 3u << 13 | a.base << 5 | rt);
    }
}

static void write_reg(int sz, int rd, int rn) {
    if (sz >= 4)
        mov_reg(sz == 8, rd, rn);
    else
        bfi_low(rd, rn, sz * 8);
}

static void emit_stub(u64 target, u32 kind) {
    E(0xD2800000u | (target & 0xffff) << 5 | S0);
    E(0xF2A00000u | ((target >> 16) & 0xffff) << 5 | S0);
    E(0xF2C00000u | ((target >> 32) & 0xffff) << 5 | S0);
    E(0xF2E00000u | ((target >> 48) & 0xffff) << 5 | S0);
    svc(kind);
}
#define STUB_WORDS 5

// x16 holds the x86 target. Flag-free so NZCV survives: eor plus cbnz, not cmp.
static void emit_indirect(void) {
    bitfield(1, 2, S1, S0, 0, HASH_BITS - 1);
    add_reg(1, 0, 0, S1, 19, S1, 4);
    E(0xA9400000u | RS << 10 | S1 << 5 | AD); // ldp x20, x22, [x17]
    logic_reg(1, 2, 0, AD, AD, S0);
    cbz(1, 1, AD, 2);
    E(0xD61F0000u | RS << 5);
    svc(EXIT_IND);
}

static void emit_alu(const Insn *in, int live) {
    int sf = in->sz == 8, narrow = in->sz < 4, alu = in->alu;
    bool wb = alu != ALU_CMP && alu != ALU_TEST;
    Addr a = {0};
    int dst, src = XZR;
    bool use_imm = false;
    i64 imm = in->imm;
    if (!in->rm_reg) {
        a = addr_prepare(in, in->sz);
        ldst(1, in->sz, S0, a);
    }
    if (in->to_reg) {
        dst = in->reg;
        src = in->rm_reg ? in->rm : S0;
    } else {
        dst = in->rm_reg ? in->rm : S0;
        if (in->has_imm)
            use_imm = true;
        else
            src = in->reg;
    }
    if (use_imm)
        imm = in->sz == 8 ? imm : (u64)imm & (in->sz == 4 ? 0xffffffffULL : in->sz == 2 ? 0xffffULL : 0xffULL);

    if (in->preserve_c && (live & F_C))
        cset(S2, 2);
    int s = live != 0;

    if (narrow) {
        if (use_imm && live && alu == ALU_TEST && in->sz == 1 && !(imm & 0x80)) { // peephole: no bit 7, N stays right
            u32 enc;
            if (logimm(imm, 0, &enc)) {
                E(0x72000000u | enc | dst << 5 | PF);
                if (live & F_C)
                    cfinv();
                return;
            }
        }
        if (use_imm) {
            movimm(S1, imm);
            src = S1;
        }
        int rd = RS;
        if (live) {
            lsl_imm(0, S1, src, 32 - in->sz * 8);
            lsl_imm(0, S0, dst, 32 - in->sz * 8);
            if (alu == ALU_ADD || alu == ALU_SUB || alu == ALU_CMP)
                add_reg(0, alu != ALU_ADD, 1, rd, S0, S1, 0);
            else if (alu == ALU_AND || alu == ALU_TEST)
                logic_reg(0, 3, 0, rd, S0, S1);
            else {
                logic_reg(0, alu == ALU_OR ? 1 : 2, 0, rd, S0, S1);
                logic_reg(0, 3, 0, rd, rd, rd);
            }
            if ((live & F_C) && alu != ALU_SUB && alu != ALU_CMP)
                cfinv();
            bitfield(0, 2, rd, rd, 32 - in->sz * 8, 31);
            mov_reg(0, PF, rd);
        } else {
            if (alu == ALU_ADD || alu == ALU_SUB || alu == ALU_CMP)
                add_reg(0, alu != ALU_ADD, 0, rd, dst, src, 0);
            else
                logic_reg(0, alu == ALU_OR ? 1 : alu == ALU_XOR ? 2 : 0, 0, rd, dst, src);
        }
        if (wb) {
            if (in->to_reg || in->rm_reg)
                bfi_low(dst, rd, in->sz * 8);
            else
                ldst(0, in->sz, rd, a);
        }
        return;
    }

    int rd = !wb ? (live ? PF : XZR) : (dst == S0 ? RS : dst);
    bool done = false;
    if (use_imm) {
        if (alu == ALU_ADD || alu == ALU_SUB || alu == ALU_CMP) {
            bool sub = alu != ALU_ADD;
            if (imm >= 0 && imm < 4096) {
                add_imm(sf, sub, s, rd, dst, (u32)imm);
                done = true;
            } else if (!s && imm < 0 && imm > -4096) {
                add_imm(sf, !sub, 0, rd, dst, (u32)-imm);
                done = true;
            }
        } else {
            u32 enc;
            if (logimm(imm, sf, &enc)) {
                u32 opc = alu == ALU_OR ? 1 : alu == ALU_XOR ? 2 : s ? 3 : 0;
                E((u32)sf << 31 | opc << 29 | 0x12000000u | enc | dst << 5 | rd);
                done = true;
                if (s && (alu == ALU_OR || alu == ALU_XOR))
                    logic_reg(sf, 3, 0, PF, rd, rd);
            }
        }
        if (!done) {
            movimm(S1, imm);
            src = S1;
        }
    }
    if (!done) {
        if (alu == ALU_ADD || alu == ALU_SUB || alu == ALU_CMP)
            add_reg(sf, alu != ALU_ADD, s, rd, dst, src, 0);
        else if (alu == ALU_AND || alu == ALU_TEST)
            logic_reg(sf, s ? 3 : 0, 0, rd, dst, src);
        else {
            logic_reg(sf, alu == ALU_OR ? 1 : 2, 0, rd, dst, src);
            if (s)
                logic_reg(sf, 3, 0, PF, rd, rd);
        }
    }
    if (s && (alu == ALU_ADD || alu == ALU_SUB))
        mov_reg(sf, PF, rd);
    if (in->preserve_c && (live & F_C))
        rmif(S2, 63, 2);
    else if ((live & F_C) && alu != ALU_SUB && alu != ALU_CMP)
        cfinv();
    if (wb && !in->rm_reg && !in->to_reg)
        ldst(0, in->sz, rd, a);
}

static void emit_shift(const Insn *in, int live) {
    int sf = in->sz == 8, bits = sf ? 64 : 32, kind = in->alu;
    int dst = in->rm_reg ? in->rm : S0;
    Addr a = {0};
    if (in->by_cl && live) {
        emit_error(in->rip, "CL shift with live flags");
        return;
    }
    if (!in->rm_reg) {
        a = addr_prepare(in, in->sz);
        ldst(1, in->sz, S0, a);
    }
    int rd = in->rm_reg ? dst : RS;
    if (in->by_cl) {
        var_shift(sf, kind == SH_SHL ? 0 : kind == SH_SHR ? 1 : 2, rd, dst, 1);
    } else {
        int n = (int)in->imm;
        if (!n) {
            if (!sf && in->rm_reg)
                mov_reg(0, dst, dst);
            return;
        }
        if (live & F_V && n == 1 && kind != SH_SAR) {
            emit_error(in->rip, "OF of a shift by 1");
            return;
        }
        if (live & F_C)
            mov_reg(sf, S1, dst);
        if (kind == SH_SHL)
            lsl_imm(sf, rd, dst, n);
        else
            bitfield(sf, kind == SH_SHR ? 2 : 0, rd, dst, n, bits - 1);
        if (live) {
            logic_reg(sf, 3, 0, PF, rd, rd);
            if (live & F_C) {
                int bit = kind == SH_SHL ? bits - n : n - 1;
                rmif(S1, (bit - 1) & 63, 2); // x86 polarity into C
                cfinv();
            } else
                cfinv();
        }
    }
    if (!in->rm_reg)
        ldst(0, in->sz, rd, a);
}

static void emit_insn(const Insn *in, int live) {
    switch (in->op) {
        case OP_NOP:
            break;
        case OP_ALU:
            emit_alu(in, live);
            break;
        case OP_SHIFT:
            emit_shift(in, live);
            break;
        case OP_MOV:
            if (in->has_imm) {
                if (in->rm_reg || in->to_reg) {
                    int rd = in->to_reg ? in->reg : in->rm;
                    if (in->sz == 8)
                        movimm(rd, in->imm);
                    else if (in->sz == 4)
                        movimm(rd, (u64)in->imm & 0xffffffffULL);
                    else {
                        movimm(S0, in->imm);
                        bfi_low(rd, S0, in->sz * 8);
                    }
                } else {
                    Addr a = addr_prepare(in, in->sz);
                    int v = XZR;
                    if (in->imm) {
                        movimm(S0, in->sz == 8 ? (u64)in->imm : (u64)in->imm & 0xffffffffULL);
                        v = S0;
                    }
                    ldst(0, in->sz, v, a);
                }
            } else if (in->rm_reg) {
                write_reg(in->sz, in->to_reg ? in->reg : in->rm, in->to_reg ? in->rm : in->reg);
            } else {
                Addr a = addr_prepare(in, in->sz);
                if (!in->to_reg)
                    ldst(0, in->sz, in->reg, a);
                else if (in->sz >= 4)
                    ldst(1, in->sz, in->reg, a);
                else {
                    ldst(1, in->sz, S0, a);
                    bfi_low(in->reg, S0, in->sz * 8);
                }
            }
            break;
        case OP_LEA: {
            int sf = in->sz == 8, rd = in->reg;
            if (in->riprel) {
                movimm(rd, in->next + in->disp);
                break;
            }
            int cur;
            if (in->no_index)
                cur = in->no_base ? XZR : in->base;
            else {
                add_reg(1, 0, 0, AD, in->no_base ? XZR : in->base, in->index, in->scale);
                cur = AD;
            }
            if (in->disp) {
                if (cur == XZR) {
                    movimm(rd, in->disp);
                    break;
                }
                if (in->disp > 0 && in->disp < 4096)
                    add_imm(sf, 0, 0, rd, cur, (u32)in->disp);
                else if (in->disp < 0 && in->disp > -4096)
                    add_imm(sf, 1, 0, rd, cur, (u32)-in->disp);
                else {
                    movimm(S1, in->disp);
                    add_reg(sf, 0, 0, rd, cur, S1, 0);
                }
            } else
                mov_reg(sf, rd, cur);
            break;
        }
        case OP_MOVZX:
        case OP_MOVSX: {
            bool sx = in->op == OP_MOVSX;
            int rd = in->reg, sf = in->sz == 8, ss = in->srcsz;
            if (in->rm_reg) {
                if (!sx && ss == 4)
                    mov_reg(0, rd, in->rm);
                else
                    bitfield(sx ? sf : 0, sx ? 0 : 2, rd, in->rm, 0, ss * 8 - 1);
            } else {
                Addr a = addr_prepare(in, ss);
                ldst(sx ? (ss == 4 || sf ? 2 : 3) : 1, ss, rd, a);
            }
            break;
        }
        case OP_PUSH:
            E(0xF8000C00u | ((u32)-8 & 0x1ff) << 12 | 4 << 5 | in->reg);
            break;
        case OP_POP:
            E(0xF8400400u | 8 << 12 | 4 << 5 | in->reg);
            break;
        case OP_NEG:
        case OP_NOT: {
            int sf = in->sz == 8, narrow = in->sz < 4, dst = in->rm_reg ? in->rm : S0;
            Addr a = {0};
            if (!in->rm_reg) {
                a = addr_prepare(in, in->sz);
                ldst(1, in->sz, S0, a);
            }
            int rd = (in->rm_reg && !narrow) ? dst : RS;
            if (in->op == OP_NOT)
                logic_reg(sf, 1, 1, rd, XZR, dst);
            else if (narrow && live) {
                lsl_imm(0, S1, dst, 32 - in->sz * 8);
                add_reg(0, 1, 1, rd, XZR, S1, 0);
                bitfield(0, 2, rd, rd, 32 - in->sz * 8, 31);
                mov_reg(0, PF, rd);
            } else {
                add_reg(sf, 1, live != 0, rd, XZR, dst, 0);
                if (live)
                    mov_reg(sf, PF, rd);
            }
            if (!in->rm_reg)
                ldst(0, in->sz, rd, a);
            else if (narrow)
                bfi_low(dst, rd, in->sz * 8);
            break;
        }
        case OP_DIV: { // shortcut: 128/64 is not translated, only rdx == 0 and a nonzero divisor, upgrade if a guest
                       // needs it
            int src = in->rm_reg ? in->rm : S1;
            if (!in->rm_reg)
                ldst(1, 8, S1, addr_prepare(in, 8));
            u32 *cb1 = cc;
            cbz(1, 1, 2, 0); // cbnz rdx -> error
            u32 *cb2 = cc;
            cbz(1, 1, src, 0); // cbnz src -> ok
            u32 *fail = cc;
            emit_error(in->rip, "div with rdx != 0 or a zero divisor");
            u32 *ok = cc;
            *cb1 |= ((u32)(fail - cb1) & 0x7ffff) << 5;
            *cb2 |= ((u32)(ok - cb2) & 0x7ffff) << 5;
            E(0x9AC00800u | src << 16 | 0 << 5 | S0); // udiv x16, x0, src
            E(0x9B008000u | src << 16 | 0 << 10 | S0 << 5 | 2); // msub x2, x16, src, x0
            mov_reg(1, 0, S0);
            break;
        }
        case OP_IMUL: {
            if (live) {
                emit_error(in->rip, "imul with live flags");
                break;
            }
            int src = in->rm_reg ? in->rm : S0;
            if (!in->rm_reg)
                ldst(1, in->sz, S0, addr_prepare(in, in->sz));
            E(0x1B007C00u | (u32)(in->sz == 8) << 31 | src << 16 | in->reg << 5 | in->reg);
            break;
        }
        case OP_CMOV: {
            int sf = in->sz == 8, src = in->rm_reg ? in->rm : S0;
            if (!in->rm_reg)
                ldst(1, in->sz, S0, addr_prepare(in, in->sz));
            csel(sf, in->reg, src, in->reg, x86_to_arm_cc[in->cc]);
            break;
        }
        case OP_SETCC:
            cset(S0, x86_to_arm_cc[in->cc]);
            if (in->rm_reg)
                bfi_low(in->rm, S0, 8);
            else {
                Addr a = addr_prepare(in, 1);
                ldst(0, 1, S0, a);
            }
            break;
        case OP_CR3: {
            extern int cr3_mode;
            mov_reg(1, S0, in->rm);
            svc(cr3_mode == 1 ? EXIT_CR3_FAST : EXIT_CR3);
            break;
        }
        default:
            DIE("emit: unhandled op %d at %llx", in->op, in->rip);
    }
}

static u64 cc_va(const u32 *p) { return HOLE_VA + CC_OFF + (u64)((u8 *)p - (u8 *)cc_base); }
static u32 *cc_host(u64 va) { return (u32 *)((u8 *)cc_base + (va - HOLE_VA - CC_OFF)); }

static u64 translate(u64 rip) {
    u64 hit = map_lookup(rip);
    if (hit)
        return hit;
    if ((u8 *)cc - (u8 *)cc_base > (long)CC_SIZE - 0x10000)
        DIE("code cache full");
    static Insn list[64];
    int count = 0;
    u64 pc = rip;
    do {
        decode(pc, &list[count]);
        pc = list[count].next;
        count++;
    } while (count < 64 && !is_terminator(list[count - 1].op) && (pc & ~0xfffULL) == (rip & ~0xfffULL));

    const Insn *last = &list[count - 1];
    int live;
    if (last->op == OP_JCC)
        live = flags_needed_at(last->target, 2) | flags_needed_at(last->next, 2);
    else if (last->op == OP_JMP || last->op == OP_CALL)
        live = flags_needed_at(last->target, 2);
    else if (is_terminator(last->op))
        live = F_ALL;
    else
        live = flags_needed_at(last->next, 2);
    static int live_after[64];
    for (int i = count - 1; i >= 0; i--) {
        live_after[i] = live;
        live = (live & ~list[i].writes) | list[i].reads;
    }

    u32 *start = cc;
    for (int i = 0; i < count; i++) {
        const Insn *in = &list[i];
        stat_insns++;
        switch (in->op) {
            case OP_JCC:
                E(0x54000000u | (STUB_WORDS + 1) << 5 | x86_to_arm_cc[in->cc]);
                emit_stub(in->next, EXIT_DIRECT);
                emit_stub(in->target, EXIT_TAKEN);
                break;
            case OP_JMP:
                emit_stub(in->target, EXIT_DIRECT);
                break;
            case OP_CALL:
                movimm(S0, in->next);
                E(0xF8000C00u | ((u32)-8 & 0x1ff) << 12 | 4 << 5 | S0);
                emit_stub(in->target, EXIT_DIRECT);
                break;
            case OP_JMPI:
            case OP_CALLI:
                if (in->rm_reg)
                    mov_reg(1, RS, in->rm);
                else {
                    Addr a = addr_prepare(in, 8);
                    ldst(1, 8, RS, a);
                }
                if (in->op == OP_CALLI) {
                    movimm(S0, in->next);
                    E(0xF8000C00u | ((u32)-8 & 0x1ff) << 12 | 4 << 5 | S0);
                }
                mov_reg(1, S0, RS);
                emit_indirect();
                break;
            case OP_RET:
                E(0xF8400400u | 8 << 12 | 4 << 5 | S0);
                emit_indirect();
                break;
            case OP_HLT:
                movimm(S0, in->next);
                svc(EXIT_HLT);
                break;
            case OP_BAD:
                emit_error(in->rip, in->why);
                break;
            default:
                emit_insn(in, live_after[i]);
                break;
        }
    }
    if (!is_terminator(last->op))
        emit_stub(last->next, EXIT_DIRECT);
    u64 arm = cc_va(start);
    map_insert(rip, arm);
    stat_arm_words += cc - start;
    sys_icache_invalidate(start, (u8 *)cc - (u8 *)start);
    return arm;
}

// ---- Shadow page tables ----
#define SHADOW_POOL_PAGES 4096
static u64 pt_static_next; // bump for hole tables
static u64 pool_start, pool_next;
static u64 hole_l1_ipa; // shared subtree installed in every shadow root
static u64 *ipa_ptr(u64 ipa) { return ipa >= PRIV_IPA ? (u64 *)(priv + (ipa - PRIV_IPA)) : (u64 *)(ram + ipa); }

static u64 pt_alloc(void) {
    if ((pool_next - pool_start) / 4096 >= SHADOW_POOL_PAGES)
        DIE("shadow pool exhausted");
    u64 ipa = pool_next;
    pool_next += 4096;
    memset(ipa_ptr(ipa), 0, 4096);
    return ipa;
}
static u64 pt_static(void) {
    u64 ipa = pt_static_next;
    pt_static_next += 4096;
    memset(ipa_ptr(ipa), 0, 4096);
    return ipa;
}

// Two shadow address spaces, one per x86 CR3, each with its own ASID.
static u64 x86_cr3[2];
static u64 shadow_root[2];
static u64 ttbr_for(int idx) { return (u64)(idx + 1) << 48 | shadow_root[idx]; }
static void root_init(int idx) {
    shadow_root[idx] = pt_static();
    ipa_ptr(shadow_root[idx])[(HOLE_VA >> 39) & 0x1ff] = hole_l1_ipa | PTE_VALID;
}
static int cr3_index(u64 cr3) {
    if (cr3 == x86_cr3[0])
        return 0;
    if (cr3 == x86_cr3[1])
        return 1;
    DIE("unknown CR3 %llx", cr3);
}
static u64 stat_fills, stat_d_faults;
u64 block_lo, block_hi;

static void shadow_install(int idx, u64 va, u64 pte, int leaf_level) {
    u64 table = shadow_root[idx];
    for (int level = 3; level > leaf_level; level--) {
        u64 *e = ipa_ptr(table) + ((va >> (12 + 9 * level)) & 0x1ff);
        if (!*e)
            *e = pt_alloc() | PTE_VALID;
        table = *e & PA_MASK;
    }
    ipa_ptr(table)[(va >> (12 + 9 * leaf_level)) & 0x1ff] = pte;
}

// Fill from the x86 tables. A and D are set as the x86 walker would, so the guest OS sees correct history.
// Returns whether the page was already present and writable-upgraded, needing a TLB invalidate.
static bool shadow_fault(u64 va, bool write, bool perm_fault) {
    u64 gpa;
    int idx = cr3_index(cur_cr3);
    u64 *x = x86_walk(cur_cr3, va, &gpa);
    if (!x)
        DIE("x86 #PF, not present: va=%llx (delivery to the guest is not implemented)", va);
    if (!(*x & X86_US))
        DIE("x86 #PF, supervisor page at EL0: va=%llx", va);
    if (write && !(*x & X86_RW))
        DIE("x86 #PF, write to read-only page: va=%llx", va);
    *x |= X86_A | (write ? X86_D : 0);
    u64 pte = (gpa & PA_MASK) | PTE_VALID | PTE_AF | PTE_SH | PTE_NG | PTE_PXN;
    pte |= (*x & X86_D) && (*x & X86_RW) ? AP_EL0_RW : AP_RO;
    if (*x & X86_NX)
        pte |= PTE_UXN;
    // Experiment only (SPIKE_BLOCK): shortcut: ignores per-4 KB A/D and permissions across the 2 MB, a real
    // version must prove the x86 PTEs uniform and contiguous.
    extern u64 block_lo, block_hi;
    if (va >= block_lo && va < block_hi)
        shadow_install(idx, va & ~0x1fffffULL, (pte & ~(PA_MASK | 3ULL)) | (gpa & ~0x1fffffULL) | 1, 1);
    else
        shadow_install(idx, va, pte, 0);
    if (perm_fault)
        stat_d_faults++;
    else
        stat_fills++;
    return perm_fault;
}

static void shadow_flush_all(void) {
    pool_next = pool_start;
    for (int i = 0; i < 2; i++) {
        memset(ipa_ptr(shadow_root[i]), 0, 4096);
        ipa_ptr(shadow_root[i])[(HOLE_VA >> 39) & 0x1ff] = hole_l1_ipa | PTE_VALID;
    }
}

// ---- x86 page tables, built in guest RAM ----
static u64 x86_alloc_next;
static u64 x86_alloc(void) {
    u64 gpa = x86_alloc_next;
    x86_alloc_next += 4096;
    if (x86_alloc_next > RAM_SIZE)
        DIE("guest RAM exhausted");
    return gpa;
}
static void x86_map(u64 cr3, u64 va, u64 gpa, u64 flags) {
    u64 table = cr3;
    for (int level = 3; level > 0; level--) {
        u64 *e = (u64 *)(ram + table + (((va >> (12 + 9 * level)) & 0x1ff) * 8));
        if (!*e)
            *e = x86_alloc() | X86_P | X86_RW | X86_US;
        table = *e & PA_MASK;
    }
    *(u64 *)(ram + table + ((va >> 12) & 0x1ff) * 8) = gpa | flags | X86_P;
}
static u64 x86_map_range(u64 cr3, u64 va, u64 bytes, u64 flags) {
    for (u64 o = 0; o < bytes; o += 4096)
        x86_map(cr3, va + o, 0, flags); // tables first, so the data is contiguous
    x86_alloc_next = (x86_alloc_next + 0x1fffff) & ~0x1fffffULL; // and 2 MB aligned, for the SPIKE_BLOCK experiment
    u64 gpa = x86_alloc_next;
    for (u64 o = 0; o < bytes; o += 4096)
        x86_map(cr3, va + o, x86_alloc(), flags);
    return gpa;
}

#define CODE_VA 0x100000ULL
#define STACK_TOP 0x700000100000ULL
#define DATA_VA 0x600000000000ULL
#define MEM_VA DATA_VA
#define C16_VA (DATA_VA + 0x100000)
#define C64_VA (DATA_VA + 0x200000)
#define TOUCH_VA (DATA_VA + 0x10000000)
#define TOUCH_PAGES 4096ULL
#define CR3_VA (DATA_VA + 0x20000000)
#define CR3_PAGES 32ULL

// ---- vCPU ----
static void vcpu_setup(hv_vcpu_t v, bool tso) {
    u64 actlr;
    CHECK(hv_vcpu_get_sys_reg(v, HV_SYS_REG_ACTLR_EL1, &actlr));
    actlr = tso ? actlr | 2 : actlr & ~2ULL;
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_ACTLR_EL1, actlr));
    u64 back;
    CHECK(hv_vcpu_get_sys_reg(v, HV_SYS_REG_ACTLR_EL1, &back));
    if (!!(back & 2) != tso)
        DIE("ACTLR_EL1.EnTSO did not stick: %llx", back);
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_MAIR_EL1, 0xFF));
    u64 tcr = 16ULL | 16ULL << 16 | 1ULL << 23 /* EPD1 */ | 3ULL << 12 | 1ULL << 10 | 1ULL << 8 |
              2ULL << 30 /* TG1 4K */ | 1ULL << 32 /* IPS 36 */ | 1ULL << 36 /* AS */;
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_TCR_EL1, tcr));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_TTBR0_EL1, ttbr_for(0)));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_VBAR_EL1, HOLE_VA + STUBS_OFF));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_SCTLR_EL1, 0x30D00800ULL | 1 | 1 << 2 | 1 << 12));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_CPACR_EL1, 3ULL << 20));
    if (el2_s2_root) {
        CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_HCR_EL2, 1ULL << 31 | 1));
        CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_VTCR_EL2,
                                  25ULL | 1ULL << 6 | 1ULL << 8 | 1ULL << 10 | 3ULL << 12 | 2ULL << 16 | 1ULL << 31));
        CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_VTTBR_EL2, el2_s2_root | 1ULL << 48));
        CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_SCTLR_EL2, 0x30C50830)); // MMU off: VBAR_EL2 below is an IPA
        CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_VBAR_EL2, PRIV_IPA + STUBS_OFF + (u64)(guest_vel2_vectors - guest_stubs)));
    }
}
static void vcpu_enter(hv_vcpu_t v, u64 pc) {
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_ELR_EL1, pc));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_SPSR_EL1, 1ULL << 29)); // EL0t with C set, meaning CF clear
    CHECK(hv_vcpu_set_reg(v, HV_REG_CPSR, 0x3C5));
    CHECK(hv_vcpu_set_reg(v, HV_REG_PC, STUB_VA(guest_eret)));
}

int cr3_mode; // 0 host-handled ASID switch, 1 in-guest ASID switch, 2 host-handled full invalidate
static u64 stat_exits;
static const char *cur_name = "?";

// Runs from x86 `rip` until hlt. Exits only for faults, chaining misses and privileged instructions.
static u64 run_x86(u64 rip, u64 rsp, const u64 args[6]) {
    static const hv_reg_t arg_regs[6] = {HV_REG_X7, HV_REG_X6, HV_REG_X2, HV_REG_X1, HV_REG_X8, HV_REG_X9};
    for (int i = 0; i < 6; i++)
        CHECK(hv_vcpu_set_reg(vcpu, arg_regs[i], args[i]));
    CHECK(hv_vcpu_set_reg(vcpu, HV_REG_X4, rsp));
    CHECK(hv_vcpu_set_reg(vcpu, HV_REG_X19, HOLE_VA + HASH_OFF));
    vcpu_enter(vcpu, translate(rip));
    for (;;) {
        CHECK(hv_vcpu_run(vcpu));
        if (vexit->reason != HV_EXIT_REASON_EXCEPTION)
            DIE("unexpected VM exit reason %d in %s", vexit->reason, cur_name);
        u64 syn = vexit->exception.syndrome;
        if ((syn >> 26) != (el2_s2_root ? 0x17 : 0x16))
            DIE("unexpected EL2 syndrome %llx at va %llx", syn, vexit->exception.virtual_address);
        stat_exits++;
        u64 elr, esr, far, x16, pc = STUB_VA(guest_eret);
        if ((syn & 0xffff) != 8) {
            CHECK(hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_ELR_EL1, &elr));
            CHECK(hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_ESR_EL1, &esr));
            CHECK(hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_FAR_EL1, &far));
            DIE("exception at EL1, vector %llu: esr=%llx far=%llx elr=%llx", syn & 0xffff, esr, far, elr);
        }
        CHECK(hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_ESR_EL1, &esr));
        CHECK(hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_ELR_EL1, &elr));
        int ec = esr >> 26;
        if (ec == 0x15) { // translator request
            u32 kind = esr & 0xffff;
            CHECK(hv_vcpu_get_reg(vcpu, HV_REG_X16, &x16));
            if (kind == EXIT_DIRECT || kind == EXIT_TAKEN) {
                u64 arm = translate(x16);
                u32 *svc_at = cc_host(elr - 4), *stub = svc_at - (STUB_WORDS - 1);
                *stub = 0x14000000u | ((u32)(((i64)arm - (i64)cc_va(stub)) >> 2) & 0x3ffffff);
                sys_icache_invalidate(stub, 4);
                if (kind == EXIT_TAKEN) { // retarget the b.cond straight at the block when it reaches
                    u32 *bcond = stub - STUB_WORDS - 1;
                    i64 off = ((i64)arm - (i64)cc_va(bcond)) >> 2;
                    if (off >= -(1 << 18) && off < (1 << 18)) {
                        *bcond = (*bcond & ~(0x7ffffu << 5)) | ((u32)off & 0x7ffff) << 5;
                        sys_icache_invalidate(bcond, 4);
                    }
                }
                CHECK(hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_ELR_EL1, arm));
            } else if (kind == EXIT_IND) {
                u64 arm = translate(x16);
                u64 *entry = (u64 *)(priv + HASH_OFF) + 2 * (x16 & ((1 << HASH_BITS) - 1));
                entry[0] = x16;
                entry[1] = arm;
                __builtin_arm_dsb(11);
                CHECK(hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_ELR_EL1, arm));
            } else if (kind == EXIT_HLT) {
                u64 rax;
                CHECK(hv_vcpu_get_reg(vcpu, HV_REG_X0, &rax));
                return rax;
            } else if (kind == EXIT_CR3) {
                cur_cr3 = x16;
                int idx = cr3_index(x16);
                if (cr3_mode == 2) {
                    shadow_flush_all();
                    pc = STUB_VA(guest_tlbi_all);
                }
                CHECK(hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_TTBR0_EL1, ttbr_for(idx)));
            } else if (kind == EXIT_ERR) {
                const char *why = "?";
                for (int i = err_count - 1; i >= 0; i--)
                    if (errs[i].rip == x16) {
                        why = errs[i].why;
                        break;
                    }
                u8 b[8] = {0};
                fetch(x16, b, 8);
                DIE("%s at x86 rip %llx (bytes %02x %02x %02x %02x %02x %02x) in %s", why, x16, b[0], b[1], b[2], b[3],
                    b[4], b[5], cur_name);
            } else
                DIE("unknown svc %u", kind);
        } else if (ec == 0x24) { // data abort from EL0
            CHECK(hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_FAR_EL1, &far));
            u64 ttbr;
            CHECK(hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_TTBR0_EL1, &ttbr));
            cur_cr3 = x86_cr3[(ttbr >> 48) - 1]; // the in-guest CR3 path does not tell the host
            int dfsc = esr & 0x3f;
            bool write = esr & (1 << 6);
            bool perm = (dfsc & 0x3c) == 0x0c;
            if (!perm && (dfsc & 0x3c) != 0x04)
                DIE("unhandled data abort dfsc=%x far=%llx elr=%llx", dfsc, far, elr);
            if (shadow_fault(far, write, perm)) {
                // An upgrade of a live entry: invalidate through the EL1 stub, tagged with the current ASID.
                CHECK(hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_TPIDRRO_EL0, (ttbr & 0xffff000000000000ULL) | (far >> 12)));
                pc = STUB_VA(guest_tlbi_va);
            }
            __builtin_arm_dsb(11);
        } else {
            u64 far2 = 0;
            hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_FAR_EL1, &far2);
            DIE("unhandled exception EC=%x esr=%llx far=%llx elr=%llx in %s", ec, esr, far2, elr, cur_name);
        }
        if (el2_s2_root) // the report came from vEL2, so drop back to EL1 for the resume ERET
            CHECK(hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3C5));
        CHECK(hv_vcpu_set_reg(vcpu, HV_REG_PC, pc));
    }
}

static u64 run(u64 entry, u64 id, u64 a, u64 b, u64 c, u64 d, u64 e) {
    const u64 args[6] = {id, a, b, c, d, e};
    return run_x86(entry, STACK_TOP - 64, args);
}

#define BENCH(name, n, ...)                                                                                            \
    do {                                                                                                               \
        cur_name = name;                                                                                               \
        u64 sum = run(CODE_VA, __VA_ARGS__);                                                                           \
        u64 warm_exits = stat_exits;                                                                                   \
        double best = 1e30;                                                                                            \
        for (int r = 0; r < REPS; r++) {                                                                               \
            double t = now();                                                                                          \
            sum = run(CODE_VA, __VA_ARGS__);                                                                           \
            t = now() - t;                                                                                             \
            if (t < best)                                                                                              \
                best = t;                                                                                              \
        }                                                                                                              \
        printf("%-10s %8.3f ns/iter  checksum %016llx  warmup-exits %llu  exits/rep %llu\n", name, best / (n), sum,    \
               warm_exits - exits0, (stat_exits - warm_exits) / REPS);                                                 \
        exits0 = stat_exits;                                                                                           \
    } while (0)

// ---- Message-passing litmus: does EnTSO actually order accesses at EL0 in a VM? ----
typedef struct {
    u64 pc, n, result;
    bool tso;
} LitArg;
static void *litmus_thread(void *p) {
    LitArg *a = p;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    hv_vcpu_t v;
    hv_vcpu_exit_t *x;
    CHECK(hv_vcpu_create(&v, &x, NULL));
    vcpu_setup(v, a->tso);
    CHECK(hv_vcpu_set_reg(v, HV_REG_X0, HOLE_VA + LIT_OFF));
    CHECK(hv_vcpu_set_reg(v, HV_REG_X1, HOLE_VA + LIT_OFF + 0x1000));
    CHECK(hv_vcpu_set_reg(v, HV_REG_X2, a->n));
    vcpu_enter(v, a->pc);
    CHECK(hv_vcpu_run(v));
    u64 syn = x->exception.syndrome, esr;
    CHECK(hv_vcpu_get_sys_reg(v, HV_SYS_REG_ESR_EL1, &esr));
    if (x->reason != HV_EXIT_REASON_EXCEPTION || (syn >> 26) != 0x16 || (esr >> 26) != 0x15)
        DIE("litmus exit: reason %d syn %llx esr %llx", x->reason, syn, esr);
    CHECK(hv_vcpu_get_reg(v, HV_REG_X3, &a->result));
    CHECK(hv_vcpu_destroy(v));
    return NULL;
}
static u64 litmus(bool tso, u64 n) {
    memset(priv + LIT_OFF, 0, 0x2000);
    LitArg w = {STUB_VA(guest_lit_writer), n, 0, tso}, r = {STUB_VA(guest_lit_reader), n, 0, tso};
    pthread_t a, b;
    pthread_create(&a, NULL, litmus_thread, &w);
    pthread_create(&b, NULL, litmus_thread, &r);
    pthread_join(a, NULL);
    pthread_join(b, NULL);
    return r.result;
}

int main(int argc, char **argv) {
    alarm(28); // a wedged vCPU must not outlive the short-burst budget
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *mode = argc > 1 ? argv[1] : "bench";
    const char *img = argc > 2 ? argv[2] : "flat.bin";
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    tick_ns = (double)tb.numer / tb.denom;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    hv_vm_config_t cfg = hv_vm_config_create();
    bool ipa16 = getenv("SPIKE_IPA16") != NULL;
    CHECK(hv_vm_config_set_ipa_granule(cfg, ipa16 ? HV_IPA_GRANULE_16KB : HV_IPA_GRANULE_4KB));
    bool el2 = getenv("SPIKE_EL2") != NULL;
    if (el2)
        CHECK(hv_vm_config_set_el2_enabled(cfg, true));
    CHECK(hv_vm_create(cfg));
    ram = mmap(0, RAM_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    priv = mmap(0, PRIV_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (ram == MAP_FAILED || priv == MAP_FAILED)
        DIE("mmap");
    CHECK(hv_vm_map(ram, 0, RAM_SIZE, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC));
    CHECK(hv_vm_map(priv, PRIV_IPA, PRIV_SIZE, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC));

    // Can a single 4 KB IPA page be carved out of stage 2? Matters for MMIO holes at x86 page granularity.
    hv_return_t carve = hv_vm_protect(0x1000, 0x1000, HV_MEMORY_READ);
    printf("ipa-granule=%s  4KB stage-2 protect: %s\n", ipa16 ? "16K" : "4K", carve ? "refused" : "accepted");
    if (!carve)
        CHECK(hv_vm_protect(0x1000, 0x1000, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC));

    // Stubs, hash and code cache: static hole tables with 2 MB blocks, shared by every shadow root, global (nG clear).
    memcpy(priv + STUBS_OFF, guest_stubs, guest_stubs_end - guest_stubs);
    memset(priv + HASH_OFF, 0xFF, 16ULL << HASH_BITS); // key ~0 is non-canonical, so it can never match
    pt_static_next = PRIV_IPA + PT_OFF;
    hole_l1_ipa = pt_static();
    u64 l2 = pt_static();
    ipa_ptr(hole_l1_ipa)[(HOLE_VA >> 30) & 0x1ff] = l2 | PTE_VALID;
    u64 blk = 1 | PTE_AF | PTE_SH;
    for (u64 o = 0; o < PT_OFF; o += 2ULL << 20) {
        u64 attrs = o == LIT_OFF ? AP_EL0_RW | PTE_UXN | PTE_PXN : o == HASH_OFF ? AP_RO | PTE_UXN | PTE_PXN : AP_RO;
        ipa_ptr(l2)[((HOLE_VA + o) >> 21) & 0x1ff] = (PRIV_IPA + o) | blk | attrs;
    }
    if (el2) { // identity guest stage 2 in 1 GB blocks: IPA 0 and PRIV_IPA
        el2_s2_root = pt_static();
        u64 s2_block = 1 | 1ULL << 10 | 3ULL << 8 | 3ULL << 6 | 0xFULL << 2;
        ipa_ptr(el2_s2_root)[0] = 0 | s2_block;
        ipa_ptr(el2_s2_root)[1] = PRIV_IPA | s2_block;
    }
    root_init(0);
    root_init(1);
    pool_start = pool_next = pt_static_next;
    cc_base = cc = (u32 *)(priv + CC_OFF);
    __builtin_arm_dsb(11);

    x86_alloc_next = 0x1000;
    x86_cr3[0] = x86_alloc();
    x86_cr3[1] = x86_alloc();
    if (((x86_cr3[0] >> 12) & 15) == ((x86_cr3[1] >> 12) & 15))
        DIE("CR3 table collision");
    cur_cr3 = x86_cr3[0];
    u64 *tab = (u64 *)(priv + STUBS_OFF + (guest_cr3tab - guest_stubs));
    tab[(x86_cr3[0] >> 12) & 15] = ttbr_for(0);
    tab[(x86_cr3[1] >> 12) & 15] = ttbr_for(1);

    if (!strcmp(mode, "litmus")) {
        for (int t = 0; t < 2; t++)
            printf("litmus EL0 EnTSO=%d: %llu ordering violations in 200M reads\n", t, litmus(t, 200000000ULL));
        return 0;
    }

    FILE *f = fopen(img, "rb");
    if (!f)
        DIE("cannot open %s", img);
    u64 code_gpa = x86_map_range(x86_cr3[0], CODE_VA, 0x8000, X86_US);
    size_t got = fread(ram + code_gpa, 1, 0x8000, f);
    if (!got || !feof(f))
        DIE("image missing or larger than 32 KB");
    fclose(f);
    x86_map_range(x86_cr3[0], STACK_TOP - 0x10000, 0x10000, X86_US | X86_RW | X86_NX);
    x86_map_range(x86_cr3[0], MEM_VA, BUF16K, X86_US | X86_RW | X86_NX);
    x86_map_range(x86_cr3[0], C16_VA, BUF16K, X86_US | X86_RW | X86_NX);
    if (getenv("SPIKE_BLOCK")) {
        block_lo = C64_VA;
        block_hi = C64_VA + BUF64M;
    }
    x86_map_range(x86_cr3[0], C64_VA, BUF64M, X86_US | X86_RW | X86_NX);
    x86_map_range(x86_cr3[0], TOUCH_VA, TOUCH_PAGES * 4096, X86_US | X86_RW | X86_NX);
    x86_map_range(x86_cr3[0], CR3_VA, CR3_PAGES * 4096, X86_US | X86_RW | X86_NX);
    memcpy(ram + x86_cr3[1], ram + x86_cr3[0], 4096); // the second address space shares every lower table

    vcpu = 0;
    CHECK(hv_vcpu_create(&vcpu, &vexit, NULL));
    vcpu_setup(vcpu, !getenv("SPIKE_NO_TSO"));
    u64 exits0 = 0;

    if (!strcmp(mode, "bench")) {
        cur_name = "chase-init";
        double t0 = now();
        run(CODE_VA, W_CHASE_INIT, C16_VA, BUF16K, 0, 0, 0);
        run(CODE_VA, W_CHASE_INIT, C64_VA, BUF64M, 0, 0, 0);
        printf("chase init %.1f ms incl. translation and %llu shadow fills, %llu dirty upgrades\n", (now() - t0) / 1e6,
               stat_fills, stat_d_faults);
        exits0 = stat_exits;
        BENCH("int", N_INT, W_INT, N_INT, 0, 0, 0, 0);
        BENCH("mem16k", MEM_WORDS * MEM_ROUNDS, W_MEM, MEM_VA, MEM_WORDS, MEM_ROUNDS, 0, 0);
        BENCH("chase16k", N_CHASE16K, W_CHASE, C16_VA, N_CHASE16K, 0, 0, 0);
        BENCH("chase64m", N_CHASE64M, W_CHASE, C64_VA, N_CHASE64M, 0, 0, 0);
        BENCH("call", N_CALL, W_CALL, N_CALL, 0, 0, 0, 0);
        BENCH("callrand", N_CALLRAND, W_CALLRAND, N_CALLRAND, 0, 0, 0, 0);
        BENCH("flags", N_FLAGS, W_FLAGS, N_FLAGS, 0, 0, 0, 0);
        BENCH("flagasm", N_FLAGASM, W_FLAGASM, N_FLAGASM, 0, 0, 0, 0);
        printf("blocks %d, x86 insns %llu, arm words %llu (%.2f per x86 insn incl. stubs), fills %llu, dirty %llu\n",
               block_count, stat_insns, stat_arm_words, (double)stat_arm_words / stat_insns, stat_fills, stat_d_faults);
    } else if (!strcmp(mode, "fill")) {
        // One translated walk first, on the same code path, so translation cost is not counted as fill cost.
        cur_name = "touch";
        run(CODE_VA, W_TOUCH, TOUCH_VA, 1, 0, 0, 0);
        u64 f0 = stat_fills;
        double t = now();
        run(CODE_VA, W_TOUCH, TOUCH_VA + 4096, TOUCH_PAGES - 1, 0, 0, 0);
        t = now() - t;
        printf("read fill:  %8.1f ns/page, %llu fills\n", t / (TOUCH_PAGES - 1), stat_fills - f0);
        u64 d0 = stat_d_faults;
        t = now();
        run(CODE_VA, W_TOUCH, TOUCH_VA + 4096, TOUCH_PAGES - 1, 1, 0, 0);
        t = now() - t;
        printf("dirty upgrade incl. TLBI: %8.1f ns/page, %llu upgrades\n", t / (TOUCH_PAGES - 1), stat_d_faults - d0);
        t = now();
        run(CODE_VA, W_TOUCH, TOUCH_VA + 4096, TOUCH_PAGES - 1, 1, 0, 0);
        t = now() - t;
        printf("no faults, baseline: %8.1f ns/page\n", t / (TOUCH_PAGES - 1));
    } else if (!strcmp(mode, "cr3")) {
        cur_name = "cr3";
        const u64 N = 20000;
        struct {
            const char *label;
            int mode;
            u64 a, b, n;
        } rows[] = {
            {"no reload, baseline", 0, 0, 0, N},
            {"host, ASID switch", 0, x86_cr3[0], x86_cr3[1], N},
            {"in-guest, ASID switch", 1, x86_cr3[0], x86_cr3[1], N},
            {"host, full invalidate + refill", 2, x86_cr3[0], x86_cr3[1], N / 10},
        };
        double base = 0;
        for (int i = 0; i < 4; i++) {
            // Translation depends on cr3_mode, so each row needs its own code, reached via a fresh block map.
            cr3_mode = rows[i].mode;
            memset(block_map, 0, sizeof block_map);
            memset(priv + HASH_OFF, 0xFF, 16ULL << HASH_BITS);
            run(CODE_VA, W_CR3, rows[i].n, rows[i].a, rows[i].b, CR3_VA, CR3_PAGES);
            double best = 1e30;
            u64 e0 = stat_exits, s0 = stat_fills;
            for (int r = 0; r < REPS; r++) {
                double t = now();
                run(CODE_VA, W_CR3, rows[i].n, rows[i].a, rows[i].b, CR3_VA, CR3_PAGES);
                t = now() - t;
                if (t < best)
                    best = t;
            }
            best /= rows[i].n;
            if (!i)
                base = best;
            printf("%-32s %9.1f ns/iter  delta %9.1f ns/reload  exits/iter %.2f  fills/iter %.2f (%llu pages/iter)\n",
                   rows[i].label, best, best - base, (double)(stat_exits - e0) / REPS / rows[i].n,
                   (double)(stat_fills - s0) / REPS / rows[i].n, CR3_PAGES);
        }
    } else
        DIE("modes: bench, fill, cr3, litmus");
    return 0;
}
