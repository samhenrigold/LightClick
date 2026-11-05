/*
 * hvdbt: run a guest's 64-bit code in Source/Engine, the x86 translator inside a Hypervisor.framework VM, with TCG as its other half.
 *
 * Off unless LC_HVDBT=1, on a build configured with -Dhvdbt_engine. TCG runs the firmware and the boot loaders. On the first TB miss in the high half in
 * 64-bit mode, which is XNU's vstart, this file loads the engine's state from CPUX86State and runs it on the vCPU thread. Whatever the engine can't do
 * comes back as ENGINE_RUN_FALLBACK: TCG runs that one instruction and, through the same TB miss, control returns. An instruction that leaves 64-bit
 * mode (iret to a 32-bit process, say) just means TCG goes on running until a TB miss finds the state acceptable again. Since a normal TB is never
 * generated for an acceptable state, there is always a miss to catch.
 *
 * The APIC stays QEMU's, for both halves: the engine's in-VM one is off. So APIC accesses go through the host here, which DESIGN.md's rates don't assume.
 * Device models, timers and vCPU stop and start are all TCG's loop, unchanged. Single vCPU only.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/main-loop.h"
#include "qemu/rcu.h"
#include "qemu/timer.h"
#include "cpu.h"
#include "accel/tcg/handoff.h"
#include "exec/cputlb.h"
#include "exec/target_page.h"
#include "exec/tb-flush.h"
#include "exec/translation-block.h"
#include "hw/core/boards.h"
#include "hw/core/cpu.h"
#include "hw/i386/apic.h"
#include "hw/i386/x86.h"
#include "system/address-spaces.h"
#include "system/cpu-timers.h"
#include "system/cpus.h"
#include "system/memory.h"
#include "system/physmem.h"
#include "system/runstate.h"
#include "system/tcg.h"
#include "engine_api.h"

#define HIGH_RAM (1ULL << 32)
/* What the monitor's CR4_OK allows. */
#define ENGINE_CR4 (CR4_TSD_MASK | CR4_DE_MASK | CR4_PSE_MASK | CR4_PAE_MASK | CR4_PGE_MASK | CR4_OSFXSR_MASK | CR4_OSXMMEXCPT_MASK | \
                    CR4_PCIDE_MASK | CR4_SMEP_MASK)
#define OTHER_INTERRUPTS (CPU_INTERRUPT_NMI | CPU_INTERRUPT_SMI | CPU_INTERRUPT_INIT | CPU_INTERRUPT_SIPI | CPU_INTERRUPT_MCE)

static struct {
    EngineHandle *engine;
    bool dead;
    bool in_engine;
    bool tcg_ran; /* normal TBs have been generated: engine writes may have made them stale, and nothing tells TCG */
    ram_addr_t ram_base;
    uint64_t ram_bytes, below_4g;
    /* Pages TCG wrote since DIRTY_MEMORY_CODE was last cleared for them. Only the vCPU thread touches this. */
    ram_addr_t written[64];
    unsigned written_count;
    bool protect_all;
} hv;

/* ---- Devices: the vCPU thread, BQL taken here, as TCG's slow path would. ---- */

/* A device model running here can raise an interrupt or stop this vCPU, with no kick since it is on the vCPU's own thread. */
static void hvdbt_after_device(CPUState *cs)
{
    if (cpu_test_interrupt(cs, CPU_INTERRUPT_HARD | CPU_INTERRUPT_POLL)) {
        engine_set_irq_line(hv.engine, true);
    }
    if (cpu_test_interrupt(cs, OTHER_INTERRUPTS) || !cpu_can_run(cs) || !cpu_work_list_empty(cs)) {
        engine_request_boundary(hv.engine);
    }
}

static uint64_t hvdbt_mmio_read(void *opaque, uint64_t gpa, unsigned size)
{
    uint64_t v = 0;
    bql_lock();
    address_space_read(&address_space_memory, gpa, MEMTXATTRS_UNSPECIFIED, &v, size);
    hvdbt_after_device(opaque);
    bql_unlock();
    return v;
}

