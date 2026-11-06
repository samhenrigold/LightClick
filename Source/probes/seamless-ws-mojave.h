// Included by seamless-ws-hook.c. On Mojave, each damaged window composited on the GPU into its own surface, and
// nothing to the display. A guest IOSurface is a host IOSurface there, so the host takes each window's pixels as they
// are, and nothing is read in the guest. seamless-guest gpu --mode 1 turns it on, in `gpu_mode` of the table; off, this
// does nothing.
//
// Read from 18G103: update_display calls generate_layers_for_window for each window, front first, and stops at the
// first that returns nonzero. Returning 0 with no layers leaves the display alone and goes on to windows behind. A
// composite also calls it, which is what makes the layers. The capture surface comes as
// _XHWCaptureWindowListToIOSurface makes it, and Populate is the capture's own composite.
//
// Damage is of two kinds. CGXScheduleUpdateDisplay names who asked for this update, in
// add_connection_to_update_contributors, and a window is at +0x18 of its own, so a covered window whose app is drawing
// is damaged. CA's animations have no connection and nobody asks: for them the update's own region, at +0x50 of the
// state, says what changed on the display, so any window there gets a composite, needed or not. A window is also
// damaged when it's new or moved. Only what changed is drawn, as on a display: each surface has the last frame's change
// to catch up on, and a new or moved window is all drawn. So is one with anything over it, as the update's region
// leaves out what's covered: a covered window that changes costs a whole composite each frame.
//
// A surface's size says which window it is, as there's no other channel to the host. The low 8 bits of its width are
// the ID's, and of its height 0xA0 and the ID's top 4 bits. Past the window it's transparent.
#include <dlfcn.h>

void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *);

static char (*generate_layers_original)(char *, char *);
static void *(*capture_shape)(void *, int);
static void *(*compositor_for_device)(void *, int);
static int (*display_accelerator)(void *);
static void *(*metal_compositor)(int);
static int (*composite_window)(void *, void *, void *, void *, void *, int, int, int, int);
static void *(*region_intersection)(void *, void *);
static void *(*opaque_shape)(void *, int);
static char (*region_contains)(void *, void *);
static void *(*region_union)(void *, void *);
static void (*cf_release)(void *);
static void *(*main_display_device)(void);
static char (*regions_intersect)(void *, void *);
static char (*region_is_empty)(void *);
static void (*region_bounds)(struct RectResult *, void *);
static void (*region_free)(void *);
static void *(*device_rgb)(void);

struct GPUWindow {
    uint32_t id;
    int width, height; // Of the surface.
    void *surfaces[2];
    int next;
    void *pending, *previous; // What's changed since the last frame, and what changed in it. Null means all of it.
    int whole; // Everything's to be drawn, on both surfaces, on the next two.
    struct GPUWindow *more;
};
static struct GPUWindow *gpu_windows;
static uint32_t gpu_damaged[256];
static unsigned gpu_damaged_count;
static int gpu_busy;
static void (*contributors_original)(void *, void *);
static struct RectResult (*window_rect)(void *);
static void *gpu_contributors[64];
static unsigned gpu_contributor_count;
static unsigned gpu_order;
static void *gpu_in_front; // What the windows before this one in the update cover.
static void contributors_hook(void *connection, void *session) {
    unsigned i = 0;
    while (i < gpu_contributor_count && gpu_contributors[i] != connection)
        i++;
    if (i == gpu_contributor_count && i < 64 && connection)
        gpu_contributors[gpu_contributor_count++] = connection;
    contributors_original(connection, session);
}

static struct GPUWindow *gpu_window(uint32_t id) {
    struct GPUWindow *w = gpu_windows;
    while (w && w->id != id)
        w = w->more;
    if (!w) {
        w = calloc(1, sizeof(*w));
        w->id = id;
        w->whole = 2;
        w->more = gpu_windows;
        gpu_windows = w;
    }
    return w;
}

