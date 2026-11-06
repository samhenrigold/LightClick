// Host-only: which 4K mapping shapes does Metal import no-copy under Rosetta, and
// what does each shadow step cost? No VM or PVG donor. Includes the real shadow.
//   xcrun clang -arch x86_64 -O2 -fno-objc-arc -undefined dynamic_lookup \
//     -I <qemu>/hw/display -framework Foundation -framework Metal \
//     host-shadow-import-rules.m -o /tmp/rules
#include "apple-gfx-legacy-shadow.m"
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#define K4 4096u
#define K16 16384u
#define TRIALS 5

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static uint8_t *ram; // File offset 0 is host-page aligned; page n is offset n * 4K.
static const size_t ram_size = 64u << 20;

static uint8_t *aligned_range(size_t length) {
    mach_vm_address_t address = 0;
    if (mach_vm_map(mach_task_self(), &address, length, 16383, VM_FLAGS_ANYWHERE, MACH_PORT_NULL, 0, FALSE,
                    VM_PROT_READ | VM_PROT_WRITE, VM_PROT_ALL, VM_INHERIT_DEFAULT))
        abort();
    return (uint8_t *)address;
}
static void map_page(uint8_t *target, unsigned ram_page) {
    mach_vm_address_t destination = (mach_vm_address_t)target;
    vm_prot_t current, maximum;
    if (mach_vm_remap(mach_task_self(), &destination, K4, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                      (mach_vm_address_t)ram + ram_page * K4, FALSE, &current, &maximum, VM_INHERIT_NONE))
        abort();
}
// Maps ram pages (ordered as given) at a VA phase, then imports. On success the
// GPU must read the same bytes the CPU sees there.
static void import_case(const char *name, unsigned phase, const unsigned *pages, unsigned count) {
    uint8_t *base = aligned_range((phase + count + 8) * K4), *start = base + phase * K4;
    for (unsigned i = 0; i < count; i++)
        map_page(start + i * K4, pages[i]);
    id<MTLBuffer> buffer = [device newBufferWithBytesNoCopy:start length:count * K4
                                                    options:MTLResourceStorageModeShared deallocator:nil];
    const char *verdict = "rejected";
    if (buffer) {
        id<MTLBuffer> copy = [device newBufferWithLength:count * K4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        [blit copyFromBuffer:buffer sourceOffset:0 toBuffer:copy destinationOffset:0 size:count * K4];
        [blit endEncoding];
        [command commit];
        [command waitUntilCompleted];
        verdict = command.error ? "gpu-error" : memcmp(copy.contents, start, count * K4) ? "WRONG-BYTES" : "ok";
        [copy release];
        [buffer release];
    }
    printf("import %-40s %s\n", name, verdict);
    mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)base, (phase + count + 8) * K4);
}

typedef struct {
    double encode, gpu, total;
} Cost;
static Cost timed(void (^encode)(id<MTLCommandBuffer>)) {
    Cost cost = {0};
    for (unsigned trial = 0; trial < TRIALS; trial++)
        @autoreleasepool {
            uint64_t begin = apple_gfx_oop_now();
            id<MTLCommandBuffer> command = [queue commandBuffer];
            encode(command);
            cost.encode += (apple_gfx_oop_now() - begin) / 1e6 / TRIALS;
            [command commit];
            [command waitUntilCompleted];
            if (command.error)
                abort();
            cost.total += (apple_gfx_oop_now() - begin) / 1e6 / TRIALS;
            cost.gpu += (command.GPUEndTime - command.GPUStartTime) * 1e3 / TRIALS;
        }
    return cost;
}
static void print_cost(const char *name, unsigned runs, Cost cost) {
    printf("%-30s runs=%-5u encode=%7.3fms gpu=%7.3fms wall=%7.3fms\n", name, runs, cost.encode, cost.gpu, cost.total);
}
// Blit source pages in a shuffled order, the worst case for a fragmented guest.
static NSUInteger shuffled(unsigned index, unsigned count) { return (index * 2654435761u % count) * (NSUInteger)K4; }

