/*
 * Local AArch64 REP MOVS/STOS experiment, not an upstream contribution.
 * Host-pointer copies with the result of element-at-a-time string moves.
 * No QEMU dependencies, so probes/rep-bulk-test.c can compile it alone.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#ifndef I386_REP_BULK_H
#define I386_REP_BULK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/*
 * Copy up to @n bytes (a multiple of @size) between the low addresses of the
 * two ranges, and return how many were copied, or 0 if none could be.
 *
 * memmove equals an element loop unless each write lands on a source byte the
 * loop has yet to read: destination above source going up, or below it going
 * down. Those overlaps replicate a pattern, so copy no more than the distance
 * between them, which is then an ordinary non-overlapping copy. Going down,
 * that chunk is the top of the range. The test is on host addresses because
 * two guest pages can alias one host page.
 */
static inline size_t rep_bulk_copy(uint8_t *dst, const uint8_t *src, size_t n,
                                   size_t size, bool down)
{
    uintptr_t gap = down ? (uintptr_t)src - (uintptr_t)dst
                         : (uintptr_t)dst - (uintptr_t)src;

    if (gap && gap < n) {
        size_t limit = gap & ~(size - 1);

        if (down) {
            dst += n - limit;
            src += n - limit;
        }
        n = limit;
    }
    if (n) {
        memmove(dst, src, n);
    }
    return n;
}

/* The pattern repeats per element, so it needs no element-aligned stores. */
static inline void rep_bulk_fill(uint8_t *dst, size_t n, uint64_t value,
                                 size_t size)
{
    size_t i = 0;

    value &= UINT64_MAX >> (64 - size * 8);
    value *= size == 1 ? UINT64_C(0x0101010101010101) :
             size == 2 ? UINT64_C(0x0001000100010001) :
             size == 4 ? UINT64_C(0x0000000100000001) : 1;
    if (value == (value & 0xff) * UINT64_C(0x0101010101010101)) {
        memset(dst, value & 0xff, n);
        return;
    }
    for (; i + 8 <= n; i += 8) {
        memcpy(dst + i, &value, 8);
    }
    memcpy(dst + i, &value, n - i);
}

#endif
