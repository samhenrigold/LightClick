// Runs inside WindowServer, for the builds in `builds`: 13F34's CoreGraphics in full, 18G103's SkyLight for now only
// reporting what it finds. Loaded with DYLD_INSERT_LIBRARIES by
// probes/seamless-driver.py on a throwaway clone. It logs each window's backing and shadow to
// /var/tmp/seamless-ws-probe.log, and publishes the backing stores of windows seamless-guest asks for through
// seamless-ws-table.h, so reading a window no longer means a capture. It changes nothing WindowServer does.
//
// WindowServer's main loop isn't a run loop, so a timer can't reach its thread. It calls mach_msg from
// CGXRunOneServicesPass, between requests, and that's when its structures are safe to read. So this interposes
// mach_msg.
//
// Offsets are from a disassembly of 13F34: a window keeps its backing at 0x108 and a no-shadow flag at 0x9d, a backing
// its accelerated-surface pointer at 0x88. Local symbols aren't in the shared cache's symbol table, so they come from
// the CoreGraphics file on disk, and are refused if its UUID isn't the loaded image's.
#include "seamless-ws-table.h"
#include <fcntl.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

static int logfd = -1;
static pthread_t main_thread;
static void note(const char *format, ...) {
    char line[1024];
    va_list arguments;
    va_start(arguments, format);
    int n = vsnprintf(line, sizeof(line), format, arguments);
    va_end(arguments);
    if (logfd >= 0 && n > 0)
        write(logfd, line, (size_t)(n < (int)sizeof(line) ? n : (int)sizeof(line) - 1));
}

static void *(*window_by_id)(uint32_t);
static char (*window_has_shadow)(void *);
static char (*backing_is_accelerated)(void *);
static uint32_t (*backing_row_bytes)(void *, uint64_t);
static uint32_t (*backing_width)(void *), (*backing_height)(void *), (*backing_bits)(void *);
static char (*backing_has_alpha)(void *);
static void *(*backing_data)(void *, uint64_t, uint64_t);
static const char *const wanted[] = {
    "_CGXWindowByID",
    "_CGXWindowHasShadow",
    "_CGXBackingStoreIsAccelerated",
    "_CGXBackingStoreRowBytes",
    "_CGXBackingStoreWidth",
    "_CGXBackingStoreHeight",
    "_CGXBackingStoreBitsPerPixel",
    "_CGXBackingStoreHasAlpha",
    "_CGXBackingStoreDataIndexed",
    "_WSGetVisibleWindowArray",
    "_CGXWindowArraySubArray",
    "_CGXWindowArrayEnumeratorSubArray",
    "_CGXWindowArrayEnumeratorNext",
    "_WSWindowGetScreenRect",
    "_CGXGetShadowMarginForWindow",
    "_CGXGetCurrentSessionWindowData",
    "_CGXGLGetContext",
    "_redraw_window",
    "_gl_composite_layer",
    "_CGRegionCreateWithRect",
    "_CGRegionRelease",
};
static void *resolved[21];
static void *(*session_data)(void);
static void **(*server_gl)(void);
static void *placement_targets[3];
struct RectResult {
    double x, y, width, height;
};
struct WindowArray {
    void **items;
    long count;
};
static void *(*visible_array)(void);
static struct WindowArray (*array_sub)(void *);
static void *(*enumerator_init)(void *, struct WindowArray *);
static char *(*enumerator_next)(void *);
static struct RectResult (*window_screen_rect)(void *);
static void (*shadow_margin)(void *, int *, int *, int *, int *);

// What differs by build, one row per guest build this has been read for. See "Surviving several builds" in
// seamless-apps-design.md.
static const char *const wanted_mojave[] = {
    "_CGXWindowByID",
    "__ZL26generate_layers_for_windowP14CGXRedrawStateP9CGXWindow",
    "_window_create_capture_shape",
    "_WSGetCompositorForDisplayDevice",
    "_CGXGLDisplayDeviceAccelerator",
    "_WSWindowGetScreenRect",
    "__ZL37add_connection_to_update_contributorsP13CGXConnectionP20CGXSessionWindowData",
    "_WSGetCompositorMetal",
    "_WSCompositeWindowToDestination",
    "_CGXCopyScreenOpaqueShapeForWindow"};
