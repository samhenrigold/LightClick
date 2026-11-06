// Runs inside WindowServer, on 10.9 only (13F34's CoreGraphics). Loaded with DYLD_INSERT_LIBRARIES by
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
#include <time.h>
#include <unistd.h>

static int logfd = -1;
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
static const char *const wanted[] = {"_CGXWindowByID",
                                     "_CGXWindowHasShadow",
                                     "_CGXBackingStoreIsAccelerated",
                                     "_CGXBackingStoreRowBytes",
                                     "_CGXBackingStoreWidth",
                                     "_CGXBackingStoreHeight",
                                     "_CGXBackingStoreBitsPerPixel",
                                     "_CGXBackingStoreHasAlpha",
                                     "_CGXBackingStoreDataIndexed"};
static void *resolved[9];

static const struct mach_header_64 *loaded_coregraphics(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        // Not just anything under the framework: its Resources hold more libraries.
        size_t length = name ? strlen(name) : 0;
        if (length > 13 && !strcmp(name + length - 13, "/CoreGraphics"))
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
    const struct mach_header_64 *loaded = loaded_coregraphics();
    if (!loaded) {
        note("no CoreGraphics image\n");
        return 0;
    }
    const char *path = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/CoreGraphics.framework/"
                       "Versions/A/CoreGraphics";
    int fd = open(path, O_RDONLY);
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
        for (size_t w = 0; w < sizeof(wanted) / sizeof(*wanted); w++)
            if (!resolved[w] && !strcmp(name, wanted[w])) {
                // The file's __TEXT starts at 0, so a text symbol's value is its offset from the header. Text keeps
                // its layout in the shared cache.
                resolved[w] = (char *)loaded + symbols[i].n_value;
                if (memcmp(resolved[w], (const char *)header + symbols[i].n_value, 16)) {
                    note("%s isn't the same code on disk and in memory; refusing\n", name);
                    return 0;
                }
                found++;
            }
    }
    munmap((void *)file, (size_t)st.st_size);
    if (found != (int)(sizeof(wanted) / sizeof(*wanted))) {
        note("found %d of the wanted symbols; not calling any\n", found);
        return 0;
    }
    window_by_id = resolved[0];
    window_has_shadow = resolved[1];
    backing_is_accelerated = resolved[2];
    backing_row_bytes = resolved[3];
    backing_width = resolved[4];
    backing_height = resolved[5];
    backing_bits = resolved[6];
    backing_has_alpha = resolved[7];
    backing_data = resolved[8];
    note("symbols resolved: CGXWindowByID at %p\n", (void *)window_by_id);
    return 1;
}

static void dump(const void *data, size_t size) {
    const uint32_t *words = data;
    for (size_t i = 0; i < size / 4; i += 4)
        note("  +%03zx %08x %08x %08x %08x\n", i * 4, words[i], words[i + 1], words[i + 2], words[i + 3]);
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

// Compares each wanted window's backing with the last copy row by row, and copies only what changed. Runs at most once
// per 8 ms of WindowServer's main thread, between requests, where its structures are consistent. This assumes
// nothing about what changed, so it costs a read of the window; a flush-seed check would avoid that.
static void publish(void) {
    static uint64_t next;
    uint64_t now = mach_absolute_time();
    if (now < next)
        return;
    next = now + 8000000ull * table->ticks_denom / table->ticks_numer;
    table->passes++;
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
        uint32_t width = backing_width(backing), height = backing_height(backing), row = backing_row_bytes(backing, 1);
        const uint8_t *data = backing_data(backing, 1, 0);
        if (e->accelerated || !data || !width || !height || row < width * 4 || backing_bits(backing) != 32)
            continue;
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

static pthread_t main_thread;
static time_t next_sample;
static int ready, samples_left = 2, in_sample, reached;

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
        sample();
    }
    if (ready && table)
        publish();
    in_sample = 0;
}

static mach_msg_return_t hook_msg(mach_msg_header_t *msg, mach_msg_option_t option, mach_msg_size_t send,
                                  mach_msg_size_t receive, mach_port_t port, mach_msg_timeout_t timeout,
                                  mach_port_t notify) {
    between_requests();
    return mach_msg(msg, option, send, receive, port, timeout, notify);
}
static mach_msg_return_t hook_overwrite(mach_msg_header_t *msg, mach_msg_option_t option, mach_msg_size_t send,
                                        mach_msg_size_t receive, mach_port_t port, mach_msg_timeout_t timeout,
                                        mach_port_t notify, mach_msg_header_t *rcv, mach_msg_size_t limit) {
    between_requests();
    return mach_msg_overwrite(msg, option, send, receive, port, timeout, notify, rcv, limit);
}
__attribute__((used)) static struct {
    const void *replacement, *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)hook_msg, (const void *)mach_msg},
    {(const void *)hook_overwrite, (const void *)mach_msg_overwrite},
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
    }
}
