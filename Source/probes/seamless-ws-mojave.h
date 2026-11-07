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
// to catch up on, and a new or moved window is all drawn. So is what's in front of it, each time, as the update's
// region leaves that out: a covered window that changes costs a composite of the covered part each frame.
//
// A surface's size says which window it is, as there's no other channel to the host. The low 8 bits of its width are
// the ID's, and of its height 0xA0 and the ID's top 4 bits. Past the window it's transparent. After a composite, a
// clear of one point in a small surface with 0xB0 in place of 0xA0 follows on the same queue, and tells the
// host's helper that the last is finished. A window with materials has a third, 0xC0, of its whole composite without
// its shadow, when drawn whole: there, any alpha at all is the window's real shape, with its material's corners, a
// popover's arrow and the like, as a material comes out clear but for an alpha of 1. The host masks its materials with
// it.

void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *);

static char (*generate_layers_original)(char *, char *);
static void *(*capture_shape)(void *, int);
static void *(*compositor_for_device)(void *, int);
static int (*display_accelerator)(void *);
static void *(*metal_compositor)(int);
static int (*composite_window)(void *, void *, void *, void *, void *, int, int, int, int);
static void *(*region_intersection)(void *, void *);
static void *(*region_union)(void *, void *);
static void (*cf_release)(void *);
static void *(*main_display_device)(void);
static char (*regions_intersect)(void *, void *);
static char (*region_is_empty)(void *);
static void (*region_bounds)(struct RectResult *, void *);
static void (*region_free)(void *);
static void *(*device_rgb)(void);
static long (*array_count)(const void *);
static const void *(*array_value)(const void *, long);
static void *(*backdrop_screen_shape)(void *);
static void (*enumerator_make)(void *, void *);
static void *(*region_from_rect)(struct RectResult);
static char (*enumerator_next_bounds)(void *, int *, int *, int *, int *);

struct GPUWindow {
    uint32_t id;
    int width, height; // Of the surface.
    void *surfaces[2];
    void *marker, *shape;
    void *retired[2]; // What a resize left, kept for a few frames, as what's in flight may use them.
    int retired_for;
    int next;
    void *pending, *previous; // What's changed since the last frame, and what changed in it. Null means all of it.
    void *covered; // What's in front of it, which the update says nothing of.
    uint64_t settles_at; // Ticks.
    int whole; // Everything's to be drawn, on both surfaces, on the next two.
    uint32_t frames;
    float content[4]; // What the host's surface holds, in points.
    struct GPUWindow *more;
};
static struct GPUWindow *gpu_windows;
static uint32_t gpu_damaged[256];
static unsigned gpu_damaged_count;
static int gpu_busy, gpu_marking;
static struct {
    void *surface;
    uint32_t slot;
} identify_queue[256];
static unsigned identify_count;
static const void *(*cf_retain)(const void *);
static void (*contributors_original)(void *, void *);
static struct RectResult (*window_rect)(void *);
static void *gpu_contributors[64];
static unsigned gpu_contributor_count;
static unsigned gpu_order;
static void *gpu_front; // The windows before this one in the update.
static void *gpu_front_shown; // The same, leaving out those nobody will show.
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

// A composite clears what it's given to clear, in the same points as a clip: for a capture, all of it. Here that's only
// the clip, so what's drawn isn't blended over itself and the rest stays.
static void (*clear_original)(void *, void *, float);
static void *gpu_clear_only;
static void clear_hook(void *metal, void *region, float alpha) {
    clear_original(metal, gpu_clear_only ? gpu_clear_only : region, alpha);
}