static void hvdbt_mmio_write(void *opaque, uint64_t gpa, unsigned size, uint64_t value)
{
    bql_lock();
    address_space_write(&address_space_memory, gpa, MEMTXATTRS_UNSPECIFIED, &value, size);
    hvdbt_after_device(opaque);
    bql_unlock();
}

static uint32_t hvdbt_port_read(void *opaque, uint16_t port, unsigned size)
{
    uint32_t v = 0;
    bql_lock();
    address_space_read(&address_space_io, port, MEMTXATTRS_UNSPECIFIED, &v, size);
    hvdbt_after_device(opaque);
    bql_unlock();
    return v;
}

static void hvdbt_port_write(void *opaque, uint16_t port, unsigned size, uint32_t value)
{
    bql_lock();
    address_space_write(&address_space_io, port, MEMTXATTRS_UNSPECIFIED, &value, size);
    hvdbt_after_device(opaque);
    bql_unlock();
}

/* The monitor keeps the syscall MSRs and sends the rest back as fallbacks, so these never run in hybrid mode. */
static bool hvdbt_read_msr(void *opaque, uint32_t msr, uint64_t *value)
{
    return false;
}

static bool hvdbt_write_msr(void *opaque, uint32_t msr, uint64_t value)
{
    return false;
}

static void hvdbt_cpuid(void *opaque, uint32_t leaf, uint32_t subleaf, uint32_t out[4])
{
    CPUState *cs = opaque;
    cpu_x86_cpuid(cpu_env(cs), leaf, subleaf, &out[0], &out[1], &out[2], &out[3]);
}

static bool hvdbt_has_interrupt(void *opaque)
{
    CPUState *cs = opaque;
    bool hard;

    bql_lock();
    if (cpu_test_interrupt(cs, CPU_INTERRUPT_POLL)) { /* what the IO-APIC raises from another thread, as x86_cpu_exec_interrupt handles it */
        cpu_reset_interrupt(cs, CPU_INTERRUPT_POLL);
        apic_poll_irq(X86_CPU(cs)->apic_state);
    }
    if (cpu_test_interrupt(cs, OTHER_INTERRUPTS)) { /* TCG delivers these, when the boundary stop gets back to its loop */
        engine_request_boundary(hv.engine);
    }
    hard = cpu_test_interrupt(cs, CPU_INTERRUPT_HARD);
    bql_unlock();
    return hard;
}

static int hvdbt_acknowledge_interrupt(void *opaque)
{
    CPUState *cs = opaque;
    int vector;

    bql_lock();
    cpu_reset_interrupt(cs, CPU_INTERRUPT_HARD);
    vector = cpu_get_pic_interrupt(cpu_env(cs));
    bql_unlock();
    return vector;
}

/* hlt comes back as a fallback, and the APIC's EOI and ICR are MMIO to QEMU's model. */
static bool hvdbt_wait(void *opaque, uint64_t deadline_ns)
{
    return false;
}

static void hvdbt_apic_eoi(void *opaque, uint8_t vector)
{
}

static void hvdbt_apic_icr(void *opaque, uint64_t icr)
{
}

/* ---- State ---- */

static bool hvdbt_read_descriptor(CPUState *cs, uint16_t sel, uint32_t *e, unsigned words)
{
    CPUX86State *env = cpu_env(cs);
    uint64_t table = sel & 4 ? env->ldt.base : env->gdt.base;
    uint8_t bytes[16];

    if (cpu_memory_rw_debug(cs, table + (sel & ~7), bytes, words * 4, false)) {
        return false;
    }
    for (unsigned i = 0; i < words; i++) {
        e[i] = ldl_le_p(bytes + i * 4);
    }
    return true;
}

static uint64_t hvdbt_desc_base(const uint32_t *e)
{
    return (e[0] >> 16) | ((e[1] & 0xff) << 16) | (e[1] & 0xff000000);
}

static uint32_t hvdbt_desc_limit(const uint32_t *e)
{
    uint32_t limit = (e[0] & 0xffff) | (e[1] & 0x000f0000);
    return e[1] & DESC_G_MASK ? (limit << 12) | 0xfff : limit;
}

