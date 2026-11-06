// Host-only: checks the real slab gather and table scatter from
// apple-gfx-legacy-shadow.m, byte for byte, and prices them against per-run imports.
// No VM or PVG donor. Exits non-zero on the first wrong byte.
//   xcrun clang -arch x86_64 -O2 -fno-objc-arc -undefined dynamic_lookup \
//     -I <qemu>/hw/display -framework Foundation -framework Metal \
//     host-shadow-gather.m -o /tmp/gather && /tmp/gather
// Rerun with MTL_DEBUG_LAYER=1 and MTL_SHADER_VALIDATION=1 to catch misuse and
// out-of-bounds kernel accesses. Needs x86_64: only 4 KB pages can fracture a mapping.
#include "apple-gfx-legacy-shadow.m"
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#define K4 4096u

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static uint8_t *ram;
static const size_t ram_size = 256u << 20;
static AppleGFXShadowRegion regions[3];
static AppleGFXShadowPage *lookup_map;
static uint32_t lookup_pages;

static bool fake_lookup(const void *address, uint64_t pages, AppleGFXShadowPage *out) {
    if (!lookup_map || pages != lookup_pages)
        return false;
    memcpy(out, lookup_map, pages * sizeof(*out));
    return true;
}
static void check(bool ok, const char *what) {
    if (!ok) {
        printf("FAIL %s\n", what);
        exit(1);
    }
    printf("ok   %s\n", what);
}
static uint8_t *region_page(AppleGFXShadowPage p) {
    return regions[p.region].host + (uint64_t)p.page * K4;
}

@interface ProbeTask : NSObject {
  @public
    void *bytes;
}
- (void *)mappedAddressForPageNumber:(uint32_t)page length:(uint64_t)length;
- (id)mtlDevice;
@end
@implementation ProbeTask
- (void *)mappedAddressForPageNumber:(uint32_t)page length:(uint64_t)length {
    return bytes;
}
- (id)mtlDevice {
    return device;
}
@end