static const struct Build {
    const char *release; // Darwin's, as a prefix.
    const char *suffix, *path; // The image with WindowServer's code, by its name when loaded and on disk.
    const char *const *wanted;
    size_t wanted_count;
    size_t window_backing;
    int full; // The tree, damage and backing stores are known. Otherwise this only reports what it finds, for reading.
    int flush_surface, flush_surface_inline; // Their message IDs. Each holds the window at its offset below.
    size_t flush_window, flush_inline_window;
} builds[] = {
    {"13.", "/CoreGraphics",
     "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/CoreGraphics.framework/Versions/A/"
     "CoreGraphics",
     wanted, sizeof(wanted) / sizeof(*wanted), 0x108, 1, 0x7268, 0x7267, 0x34, 0x20},
    {"18.", "/SkyLight", "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", wanted_mojave,
     sizeof(wanted_mojave) / sizeof(*wanted_mojave), 0xf0, 0, 0, 0, 0, 0},
};
static const struct Build *build;
static int samples_left = 12;

static const struct mach_header_64 *loaded_image(void) {
    size_t suffix = strlen(build->suffix);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        // Not just anything under the framework: its Resources hold more libraries.
        size_t length = name ? strlen(name) : 0;
        if (length > suffix && !strcmp(name + length - suffix, build->suffix))
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
    }
    return NULL;
}

static const uint8_t *image_uuid(const struct mach_header_64 *header) {
    const struct load_command *c = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, c = (const void *)((const char *)c + c->cmdsize))
        if (c->cmd == LC_UUID)
            return ((const struct uuid_command *)c)->uuid;
    return NULL;
}

static int resolve_symbols(void) {
    struct utsname name_of_system;
    uname(&name_of_system);
    for (size_t i = 0; !build && i < sizeof(builds) / sizeof(*builds); i++)
        if (!strncmp(name_of_system.release, builds[i].release, strlen(builds[i].release)))
            build = &builds[i];
    if (!build) {
        note("nothing is known of Darwin %s\n", name_of_system.release);
        return 0;
    }
    const struct mach_header_64 *loaded = loaded_image();
    if (!loaded) {
        note("no %s image\n", build->suffix);
        return 0;
    }
    int fd = open(build->path, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) {
        note("can't open CoreGraphics\n");
        return 0;
    }
    const uint8_t *file = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (file == MAP_FAILED)
        return 0;
    const struct mach_header_64 *header = (const void *)file;
    const struct fat_header *fat = (const void *)file;
    if (fat->magic == FAT_CIGAM) {
        const struct fat_arch *arch = (const void *)(fat + 1);
        for (uint32_t i = 0; i < OSSwapBigToHostInt32(fat->nfat_arch); i++)
            if (OSSwapBigToHostInt32((uint32_t)arch[i].cputype) == CPU_TYPE_X86_64)
                header = (const void *)(file + OSSwapBigToHostInt32(arch[i].offset));
    }
    if (header->magic != MH_MAGIC_64) {
        note("no x86_64 slice\n");
        return 0;
    }
    const uint8_t *file_uuid = image_uuid(header), *memory_uuid = image_uuid(loaded);
    if (!file_uuid || !memory_uuid || memcmp(file_uuid, memory_uuid, 16)) {
        // The guest's setup may have patched the file after the shared cache was built, so also accept a match of the
        // code itself, checked below for every symbol this uses.
        note("CoreGraphics on disk has a different UUID from the loaded image, comparing code instead\n");
    }
    const struct symtab_command *symtab = NULL;
    const struct load_command *c = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, c = (const void *)((const char *)c + c->cmdsize))
        if (c->cmd == LC_SYMTAB)
            symtab = (const void *)c;
    if (!symtab) {
        note("no symbol table\n");
        return 0;
    }
    const struct nlist_64 *symbols = (const void *)((const char *)header + symtab->symoff);
    const char *names = (const char *)header + symtab->stroff;
    int found = 0;
    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        if (symbols[i].n_type & N_STAB)
            continue;
        const char *name = names + symbols[i].n_un.n_strx;
        for (size_t w = 0; w < build->wanted_count; w++)
            if (!resolved[w] && !strcmp(name, build->wanted[w])) {
                // The file's __TEXT starts at 0, so a text symbol's value is its offset from the header. Text keeps
                // its layout in the shared cache.
                resolved[w] = (char *)loaded + symbols[i].n_value;
                // Only up to its first RIP-relative load for this one: the shared cache moves its data.
                size_t compared = !strcmp(name, "_CGXGLGetContext") ? 7 : 12;
                if (memcmp(resolved[w], (const char *)header + symbols[i].n_value, compared)) {
                    note("%s isn't the same code on disk and in memory; refusing\n", name);
                    return 0;
                }
                found++;
            }
    }
    munmap((void *)file, (size_t)st.st_size);
    if (found != (int)build->wanted_count) {
        note("found %d of the wanted symbols; not calling any\n", found);
        return 0;
    }
    window_by_id = resolved[0];
    note("build: Darwin %s, %s\n", name_of_system.release, build->full ? "known" : "reporting only");
    if (!build->full)
        return 1;
    samples_left = 2;
    window_has_shadow = resolved[1];
    backing_is_accelerated = resolved[2];
    backing_row_bytes = resolved[3];
    backing_width = resolved[4];
    backing_height = resolved[5];
    backing_bits = resolved[6];
    backing_has_alpha = resolved[7];
    backing_data = resolved[8];
    visible_array = resolved[9];
    array_sub = resolved[10];
    enumerator_init = resolved[11];
    enumerator_next = resolved[12];
    window_screen_rect = resolved[13];
    shadow_margin = resolved[14];
    session_data = resolved[15];
    server_gl = resolved[16];
    placement_targets[0] = resolved[17];
    placement_targets[1] = resolved[19];
    placement_targets[2] = resolved[20];
    note("symbols resolved: CGXWindowByID at %p\n", (void *)window_by_id);
    return 1;
}

