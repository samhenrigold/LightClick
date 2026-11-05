// x87: each operation is one monitor call, with its memory operand moved here at EL0, so that a fault on it takes the
// ordinary path: shadow fills, devices and all. Nothing commits before the last access that can fault. A store gets its
// value and the new state word from the monitor, writes memory, then writes the word.
#include <stddef.h>
#include "tr_internal.h"

enum { NONE, LOAD16, LOAD32, LOAD64, LOAD80, AREA_READ, AREA_WRITE, STORE16, STORE32, STORE64, STORE80 };

static int mem_kind(int esc, int reg) {
    static const u8 table[8][8] = {
        {LOAD32, LOAD32, LOAD32, LOAD32, LOAD32, LOAD32, LOAD32, LOAD32}, // D8
        {LOAD32, NONE, STORE32, STORE32, AREA_READ, LOAD16, AREA_WRITE, STORE16}, // D9
        {LOAD32, LOAD32, LOAD32, LOAD32, LOAD32, LOAD32, LOAD32, LOAD32}, // DA
        {LOAD32, STORE32, STORE32, STORE32, NONE, LOAD80, NONE, STORE80}, // DB
        {LOAD64, LOAD64, LOAD64, LOAD64, LOAD64, LOAD64, LOAD64, LOAD64}, // DC
        {LOAD64, STORE64, STORE64, STORE64, AREA_READ, NONE, AREA_WRITE, STORE16}, // DD
        {LOAD16, LOAD16, LOAD16, LOAD16, LOAD16, LOAD16, LOAD16, LOAD16}, // DE
        {LOAD16, STORE16, STORE16, STORE16, LOAD80, LOAD64, STORE80, STORE64}, // DF
    };
    return table[esc][reg];
}

static void call_monitor(const Insn *in) {
    svc(SVC_X87);
    E((u32)(in->sub == 8 ? 0xFFFF : in->sub << 8 | in->opc) | (u32)in->seg << 16 | (in->pfx == 0x66 ? 1u << 18 : 0));
    E((u32)in->rip);
    E((u32)(in->rip >> 32));
}

void emit_x87(const Insn *in) {
    if (in->rm_reg) {
        call_monitor(in);
        if (in->sub == 7 && in->opc == 0xE0) // fnstsw ax
            gpr_write(0, 2, false, S0);
        return;
    }
    int reg = (in->opc >> 3) & 7, kind = mem_kind(in->sub, reg);
    if (kind == NONE) {
        emit_stop(in->rip, "x87: reserved memory form");
        return;
    }
    E(0x4F00E400u | V_MEM); // movi v30.16b, #0: TS gives #NM ahead of any fault on the operand
    int r = addr_reg(in);
    if (r != AD)
        mov_reg(1, AD, r);
    Addr a = {.base = AD}, hi = {.base = AD, .imm = 8};
    switch (kind) {
        case LOAD16:
            ldst(1, 2, S0, a);
            break;
        case LOAD32:
            ldst(1, 4, S0, a);
            break;
        case LOAD64:
            ldst(1, 8, S0, a);
            break;
        case LOAD80:
            ldst(1, 8, S0, a);
            ldst(1, 2, S1, hi);
            break;
        case AREA_READ:
        case AREA_WRITE: {
            // fldenv, fnstenv, frstor, fnsave: the monitor copies these through its walker, so make sure both ends are
            // there and writable.
            int bytes = in->sub == 1 ? (in->pfx == 0x66 ? 14 : 28) : (in->pfx == 0x66 ? 94 : 108);
            Addr last = {.base = AD, .imm = bytes - 1};
            ldst(1, 1, S0, a);
            ldst(1, 1, S1, last);
            if (kind == AREA_WRITE) {
                ldst(0, 1, S0, a);
                ldst(0, 1, S1, last);
            }
            break;
        }
        default:
            break;
    }
    call_monitor(in);
    if (kind < STORE16)
        return;
    switch (kind) {
        case STORE16:
            ldst(0, 2, S0, a);
            break;
        case STORE32:
            ldst(0, 4, S0, a);
            break;
        case STORE64:
            ldst(0, 8, S0, a);
            break;
        default:
            // A fault on either page must leave both as they were: write the first eight bytes back, then the last two,
            // then the first eight for real.
            ldst(1, 8, S2, a);
            ldst(0, 8, S2, a);
            ldst(0, 2, S1, hi);
            ldst(0, 8, S0, a);
            break;
    }
    Addr state = {.base = CTX, .imm = offsetof(EngineCtx, fp_top)};
    ldst(0, 4, S3, state);
}
