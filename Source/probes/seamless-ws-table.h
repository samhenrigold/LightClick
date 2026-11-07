// What seamless-ws-hook.c, inside WindowServer, shares with seamless-guest: a file mapped by both, with a row per
// window the guest tool wants and that window's pixels as its backing store holds them. The tool writes `id`; the hook
// writes the rest. Nothing needs a round trip to WindowServer, and an unchanged window costs a compare of one number.
//
// shortcut: a world-writable file in /var/tmp, on a throwaway clone. A shipping version needs a private channel.
#ifndef SEAMLESS_WS_TABLE_H
#define SEAMLESS_WS_TABLE_H
#include <stdint.h>

#define SWS_PATH "/var/tmp/seamless-ws.table"
#define SWS_MAGIC 0x31535755u
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

// One visible window, in WindowServer's own order, as of the last walk. Replaces asking for the window list.
struct SWSTreeEntry {
    uint32_t id, connection;
    int32_t level;
    float alpha;
    double x, y, width, height; // Points, top-left origin.
    uint32_t margin; // Points of shadow around the bounds, at most, or 0 for no shadow.
    uint32_t shadow_key; // Changes when the window's shadow does, such as on losing focus.
    uint32_t has_surfaces; // GL, video or CA surfaces drawn over the backing, which the backing doesn't hold.
    uint32_t reserved;
};
#define SWS_TREE 256
#define SWS_FLUSHES 4096
#define SWS_PLACEMENTS 64
#define SWS_BACKDROPS 1024

struct SWSTable {
    uint32_t magic, version;
    volatile uint64_t passes;
    volatile uint64_t ticks_spent;
    uint64_t arena_used;
    uint32_t ticks_numer, ticks_denom; // mach_timebase_info, for the tool to convert ticks_spent.
    struct SWSEntry slots[SWS_SLOTS];
    volatile uint32_t tree_generation; // Odd while being written.
    uint32_t tree_count;
    struct SWSTreeEntry tree[SWS_TREE];
    // Surface flushes seen, by window ID modulo the size. A clash only means an extra capture.
    volatile uint32_t surface_flushes[SWS_FLUSHES];
    // Where WindowServer's composite draws a window, by how far from where it is. Nothing else about the window
    // changes.
    struct SWSPlacement {
        volatile uint32_t id;
        volatile int32_t dx, dy; // Device pixels.
    } placements[SWS_PLACEMENTS];
    volatile uint64_t placed_redraws;
    // Mojave, per-window composites on the GPU: see seamless-ws-mojave.h. The tool writes the first two.
    volatile uint32_t gpu_mode;
    volatile float gpu_scale;
    volatile uint64_t gpu_generate_calls, gpu_composites, gpu_ticks, gpu_whole_composites;
    // Windows nobody will show, such as the desktop's, so not worth a composite. The tool writes these.
    volatile uint32_t gpu_skip_count, gpu_skip[64];
    // Every window in the last update, front first: what the host's surface for each one holds, in points.
    volatile uint32_t gpu_row_generation, gpu_row_count;
    struct SWSGPURow {
        uint32_t id, frames;
        float x, y, width, height; // The surface's content: the window with its shadow.
        float window_x, window_y, window_width, window_height;
    } gpu_rows[SWS_TREE];
    // A rectangle of a window's material, in points, top-left origin. Odd while being written.
    volatile uint32_t gpu_backdrop_generation, gpu_backdrop_count;
    volatile struct SWSBackdrop {
        uint32_t id, order, material, active, blend;
        float x, y, width, height, saturation;
        float color[12];
    } gpu_backdrops[SWS_BACKDROPS];
    // The tool writes this: leave the window's shadow out of its surface, for the host to draw one.
    volatile uint32_t gpu_no_shadow;
    // The tool writes this, for measuring what the marker costs. Nothing reaches the host without one.
    volatile uint32_t gpu_no_marker;
    // The tool writes these with the mode: the display's size, in points.
    volatile uint32_t gpu_display_width, gpu_display_height;
    // The tool writes this: how many surface updates to print the layer trees of.
    volatile int32_t gpu_census;
    // What a census printed as contents, by the index it printed: top row first, 4 bytes a pixel, in the arena.
    volatile uint32_t gpu_blob_count;
    struct SWSBlob {
        uint32_t width, height, row;
        uint64_t offset;
    } gpu_blobs[4096];
    // Set by the hook once all its patches are in, for seamless-ws-inject to read.
    volatile int32_t installed_pid;
    uint8_t arena[SWS_ARENA];
};
#endif