static char generate_layers_hook(char *state, char *window) {
    if (gpu_marking) // No layers, so all it draws is its clear, which is all that's wanted of it.
        return 0;
    static int was_on;
    if (table && !table->gpu_mode)
        was_on = 0;
    if (!table || !table->gpu_mode || gpu_busy) // Inside a composite it does what it always does.
        return generate_layers_original(state, window);
    table->gpu_generate_calls++;
    uint32_t id = *(const uint32_t *)(window + 0x10);
    struct RectResult rect = window_rect(window);
    // What's in front of this window, by its real shape and without shadows, including one nobody will show, as the
    // Dock: the update's region leaves that out, so it's drawn each time.
    void *own = capture_shape(window, 0), *in_front = NULL;
    if (own && gpu_front) {
        in_front = region_intersection(gpu_front, own);
        if (in_front && region_is_empty(in_front)) {
            region_free(in_front);
            in_front = NULL;
        }
    }
    if (own) {
        void *grown = gpu_front ? region_union(gpu_front, own) : NULL;
        if (grown) {
            region_free(gpu_front);
            region_free(own);
            gpu_front = grown;
        } else if (!gpu_front)
            gpu_front = own;
        else
            region_free(own);
    }
    {
        struct GPUWindow *w = gpu_window(id);
        if (w->covered)
            region_free(w->covered);
        w->covered = in_front;
    }
    for (uint32_t i = 0; i < table->gpu_skip_count && i < 64; i++)
        if (table->gpu_skip[i] == id)
            return 0;
    // shortcut: a partial composite of a window with a shown window in front lost a CA surface, a scroller's, with its
    // alpha 0, and all of it being drawn doesn't. Why isn't known. The Dock doesn't count, or a window over it would
    // always be whole. Windows going to host layers don't come here.
    void *shown_shape = capture_shape(window, 0);
    int under_shown = 0;
    if (shown_shape) {
        void *both = gpu_front_shown ? region_intersection(gpu_front_shown, shown_shape) : NULL;
        if (both) {
            under_shown = !region_is_empty(both);
            region_free(both);
        }
        void *grown = gpu_front_shown ? region_union(gpu_front_shown, shown_shape) : NULL;
        if (grown) {
            region_free(gpu_front_shown);
            region_free(shown_shape);
            gpu_front_shown = grown;
        } else if (!gpu_front_shown)
            gpu_front_shown = shown_shape;
        else
            region_free(shown_shape);
    }
    // shortcut: a row per window seen, by search. A real session keeps these in the window's own record.
    static struct {
        uint32_t id;
        struct RectResult rect;
    } known[SWS_TREE];
    // Each time the mode goes on, all of every window, as nothing else would ever draw what doesn't change.
    if (!was_on) {
        was_on = 1;
        memset(known, 0, sizeof(known));
    }
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
    void *touched = damage && shape ? region_intersection(damage, shape) : NULL;
    if (touched && region_is_empty(touched)) {
        region_free(touched);
        touched = NULL;
    }
    if (shape)
        region_free(shape);
    // One that's just opened was mid-effect, with its shadow missing and parts of it not drawn, when it was drawn
    // whole. So it's drawn whole again a second later, whatever else is happening.
    uint64_t now = mach_absolute_time(), second = 1000000000ull * table->ticks_denom / table->ticks_numer;
    struct GPUWindow *known_window = gpu_window(id);
    int settling = known_window->settles_at && now >= known_window->settles_at;
    if (settling)
        known_window->settles_at = 0;
    if (fresh)
        known_window->settles_at = now + second;
    if (fresh || asked || touched || settling) {
        struct GPUWindow *w = gpu_window(id);
        if (settling)
            w->whole = 2;
        if (under_shown && !w->whole)
            w->whole = 1;
        if (fresh || !touched)
            w->whole = 2; // An app drawing where the display won't show it says nothing of where.
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
        struct GPUWindow *w = gpu_window(id);
        row->frames = w->frames;
        row->x = w->content[0];
        row->y = w->content[1];
        row->width = w->content[2];
        row->height = w->content[3];
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
    // For telling whether this reaches the host.
    void (*set_value)(void *, const void *, const void *) = dlsym(RTLD_DEFAULT, "IOSurfaceSetValue");
    const void *(*make_string)(void *, const char *, uint32_t) = dlsym(RTLD_DEFAULT, "CFStringCreateWithCString");
    if (set_value && make_string)
        set_value(*(void **)(surface + 0x70), make_string(NULL, "seamless-window", 0x08000100),
                  make_string(NULL, "seamless-window-value", 0x08000100));
    return surface;
}

// What's behind a window's material, in the order it's drawn: a composite of the window alone leaves those parts clear,
// with only what's over them, as a backdrop samples what's already in the destination. So the host can put its own
// there.
static void gpu_publish_backdrops(uint32_t id, char *window) {
    table->gpu_backdrop_generation++;
    uint32_t kept = 0, count = table->gpu_backdrop_count;
    for (uint32_t i = 0; i < count; i++)
        if (table->gpu_backdrops[i].id != id)
            table->gpu_backdrops[kept++] = table->gpu_backdrops[i];
    // All of them as the app made them, and not those in use at +0x3c0: an inactive window's aren't there, and its
    // sidebar is still clear.
    const void *backdrops = *(void **)(window + 0x3b0);
    long total = backdrops ? array_count(backdrops) : 0;
    for (long b = 0; b < total; b++) {
        char *backdrop = (char *)array_value(backdrops, b);
        void *shape = backdrop_screen_shape(backdrop);
        if (!shape)
            continue;
        uint64_t enumerator[64];
        int x, y, right, bottom;
        enumerator_make(enumerator, shape);
        while (kept < SWS_BACKDROPS && enumerator_next_bounds(enumerator, &x, &y, &right, &bottom)) {
            struct SWSBackdrop *row = (struct SWSBackdrop *)&table->gpu_backdrops[kept++];
            row->id = id;
            row->order = (uint32_t)b;
            row->material = *(uint32_t *)(backdrop + 0x20);
            row->active = *(uint8_t *)(backdrop + 0xc8);
            row->x = (float)x;
            row->y = (float)y;
            row->width = (float)(right - x);
            row->height = (float)(bottom - y);
            memcpy((void *)row->color, backdrop + 0x80, sizeof(row->color));
            row->saturation = *(float *)(backdrop + 0xb0);
            row->blend = *(uint32_t *)(backdrop + 0x24);
        }
    }
    table->gpu_backdrop_count = kept;
    table->gpu_backdrop_generation++;
}

static void gpu_composite(char *window, char *surface, const struct RectResult *bounds, void *clip, int no_shadow) {
    void *compositor = metal_compositor(*(int *)(surface + 0x88));
    gpu_clear_only = clip;
    char *backing = *(char **)(surface + 0xa8);
    void *color = *(void **)(surface + 0x60);
    typedef void *(*MakeDestination)(void *, void *, void *, unsigned, unsigned, float, struct RectResult);
    MakeDestination make = *(MakeDestination *)(*(char **)backing + 0x50);
    void *destination = compositor
                            ? make(backing, *(void **)((char *)compositor + 0x10), color,
                                   0x10c20000u | (color ? 0x04000000u : 0), 0, *(float *)(surface + 0x68), *bounds)
                            : NULL;
    double transform[6] = {1, 0, 0, 1, 0, 0};
    memcpy(&transform[4], window + 0x208, 16);
    if (destination) {
        // The first of the last four leaves out the shadow.
        composite_window(window, destination, *(void **)(surface + 0x80), clip, transform, no_shadow, 1, 1, 1);
        cf_release(destination);
    }
    gpu_clear_only = NULL;
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
        // Another resize in the meantime: those go now, and they're older than anything in flight by then.
        for (int i = 0; i < 2; i++) {
            if (w->retired[i]) {
                typedef void (*Release)(void *);
                (*(Release *)(*(char **)w->retired[i] + 0x18))(w->retired[i]);
            }
            w->retired[i] = w->surfaces[i];
            w->surfaces[i] = NULL;
        }
        // shortcut: the shape's surface leaks on a resize, at one for each new size, until they're counted with the
        // others.
        w->shape = NULL;
        w->retired_for = 8;
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
        // only what changed.
        void *clip = shape, *both = NULL;
        if (table->gpu_mode == 2) // For telling what drawing only part of a window costs and breaks.
            w->whole = 2;
        // A shadow changes when a window's activation does, which only its size says.
        if (memcmp(w->content, (float[]){(float)bounds.x, (float)bounds.y, (float)bounds.width, (float)bounds.height},
                   sizeof(w->content)))
            w->whole = 2;
        if (w->whole > 0)
            w->whole--;
        else if (w->pending && w->previous && (both = region_union(w->pending, w->previous))) {
            void *more = w->covered ? region_union(both, w->covered) : NULL;
            if (more) {
                region_free(both);
                both = more;
            }
            clip = both;
        }
        if (clip == shape)
            table->gpu_whole_composites++;
        gpu_composite(window, w->surfaces[which], &bounds, clip, table->gpu_no_shadow != 0);
        void *backdrops = *(void **)(window + 0x3b0);
        if (clip == shape && backdrops && array_count(backdrops) > 0) {
            if (!w->shape)
                w->shape = gpu_make_surface((int)id, &bounds, scale, width,
                                            (height & ~0xff) + (int)(0xc0 | ((id >> 8) & 0xf)));
            if (w->shape)
                gpu_composite(window, w->shape, &bounds, clip, 1);
        }
        if (both)
            region_free(both);
        if (w->previous)
            region_free(w->previous);
        w->previous = w->pending;
        w->pending = NULL;
        table->gpu_composites++;
        if (!w->marker)
            w->marker = gpu_make_surface((int)id, &bounds, scale, 512 + (int)(id & 0xff),
                                         512 + (int)(0xb0 | ((id >> 8) & 0xf)));
        struct RectResult point = {bounds.x, bounds.y, 1, 1};
        void *one = region_from_rect(point);
        if (w->marker && one && !table->gpu_no_marker) {
            gpu_marking = 1;
            gpu_composite(window, w->marker, &bounds, one, 1);
            gpu_marking = 0;
            region_free(one);
        }
        // Their release is as _XHWCaptureWindowListToIOSurface's.
        if (w->retired_for > 0 && !--w->retired_for)
            for (int i = 0; i < 2; i++)
                if (w->retired[i]) {
                    typedef void (*Release)(void *);
                    (*(Release *)(*(char **)w->retired[i] + 0x18))(w->retired[i]);
                    w->retired[i] = NULL;
                }
        gpu_publish_backdrops(id, window);
        w->frames++;
        w->content[0] = (float)bounds.x;
        w->content[1] = (float)bounds.y;
        w->content[2] = (float)bounds.width;
        w->content[3] = (float)bounds.height;
        for (unsigned i = 0; i < table->gpu_row_count; i++)
            if (table->gpu_rows[i].id == id) {
                struct SWSGPURow *row = &table->gpu_rows[i];
                row->x = w->content[0];
                row->y = w->content[1];
                row->width = w->content[2];
                row->height = w->content[3];
                row->frames = w->frames;
            }
    }
    region_free(shape);
}

