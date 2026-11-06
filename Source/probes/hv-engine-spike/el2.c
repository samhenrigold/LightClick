// Trap-cost probe: how much of an x86 guest's privileged traffic can stay inside the VM? See DESIGN.md.
// Modes: plain, el2, hcr, chase, litmus, irq, irq-gic[-wfi], ipi-gic[-wfi], ipi-host; some take a second argument el2. SPIKE_IPA16 selects the 16 KB host stage 2.
// Each process makes one VM; run the modes one at a time. Guest code is el2guest.s.
#include <Hypervisor/Hypervisor.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef uint64_t u64;
typedef uint32_t u32;
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
        fprintf(stderr, "stop: " __VA_ARGS__);                                                                         \
        fprintf(stderr, "\n");                                                                                         \
        exit(1);                                                                                                       \
    } while (0)

// Identity mapped: VA == IPA. S1 39-bit, 4 KB granule, root at TABLES.
#define RAM_IPA 0x40000000ULL
#define RAM_SIZE 0x5000000ULL
#define CODE_VA RAM_IPA
#define DATA_VA 0x40200000ULL
#define TABLES 0x40400000ULL
#define S1_ROOT (TABLES + 0x0000)
#define S1_L2 (TABLES + 0x1000)
#define S1_L3_PTW (TABLES + 0x2000)
#define S2_ROOT (TABLES + 0x10000)
#define S2_L2 (TABLES + 0x11000)
#define S2_L3_S2PT (TABLES + 0x12000)
#define S1_L3_CHASE (TABLES + 0x20000)
#define S2_L3_CHASE (TABLES + 0x40000)
#define PTW_VA 0x40800000ULL  // page 0 is the S1 read-only table page, the rest are the pages it maps
#define ALIAS_VA 0x40A00000ULL // writable alias of PTW_VA's 2 MB
#define S2PT_VA 0x40C00000ULL // page 0 is read-only at guest stage 2 (and at host stage 2 for the host rows)
#define CHASE_VA 0x41000000ULL
#define CHASE_SIZE 0x4000000ULL
#define EXIT_IPA 0x80000000ULL // not mapped by the host
#define MMIO_IPA 0x80001000ULL
#define GICD_IPA 0x08000000ULL
#define GICR_IPA 0x08100000ULL
#define ASID 1ULL

#define S1_TABLE 3ULL
#define S1_BLOCK (1ULL | 1ULL << 10 | 3ULL << 8)
#define S1_PAGE (3ULL | 1ULL << 10 | 3ULL << 8)
#define AP_EL0_RW (1ULL << 6)
#define AP_RO (3ULL << 6)
#define NX (3ULL << 53)
#define NG (1ULL << 11)
#define S2_BLOCK (1ULL | 1ULL << 10 | 3ULL << 8 | 0xFULL << 2)
#define S2_PAGE (3ULL | 1ULL << 10 | 3ULL << 8 | 0xFULL << 2)
#define S2_RW (3ULL << 6)
#define S2_R (1ULL << 6)
#define S2_DEV (1ULL | 1ULL << 10 | 3ULL << 6)

#define HCR_VM (1ULL << 0)
#define HCR_TID2 (1ULL << 17)
#define HCR_RW (1ULL << 31)

extern char g_start[], g_end[], s_eret[], s_fresh_el1[], s_fresh_el2[], s_host_tlbi[];
extern char v_eret[], v_skip_el2[], v_syscall_el1[], v_syscall_el2[], v_exc_el1[], v_ptw_el1_is[],
    v_ptw_el1_nsh[], v_ptw_el2_is[], v_s2_emul[], v_irq_flag_hvc[], v_irq_flag_gic[], v_irq_pong_gic[],
    v_irq_pong_hvc[], v_none[];
extern char t_nop[], t_svc[], t_hvc[], t_ctr[], t_mmio[], t_chase[], t_syscall[], t_syscall_trap[], t_exc[], t_ptw[], t_store[],
    t_ttbr_el1[], t_eret_self[], t_elr_el2[], t_hcr_el2[], t_vttbr_el2[], t_tlbi_vale1[], t_tlbi_vale1is[],
    t_tlbi_aside1is[], t_tlbi_vmalle1is[], t_tlbi_ipas2e1is[], t_tlbi_vmalls12e1is[], t_dsb_isb[], t_lit_writer[],
    t_lit_reader[], t_hcr_probe[], t_spin[], t_gic_spin[], t_wfi[], t_gic_wfi[], t_ipi_gic[], t_ipi_hvc[], t_poll_a[], t_poll_b[];
#define G(sym) (CODE_VA + (u64)((sym) - g_start))

static char *ram;
static bool el2_vm, use_gic;
static double tick_ns;
static double now(void) { return mach_absolute_time() * tick_ns; }
#define P(ipa) ((u64 *)(ram + ((ipa) - RAM_IPA)))
#define VP(ipa) ((volatile u64 *)(ram + ((ipa) - RAM_IPA)))

typedef struct {
    hv_vcpu_t v;
    hv_vcpu_exit_t *x;
    u64 hcr;
} Cpu;

