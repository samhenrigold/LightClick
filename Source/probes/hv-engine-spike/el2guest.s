// Bare-metal guest for el2.c: copied to CODE_VA (identity mapped) and run at EL0, EL1 or virtual EL2.
// x28 always holds an address whose IPA the host never maps, so `ldr xzr, [x28]` exits to the host from any level.
// x24 is the loop count. The x86 register mapping in the "translated" paths follows spike.c: x1 rcx, x4 rsp, x11 r11,
// x19 hash table, x25/x26 live and swapped GS base. They are hand-written, as the translator has no syscall yet.
.set ALIAS_VA,   0x40A00000
.set S2PT_VA,    0x40C00000
.set SHADOW_L3,  0x40402000
.set RAM_END,    0x45000000

.macro MOV32 r, v
    movz \r, #((\v) >> 16), lsl #16
    movk \r, #((\v) & 0xffff)
.endm
.macro EXIT
    ldr xzr, [x28]
.endm
.macro ENT i, target
    .p2align 7
    .ifb \target
    mov x27, #\i
    ldr xzr, [x28]
    .else
    b \target
    .endif
.endm
.macro VECTOR name, cs, ci, ls, li
    .p2align 11
    .globl _\name
_\name:
    ENT 0
    ENT 1
    ENT 2
    ENT 3
    ENT 4, \cs
    ENT 5, \ci
    ENT 6
    ENT 7
    ENT 8, \ls
    ENT 9, \li
    ENT 10
    ENT 11
    ENT 12
    ENT 13
    ENT 14
    ENT 15
.endm
.macro LOOP label
    subs x24, x24, #1
    b.ne \label
    EXIT
.endm
.macro SWAPGS
    mov x16, x25
    mov x25, x26
    mov x26, x16
.endm
.macro HASH_LOOKUP // x16 = x86 target, result in x22, same shape as emit_indirect
    and x17, x16, #0xfff
    add x17, x19, x17, lsl #4
    ldp x20, x22, [x17]
    eor x20, x20, x16
    cbnz x20, Lbad
.endm
.macro PRIME rip, label
    mov x16, #\rip
    adr x17, \label
    mov x20, #((\rip & 0xfff) << 4)
    add x20, x19, x20
    stp x16, x17, [x20]
.endm

    .text
    .p2align 14
    .globl _g_start
_g_start:
    .globl _s_eret
_s_eret:
    eret
    .p2align 4
    .globl _s_fresh_el1
_s_fresh_el1:
    tlbi vmalle1is
    dsb ish
    isb
    eret
    .p2align 4
    .globl _s_fresh_el2
_s_fresh_el2:
    tlbi vmalls12e1is
    dsb ish
    isb
    eret
    .p2align 4
    .globl _s_host_tlbi // the host's shadow update needs a guest TLBI: x16 operand, x15 return
_s_host_tlbi:
    dsb ishst
    tlbi vale1is, x16
    dsb ish
    isb
    br x15
Lbad:
    mov x27, #99
    EXIT

// ---- Handlers ----
Lh_eret:
    eret
Lh_skip_el2:
    mrs x16, elr_el2
    add x16, x16, #4
    msr elr_el2, x16
    eret