static void dump(const void *data, size_t size) {
    const uint32_t *words = data;
    for (size_t i = 0; i < size / 4; i += 4)
        note("  +%03zx %08x %08x %08x %08x\n", i * 4, words[i], words[i + 1], words[i + 2], words[i + 3]);
}

// For a build not yet read in full: what its windows hold, for working out the rest offline.
static void sample_unknown_build(void) {
    unsigned count = 0, dumped = 0;
    static unsigned total_samples;
    note("-- sample %u at %ld\n", ++total_samples, (long)time(NULL));
    for (uint32_t id = 1; id < 8192; id++) {
        char *window = window_by_id(id);
        if (!window)
            continue;
        count++;
        const char *backing = *(const char **)(window + build->window_backing);
        note("window %u at %p backing %p", id, window, backing);
        if (backing)
            note(" words %u %u %u %u flags %x surface %p", *(const uint32_t *)(backing + 0),
                 *(const uint32_t *)(backing + 4), *(const uint32_t *)(backing + 8), *(const uint32_t *)(backing + 12),
                 *(const uint32_t *)(backing + 0x38), *(void *const *)(backing + 0x68));
        note("\n");
        // Only what's on the desktop by now: an app's window, not the ones from before login.
        if (backing && dumped < 6 && total_samples > 2 && *(const uint32_t *)(backing + 4) > 400 &&
            *(const uint32_t *)(backing + 12) > 200) {
            dumped++;
            const uint8_t *data = *(const uint8_t *const *)(backing + 0x48);
            uint32_t row = *(const uint32_t *)(backing + 8), height = *(const uint32_t *)(backing + 12);
            if (data && row)
                note(" data %p, size %x, middle %08x\n", data, *(const uint32_t *)(backing + 0x50),
                     *(const uint32_t *)(data + (size_t)row * (height / 2) + row / 2));
            note(" window bytes\n");
            dump(window, 0x200);
            note(" backing bytes\n");
            dump(backing, 0x100);
        }
    }
    note("%u windows\n", count);
}

static void sample(void) {
    unsigned count = 0, dumped = 0;
    static unsigned total_samples;
    note("-- sample %u at %ld\n", ++total_samples, (long)time(NULL));
    for (uint32_t id = 1; id < 8192; id++) {
        char *window = window_by_id(id);
        if (!window)
            continue;
        count++;
        void *backing = *(void **)(window + 0x108);
        int accelerated = backing ? backing_is_accelerated(backing) : 0;
        uint32_t width = backing ? backing_width(backing) : 0, height = backing ? backing_height(backing) : 0;
        uint32_t row = backing ? backing_row_bytes(backing, 1) : 0;
        const uint8_t *data = backing ? backing_data(backing, 1, 0) : NULL;
        note("window %u at %p shadow=%d noshadowflag=%d backing=%p %ux%u bits=%u alpha=%d rowbytes=%u accelerated=%d "
             "data=%p",
             id, window, window_has_shadow(window), window[0x9d], backing, width, height,
             backing ? backing_bits(backing) : 0, backing ? backing_has_alpha(backing) : 0, row, accelerated, data);
        // Is the memory really there, and is it the picture? Corners of a window are clear; its middle isn't.
        if (data && row && height && width) {
            const uint8_t *middle = data + (size_t)row * (height / 2) + (size_t)(width / 2) * 4;
            note(" middle=%02x%02x%02x%02x first=%02x%02x%02x%02x", middle[0], middle[1], middle[2], middle[3], data[0],
                 data[1], data[2], data[3]);
        }
        note("\n");
        // Raw structures, for working out the rest offline. A few per sample is plenty.
        if (backing && dumped < 3 && total_samples == 2) {
            dumped++;
            note(" window bytes\n");
            dump(window, 0x180);
            note(" backing bytes\n");
            dump(backing, 0x100);
        }
    }
    note("%u windows\n", count);
}