static void tables_build(bool chase_s1_4k, bool chase_s2_4k) {
    u64 blk = S1_BLOCK;
    P(S1_ROOT)[0] = 0 | S1_BLOCK | 1 << 2 | NX; // low GB: device, for the GIC frames
    P(S1_ROOT)[1] = S1_L2 | S1_TABLE;
    P(S1_ROOT)[2] = 0x80000000ULL | S1_BLOCK | 1 << 2 | AP_EL0_RW | NX; // device: the exit and MMIO pages
    u64 *l2 = P(S1_L2);
    l2[0] = CODE_VA | blk | AP_RO;
    l2[1] = DATA_VA | blk | AP_EL0_RW | NX;
    l2[2] = TABLES | blk | NX; // EL1 and vEL2 only, also the unreadable target for t_exc
    l2[3] = (TABLES + 0x200000) | blk | NX;
    l2[4] = S1_L3_PTW | S1_TABLE;
    l2[5] = PTW_VA | blk | NX; // ALIAS_VA
    l2[6] = S2PT_VA | blk | AP_EL0_RW | NX;
    l2[7] = (S2PT_VA + 0x200000) | blk | NX;
    u64 *l3 = P(S1_L3_PTW);
    l3[0] = PTW_VA | S1_PAGE | AP_RO | NX;
    for (u64 i = 1; i < 512; i++)
        l3[i] = (PTW_VA + i * 4096) | S1_PAGE | AP_EL0_RW | NX | NG;
    for (u64 i = 0; i < CHASE_SIZE >> 21; i++) {
        u64 va = CHASE_VA + (i << 21);
        if (!chase_s1_4k) {
            l2[va >> 21 & 0x1ff] = va | blk | AP_EL0_RW | NX;
            continue;
        }
        u64 t = S1_L3_CHASE + i * 4096;
        for (u64 j = 0; j < 512; j++)
            P(t)[j] = (va + j * 4096) | S1_PAGE | AP_EL0_RW | NX;
        l2[va >> 21 & 0x1ff] = t | S1_TABLE;
    }
    // Guest stage 2: identity, with one 4 KB read-only page at S2PT_VA.
    P(S2_ROOT)[0] = 0 | S2_DEV;
    P(S2_ROOT)[1] = S2_L2 | S1_TABLE;
    P(S2_ROOT)[2] = 0x80000000ULL | S2_DEV;
    u64 *s2 = P(S2_L2);
    for (u64 i = 0; i < 512; i++)
        s2[i] = (0x40000000ULL + (i << 21)) | S2_BLOCK | S2_RW;
    s2[S2PT_VA >> 21 & 0x1ff] = S2_L3_S2PT | S1_TABLE;
    for (u64 i = 0; i < 512; i++)
        P(S2_L3_S2PT)[i] = (S2PT_VA + i * 4096) | S2_PAGE | (i ? S2_RW : S2_R);
    if (chase_s2_4k)
        for (u64 i = 0; i < CHASE_SIZE >> 21; i++) {
            u64 va = CHASE_VA + (i << 21), t = S2_L3_CHASE + i * 4096;
            for (u64 j = 0; j < 512; j++)
                P(t)[j] = (va + j * 4096) | S2_PAGE | S2_RW;
            s2[va >> 21 & 0x1ff] = t | S1_TABLE;
        }
    __builtin_arm_dsb(11);
}

static void cpu_init(Cpu *c, u64 mpidr, bool tso) {
    CHECK(hv_vcpu_create(&c->v, &c->x, NULL));
    hv_vcpu_t v = c->v;
    u64 actlr;
    CHECK(hv_vcpu_get_sys_reg(v, HV_SYS_REG_ACTLR_EL1, &actlr));
    actlr = tso ? actlr | 2 : actlr & ~2ULL;
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_ACTLR_EL1, actlr));
    CHECK(hv_vcpu_get_sys_reg(v, HV_SYS_REG_ACTLR_EL1, &actlr));
    if (!!(actlr & 2) != tso)
        DIE("ACTLR_EL1.EnTSO did not stick");
    u64 mair = 0xFF, ttbr = S1_ROOT | ASID << 48,
        sctlr = 0x30D00800ULL | 1 | 1 << 2 | 1 << 12 | 1 << 15 /* UCT */;
    u64 tcr = 25ULL | 3ULL << 8 | 3ULL << 10 | 3ULL << 12 | 1ULL << 23 /* EPD1 */ | 2ULL << 30 | 2ULL << 32 /* IPS 40 */ |
              1ULL << 36 /* AS */;
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_MAIR_EL1, mair));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_TCR_EL1, tcr));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_TTBR0_EL1, ttbr));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_SCTLR_EL1, sctlr));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_CPACR_EL1, 3ULL << 20));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_MPIDR_EL1, mpidr));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_SP_EL1, DATA_VA + 0x100000 + mpidr * 0x10000));
    CHECK(hv_vcpu_set_reg(v, HV_REG_X28, EXIT_IPA));
    if (!el2_vm)
        return;
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_MAIR_EL2, mair));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_TCR_EL2, tcr));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_TTBR0_EL2, ttbr));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_SCTLR_EL2, sctlr));
    // T0SZ 25, SL0 1 (start at level 1), inner/outer WB, inner shareable, 4 KB, 40-bit, RES1.
    u64 vtcr = 25ULL | 1ULL << 6 | 1ULL << 8 | 1ULL << 10 | 3ULL << 12 | 2ULL << 16 | 1ULL << 31;
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_VTCR_EL2, vtcr));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_VTTBR_EL2, S2_ROOT | 1ULL << 48));
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_SP_EL2, DATA_VA + 0x180000 + mpidr * 0x10000));
    CHECK(hv_vcpu_set_vtimer_offset(v, 0));
}

// Enter at the given level through an ERET from the highest level.
static void cpu_start(Cpu *c, u64 pc, int level, u64 spsr_daif, const char *stub, u64 vbar1, u64 vbar2, u64 hcr) {
    hv_vcpu_t v = c->v;
    u64 spsr = spsr_daif | (level == 2 ? 9 : level == 1 ? 5 : 0);
    CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_VBAR_EL1, vbar1));
    if (el2_vm) {
        CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_VBAR_EL2, vbar2));
        CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_HCR_EL2, hcr));
        CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_ELR_EL2, pc));
        CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_SPSR_EL2, spsr));
        CHECK(hv_vcpu_set_reg(v, HV_REG_CPSR, 0x3C9));
    } else {
        CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_ELR_EL1, pc));
        CHECK(hv_vcpu_set_sys_reg(v, HV_SYS_REG_SPSR_EL1, spsr));
        CHECK(hv_vcpu_set_reg(v, HV_REG_CPSR, 0x3C5));
    }
    CHECK(hv_vcpu_set_reg(v, HV_REG_PC, G(stub)));
    c->hcr = hcr;
}

