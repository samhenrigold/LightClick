/* Local Rosetta bring-up experiment; not an upstream contribution.
 * macOS 26 Intel PVG's 4K fragmented mappings cannot always be imported by
 * Apple Silicon Metal. Preserve zero-copy when possible; stage rejected maps.
 * Standalone diagnostic build uses -DAPPLE_GFX_SHADOW_STANDALONE. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <IOSurface/IOSurface.h>
#include <os/lock.h>
#include <stdint.h>
#include <string.h>
#include "apple-gfx-oop-timing.h"
#include "apple-gfx-paging-encoder.h"
#include "apple-gfx-shadow-ram.h"

/* Opt-in shadow cost counters (VIM_PVG_TIMING; the launch plan strips PVG_*).
 * Off, each site costs one predicted branch. Stderr only, at most once per 5s. */
static bool shadow_timing;
static os_unfair_lock shadow_timing_lock = OS_UNFAIR_LOCK_INIT;
static AppleGFXOOPTiming import_time, exec_encode_time, exec_complete_time, scatter_gpu_time;
static uint64_t count_exec, count_barrier, count_zero_copy, bytes_zero_copy, count_shadow,
    bytes_shadow, count_runs, bytes_small_runs, bytes_upload, bytes_baseline, bytes_scatter,
    count_table, count_windows, count_gather, count_slab_blit, count_table_scatter;
static void shadow_time(AppleGFXOOPTiming *metric, const char *name, uint64_t start)
{
    os_unfair_lock_lock(&shadow_timing_lock);
    apple_gfx_oop_timing(metric, name, start);
    os_unfair_lock_unlock(&shadow_timing_lock);
}
#define SHADOW_ADD(counter, value) \
    (shadow_timing ? (void)__atomic_fetch_add(&(counter), (value), __ATOMIC_RELAXED) : (void)0)
