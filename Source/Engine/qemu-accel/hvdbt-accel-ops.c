/*
 * hvdbt: the x86 translator-in-a-VM engine as a QEMU accelerator. SKELETON, NEVER COMPILED.
 *
 * Shape follows accel/hvf/hvf-accel-ops.c: one thread per vCPU, kick through hv_vcpus_exit, state synchronised on demand. QEMU keeps its
 * devices, memory API and machine. Everything marked TODO is listed in ../DESIGN.md under "What is left to boot XNU".
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "qemu/accel.h"
#include "qemu/main-loop.h"
#include "system/accel-ops.h"
#include "system/address-spaces.h"
#include "system/cpus.h"
#include "system/runstate.h"
#include "exec/cpu-common.h"
#include "exec/memory.h"
#include "hw/core/cpu.h"
#include "target/i386/cpu.h"
#include "engine_api.h"

typedef struct AccelCPUState {
    EngineHandle *engine;
    bool dirty; /* CPUX86State is newer than the engine */
} AccelCPUState;

/* ---- Device callbacks: every one is the current vCPU thread with the BQL taken here, as hvf does for MMIO. ---- */

static uint64_t hvdbt_mmio_read(void *opaque, uint64_t gpa, unsigned size)
{
    uint64_t v = 0;
    bql_lock();
    address_space_read(&address_space_memory, gpa, MEMTXATTRS_UNSPECIFIED, &v, size);
    bql_unlock();
    return v;
}

static void hvdbt_mmio_write(void *opaque, uint64_t gpa, unsigned size, uint64_t value)
{
    bql_lock();
    address_space_write(&address_space_memory, gpa, MEMTXATTRS_UNSPECIFIED, &value, size);
    bql_unlock();
}

static uint32_t hvdbt_port_read(void *opaque, uint16_t port, unsigned size)
{
    uint32_t v = 0;
    bql_lock();
    address_space_read(&address_space_io, port, MEMTXATTRS_UNSPECIFIED, &v, size);
    bql_unlock();
    return v;
}

static void hvdbt_port_write(void *opaque, uint16_t port, unsigned size, uint32_t value)
{
    bql_lock();
    address_space_write(&address_space_io, port, MEMTXATTRS_UNSPECIFIED, &value, size);
    bql_unlock();
}

static bool hvdbt_read_msr(void *opaque, uint32_t msr, uint64_t *value)
{
    /* TODO: route through target/i386's MSR handling (APIC base and the syscall family stay in the monitor). */
    CPUState *cs = opaque;
    (void)cs;
    *value = 0;
    return false;
}

static bool hvdbt_write_msr(void *opaque, uint32_t msr, uint64_t value)
{
    /* TODO: as above. */
    return false;
}

static void hvdbt_cpuid(void *opaque, uint32_t leaf, uint32_t subleaf, uint32_t out[4])
{
    CPUState *cs = opaque;
    cpu_x86_cpuid(&X86_CPU(cs)->env, leaf, subleaf, &out[0], &out[1], &out[2], &out[3]);
}

static int hvdbt_ack_interrupt(void *opaque)
{
    /* ExtINT from the PIC path: pic_read_irq under the BQL. APIC-routed vectors arrive through engine_post_vector instead. */
    CPUState *cs = opaque;
    int vector = -1;
    bql_lock();
    if (cs->interrupt_request & CPU_INTERRUPT_HARD) {
        vector = cpu_get_pic_interrupt(&X86_CPU(cs)->env);
        cs->interrupt_request &= ~CPU_INTERRUPT_HARD;
    }
    bql_unlock();
    return vector;
}

static bool hvdbt_has_interrupt(void *opaque)
{
    CPUState *cs = opaque;
    return qatomic_read(&cs->interrupt_request) & (CPU_INTERRUPT_HARD | CPU_INTERRUPT_NMI);
}

static bool hvdbt_wait(void *opaque, uint64_t deadline_ns)
{
    /* TODO: qemu_process_cpu_events with a timeout on cs->halt_cond, BQL held, deadline from the virtual APIC timer. */
    return true;
}

static void hvdbt_eoi(void *opaque, uint8_t vector)
{
    bql_lock();
    /* TODO: ioapic_eoi_broadcast(vector) */
    bql_unlock();
}

static void hvdbt_icr(void *opaque, uint64_t icr)
{
    /* TODO: other vCPUs: engine_post_vector on the target's handle. INIT and SIPI: as x86_cpu do_cpu_init and do_cpu_sipi. */
}

/* ---- State ---- */

static void hvdbt_get_regs(CPUState *cs)
{
    X86CPU *cpu = X86_CPU(cs);
    CPUX86State *env = &cpu->env;
    EngineX86State s;
    engine_get_state(cs->accel->engine, &s);
    memcpy(env->regs, s.gpr, sizeof s.gpr);
    env->eip = s.rip;
    env->eflags = s.rflags;
    env->cr[0] = s.cr0;
    env->cr[2] = s.cr2;
    env->cr[3] = s.cr3;
    env->cr[4] = s.cr4;
    env->efer = s.efer;
    env->star = s.star;
    env->lstar = s.lstar;
    env->cstar = s.cstar;
    env->fmask = s.sfmask;
    env->kernelgsbase = s.kernel_gs_base;
    /* TODO: segments through their descriptors, GDT and IDT limits, xmm_regs, mxcsr, APIC registers into the apic_common state. */
}