static void cpu_diag(Cpu *c, const char *why) {
    u64 pc, x27, cpsr, r[6] = {0};
    hv_vcpu_get_reg(c->v, HV_REG_PC, &pc);
    hv_vcpu_get_reg(c->v, HV_REG_X27, &x27);
    hv_vcpu_get_reg(c->v, HV_REG_CPSR, &cpsr);
    hv_vcpu_get_sys_reg(c->v, HV_SYS_REG_ESR_EL1, &r[0]);
    hv_vcpu_get_sys_reg(c->v, HV_SYS_REG_ELR_EL1, &r[1]);
    hv_vcpu_get_sys_reg(c->v, HV_SYS_REG_FAR_EL1, &r[2]);
    if (el2_vm) {
        hv_vcpu_get_sys_reg(c->v, HV_SYS_REG_ESR_EL2, &r[3]);
        hv_vcpu_get_sys_reg(c->v, HV_SYS_REG_ELR_EL2, &r[4]);
        hv_vcpu_get_sys_reg(c->v, HV_SYS_REG_FAR_EL2, &r[5]);
    }
    u64 hcr = 0;
    if (el2_vm)
        hv_vcpu_get_sys_reg(c->v, HV_SYS_REG_HCR_EL2, &hcr);
    fprintf(stderr, "hcr_el2 now %llx, requested %llx\n", hcr, c->hcr);
    DIE("%s: reason=%d syn=%llx ipa=%llx va=%llx pc=%llx (+%llx) cpsr=%llx x27=%lld\n"
        "  esr1=%llx elr1=%llx far1=%llx esr2=%llx elr2=%llx far2=%llx",
        why, c->x->reason, c->x->exception.syndrome, c->x->exception.physical_address, c->x->exception.virtual_address,
        pc, pc - CODE_VA, cpsr, x27, r[0], r[1], r[2], r[3], r[4], r[5]);
}

enum { HOST_NONE, HOST_MMIO, HOST_STORE, HOST_PTW };
// Runs until the guest touches EXIT_IPA. HVCs resume; the host modes emulate what would be a device or trapped store.
static void cpu_run(Cpu *c, int host_mode) {
    for (;;) {
        CHECK(hv_vcpu_run(c->v));
        if (c->x->reason != HV_EXIT_REASON_EXCEPTION)
            cpu_diag(c, "unexpected exit");
        u64 syn = c->x->exception.syndrome, ipa = c->x->exception.physical_address, pc;
        u32 ec = syn >> 26;
        if (ec == 0x16 && !(syn & 0xffff))
            continue;
        if (ec != 0x24 && ec != 0x25)
            cpu_diag(c, "unexpected syndrome");
        if (ipa == EXIT_IPA) {
            u64 x27 = 0;
            CHECK(hv_vcpu_get_reg(c->v, HV_REG_X27, &x27));
            if (x27)
                cpu_diag(c, "guest vector");
            return;
        }
        CHECK(hv_vcpu_get_reg(c->v, HV_REG_PC, &pc));
        if (host_mode == HOST_MMIO && ipa == MMIO_IPA) {
            CHECK(hv_vcpu_set_reg(c->v, HV_REG_X0, 0));
        } else if (host_mode == HOST_STORE) {
            u64 val;
            CHECK(hv_vcpu_get_reg(c->v, HV_REG_X1, &val));
            P(ipa)[0] = val;
        } else if (host_mode == HOST_PTW) {
            // Same work as H_PTW, on the host: emulate the store, derive the shadow PTE, then a guest stub does the TLBI.
            u64 val, off = ipa & 0xfff;
            CHECK(hv_vcpu_get_reg(c->v, HV_REG_X1, &val));
            *(u64 *)(ram + (ipa - RAM_IPA)) = val;
            u64 pa = val & 0x0000fffffffff000ULL;
            if (!(val & 1) || pa >= RAM_IPA + RAM_SIZE)
                DIE("bad PTE");
            P(S1_L3_PTW)[off / 8] = pa | S1_PAGE | ((val & 2) ? AP_EL0_RW : AP_RO) | NG;
            CHECK(hv_vcpu_set_reg(c->v, HV_REG_X16, pa >> 12 | ASID << 48));
            CHECK(hv_vcpu_set_reg(c->v, HV_REG_X15, pc + 4));
            CHECK(hv_vcpu_set_reg(c->v, HV_REG_PC, G(s_host_tlbi)));
            continue;
        } else
            cpu_diag(c, "unexpected abort");
        CHECK(hv_vcpu_set_reg(c->v, HV_REG_PC, pc + 4));
    }
}

typedef struct {
    u64 r[8];
} Regs;
static Cpu cpu0;
static const hv_reg_t arg_regs[8] = {HV_REG_X0, HV_REG_X1, HV_REG_X2, HV_REG_X3,
                                     HV_REG_X4, HV_REG_X5, HV_REG_X6, HV_REG_X7};

// Warm once on a clean TLB, then time 5 runs. Prints best of 5 with the worst alongside as a noise marker.
static double row(const char *name, u64 n, char *pc, int level, char *vbar1, char *vbar2, u64 hcr, int host_mode,
                  Regs regs, double div) {
    Cpu *c = &cpu0;
    double best = 1e30, worst = 0, warm = 0;
    u64 hash = DATA_VA + 0x40000, gs_u = DATA_VA + 0x10000, gs_k = DATA_VA + 0x11000;
    for (int i = -1; i < 5; i++) {
        cpu_start(c, G(pc), level, 0x3C0, i < 0 ? (el2_vm ? s_fresh_el2 : s_fresh_el1) : s_eret, G(vbar1), G(vbar2),
                  hcr);
        for (int k = 0; k < 8; k++)
            CHECK(hv_vcpu_set_reg(c->v, arg_regs[k], regs.r[k]));
        CHECK(hv_vcpu_set_reg(c->v, HV_REG_X24, n));
        CHECK(hv_vcpu_set_reg(c->v, HV_REG_X19, hash));
        CHECK(hv_vcpu_set_reg(c->v, HV_REG_X25, gs_u));
        CHECK(hv_vcpu_set_reg(c->v, HV_REG_X26, gs_k));
        CHECK(hv_vcpu_set_reg(c->v, HV_REG_X27, 0));
        double t = now();
        cpu_run(c, host_mode);
        t = now() - t;
        if (i < 0) {
            warm = t;
            continue;
        }
        if (t < best)
            best = t;
        if (t > worst)
            worst = t;
    }
    printf("%-44s %10.1f ns  (worst %10.1f, first %10.1f)\n", name, best / n / div, worst / n / div, warm / n / div);
    return best / n / div;
}

static void data_init(void) {
    u64 *gs_k = P(DATA_VA + 0x11000), *gs_u = P(DATA_VA + 0x10000);
    gs_k[1] = gs_u[1] = DATA_VA + 0x30000; // kernel stack
    memset(P(DATA_VA + 0x40000), 0xFF, 16 << 12);
}

