// Layout and calling conventions shared by the translator, the EL1 monitor (Monitor/) and the Swift control plane.
#pragma once
#include <stdint.h>

// Register pinning for translated code (EL0). x86 rax,rcx,rdx,rbx,rsp,rbp,rsi,rdi,r8-r15 are x0-x15, xmm0-15 are v0-15.
#define R_S0 16 // scratch
#define R_S1 17 // scratch
#define R_CTX 18 // EngineCtx, in private memory
#define R_HASH 19 // indirect-branch table of the current view
#define R_AD 20 // scratch, usually an address
#define R_PF 21 // lazy PF: low byte of the last flag-setting result
#define R_S2 22 // scratch
#define R_S3 23 // scratch
#define R_S4 24 // scratch
#define R_AF 25 // lazy AF: bit 4 of (R_AF ^ R_PF)
#define R_RS 26 // shadow return stack pointer of the current view
#define R_GS 27 // x86 GS base
#define R_FS 28 // x86 FS base
#define R_S5 29 // scratch
#define R_LR 30 // scratch, bl/ret pairing

// Private memory. Mapped from PRIV_IPA and in every shadow root at PRIV_VA (non-canonical for x86: bit 47 set, top bits clear).
#define PRIV_IPA 0xF00000000ULL // 60 GB; x86 RAM and device GPAs stay below it
#define PRIV_VA 0xF00000000000ULL
#define PRIV_SIZE (1ULL << 30) // reserved, touched lazily

#define OFF_MON_TEXT 0ULL // EL1 rx: vectors, monitor text and rodata
#define OFF_MON_DATA (2ULL << 20) // EL1 rw: monitor data, stack
#define OFF_STUBS (4ULL << 20) // EL0 execute-only: lookup and helper stubs, within bl reach of the code cache
#define OFF_CC (6ULL << 20) // EL0 execute-only, EL1 rw: translated code
#define CC_SIZE (118ULL << 20)
#define OFF_CTX (124ULL << 20) // EL0 rw: EngineCtx
#define OFF_RSTACKS (126ULL << 20) // EL0 rw, per view: 16 KB guard (unmapped), then a 16 KB shadow return stack
#define OFF_HASH (128ULL << 20) // EL0 ro, per view: indirect-branch table
#define HASH_ENTRIES (1ULL << 16)
#define HASH_BYTES (HASH_ENTRIES * 16)
#define MAX_VIEWS 64 // two per x86 address space. shortcut: no recycling yet, a real guest needs LRU eviction
#define OFF_BLOCKS (196ULL << 20) // EL1 ro: block table, pc maps
#define BLOCKS_MAX (1ULL << 20)
#define OFF_PCMAP (212ULL << 20)
#define PCMAP_BYTES (44ULL << 20)
#define OFF_PT (256ULL << 20) // EL1 rw: static hole tables, then the shadow pool
#define PT_STATIC_BYTES (1ULL << 20)
#define SHADOW_POOL_BYTES (256ULL << 20)
#define OFF_SHADOW_META (512ULL << 20) // EL1 rw: shadow page descriptors, hash, rmap
#define OFF_PAGEINFO (768ULL << 20) // EL1 rw, one byte per guest page frame (4 GB of RAM per MB)

// RAM alias, EL1 only: x86 GPA + RAM_ALIAS_VA reaches guest RAM for the monitor's walker.
#define RAM_ALIAS_VA 0xF10000000000ULL

#define RSTACK_BYTES (16ULL << 10)
#define RSTACK_SLOT (32ULL << 10)

// Page info bits, one byte per GPA frame, owned by the monitor.
#define PI_CODE 1 // blocks were translated from this frame
#define PI_PT 2 // a shadow page tracks this frame as a guest page table
#define PI_RAM 4 // RAM, as opposed to a device hole