static void hvdbt_put_regs(CPUState *cs)
{
    X86CPU *cpu = X86_CPU(cs);
    CPUX86State *env = &cpu->env;
    EngineX86State s;
    engine_get_state(cs->accel->engine, &s);
    memcpy(s.gpr, env->regs, sizeof s.gpr);
    s.rip = env->eip;
    s.rflags = env->eflags;
    /* TODO: the rest, the mirror of hvdbt_get_regs. */
    engine_set_state(cs->accel->engine, &s);
}

static void do_sync_state(CPUState *cs, run_on_cpu_data arg)
{
    if (!cs->accel->dirty) {
        hvdbt_get_regs(cs);
        cs->accel->dirty = true;
    }
}

static void hvdbt_cpu_synchronize_state(CPUState *cs)
{
    if (!cs->accel->dirty) {
        run_on_cpu(cs, do_sync_state, RUN_ON_CPU_NULL);
    }
}

/* ---- The vCPU thread ---- */

static void hvdbt_kick(CPUState *cs)
{
    /* Stops at an x86 boundary, so QEMU always sees whole instructions. */
    engine_request_boundary(cs->accel->engine);
}

static void *hvdbt_cpu_thread(void *arg)
{
    CPUState *cs = arg;
    bql_lock();
    qemu_thread_get_self(cs->thread);
    cs->thread_id = qemu_get_thread_id();
    current_cpu = cs;

    EngineConfig config = {
        .ram_bytes = current_machine->ram_size,
        .ram_host = memory_region_get_ram_ptr(current_machine->ram), /* TODO: holes, ROM, device BARs: see DESIGN */
        .kernel_model = true,
        .precise_flags = true,
        .tso = true,
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
        .acknowledge_interrupt = hvdbt_ack_interrupt,
        .has_interrupt_waiting = hvdbt_has_interrupt,
        .wait_for_interrupt = hvdbt_wait,
        .apic_eoi = hvdbt_eoi,
        .apic_icr = hvdbt_icr,
    };
    cs->accel = g_new0(AccelCPUState, 1);
    cs->accel->engine = engine_create(&config, &ops);
    cs->accel->dirty = true;
    cpu_thread_signal_created(cs);
    qemu_guest_random_seed_thread_part2(0);

    do {
        qemu_process_cpu_events(cs);
        if (cpu_can_run(cs)) {
            if (cs->accel->dirty) {
                hvdbt_put_regs(cs);
                cs->accel->dirty = false;
            }
            bql_unlock();
            EngineRunResult r = engine_run(cs->accel->engine);
            bql_lock();
            if (r == ENGINE_RUN_ERROR) {
                /* TODO: fall back to TCG for this instruction (real mode, x87 until helpers exist) rather than stop. */
                error_report("hvdbt: %s", engine_error_text(cs->accel->engine));
                qemu_system_guest_panicked(NULL);
            }
        }
    } while (!cs->unplug || cpu_can_run(cs));

    engine_destroy(cs->accel->engine);
    cpu_thread_signal_destroyed(cs);
    bql_unlock();
    return NULL;
}

static void hvdbt_start_vcpu_thread(CPUState *cs)
{
    char name[VCPU_THREAD_NAME_SIZE];
    cs->thread = g_new0(QemuThread, 1);
    cs->halt_cond = g_new0(QemuCond, 1);
    qemu_cond_init(cs->halt_cond);
    snprintf(name, VCPU_THREAD_NAME_SIZE, "CPU %d/HVDBT", cs->cpu_index);
    qemu_thread_create(cs->thread, name, hvdbt_cpu_thread, cs, QEMU_THREAD_JOINABLE);
}

static void hvdbt_accel_ops_class_init(ObjectClass *oc, const void *data)
{
    AccelOpsClass *ops = ACCEL_OPS_CLASS(oc);
    ops->create_vcpu_thread = hvdbt_start_vcpu_thread;
    ops->kick_vcpu_thread = hvdbt_kick;
    ops->handle_interrupt = generic_handle_interrupt;
    ops->synchronize_state = hvdbt_cpu_synchronize_state;
    /* TODO: synchronize_post_reset, post_init, pre_loadvm as in hvf; gdbstub breakpoints through invalid-entry stubs. */
}

static const TypeInfo hvdbt_accel_ops_type = {
    .name = ACCEL_OPS_NAME("hvdbt"),
    .parent = TYPE_ACCEL_OPS,
    .class_init = hvdbt_accel_ops_class_init,
    .abstract = true,
};

static void hvdbt_accel_ops_register_types(void)
{
    type_register_static(&hvdbt_accel_ops_type);
}
type_init(hvdbt_accel_ops_register_types);