static void chain_build(u64 va, u64 size) {
    u64 lines = size / 64;
    u32 *ord = malloc(lines * sizeof *ord);
    for (u64 i = 0; i < lines; i++)
        ord[i] = (u32)i;
    for (u64 i = lines - 1; i > 0; i--) { // Sattolo: one cycle through every line
        u32 j = arc4random_uniform((u32)i), t = ord[i];
        ord[i] = ord[j];
        ord[j] = t;
    }
    for (u64 i = 0; i < lines; i++)
        P(va + ord[i] * 64ULL)[0] = va + ord[(i + 1) % lines] * 64ULL;
    free(ord);
}

// ---- Single vCPU rows ----
#define R(...) ((Regs){{__VA_ARGS__}})
// The emulated PTE store and the derived shadow PTE must both have landed.
static void ptw_check(u64 table) {
    u64 want = PTW_VA + 2 * 4096;
    if (table == ALIAS_VA)
        table = PTW_VA;
    if (P(table)[2] != (want | 0x67) || (P(S1_L3_PTW)[2] & 0x0000fffffffff000ULL) != want || !(P(S1_L3_PTW)[2] & NG))
        DIE("PT write path wrong: guest %llx shadow %llx", P(table)[2], P(S1_L3_PTW)[2]);
}
static void rows_common(u64 hcr, const char *tag) {
    char name[80];
#define N(s) (snprintf(name, sizeof name, "%s %s", tag, s), name)
    u64 h = hcr;
    // 0: x86 kernel/user both as a plain EL1 runtime under whichever VM this is.
    row(N("loop baseline"), 1000000, t_nop, 0, v_none, v_none, h, HOST_NONE, R(0), 1);
    row(N("EL0-EL1-EL0 svc/eret"), 200000, t_svc, 0, v_eret, v_none, h, HOST_NONE, R(0), 1);
    row(N("translated syscall+sysret, EL0-EL1"), 200000, t_syscall, 0, v_syscall_el1, v_none, h, HOST_NONE,
        R(0, 0, 0, 0, DATA_VA + 0x20000), 1);
    row(N("translated fault+iret, EL0-EL1"), 200000, t_exc, 0, v_exc_el1, v_none, h, HOST_NONE,
        R(0, 0, 0, TABLES, DATA_VA + 0x20000), 1);
    row(N("PT write trap+shadow+tlbi vale1is, EL1"), 100000, t_ptw, 1, v_ptw_el1_is, v_none, h, HOST_NONE,
        R(0, 0, 0, 0, 0, PTW_VA, 0, PTW_VA), 1);
    ptw_check(ALIAS_VA);
    row(N("PT write trap+shadow+tlbi vale1 (nsh), EL1"), 100000, t_ptw, 1, v_ptw_el1_nsh, v_none, h, HOST_NONE,
        R(0, 0, 0, 0, 0, PTW_VA, 0, PTW_VA), 1);
    row(N("dsb+isb baseline, EL1"), 200000, t_dsb_isb, 1, v_none, v_none, h, HOST_NONE, R(0), 1);
    row(N("tlbi vale1, EL1"), 100000, t_tlbi_vale1, 1, v_none, v_none, h, HOST_NONE, R(0, ASID << 48 | PTW_VA >> 12), 1);
    row(N("tlbi vale1is, EL1"), 100000, t_tlbi_vale1is, 1, v_none, v_none, h, HOST_NONE,
        R(0, ASID << 48 | PTW_VA >> 12), 1);
    row(N("tlbi aside1is, EL1"), 50000, t_tlbi_aside1is, 1, v_none, v_none, h, HOST_NONE, R(0, 7ULL << 48), 1);
    row(N("tlbi vmalle1is, EL1"), 20000, t_tlbi_vmalle1is, 1, v_none, v_none, h, HOST_NONE, R(0), 1);
    row(N("ttbr0_el1 ASID switch+isb, EL1"), 100000, t_ttbr_el1, 1, v_none, v_none, h, HOST_NONE,
        R(0, S1_ROOT | 2ULL << 48, S1_ROOT | ASID << 48), 2);
    row(N("exit to host: unmapped load, EL1"), 50000, t_mmio, 1, v_none, v_none, h, HOST_MMIO, R(0, 0, 0, 0, 0, MMIO_IPA),
        1);
    row(N("exit to host: unmapped load, EL0"), 50000, t_mmio, 0, v_none, v_none, h, HOST_MMIO, R(0, 0, 0, 0, 0, MMIO_IPA),
        1);
}

static void mode_plain(bool ipa16) {
    rows_common(0, "plain");
    row("plain exit to host: hvc, EL1", 50000, t_hvc, 1, v_none, v_none, 0, HOST_NONE, R(0), 1);
    if (ipa16)
        return;
    CHECK(hv_vm_protect(S2PT_VA, 4096, HV_MEMORY_READ | HV_MEMORY_EXEC));
    row("plain exit to host: S2 write trap, emulate", 50000, t_store, 1, v_none, v_none, 0, HOST_STORE,
        R(0, 0, 0, 0, 0, S2PT_VA), 1);
    row("plain host PT write trap+shadow+guest tlbi", 30000, t_ptw, 1, v_none, v_none, 0, HOST_PTW,
        R(0, 0, 0, 0, 0, S2PT_VA, 0, PTW_VA), 1);
    ptw_check(S2PT_VA);
}