/* Only descriptors for a changed selector are read. A change of GDT contents under the same selector is not noticed. */
static void hvdbt_load_segment(CPUState *cs, X86Seg seg, uint16_t sel, uint32_t cpl)
{
    CPUX86State *env = cpu_env(cs);
    uint32_t e[2] = { 0, 0 };

    if (env->segs[seg].selector == sel && (seg != R_SS || ((env->segs[R_SS].flags >> DESC_DPL_SHIFT) & 3) == cpl)) {
        return;
    }
    if (sel & ~3) {
        hvdbt_read_descriptor(cs, sel, e, 2);
    }
    if (seg == R_SS) { /* CPL is what TCG reads from here, and the engine keeps SS null in ring 0 */
        e[1] = (e[1] & ~DESC_DPL_MASK) | (cpl << DESC_DPL_SHIFT);
    }
    cpu_x86_load_seg_cache(env, seg, sel, hvdbt_desc_base(e), hvdbt_desc_limit(e), e[1]);
}

static void hvdbt_put_state(CPUState *cs)
{
    CPUX86State *env = cpu_env(cs);
    EngineX86State s;

    engine_get_state(hv.engine, &s);
    memcpy(s.gpr, env->regs, sizeof s.gpr);
    s.rip = env->eip;
    s.rflags = env->eflags; /* cpu_exec_exit made it whole */
    s.cr0 = env->cr[0];
    s.cr2 = env->cr[2];
    s.cr3 = env->cr[3];
    s.cr4 = env->cr[4];
    s.efer = env->efer;
    s.star = env->star;
    s.lstar = env->lstar;
    s.cstar = env->cstar;
    s.sfmask = env->fmask;
    s.fs_base = env->segs[R_FS].base;
    s.gs_base = env->segs[R_GS].base;
    s.kernel_gs_base = env->kernelgsbase;
    s.gdt_base = env->gdt.base;
    s.gdt_limit = env->gdt.limit;
    s.idt_base = env->idt.base;
    s.idt_limit = env->idt.limit;
    s.tss_base = env->tr.base;
    s.tss_limit = env->tr.limit;
    for (int i = 0; i < 6; i++) {
        s.sel[i] = env->segs[i].selector; /* the same order: es cs ss ds fs gs */
    }
    s.tr = env->tr.selector;
    s.ldtr = env->ldt.selector;
    s.cpl = env->hflags & HF_CPL_MASK;
    update_mxcsr_from_sse_status(env);
    s.mxcsr = env->mxcsr;
    for (int i = 0; i < 16; i++) {
        s.xmm[i][0] = env->xmm_regs[i].ZMM_Q(0);
        s.xmm[i][1] = env->xmm_regs[i].ZMM_Q(1);
    }
    engine_set_state(hv.engine, &s);

    /* The TSC is the same clock on both sides, cpu_get_tsc's steps with cpu_get_tsc's offsets. */
    uint32_t khz = env->user_tsc_khz;
    uint64_t num = khz > 1000000 ? khz - 1000000 : 0, den = 1000000, g = den;
    for (uint64_t r = num; r; ) { /* gcd: keeps ns * num in range, and 1.2 GHz is exactly floor(ns / 5), as cpu_get_tsc has it */
        uint64_t next = g % r;
        g = r;
        r = next;
    }
    engine_set_tsc(hv.engine, cpus_get_elapsed_ticks() - cpu_get_host_ticks(), env->tsc_offset, num / g, den / g);
}