// Called when an update has finished, so nothing's holding Metal's locks. Runs on WindowServer's own thread, as it's
// the update's caller, and needs no interposing, so it works in a WindowServer already running.
static void gpu_compose_damaged(void) {
    if (!table || gpu_busy)
        return;
    if (gpu_order) {
        // shortcut: rows aren't checked for tearing: the tool's look is a snapshot, and order changes rarely.
        table->gpu_row_count = gpu_order;
        table->gpu_row_generation++;
        gpu_order = 0;
        gpu_contributor_count = 0;
        if (gpu_front)
            region_free(gpu_front);
        gpu_front = NULL;
        if (gpu_front_shown)
            region_free(gpu_front_shown);
        gpu_front_shown = NULL;
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

static void (*update_original)(void *, double);
static void identify_surface(void *surface, uint32_t slot);
static void update_hook(void *context, double time) {
    update_original(context, time);
    for (unsigned i = 0; i < identify_count; i++) {
        identify_surface(identify_queue[i].surface, identify_queue[i].slot);
        cf_release(identify_queue[i].surface);
    }
    identify_count = 0;
    gpu_compose_damaged();
}

// A census of what real windows' layers are, for sizing a translator to host layers: while gpu_census counts down, each
// surface's update prints its tree into the log. CARenderUpdateCopyRegion is called once per surface's update, once its
// contexts are added, and SkyLight reaches it through a pointer that can be changed at any moment.
static void *(*copy_region_original)(void *);
static void (*print_trees)(void *);
static int census_printing;
static void (*set_message_function)(void (*)(const char *, va_list, void *), void *);
static void census_line(const char *format, va_list arguments, void *info) {
    (void)info;
    vdprintf(logfd, format, arguments);
}
static void *copy_region_hook(void *update) {
    if (table && table->gpu_census > 0 && print_trees && set_message_function && logfd >= 0) {
        table->gpu_census--;
        note("== census\n");
        set_message_function(census_line, NULL);
        census_printing = 1;
        print_trees(update);
        census_printing = 0;
        set_message_function(NULL, NULL);
    }
    return copy_region_original(update);
}
// In a census, the pixels of each layer's contents go to the table's arena, once each, and the tree says which by a
// line before it. Through IOSurfaces: an image makes one when asked, as CA does for the GPU, and a surface is one.
enum {
    image_show_at = 0xdcdc4,
    x_log_at = 0xe9bad,
    gradient_show_at = 0x20154a,
    surface_show_at = 0x1d95e0,
    image_retain_iosurface_at = 0xddb0c,
    copy_region_stub = 0x2696f8 // In SkyLight.
};
static void *(*image_retain_iosurface)(void *);
static int (*surface_lock)(void *, uint32_t, void *), (*surface_unlock)(void *, uint32_t, void *);
static size_t (*surface_width)(void *), (*surface_height)(void *), (*surface_row)(void *);
static void *(*surface_base)(void *);
static void (*census_log)(int, const char *, ...);
static const void *census_seen[4096];
static uint32_t census_seen_seed[4096];

static void census_blob(const void *object, uint32_t seed, void *surface) {
    uint32_t found = 4096;
    for (uint32_t i = 0; i < table->gpu_blob_count && i < 4096; i++)
        if (census_seen[i] == object && census_seen_seed[i] == seed)
            found = i;
    if (found == 4096 && table->gpu_blob_count < 4096 && surface && !surface_lock(surface, 1, NULL)) {
        size_t width = surface_width(surface), height = surface_height(surface);
        size_t row = surface_row(surface);
        if (row < width * 4)
            row = width * 4;
        uint64_t size = (uint64_t)height * row;
        if (size && table->arena_used + size <= SWS_ARENA) {
            found = table->gpu_blob_count;
            memcpy(table->arena + table->arena_used, surface_base(surface), size);
            table->gpu_blobs[found] =
                (struct SWSBlob){(uint32_t)width, (uint32_t)height, (uint32_t)row, table->arena_used};
            uint64_t sum = 0;
            const uint8_t *pixels = table->arena + table->arena_used;
            for (size_t y = 0; y < height; y++)
                for (size_t x = 0; x < width; x++)
                    sum += pixels[y * row + x * 4 + 1];
            census_log(0, "(blob-sum %u %llu)", found, sum);
            table->arena_used += size;
            census_seen[found] = object;
            census_seen_seed[found] = seed;
            table->gpu_blob_count = found + 1;
        }
        surface_unlock(surface, 1, NULL);
        // Not here, with CA's locks held and an update underway: binding it from inside this hung the guest.
        if (found < 4096 && identify_count < 256) {
            cf_retain(surface);
            identify_queue[identify_count].surface = surface;
            identify_queue[identify_count++].slot = found + 1;
        }
    }
    if (found == 4096 && surface)
        census_log(0, "(no-blob)");
    if (found < 4096)
        census_log(0, "(blob %u)", found); // Into the stream the tree is being printed to.
}
// For telling whether the host can have a guest's surface: a copy of a pixel of it to a surface whose size says which,
// on the compositor's own queue, as anything that opens a Metal device here can hang, this being WindowServer.
typedef struct {
    unsigned long x, y, z;
} MetalTriple;
static void identify_surface(void *surface, uint32_t slot) {
    void *(*send)(void *, void *) = dlsym(RTLD_DEFAULT, "objc_msgSend");
    void *(*sel_getUid)(const char *) = dlsym(RTLD_DEFAULT, "sel_getUid");
    void *(*objc_getClass)(const char *) = dlsym(RTLD_DEFAULT, "objc_getClass");
    void *(*make_surface)(const void *) = dlsym(RTLD_DEFAULT, "IOSurfaceCreate");
    void *(*dictionary)(const void *, const void **, const void **, long, const void *, const void *) =
        dlsym(RTLD_DEFAULT, "CFDictionaryCreate");
    void *(*number)(const void *, long, const void *) = dlsym(RTLD_DEFAULT, "CFNumberCreate");
    const void *key_callbacks = dlsym(RTLD_DEFAULT, "kCFTypeDictionaryKeyCallBacks");
    const void *value_callbacks = dlsym(RTLD_DEFAULT, "kCFTypeDictionaryValueCallBacks");
    const void **key_names[] = {dlsym(RTLD_DEFAULT, "kIOSurfaceWidth"), dlsym(RTLD_DEFAULT, "kIOSurfaceHeight"),
                                dlsym(RTLD_DEFAULT, "kIOSurfaceBytesPerElement"),
                                dlsym(RTLD_DEFAULT, "kIOSurfacePixelFormat")};
    void *display = main_display_device();
    int accelerator = display && (*((uint8_t *)display + 0x64) & 0x10) ? display_accelerator(display) : 0;
    char *compositor = metal_compositor(accelerator);
    char *context = compositor ? *(char **)(compositor + 0x10) : NULL;
    void *queue = context ? *(void **)(context + 0x88) : NULL;
    static unsigned told;
    if (told++ < 6)
        note("identify %u: queue %p\n", slot, queue);
    if (!queue || !send || !make_surface || !dictionary || !number)
        return;
    void *pool = objc_autoreleasePoolPush();
    void *device = send(queue, sel_getUid("device"));
    typedef void *(*DescriptorMake)(void *, void *, unsigned long, unsigned long, unsigned long, char);
    typedef void *(*TextureMake)(void *, void *, void *, void *, unsigned long);
    void *descriptors = objc_getClass("MTLTextureDescriptor");
    void *make = sel_getUid("texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
    void *wrap = sel_getUid("newTextureWithDescriptor:iosurface:plane:");
    void *descriptor =
        ((DescriptorMake)send)(descriptors, make, 80, surface_width(surface), surface_height(surface), 0);
    void *texture = ((TextureMake)send)(device, wrap, descriptor, surface, 0);
    int width = 512 + (int)(slot & 0xff), height = 512 + (int)(0xd0 | ((slot >> 8) & 0xf));
    int32_t values[] = {width, height, 4, 0x42475241};
    const void *keys[4], *numbers[4];
    for (int i = 0; i < 4; i++) {
        keys[i] = *key_names[i];
        numbers[i] = number(NULL, 3 /* kCFNumberSInt32Type */, &values[i]);
    }
    void *target_surface = make_surface(dictionary(NULL, keys, numbers, 4, key_callbacks, value_callbacks));
    void *target_descriptor =
        ((DescriptorMake)send)(descriptors, make, 80, (unsigned long)width, (unsigned long)height, 0);
    void *target = target_surface ? ((TextureMake)send)(device, wrap, target_descriptor, target_surface, 0) : NULL;
    if (told <= 6)
        note("identify %u: texture %p target %p\n", slot, texture, target);
    if (texture && target) {
        void *commands = send(queue, sel_getUid("commandBuffer"));
        void *encoder = send(commands, sel_getUid("blitCommandEncoder"));
        MetalTriple zero = {0, 0, 0}, one = {1, 1, 1};
        ((void (*)(void *, void *, void *, unsigned long, unsigned long, MetalTriple, MetalTriple, void *,
                   unsigned long, unsigned long, MetalTriple))send)(
            encoder,
            sel_getUid("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:"
                       "destinationLevel:destinationOrigin:"),
            texture, 0, 0, zero, one, target, 0, 0, zero);
        send(encoder, sel_getUid("endEncoding"));
        send(commands, sel_getUid("commit"));
    }
    objc_autoreleasePoolPop(pool);
}

static void (*image_show_original)(void *, unsigned, unsigned);
static void image_show_hook(void *image, unsigned a, unsigned b) {
    if (census_printing) {
        void *surface = image_retain_iosurface(image);
        census_blob(image, *(uint32_t *)((char *)image + 0x1c), surface);
        if (surface)
            cf_release(surface);
    }
    image_show_original(image, a, b);
}
static void (*surface_show_original)(void *, unsigned, unsigned);
static void surface_show_hook(void *object, unsigned a, unsigned b) {
    if (census_printing) {
        census_blob(object, *(uint32_t *)((char *)object + 0x1c), *(void **)((char *)object + 0x80));
    }
    surface_show_original(object, a, b);
}

// A gradient's show leaves out its colors. The layer keeps its gradient in place at +0x10, with its count at +0x10 in
// that, its locations at +0x18 and its colors at +0x20, as Gradient::set_colors and GradientLayer::set_property read.
static void (*gradient_show_original)(void *, unsigned, unsigned);
static void gradient_show_hook(char *layer, unsigned a, unsigned b) {
    const char *gradient = census_printing ? *(const char **)(layer + 0x10) : NULL;
    size_t count = gradient ? *(const size_t *)(gradient + 0x10) : 0;
    const float *colors = gradient ? *(const float *const *)(gradient + 0x20) : NULL;
    const float *locations = gradient ? *(const float *const *)(gradient + 0x18) : NULL;
    if (colors && count && count <= 64) {
        census_log(0, "(gradient-colors");
        for (size_t i = 0; i < count; i++)
            census_log(0, " %g %g %g %g %g", locations ? locations[i] : (count > 1 ? (double)i / (count - 1) : 0),
                       colors[i * 4], colors[i * 4 + 1], colors[i * 4 + 2], colors[i * 4 + 3]);
        census_log(0, ")");
    }
    gradient_show_original(layer, a, b);
}

static void gpu_census_install(void) {
    print_trees = dlsym(RTLD_DEFAULT, "CARenderUpdatePrintTrees");
    copy_region_original = dlsym(RTLD_DEFAULT, "CARenderUpdateCopyRegion");
    set_message_function = dlsym(RTLD_DEFAULT, "CASetMessageFunction");
    surface_lock = dlsym(RTLD_DEFAULT, "IOSurfaceLock");
    surface_unlock = dlsym(RTLD_DEFAULT, "IOSurfaceUnlock");
    surface_width = dlsym(RTLD_DEFAULT, "IOSurfaceGetWidth");
    surface_height = dlsym(RTLD_DEFAULT, "IOSurfaceGetHeight");
    surface_row = dlsym(RTLD_DEFAULT, "IOSurfaceGetBytesPerRow");
    surface_base = dlsym(RTLD_DEFAULT, "IOSurfaceGetBaseAddress");
    const uint8_t *stub = (const uint8_t *)loaded_image() + copy_region_stub;
    const uint8_t *quartz = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        size_t length = name ? strlen(name) : 0;
        if (length > 11 && !strcmp(name + length - 11, "/QuartzCore"))
            quartz = (const uint8_t *)_dyld_get_image_header(i);
    }
    static const uint8_t image_entry[] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56,
                                          0x53, 0x48, 0x81, 0xec, 0xd8, 0x00, 0x00, 0x00};
    static const uint8_t surface_entry[] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x41, 0x55,
                                            0x41, 0x54, 0x53, 0x48, 0x81, 0xec, 0x38, 0x01, 0x00, 0x00};
    if (!print_trees || !copy_region_original || !set_message_function || !surface_lock || !surface_unlock ||
        !surface_width || !surface_height || !surface_row || !surface_base || !quartz || stub[0] != 0xff ||
        stub[1] != 0x25) {
        note("no census\n");
        return;
    }
    image_retain_iosurface = (void *(*)(void *))(quartz + image_retain_iosurface_at);
    census_log = (void (*)(int, const char *, ...))(quartz + x_log_at);
    struct Patch patches[] = {{(uint8_t *)quartz + image_show_at, image_entry, sizeof(image_entry), sizeof(image_entry),
                               (const void *)image_show_hook, (void **)&image_show_original},
                              {(uint8_t *)quartz + surface_show_at, surface_entry, sizeof(surface_entry),
                               sizeof(surface_entry), (const void *)surface_show_hook,
                               (void **)&surface_show_original}};
    static const uint8_t gradient_entry[] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56,
                                             0x41, 0x54, 0x53, 0x48, 0x83, 0xec, 0x40};
    struct Patch gradient = {(uint8_t *)quartz + gradient_show_at,
                             gradient_entry,
                             sizeof(gradient_entry),
                             sizeof(gradient_entry),
                             (const void *)gradient_show_hook,
                             (void **)&gradient_show_original};
    if (!patches_apply(patches, 2) || !patches_apply(&gradient, 1)) {
        note("no census of contents\n");
        return;
    }
    int32_t offset;
    memcpy(&offset, stub + 2, 4);
    void *const *pointer = (void *const *)(stub + 6 + offset);
    __atomic_store_n((void **)pointer, (void *)copy_region_hook, __ATOMIC_SEQ_CST);
}