static struct SWSTable *table;

// Everything a window list says, read where it's kept. The window's read-only state at +0xe0 holds its ID, connection,
// level, alpha and surface flag, at the offsets CGSWindowROStateGet* read; the rect comes the way kCGWindowBounds'
// does. The shadow's parameters at +0x134 to +0x148 feed the key, as CGXGetShadowMarginForWindow reads them.
static void walk_windows(void) {
    // Before a session exists, the array this asks for is at address 0x20.
    if (!session_data())
        return;
    uint64_t enumerator[8] = {0};
    struct WindowArray sub = array_sub(visible_array());
    if (!sub.items)
        return;
    enumerator_init(enumerator, &sub);
    table->tree_generation++;
    uint32_t count = 0;
    for (char *window; count < SWS_TREE && (window = enumerator_next(enumerator));) {
        const uint8_t *state = *(const uint8_t **)(window + 0xe0);
        if (!state)
            continue;
        struct SWSTreeEntry *t = &table->tree[count++];
        t->id = *(const uint32_t *)state;
        t->connection = *(const uint32_t *)(state + 4);
        t->level = *(const int32_t *)(state + 0x10);
        t->alpha = *(const float *)(state + 0x18);
        t->has_surfaces = state[0xb];
        struct RectResult rect = window_screen_rect(window);
        t->x = rect.x;
        t->y = rect.y;
        t->width = rect.width;
        t->height = rect.height;
        t->margin = 0;
        uint32_t key = 2166136261u;
        if (window_has_shadow(window)) {
            int side[4] = {0, 0, 0, 0};
            shadow_margin(window, &side[0], &side[1], &side[2], &side[3]);
            for (int i = 0; i < 4; i++) {
                uint32_t size = (uint32_t)abs(side[i]);
                t->margin = size > t->margin ? size : t->margin;
            }
            for (int i = 0x134; i < 0x148; i++)
                key = (key ^ (uint8_t)window[i]) * 16777619u;
        }
        t->shadow_key = key;
    }
    table->tree_count = count;
    table->tree_generation++;
}

static int tree_in_gl;
static uint64_t marks, unmarked;

// For a host that draws each window on its own GPU (PassthroughOpenGL/seamless-gpu-replay-host.c), which window each
// layer of a composite belongs to. redraw_window builds a window's layers, all allocated with new[], and
// gl_composite_layer later draws them, so a layer is known by its address. Before each one's draws goes that window's
// ID and bounds, as glPassThrough tokens in WindowServer's own GL stream: a no-op in GL, and in order with its draws.
// Whole numbers below 2^24, which a float holds exactly. Only with /var/tmp/seamless-ws-gl-tree present. Their entries
// are patched, as both are local symbols.
#define LAYER_SLOTS 8192
static struct {
    const void *layer;
    char *window;
} layer_owner[LAYER_SLOTS];
static char *building_window, *marked_window;
static int layers_used;