// Builds a task mapping of the given region pages, so Metal rejects the whole-range
// import just as it does for a fragmented guest, then makes the real shadow.
static id<MTLBuffer> make_shadow(AppleGFXShadowPage *map, uint32_t pages, bool shared, bool known) {
    mach_vm_address_t address = 0;
    if (mach_vm_map(mach_task_self(), &address, pages * K4, 16383, VM_FLAGS_ANYWHERE, MACH_PORT_NULL, 0, FALSE,
                    VM_PROT_READ | VM_PROT_WRITE, VM_PROT_ALL, VM_INHERIT_DEFAULT))
        abort();
    for (uint32_t i = 0; i < pages; i++) {
        mach_vm_address_t destination = address + i * K4;
        vm_prot_t current, maximum;
        if (mach_vm_remap(mach_task_self(), &destination, K4, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                          (mach_vm_address_t)region_page(map[i]), FALSE, &current, &maximum, VM_INHERIT_NONE))
            abort();
    }
    ProbeTask *task = [ProbeTask new];
    task->bytes = (void *)address;
    lookup_map = known ? map : NULL;
    lookup_pages = pages;
    shadow_wants_baseline = shared;
    id<MTLBuffer> buffer = legacy_buffer(task, NULL, 0, pages * K4);
    shadow_wants_baseline = false;
    [task release];
    return buffer;
}
static AppleGFXShadowPage *shuffled_map(uint32_t pages) {
    AppleGFXShadowPage *map = malloc(pages * sizeof(*map));
    uint32_t region_pages = (uint32_t)(regions[0].length / K4);
    // An odd multiplier over a power of two is a permutation, and spans every window.
    for (uint32_t i = 0; i < pages; i++)
        map[i] = (AppleGFXShadowPage){0, (i * 2654435761u) & (region_pages - 1)};
    return map;
}
static void fill_ram(uint32_t seed) {
    uint32_t *words = (uint32_t *)ram;
    for (size_t i = 0; i < ram_size / 4; i++)
        words[i] = (uint32_t)(i * 2654435761u) ^ seed;
}
static bool matches_guest(const uint8_t *bytes, AppleGFXShadowPage *map, uint32_t pages) {
    for (uint32_t i = 0; i < pages; i++)
        if (memcmp(bytes + i * K4, region_page(map[i]), K4))
            return false;
    return true;
}
static void finish(id<MTLCommandBuffer> command) {
    [command commit];
    [command waitUntilCompleted];
    if (command.error) {
        printf("FAIL gpu error %s\n", command.error.description.UTF8String);
        exit(1);
    }
}
// Encodes what the donor's prepareInEncoder does: earlier blits, the shadow transfer,
// then a blit that consumes the shadow, here into private storage.
static void upload(id<MTLBuffer> buffer, id<MTLBuffer> private_copy, id<MTLBuffer> before, bool adapter) {
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id encoder = adapter ? [[[AppleGFXPagingEncoder alloc] initWithCommandBuffer:command] autorelease]
                         : [command blitCommandEncoder];
    [encoder copyFromBuffer:buffer sourceOffset:0 toBuffer:before destinationOffset:0 size:buffer.length];
    transfer(buffer, encoder, YES);
    [encoder copyFromBuffer:buffer sourceOffset:0 toBuffer:private_copy destinationOffset:0 size:buffer.length];
    [encoder endEncoding];
    finish(command);
}
static bool private_matches(id<MTLBuffer> private_copy, AppleGFXShadowPage *map, uint32_t pages) {
    id<MTLBuffer> out = [device newBufferWithLength:private_copy.length options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    [blit copyFromBuffer:private_copy sourceOffset:0 toBuffer:out destinationOffset:0 size:out.length];
    [blit endEncoding];
    finish(command);
    bool ok = matches_guest(out.contents, map, pages);
    [out release];
    return ok;
}

static void check_upload(uint32_t pages, bool adapter, bool expect_gather, const char *what) {
    AppleGFXShadowPage *map = shuffled_map(pages);
    fill_ram(pages);
    id<MTLBuffer> buffer = make_shadow(map, pages, true, true);
    AppleGFXLegacyShadow *shadow = objc_getAssociatedObject(buffer, &shadow_key);
    if (!shadow || !shadow->table)
        check(false, "shadow should have a table");
    id<MTLBuffer> private_copy = [device newBufferWithLength:pages * K4 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> before = [device newBufferWithLength:pages * K4 options:MTLResourceStorageModeShared];
    memset(buffer.contents, 0xee, pages * K4);
    memset(shadow->baseline.contents, 0xdd, pages * K4);
    uint64_t gathers = count_gather;
    upload(buffer, private_copy, before, adapter);
    if ((count_gather != gathers) != expect_gather)
        check(false, "wrong upload path taken");
    // The blit encoded ahead of the gather must not see the gathered bytes.
    bool ordered = ((uint8_t *)before.contents)[0] == 0xee && ((uint8_t *)before.contents)[pages * K4 - 1] == 0xee;
    bool ok = ordered && matches_guest(buffer.contents, map, pages) &&
              matches_guest(shadow->baseline.contents, map, pages) && private_matches(private_copy, map, pages);
    check(ok, what);
    [before release];
    [private_copy release];
    [buffer release];
    free(map);
}

// Byte-granular, with the CPU writing other bytes of the same pages during the scatter.
static void check_scatter(bool table_kernel, const char *what) {
    const uint32_t pages = 4096;
    AppleGFXShadowPage *map = shuffled_map(pages);
    id<MTLBuffer> buffer = make_shadow(map, pages, true, true);
    AppleGFXLegacyShadow *shadow = objc_getAssociatedObject(buffer, &shadow_key);
    shadow_scatter_enabled = table_kernel;
    for (uint32_t i = 0; i < pages; i++)
        memset(region_page(map[i]), 0x11, K4);
    memset(buffer.contents, 0x11, pages * K4);
    memset(shadow->baseline.contents, 0x11, pages * K4);
    for (size_t i = 0; i < pages * K4; i += 1024)
        ((uint8_t *)buffer.contents)[i] = 0x33;
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLComputeCommandEncoder> compute = [command computeCommandEncoder];
    encode_table_scatter(compute, device, shadow, buffer);
    [compute endEncoding];
    [command commit];
    while (command.status < MTLCommandBufferStatusCompleted)
        for (uint32_t i = 0; i < pages; i += 7)
            region_page(map[i])[1] = 0x44;
    [command waitUntilCompleted];
    bool ok = !command.error;
    for (uint32_t i = 0; ok && i < pages; i++) {
        const uint8_t *page = region_page(map[i]);
        for (uint32_t j = 0; ok && j < K4; j++) {
            uint8_t want = j % 1024 ? 0x11 : 0x33;
            if (j == 1 && i % 7 == 0)
                want = page[j] == 0x44 ? 0x44 : 0x11;
            ok = page[j] == want;
        }
    }
    shadow_scatter_enabled = true;
    check(ok, what);
    [buffer release];
    free(map);
}

// A scatter then a gather of one shadow on one queue, with no CPU wait between them.
// Windows are untracked, so only the shadow's own tracked buffer can order these.
static void check_same_queue_order(void) {
    const uint32_t pages = 1024;
    AppleGFXShadowPage *map = shuffled_map(pages);
    id<MTLBuffer> buffer = make_shadow(map, pages, true, true);
    AppleGFXLegacyShadow *shadow = objc_getAssociatedObject(buffer, &shadow_key);
    bool ok = true;
    for (uint32_t round = 1; ok && round <= 50; round++) {
        for (uint32_t i = 0; i < pages; i++)
            memset(region_page(map[i]), 0, K4);
        memset(shadow->baseline.contents, 0, pages * K4);
        memset(buffer.contents, (int)round, pages * K4);
        id<MTLCommandBuffer> tail = [queue commandBuffer];
        id<MTLComputeCommandEncoder> compute = [tail computeCommandEncoder];
        encode_table_scatter(compute, device, shadow, buffer);
        [compute endEncoding];
        id<MTLCommandBuffer> next = [queue commandBuffer];
        id encoder = [[[AppleGFXPagingEncoder alloc] initWithCommandBuffer:next] autorelease];
        transfer(buffer, encoder, YES);
        [encoder endEncoding];
        [tail commit];
        finish(next);
        const uint8_t *bytes = buffer.contents;
        for (size_t i = 0; ok && i < pages * K4; i += 509)
            ok = bytes[i] == round;
    }
    check(ok, "scatter then gather on one queue stay ordered");
    [buffer release];
    free(map);
}

static void check_download(void) {
    const uint32_t pages = 256;
    AppleGFXShadowPage *map = shuffled_map(pages);
    id<MTLBuffer> buffer = make_shadow(map, pages, false, true);
    memset(buffer.contents, 0x5a, pages * K4);
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    transfer(buffer, blit, NO);
    [blit endEncoding];
    finish(command);
    check(matches_guest(buffer.contents, map, pages), "download blits reach guest RAM");
    [buffer release];
    free(map);
}

static void check_fallbacks(void) {
    const uint32_t pages = 64;
    AppleGFXShadowPage *map = shuffled_map(pages);
    fill_ram(7);
    id<MTLBuffer> unknown = make_shadow(map, pages, true, false);
    AppleGFXLegacyShadow *shadow = objc_getAssociatedObject(unknown, &shadow_key);
    check(!shadow->table && shadow->pages.count, "unknown mapping stays on per-run imports");
    map[9] = map[3];
    id<MTLBuffer> twice = make_shadow(map, pages, true, true);
    shadow = objc_getAssociatedObject(twice, &shadow_key);
    check(!shadow->table && shadow->pages.count, "page mapped twice stays on per-run imports");
    id<MTLBuffer> copy = [device newBufferWithLength:pages * K4 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> before = [device newBufferWithLength:pages * K4 options:MTLResourceStorageModeShared];
    upload(twice, copy, before, true);
    check(matches_guest(twice.contents, map, pages), "per-run upload still works through the adapter");
    [before release];
    [copy release];
    [twice release];
    [unknown release];
    free(map);
}

// Both regions have a file phase the window import must tolerate or refuse cleanly.
static void check_regions(void) {
    AppleGFXShadowPage map[64];
    for (uint32_t i = 0; i < 64; i++)
        map[i] = (AppleGFXShadowPage){i & 1, i * 3};
    fill_ram(11);
    id<MTLBuffer> buffer = make_shadow(map, 64, false, true);
    AppleGFXLegacyShadow *shadow = objc_getAssociatedObject(buffer, &shadow_key);
    check(shadow && shadow->table && shadow->window_count == 2, "pages across two regions make two windows");
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id encoder = [[[AppleGFXPagingEncoder alloc] initWithCommandBuffer:command] autorelease];
    transfer(buffer, encoder, YES);
    [encoder endEncoding];
    finish(command);
    check(matches_guest(buffer.contents, map, 64), "two-region gather is byte exact");
    [buffer release];
    AppleGFXShadowPage odd[64];
    for (uint32_t i = 0; i < 64; i++)
        odd[i] = (AppleGFXShadowPage){2, 63 - i};
    buffer = make_shadow(odd, 64, false, true);
    shadow = objc_getAssociatedObject(buffer, &shadow_key);
    printf("note region at file phase 4K: %s\n", shadow->table ? "window imported" : "fell back to per-run");
    command = [queue commandBuffer];
    encoder = [[[AppleGFXPagingEncoder alloc] initWithCommandBuffer:command] autorelease];
    transfer(buffer, encoder, YES);
    [encoder endEncoding];
    finish(command);
    check(matches_guest(buffer.contents, odd, 64), "file phase 4K region is byte exact");
    [buffer release];
}

static void check_exact_run(void) {
    // Region 0's file offset is 0, so page 4 starts a host 16 KB page.
    AppleGFXShadowPage map[] = {{0, 4}, {0, 5}, {0, 6}, {0, 7}, {0, 20}, {0, 21}, {0, 30}, {0, 31}};
    check(exact_run(map, 0, 8) == 6 * K4, "exact run joins contiguous pages and 16 KB boundaries");
    check(exact_run(map, 6, 8) == 2 * K4, "exact run stops at a bad join and at the end");
}

typedef struct {
    double encode, wall;
} Cost;
static Cost timed(void (^encode)(id<MTLCommandBuffer>)) {
    Cost cost = {0, 0};
    for (unsigned trial = 0; trial < 5; trial++)
        @autoreleasepool {
            uint64_t begin = apple_gfx_oop_now();
            id<MTLCommandBuffer> command = [queue commandBuffer];
            encode(command);
            cost.encode += (apple_gfx_oop_now() - begin) / 5e6;
            finish(command);
            cost.wall += (apple_gfx_oop_now() - begin) / 5e6;
        }
    return cost;
}
static void price(const char *name, id<MTLBuffer> buffer, AppleGFXShadowPage *map, uint32_t pages) {
    AppleGFXLegacyShadow *shadow = objc_getAssociatedObject(buffer, &shadow_key);
    Cost up = timed(^(id<MTLCommandBuffer> command) {
        id encoder = [[[AppleGFXPagingEncoder alloc] initWithCommandBuffer:command] autorelease];
        transfer(buffer, encoder, YES);
        [encoder endEncoding];
    });
    if (!matches_guest(buffer.contents, map, pages))
        check(false, "priced upload was wrong");
    id<MTLComputePipelineState> per_run = scatter_pipeline(device);
    Cost down = timed(^(id<MTLCommandBuffer> command) {
        id<MTLComputeCommandEncoder> compute = [command computeCommandEncoder];
        if (shadow->table)
            encode_table_scatter(compute, device, shadow, buffer);
        else {
            [compute setComputePipelineState:per_run];
            NSUInteger offset = 0;
            for (id<MTLBuffer> page in shadow->pages) {
                NSUInteger size = MIN(page.length, shadow->length - offset);
                [compute setBuffer:buffer offset:offset atIndex:0];
                [compute setBuffer:shadow->baseline offset:offset atIndex:1];
                [compute setBuffer:page offset:0 atIndex:2];
                [compute dispatchThreads:MTLSizeMake(size, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                offset += size;
            }
        }
        [compute endEncoding];
    });
    printf("%-26s runs=%-5lu windows=%-2u upload wall=%7.3fms (encode %.3f) scatter wall=%7.3fms (encode %.3f)\n", name,
           (unsigned long)shadow->pages.count, shadow->window_count, up.wall, up.encode, down.wall, down.encode);
}
static void price_all(void) {
    const uint32_t pages = 4096;
    AppleGFXShadowPage *map = shuffled_map(pages);
    fill_ram(3);
    uint64_t begin = apple_gfx_oop_now();
    shadow_slab_enabled = false;
    id<MTLBuffer> before = make_shadow(map, pages, true, true);
    printf("per-run shadow create %.2fms\n", (apple_gfx_oop_now() - begin) / 1e6);
    price("per-run imports", before, map, pages);
    [before release];
    shadow_slab_enabled = true;
    begin = apple_gfx_oop_now();
    id<MTLBuffer> after = make_shadow(map, pages, true, true);
    printf("table shadow create %.2fms\n", (apple_gfx_oop_now() - begin) / 1e6);
    price("gather and table scatter", after, map, pages);
    shadow_gather_enabled = shadow_scatter_enabled = false;
    price("slab blits, page scatter", after, map, pages);
    shadow_gather_enabled = shadow_scatter_enabled = true;
    [after release];
    free(map);
}

int main(void) {
    @autoreleasepool {
        if (vm_page_size != K4) {
            printf("build with -arch x86_64\n");
            return 2;
        }
        device = MTLCreateSystemDefaultDevice();
        queue = [device newCommandQueue];
        char name[64];
        snprintf(name, sizeof(name), "/vim-gather-%d", getpid());
        int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (fd < 0 || ftruncate(fd, ram_size))
            abort();
        shm_unlink(name);
        ram = mmap(NULL, ram_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (ram == MAP_FAILED)
            abort();
        // Separate mappings, as the helper has for separate RAM sections.
        regions[0] = (AppleGFXShadowRegion){ram, 128u << 20, 0};
        regions[1] = (AppleGFXShadowRegion){ram + (128u << 20), 64u << 20, 128u << 20};
        regions[2] = (AppleGFXShadowRegion){ram + (192u << 20) + K4, 1u << 20, (192u << 20) + K4};
        apple_gfx_legacy_shadow_set_ram(regions, 3, fake_lookup);
        shadow_slab_enabled = shadow_gather_enabled = shadow_scatter_enabled = shadow_exact_enabled = shadow_timing = true;

        check_exact_run();
        check_upload(4096, true, true, "gather through the adapter, with baseline and private blit");
        check_upload(4096, false, false, "slab blits through a real blit encoder");
        check_upload(8, true, false, "small shadow stays in the blit encoder");
        check_scatter(true, "table scatter is byte exact with the CPU writing");
        check_scatter(false, "page scatter is byte exact with the CPU writing");
        check_same_queue_order();
        check_download();
        check_regions();
        check_fallbacks();
        price_all();
        printf("all checks passed\n");
        return 0;
    }
}
