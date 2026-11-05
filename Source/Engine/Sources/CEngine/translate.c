// Block builder: decodes x86 into a superblock, runs flag liveness, emits AArch64 and side exits, and owns block bookkeeping.
#include <libkern/OSCacheControl.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tr_internal.h"

#define MAX_INSNS 96
#define MAX_PENDING (MAX_INSNS * 2)
#define MAP_BITS 22
#define MAP_SIZE (1u << MAP_BITS)

u32 *tr_cc;
bool tr_precise_flags, tr_has_tzcnt, tr_hybrid, tr_no_bulk_rep;
int tr_cpl;
u64 tr_stub_lookup, tr_stub_ret_miss, tr_stub_pushf, tr_stub_sahf;

static TrConfig cfg;
static u32 *cc_base;
static u64 cc_limit;
static BlockEntry *block_table;
static PcMap *pc_map;
static u32 pc_map_used;
static EngineCtx *ctx_ptr;

typedef struct {
    u64 rip;
    u32 view;
    u32 entry_word; // arm_off
    u64 frame[2]; // ~0 when unused
    u32 next_on_frame[2]; // block index + 1
    bool dead, registered;
} HostBlock;
static HostBlock *hblocks;
static u32 hblock_count;
static u32 *frame_head; // per GPA frame: block index + 1

// Lookup: (view, rip) to block index + 1. Open addressing, deleted entries keep probing.
typedef struct {
    u64 rip;
    u32 view;
    u32 block; // 0 empty, ~0 deleted, otherwise index + 1
} MapEntry;
static MapEntry *block_map;

static TrStats stats;

static const char *stop_reasons[4096];
static u32 stop_reason_count;

u64 tr_cc_va(const u32 *p) { return PRIV_VA + OFF_CC + (u64)((const u8 *)p - (const u8 *)cc_base); }
static u32 *cc_host(u64 va) { return (u32 *)((u8 *)cc_base + (va - PRIV_VA - OFF_CC)); }

static u32 map_hash(int view, u64 rip) { return (u32)((rip ^ ((u64)view << 40)) * 0x9E3779B97F4A7C15ULL >> (64 - MAP_BITS)); }

static u32 map_find(int view, u64 rip) {
    for (u32 h = map_hash(view, rip);; h = (h + 1) & (MAP_SIZE - 1)) {
        MapEntry *e = &block_map[h];
        if (!e->block)
            return 0;
        if (e->block != ~0u && e->rip == rip && e->view == (u32)view)
            return e->block;
    }
}
static void map_insert(int view, u64 rip, u32 block) {
    for (u32 h = map_hash(view, rip);; h = (h + 1) & (MAP_SIZE - 1)) {
        MapEntry *e = &block_map[h];
        if (!e->block || e->block == ~0u) {
            e->rip = rip;
            e->view = (u32)view;
            e->block = block;
            return;
        }
    }
}
static void map_remove(int view, u64 rip) {
    for (u32 h = map_hash(view, rip);; h = (h + 1) & (MAP_SIZE - 1)) {
        MapEntry *e = &block_map[h];
        if (!e->block)
            return;
        if (e->block != ~0u && e->rip == rip && e->view == (u32)view) {
            e->block = ~0u;
            return;
        }
    }
}

static u8 *ram_at(u64 gpa) { return cfg.ram + (cfg.ram_below_4g && gpa >= 1ULL << 32 ? gpa - (1ULL << 32) + cfg.ram_below_4g : gpa); }
static bool is_ram(u64 gpa) { return gpa < cfg.ram_size && (cfg.priv[OFF_PAGEINFO + (gpa >> 12)] & PI_RAM); }

// Ring-0 code in the high half is shared by every address space that reaches it through the same PML4 entry target: an x86 kernel keeps
// those entries identical, and a change to them invalidates through the page-table write path. Everything else belongs to one view.
#define KEY_DOMAIN 0x40000000
static int view_high;
static int block_key(int view, u64 cr3, int cpl, u64 rip) {
    if (cpl == 0 && (rip >> 47)) {
        u64 table = cr3 & 0x000FFFFFFFFFF000ULL;
        if (is_ram(table)) {
            u64 e = *(u64 *)(ram_at(table) + ((rip >> 39) & 0x1ff) * 8);
            return KEY_DOMAIN | (int)((e >> 12) & 0x3FFFFFFF);
        }
    }
    return view;
}

// ---- Guest memory, host's read-only view ----
static u64 walk_cr3;
static int walk_cpl;
#define X_P 1ULL
#define X_US 4ULL
#define X_PS 0x80ULL
#define X_NX (1ULL << 63)
#define X_ADDR 0x000FFFFFFFFFF000ULL

// Instruction-fetch walk. Returns false for anything that would be a fetch fault. Permission intersection as the monitor does it.
static bool fetch_walk(u64 va, u64 *gpa) {
    u64 table = walk_cr3 & X_ADDR;
    bool user = true, nx = false;
    for (int level = 3; level >= 0; level--) {
        if (!is_ram(table))
            return false;
        u64 e = *(u64 *)(ram_at(table) + ((va >> (12 + 9 * level)) & 0x1ff) * 8);
        if (!(e & X_P))
            return false;
        user = user && (e & X_US);
        nx = nx || (e & X_NX);
        if (level && level < 3 && (e & X_PS)) {
            u64 size = 1ULL << (12 + 9 * level);
            u64 base = e & X_ADDR & ~(size - 1);
            *gpa = base | (va & (size - 1));
            goto ok;
        }
        if (!level) {
            *gpa = (e & X_ADDR) | (va & 0xfff);
            goto ok;
        }
        table = e & X_ADDR;
    }
    return false;
ok:
    if (nx || (walk_cpl == 3 && !user))
        return false;
    return is_ram(*gpa);
}

int tr_fetch(u64 va, u8 *out, int n) {
    int got = 0;
    while (got < n) {
        u64 gpa;
        if (!fetch_walk(va + got, &gpa))
            return got;
        int chunk = 4096 - (int)((va + got) & 0xfff);
        if (chunk > n - got)
            chunk = n - got;
        memcpy(out + got, ram_at(gpa), chunk);
        got += chunk;
    }
    return got;
}

// ---- Liveness ----
static int insn_reads(const Insn *in) {
    int r = in->reads;
    if (tr_precise_flags && in->memop)
        r = F_ARITH; // a fault here shows every flag in the x86 exception frame
    return r;
}

// Which flags can be read from `rip` on before being overwritten. Only looks inside the page `page`: anything else can change
// without invalidating the block asking, so it counts as all live.
static int flags_needed_at(u64 rip, u64 page, int depth) {
    int need = 0, written = 0;
    for (int i = 0; i < 16; i++) {
        if ((rip & ~0xfffULL) != page || ((rip + 15) & ~0xfffULL) != page)
            return need | (F_ARITH & ~written);
        Insn in;
        x86_decode(rip, &in);
        need |= insn_reads(&in) & ~written;
        written |= in.writes;
        if ((written & F_ARITH) == F_ARITH)
            return need;
        if (in.op == OP_JCC) {
            if (!depth)
                return need | (F_ARITH & ~written);
            return need | ((flags_needed_at(in.target, page, depth - 1) | flags_needed_at(in.next, page, depth - 1)) & ~written);
        }
        if (in.op == OP_JMP) {
            rip = in.target;
            continue;
        }
        if (insn_is_terminator(&in) || in.op == OP_CALL || in.op == OP_CALLI || in.op == OP_JRCXZ)
            return need | (F_ARITH & ~written);
        rip = in.next;
    }
    return need | (F_ARITH & ~written);
}

// ---- Stubs ----
typedef struct {
    u32 *site; // the branch to fix up, or NULL for a plain fall-through stub
    u64 target;
    int kind; // SVC_DIRECT, SVC_JCC, SVC_CALL
    int form; // 0 b.cond/cbz (19-bit), 1 b/bl (26-bit), 2 tbz (unused)
} Pending;
static Pending pend[MAX_PENDING];
static int pend_count;

void emit_stop(u64 rip, const char *why) {
    (void)rip;
    u32 idx = stop_reason_count;
    for (u32 i = 0; i < stop_reason_count; i++)
        if (stop_reasons[i] == why || !strcmp(stop_reasons[i], why)) {
            idx = i;
            break;
        }
    if (idx == stop_reason_count && stop_reason_count < 4096)
        stop_reasons[stop_reason_count++] = why;
    svc(SVC_STOP);
    E(idx);
}

const char *tr_stop_reason(uint32_t index) { return index < stop_reason_count ? stop_reasons[index] : "?"; }

static void add_pending(u32 *site, u64 target, int kind, int form) {
    pend[pend_count].site = site;
    pend[pend_count].target = target;
    pend[pend_count].kind = kind;
    pend[pend_count].form = form;
    pend_count++;
}

// Reserves a b.cond/cbz/b word to be resolved to a stub at the block end.
static void stub_lit(u64 target) {
    E((u32)target);
    E((u32)(target >> 32));
}

static void emit_indirect_tail(void) {
    // x16 holds the x86 target. Lookup returns the translation in x22, and the branch stays here so that each site has
    // its own predictor entry.
    bl_rel((int)((i64)(tr_stub_lookup - tr_cc_va(tr_cc)) / 4));
    br(S2);
}

static const Insn *block_insns;
static u32 *insn_arm[MAX_INSNS];
static int insn_total;

// If target is an instruction already emitted in this block, returns where.
static u32 *internal_target(u64 target, int upto) {
    for (int i = 0; i <= upto && i < insn_total; i++)
        if (block_insns[i].rip == target)
            return insn_arm[i];
    return NULL;
}

static void emit_monitor_op(const Insn *in);

static void emit_control(const Insn *in, int idx, int live_after) {
    switch (in->op) {
        case OP_JCC: {
            u32 *back = internal_target(in->target, idx);
            int acc = x86_to_arm_cc[in->cc];
            if (acc < 0) {
                emit_parity(S4);
                if (back) {
                    cbz(in->cc == 10, 0, S4, (int)(back - tr_cc));
                } else {
                    add_pending(tr_cc, in->target, SVC_JCC, 0);
                    cbz(in->cc == 10, 0, S4, 0);
                }
            } else if (back) {
                b_cond(acc, (int)(back - tr_cc));
            } else {
                add_pending(tr_cc, in->target, SVC_JCC, 0);
                b_cond(acc, 0);
            }
            break;
        }
        case OP_JRCXZ: {
            u32 *back = internal_target(in->target, idx);
            int sub = in->sub;
            int sf = in->addr32 ? 0 : 1; // with 67h the count is ecx
            if (sub >= 2)
                add_imm(sf, 1, 0, 1, 1, 1);
            if (sub == 0 || sub == 1) {
                if (!back)
                    add_pending(tr_cc, in->target, SVC_JCC, 0);
                cbz(0, sub == 1 ? 0 : 1, 1, back ? (int)(back - tr_cc) : 0);
            } else if (sub == 2) {
                if (!back)
                    add_pending(tr_cc, in->target, SVC_JCC, 0);
                cbz(1, sf, 1, back ? (int)(back - tr_cc) : 0);
            } else {
                u32 *over = tr_cc;
                b_cond(sub == 3 ? 1 : 0, 0); // loope leaves when ZF is clear, loopne when it is set
                if (!back)
                    add_pending(tr_cc, in->target, SVC_JCC, 0);
                cbz(1, sf, 1, back ? (int)(back - tr_cc) : 0);
                *over |= ((u32)(tr_cc - over) & 0x7ffff) << 5;
            }
            break;
        }
        case OP_JMP: {
            u32 *back = internal_target(in->target, idx);
            if (back) {
                b_rel((int)(back - tr_cc));
            } else {
                add_pending(tr_cc, in->target, SVC_DIRECT, 1);
                b_rel(0);
            }
            break;
        }
        case OP_CALL: {
            // Guest push first (it can fault), shadow pair next, then a real bl so that the matching ret is predicted.
            movimm(S0, in->next);
            E(0xF8000C00u | ((u32)-8 & 0x1ff) << 12 | 4 << 5 | S0);
            adr_words(S1, 3);
            E(0xA9800000u | ((u32)-2 & 0x7f) << 15 | S1 << 10 | RS << 5 | S0); // stp x16, x17, [x26, #-16]!
            add_pending(tr_cc, in->target, SVC_CALL, 1);
            bl_rel(0);
            break;
        }
        case OP_CALLI: {
            if (in->rm_reg)
                mov_reg(1, S0, in->rm);
            else
                ldst(1, 8, S0, addr_prepare(in, 8));
            movimm(S1, in->next);
            E(0xF8000C00u | ((u32)-8 & 0x1ff) << 12 | 4 << 5 | S1);
            adr_words(AD, 4);
            E(0xA9800000u | ((u32)-2 & 0x7f) << 15 | AD << 10 | RS << 5 | S1);
            bl_rel((int)((i64)(tr_stub_lookup - tr_cc_va(tr_cc)) / 4));
            E(0xD63F0000u | S2 << 5); // blr x22
            // landing pad: the next instruction (adr above counts from the adr: push, stp, bl, blr, then here)
            break;
        }
        case OP_JMPI:
            if (in->rm_reg)
                mov_reg(1, S0, in->rm);
            else
                ldst(1, 8, S0, addr_prepare(in, 8));
            emit_indirect_tail();
            break;
        case OP_RET: {
            E(0xF8400400u | 8 << 12 | 4 << 5 | S0); // ldr x16, [x4], #8
            if (in->imm) {
                if (in->imm < 4096)
                    add_imm(1, 0, 0, 4, 4, (u32)in->imm);
                else {
                    movimm(S1, (u64)in->imm);
                    add_reg(1, 0, 0, 4, 4, S1, 0);
                }
            }
            if (cfg.no_return_prediction) { // the guest's value decides, by lookup
                b_rel((int)((i64)(tr_stub_ret_miss - tr_cc_va(tr_cc)) / 4));
                break;
            }
            E(0xA8C00000u | 2 << 15 | LR << 10 | RS << 5 | S1); // ldp x17, x30, [x26], #16
            logic_reg(1, 2, 0, S1, S1, S0);
            cbz(1, 1, S1, 2);
            ret_reg(LR);
            b_rel((int)((i64)(tr_stub_ret_miss - tr_cc_va(tr_cc)) / 4));
            break;
        }
        default:
            break;
    }
    (void)live_after;
}

// Patch helper: resolves a forward reference.
static void fix(u32 *site, int form, u32 *to) {
    i64 d = to - site;
    if (form == 0)
        *site = (*site & ~(0x7ffffu << 5)) | ((u32)d & 0x7ffff) << 5;
    else
        *site = (*site & 0xFC000000u) | ((u32)d & 0x3ffffff);
}

static void flush_everything(void) {
    tr_flush_all();
}

static TrResult do_translate(int view, u64 cr3, int cpl, u64 rip, bool single) {
    u64 t0 = mach_absolute_time();
    TrResult res = {0};
    res.frames[0] = res.frames[1] = ~0ULL;
    static Insn list[MAX_INSNS];
    walk_cr3 = cr3;
    walk_cpl = cpl;
    tr_cpl = cpl;
    if ((u8 *)tr_cc - (u8 *)cc_base > (long)(cc_limit - 0x40000) || hblock_count >= BLOCKS_MAX - 2 ||
        pc_map_used + MAX_INSNS >= PCMAP_BYTES / sizeof(PcMap)) {
        flush_everything();
        res.flushed = true;
    }
    int count = 0;
    u64 pc = rip, page = rip & ~0xfffULL;
    do {
        x86_decode(pc, &list[count]);
        Insn *in = &list[count];
        if (in->op == OP_BAD && in->why && !strcmp(in->why, "FETCH_FAULT")) {
            if (count == 0) {
                res.fetch_fault_va = in->target ? in->target : pc;
                return res;
            }
            break; // cut the block before it, the fault belongs to the instruction when it runs
        }
        pc = in->next;
        count++;
        if (in->next > page + 4096 && count > 0) {
            // Crossed into the next page: record it, end here.
            u64 gpa;
            if (fetch_walk(page + 4096, &gpa))
                res.frames[1] = gpa & ~0xfffULL;
            break;
        }
    } while (!single && count < MAX_INSNS && !insn_is_terminator(&list[count - 1]) && (pc & ~0xfffULL) == page);

    u64 gpa0 = 0;
    fetch_walk(rip, &gpa0);
    res.frames[0] = gpa0 & ~0xfffULL;

    Insn *last = &list[count - 1];
    bool fallthrough_end = !(last->op == OP_JMP || last->op == OP_JMPI || last->op == OP_RET || last->op == OP_BAD ||
                             last->op == OP_UD || last->op == OP_IRET);
    int live;
    if (last->op == OP_JMP)
        live = flags_needed_at(last->target, page, 2);
    else if (!fallthrough_end)
        live = F_ARITH;
    else
        live = flags_needed_at(last->next, page, 2);
    static u8 live_after[MAX_INSNS];
    for (int i = count - 1; i >= 0; i--) {
        Insn *in = &list[i];
        if (in->op == OP_JCC || in->op == OP_JRCXZ)
            live |= flags_needed_at(in->target, page, 1);
        else if (in->op == OP_CALL || in->op == OP_CALLI)
            live = F_ARITH; // the callee and the landing pad are unknown
        else if (in->op == OP_JMP || in->op == OP_JMPI || in->op == OP_RET)
            live = i == count - 1 ? live : F_ARITH;
        live_after[i] = (u8)(cfg.all_flags_live ? F_ARITH : live);
        live = (live & ~in->writes) | insn_reads(in);
    }

    block_insns = list;
    insn_total = count;
    pend_count = 0;
    u32 *start = tr_cc;
    u32 map0 = pc_map_used;
    for (int i = 0; i < count; i++) {
        const Insn *in = &list[i];
        insn_arm[i] = tr_cc;
        pc_map[pc_map_used].arm_word = (u16)(tr_cc - start);
        pc_map[pc_map_used].rip_off = (u16)(in->rip - rip);
        pc_map_used++;
        stats.insns++;
        switch (in->op) {
            case OP_JCC:
            case OP_JRCXZ:
            case OP_JMP:
            case OP_CALL:
            case OP_CALLI:
            case OP_JMPI:
            case OP_RET:
                emit_control(in, i, live_after[i]);
                break;
            case OP_BAD:
                emit_stop(in->rip, in->why);
                break;
            case OP_UD:
                svc(SVC_UD);
                break;
            case OP_SSE:
            case OP_LDMXCSR:
            case OP_STMXCSR:
                emit_sse(in, live_after[i]);
                break;
            case OP_SYSCALL:
            case OP_SYSRET:
            case OP_IRET:
            case OP_INT:
            case OP_INT3:
            case OP_HLT:
            case OP_CPUID:
            case OP_RDTSC:
            case OP_RDTSCP:
            case OP_RDMSR:
            case OP_WRMSR:
            case OP_CLI:
            case OP_STI:
            case OP_MOV_CR:
            case OP_MOV_DR:
            case OP_INVLPG:
            case OP_INVPCID:
            case OP_WBINVD:
            case OP_CLTS:
            case OP_LGDT:
            case OP_LTR:
            case OP_MOV_SEG:
            case OP_IN:
            case OP_OUT:
            case OP_SWAPGS:
            case OP_FXSAVE:
            case OP_FXRSTOR:
                emit_monitor_op(in);
                break;
            default:
                emit_int(in, live_after[i]);
                break;
        }
    }
    u32 *tail = tr_cc;
    if (fallthrough_end) {
        svc(SVC_DIRECT);
        stub_lit(last->next);
    }
    for (int i = 0; i < pend_count; i++) {
        u32 *stub = tr_cc;
        svc(pend[i].kind);
        stub_lit(pend[i].target);
        if (pend[i].kind == SVC_JCC)
            E((u32)(stub - pend[i].site));
        fix(pend[i].site, pend[i].form, stub);
    }
    (void)tail;

    // Registers the block.
    u32 idx = hblock_count++;
    HostBlock *hb = &hblocks[idx];
    memset(hb, 0, sizeof *hb);
    hb->rip = rip;
    hb->view = (u32)block_key(view, cr3, cpl, rip);
    hb->entry_word = (u32)(start - cc_base);
    hb->frame[0] = res.frames[0];
    hb->frame[1] = res.frames[1];
    for (int f = 0; f < 2; f++) {
        if (hb->frame[f] != ~0ULL && hb->frame[f] < cfg.ram_size) {
            u32 *head = &frame_head[hb->frame[f] >> 12];
            hb->next_on_frame[f] = *head;
            *head = idx + 1;
        }
    }
    BlockEntry *be = &block_table[idx];
    be->rip = rip;
    be->arm_off = (u32)(start - cc_base);
    be->arm_words = (u32)(tr_cc - start);
    be->map_off = map0;
    be->map_count = (u32)count;
    if (!single) {
        map_insert((int)hb->view, rip, idx + 1);
        hb->registered = true;
    }
    __sync_synchronize();
    ctx_ptr->block_count = hblock_count;
    sys_icache_invalidate(start, (u8 *)tr_cc - (u8 *)start);
    stats.blocks++;
    stats.words += tr_cc - start;
    res.arm = tr_cc_va(start);
    stats.translate_ns += mach_absolute_time() - t0;
    return res;
}

// Privileged and rare instructions run in the monitor. Views are per CPL, so CPL-3 code simply takes #GP where it must.
static void emit_monitor_op(const Insn *in) {
    bool cpl0_only = false;
    switch (in->op) {
        case OP_HLT:
        case OP_RDMSR:
        case OP_WRMSR:
        case OP_MOV_CR:
        case OP_MOV_DR:
        case OP_INVLPG:
        case OP_INVPCID:
        case OP_WBINVD:
        case OP_CLTS:
        case OP_SYSRET:
        case OP_SWAPGS:
            cpl0_only = true;
            break;
        case OP_LGDT:
            cpl0_only = in->sub <= 1; // sgdt and sidt are not privileged without UMIP, which isn't offered: libsystem reads the CPU number with sidt
            break;
        case OP_LTR:
            cpl0_only = in->sub == 0 || in->sub == 2;
            break;
        default:
            break;
    }
    if (cpl0_only && tr_cpl != 0) {
        svc(SVC_GP0);
        return;
    }
    switch (in->op) {
        case OP_SYSCALL:
            svc(SVC_SYSCALL);
            break;
        case OP_SYSRET:
            mov_reg(1, S0, XZR);
            movimm(S0, in->sz == 8);
            svc(SVC_SYSRET);
            break;
        case OP_IRET:
            movimm(S0, in->sz);
            svc(SVC_IRET);
            break;
        case OP_INT:
            movimm(S1, (u64)in->imm);
            svc(SVC_INT);
            break;
        case OP_INT3:
            svc(SVC_INT3);
            break;
        case OP_HLT:
            svc(SVC_HLT);
            break;
        case OP_CPUID:
            svc(SVC_CPUID);
            break;
        case OP_RDTSC:
            svc(SVC_RDTSC);
            break;
        case OP_RDTSCP:
            svc(SVC_RDTSCP);
            break;
        case OP_RDMSR:
            svc(SVC_RDMSR);
            break;
        case OP_WRMSR:
            svc(SVC_WRMSR);
            break;
        case OP_CLI:
            svc(SVC_CLI);
            break;
        case OP_STI:
            svc(SVC_STI);
            break;
        case OP_MOV_CR: {
            int cr = in->reg;
            if (cr != 0 && cr != 2 && cr != 3 && cr != 4 && cr != 8) {
                svc(SVC_UD);
                break;
            }
            movimm(S0, (u64)cr);
            if (in->to_reg) {
                svc(SVC_MOV_CR_READ);
                mov_reg(1, in->rm, S0);
            } else {
                mov_reg(1, S1, in->rm);
                svc(SVC_MOV_CR_WRITE);
            }
            break;
        }
        case OP_MOV_DR:
            emit_stop(in->rip, "debug registers");
            break;
        case OP_INVLPG: {
            Insn t = *in;
            mov_reg(1, S0, addr_reg(&t));
            svc(SVC_INVLPG);
            break;
        }
        case OP_INVPCID:
            svc(SVC_INVPCID);
            break;
        case OP_WBINVD:
            svc(SVC_WBINVD);
            break;
        case OP_CLTS:
            svc(SVC_CLTS);
            break;
        case OP_LGDT: {
            // Limit word, then base. The load comes before anything changes.
            int r = addr_reg(in);
            if (in->sub <= 1) {
                Addr a = {.base = r};
                ldst(1, 2, S1, a);
                a.imm = 2;
                ldst(1, 8, S0, a);
                svc(in->sub == 0 ? SVC_LGDT : SVC_LIDT);
            } else {
                mov_reg(1, S2, r);
                svc(in->sub == 2 ? SVC_SGDT : SVC_SIDT);
                Addr a = {.base = S2};
                ldst(0, 2, S1, a);
                a.imm = 2;
                ldst(0, 8, S0, a);
            }
            break;
        }
        case OP_LTR: {
            int mode = in->sub; // 0 ltr, 1 str, 2 lldt, 3 sldt
            bool read = mode == 1 || mode == 3;
            int svcn = mode == 0 ? SVC_LTR : mode == 1 ? SVC_STR : mode == 2 ? SVC_LLDT : SVC_SLDT;
            if (read) {
                svc(svcn);
                if (in->rm_reg)
                    gpr_write(in->rm, in->sz, false, S0);
                else
                    ldst(0, 2, S0, addr_prepare(in, 2));
            } else {
                if (in->rm_reg)
                    mov_reg(1, S0, in->rm);
                else
                    ldst(1, 2, S0, addr_prepare(in, 2));
                svc(svcn);
            }
            break;
        }
        case OP_MOV_SEG: {
            movimm(S0, in->sub);
            if (in->to_reg) {
                svc(SVC_MOV_SEG_READ);
                if (in->rm_reg)
                    gpr_write(in->rm, in->sz == 2 ? 2 : in->sz, false, S0);
                else
                    ldst(0, 2, S0, addr_prepare(in, 2));
            } else {
                if (in->rm_reg)
                    mov_reg(1, S1, in->rm);
                else
                    ldst(1, 2, S1, addr_prepare(in, 2));
                svc(SVC_MOV_SEG_WRITE);
            }
            break;
        }
        case OP_IN:
        case OP_OUT: {
            if (in->has_imm)
                movimm(S0, (u64)in->imm & 0xff);
            else
                ubfx(0, S0, 2, 0, 16);
            movimm(S1, in->sz);
            if (in->op == OP_IN) {
                svc(SVC_IN);
                gpr_write(0, in->sz, false, S0);
            } else {
                mov_reg(1, S2, 0);
                svc(SVC_OUT);
            }
            break;
        }
        case OP_SWAPGS:
            E(0xF9400000u | (u32)(__builtin_offsetof(EngineCtx, kernel_gs_base) / 8) << 10 | CTX << 5 | S0);
            E(0xF9000000u | (u32)(__builtin_offsetof(EngineCtx, kernel_gs_base) / 8) << 10 | CTX << 5 | R_GS);
            mov_reg(1, R_GS, S0);
            break;
        case OP_FXSAVE:
        case OP_FXRSTOR: {
            // Probe both ends, so the monitor's access cannot fault for the guest's reasons.
            int r = addr_reg(in);
            if (r != S0)
                mov_reg(1, S0, r);
            ubfx(1, S1, S0, 0, 4);
            cbz(0, 1, S1, 2);
            svc(SVC_GP0);
            Addr a = {.base = S0};
            ldst(1, 8, XZR, a);
            a.imm = 504;
            ldst(1, 8, XZR, a);
            if (in->op == OP_FXSAVE) {
                a.imm = 0;
                ldst(1, 8, S1, a);
                ldst(0, 8, S1, a);
                a.imm = 504;
                ldst(1, 8, S1, a);
                ldst(0, 8, S1, a);
            }
            svc(in->op == OP_FXSAVE ? SVC_FXSAVE : SVC_FXRSTOR);
            break;
        }
        default:
            emit_stop(in->rip, "no monitor path for this instruction");
    }
}

void tr_init(const TrConfig *config) {
    cfg = *config;
    cc_base = (u32 *)(cfg.priv + OFF_CC);
    tr_cc = cc_base;
    block_table = (BlockEntry *)(cfg.priv + OFF_BLOCKS);
    pc_map = (PcMap *)(cfg.priv + OFF_PCMAP);
    ctx_ptr = (EngineCtx *)(cfg.priv + OFF_CTX);
    tr_precise_flags = cfg.precise_flags;
    tr_has_tzcnt = cfg.has_tzcnt_lzcnt;
    tr_hybrid = cfg.hybrid;
    tr_no_bulk_rep = cfg.no_bulk_rep;
    cc_limit = cfg.code_cache_bytes ? cfg.code_cache_bytes : CC_SIZE;
    tr_stub_lookup = cfg.stub_lookup;
    tr_stub_ret_miss = cfg.stub_ret_miss;
    tr_stub_pushf = cfg.stub_pushf;
    tr_stub_sahf = cfg.stub_sahf;
    hblocks = calloc(BLOCKS_MAX, sizeof(HostBlock));
    block_map = calloc(MAP_SIZE, sizeof(MapEntry));
    frame_head = calloc(cfg.ram_size >> 12, sizeof(u32));
}

TrResult tr_translate(int view, uint64_t cr3, int cpl, uint64_t rip, bool single) {
    if (view > view_high)
        view_high = view;
    int key = block_key(view, cr3, cpl, rip);
    if (!single) {
        u32 hit = map_find(key, rip);
        if (hit) {
            TrResult r = {0};
            r.arm = tr_cc_va(cc_base + hblocks[hit - 1].entry_word);
            r.frames[0] = hblocks[hit - 1].frame[0];
            r.frames[1] = hblocks[hit - 1].frame[1];
            r.key = key;
            return r;
        }
    }
    TrResult r = do_translate(view, cr3, cpl, rip, single);
    r.key = key;
    return r;
}