// svc immediates from translated code and stubs. Translator requests come first, then x86 events and helpers.
enum {
    SVC_DIRECT = 1, // literal target follows: fall through or jump stub. ELR points at the literal.
    SVC_JCC, // as above, a third word holds the distance back to the b.cond
    SVC_CALL, // as SVC_DIRECT, x30-4 is the bl site
    SVC_LOOKUP_MISS, // x16 target, x30 return
    SVC_DEAD, // this block was invalidated; ELR-4 finds it
    SVC_STOP, // literal: u32 stop reason index
    SVC_SINGLE_DONE, // end of a one-off single-instruction block, literal target follows
    // x86 events
    SVC_SYSCALL = 16, // x16 next rip
    SVC_SYSRET,
    SVC_IRET,
    SVC_INT, // x16 next rip, x17 vector
    SVC_INT3,
    SVC_INTO_UNUSED,
    SVC_UD, // #UD at this instruction, literal rip
    SVC_DE, // #DE
    SVC_GP0, // #GP(0)
    SVC_HLT,
    SVC_CPUID,
    SVC_RDTSC,
    SVC_RDTSCP,
    SVC_RDMSR,
    SVC_WRMSR,
    SVC_CLI,
    SVC_STI,
    SVC_POPF, // x16 value, x17 next rsp
    SVC_MOV_CR_READ, // x16 cr number, result in x16
    SVC_MOV_CR_WRITE, // x16 cr number, x17 value
    SVC_INVLPG, // x16 va
    SVC_INVPCID,
    SVC_WBINVD,
    SVC_LGDT, // x16 base, x17 limit
    SVC_LIDT,
    SVC_SGDT, // result x16 base, x17 limit
    SVC_SIDT,
    SVC_LTR, // x16 selector
    SVC_STR, // result x16
    SVC_LLDT,
    SVC_SLDT,
    SVC_MOV_SEG_WRITE, // x16 segment index, x17 selector
    SVC_MOV_SEG_READ, // x16 segment index, result x16
    SVC_IN, // x16 port, x17 size, result x16
    SVC_OUT, // x16 port, x17 size, x22 value
    SVC_SWAPGS,
    SVC_LDMXCSR, // x16 value
    SVC_STMXCSR, // result x16
    SVC_FXSAVE, // x16 address of 512-byte buffer, already probed writable
    SVC_FXRSTOR,
    SVC_MFENCE_UNUSED,
    // Helpers: operands in x16, x17, x22, x23. Results as documented in monitor.c. Flags come back in x22 (nzcv), x23 (pf), x24 (aux).
    SVC_H_SHIFT = 64, // narrow and rotate-through-carry shifts: x16 value, x17 count, x22 kind|size<<8. x16 result
    SVC_H_SHD, // shld/shrd: x16 dst, x17 src, x22 count, x23 size|isright<<8. x16 result
    SVC_H_MUL, // mul/imul narrow: x16 a, x17 b, x22 size|signed<<8. x16 low, x17 high
    SVC_H_DIV, // x16 low, x17 high, x22 divisor, x23 size|signed<<8. x16 quotient, x17 remainder
    SVC_H_BITSCAN_UNUSED,
    SVC_H_SSE, // x16 op id; operands live in v-regs, memory operand already in v30
    SVC_H_RMWFLAGS_UNUSED,
};

// Hypervisor calls from monitor to host: hvc #code, arguments and results in EngineCtx.req.
enum {
    HC_NONE = 0,
    HC_TRANSLATE, // req.a[0] view, a[1] rip, a[2] site VA or 0, a[3] link kind (svc number) or 0, a[4] 1 for single instruction
                  // result r[0] arm, r[1] nonzero if fetch fault at VA r[1]-1. Host reports frames used in r[2], r[3] (GPA|1 or 0)
    HC_SMC, // a[0] gpa: invalidate frame
    HC_VIEW_INVALIDATE_VA, // a[0] view, a[1] va: invalidate blocks at this page in the view
    HC_STOP, // a[0] reason code, a[1] x86 rip, a[2..4] detail
    HC_SYSCALL, // user-mode shim (no IDT model): regs in ctx
    HC_MMIO, // a[0] gpa, a[1] size, a[2] is write, a[3] value. r[0] read value
    HC_PORT, // a[0] port, a[1] size, a[2] is write, a[3] value. r[0] read value
    HC_RDMSR, // a[0] msr. r[0] value, r[1] 1 if unhandled (#GP)
    HC_WRMSR, // a[0] msr, a[1] value. r[1] 1 if unhandled
    HC_CPUID, // a[0] leaf, a[1] subleaf. r[0..3] eax,ebx,ecx,edx
    HC_HLT, // guest halted with interrupts possibly enabled. Host returns when an interrupt may be pending.
    HC_IRQ, // host-injected IRQ arrived; a[0] arm pc. Asks the host for an external vector. r[0] vector or -1
    HC_FLUSH_VIEWS, // shadow pool wrapped: drop all translations
    HC_DEBUG, // a[0] a[1] printable
};