static char generate_layers_hook(char *state, char *window) {
    if (!table || !table->gpu_mode || gpu_busy) // Inside a composite it does what it always does.

        return generate_layers_original(state, window);
    table->gpu_generate_calls++;
    uint32_t id = *(const uint32_t *)(window + 0x10);
    for (uint32_t i = 0; i < table->gpu_skip_count && i < 64; i++)
        if (table->gpu_skip[i] == id)
            return 0;
    struct RectResult rect = window_rect(window);
    // shortcut: a row per window seen, by search. A real session keeps these in the window's own record.
    static struct {
        uint32_t id;
        struct RectResult rect;
    } known[SWS_TREE];
    unsigned k = 0;
    while (k < SWS_TREE && known[k].id && known[k].id != id)
        k++;
    int fresh = k < SWS_TREE && (known[k].id != id || memcmp(&known[k].rect, &rect, sizeof(rect)));
    if (k < SWS_TREE) {
        known[k].id = id;
        known[k].rect = rect;
    }
    void *connection = *(void **)(window + 0x18);
    int asked = 0;
    for (unsigned i = 0; i < gpu_contributor_count && !asked; i++)
        asked = gpu_contributors[i] == connection;
    void *damage = *(void **)(state + 0x50);
    void *shape = capture_shape(window, 1);
    int covered = shape && gpu_in_front && regions_intersect(gpu_in_front, shape);
    if (shape) {
        void *grown = gpu_in_front ? region_union(gpu_in_front, shape) : NULL;
        if (grown)
            region_free(gpu_in_front);
        gpu_in_front = grown ? grown : gpu_in_front;
        if (!gpu_in_front)
            gpu_in_front = region_union(shape, shape);
    }
    void *touched = damage && shape ? region_intersection(damage, shape) : NULL;
    if (touched && region_is_empty(touched)) {
        region_free(touched);
        touched = NULL;
    }
    if (shape)
        region_free(shape);
    if (fresh || asked || touched) {
        struct GPUWindow *w = gpu_window(id);
        if (fresh || !touched)
            w->whole = 2; // An app drawing where the display won't show it says nothing of where.
        else if (covered && !w->whole)
            w->whole = 1;
        if (touched) {
            void *grown = w->pending ? region_union(w->pending, touched) : NULL;
            if (grown) {
                region_free(w->pending);
                w->pending = grown;
            } else if (!w->pending) {
                w->pending = touched;
                touched = NULL;
            }
        }
        unsigned i = 0;
        while (i < gpu_damaged_count && gpu_damaged[i] != id)
            i++;
        if (i == gpu_damaged_count && gpu_damaged_count < 256)
            gpu_damaged[gpu_damaged_count++] = id;
    }
    if (touched)
        region_free(touched);
    if (gpu_order < SWS_TREE) {
        struct SWSGPURow *row = &table->gpu_rows[gpu_order++];
        row->id = id;
        row->window_x = (float)rect.x;
        row->window_y = (float)rect.y;
        row->window_width = (float)rect.width;
        row->window_height = (float)rect.height;
    }
    return 0;
}

static void *gpu_make_surface(int id, const struct RectResult *bounds, float scale, int width, int height) {
    void *device = main_display_device();
    void *compositor = device ? compositor_for_device(device, 1) : NULL;
    if (!compositor)
        return NULL;
    void *space = *(void **)((char *)device + 0x120);
    if (!space)
        space = device_rgb();
    typedef void *(*Create)(void *, struct RectResult, unsigned, unsigned, unsigned, float, int, void *, unsigned);
    Create create = *(Create *)(*(char **)compositor + 0x70);
    struct RectResult rect = {bounds->x, bounds->y, width / scale, height / scale};
    char *surface = create(compositor, rect, 0, 0, 4, scale, 1, space, 1);
    if (!surface)
        return NULL;
    *(void **)(surface + 0x80) = device;
    *(int *)(surface + 0x88) = (*((uint8_t *)device + 0x64) & 0x10) ? display_accelerator(device) : 0;
    if (!surface[0x7a]) {
        note("window %d: surface incomplete\n", id);
        return NULL;
    }
    note("window %d: surface %dx%d for %gx%g at %g, IOSurface %p\n", id, width, height, bounds->width, bounds->height,
         scale, *(void **)(surface + 0x70));
    return surface;
}

static void gpu_compose_one(uint32_t id) {
    char *window = window_by_id(id);
    void *shape = window ? capture_shape(window, 1) : NULL;
    if (!shape)
        return;
    struct RectResult bounds;
    region_bounds(&bounds, shape);
    float scale = table->gpu_scale > 0 ? table->gpu_scale : 1;
    int width = (((int)(bounds.width * scale) + 255) & ~255) + (int)(id & 0xff);
    int height = (((int)(bounds.height * scale) + 255) & ~255) + (int)(0xa0 | ((id >> 8) & 0xf));
    if (region_is_empty(shape) || bounds.width < 1 || bounds.height < 1 || id >= 4096 || width > 8192 ||
        height > 8192) {
        region_free(shape);
        return;
    }
    struct GPUWindow *w = gpu_window(id);
    if (w->width != width || w->height != height) {
        // shortcut: the old surfaces leak, as their release isn't safe with a frame in flight. Upgrade with a real
        // session.
        w->surfaces[0] = w->surfaces[1] = NULL;
        w->width = width;
        w->height = height;
        w->whole = 2;
    }
    int which = w->next;
    w->next = !which;
    if (!w->surfaces[which])
        w->surfaces[which] = gpu_make_surface((int)id, &bounds, scale, width, height);
    if (w->surfaces[which]) {
        // As CaptureSurfaceMetal::Populate(CGXWindow*, region), with the destination the whole surface and the clip
        // only what changed. Its flag 0x10000000 clears all that a composite doesn't cover, so that goes for a clip,
        // and what that clip holds must be opaque, or it'd be blended over itself. Otherwise it's a whole composite.
        char *surface = w->surfaces[which];
        void *compositor = metal_compositor(*(int *)(surface + 0x88));
        void *clip = shape, *both = NULL;
        if (w->whole > 0)
            w->whole--;
        else if (w->pending && w->previous && (both = region_union(w->pending, w->previous)))
            clip = both;
        if (both) {
            void *solid = opaque_shape(window, 0);
            if (!solid || !region_contains(solid, both))
                clip = shape;
            if (solid)
                region_free(solid);
        }
        unsigned clears = clip == shape ? 0x10000000u : 0;
        char *backing = *(char **)(surface + 0xa8);
        void *color = *(void **)(surface + 0x60);
        typedef void *(*MakeDestination)(void *, void *, void *, unsigned, unsigned, float, struct RectResult);
        MakeDestination make = *(MakeDestination *)(*(char **)backing + 0x50);
        void *destination =
            compositor ? make(backing, *(void **)((char *)compositor + 0x10), color,
                              0x00c20000u | clears | (color ? 0x04000000u : 0), 0, *(float *)(surface + 0x68), bounds)
                       : NULL;
        double transform[6] = {1, 0, 0, 1, 0, 0};
        memcpy(&transform[4], window + 0x208, 16);
        if (destination) {
            composite_window(window, destination, *(void **)(surface + 0x80), clip, transform, 1, 1, 1, 1);
            cf_release(destination);
        }
        if (both)
            region_free(both);
        if (w->previous)
            region_free(w->previous);
        w->previous = w->pending;
        w->pending = NULL;
        table->gpu_composites++;
        for (unsigned i = 0; i < table->gpu_row_count; i++)
            if (table->gpu_rows[i].id == id) {
                struct SWSGPURow *row = &table->gpu_rows[i];
                row->x = (float)bounds.x;
                row->y = (float)bounds.y;
                row->width = (float)bounds.width;
                row->height = (float)bounds.height;
                row->frames++;
            }
    }
    region_free(shape);
}