static void mode_el2(void) {
    u64 base = HCR_RW;
    // First the simplest possible vEL2 use: no guest stage 2.
    row("vEL2 loop baseline at vEL2", 1000000, t_nop, 2, v_none, v_none, base, HOST_NONE, R(0), 1);
    row("vEL2 eret to vEL2 at vEL2", 100000, t_eret_self, 2, v_none, v_none, base, HOST_NONE, R(0), 1);
    row("vEL2 mrs+msr elr_el2 at vEL2", 100000, t_elr_el2, 2, v_none, v_none, base, HOST_NONE, R(0), 1);
    row("vEL2 mrs+msr hcr_el2 at vEL2", 20000, t_hcr_el2, 2, v_none, v_none, base, HOST_NONE, R(0), 1);
    row("vEL2 mrs+msr vttbr_el2+isb at vEL2", 20000, t_vttbr_el2, 2, v_none, v_none, base, HOST_NONE, R(0), 1);
    row("vEL2 EL1-vEL2-EL1 hvc/eret", 100000, t_hvc, 1, v_none, v_eret, base, HOST_NONE, R(0), 1);
    row("vEL2 EL0-vEL2-EL0 trapped mrs", 100000, t_ctr, 0, v_none, v_skip_el2, base | HCR_TID2, HOST_NONE, R(0), 1);
    row("vEL2 EL1-vEL2-EL1 trapped mrs", 100000, t_ctr, 1, v_none, v_skip_el2, base | HCR_TID2, HOST_NONE, R(0), 1);
    row("vEL2 translated syscall+sysret, EL0-vEL2", 100000, t_syscall_trap, 0, v_none, v_syscall_el2, base | HCR_TID2,
        HOST_NONE, R(0, 0, 0, 0, DATA_VA + 0x20000), 1);
    row("vEL2 tlbi vale1is at vEL2", 50000, t_tlbi_vale1is, 2, v_none, v_none, base, HOST_NONE,
        R(0, ASID << 48 | PTW_VA >> 12), 1);
    row("vEL2 tlbi vmalls12e1is at vEL2", 20000, t_tlbi_vmalls12e1is, 2, v_none, v_none, base, HOST_NONE, R(0), 1);
    row("vEL2 tlbi ipas2e1is at vEL2", 20000, t_tlbi_ipas2e1is, 2, v_none, v_none, base, HOST_NONE,
        R(0, 0, PTW_VA >> 12), 1);
    row("vEL2 ttbr0_el1 write+isb at vEL2", 50000, t_ttbr_el1, 2, v_none, v_none, base, HOST_NONE,
        R(0, S1_ROOT | 2ULL << 48, S1_ROOT | ASID << 48), 2);
    row("vEL2 exit to host: unmapped load, vEL2", 50000, t_mmio, 2, v_none, v_none, base, HOST_MMIO,
        R(0, 0, 0, 0, 0, MMIO_IPA), 1);
    // With a guest stage 2 under EL1/EL0.
    u64 vm = base | HCR_VM;
    rows_common(base, "EL2-on VM=0");
    rows_common(vm, "EL2-on VM=1");
    row("VM=1 S2 perm fault, emulate at vEL2, EL1", 100000, t_store, 1, v_none, v_s2_emul, vm, HOST_NONE,
        R(0, 0, 0, 0, 0, S2PT_VA), 1);
    row("VM=1 S2 perm fault, emulate at vEL2, EL0", 100000, t_store, 0, v_none, v_s2_emul, vm, HOST_NONE,
        R(0, 0, 0, 0, 0, S2PT_VA), 1);
    row("VM=1 PT write via S2 fault+shadow+tlbi, vEL2", 50000, t_ptw, 1, v_none, v_ptw_el2_is, vm, HOST_NONE,
        R(0, 0, 0, 0, 0, S2PT_VA, 0, PTW_VA), 1);
    ptw_check(S2PT_VA);
}

static void mode_hcr(void) {
    u64 v;
#define ID(r) do { CHECK(hv_vcpu_get_sys_reg(cpu0.v, HV_SYS_REG_##r, &v)); printf("%-20s %016llx\n", #r, v); } while (0)
    ID(ID_AA64MMFR0_EL1);
    ID(ID_AA64MMFR1_EL1);
    ID(ID_AA64MMFR2_EL1);
    ID(ID_AA64PFR0_EL1);
    u64 rw = HCR_RW;
    u64 tries[] = {rw, rw | 1ULL << 34 /* E2H */, rw | 1ULL << 27 /* TGE */, rw | HCR_VM};
    for (int i = 0; i < 4; i++) {
        cpu_start(&cpu0, G(t_hcr_probe), 2, 0x3C0, s_eret, G(v_none), G(v_none), HCR_RW);
        CHECK(hv_vcpu_set_reg(cpu0.v, HV_REG_X1, tries[i]));
        CHECK(hv_vcpu_set_reg(cpu0.v, HV_REG_X27, 0));
        cpu_run(&cpu0, HOST_NONE);
        u64 r0, r2, r3, r4, h;
        CHECK(hv_vcpu_get_reg(cpu0.v, HV_REG_X0, &r0));
        CHECK(hv_vcpu_get_reg(cpu0.v, HV_REG_X2, &r2));
        CHECK(hv_vcpu_get_reg(cpu0.v, HV_REG_X3, &r3));
        CHECK(hv_vcpu_get_reg(cpu0.v, HV_REG_X4, &r4));
        CHECK(hv_vcpu_get_sys_reg(cpu0.v, HV_SYS_REG_HCR_EL2, &h));
        printf("guest wrote hcr %llx read %llx host then reads %llx currentel %llx tcr %llx sctlr %llx\n", tries[i], r0, h,
               r2, r3, r4);
    }
}

static void mode_chase(void) {
    chain_build(CHASE_VA, CHASE_SIZE - 0x4000);
    chain_build(CHASE_VA + CHASE_SIZE - 0x4000, 0x4000);
    u64 small = CHASE_VA + CHASE_SIZE - 0x4000;
    Regs big = R(CHASE_VA), lil = R(small);
    tables_build(true, false);
    if (!el2_vm) {
        row("chase 16 KB, EL0, S1 4K", 3000000, t_chase, 0, v_none, v_none, 0, HOST_NONE, lil, 1);
        row("chase 64 MB, EL0, S1 4K", 1000000, t_chase, 0, v_none, v_none, 0, HOST_NONE, big, 1);
        tables_build(false, false);
        row("chase 64 MB, EL0, S1 2M", 1000000, t_chase, 0, v_none, v_none, 0, HOST_NONE, big, 1);
        return;
    }
    u64 base = HCR_RW;
    row("chase 16 KB, EL0, S1 4K, VM=0", 3000000, t_chase, 0, v_none, v_none, base, HOST_NONE, lil, 1);
    row("chase 64 MB, EL0, S1 4K, VM=0", 1000000, t_chase, 0, v_none, v_none, base, HOST_NONE, big, 1);
    row("chase 16 KB, EL0, S1 4K, guest S2 2M", 3000000, t_chase, 0, v_none, v_none, base | HCR_VM, HOST_NONE, lil, 1);
    row("chase 64 MB, EL0, S1 4K, guest S2 2M", 1000000, t_chase, 0, v_none, v_none, base | HCR_VM, HOST_NONE, big, 1);
    tables_build(true, true);
    row("chase 64 MB, EL0, S1 4K, guest S2 4K", 1000000, t_chase, 0, v_none, v_none, base | HCR_VM, HOST_NONE, big, 1);
    row("chase 64 MB, vEL2, S1 4K", 1000000, t_chase, 2, v_none, v_none, base, HOST_NONE, big, 1);
    tables_build(false, true);
    row("chase 64 MB, EL0, S1 2M, guest S2 4K", 1000000, t_chase, 0, v_none, v_none, base | HCR_VM, HOST_NONE, big, 1);
    tables_build(false, false);
    row("chase 64 MB, EL0, S1 2M, guest S2 2M", 1000000, t_chase, 0, v_none, v_none, base | HCR_VM, HOST_NONE, big, 1);
}

