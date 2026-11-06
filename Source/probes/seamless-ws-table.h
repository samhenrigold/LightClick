// What seamless-ws-hook.c, inside WindowServer, shares with seamless-guest: a file mapped by both, with a row per
// window the guest tool wants and that window's pixels as its backing store holds them. The tool writes `id`; the hook
// writes the rest. Nothing needs a round trip to WindowServer, and an unchanged window costs a compare of one number.
//
// shortcut: a world-writable file in /var/tmp, on a throwaway clone. A shipping version needs a private channel.
#ifndef SEAMLESS_WS_TABLE_H
#define SEAMLESS_WS_TABLE_H
#include <stdint.h>

#define SWS_PATH "/var/tmp/seamless-ws.table"
#define SWS_MAGIC 0x31535753u
#define SWS_SLOTS 64
#define SWS_ARENA (512u * 1024 * 1024)

struct SWSEntry {
    uint32_t id; // Written by the tool; 0 means free.
    uint32_t present; // The window exists and has a backing store.
    uint32_t accelerated; // Drawn on the GPU, so these pixels aren't the window's: the tool must capture it.
    uint32_t width, height; // Pixels. Rows here are tightly packed BGRA premultiplied, top first.
    volatile uint32_t sequence; // Goes up when any row changes.
    uint64_t offset; // Into the arena.
    uint64_t next_compare, copy_rows, seed_skips;
    uint32_t seed, opaque; // `opaque`: no alpha in these rows, so treat every pixel as solid.
};

struct SWSTable {
    uint32_t magic, version;
    volatile uint64_t passes;
    volatile uint64_t ticks_spent;
    uint64_t arena_used;
    uint32_t ticks_numer, ticks_denom; // mach_timebase_info, for the tool to convert ticks_spent.
    struct SWSEntry slots[SWS_SLOTS];
    uint8_t arena[SWS_ARENA];
};
#endif