.macro H_SYSCALL el, ec // x86 syscall entry stub, a trivial kernel body, then sysretq; all as translated code at this level
Lh_syscall_\el:
    mrs x16, esr_\el
    ubfx x16, x16, #26, #6
    cmp x16, #\ec
    b.ne Lbad
    SWAPGS
    str x4, [x25, #16]
    ldr x4, [x25, #8]
    stp x1, x11, [x4, #-16]!
    mov x0, #0
    ldp x1, x11, [x4], #16
    ldr x4, [x25, #16]
    SWAPGS
    mov x16, x1
    HASH_LOOKUP
    msr elr_\el, x22
    msr spsr_\el, x11
    eret
.endm
H_SYSCALL el1, 0x15
H_SYSCALL el2, 0x18 // reached by a trapped MRS: nVHE has no way to send EL0's SVC to EL2 while EL1 exists

.macro H_EXC el // x86 fault taken from user: save CR2, IDT load, push six words on the kernel stack, handler, iretq
Lh_exc_\el:
    mrs x16, esr_\el
    mrs x17, far_\el
    str x17, [x26, #24]
    ldr x20, [x26, #8]
    mov x16, #0x33
    stp x16, x4, [x20, #-16]
    mrs x17, spsr_\el
    mov x16, #0x2b
    stp x17, x16, [x20, #-32]
    mov x16, #0x2345
    mov x17, #4
    stp x16, x17, [x20, #-48]
    ldr x22, [x19, #0x20]
    ldp x16, x17, [x20, #-48]
    ldp x11, x17, [x20, #-32]
    HASH_LOOKUP
    msr elr_\el, x22
    msr spsr_\el, x11
    eret
.endm
H_EXC el1

// Write-protected guest page table: decode, emulate the store, derive the shadow PTE, TLBI, resume.
.macro H_PTW name, el, alias, op
Lh_\name:
    stp x0, x1, [sp, #-48]!
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    mrs x0, elr_\el
    ldr w1, [x0]
    and x1, x1, #31
    ldr x2, [sp, x1, lsl #3]
    mrs x3, far_\el
    and x4, x3, #0xfff
    MOV32 x1, \alias
    str x2, [x1, x4]
    tbz x2, #0, Lbad
    and x5, x2, #0x0000fffffffff000
    MOV32 x1, RAM_END
    cmp x5, x1
    b.hs Lbad
    mov x1, #0xc0
    mov x3, #0x40
    tst x2, #2
    csel x1, x1, x3, eq
    mov x3, #0xf03
    orr x1, x1, x3
    orr x1, x5, x1
    MOV32 x3, SHADOW_L3
    str x1, [x3, x4]
    dsb ishst
    ubfx x1, x5, #12, #36
    orr x1, x1, #(1 << 48)
    tlbi \op, x1
    dsb ish
    isb
    add x0, x0, #4
    msr elr_\el, x0
    ldp x4, x5, [sp, #32]
    ldp x2, x3, [sp, #16]
    ldp x0, x1, [sp], #48
    eret
.endm
H_PTW ptw_el1_is, el1, ALIAS_VA, vale1is
H_PTW ptw_el1_nsh, el1, ALIAS_VA, vale1
H_PTW ptw_el2_is, el2, S2PT_VA, vale1is

// Stage-2 permission fault with only a store emulated, no shadow or TLBI work.
Lh_s2_emul:
    stp x0, x1, [sp, #-16]!
    mrs x0, elr_el2
    mrs x1, esr_el2
    mrs x1, hpfar_el2
    mrs x1, far_el2
    str x1, [x1]
    add x0, x0, #4
    msr elr_el2, x0
    ldp x0, x1, [sp], #16
    eret

// IRQ paths. x20-x23 are free in every interrupt test's foreground loop.
Lh_irq_flag_hvc: // no GIC: count, then tell the host so it stops asserting the line
    ldr x20, [x3]
    add x20, x20, #1
    str x20, [x3]
    hvc #2
    eret
Lh_irq_flag_gic:
    mrs x20, icc_iar1_el1
    ldr x21, [x3]
    add x21, x21, #1
    str x21, [x3]
    msr icc_eoir1_el1, x20
    eret
Lh_irq_pong_gic: // x0 = SGI aimed at the peer
    mrs x20, icc_iar1_el1
    msr icc_sgi1r_el1, x0
    msr icc_eoir1_el1, x20
    eret
Lh_irq_pong_hvc:
    hvc #3
    eret

VECTOR v_eret, Lh_eret, , Lh_eret,
VECTOR v_skip_el2, , , Lh_skip_el2,
VECTOR v_syscall_el1, , , Lh_syscall_el1,
VECTOR v_syscall_el2, , , Lh_syscall_el2,
VECTOR v_exc_el1, , , Lh_exc_el1,
VECTOR v_ptw_el1_is, Lh_ptw_el1_is, , Lh_ptw_el1_is,
VECTOR v_ptw_el1_nsh, Lh_ptw_el1_nsh, , Lh_ptw_el1_nsh,
VECTOR v_ptw_el2_is, , , Lh_ptw_el2_is,
VECTOR v_s2_emul, , , Lh_s2_emul,
VECTOR v_irq_flag_hvc, , Lh_irq_flag_hvc, , Lh_irq_flag_hvc
VECTOR v_irq_flag_gic, , Lh_irq_flag_gic, , Lh_irq_flag_gic
VECTOR v_irq_pong_gic, , Lh_irq_pong_gic, , Lh_irq_pong_gic
VECTOR v_irq_pong_hvc, , Lh_irq_pong_hvc, , Lh_irq_pong_hvc
VECTOR v_none, , , ,

// ---- Foreground loops ----
.macro TEST name
    .p2align 4
    .globl _\name
_\name:
.endm

TEST t_hcr_probe // x1 candidate: write it from vEL2, read it back in x0; x2 records the CurrentEL
    mrs x2, currentel
    msr hcr_el2, x1
    isb
    mrs x0, hcr_el2
    mrs x3, tcr_el2
    mrs x4, sctlr_el2
    EXIT
TEST t_nop
1:  subs x24, x24, #1
    b.ne 1b
    EXIT
TEST t_svc
1:  svc #0
    LOOP 1b
TEST t_hvc
1:  hvc #0
    LOOP 1b
TEST t_ctr
1:  mrs x0, ctr_el0
    LOOP 1b
TEST t_mmio // the host advances the PC by 4 on every hit of x5; the x28 exit ends the run
1:  ldr x0, [x5]
    LOOP 1b
TEST t_chase
1:  ldr x0, [x0]
    LOOP 1b
TEST t_syscall
    PRIME 0x1234, Lsys_next
Lsys_top:
    mov x1, #0x1234
    mrs x11, nzcv
    orr x11, x11, #0x3c0
    svc #0
Lsys_next:
    LOOP Lsys_top
TEST t_syscall_trap
    PRIME 0x1234, Lsyst_next
Lsyst_top:
    mov x1, #0x1234
    mrs x11, nzcv
    orr x11, x11, #0x3c0
    mrs x0, ctr_el0
Lsyst_next:
    LOOP Lsyst_top
TEST t_exc // x3 = a VA the current level may not read
    PRIME 0x2345, Lexc_next
Lexc_top:
    ldr x2, [x3]
Lexc_next:
    LOOP Lexc_top
TEST t_ptw // x5 protected table page, x7 base of the pages it maps
    mov x9, #0
    mov x14, #0x67
1:  add x9, x9, #1
    and x9, x9, #0xff
    add x10, x9, #1
    lsl x11, x10, #12
    add x12, x7, x11
    orr x1, x12, x14
    str x1, [x5, x10, lsl #3]
    ldr x13, [x12]
    LOOP 1b
TEST t_store // x5 protected page
1:  str x1, [x5]
    LOOP 1b
TEST t_ttbr_el1 // cost per pair of switches
1:  msr ttbr0_el1, x1
    isb
    msr ttbr0_el1, x2
    isb
    LOOP 1b
TEST t_eret_self // vEL2 to vEL2, to separate the ERET trap from the exception entry
    mov x1, #0x3c9
    msr spsr_el2, x1
    adr x0, 1f
    msr elr_el2, x0
1:  isb
    subs x24, x24, #1
    b.eq 2f
    eret
2:  EXIT
TEST t_elr_el2
1:  mrs x0, elr_el2
    msr elr_el2, x0
    LOOP 1b
TEST t_hcr_el2
1:  mrs x0, hcr_el2
    msr hcr_el2, x0
    LOOP 1b
TEST t_vttbr_el2
1:  mrs x0, vttbr_el2
    msr vttbr_el2, x0
    isb
    LOOP 1b
.macro T_TLBI name, op, arg
TEST \name
1:
    .ifb \arg
    tlbi \op
    .else
    tlbi \op, \arg
    .endif
    dsb ish
    isb
    LOOP 1b
.endm
T_TLBI t_tlbi_vale1, vale1, x1
T_TLBI t_tlbi_vale1is, vale1is, x1
T_TLBI t_tlbi_aside1is, aside1is, x1
T_TLBI t_tlbi_vmalle1is, vmalle1is
T_TLBI t_tlbi_ipas2e1is, ipas2e1is, x2
T_TLBI t_tlbi_vmalls12e1is, vmalls12e1is
TEST t_dsb_isb
1:  dsb ish
    isb
    LOOP 1b
TEST t_lit_writer // x0 data, x1 flag, x2 iterations; the reader counts violations in x3
    mov x3, #1
1:  str x3, [x0]
    str x3, [x1]
    add x3, x3, #1
    cmp x3, x2
    b.ne 1b
    EXIT
TEST t_lit_reader
    mov x3, #0
    mov x5, #0
1:  ldr x4, [x1]
    ldr x6, [x0]
    cmp x6, x4
    cinc x3, x3, lo
    add x5, x5, #1
    cmp x5, x2
    b.ne 1b
    EXIT
.macro GIC_ON
    str wzr, [x26, #0x14] // GICR_WAKER: clear ProcessorSleep
    dsb sy
9:  ldr w20, [x26, #0x14]
    tbnz w20, #2, 9b
    mov x20, #0xf0
    msr icc_pmr_el1, x20
    mov x20, #1
    msr icc_igrpen1_el1, x20
    isb
.endm
TEST t_spin // spins with interrupts open until the host cancels it
1:  b 1b
TEST t_gic_spin
    GIC_ON
1:  b 1b
TEST t_wfi
1:  wfi
    b 1b
TEST t_gic_wfi
    GIC_ON
1:  wfi
    b 1b
TEST t_ipi_gic // x0 SGI for the peer, x3 flag bumped by the IRQ handler
    GIC_ON
1:  ldr x5, [x3]
    msr icc_sgi1r_el1, x0
2:  ldr x6, [x3]
    cmp x6, x5
    b.eq 2b
    LOOP 1b
TEST t_ipi_hvc // the same round trip with the host carrying the interrupt both ways
1:  ldr x5, [x3]
    hvc #3
2:  ldr x6, [x3]
    cmp x6, x5
    b.eq 2b
    LOOP 1b
TEST t_poll_a // x3 our word, x4 the peer's. Sequence survives A's restart so B keeps following.
    ldr x5, [x3]
1:  add x5, x5, #1
    str x5, [x3]
2:  ldr x6, [x4]
    cmp x6, x5
    b.ne 2b
    LOOP 1b
TEST t_poll_b
    mov x5, #0
1:  add x5, x5, #1
2:  ldr x6, [x3]
    cmp x6, x5
    b.ne 2b
    str x5, [x4]
    b 1b

    .p2align 14
    .globl _g_end
_g_end:
