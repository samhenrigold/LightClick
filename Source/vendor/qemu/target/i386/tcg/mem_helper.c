/*
 *  x86 memory access helpers
 *
 *  Copyright (c) 2003 Fabrice Bellard
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, see <http://www.gnu.org/licenses/>.
 */

#include "qemu/osdep.h"
#include "cpu.h"
#include "exec/helper-proto.h"
#include "accel/tcg/cpu-ldst.h"
#include "qemu/int128.h"
#include "qemu/atomic128.h"
#include "tcg/tcg.h"
#include "helper-tcg.h"
#include "accel/tcg/probe.h"
#include "exec/target_page.h"
#include "rep-bulk.h"

/*
 * Whole pages of REP MOVS/STOS through host memory, leaving everything awkward
 * to the element loop the translator emits after this call. Returns nonzero if
 * it stopped for the budget, so the translator can return to the main loop and
 * take interrupts. Returning 0 with RCX nonzero hands the rest to that loop.
 *
 * - Faults: probes do not fault. An unmapped or forbidden page stops the copy
 *   with RCX/RSI/RDI counting only finished elements, and the loop takes the
 *   fault from there, as on hardware.
 * - MMIO, ROM, watchpoints, plugins: nonzero probe flags, so also the loop's.
 * - Clean RAM and self-modifying code: the store probe marks the range dirty
 *   and invalidates its TBs. That may leave through cpu_loop_exit, which is safe
 *   because the registers are current at every probe.
 * - An element across a page: one normal access pair, which may fault precisely.
 * - RSI, RDI or a 32-bit linear address reaching a wrap: stop for the loop.
 */
#define REP_BULK_BUDGET (1 << 20)

static inline bool rep_bulk_fits(uint64_t value, uint64_t n, bool down,
                                 uint64_t limit)
{
    return down ? value >= n : value < limit && limit - value > n;
}

static inline uint64_t rep_bulk_room(uint64_t addr, unsigned size, bool down)
{
    return down ? ((addr + size - 1) & ~TARGET_PAGE_MASK) + 1
                : TARGET_PAGE_SIZE - (addr & ~TARGET_PAGE_MASK);
}

uint32_t helper_rep_bulk(CPUX86State *env, target_ulong src, target_ulong dst,
                         uint32_t desc)
{
    uintptr_t ra = GETPC();
    unsigned ot = extract32(desc, 0, 2), size = 1 << ot;
    bool movs = extract32(desc, 3, 1), down = env->df < 0;
    uint64_t mask = extract32(desc, 2, 1) ? UINT64_MAX : UINT32_MAX;
    uint64_t limit = env->hflags & HF_CS64_MASK ? UINT64_MAX : UINT32_MAX;
    int mmu_idx = extract32(desc, 8, 8);
    uint64_t budget = REP_BULK_BUDGET, cx;

    /* Host TSO may be off, and the stores must stay ordered around the insn. */
    smp_mb();
    while ((cx = env->regs[R_ECX] & mask)) {
        uint64_t rsi = env->regs[R_ESI] & mask, rdi = env->regs[R_EDI] & mask;
        uint64_t n, span;

        if (!budget) {
            smp_mb();
            return 1;
        }
        n = MIN(cx, budget >> ot) << ot;
        n = MIN(n, rep_bulk_room(dst, size, down));
        if (movs) {
            n = MIN(n, rep_bulk_room(src, size, down));
        }
        n &= -(uint64_t)size;
        span = MAX(n, size);

        if (!rep_bulk_fits(rdi, span, down, mask) ||
            !rep_bulk_fits(dst, span, down, limit) ||
            (movs && (!rep_bulk_fits(rsi, span, down, mask) ||
                      !rep_bulk_fits(src, span, down, limit)))) {
            break;
        }

        if (n) {
            uint64_t src_low = down ? src + size - n : src;
            uint64_t dst_low = down ? dst + size - n : dst;
            void *hsrc = NULL, *hdst;

            if ((movs && probe_access_flags(env, src_low, n, MMU_DATA_LOAD,
                                            mmu_idx, true, &hsrc, ra)) ||
                probe_access_flags(env, dst_low, n, MMU_DATA_STORE, mmu_idx,
                                   true, &hdst, ra)) {
                break;
            }
            if (movs) {
                n = rep_bulk_copy(hdst, hsrc, n, size, down);
                if (!n) {
                    break;
                }
            } else {
                rep_bulk_fill(hdst, n, env->regs[R_EAX], size);
            }
        } else {
            MemOpIdx oi = make_memop_idx(MO_LE | ot, mmu_idx);
            uint64_t value = env->regs[R_EAX];

            n = size;
            switch (ot) {
            case MO_16:
                value = movs ? cpu_ldw_mmu(env, src, oi, ra) : value;
                cpu_stw_mmu(env, dst, value, oi, ra);
                break;
            case MO_32:
                value = movs ? cpu_ldl_mmu(env, src, oi, ra) : value;
                cpu_stl_mmu(env, dst, value, oi, ra);
                break;
            default:
                value = movs ? cpu_ldq_mmu(env, src, oi, ra) : value;
                cpu_stq_mmu(env, dst, value, oi, ra);
                break;
            }
        }

        env->regs[R_ECX] = (cx - (n >> ot)) & mask;
        env->regs[R_EDI] = (down ? rdi - n : rdi + n) & mask;
        dst = down ? dst - n : dst + n;
        if (movs) {
            env->regs[R_ESI] = (down ? rsi - n : rsi + n) & mask;
            src = down ? src - n : src + n;
        }
        budget -= n;
    }
    smp_mb();
    return 0;
}

void helper_boundw(CPUX86State *env, target_ulong a0, int v)
{
    int low, high;

    low = cpu_ldsw_le_data_ra(env, a0, GETPC());
    high = cpu_ldsw_le_data_ra(env, a0 + 2, GETPC());
    v = (int16_t)v;
    if (v < low || v > high) {
        if (env->hflags & HF_MPX_EN_MASK) {
            env->bndcs_regs.sts = 0;
        }
        raise_exception_ra(env, EXCP05_BOUND, GETPC());
    }
}

void helper_boundl(CPUX86State *env, target_ulong a0, int v)
{
    int low, high;

    low = cpu_ldl_le_data_ra(env, a0, GETPC());
    high = cpu_ldl_le_data_ra(env, a0 + 4, GETPC());
    if (v < low || v > high) {
        if (env->hflags & HF_MPX_EN_MASK) {
            env->bndcs_regs.sts = 0;
        }
        raise_exception_ra(env, EXCP05_BOUND, GETPC());
    }
}