static void forget_layers(void) {
    memset(layer_owner, 0, sizeof(layer_owner));
    layers_used = 0;
}
void *_Znam(unsigned long);
static void *hook_new_array(unsigned long size) {
    // What libc++'s does, without calling it: on 10.14 a call from here comes back here, as dyld coalesces the weak
    // name.
    void *memory = malloc(size ? size : 1);
    if (!memory)
        abort();
    if (building_window && pthread_equal(pthread_self(), main_thread)) {
        size_t slot = ((uintptr_t)memory >> 4) % LAYER_SLOTS;
        for (int tries = 0; tries < 16; tries++, slot = (slot + 1) % LAYER_SLOTS)
            if (!layer_owner[slot].layer) {
                layer_owner[slot].layer = memory;
                layer_owner[slot].window = building_window;
                break;
            }
    }
    return memory;
}
__attribute__((used)) void seamless_redraw_window(void *state, char *window) {
    (void)state;
    if (layers_used)
        forget_layers();
    marked_window = (char *)-1; // Nothing marked yet, so the first layer is told, even with no owner.
    building_window = window;
}
__attribute__((used)) void seamless_composite_layer(const void *layer) {
    building_window = 0;
    layers_used = 1;
    char *owner = NULL;
    size_t slot = ((uintptr_t)layer >> 4) % LAYER_SLOTS;
    for (int tries = 0; tries < 16; tries++, slot = (slot + 1) % LAYER_SLOTS)
        if (layer_owner[slot].layer == layer) {
            owner = layer_owner[slot].window;
            break;
        }
    owner ? marks++ : unmarked++;
    // CoreGraphics calls GL through its own context record, as CGLMacro does: the renderer first, then the dispatch
    // table, whose slots are the wire's opcodes. glDeleteTextures, slot 59, at +0x1e0 in _CGXGLDeleteTexture shows it.
    void **gl = server_gl();
    if (!gl || owner == marked_window)
        return;
    if (!owner) {
        static unsigned shown;
        if (shown++ < 12)
            note("layer %p has no known window\n", layer);
    }
    marked_window = owner;
    float tokens[9] = {11184809.0f};
    const uint8_t *state = owner ? *(const uint8_t **)(owner + 0xe0) : NULL;
    if (state) {
        struct RectResult rect = window_screen_rect(owner);
        int side[4] = {0, 0, 0, 0};
        uint32_t margin = 0;
        if (window_has_shadow(owner)) {
            shadow_margin(owner, &side[0], &side[1], &side[2], &side[3]);
            for (int i = 0; i < 4; i++)
                margin = (uint32_t)abs(side[i]) > margin ? (uint32_t)abs(side[i]) : margin;
        }
        int32_t level = *(const int32_t *)(state + 0x10);
        tokens[1] = (float)*(const uint32_t *)state;
        tokens[2] = level < 0 ? 0 : (float)(level > 100000 ? 100001 : level + 1);
        tokens[3] = (float)(16384 + (int)rect.x);
        tokens[4] = (float)(16384 + (int)rect.y);
        tokens[5] = (float)(int)rect.width;
        tokens[6] = (float)(int)rect.height;
        tokens[7] = (float)margin;
        tokens[8] = *(const float *)(owner + 0x100) * 16;
    }
    void (*pass_through)(void *, float) = (void (*)(void *, float))gl[1 + 190];
    for (int i = 0; i < 9; i++)
        pass_through(gl[0], tokens[i]);
    static unsigned told;
    if (told++ % 3000 == 0)
        note("layers marked %llu, unknown %llu\n", marks, unmarked);
}
void *seamless_layer_continue;
__asm__(".text\n"
        "_seamless_layer_entry:\n"
        "  pushq %rdi\n  pushq %rsi\n  subq $8, %rsp\n  callq _seamless_composite_layer\n"
        "  addq $8, %rsp\n  popq %rsi\n  popq %rdi\n  jmpq *_seamless_layer_continue(%rip)\n");
extern char seamless_layer_entry[];