static void hvdbt_get_state(CPUState *cs)
{
    CPUX86State *env = cpu_env(cs);
    EngineX86State s;

    engine_get_state(hv.engine, &s);
    memcpy(env->regs, s.gpr, sizeof s.gpr);
    env->eip = s.rip;
    env->eflags = s.rflags; /* cpu_exec_enter splits it again */
    env->cr[0] = s.cr0;
    env->cr[2] = s.cr2;
    env->cr[3] = s.cr3;
    env->cr[4] = s.cr4;
    env->efer = s.efer | MSR_EFER_LMA;
    env->star = s.star;
    env->lstar = s.lstar;
    env->cstar = s.cstar;
    env->fmask = s.sfmask;
    env->kernelgsbase = s.kernel_gs_base;
    env->gdt.base = s.gdt_base;
    env->gdt.limit = s.gdt_limit;
    env->idt.base = s.idt_base;
    env->idt.limit = s.idt_limit;
    env->hflags |= HF_LMA_MASK; /* for the page walks below */

    if (env->tr.selector != s.tr) {
        env->tr.selector = s.tr;
        env->tr.flags = DESC_P_MASK | (11 << DESC_TYPE_SHIFT);
    }
    env->tr.base = s.tss_base;
    env->tr.limit = s.tss_limit;
    if (env->ldt.selector != s.ldtr) { /* the monitor's lldt keeps only the selector */
        uint32_t e[4] = { 0, 0, 0, 0 };
        if (s.ldtr & ~3) {
            hvdbt_read_descriptor(cs, s.ldtr & ~4, e, 4);
        }
        cpu_x86_load_seg_cache(env, R_LDTR, s.ldtr, hvdbt_desc_base(e) | ((uint64_t)e[2] << 32), hvdbt_desc_limit(e), e[1]);
    }
    for (int i = 0; i < 6; i++) {
        hvdbt_load_segment(cs, i, s.sel[i], s.cpl);
    }
    env->segs[R_FS].base = s.fs_base;
    env->segs[R_GS].base = s.gs_base;
    x86_update_hflags(env);
    env->hflags &= ~HF_INHIBIT_IRQ_MASK;

    cpu_set_mxcsr(env, s.mxcsr);
    for (int i = 0; i < 16; i++) {
        env->xmm_regs[i].ZMM_Q(0) = s.xmm[i][0];
        env->xmm_regs[i].ZMM_Q(1) = s.xmm[i][1];
    }
    /* shortcut: a whole TLB flush at every return to TCG, since guest tables changed unseen. Measure before narrowing it. */
    tlb_flush(cs);
}

/* ---- The other direction: TCG and DMA writing what the engine translated or shadows ---- */

static void hvdbt_note_write(uint64_t addr, uint64_t len, bool by_tcg)
{
    EngineHandle *engine = __atomic_load_n(&hv.engine, __ATOMIC_ACQUIRE);

    if (!engine || addr < hv.ram_base || addr >= hv.ram_base + hv.ram_bytes) {
        return;
    }
    if (by_tcg) {
        if (hv.written_count < ARRAY_SIZE(hv.written)) {
            hv.written[hv.written_count++] = addr & TARGET_PAGE_MASK;
        } else {
            hv.protect_all = true;
        }
    }
    uint64_t off = addr - hv.ram_base;
    if (off < hv.below_4g) {
        uint64_t n = MIN(len, hv.below_4g - off);
        engine_note_write(engine, off, n);
        off += n;
        len -= n;
    }
    if (len) {
        engine_note_write(engine, HIGH_RAM + off - hv.below_4g, len);
    }
}

/* Every TCG write to RAM must hit notdirty_write, or the engine won't hear of it. That is what a clean page does; it stays dirty once written. */
static void hvdbt_protect_written(void)
{
    if (hv.protect_all) {
        physical_memory_test_and_clear_dirty(hv.ram_base, hv.ram_bytes, DIRTY_MEMORY_CODE, NULL);
    } else {
        for (unsigned i = 0; i < hv.written_count; i++) {
            physical_memory_test_and_clear_dirty(hv.written[i], TARGET_PAGE_SIZE, DIRTY_MEMORY_CODE, NULL);
        }
    }
    hv.protect_all = false;
    hv.written_count = 0;
}

/* ---- Hand-off ---- */

static bool hvdbt_mark_device(Int128 start, Int128 len, const MemoryRegion *mr, hwaddr offset, void *opaque)
{
    MachineState *ms = opaque;
    uint64_t gpa = int128_get64(start), bytes = int128_get64(len);
    uint64_t expect = gpa >= HIGH_RAM ? gpa - HIGH_RAM + hv.below_4g : gpa;

    if (mr != ms->ram || offset != expect) {
        engine_mark_device(hv.engine, gpa, bytes);
    }
    return false;
}

static void hvdbt_write_tally_at_exit(void)
{
    engine_tally_write(hv.engine);
}

