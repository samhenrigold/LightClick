// Where a guest window goes on the oversized guest display, so that no window ever covers another and a crop of the
// framebuffer is always this window's own pixels. Coordinates are guest points, with a top-left origin.
#ifndef SEAMLESS_SLOTS_H
#define SEAMLESS_SLOTS_H

// Clear of the menu bar and Dock, which also keeps the pointer away from auto-hide and hot corners.
#define SWM_SLOT_MARGIN_TOP 64
#define SWM_SLOT_MARGIN_SIDE 64
#define SWM_SLOT_MARGIN_BOTTOM 128
// Wider than a window shadow, so a neighbor's shadow never lands inside a crop.
#define SWM_SLOT_DEFAULT_GAP 64

struct SWMSlotLayout {
    int display_width, display_height, slot_width, slot_height, gap;
};

// Slots fill rows left to right, top to bottom. Returns 0 if this one doesn't fit.
static inline int swm_slot_origin(const struct SWMSlotLayout *l, int index, int *x, int *y) {
    if (index < 0 || l->slot_width <= 0 || l->slot_height <= 0 || l->gap < 0)
        return 0;
    int width = l->display_width - 2 * SWM_SLOT_MARGIN_SIDE,
        height = l->display_height - SWM_SLOT_MARGIN_TOP - SWM_SLOT_MARGIN_BOTTOM;
    if (width < l->slot_width || height < l->slot_height)
        return 0;
    int columns = (width + l->gap) / (l->slot_width + l->gap), rows = (height + l->gap) / (l->slot_height + l->gap);
    if (index / columns >= rows)
        return 0;
    *x = SWM_SLOT_MARGIN_SIDE + index % columns * (l->slot_width + l->gap);
    *y = SWM_SLOT_MARGIN_TOP + index / columns * (l->slot_height + l->gap);
    return 1;
}
#endif