static const uint8_t contributors_entry[] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x53,
                                             0x50, 0x80, 0xbe, 0x00, 0x02, 0x00, 0x00, 0x00};
static const uint8_t clear_entry[] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41,
                                      0x56, 0x41, 0x55, 0x41, 0x54, 0x53, 0x50};
static const uint8_t update_entry[] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56,
                                       0x41, 0x54, 0x53, 0x48, 0x83, 0xec, 0x30};
#define GPU_PATCHES 4
static struct Patch gpu_patches[GPU_PATCHES];

// Everything needed, found and checked, with nothing changed.
static int gpu_prepare(void) {
    capture_shape = resolved[2];
    compositor_for_device = resolved[3];
    display_accelerator = resolved[4];
    window_rect = resolved[5];
    metal_compositor = resolved[7];
    composite_window = resolved[8];
    region_intersection = dlsym(RTLD_DEFAULT, "CGRegionCreateIntersectionWithRegion");
    region_union = dlsym(RTLD_DEFAULT, "CGRegionCreateUnionWithRegion");
    cf_release = dlsym(RTLD_DEFAULT, "CFRelease");
    cf_retain = dlsym(RTLD_DEFAULT, "CFRetain");
    main_display_device = dlsym(RTLD_DEFAULT, "CGXMainDisplayDevice");
    regions_intersect = dlsym(RTLD_DEFAULT, "CGRegionIntersectsRegion");
    region_is_empty = dlsym(RTLD_DEFAULT, "CGRegionIsEmpty");
    region_bounds = dlsym(RTLD_DEFAULT, "CGRegionGetBoundingBox");
    region_free = dlsym(RTLD_DEFAULT, "CGRegionRelease");
    device_rgb = dlsym(RTLD_DEFAULT, "CGColorSpaceCreateDeviceRGB");
    array_count = dlsym(RTLD_DEFAULT, "CFArrayGetCount");
    array_value = dlsym(RTLD_DEFAULT, "CFArrayGetValueAtIndex");
    backdrop_screen_shape = resolved[12];
    enumerator_make = dlsym(RTLD_DEFAULT, "CGRegionForwardEnumeratorMake");
    region_from_rect = dlsym(RTLD_DEFAULT, "CGRegionCreateWithRect");
    enumerator_next_bounds = dlsym(RTLD_DEFAULT, "CGRegionForwardEnumeratorGetNextBounds");
    if (!region_from_rect || !array_count || !array_value || !enumerator_make || !enumerator_next_bounds ||
        !region_intersection || !region_union || !cf_release || !main_display_device || !regions_intersect ||
        !region_is_empty || !region_bounds || !region_free || !device_rgb) {
        note("gpu: a library symbol is missing; off\n");
        return 0;
    }
    const struct Patch patches[GPU_PATCHES] = {
        PUSHES_PATCH(resolved[1], generate_layers_hook, generate_layers_original),
        {resolved[10], clear_entry, sizeof(clear_entry), sizeof(clear_entry), (const void *)clear_hook,
         (void **)&clear_original},
        {resolved[11], update_entry, sizeof(update_entry), sizeof(update_entry), (const void *)update_hook,
         (void **)&update_original},
        // Pushes and a compare, 17 bytes, which can run anywhere.
        {resolved[6], contributors_entry, sizeof(contributors_entry), sizeof(contributors_entry),
         (const void *)contributors_hook, (void **)&contributors_original}};
    memcpy(gpu_patches, patches, sizeof(patches));
    return 1;
}