// Sends a function's entry to `entry`, and returns where to continue it. The bytes moved have to run anywhere, and be
// at least the 14 of the jump. Refuses anything but the entry it was told of.
static void *patch_entry_with(uint8_t *function, const void *entry, const uint8_t *prologue, size_t size) {
    if (memcmp(function, prologue, size)) {
        note("refusing to patch %p: its entry isn't the expected one\n", (void *)function);
        return NULL;
    }
    uint8_t *island = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (island == MAP_FAILED)
        return NULL;
    const uint8_t jump[] = {0xff, 0x25, 0, 0, 0, 0};
    memcpy(island, function, size);
    memcpy(island + size, jump, sizeof(jump));
    void *back = function + size;
    memcpy(island + size + sizeof(jump), &back, 8);
    vm_address_t page = (vm_address_t)function & ~(vm_address_t)4095;
    kern_return_t result = vm_protect(mach_task_self(), page, 8192, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (result) {
        note("vm_protect failed: %d\n", result);
        return NULL;
    }
    memcpy(function, jump, sizeof(jump));
    memcpy(function + 6, &entry, 8);
    vm_protect(mach_task_self(), page, 8192, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    return island;
}
// Most entries here: pushes and a stack adjustment.
static void *patch_entry(uint8_t *function, const void *entry) {
    static const uint8_t pushes[] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56,
                                     0x41, 0x55, 0x41, 0x54, 0x53, 0x48, 0x81, 0xec};
    uint8_t prologue[20];
    memcpy(prologue, pushes, sizeof(pushes));
    memcpy(prologue + sizeof(pushes), function + sizeof(pushes), 4);
    return patch_entry_with(function, entry, prologue, sizeof(prologue));
}

// Copies the rows of each wanted window's backing that changed, for windows whose flush seed moved. Runs at most once
// per 8 ms of WindowServer's main thread, between requests, where its structures are consistent.
static void publish(void) {
    static uint64_t next;
    uint64_t now = mach_absolute_time();
    if (now < next)
        return;
    next = now + 8000000ull * table->ticks_denom / table->ticks_numer;
    table->passes++;
    static uint64_t next_walk;
    if (now >= next_walk) {
        next_walk = now + 33000000ull * table->ticks_denom / table->ticks_numer;
        walk_windows();
    }
    for (int i = 0; i < SWS_SLOTS; i++) {
        struct SWSEntry *e = &table->slots[i];
        if (!e->id)
            continue;
        char *window = window_by_id(e->id);
        void *backing = window ? *(void **)(window + 0x108) : NULL;
        e->present = backing != NULL;
        if (!backing)
            continue;
        e->accelerated = backing_is_accelerated(backing) != 0;
        // Plane 1 of these two accessors only answers for a backing with alpha; plane 0 answers for all, including an
        // opaque window, whose alpha byte is meaningless.
        uint32_t width = backing_width(backing), height = backing_height(backing), row = backing_row_bytes(backing, 0);
        const uint8_t *data = backing_data(backing, 0, 0);
        e->opaque = !backing_has_alpha(backing);
        if (e->accelerated || !data || !width || !height || row < width * 4 || backing_bits(backing) != 32) {
            // Says why once per window, since each of these falls back to a capture.
            static uint32_t told[64];
            if (told[i] != e->id) {
                told[i] = e->id;
                note("window %u not published: accelerated=%d data=%p/%p %ux%u rowbytes=%u bits=%u flags=%02x\n", e->id,
                     e->accelerated, data, backing_data(backing, 1, 1), width, height, row, backing_bits(backing),
                     ((const uint8_t *)backing)[0x41]);
            }
            continue;
        }
        uint64_t size = (uint64_t)width * height * 4;
        if (e->width != width || e->height != height) {
            // shortcut: wraps over older windows' rows, which then read wrong until they change. Fine for a demo's few
            // windows in 512 MB; a real one frees and reuses.
            if (size > SWS_ARENA)
                continue;
            if (table->arena_used + size > SWS_ARENA)
                table->arena_used = 0;
            e->offset = table->arena_used;
            table->arena_used += size;
            e->width = width;
            e->height = height;
            e->sequence++;
        }
        // Its flush seed goes up when the app flushes, so nothing else needs looking at. +0xe0 is the shared state
        // CGSWindowROStateGetFlushSeed reads at +0x1c; a run showed it moving with the pixels, and nothing else near it
        // moving. The occasional full compare is for anything that reaches the backing without a flush.
        const uint32_t *state = *(const uint32_t **)(window + 0xe0);
        uint32_t seed = state ? state[7] : 0;
        if (state && seed == e->seed && e->sequence && now < e->next_compare) {
            e->seed_skips++;
            continue;
        }
        e->seed = seed;
        e->next_compare = now + 1000000000ull * table->ticks_denom / table->ticks_numer;
        uint8_t *dest = table->arena + e->offset;
        int changed = 0;
        for (uint32_t y = 0; y < height; y++) {
            uint8_t *to = dest + (size_t)y * width * 4;
            const uint8_t *from = data + (size_t)y * row;
            if (memcmp(to, from, width * 4)) {
                memcpy(to, from, width * 4);
                changed = 1;
                e->copy_rows++;
            }
        }
        if (changed)
            e->sequence++;
    }
    table->ticks_spent += mach_absolute_time() - now;
}

// redraw_window(state, window), which CGXUpdateDisplay calls for each window. The state already has what placement
// needs: it offsets everything it draws by +0x70 and +0x74, clips to the region at +0x18, and skips shadows with +0x6b.
// All of that is for the whole update, so this sets them for one window and puts them back.
static const uint8_t redraw_prologue[] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x41, 0x55,
                                          0x41, 0x54, 0x53, 0x48, 0x81, 0xec, 0x28, 0x02, 0x00, 0x00};
static char (*redraw_original)(char *, char *);
static void *(*region_with_rect)(struct RectResult);
static void (*region_release_fn)(void *);