// ---- Two vCPUs ----
typedef struct {
    Cpu c;
    u64 mpidr;
    bool tso;
    char *pc, *vbar1, *vbar2;
    int level;
    u64 daif, hcr;
    Regs regs;
    u64 n;
    int kind;
    u64 result;
    atomic_int ready;
    atomic_int stop;
    void *peer;
    double elapsed, best;
    int reps;
    u64 wfi_exits, irq_exits, cancels;
    semaphore_t sem;
} Vc;
static atomic_int go;

enum { K_FOREVER, K_IRQ_HOST, K_WFI_HOST };

static void vc_prepare(Vc *a) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    cpu_init(&a->c, a->mpidr, a->tso);
    if (use_gic) {
        hv_vcpu_t v = a->c.v;
        CHECK(hv_gic_set_redistributor_reg(v, HV_GIC_REDISTRIBUTOR_REG_GICR_IGROUPR0, ~0u));
        CHECK(hv_gic_set_redistributor_reg(v, HV_GIC_REDISTRIBUTOR_REG_GICR_ISENABLER0, 0xffff));
        // Routing written before a vCPU exists does not take: SPIs stayed pending and undelivered until this moved here.
        if (!a->mpidr)
            CHECK(hv_gic_set_distributor_reg(HV_GIC_DISTRIBUTOR_REG_GICD_IROUTER32, 0));
        hv_ipa_t rd;
        CHECK(hv_gic_get_redistributor_base(v, &rd));
        CHECK(hv_vcpu_set_reg(v, HV_REG_X26, rd)); // GIC_ON wakes its redistributor; the API has no GICR_WAKER
    }
    cpu_start(&a->c, G(a->pc), a->level, a->daif, s_eret, G(a->vbar1), G(a->vbar2), a->hcr);
    for (int k = 0; k < 8; k++)
        CHECK(hv_vcpu_set_reg(a->c.v, arg_regs[k], a->regs.r[k]));
    CHECK(hv_vcpu_set_reg(a->c.v, HV_REG_X24, a->n));
    atomic_store(&a->ready, 1);
    while (!atomic_load(&go))
        ;
}

// Generic vCPU thread. HVC #2 acks a host-injected IRQ, HVC #3 is a host-carried IPI to the peer.
static void *vc_thread(void *p) {
    Vc *a = p;
    vc_prepare(a);
    bool pend = false;
    double t = now();
    for (;;) {
        if (pend)
            CHECK(hv_vcpu_set_pending_interrupt(a->c.v, HV_INTERRUPT_TYPE_IRQ, true));
        CHECK(hv_vcpu_run(a->c.v));
        hv_vcpu_exit_t *x = a->c.x;
        if (x->reason == HV_EXIT_REASON_CANCELED) {
            a->cancels++;
            if (atomic_load(&a->stop))
                break;
            if (a->kind != K_FOREVER)
                pend = true;
            continue;
        }
        if (x->reason != HV_EXIT_REASON_EXCEPTION)
            cpu_diag(&a->c, "vc exit");
        u32 ec = x->exception.syndrome >> 26, imm = x->exception.syndrome & 0xffff;
        if (ec == 0x16 && imm == 2) {
            a->irq_exits++;
            pend = false;
            continue;
        }
        if (ec == 0x16 && imm == 3) {
            Vc *peer = (Vc *)a->peer;
            CHECK(hv_vcpus_exit(&peer->c.v, 1));
            pend = false;
            continue;
        }
        if (ec == 1) { // WFI or WFE reached the host
            a->wfi_exits++;
            u64 pc;
            CHECK(hv_vcpu_get_reg(a->c.v, HV_REG_PC, &pc));
            CHECK(hv_vcpu_set_reg(a->c.v, HV_REG_PC, pc + 4));
            if (a->kind == K_WFI_HOST) {
                semaphore_wait(a->sem);
                if (atomic_load(&a->stop))
                    break;
                pend = true;
            }
            continue;
        }
        if ((ec == 0x24 || ec == 0x25) && x->exception.physical_address == EXIT_IPA) {
            u64 x27;
            CHECK(hv_vcpu_get_reg(a->c.v, HV_REG_X27, &x27));
            if (x27)
                cpu_diag(&a->c, "guest vector");
            double d = now() - t;
            if (a->best == 0 || d < a->best)
                a->best = d;
            if (--a->reps > 0) { // again on the same vCPU; a GIC VM's vCPUs must live to teardown
                cpu_start(&a->c, G(a->pc), a->level, a->daif, s_eret, G(a->vbar1), G(a->vbar2), a->hcr);
                for (int k = 0; k < 8; k++)
                    CHECK(hv_vcpu_set_reg(a->c.v, arg_regs[k], a->regs.r[k]));
                CHECK(hv_vcpu_set_reg(a->c.v, HV_REG_X24, a->n));
                t = now();
                continue;
            }
            break;
        }
        cpu_diag(&a->c, "vc syndrome");
    }
    a->elapsed = now() - t;
    CHECK(hv_vcpu_get_reg(a->c.v, HV_REG_X3, &a->result));
    CHECK(hv_vcpu_destroy(a->c.v)); // owner thread only
    return NULL;
}

static void wait_ready(Vc *a) {
    while (!atomic_load(&a->ready))
        ;
}