// Called where WindowServer waits for its next request. Its update has finished, and nothing's holding Metal's locks.
static void gpu_compose_damaged(mach_msg_option_t option) {
    if (!table || gpu_busy || (option & MACH_SEND_MSG) || !pthread_equal(pthread_self(), main_thread))
        return;
    if (gpu_order) {
        // shortcut: rows aren't checked for tearing: the tool's look is a snapshot, and order changes rarely.
        table->gpu_row_count = gpu_order;
        table->gpu_row_generation++;
        gpu_order = 0;
        gpu_contributor_count = 0;
        if (gpu_in_front) {
            region_free(gpu_in_front);
            gpu_in_front = NULL;
        }
    }
    if (!gpu_damaged_count)
        return;
    gpu_busy = 1;
    uint64_t began = mach_absolute_time();
    void *pool = objc_autoreleasePoolPush();
    uint32_t ids[256];
    unsigned count = gpu_damaged_count;
    memcpy(ids, gpu_damaged, count * sizeof(*ids));
    gpu_damaged_count = 0;
    for (unsigned i = 0; i < count; i++)
        gpu_compose_one(ids[i]);
    objc_autoreleasePoolPop(pool);
    table->gpu_ticks += mach_absolute_time() - began;
    gpu_busy = 0;
}

static void gpu_install(void) {
    capture_shape = resolved[2];
    compositor_for_device = resolved[3];
    display_accelerator = resolved[4];
    window_rect = resolved[5];
    metal_compositor = resolved[7];
    composite_window = resolved[8];
    region_intersection = dlsym(RTLD_DEFAULT, "CGRegionCreateIntersectionWithRegion");
    opaque_shape = resolved[9];
    region_contains = dlsym(RTLD_DEFAULT, "CGRegionContainsRegion");
    region_union = dlsym(RTLD_DEFAULT, "CGRegionCreateUnionWithRegion");
    cf_release = dlsym(RTLD_DEFAULT, "CFRelease");
    main_display_device = dlsym(RTLD_DEFAULT, "CGXMainDisplayDevice");
    regions_intersect = dlsym(RTLD_DEFAULT, "CGRegionIntersectsRegion");
    region_is_empty = dlsym(RTLD_DEFAULT, "CGRegionIsEmpty");
    region_bounds = dlsym(RTLD_DEFAULT, "CGRegionGetBoundingBox");
    region_free = dlsym(RTLD_DEFAULT, "CGRegionRelease");
    device_rgb = dlsym(RTLD_DEFAULT, "CGColorSpaceCreateDeviceRGB");
    if (!region_contains || !region_intersection || !region_union || !cf_release || !main_display_device ||
        !regions_intersect || !region_is_empty || !region_bounds || !region_free || !device_rgb) {
        note("gpu: a library symbol is missing; off\n");
        return;
    }
    generate_layers_original = (char (*)(char *, char *))patch_entry(resolved[1], (const void *)generate_layers_hook);
    // Its entry differs from the others: pushes and a compare, 17 bytes, which can run anywhere.
    static const uint8_t contributors_entry[] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x53,
                                                 0x50, 0x80, 0xbe, 0x00, 0x02, 0x00, 0x00, 0x00};
    contributors_original = (void (*)(void *, void *))patch_entry_with(resolved[6], (const void *)contributors_hook,
                                                                       contributors_entry, sizeof(contributors_entry));
    note("gpu: hooked %p %p\n", (void *)generate_layers_original, (void *)contributors_original);
}