// When the host needs all of a window: once its bounds have held for a second, since one that opened by an effect
// wasn't drawn whole at its final size. With gpu_mode 2, every time, which times a full redraw, and draws a covered
// window.
static int whole_window_due(uint32_t id, char *window) {
    if (table->gpu_mode == 2)
        return 1;
    static struct {
        uint32_t id;
        int done;
        uint64_t stable_since;
        struct RectResult rect;
    } seen[256];
    unsigned i = 0;
    while (i < 256 && seen[i].id && seen[i].id != id)
        i++;
    if (i == 256)
        return 0;
    uint64_t now = mach_absolute_time();
    struct RectResult rect = window_screen_rect(window);
    if (seen[i].id != id || memcmp(&rect, &seen[i].rect, sizeof(rect))) {
        seen[i].id = id;
        seen[i].rect = rect;
        seen[i].stable_since = now;
        seen[i].done = 0;
        return 0;
    }
    if (seen[i].done || now - seen[i].stable_since < 1000000000ull * table->ticks_denom / table->ticks_numer)
        return 0;
    seen[i].done = 1;
    return 1;
}

static char redraw_placed(char *state, char *window) {
    if (tree_in_gl)
        seamless_redraw_window(state, window);
    const uint8_t *ro = window ? *(const uint8_t **)(window + 0xe0) : NULL;
    uint32_t id = ro ? *(const uint32_t *)ro : 0;
    const struct SWSPlacement *placement = NULL;
    for (int i = 0; id && table && i < SWS_PLACEMENTS; i++)
        if (table->placements[i].id == id)
            placement = (const struct SWSPlacement *)&table->placements[i];
    if (!placement && tree_in_gl && id && whole_window_due(id, window)) {
        void *saved_clip = *(void **)(state + 0x18);
        struct RectResult everywhere = {0, 0, 16384, 16384};
        void *whole = region_with_rect(everywhere);
        *(void **)(state + 0x18) = whole;
        char drew = redraw_original(state, window);
        *(void **)(state + 0x18) = saved_clip;
        region_release_fn(whole);
        table->gpu_composites++;
        return drew;
    }
    if (!placement)
        return redraw_original(state, window);
    int saved_x = *(int *)(state + 0x70), saved_y = *(int *)(state + 0x74);
    void *saved_region = *(void **)(state + 0x18);
    uint8_t saved_shadow = *(uint8_t *)(state + 0x6b);
    struct RectResult everywhere = {0, 0, 16384, 16384};
    void *region = region_with_rect(everywhere);
    *(int *)(state + 0x70) = saved_x + placement->dx;
    *(int *)(state + 0x74) = saved_y + placement->dy;
    *(void **)(state + 0x18) = region;
    *(uint8_t *)(state + 0x6b) = 1;
    char result = redraw_original(state, window);
    *(int *)(state + 0x70) = saved_x;
    *(int *)(state + 0x74) = saved_y;
    *(void **)(state + 0x18) = saved_region;
    *(uint8_t *)(state + 0x6b) = saved_shadow;
    region_release_fn(region);
    table->placed_redraws++;
    return result;
}