// Message-passing litmus at the given level with TSO on and off.
static void mode_litmus(void) {
    u64 n = 30000000, flag = DATA_VA + 0x3000, data = DATA_VA + 0x2000, base = HCR_RW;
    struct {
        const char *name;
        int level;
        u64 hcr;
    } cases[] = {{"EL0", 0, el2_vm ? base | HCR_VM : 0}, {"EL1", 1, el2_vm ? base | HCR_VM : 0}, {"vEL2", 2, base}};
    int count = el2_vm ? 3 : 2;
    for (int i = 0; i < count; i++)
        for (int tso = 0; tso < 2; tso++) {
            memset(ram + (data - RAM_IPA), 0, 0x2000);
            Vc w = {.tso = tso, .pc = t_lit_writer, .vbar1 = v_none, .vbar2 = v_none, .level = cases[i].level,
                    .daif = 0x3C0, .hcr = cases[i].hcr, .regs = R(data, flag, n), .mpidr = 0},
               r = w;
            r.pc = t_lit_reader;
            r.mpidr = 1;
            atomic_store(&go, 0);
            pthread_t a, b;
            pthread_create(&a, NULL, vc_thread, &w);
            pthread_create(&b, NULL, vc_thread, &r);
            wait_ready(&w);
            wait_ready(&r);
            atomic_store(&go, 1);
            pthread_join(a, NULL);
            pthread_join(b, NULL);
            printf("litmus %-10s EnTSO=%d: %llu violations in %lluM reads (%.1f ns/read)\n", cases[i].name, tso, r.result,
                   n / 1000000, r.elapsed / n);
        }
}

// Interrupt latency from another host thread: from the first host call until the guest handler has stored the flag.
#define FLAG (DATA_VA + 0x2000)
static double latency_batches(const char *name, Vc *a, int iters, int gap_us, void (*fire)(Vc *, u64)) {
    volatile u64 *flag = VP(FLAG);
    double best = 1e30, worst = 0, best_min = 1e30;
    for (int b = 0; b < 5; b++) {
        double sum = 0;
        for (int i = 0; i < iters; i++) {
            if (gap_us)
                usleep(gap_us);
            else {
                double spin = now() + 20000;
                while (now() < spin)
                    ;
            }
            u64 before = *flag;
            double t = now();
            fire(a, 1);
            double deadline = t + 100e6;
            while (*flag == before)
                if (now() > deadline)
                    DIE("%s: no interrupt reached the guest in 100 ms (wfi exits %llu, cancels %llu)", name, a->wfi_exits,
                        a->cancels);
            t = now() - t;
            fire(a, 0);
            sum += t;
            if (t < best_min)
                best_min = t;
        }
        sum /= iters;
        if (sum < best)
            best = sum;
        if (sum > worst)
            worst = sum;
    }
    printf("%-44s %10.1f ns  (worst batch %10.1f, fastest event %10.1f; wfi exits %llu)\n", name, best, worst, best_min,
           a->wfi_exits);
    return best;
}
static void fire_cancel(Vc *a, u64 on) {
    if (on)
        CHECK(hv_vcpus_exit(&a->c.v, 1));
}
static void fire_sem(Vc *a, u64 on) {
    if (on)
        semaphore_signal(a->sem);
}
static u32 spi_intid;
static void fire_spi(Vc *a, u64 on) {
    (void)a;
    CHECK(hv_gic_set_spi(spi_intid, on));
}

static void vc_stop(Vc *a, pthread_t th) {
    atomic_store(&a->stop, 1);
    if (a->kind == K_WFI_HOST)
        semaphore_signal(a->sem);
    CHECK(hv_vcpus_exit(&a->c.v, 1));
    pthread_join(th, NULL);
}

static void mode_irq(void) {
    for (int wfi = 0; wfi < 2; wfi++) {
        *VP(FLAG) = 0;
        static Vc a;
        memset(&a, 0, sizeof a);
        a.pc = wfi ? t_wfi : t_spin;
        a.vbar1 = a.vbar2 = v_irq_flag_hvc;
        a.level = 1;
        a.daif = 0x340;
        a.regs = R(0, 0, 0, FLAG);
        a.kind = wfi ? K_WFI_HOST : K_IRQ_HOST;
        semaphore_create(mach_task_self(), &a.sem, SYNC_POLICY_FIFO, 0);
        atomic_store(&go, 1);
        pthread_t th;
        pthread_create(&th, NULL, vc_thread, &a);
        wait_ready(&a);
        double spin = now() + 2e6;
        while (now() < spin)
            ;
        if (wfi)
            latency_batches("host: semaphore wake, inject, WFI guest", &a, 300, 200, fire_sem);
        else
            latency_batches("host: hv_vcpus_exit, inject, busy guest", &a, 1000, 0, fire_cancel);
        printf("  cancels %llu, irq acks %llu\n", a.cancels, a.irq_exits);
        vc_stop(&a, th);
    }
}

static void gic_setup(void) {
    size_t da, ra, ds, rs;
    CHECK(hv_gic_get_distributor_base_alignment(&da));
    CHECK(hv_gic_get_redistributor_base_alignment(&ra));
    CHECK(hv_gic_get_distributor_size(&ds));
    CHECK(hv_gic_get_redistributor_region_size(&rs));
    printf("gic: distributor size %zx align %zx, redistributor region %zx align %zx\n", ds, da, rs, ra);
    if ((GICD_IPA & (da - 1)) || (GICR_IPA & (ra - 1)))
        DIE("GIC base misaligned");
    hv_gic_config_t cfg = hv_gic_config_create();
    CHECK(hv_gic_config_set_distributor_base(cfg, GICD_IPA));
    CHECK(hv_gic_config_set_redistributor_base(cfg, GICR_IPA));
    CHECK(hv_gic_create(cfg));
    u32 base, count;
    CHECK(hv_gic_get_spi_interrupt_range(&base, &count));
    if (base != 32)
        DIE("SPI base %u", base);
    spi_intid = base;
    CHECK(hv_gic_set_distributor_reg(HV_GIC_DISTRIBUTOR_REG_GICD_CTLR, 0x12));
    CHECK(hv_gic_set_distributor_reg(HV_GIC_DISTRIBUTOR_REG_GICD_IGROUPR1, ~0u));
    CHECK(hv_gic_set_distributor_reg(HV_GIC_DISTRIBUTOR_REG_GICD_ICFGR2, 2));
    CHECK(hv_gic_set_distributor_reg(HV_GIC_DISTRIBUTOR_REG_GICD_ISENABLER1, 1));
}