static void shadow_report(void)
{
    static uint64_t reported;
    uint64_t now = apple_gfx_oop_now(), last = __atomic_load_n(&reported, __ATOMIC_RELAXED);
    if (now - last < 5000000000ULL ||
        !__atomic_compare_exchange_n(&reported, &last, now, false, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) return;
    fprintf(stderr, "PVG shadow exec=%llu barriers=%llu zero_copy=%llu/%lluB shadow=%llu/%lluB "
        "runs=%llu small_run_bytes=%llu upload=%llu baseline=%llu scatter=%llu "
        "table=%llu windows=%llu gather=%llu slab_blit=%llu table_scatter=%llu\n",
        count_exec, count_barrier, count_zero_copy, bytes_zero_copy, count_shadow, bytes_shadow,
        count_runs, bytes_small_runs, bytes_upload, bytes_baseline, bytes_scatter,
        count_table, count_windows, count_gather, count_slab_blit, count_table_scatter);
}

/* Local Intel-on-Apple-GPU compatibility experiment. Catalina's incremental
 * scanout passes can request DontCare while relying on untouched pixels.
 * Preserve IOSurface color attachments only during guest command decoding;
 * never alter explicit clears, depth/stencil, or host presentation passes. */
static __thread unsigned guest_render_depth;
static IMP original_render_encoder;
static IMP original_library_data;
extern dispatch_data_t PVGHostRepairLibrary(dispatch_data_t) __attribute__((weak_import));
static unsigned library_capture_sequence;
static id capture_library_data(id self, SEL cmd, dispatch_data_t data, NSError **error)
{
    /* Opt-in, bounded diagnostic capture before the compiler sees the bytes.
     * Not enabled by normal launch and never changes the submitted library. */
    unsigned sequence = __atomic_fetch_add(&library_capture_sequence, 1, __ATOMIC_RELAXED);
    if (getenv("PVG_CAPTURE_LIBRARIES") && sequence < 256) {
        const void *bytes = NULL;
        size_t size = 0;
        dispatch_data_t mapped = dispatch_data_create_map(data, &bytes, &size);
        if (mapped) {
            NSString *path = [NSString stringWithFormat:@"%s/library-%d-%03u.metallib",
                getenv("PVG_CAPTURE_LIBRARIES"), getpid(), sequence];
            BOOL saved = [[NSData dataWithBytesNoCopy:(void *)bytes length:size
                                         freeWhenDone:NO] writeToFile:path atomically:YES];
            fprintf(stderr, "PVG library capture %u bytes=%zu saved=%d\n", sequence, size, saved);
            dispatch_release(mapped);
        }
    }
    dispatch_data_t repaired = PVGHostRepairLibrary ? PVGHostRepairLibrary(data) : NULL;
    id library = ((id (*)(id, SEL, dispatch_data_t, NSError **))original_library_data)(self, cmd, repaired ?: data, error);
    if (repaired) dispatch_release(repaired);
    return library;
}
/* Research, off unless VIM_SEAMLESS_PVG_DIR is set: what the guest renders to, as the host sees it. Each second, a line
 * per render target in <dir>/passes.txt, and how many frames the display asked to show. */
static const char *seamless_pvg_dir;
static uint64_t seamless_frames;
void apple_gfx_seamless_frame(void) { __atomic_fetch_add(&seamless_frames, 1, __ATOMIC_RELAXED); }
static void seamless_note_pass(MTLRenderPassDescriptor *pass)
{
    static NSMutableDictionary *counts;
    static uint64_t next, last_frames;
    static FILE *file;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    id<MTLTexture> t = pass.colorAttachments[0].texture;
    if (!t) return;
    os_unfair_lock_lock(&lock);
    if (!counts) {
        counts = [NSMutableDictionary new];
        file = fopen([NSString stringWithFormat:@"%s/passes.txt", seamless_pvg_dir].UTF8String, "w");
    }
    NSString *key = [NSString stringWithFormat:@"%lux%lu fmt=%lu storage=%lu surface=%u load=%lu store=%lu label=%@ cls=%s",
        (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, (unsigned long)t.storageMode,
        t.iosurface ? IOSurfaceGetID(t.iosurface) : 0, (unsigned long)pass.colorAttachments[0].loadAction,
        (unsigned long)pass.colorAttachments[0].storeAction, t.label, object_getClassName(t)];
    counts[key] = @([counts[key] unsignedLongLongValue] + 1);
    uint64_t now = apple_gfx_oop_now();
    if (now >= next && file) {
        uint64_t frames = __atomic_load_n(&seamless_frames, __ATOMIC_RELAXED);
        fprintf(file, "-- %llu ms frames=%llu (+%llu)\n", now / 1000000, frames, frames - last_frames);
        last_frames = frames;
        for (NSString *name in counts) fprintf(file, "%s n=%llu\n", name.UTF8String, [counts[name] unsignedLongLongValue]);
        fflush(file);
        [counts removeAllObjects];
        next = now + 1000000000ull;
    }
    os_unfair_lock_unlock(&lock);
}
static id preserving_render_encoder(id self, SEL cmd, MTLRenderPassDescriptor *pass)
{
    MTLRenderPassDescriptor *adjusted = nil;
    if (seamless_pvg_dir && guest_render_depth) seamless_note_pass(pass);
    if (guest_render_depth) {
        for (NSUInteger i = 0; i < 8; i++) {
            MTLRenderPassColorAttachmentDescriptor *a = pass.colorAttachments[i];
            if (a.loadAction == MTLLoadActionDontCare && a.texture.iosurface &&
                a.texture.storageMode != MTLStorageModeMemoryless) {
                if (!adjusted) adjusted = [pass copy];
                adjusted.colorAttachments[i].loadAction = MTLLoadActionLoad;
            }
        }
    }
    id result = ((id (*)(id, SEL, id))original_render_encoder)(
        self, cmd, adjusted ?: pass);
    [adjusted release];
    return result;
}

/* Table entries are sorted by RAM page and grouped by slab window. */
typedef struct {
    uint32_t shadow, ram;
} AppleGFXTableEntry;
struct AppleGFXShadowWindow {
    id<MTLBuffer> slab; /* Owned by shadow_slabs, which never releases one. */
    uint32_t first, count;
};
@interface AppleGFXLegacyShadow : NSObject {
@public
    void *guest;
    NSUInteger length;
    NSArray *pages;
    id<MTLBuffer> baseline;
    /* Set instead of pages when guest RAM is reached through slab windows. */
    id<MTLBuffer> table;
    struct AppleGFXShadowWindow *windows;
    uint32_t window_count;
}
@end
@implementation AppleGFXLegacyShadow
- (void)dealloc { [baseline release]; [pages release]; [table release]; free(windows); [super dealloc]; }
@end

static char shadow_key;
static char order_key;
static char scatter_key, gather_key, table_scatter_key;
@interface AppleGFXShadowCompletion : NSObject {
@public
    BOOL donorDone, gpuDone;
    uint64_t started;
    uint32_t result;
    NSError *failure;
    void (^callback)(uint32_t, NSError *);
}
- (void)finishDonor:(BOOL)donor result:(uint32_t)value error:(NSError *)error;
@end
@implementation AppleGFXShadowCompletion
- (void)finishDonor:(BOOL)donor result:(uint32_t)value error:(NSError *)error
{
    void (^ready)(uint32_t, NSError *) = nil;
    @synchronized (self) {
        if (donor) { donorDone = YES; result = value; } else gpuDone = YES;
        if (error && !failure) failure = [error retain];
        if (donorDone && gpuDone) { ready = callback; callback = nil; }
    }
    if (ready) {
        if (started) shadow_time(&exec_complete_time, "shadow-exec-to-complete", started);
        ready(result, failure);
        [ready release];
    }
}
- (void)dealloc { [callback release]; [failure release]; [super dealloc]; }
@end
@interface AppleGFXShadowOrder : NSObject {
@public
    id<MTLEvent> event;
    uint64_t value;
    uint64_t completedValue;
}
@end
@implementation AppleGFXShadowOrder
- (void)dealloc { [event release]; [super dealloc]; }
@end
static IMP original_needs_prepare, original_exec;
static IMP original_backing_prepare, original_backing_sync;
static IMP original_private_prepare, original_private_sync;
static Ivar shared_buffer;
static id send_id(id obj, const char *name)
{
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName(name));
}

/* Only the shared-buffer scatter reads a baseline, and only that resource's
 * ensurePhysical creates its buffer. Others would just double memory and blits. */
static __thread bool shadow_wants_baseline;
static IMP original_shared_physical;
static void shared_physical(id self, SEL cmd)
{
    shadow_wants_baseline = true;
    @try {
        ((void (*)(id, SEL))original_shared_physical)(self, cmd);
    } @finally {
        shadow_wants_baseline = false;
    }
}

/* A no-copy view of guest RAM, so a shadow needs one table rather than one
 * Metal import per run (probes/host-shadow-gather.m has the numbers).
 *
 * First GPU use makes a view's whole range resident [measured: 8 GB view, 8.6 GB
 * resident], which would commit all guest RAM at once, so views are 64 MB windows
 * imported on demand. Each costs about 2.4 ms on first use, once.
 * shortcut: windows are never evicted, add an LRU if guests churn through RAM.
 *
 * Views are untracked. Tracked hazards don't cross queues [measured], and the
 * paging, exec and blitDown queues are already ordered by events. Within a queue,
 * every transfer binds its shadow's own tracked buffer (written by an upload, read
 * by a download or scatter), which orders one shadow's accesses exactly as its old
 * per-run buffers did. Tracking the view would add false dependencies between
 * unrelated shadows, and blitDown's tails wait on render events. */
#define SHADOW_WINDOW_PAGES (UINT32_C(64) << 8)
static bool shadow_slab_enabled, shadow_gather_enabled, shadow_scatter_enabled, shadow_exact_enabled;
static const AppleGFXShadowRegion *shadow_regions;
static AppleGFXShadowLookup shadow_lookup;
static id<MTLBuffer> **shadow_slabs;
void apple_gfx_legacy_shadow_set_ram(const AppleGFXShadowRegion *regions, uint32_t count, AppleGFXShadowLookup lookup)
{
    shadow_regions = regions;
    shadow_lookup = lookup;
    shadow_slabs = calloc(count, sizeof(*shadow_slabs));
    if (!shadow_slabs) abort();
}
static id<MTLBuffer> shadow_slab(id<MTLDevice> device, uint32_t region, uint32_t window)
{
    const AppleGFXShadowRegion *r = &shadow_regions[region];
    uint64_t offset = (uint64_t)window * SHADOW_WINDOW_PAGES * 4096;
    @synchronized (device) {
        if (!shadow_slabs[region]) {
            shadow_slabs[region] = calloc(r->length / (SHADOW_WINDOW_PAGES * 4096ULL) + 1, sizeof(id));
            if (!shadow_slabs[region]) abort();
        }
        id<MTLBuffer> *slot = &shadow_slabs[region][window];
        if (!*slot) *slot = [device newBufferWithBytesNoCopy:r->host + offset
            length:MIN((uint64_t)SHADOW_WINDOW_PAGES * 4096, r->length - offset)
            options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked deallocator:nil];
        return *slot;
    }
}
typedef struct {
    uint32_t region, page, shadow;
} AppleGFXSortPage;
static int compare_sort_page(const void *a, const void *b)
{
    const AppleGFXSortPage *x = a, *y = b;
    if (x->region != y->region) return x->region < y->region ? -1 : 1;
    if (x->page != y->page) return x->page < y->page ? -1 : 1;
    return 0;
}
/* False leaves the shadow on per-run imports. A page mapped twice is refused: one
 * dispatch would race its two copies, where per-run scatter wrote them in order.
 * The caller keeps length under 4 GB, since byte-grid kernels index with uint, and
 * page-aligned, since they can't take a partial last page. */
static bool shadow_build_table(AppleGFXLegacyShadow *shadow, id<MTLDevice> device, const AppleGFXShadowPage *map)
{
    uint64_t count = shadow->length / 4096;
    AppleGFXSortPage *sorted = malloc(count * sizeof(*sorted));
    AppleGFXTableEntry *entries = malloc(count * sizeof(*entries));
    struct AppleGFXShadowWindow *windows = NULL;
    uint32_t window_count = 0;
    bool ok = sorted && entries;
    for (uint64_t i = 0; ok && i < count; i++)
        sorted[i] = (AppleGFXSortPage){map[i].region, map[i].page, (uint32_t)i};
    if (ok) qsort(sorted, count, sizeof(*sorted), compare_sort_page);
    for (uint64_t i = 0; ok && i < count; i++) {
        uint32_t window = sorted[i].page / SHADOW_WINDOW_PAGES;
        if (i && !compare_sort_page(&sorted[i - 1], &sorted[i])) ok = false;
        else if (!i || sorted[i - 1].region != sorted[i].region ||
                 sorted[i - 1].page / SHADOW_WINDOW_PAGES != window) {
            id<MTLBuffer> slab = shadow_slab(device, sorted[i].region, window);
            struct AppleGFXShadowWindow *grown = realloc(windows, (window_count + 1) * sizeof(*windows));
            if (grown) windows = grown;
            if (!slab || !grown) ok = false;
            else windows[window_count++] = (struct AppleGFXShadowWindow){slab, (uint32_t)i, 0};
        }
        if (!ok) break;
        windows[window_count - 1].count++;
        entries[i] = (AppleGFXTableEntry){sorted[i].shadow, sorted[i].page - window * SHADOW_WINDOW_PAGES};
    }
    id<MTLBuffer> table = ok ? [device newBufferWithBytes:entries length:count * sizeof(*entries)
                                                  options:MTLResourceStorageModeShared] : nil;
    free(sorted);
    free(entries);
    if (!table) {
        free(windows);
        return false;
    }
    shadow->table = table;
    shadow->windows = windows;
    shadow->window_count = window_count;
    return true;
}
/* Longest run from `first` that Metal's rule accepts: every join physically
 * contiguous or on a host 16 KB boundary on both sides [measured]. It is only a
 * first guess, since Metal still has to accept the import. The limit keeps a
 * per-run scatter's grid well inside uint. */
static NSUInteger exact_run(const AppleGFXShadowPage *map, NSUInteger first, NSUInteger pages)
{
    NSUInteger end = first + 1;
    for (; end < pages && end - first < (1u << 18); end++) {
        AppleGFXShadowPage a = map[end - 1], b = map[end];
        uint64_t a_end = shadow_regions[a.region].file_offset + (a.page + UINT64_C(1)) * 4096;
        uint64_t b_start = shadow_regions[b.region].file_offset + (uint64_t)b.page * 4096;
        if (!(a.region == b.region && a.page + 1 == b.page) && ((a_end | b_start) & 16383)) break;
    }
    return (end - first) * 4096;
}

static id legacy_buffer(id self, SEL cmd, uint32_t page, uint64_t length)
{
    uint64_t started = shadow_timing ? apple_gfx_oop_now() : 0;
    void *bytes = ((void *(*)(id, SEL, uint32_t, uint64_t))objc_msgSend)(
        self, sel_registerName("mappedAddressForPageNumber:length:"), page, length);
    if (!bytes) [NSException raise:NSInternalInconsistencyException
                            format:@"PVG legacy mapping failed"];
    id<MTLDevice> device = send_id(self, "mtlDevice");
    id<MTLBuffer> buffer = [device newBufferWithBytesNoCopy:bytes length:length
        options:MTLResourceStorageModeShared deallocator:nil];
    if (buffer) {
        SHADOW_ADD(count_zero_copy, 1);
        SHADOW_ADD(bytes_zero_copy, length);
        return buffer;
    }
    buffer = [device newBufferWithBytes:bytes length:length
        options:MTLResourceStorageModeShared];
    if (!buffer) [NSException raise:NSMallocException
                             format:@"PVG legacy shadow allocation failed"];
    AppleGFXLegacyShadow *shadow = [AppleGFXLegacyShadow new];
    shadow->guest = bytes;
    shadow->length = length;
    if (shadow_wants_baseline) {
        shadow->baseline = [device newBufferWithBytes:bytes length:length
            options:MTLResourceStorageModeShared];
        if (!shadow->baseline) abort();
    }
    AppleGFXShadowPage *map = NULL;
    if (shadow_lookup && (shadow_slab_enabled || shadow_exact_enabled) && !(length & 4095)) {
        map = malloc(length / 4096 * sizeof(*map));
        if (map && !shadow_lookup(bytes, length / 4096, map)) {
            free(map);
            map = NULL;
        }
    }
    if (map && shadow_slab_enabled && length < (UINT64_C(1) << 32) && shadow_build_table(shadow, device, map)) {
        free(map);
        objc_setAssociatedObject(buffer, &shadow_key, shadow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SHADOW_ADD(count_shadow, 1);
        SHADOW_ADD(bytes_shadow, length);
        SHADOW_ADD(count_table, 1);
        SHADOW_ADD(count_windows, shadow->window_count);
        uint32_t windows = shadow->window_count;
        [shadow release];
        if (started) shadow_time(&import_time, "shadow-import", started);
        static unsigned table_count;
        if (__atomic_fetch_add(&table_count, 1, __ATOMIC_RELAXED) < 12)
            fprintf(stderr, "PVG legacy shadow: page=%u length=%llu windows=%u\n", page, length, windows);
        return buffer;
    }
    NSMutableArray *pages = [NSMutableArray array];
    BOOL coalesce = getenv("PVG_SHADOW_COALESCE") != NULL;
    NSUInteger maximumChunk = 65536;
    const char *chunkSetting = getenv("PVG_SHADOW_MAX_CHUNK");
    if (chunkSetting) {
        char *end;
        unsigned long parsed = strtoul(chunkSetting, &end, 10);
        if (end != chunkSetting && !*end && parsed >= 4096 &&
            parsed <= 1048576 && !(parsed & (parsed - 1))) maximumChunk = parsed;
    }
    NSUInteger nextChunk = maximumChunk;
    for (NSUInteger offset = 0; offset < length;) {
        // Bounded speculative import, never infer compatibility from virtual
        // adjacency. Metal must accept the actual no-copy range. Fall back to
        // the existing single-page path on fragmented backing.
        NSUInteger chunk = coalesce ? nextChunk : 4096;
        while (chunk > length - offset && chunk > 4096) chunk /= 2;
        if (map && shadow_exact_enabled) chunk = exact_run(map, offset / 4096, length / 4096);
        id<MTLBuffer> pageBuffer = nil;
        for (;;) {
            pageBuffer = [device newBufferWithBytesNoCopy:(char *)bytes + offset
                length:chunk options:MTLResourceStorageModeShared deallocator:nil];
            if (pageBuffer || chunk == 4096) break;
            chunk = MAX(chunk / 2 & ~(NSUInteger)4095, 4096); // An exact run needn't be a power of two.
        }
        if (!pageBuffer) [NSException raise:NSInternalInconsistencyException
            format:@"PVG single-page Metal import failed"];
        [pages addObject:pageBuffer];
        [pageBuffer release];
        if (chunk < 16384) SHADOW_ADD(bytes_small_runs, chunk);
        offset += chunk;
        /* Probe growth after a success, but do not retry all large sizes
         * for every 4K page in a persistently fractured region. */
        nextChunk = MIN(maximumChunk, chunk * 2);
    }
    free(map);
    shadow->pages = [pages copy];
    objc_setAssociatedObject(buffer, &shadow_key, shadow,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SHADOW_ADD(count_shadow, 1);
    SHADOW_ADD(bytes_shadow, length);
    SHADOW_ADD(count_runs, pages.count);
    [shadow release];
    if (started) shadow_time(&import_time, "shadow-import", started);
    static unsigned count;
    if (__atomic_fetch_add(&count, 1, __ATOMIC_RELAXED) < 12)
        fprintf(stderr, "PVG legacy shadow: page=%u length=%llu runs=%lu coalesce=%d\n",
                page, length, (unsigned long)pages.count, coalesce);
    return buffer;
}

static BOOL needs_prepare(id self, SEL cmd)
{
    id buffer = object_getIvar(self, shared_buffer);
    if (objc_getAssociatedObject(buffer, &shadow_key)) return YES;
    return ((BOOL (*)(id, SEL))original_needs_prepare)(self, cmd);
}

static id<MTLComputePipelineState> shadow_pipeline(id<MTLDevice> device, char *key, NSString *name)
{
    @synchronized (device) {
        id pipeline = objc_getAssociatedObject(device, key);
        if (pipeline) return pipeline;
        NSError *error = nil;
        /* Scatter stays byte-granular, writing only bytes the GPU changed: the guest
         * CPU can be writing other bytes of the same shared buffer meanwhile. */
        id<MTLLibrary> library = [device newLibraryWithSource:
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "struct entry { uint shadow; uint ram; };\n"
             "kernel void scatter(device const uchar *after [[buffer(0)]],"
             "device const uchar *before [[buffer(1)]],"
             "device uchar *guest [[buffer(2)]], uint i [[thread_position_in_grid]])"
             "{ if (after[i] != before[i]) guest[i] = after[i]; }\n"
             "kernel void table_scatter(device const uchar *after [[buffer(0)]],"
             "device const uchar *before [[buffer(1)]], device uchar *ram [[buffer(2)]],"
             "device const entry *table [[buffer(3)]], uint i [[thread_position_in_grid]])"
             "{ entry e = table[i >> 12]; uint s = e.shadow * 4096 + (i & 4095);"
             "  if (after[s] != before[s]) ram[e.ram * 4096 + (i & 4095)] = after[s]; }\n"
             "kernel void gather(device const uint *ram [[buffer(0)]], device uint *shadow [[buffer(1)]],"
             "device const entry *table [[buffer(2)]], uint i [[thread_position_in_grid]])"
             "{ entry e = table[i >> 10]; shadow[e.shadow * 1024 + (i & 1023)] = ram[e.ram * 1024 + (i & 1023)]; }"
            options:nil error:&error];
        id function = [library newFunctionWithName:name];
        pipeline = function ? [device newComputePipelineStateWithFunction:function
            error:&error] : nil;
        [function release]; [library release];
        if (!pipeline) [NSException raise:NSInternalInconsistencyException
            format:@"PVG %@ compile failed: %@", name, error];
        objc_setAssociatedObject(device, key, pipeline, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [pipeline release];
        return pipeline;
    }
}
static id<MTLComputePipelineState> scatter_pipeline(id<MTLDevice> device)
{
    return shadow_pipeline(device, &scatter_key, @"scatter");
}

/* Swapping encoders costs about what 24 single-page blits do [measured], so below
 * this size stay in the blit encoder. */
#define SHADOW_GATHER_MIN_PAGES 32
static void slab_blits(AppleGFXLegacyShadow *shadow, id<MTLBuffer> buffer, id<MTLBlitCommandEncoder> encoder, BOOL upload)
{
    const AppleGFXTableEntry *entries = shadow->table.contents;
    for (uint32_t w = 0; w < shadow->window_count; w++) {
        const struct AppleGFXShadowWindow *window = &shadow->windows[w];
        for (uint32_t i = 0; i < window->count;) {
            AppleGFXTableEntry start = entries[window->first + i];
            uint32_t run = 1;
            while (i + run < window->count && entries[window->first + i + run].ram == start.ram + run &&
                   entries[window->first + i + run].shadow == start.shadow + run) run++;
            NSUInteger ram = (NSUInteger)start.ram * 4096, offset = (NSUInteger)start.shadow * 4096;
            if (upload) [encoder copyFromBuffer:window->slab sourceOffset:ram toBuffer:buffer
                destinationOffset:offset size:(NSUInteger)run * 4096];
            else [encoder copyFromBuffer:buffer sourceOffset:offset toBuffer:window->slab
                destinationOffset:ram size:(NSUInteger)run * 4096];
            SHADOW_ADD(count_slab_blit, 1);
            i += run;
        }
    }
}
/* Only the adapter can leave a blit pass mid-resource and come back. Its compute
 * pass sits at an encoder boundary of the caller's command buffer, so it can't break
 * event order or land inside a render pass, and the blits after it (baseline, donor
 * staging to private or MSAA textures) are ordered behind it by the shadow's tracked
 * buffer. The destination is always shared storage: legacy_buffer made it. */
static void gather(AppleGFXLegacyShadow *shadow, id<MTLBuffer> buffer, AppleGFXPagingEncoder *adapter)
{
    [adapter performTransfer:^(id<MTLCommandBuffer> commands) {
        id<MTLComputeCommandEncoder> compute = [commands computeCommandEncoder];
        [compute setComputePipelineState:shadow_pipeline(commands.device, &gather_key, @"gather")];
        [compute setBuffer:buffer offset:0 atIndex:1];
        for (uint32_t w = 0; w < shadow->window_count; w++) {
            const struct AppleGFXShadowWindow *window = &shadow->windows[w];
            [compute setBuffer:window->slab offset:0 atIndex:0];
            [compute setBuffer:shadow->table offset:window->first * sizeof(AppleGFXTableEntry) atIndex:2];
            [compute dispatchThreads:MTLSizeMake((NSUInteger)window->count * 1024, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        }
        [compute endEncoding];
    }];
    SHADOW_ADD(count_gather, 1);
}

static void transfer(id<MTLBuffer> buffer, id<MTLBlitCommandEncoder> encoder, BOOL upload)
{
    AppleGFXLegacyShadow *shadow = objc_getAssociatedObject(buffer, &shadow_key);
    if (!shadow) return;
    if (shadow->table) {
        if (upload && shadow_gather_enabled && shadow->length >= SHADOW_GATHER_MIN_PAGES * 4096 &&
            [(id)encoder isKindOfClass:[AppleGFXPagingEncoder class]])
            gather(shadow, buffer, (AppleGFXPagingEncoder *)encoder);
        else slab_blits(shadow, buffer, encoder, upload);
    }
    NSUInteger offset = 0;
    for (id<MTLBuffer> page in shadow->pages) {
        NSUInteger size = MIN(page.length, shadow->length - offset);
        if (upload) [encoder copyFromBuffer:page sourceOffset:0 toBuffer:buffer
            destinationOffset:offset size:size];
        else [encoder copyFromBuffer:buffer sourceOffset:offset toBuffer:page
            destinationOffset:0 size:size];
        offset += size;
    }
    if (upload) SHADOW_ADD(bytes_upload, shadow->length);
    if (upload && shadow->baseline) {
        [encoder copyFromBuffer:buffer sourceOffset:0
            toBuffer:shadow->baseline destinationOffset:0 size:shadow->length];
        SHADOW_ADD(bytes_baseline, shadow->length);
    }
}

static BOOL cpu_paging(id self, SEL cmd) { return NO; }
static BOOL needs_sync(id self, SEL cmd)
{
    return objc_getAssociatedObject(object_getIvar(self, shared_buffer), &shadow_key) != nil;
}
static void prepare(id self, SEL cmd, id encoder)
{
    send_id(self, "ensurePhysical");
    transfer(object_getIvar(self, shared_buffer), encoder, YES);
}
static void synchronize(id self, SEL cmd, id encoder)
{
    /* Shared storage can be CPU-written in disjoint regions while the GPU is
     * using it. Whole-buffer scatter clobbers those writes. The execution tail
     * selectively scatters GPU-changed bytes before publishing completion. */
}

static void backing_prepare(id self, SEL cmd, id encoder)
{
    send_id(self, "ensurePhysical");
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "_transferBuffer");
    transfer(object_getIvar(self, ivar), encoder, YES);
    ((void (*)(id, SEL, id))original_backing_prepare)(self, cmd, encoder);
}
static void backing_sync(id self, SEL cmd, id encoder)
{
    ((void (*)(id, SEL, id))original_backing_sync)(self, cmd, encoder);
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "_transferBuffer");
    transfer(object_getIvar(self, ivar), encoder, NO);
}

/* PGPrivateBufferResource owns its own transfer buffer and does not inherit
 * PGBackingResource's paging methods. The donor's ensurePhysical creates that
 * legacy mapping; mirror it around the donor's ordinary private-buffer blits.
 * Unlike shared buffers, managed/private staging follows explicit ownership. */
static void private_prepare(id self, SEL cmd, id encoder)
{
    send_id(self, "ensurePhysical");
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "_transferBuffer");
    transfer(object_getIvar(self, ivar), encoder, YES);
    ((void (*)(id, SEL, id))original_private_prepare)(self, cmd, encoder);
}
static void private_sync(id self, SEL cmd, id encoder)
{
    ((void (*)(id, SEL, id))original_private_sync)(self, cmd, encoder);
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "_transferBuffer");
    transfer(object_getIvar(self, ivar), encoder, NO);
}

/* These texture classes inherit PGTextureResource, not PGBackingResource.
 * Hook the actual paging operation, inside the donor's validity checks, so
 * already-valid GPU textures are not overwritten by stale guest bytes.
 * Compute paging is deliberately excluded: a compute encoder cannot blit. */
static const char *texture_classes[] = {
    "PGSinglePlaneTextureResource",
    "PGDualPlaneBlitTextureResource",
    "PGSinglePlaneSharedTextureBackingResource",
    "PGDualPlaneSharedTextureBackingResource",
};
static IMP original_texture_page[4];
static void texture_page(unsigned index, id self, SEL cmd, id encoder,
                         BOOL download)
{
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "_transferBuffer");
    if (!ivar) abort();
    id buffer = object_getIvar(self, ivar);
    if (!download) transfer(buffer, encoder, YES);
    ((void (*)(id, SEL, id, BOOL))original_texture_page[index])(
        self, cmd, encoder, download);
    if (download) transfer(object_getIvar(self, ivar), encoder, NO);
}
#define TEXTURE_PAGE_WRAPPER(N) \
static void texture_page_##N(id self, SEL cmd, id encoder, BOOL download) \
{ texture_page(N, self, cmd, encoder, download); }
TEXTURE_PAGE_WRAPPER(0)
TEXTURE_PAGE_WRAPPER(1)
TEXTURE_PAGE_WRAPPER(2)
TEXTURE_PAGE_WRAPPER(3)
#undef TEXTURE_PAGE_WRAPPER

/* Verified donor PGResourceList vtable returns id | flags << 32. */
typedef struct LegacyResourceList {
    uint64_t (**vtable)(void *, uint64_t);
    uint64_t count;
} LegacyResourceList;
typedef struct ShadowResourceList {
    LegacyResourceList base;
    LegacyResourceList *original;
    id task;
} ShadowResourceList;
static uint64_t get_entry(void *list, uint64_t index)
{
    ShadowResourceList *wrapper = list;
    uint64_t entry = wrapper->original->vtable[0](wrapper->original, index);
    // Resolve only when the donor enumerates: doExecIndirect first refreshes
    // the object list. Eager resolution before that initialization is invalid.
    id resource = ((id (*)(id, SEL, uint32_t))objc_msgSend)(wrapper->task,
        sel_registerName("getHostResource:"), (uint32_t)entry);
    /* Shared storage relies on coherence: even GPU-written buffers can arrive
     * with flags=0 (verified with a compute output buffer). Request download
     * for every shared buffer, not only those explicitly marked GPU-written.
     * First enumeration precedes ensurePhysical, so do not require an existing
     * shadow here. needsSync filters zero-copy maps after initialization. */
    if ([resource isKindOfClass:NSClassFromString(@"PGSharedBufferResource")])
        entry |= UINT64_C(4) << 32;
    return entry;
}

static void encode_table_scatter(id<MTLComputeCommandEncoder> compute, id<MTLDevice> device,
                                 AppleGFXLegacyShadow *shadow, id<MTLBuffer> buffer)
{
    const AppleGFXTableEntry *entries = shadow->table.contents;
    [compute setComputePipelineState:shadow_scatter_enabled ?
        shadow_pipeline(device, &table_scatter_key, @"table_scatter") : scatter_pipeline(device)];
    [compute setBuffer:buffer offset:0 atIndex:0];
    [compute setBuffer:shadow->baseline offset:0 atIndex:1];
    for (uint32_t w = 0; w < shadow->window_count; w++) {
        const struct AppleGFXShadowWindow *window = &shadow->windows[w];
        [compute setBuffer:window->slab offset:0 atIndex:2];
        if (shadow_scatter_enabled) {
            [compute setBuffer:shadow->table offset:window->first * sizeof(AppleGFXTableEntry) atIndex:3];
            [compute dispatchThreads:MTLSizeMake((NSUInteger)window->count * 4096, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            SHADOW_ADD(count_table_scatter, 1);
            continue;
        }
        for (uint32_t i = 0; i < window->count; i++) { // VIM_PVG_SCATTER=0: one dispatch per page.
            AppleGFXTableEntry e = entries[window->first + i];
            [compute setBufferOffset:(NSUInteger)e.shadow * 4096 atIndex:0];
            [compute setBufferOffset:(NSUInteger)e.shadow * 4096 atIndex:1];
            [compute setBufferOffset:(NSUInteger)e.ram * 4096 atIndex:2];
            [compute dispatchThreads:MTLSizeMake(4096, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        }
    }
}

static void execute(id self, SEL cmd, uint32_t count, void *commands,
                    LegacyResourceList *resources, id event, uint64_t *value,
                    void (^completion)(uint32_t, NSError *))
{
    uint64_t started = shadow_timing ? apple_gfx_oop_now() : 0;
    uint64_t (*vtable[])(void *, uint64_t) = {get_entry};
    ShadowResourceList list = {{vtable, resources->count}, resources, self};
    @synchronized (self) {
        AppleGFXShadowOrder *order = objc_getAssociatedObject(self, &order_key);
        if (!order) {
            order = [AppleGFXShadowOrder new];
            order->event = [send_id(self, "mtlDevice") newEvent];
            if (!order->event) abort();
            objc_setAssociatedObject(self, &order_key, order,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [order release];
        }
        id device = send_id(self, "device");
        uint64_t completed;
        @synchronized (order) { completed = order->completedValue; }
        if (order->value > completed) {
            /* Donor FIFO event signals rendering completion, not completion
             * of our additional scatter on blitDownQueue. Fence both paging
             * and execution before the next submission touches shadow data. */
            SHADOW_ADD(count_barrier, 1);
            Ivar paging = class_getInstanceVariable(object_getClass(self), "_pagingQueue");
            if (!paging) abort();
            id<MTLCommandQueue> queues[] = {object_getIvar(self, paging),
                                           send_id(device, "execQueue")};
            for (unsigned i = 0; i < 2; i++) {
                id<MTLCommandBuffer> barrier = [queues[i] commandBuffer];
                [barrier encodeWaitForEvent:order->event value:order->value];
                [barrier commit];
            }
        }
        AppleGFXShadowCompletion *done = [AppleGFXShadowCompletion new];
        done->callback = [completion copy];
        done->started = started;
        guest_render_depth++;
        @try {
        ((void (*)(id, SEL, uint32_t, void *, void *, id, uint64_t *, id))
            original_exec)(self, cmd, count, commands, &list, event, value,
                ^(uint32_t result, NSError *error) {
                    [done finishDonor:YES result:result error:error];
                });
        } @finally {
            guest_render_depth--;
        }
        if (started) {
            shadow_time(&exec_encode_time, "shadow-exec-encode", started);
            SHADOW_ADD(count_exec, 1);
            shadow_report();
        }
        NSMutableSet *buffers = [NSMutableSet set];
        for (uint64_t i = 0; i < resources->count; i++) {
            uint64_t entry = resources->vtable[0](resources, i);
            id resource = ((id (*)(id, SEL, uint32_t))objc_msgSend)(self,
                sel_registerName("getExistingHostResource:"), (uint32_t)entry);
            if (![resource isKindOfClass:NSClassFromString(@"PGSharedBufferResource")]) continue;
            id buffer = object_getIvar(resource, shared_buffer);
            if (objc_getAssociatedObject(buffer, &shadow_key)) [buffers addObject:buffer];
        }
        if (!buffers.count) {
            /* No extra GPU writes: donor completion is sufficient. Keep the
             * last real scatter fence for later submissions, but do not add
             * an empty blitDown submission or advance its sequence. */
            [done finishDonor:NO result:0 error:nil];
            [done release];
            return;
        }
        id<MTLCommandBuffer> tail = [send_id(device, "blitDownQueue") commandBuffer];
        [tail encodeWaitForEvent:event value:*value];
        if (buffers.count) {
            id<MTLComputeCommandEncoder> compute = [tail computeCommandEncoder];
            id<MTLDevice> metal = send_id(self, "mtlDevice");
            for (id<MTLBuffer> buffer in buffers) {
                AppleGFXLegacyShadow *shadow = objc_getAssociatedObject(buffer, &shadow_key);
                if (shadow->table) {
                    encode_table_scatter(compute, metal, shadow, buffer);
                    SHADOW_ADD(bytes_scatter, shadow->length);
                    continue;
                }
                [compute setComputePipelineState:scatter_pipeline(metal)];
                NSUInteger offset = 0;
                for (id<MTLBuffer> page in shadow->pages) {
                    NSUInteger size = MIN(page.length, shadow->length - offset);
                    [compute setBuffer:buffer offset:offset atIndex:0];
                    [compute setBuffer:shadow->baseline offset:offset atIndex:1];
                    [compute setBuffer:page offset:0 atIndex:2];
                    SHADOW_ADD(bytes_scatter, size);
                    [compute dispatchThreads:MTLSizeMake(size, 1, 1)
                        threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                    offset += size;
                }
            }
            [compute endEncoding];
        }
        uint64_t submitted = ++order->value;
        [tail encodeSignalEvent:order->event value:submitted];
        [tail addCompletedHandler:^(id<MTLCommandBuffer> command) {
            if (started && command.GPUEndTime > command.GPUStartTime) {
                shadow_time(&scatter_gpu_time, "shadow-scatter-gpu", apple_gfx_oop_now() -
                    (uint64_t)((command.GPUEndTime - command.GPUStartTime) * 1e9));
            }
            /* Only successful GPU completion retires a dependency. The
             * callback retains order; publish under its own short lock, not
             * the task lock held by submission. Never erase an in-flight
             * newer fence, and keep error paths conservatively fenced. */
            if (command.status == MTLCommandBufferStatusCompleted) {
                @synchronized (order) {
                    order->completedValue = MAX(order->completedValue, submitted);
                }
            }
            [done finishDonor:NO result:0 error:command.error];
        }];
        [tail commit];
        [done release];
    }
}

/* Same scope as the Intel MSAA transfer: only blit encoders the donor opens for
 * paging get the adapter. Every other path gets a real encoder and slab_blits. */
static __thread unsigned shadow_paging_scope;
static IMP original_prepare_resources;
typedef struct {
    bool first, second;
    id event;
    uint64_t value;
} ShadowPrepareSync;
static id shadow_paging_blit(id self, SEL selector)
{
    if (shadow_paging_scope) return [[[AppleGFXPagingEncoder alloc] initWithCommandBuffer:self] autorelease];
    return ((id (*)(id, SEL))apple_gfx_paging_native_blit)(self, selector);
}
static ShadowPrepareSync shadow_prepare_resources(id self, SEL selector, void *resources, id event, uint64_t value)
{
    shadow_paging_scope++;
    @try {
        return ((ShadowPrepareSync (*)(id, SEL, void *, id, uint64_t))original_prepare_resources)(
            self, selector, resources, event, value);
    } @finally {
        shadow_paging_scope--;
    }
}
static bool shadow_flag(const char *name)
{
    const char *value = getenv(name);
    return !value || strcmp(value, "0");
}

static IMP replace(Class cls, const char *name, IMP replacement)
{
    SEL selector = sel_registerName(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) abort();
    IMP old = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return old;
}

#ifdef APPLE_GFX_SHADOW_STANDALONE
__attribute__((constructor))
#endif
void apple_gfx_legacy_shadow_install(void)
{
    Class task = NSClassFromString(@"PGLocalTask");
    Class shared = NSClassFromString(@"PGSharedBufferResource");
    seamless_pvg_dir = getenv("VIM_SEAMLESS_PVG_DIR");
    if (!getenv("PVG_LEGACY_SHADOW")) return;
    shadow_timing = getenv("VIM_PVG_TIMING") != NULL;
    if (getenv("PVG_CAPTURE_LIBRARIES") || (PVGHostRepairLibrary && getenv("PVG_HOST_AIR_LLVM"))) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        original_library_data = replace(object_getClass(device),
            "newLibraryWithData:error:", (IMP)capture_library_data);
        [device release];
    }
    const char *preserve = getenv("PVG_PRESERVE_IOSURFACE");
    if (preserve && strcmp(preserve, "0") != 0) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id buffer = [queue commandBuffer];
        original_render_encoder = replace(object_getClass(buffer),
            "renderCommandEncoderWithDescriptor:", (IMP)preserving_render_encoder);
        [queue release];
        [device release];
    }
    /* The Metal hooks above apply to every framework. The shadow itself needs
     * the task/resource classes of newer frameworks; macOS 13's has neither. */
    if (!task || !shared) {
        fprintf(stderr, "PVG legacy shadow: framework has no legacy task classes; shadow disabled\n");
        return;
    }
    shared_buffer = class_getInstanceVariable(shared, "_buffer");
    if (!shared_buffer) abort();
    replace(task, "newLegacyBufferForVirtualPage:length:", (IMP)legacy_buffer);
    original_shared_physical = replace(shared, "ensurePhysical", (IMP)shared_physical);
    replace(shared, "prepareInEncoder:", (IMP)prepare);
    replace(shared, "synchronizeInEncoder:", (IMP)synchronize);
    /* macOS 26 adds CPU paging for shared buffers; keep the encoder path we
     * shadow. Earlier frameworks (macOS 15) only have the encoder path. */
    if (class_getInstanceMethod(shared, sel_registerName("needsCPUPaging")))
        replace(shared, "needsCPUPaging", (IMP)cpu_paging);
    replace(shared, "needsSync", (IMP)needs_sync);
    original_needs_prepare = replace(shared, "needsPrepare", (IMP)needs_prepare);
    Class backing = NSClassFromString(@"PGBackingResource");
    original_backing_prepare = replace(backing, "prepareInEncoder:", (IMP)backing_prepare);
    original_backing_sync = replace(backing, "synchronizeInEncoder:", (IMP)backing_sync);
    if (getenv("PVG_SHADOW_PRIVATE_PAGING")) {
        Class private = NSClassFromString(@"PGPrivateBufferResource");
        if (!private || !class_getInstanceVariable(private, "_transferBuffer")) abort();
        original_private_prepare = replace(private, "prepareInEncoder:", (IMP)private_prepare);
        original_private_sync = replace(private, "synchronizeInEncoder:", (IMP)private_sync);
    }
    if (getenv("PVG_SHADOW_TEXTURE_PAGING")) {
        IMP hooks[] = {(IMP)texture_page_0, (IMP)texture_page_1,
                       (IMP)texture_page_2, (IMP)texture_page_3};
        for (unsigned i = 0; i < 4; i++) {
            Class cls = objc_getClass(texture_classes[i]);
            if (!cls || !class_getInstanceVariable(cls, "_transferBuffer")) abort();
            original_texture_page[i] = replace(cls,
                "pageTextureInEncoder:isDownload:", hooks[i]);
        }
    }
    original_exec = replace(task,
        "doExecIndirect:cmdBuffers:resourceList:fifoEvent:fifoEventValue:completionHandler:",
        (IMP)execute);
    shadow_slab_enabled = shadow_flag("VIM_PVG_SLAB");
    shadow_gather_enabled = shadow_flag("VIM_PVG_GATHER");
    shadow_scatter_enabled = shadow_flag("VIM_PVG_SCATTER");
    shadow_exact_enabled = shadow_flag("VIM_PVG_EXACT_RUNS");
    Method prepare_resources = class_getInstanceMethod(task, sel_registerName("prepareResources:event:value:"));
    /* Older frameworks have another task ABI. They keep slab blits, which need no adapter. */
    if (shadow_slab_enabled && shadow_gather_enabled && prepare_resources && !strcmp(method_getTypeEncoding(prepare_resources),
            "{PGTaskPrepareSync_s=BB@Q}40@0:8^{PGResourceList=^^?Q}16@24Q32")) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id commands = [queue commandBuffer];
        Method factory = class_getInstanceMethod(object_getClass(commands), @selector(blitCommandEncoder));
        apple_gfx_paging_native_blit = method_getImplementation(factory);
        class_replaceMethod(object_getClass(commands), @selector(blitCommandEncoder),
                            (IMP)shadow_paging_blit, method_getTypeEncoding(factory));
        original_prepare_resources = replace(task, "prepareResources:event:value:", (IMP)shadow_prepare_resources);
        [queue release];
        [device release];
    }
    fprintf(stderr, "PVG legacy shadow experiment enabled: slab=%d gather=%d scatter=%d exact_runs=%d adapter=%d\n",
            shadow_slab_enabled, shadow_gather_enabled, shadow_scatter_enabled, shadow_exact_enabled,
            original_prepare_resources != NULL);
}