// Replaces the start of redraw_window with a jump here, keeping its first instructions in a page of their own to
// continue from.
static void hook_redraw(void *target) {
    if (memcmp(target, redraw_prologue, sizeof(redraw_prologue))) {
        note("redraw_window doesn't start as expected; no placement\n");
        return;
    }
    uint8_t *page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (page == MAP_FAILED)
        return;
    static const uint8_t jump[] = {0xff, 0x25, 0, 0, 0, 0}; // jmpq *0(%rip)
    memcpy(page, redraw_prologue, sizeof(redraw_prologue));
    memcpy(page + sizeof(redraw_prologue), jump, sizeof(jump));
    uint64_t back = (uint64_t)target + sizeof(redraw_prologue), to = (uint64_t)redraw_placed;
    memcpy(page + sizeof(redraw_prologue) + sizeof(jump), &back, 8);
    redraw_original = (char (*)(char *, char *))page;
    vm_address_t start = (vm_address_t)target & ~(vm_address_t)4095;
    kern_return_t kr = vm_protect(mach_task_self(), start, 8192, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr) {
        note("can't write redraw_window: %d\n", kr);
        return;
    }
    memcpy(target, jump, sizeof(jump));
    memcpy((uint8_t *)target + sizeof(jump), &to, 8);
    vm_protect(mach_task_self(), start, 8192, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    note("redraw_window hooked\n");
}

#include "seamless-ws-mojave.h"

static time_t next_sample;
static int ready, in_sample, reached;

static void between_requests(void) {
    if (!pthread_equal(pthread_self(), main_thread) || in_sample)
        return;
    time_t now = time(NULL);
    in_sample = 1;
    if (!reached) {
        reached = 1;
        note("mach_msg reached on the main thread\n");
    }
    if (ready && samples_left > 0 && now >= next_sample) {
        // 60 s in: past login, when there are windows worth reading.
        samples_left--;
        next_sample = now + 15;
        if (build->full)
            sample();
        else
            sample_unknown_build();
    }
    if (ready && table && build->full) {
        publish();
    }
    in_sample = 0;
}

// A surface flush is a request this thread receives, with no state in WindowServer that says so afterward. On 13F34, as
// a disassembly of _CGSFlushSurface and _CGSFlushSurfaceInline shows: their IDs, and the window's place in each.
static void note_request(const mach_msg_header_t *msg, mach_msg_option_t option, mach_msg_return_t result) {
    if (!table || result != MACH_MSG_SUCCESS || !(option & MACH_RCV_MSG) || !pthread_equal(pthread_self(), main_thread))
        return;
    if (!build || !build->flush_surface)
        return;
    size_t place = msg->msgh_id == build->flush_surface          ? build->flush_window
                   : msg->msgh_id == build->flush_surface_inline ? build->flush_inline_window
                                                                 : 0;
    if (place && msg->msgh_size >= place + 4)
        table->surface_flushes[*(const uint32_t *)((const char *)msg + place) % SWS_FLUSHES]++;
}

static mach_msg_return_t hook_msg(mach_msg_header_t *msg, mach_msg_option_t option, mach_msg_size_t send,
                                  mach_msg_size_t receive, mach_port_t port, mach_msg_timeout_t timeout,
                                  mach_port_t notify) {
    between_requests();
    gpu_compose_damaged(option);
    mach_msg_return_t result = mach_msg(msg, option, send, receive, port, timeout, notify);
    note_request(msg, option, result);
    return result;
}
static mach_msg_return_t hook_overwrite(mach_msg_header_t *msg, mach_msg_option_t option, mach_msg_size_t send,
                                        mach_msg_size_t receive, mach_port_t port, mach_msg_timeout_t timeout,
                                        mach_port_t notify, mach_msg_header_t *rcv, mach_msg_size_t limit) {
    between_requests();
    gpu_compose_damaged(option);
    mach_msg_return_t result = mach_msg_overwrite(msg, option, send, receive, port, timeout, notify, rcv, limit);
    note_request(rcv ? rcv : msg, option, result);
    return result;
}
__attribute__((used)) static struct {
    const void *replacement, *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)hook_msg, (const void *)mach_msg},
    {(const void *)hook_overwrite, (const void *)mach_msg_overwrite},
    {(const void *)hook_new_array, (const void *)_Znam},
};

// Started before main, while still root: WindowServer drops privileges later, and this keeps the descriptor.
__attribute__((constructor)) static void start(void) {
    logfd = open("/var/tmp/seamless-ws-probe.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    note("== loaded into pid %d, %s\n", getpid(), getprogname());
    main_thread = pthread_self();
    next_sample = time(NULL) + 60;
    // Only WindowServer: launchd's environment can reach other programs on this clone.
    if (!strcmp(getprogname(), "WindowServer")) {
        ready = resolve_symbols();
        tree_in_gl = !access("/var/tmp/seamless-ws-gl-tree", F_OK);
        note("tree in GL: %d\n", tree_in_gl);
        if (ready && tree_in_gl && build->full) {
            seamless_layer_continue = patch_entry(resolved[18], seamless_layer_entry);
            note("patched: %p\n", seamless_layer_continue);
        }
        unlink(SWS_PATH);
        int fd = open(SWS_PATH, O_RDWR | O_CREAT, 0666);
        if (fd >= 0 && !fchmod(fd, 0666) && !ftruncate(fd, sizeof(struct SWSTable))) {
            void *mapped = mmap(NULL, sizeof(struct SWSTable), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (mapped != MAP_FAILED) {
                table = mapped;
                mach_timebase_info_data_t timebase;
                mach_timebase_info(&timebase);
                table->ticks_numer = timebase.numer;
                table->ticks_denom = timebase.denom;
                table->magic = SWS_MAGIC;
            }
        }
        if (fd >= 0)
            close(fd);
        note("table %s\n", table ? "mapped" : "NOT mapped");
        if (ready && table && !build->full)
            gpu_install();
        // Only for trying placement: it rewrites a function WindowServer's update calls, and isn't finished.
        if (ready && table && build->full && (tree_in_gl || !access("/var/tmp/seamless-ws-placement", F_OK))) {
            region_with_rect = (void *(*)(struct RectResult))placement_targets[1];
            region_release_fn = (void (*)(void *))placement_targets[2];
            hook_redraw(placement_targets[0]);
        }
    }
}
