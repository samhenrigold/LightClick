// Host-only check of the REP bulk copy against an element-at-a-time model, including replicating overlaps.
//   xcrun clang -O1 -Wall -ISource/vendor/qemu/target/i386/tcg Source/probes/rep-bulk-test.c -o /tmp/rep-bulk-test
//   /tmp/rep-bulk-test
#include "rep-bulk.h"
#include <stdio.h>
#include <stdlib.h>

enum { SPACE = 16384 };
static uint8_t real[SPACE], model[SPACE];

static void reset(void) {
    for (int i = 0; i < SPACE; i++)
        real[i] = model[i] = (uint8_t)(i * 167 + 13);
}

int main(void) {
    static const size_t sizes[] = {1, 2, 4, 8};
    static const size_t gaps[] = {0, 1, 2, 3, 4, 7, 8, 9, 15, 16, 17, 31, 64, 100, 511, 512, 1024, 3000};
    unsigned long cases = 0;
    for (int down = 0; down < 2; down++)
        for (int sign = 0; sign < 2; sign++)
            for (size_t g = 0; g < sizeof(gaps) / sizeof(*gaps); g++)
                for (size_t s = 0; s < 4; s++)
                    for (size_t count = 1; count <= 200; count += count < 20 ? 1 : 37) {
                        size_t size = sizes[s], n = count * size, gap = gaps[g];
                        size_t src = 6000, dst = sign ? src - gap : src + gap;
                        reset();
                        // The helper loops on a chunk until done or until no progress.
                        size_t left = n;
                        while (left) {
                            // Going down the remainder is the low part; going up it is the high part.
                            size_t at = down ? 0 : n - left;
                            size_t done = rep_bulk_copy(real + dst + at, real + src + at, left, size, down);
                            if (!done)
                                break;
                            left -= done;
                        }
                        // Model only the elements the helper finished; the translated loop does the rest.
                        size_t finished = (n - left) / size;
                        for (size_t e = 0; e < finished; e++) {
                            size_t i = down ? (count - 1 - e) * size : e * size;
                            uint8_t held[8];
                            memcpy(held, model + src + i, size);
                            memcpy(model + dst + i, held, size);
                        }
                        cases++;
                        if (memcmp(real, model, SPACE)) {
                            printf("FAIL copy down=%d gap=%s%zu size=%zu count=%zu\n", down, sign ? "-" : "+", gap,
                                   size, count);
                            return 1;
                        }
                        // Zero left over means the gap was under one element; nothing else may stop early.
                        if (left && !(gap && gap < size)) {
                            printf("FAIL progress down=%d gap=%zu size=%zu count=%zu left=%zu\n", down, gap, size,
                                   count, left);
                            return 1;
                        }
                    }
    for (size_t s = 0; s < 4; s++)
        for (size_t count = 1; count <= 40; count++)
            for (int pattern = 0; pattern < 3; pattern++) {
                size_t size = sizes[s], n = count * size;
                uint64_t value = pattern == 0   ? 0
                                 : pattern == 1 ? UINT64_C(0xabababababababab)
                                                : UINT64_C(0x8877665544332211);
                reset();
                rep_bulk_fill(real + 3, n, value, size);
                for (size_t e = 0; e < count; e++)
                    memcpy(model + 3 + e * size, &value, size);
                cases++;
                if (memcmp(real, model, SPACE)) {
                    printf("FAIL fill size=%zu count=%zu pattern=%d\n", size, count, pattern);
                    return 1;
                }
            }
    printf("ok %lu cases\n", cases);
    return 0;
}