// The block holding a code cache word. Blocks only grow upward, so the table is sorted.
static HostBlock *block_at(u32 word) {
    u32 lo = 0, hi = hblock_count;
    while (lo < hi) {
        u32 mid = (lo + hi) / 2;
        if (hblocks[mid].entry_word <= word)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo ? &hblocks[lo - 1] : 0;
}

void tr_link(uint64_t site, int kind, uint64_t arm, int key) {
    u32 *s = cc_host(site);
    // A link is forever, so it may only join blocks of one domain: a chain from shared code into one view's code would be wrong in the next.
    HostBlock *from = block_at((u32)(s - cc_base));
    if (!from || (int)from->view != key)
        return;
    i64 d = ((i64)arm - (i64)site) >> 2;
    if (kind == SVC_CALL)
        *s = 0x94000000u | ((u32)d & 0x3ffffff);
    else
        *s = 0x14000000u | ((u32)d & 0x3ffffff);
    sys_icache_invalidate(s, 4);
    if (kind == SVC_JCC) { // the stub's fourth word locates the conditional branch: go straight to the block if it reaches
        u32 back = s[3];
        u32 *cond = s - back;
        i64 off = ((i64)arm - (i64)tr_cc_va(cond)) >> 2;
        if (off >= -(1 << 18) && off < (1 << 18)) {
            *cond = (*cond & ~(0x7ffffu << 5)) | ((u32)off & 0x7ffff) << 5;
            sys_icache_invalidate(cond, 4);
        }
    }
}

static u64 *hash_table(int view) { return (u64 *)(cfg.priv + OFF_HASH + (u64)view * HASH_BYTES); }

static inline u32 crc32c64(u64 v) {
    u32 c = 0;
    __asm__("crc32cx %w0, %w0, %x1" : "+r"(c) : "r"(v));
    return c;
}

void tr_hash_insert(int view, uint64_t rip, uint64_t arm) {
    u64 *t = hash_table(view);
    u32 h = crc32c64(rip) & (HASH_ENTRIES - 1);
    for (u32 n = 0; n < HASH_ENTRIES; n++, h = (h + 1) & (HASH_ENTRIES - 1)) {
        u64 key = t[h * 2];
        if (key == rip) {
            t[h * 2 + 1] = arm;
            return;
        }
        if (key == 0 || key == 1) {
            t[h * 2 + 1] = arm;
            __sync_synchronize();
            t[h * 2] = rip;
            return;
        }
    }
    // shortcut: a full table leaves this target on the slow path, fine at 64K entries per view
}

static void hash_remove(int view, u64 rip) {
    u64 *t = hash_table(view);
    u32 h = crc32c64(rip) & (HASH_ENTRIES - 1);
    for (u32 n = 0; n < HASH_ENTRIES; n++, h = (h + 1) & (HASH_ENTRIES - 1)) {
        u64 key = t[h * 2];
        if (key == 0)
            return;
        if (key == rip) {
            t[h * 2] = 1; // tombstone: nonzero and never a valid target of a lookup that matters
            return;
        }
    }
}

static void kill_block(u32 idx) {
    HostBlock *hb = &hblocks[idx];
    if (hb->dead)
        return;
    hb->dead = true;
    if (hb->registered) {
        map_remove((int)hb->view, hb->rip);
        if (hb->view & KEY_DOMAIN) {
            for (int v = 0; v <= view_high; v++)
                hash_remove(v, hb->rip);
        } else
            hash_remove((int)hb->view, hb->rip);
    }
    u32 *entry = cc_base + hb->entry_word;
    *entry = 0xD4000001u | SVC_DEAD << 5;
    sys_icache_invalidate(entry, 4);
    stats.invalidated++;
}

int tr_invalidate_frame(uint64_t gpa) {
    int n = 0;
    if (gpa >= cfg.ram_size)
        return 0;
    u32 fr = (u32)(gpa >> 12);
    u32 it = frame_head[fr];
    frame_head[fr] = 0;
    u64 frame = gpa & ~0xfffULL;
    while (it) {
        HostBlock *hb = &hblocks[it - 1];
        u32 next = hb->frame[0] == frame ? hb->next_on_frame[0] : hb->next_on_frame[1];
        if (!hb->dead) {
            kill_block(it - 1);
            n++;
        }
        it = next;
    }
    return n;
}

int tr_invalidate_view_va(int view, uint64_t va) {
    // Blocks are registered by frame, so this walks the view's blocks at this page via their start rip.
    int n = 0;
    u64 page = va & ~0xfffULL;
    for (u32 i = 0; i < hblock_count; i++) {
        HostBlock *hb = &hblocks[i];
        if (!hb->dead && ((int)hb->view == view || (hb->view & KEY_DOMAIN)) && (hb->rip & ~0xfffULL) == page) {
            kill_block(i);
            n++;
        }
    }
    return n;
}

void tr_view_drop(int view) {
    for (u32 i = 0; i < hblock_count; i++)
        if (!hblocks[i].dead && (int)hblocks[i].view == view)
            kill_block(i);
    memset(hash_table(view), 0, HASH_BYTES);
    ctx_ptr->tr_flushed = 1;
}

void tr_flush_all(void) {
    ctx_ptr->tr_flushed = 1;
    tr_cc = cc_base;
    hblock_count = 0;
    pc_map_used = 0;
    ctx_ptr->block_count = 0;
    memset(block_map, 0, MAP_SIZE * sizeof(MapEntry));
    memset(frame_head, 0, (cfg.ram_size >> 12) * sizeof(u32));
    for (int v = 0; v <= view_high; v++)
        memset(hash_table(v), 0, HASH_BYTES);
}

TrStats tr_stats(void) { return stats; }