static bool hvdbt_create(CPUState *cs)
{
    MachineState *ms = current_machine;
    X86MachineState *x86ms = X86_MACHINE(ms);
    CPUX86State *env = cpu_env(cs);
    const char *tally = getenv("LC_HVDBT_TALLY");

    if (x86ms->above_4g_mem_size && x86ms->above_4g_mem_start != HIGH_RAM) {
        error_report("hvdbt: RAM above 4 GB starts at 0x%" PRIx64 ": staying on TCG", x86ms->above_4g_mem_start);
        return false;
    }
    EngineConfig config = {
        .ram_bytes = ms->ram_size,
        .ram_host = memory_region_get_ram_ptr(ms->ram),
        .ram_below_4g = x86ms->above_4g_mem_size ? x86ms->below_4g_mem_size : 0,
        .kernel_model = true,
        .precise_flags = true,
        .tso = true,
        .tzcnt_lzcnt = (env->features[FEAT_7_0_EBX] & CPUID_7_0_EBX_BMI1) && (env->features[FEAT_8000_0001_ECX] & CPUID_EXT3_ABM),
        .hybrid = true,
    };
    EngineMachineOps ops = {
        .opaque = cs,
        .mmio_read = hvdbt_mmio_read,
        .mmio_write = hvdbt_mmio_write,
        .port_read = hvdbt_port_read,
        .port_write = hvdbt_port_write,
        .read_msr = hvdbt_read_msr,
        .write_msr = hvdbt_write_msr,
        .cpuid = hvdbt_cpuid,
        .acknowledge_interrupt = hvdbt_acknowledge_interrupt,
        .has_interrupt_waiting = hvdbt_has_interrupt,
        .wait_for_interrupt = hvdbt_wait,
        .apic_eoi = hvdbt_apic_eoi,
        .apic_icr = hvdbt_apic_icr,
    };
    EngineHandle *engine = engine_create(&config, &ops);
    if (!engine) {
        error_report("hvdbt: the engine would not start: staying on TCG");
        return false;
    }
    hv.ram_base = memory_region_get_ram_addr(ms->ram);
    hv.ram_bytes = ms->ram_size;
    hv.below_4g = x86ms->above_4g_mem_size ? x86ms->below_4g_mem_size : ms->ram_size;
    hv.protect_all = true;
    hv.engine = engine; /* hvdbt_mark_device reads it, and nothing else can until the release below */

    /* shortcut: the memory map as it stands at hand-off. A BAR or PAM change after this isn't seen; a low-RAM remap would need a MemoryListener. */
    WITH_RCU_READ_LOCK_GUARD() {
        flatview_for_each_range(address_space_to_flatview(&address_space_memory), hvdbt_mark_device, ms);
    }
    __atomic_store_n(&hv.engine, engine, __ATOMIC_RELEASE);
    if (tally) {
        engine_tally_start(engine, tally);
        atexit(hvdbt_write_tally_at_exit);
    }
    info_report("hvdbt: the engine takes over at rip 0x%" PRIx64 ", cr3 0x%" PRIx64, (uint64_t)env->eip, (uint64_t)env->cr[3]);
    return true;
}

static bool hvdbt_want_engine(CPUState *cs, vaddr pc, uint32_t flags)
{
    CPUX86State *env = cpu_env(cs);
    bool ok;

    if (hv.dead) {
        return false;
    }
    if (!hv.engine && (int64_t)pc >= 0) { /* firmware and boot loaders run identity-mapped; XNU's vstart is the first thing in the high half */
        hv.tcg_ran = true;
        return false;
    }
    if (current_machine->smp.max_cpus != 1 || !qemu_tcg_mttcg_enabled()) {
        error_report("hvdbt: needs -smp 1 and -accel tcg,thread=multi");
        exit(EXIT_FAILURE);
    }
    ok = (flags & HF_CS64_MASK) && !(flags & (HF_SMM_MASK | TF_MASK)) && (env->cr[0] & CR0_WP_MASK) && !(env->cr[4] & ~ENGINE_CR4) &&
         (env->mxcsr & 0x1F80) == 0x1F80 && QTAILQ_EMPTY(&cs->breakpoints) && !cpu_single_stepping(cs);
    if (!ok) {
        hv.tcg_ran = true;
    }
    return ok;
}

