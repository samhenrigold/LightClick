// The C interface a QEMU AccelOps accelerator drives. Devices, memory topology and the machine stay in QEMU; the engine owns the x86 CPU,
// its translation, its shadow page tables and the local APIC's hot paths. See qemu-accel/ for the (uncompiled) accelerator skeleton.
// Threading: everything below runs on the thread that created the engine, unless marked "any thread".
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EngineHandle EngineHandle;

// Device and platform callbacks. Each runs on the vCPU thread with the guest stopped. For mmio and ports, the access itself has not
// completed: returning completes it. opaque is what engine_create received.
typedef struct {
    void *opaque;
    uint64_t (*mmio_read)(void *opaque, uint64_t gpa, unsigned size);
    void (*mmio_write)(void *opaque, uint64_t gpa, unsigned size, uint64_t value);
    uint32_t (*port_read)(void *opaque, uint16_t port, unsigned size);
    void (*port_write)(void *opaque, uint16_t port, unsigned size, uint32_t value);
    bool (*read_msr)(void *opaque, uint32_t msr, uint64_t *value);
    bool (*write_msr)(void *opaque, uint32_t msr, uint64_t value);
    void (*cpuid)(void *opaque, uint32_t leaf, uint32_t subleaf, uint32_t out[4]);
    // Legacy external interrupt (PIC, ExtINT): the vector, or -1. The APIC path uses engine_post_vector instead.
    int (*acknowledge_interrupt)(void *opaque);
    bool (*has_interrupt_waiting)(void *opaque);
    // The guest halted. Sleep until something might interrupt it, no later than deadline_ns if nonzero. False: nothing ever will.
    bool (*wait_for_interrupt)(void *opaque, uint64_t deadline_ns);
    // EOI of a level-triggered vector, for the IO-APIC model.
    void (*apic_eoi)(void *opaque, uint8_t vector);
    // An IPI the local APIC cannot finish alone: other CPUs, INIT, SIPI. Raw ICR value, high word in bits 63:32.
    void (*apic_icr)(void *opaque, uint64_t icr);
} EngineMachineOps;

typedef struct {
    uint64_t ram_bytes;
    void *ram_host; // RAM the host already mapped, or NULL for the engine to allocate
    bool kernel_model; // full x86 kernel model; false is the user-mode syscall shim
    bool precise_flags;
    bool tso;
    bool tzcnt_lzcnt;
} EngineConfig;

typedef enum {
    ENGINE_RUN_EXIT, // a device asked to stop the machine (engine_request_exit)
    ENGINE_RUN_BOUNDARY, // stopped at an instruction boundary after engine_request_boundary
    ENGINE_RUN_HALTED, // hlt with nothing able to wake it
    ENGINE_RUN_ERROR, // a clear stop: engine_error_text says why
} EngineRunResult;

// CPU state in QEMU's terms, to fill CPUX86State at a boundary. Segment bases beyond fs and gs are always zero in long mode.
typedef struct {
    uint64_t gpr[16], rip, rflags;
    uint64_t cr0, cr2, cr3, cr4, cr8, efer;
    uint64_t star, lstar, cstar, sfmask, fs_base, gs_base, kernel_gs_base;
    uint64_t gdt_base, idt_base, tss_base;
    uint32_t gdt_limit, idt_limit, tss_limit;
    uint16_t sel[6], tr, ldtr;
    uint32_t cpl, mxcsr;
    uint64_t xmm[16][2];
    uint64_t apic_base;
    uint32_t apic_tpr, apic_svr, apic_id, apic_ldr, apic_dfr, apic_lvt_timer, apic_lvt[5], apic_tmict, apic_tdcr;
    uint32_t apic_irr[8], apic_isr[8], apic_tmr[8];
} EngineX86State;

EngineHandle *engine_create(const EngineConfig *config, const EngineMachineOps *ops);
void engine_destroy(EngineHandle *engine);
// Host pointer to RAM, for loaders and DMA.
void *engine_ram(EngineHandle *engine);
// Marks a guest-physical range as a device hole or RAM; defaults come from ram_bytes.
// Runs until something needs the host's attention. The first call starts at state.rip after engine_set_state.
EngineRunResult engine_run(EngineHandle *engine);
const char *engine_error_text(EngineHandle *engine);
// Only valid while stopped after ENGINE_RUN_BOUNDARY or before the first run.
void engine_get_state(EngineHandle *engine, EngineX86State *out);
void engine_set_state(EngineHandle *engine, const EngineX86State *in);

// From a device callback: engine_run returns ENGINE_RUN_EXIT once the access completes.
void engine_request_exit(EngineHandle *engine);

// Any thread.
void engine_request_boundary(EngineHandle *engine); // kick: engine_run returns ENGINE_RUN_BOUNDARY at the next x86 boundary
void engine_kick(EngineHandle *engine); // look at has_interrupt_waiting and pending vectors
void engine_post_vector(EngineHandle *engine, uint8_t vector, bool level);

// Atomic helpers the Swift side needs, implemented in C.
void engine_ctx_post_vector(void *ctx, uint8_t vector, bool level);
void engine_ctx_set_stop(void *ctx);

#ifdef __cplusplus
}
#endif