// 16 MB, the same bytes each way: real per-run no-copy buffers against one slab.
static void cost_shapes(unsigned run_bytes) {
    const NSUInteger size = 16u << 20;
    uint8_t *memory = aligned_range(size);
    memset(memory, 3, size);
    NSMutableArray *runs = [NSMutableArray array];
    uint64_t begin = apple_gfx_oop_now();
    for (NSUInteger offset = 0; offset < size; offset += run_bytes) {
        id<MTLBuffer> run = [device newBufferWithBytesNoCopy:memory + offset length:run_bytes
                                                     options:MTLResourceStorageModeShared deallocator:nil];
        if (!run)
            abort();
        [runs addObject:run];
        [run release];
    }
    printf("import %lu no-copy runs of %uB: %.2fms\n", (unsigned long)runs.count, run_bytes,
           (apple_gfx_oop_now() - begin) / 1e6);
    id<MTLBuffer> shadow = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
    id<MTLBuffer> baseline = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
    print_cost("upload per-run blits", (unsigned)runs.count, timed(^(id<MTLCommandBuffer> command) {
                 id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
                 NSUInteger offset = 0;
                 for (id<MTLBuffer> run in runs) {
                     [blit copyFromBuffer:run sourceOffset:0 toBuffer:shadow destinationOffset:offset size:run_bytes];
                     offset += run_bytes;
                 }
                 [blit endEncoding];
               }));
    id<MTLComputePipelineState> scatter = scatter_pipeline(device);
    print_cost("scatter per-run dispatches", (unsigned)runs.count, timed(^(id<MTLCommandBuffer> command) {
                 id<MTLComputeCommandEncoder> compute = [command computeCommandEncoder];
                 [compute setComputePipelineState:scatter];
                 NSUInteger offset = 0;
                 for (id<MTLBuffer> run in runs) {
                     [compute setBuffer:shadow offset:offset atIndex:0];
                     [compute setBuffer:baseline offset:offset atIndex:1];
                     [compute setBuffer:run offset:0 atIndex:2];
                     [compute dispatchThreads:MTLSizeMake(run_bytes, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                     offset += run_bytes;
                 }
                 [compute endEncoding];
               }));
    // Candidate: blit from one no-copy view of guest RAM at its page offsets, so
    // runs need no MTLBuffer of their own. Same run count, one tracked resource.
    id<MTLBuffer> slab = [device newBufferWithBytesNoCopy:ram length:ram_size
                                                  options:MTLResourceStorageModeShared deallocator:nil];
    if (!slab)
        abort();
    unsigned ram_pages = (unsigned)(ram_size / K4), count = (unsigned)runs.count;
    print_cost("upload slab blits", count, timed(^(id<MTLCommandBuffer> command) {
                 id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
                 for (unsigned i = 0; i < count; i++)
                     [blit copyFromBuffer:slab sourceOffset:shuffled(i, ram_pages) & ~(NSUInteger)(run_bytes - 1)
                                 toBuffer:shadow destinationOffset:(NSUInteger)i * run_bytes size:run_bytes];
                 [blit endEncoding];
               }));
    [slab release];
    [baseline release];
    [shadow release];
    mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)memory, size);
}
// Candidate: one dispatch over a table of page numbers; no per-run CPU encoding.
static void cost_gather(void) {
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:
        @"#include <metal_stdlib>\nusing namespace metal;\n"
         "kernel void gather(device const uint *ram [[buffer(0)]], device uint *out [[buffer(1)]],"
         "device const uint *table [[buffer(2)]], uint i [[thread_position_in_grid]])"
         "{ out[i] = ram[table[i >> 10] * 1024 + (i & 1023)]; }"
                                                  options:nil error:&error];
    id<MTLComputePipelineState> pipeline =
        [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"gather"] error:&error];
    if (!pipeline)
        abort();
    const unsigned pages = 4096, ram_pages = (unsigned)(ram_size / K4);
    id<MTLBuffer> slab = [device newBufferWithBytesNoCopy:ram length:ram_size
                                                  options:MTLResourceStorageModeShared deallocator:nil];
    id<MTLBuffer> out = [device newBufferWithLength:pages * K4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> table = [device newBufferWithLength:pages * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    uint32_t *entries = table.contents;
    for (unsigned i = 0; i < pages; i++)
        entries[i] = (uint32_t)(shuffled(i, ram_pages) / K4);
    print_cost("upload slab one gather dispatch", pages, timed(^(id<MTLCommandBuffer> command) {
                 id<MTLComputeCommandEncoder> compute = [command computeCommandEncoder];
                 [compute setComputePipelineState:pipeline];
                 [compute setBuffer:slab offset:0 atIndex:0];
                 [compute setBuffer:out offset:0 atIndex:1];
                 [compute setBuffer:table offset:0 atIndex:2];
                 [compute dispatchThreads:MTLSizeMake(pages * 1024, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                 [compute endEncoding];
               }));
    for (unsigned i = 0; i < pages; i++)
        if (memcmp((uint8_t *)out.contents + i * K4, ram + entries[i] * K4, K4)) {
            printf("FAIL gather page %u\n", i);
            exit(1);
        }
    [table release];
    [out release];
    [slab release];
}

// The real legacy_buffer on a fractured mapping: only a shared buffer's creation
// gets a baseline, and uploads must still deliver the guest bytes without one.
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
static void check_baseline(BOOL shared) {
    const unsigned pages = 32;
    uint8_t *mapping = aligned_range(pages * K4);
    for (unsigned i = 0; i < pages; i++)
        map_page(mapping + i * K4, 64 + (i ^ 1));
    ProbeTask *task = [ProbeTask new];
    task->bytes = mapping;
    shadow_wants_baseline = shared;
    id<MTLBuffer> buffer = legacy_buffer(task, NULL, 0, pages * K4);
    shadow_wants_baseline = false;
    AppleGFXLegacyShadow *shadow = objc_getAssociatedObject(buffer, &shadow_key);
    if (!shadow || (shadow->baseline != nil) != shared)
        abort();
    memset(buffer.contents, 0, pages * K4);
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    transfer(buffer, blit, YES);
    [blit endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.error || memcmp(buffer.contents, mapping, pages * K4) ||
        (shared && memcmp(shadow->baseline.contents, mapping, pages * K4)))
        abort();
    printf("baseline shared=%d ok, runs=%lu\n", shared, (unsigned long)shadow->pages.count);
    [buffer release];
    [task release];
    mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)mapping, pages * K4);
}

int main(void) {
    @autoreleasepool {
        device = MTLCreateSystemDefaultDevice();
        queue = [device newCommandQueue];
        printf("page=%lu device=%s\n", (unsigned long)vm_page_size, device.name.UTF8String);
        unsigned off_phase = 0;
        for (unsigned i = 0; i < 64; i++) {
            mach_vm_address_t address = 0, noise = 0;
            mach_vm_allocate(mach_task_self(), &noise, K4 * (1 + i % 3), VM_FLAGS_ANYWHERE);
            mach_vm_allocate(mach_task_self(), &address, 8u << 20, VM_FLAGS_ANYWHERE);
            off_phase += (address & 16383) != 0;
        }
        printf("mach_vm_allocate ANYWHERE: %u/64 bases off 16K phase\n", off_phase);

        // Same shape as the helper: shared file-backed RAM mapped from a 4K process.
        char name[64];
        snprintf(name, sizeof(name), "/vim-rules-%d", getpid());
        int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (fd < 0 || ftruncate(fd, ram_size))
            abort();
        shm_unlink(name);
        ram = mmap(NULL, ram_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (ram == MAP_FAILED)
            abort();
        printf("helper-style mmap VA phase=%lu (file offsets stay host-page aligned)\n",
               (unsigned long)((uintptr_t)ram & 16383));
        for (size_t i = 0; i < ram_size; i += 4)
            *(uint32_t *)(ram + i) = (uint32_t)(i * 2654435761u);

        // A native arm64 build can't map 4K pieces; it only prices Metal encoding
        // without Rosetta, against the x86_64 build's matching lines.
        if (vm_page_size != K4) {
            cost_shapes(K16);
            cost_shapes(1u << 20);
            cost_gather();
            return 0;
        }

        // Ram page 32 starts a host 16K bucket: PA phase is (page % 4) * 4K.
        unsigned contiguous[32], reordered[32], fractured[32];
        for (unsigned i = 0; i < 32; i++) {
            contiguous[i] = 32 + i;
            reordered[i] = 32 + (7 - i / 4) * 4 + i % 4;
            fractured[i] = contiguous[i];
        }
        fractured[5] = contiguous[6];
        fractured[6] = contiguous[5];
        import_case("contiguous, VA phase 0, PA phase 0", 0, contiguous, 32);
        import_case("contiguous, VA phase 4K, PA phase 4K", 1, contiguous + 1, 31);
        import_case("contiguous, VA phase 4K, PA phase 0", 1, contiguous, 32);
        import_case("contiguous, VA phase 0, PA phase 4K", 0, contiguous + 1, 31);
        import_case("intact buckets reordered, VA phase 0", 0, reordered, 32);
        import_case("intact buckets reordered, VA phase 4K", 1, reordered, 32);
        import_case("intact buckets reordered, VA phase 8K", 2, reordered, 32);
        import_case("one bucket fractured, VA phase 0", 0, fractured, 32);
        import_case("single 4K page, VA phase == PA phase", 1, contiguous + 1, 1);
        import_case("single 4K page, VA phase != PA phase", 0, contiguous + 1, 1);
        const unsigned tail_head[] = {34, 35, 40, 41};
        import_case("bucket tail + bucket head, VA phase 0", 0, tail_head, 4);
        import_case("bucket tail + bucket head, VA phase 8K", 2, tail_head, 4);
        const unsigned tail_whole[] = {34, 35, 40, 41, 42, 43};
        import_case("tail + whole bucket, VA phase == PA", 2, tail_whole, 6);
        const unsigned aliased[] = {32, 33, 34, 35, 32, 33, 34, 35};
        import_case("same bucket mapped twice, VA phase 0", 0, aliased, 8);

        check_baseline(NO);
        check_baseline(YES);
        cost_shapes(K4);
        cost_shapes(K16);
        cost_shapes(1u << 20);
        cost_gather();
        return 0;
    }
}