static void hvdbt_finish(CPUState *cs)
{
    hv.dead = true;
    cpu_dump_state(cs, stderr, CPU_DUMP_CODE | CPU_DUMP_CCOP);
    engine_tally_write(hv.engine);
    vm_stop(RUN_STATE_INTERNAL_ERROR);
}

/* The instruction at rip runs next, on TCG, on its own, with no interrupt ahead of it. Then the next TB miss brings control back. */
static void hvdbt_prepare_step(CPUState *cs)
{
    CPUX86State *env = cpu_env(cs);

    /* The engine may have rewritten this code unseen. shortcut: regenerated at every fallback; a site at a high rate would want a byte compare. */
    for (int i = 0; i < 2; i++) {
        vaddr at = i ? env->eip + 15 : env->eip;
        TranslateForDebugResult page;
        if ((i && !((at ^ env->eip) & TARGET_PAGE_MASK)) || !cpu_translate_for_debug(cs, at & TARGET_PAGE_MASK, &page)) {
            continue;
        }
        uint64_t off = page.physaddr >= HIGH_RAM ? page.physaddr - HIGH_RAM + hv.below_4g : page.physaddr;
        if ((page.physaddr >= HIGH_RAM || page.physaddr < hv.below_4g) && off < hv.ram_bytes) {
            tb_invalidate_phys_range(NULL, hv.ram_base + off, hv.ram_base + off + TARGET_PAGE_SIZE - 1);
        }
    }
    cs->cflags_next_tb = (cs->tcg_cflags & ~CF_COUNT_MASK) | CF_NOIRQ | CF_NO_GOTO_TB | CF_NO_GOTO_PTR | 1;
}

static void hvdbt_run(CPUState *cs)
{
    EngineRunResult result;

    if (!hv.engine && !hvdbt_create(cs)) {
        hv.dead = true;
        return;
    }
    if (hv.tcg_ran) { /* the flush runs from the work queue, then the TB miss brings control back */
        hv.tcg_ran = false;
        queue_tb_flush(cs);
    }
    hvdbt_protect_written();
    qatomic_set_mb(&hv.in_engine, true);
    if (!cpu_can_run(cs) || !cpu_work_list_empty(cs)) {
        qatomic_set(&hv.in_engine, false);
        return;
    }
    hvdbt_put_state(cs);
    engine_set_irq_line(hv.engine, cpu_test_interrupt(cs, CPU_INTERRUPT_HARD | CPU_INTERRUPT_POLL));

    bql_unlock();
    result = engine_run(hv.engine);
    bql_lock();
    qatomic_set(&hv.in_engine, false);
    hvdbt_get_state(cs);

    switch (result) {
    case ENGINE_RUN_FALLBACK:
        hvdbt_prepare_step(cs);
        break;
    case ENGINE_RUN_BOUNDARY: /* whatever asked for the stop is in TCG's loop now */
        break;
    case ENGINE_RUN_ERROR:
        error_report("hvdbt: %s", engine_error_text(hv.engine));
        hvdbt_finish(cs);
        break;
    default:
        error_report("hvdbt: engine_run returned %d", result);
        hvdbt_finish(cs);
        break;
    }
}

/* Interrupts wake the monitor. A stop, or queued work, needs the state in QEMU's hands. */
static void hvdbt_kick(CPUState *cs)
{
    if (!qatomic_read(&hv.in_engine)) {
        return;
    }
    if (qatomic_read(&cs->stop) || !cpu_work_list_empty(cs)) {
        engine_request_boundary(hv.engine);
    } else {
        engine_set_irq_line(hv.engine, true);
        engine_kick(hv.engine);
    }
}

static const TcgHandoffOps hvdbt_ops = {
    .want_engine = hvdbt_want_engine,
    .run = hvdbt_run,
    .kick = hvdbt_kick,
    .note_write = hvdbt_note_write,
};

static void __attribute__((constructor)) hvdbt_init(void)
{
    const char *on = getenv("LC_HVDBT");

    if (on && !strcmp(on, "1")) {
        tcg_handoff = &hvdbt_ops;
    }
}