static void mode_irq_gic(u64 hcr, int wfi) {
    {
        *VP(FLAG) = 0;
        static Vc a;
        memset(&a, 0, sizeof a);
        a.pc = wfi ? t_gic_wfi : t_gic_spin;
        a.vbar1 = a.vbar2 = v_irq_flag_gic;
        a.level = 1;
        a.daif = 0x340;
        a.hcr = hcr;
        a.regs = R(0, 0, 0, FLAG);
        a.kind = K_FOREVER;
        atomic_store(&go, 1);
        pthread_t th;
        pthread_create(&th, NULL, vc_thread, &a);
        wait_ready(&a);
        double spin = now() + 2e6;
        while (now() < spin)
            ;
        latency_batches(wfi ? "gic: hv_gic_set_spi, WFI guest" : "gic: hv_gic_set_spi, busy guest", &a, wfi ? 300 : 1000,
                        wfi ? 200 : 0, fire_spi);
        vc_stop(&a, th);
    }
}

// Round trip between two vCPUs, best of 5 runs of A's loop, printed as half, the one-way cost.
static void ipi_pair(const char *name, char *apc, char *avec, char *bpc, char *bvec, Regs ar, Regs br, u64 n, int bkind,
                     u64 hcr) {
    static Vc a, b;
    *VP(FLAG) = 0;
    memset(ram + (DATA_VA + 0x2000 - RAM_IPA), 0, 0x2000);
    a = (Vc){.mpidr = 0, .pc = apc, .vbar1 = avec, .vbar2 = avec, .level = 1, .daif = 0x340, .regs = ar, .n = n,
             .kind = K_IRQ_HOST, .hcr = hcr, .reps = 5};
    b = (Vc){.mpidr = 1, .pc = bpc, .vbar1 = bvec, .vbar2 = bvec, .level = 1, .daif = 0x340, .regs = br, .n = ~0ULL,
             .kind = bkind, .hcr = hcr};
    a.peer = &b;
    b.peer = &a;
    atomic_store(&go, 0);
    pthread_t ta, tb;
    pthread_create(&ta, NULL, vc_thread, &a);
    pthread_create(&tb, NULL, vc_thread, &b);
    wait_ready(&a);
    wait_ready(&b);
    atomic_store(&go, 1);
    pthread_join(ta, NULL);
    atomic_store(&b.stop, 1);
    CHECK(hv_vcpus_exit(&b.c.v, 1));
    pthread_join(tb, NULL);
    printf("%-44s %10.1f ns one-way  (A cancels %llu, B wfi exits %llu)\n", name, a.best / n / 2, a.cancels, b.wfi_exits);
}

int main(int argc, char **argv) {
    alarm(25);
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *mode = argc > 1 ? argv[1] : "plain";
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    tick_ns = (double)tb.numer / tb.denom;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    el2_vm = argc > 2 && !strcmp(argv[2], "el2");
    if (!strcmp(mode, "el2") || !strcmp(mode, "hcr"))
        el2_vm = true;
    bool ipa16 = getenv("SPIKE_IPA16") != NULL;
    bool sup = false;
    CHECK(hv_vm_config_get_el2_supported(&sup));
    hv_vm_config_t cfg = hv_vm_config_create();
    CHECK(hv_vm_config_set_ipa_granule(cfg, ipa16 ? HV_IPA_GRANULE_16KB : HV_IPA_GRANULE_4KB));
    if (el2_vm) {
        if (!sup)
            DIE("EL2 not supported");
        CHECK(hv_vm_config_set_el2_enabled(cfg, true));
    }
    u32 ipa_bits = 0;
    CHECK(hv_vm_config_get_max_ipa_size(&ipa_bits));
    CHECK(hv_vm_create(cfg));
    printf("mode %s, el2 supported %d enabled %d, host IPA granule %s, max IPA %u bits\n", mode, sup, el2_vm,
           ipa16 ? "16K" : "4K", ipa_bits);

    ram = mmap(0, RAM_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (ram == MAP_FAILED)
        DIE("mmap");
    CHECK(hv_vm_map(ram, RAM_IPA, RAM_SIZE, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC));
    memcpy(ram, g_start, g_end - g_start);
    tables_build(true, false);
    data_init();

    if (!strcmp(mode, "irq")) {
        mode_irq();
        return 0;
    }
    if (!strncmp(mode, "irq-gic", 7) || !strncmp(mode, "ipi-gic", 7)) {
        use_gic = true;
        gic_setup();
    }
    u64 base = el2_vm ? HCR_RW : 0;
    if (!strncmp(mode, "irq-gic", 7)) {
        mode_irq_gic(base, !strcmp(mode, "irq-gic-wfi"));
        return 0;
    }
    u64 sgi_to_0 = 1ULL | 1ULL << 24, sgi_to_1 = 2ULL | 1ULL << 24, f = FLAG, w2 = DATA_VA + 0x3000;
    u64 n = 100000;
    if (!strcmp(mode, "ipi-gic")) {
        ipi_pair("IPI via GIC SGI, peer busy", t_ipi_gic, v_irq_flag_gic, t_gic_spin, v_irq_pong_gic, R(sgi_to_1, 0, 0, f),
                 R(sgi_to_0), n / 4, K_FOREVER, base);
        return 0;
    }
    if (!strcmp(mode, "ipi-gic-wfi")) {
        ipi_pair("IPI via GIC SGI, peer in WFI", t_ipi_gic, v_irq_flag_gic, t_gic_wfi, v_irq_pong_gic, R(sgi_to_1, 0, 0, f),
                 R(sgi_to_0), n / 4, K_FOREVER, base);
        return 0;
    }
    if (!strcmp(mode, "ipi-host")) {
        ipi_pair("shared-memory poll", t_poll_a, v_none, t_poll_b, v_none, R(0, 0, 0, f, w2), R(0, 0, 0, f, w2), n * 20,
                 K_FOREVER, base);
        ipi_pair("IPI carried by host, peer busy", t_ipi_hvc, v_irq_flag_hvc, t_spin, v_irq_pong_hvc, R(0, 0, 0, f), R(0),
                 n / 4, K_IRQ_HOST, base);
        return 0;
    }

    if (!strcmp(mode, "litmus")) {
        mode_litmus();
        return 0;
    }
    cpu_init(&cpu0, 0, true);
    if (!strcmp(mode, "plain"))
        mode_plain(ipa16);
    else if (!strcmp(mode, "el2"))
        mode_el2();
    else if (!strcmp(mode, "chase"))
        mode_chase();
    else if (!strcmp(mode, "hcr"))
        mode_hcr();
    else
        DIE("modes: plain, el2, chase [el2], litmus [el2], irq, irq-gic[-wfi] [el2], ipi-gic[-wfi] [el2], ipi-host");
    return 0;
}