// Stop reasons for HC_STOP.
enum {
    STOP_GUEST_HALT = 0,
    STOP_UNTRANSLATED, // a[2]: index into the translator's reason list
    STOP_MONITOR_FAULT, // exception taken while in the monitor. a[2] esr, a[3] far, a[4] elr
    STOP_UNSUPPORTED, // a[2]: pointer-free reason code, see monitor.c
    STOP_TRIPLE_FAULT,
    STOP_GUEST_FAULT_NO_IDT, // user-mode shim: x86 exception with no IDT model. a[2] vector, a[3] error code, a[4] cr2
    STOP_SHADOW_FULL,
};

typedef struct {
    uint64_t x[31]; // +0: x0-x30, saved on every monitor entry
    uint64_t elr; // +248
    uint64_t spsr; // +256
    uint64_t esr; // +264
    uint64_t far; // +272
    // Read and written by translated code. Offsets are used in stubs; keep them fixed.
    int64_t df; // +280: +1 or -1
    uint64_t kernel_gs_base; // +288
    uint64_t rs_top; // +296: reset value for R_RS in the current view
    uint64_t rflags_sys; // +304: every RFLAGS bit except CF PF AF ZF SF OF DF. Bit 1 always set
    uint64_t rsvd_el0[3];

    // Host request block.
    uint64_t req_a[6]; // +344
    uint64_t req_r[4];

    // Monitor-owned x86 system state; the host may read it stopped.
    uint64_t cr0, cr2, cr3, cr4, efer;
    uint64_t star, lstar, cstar, sfmask;
    uint64_t gdtr_base, idtr_base;
    uint32_t gdtr_limit, idtr_limit;
    uint16_t tr, ldtr, seg_sel[6]; // es cs ss ds fs gs
    uint64_t tss_base;
    uint32_t tss_limit;
    uint32_t cpl;
    uint32_t mxcsr; // control bits; status bits live in FPSR
    uint32_t view; // current view index
    uint32_t model_kernel; // 0 user-mode shim: syscall and faults go to the host. 1 full x86 kernel model.
    uint32_t pad_shadow;
    uint64_t irq_shadow_rip; // interrupts wait until the instruction at this rip has run: the sti shadow
    uint32_t irq_pending; // host or in-VM APIC has an interrupt ready
    uint32_t halted;
    uint32_t stepping; // walking to an x86 boundary with the software step
    uint32_t tr_flushed; // the translator reset the code cache; every return stack is stale
    uint32_t pad2;
    uint64_t ram_size;
    uint64_t kernel_view_tag;

    // Blocks, published by the host.
    uint64_t block_count;
    uint64_t tsc_offset;

    // Statistics, read by the host.
    uint64_t stat_svc[128];
    uint64_t stat_fills, stat_dirty, stat_pf_delivered, stat_pt_writes, stat_pt_writes_zap, stat_pt_step, stat_smc,
        stat_irq, stat_steps, stat_cr3, stat_iret, stat_syscall, stat_mmio, stat_mmio_vm;
} EngineCtx;

// Block table, one entry per translated block, ordered by arm_off because the code cache only grows.
typedef struct {
    uint64_t rip;
    uint32_t arm_off; // words from the code cache base
    uint32_t arm_words;
    uint32_t map_off; // index of the first PcMap in the map array
    uint32_t map_count;
} BlockEntry;

// One x86 instruction boundary inside a block.
typedef struct {
    uint16_t arm_word;
    uint16_t rip_off;
} PcMap;
