/* Host-only: what a CAMetalLayer swap queue costs a frame, with the production view's shape. One frame in flight until
 * GPU completion (the display ACK), a blit from a shared buffer, acquisition on a worker. No guest.
 *
 *   clang -fobjc-arc -framework Cocoa -framework Metal -framework QuartzCore \
 *       Source/probes/display-swap-queue.m -o /tmp/display-swap-queue && /tmp/display-swap-queue
 *
 * "hand-off" runs from before nextDrawable to the presented timestamp: the time a frame the producer has finished
 * spends in the app and swap queue. It excludes guest time and whatever the panel adds after presentedTime.
 */
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdlib.h>

static int compareDouble(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}
static double percentile(NSArray<NSNumber *> *values, double fraction) {
    if (!values.count)
        return 0;
    double *sorted = malloc(values.count * sizeof(double));
    for (NSUInteger i = 0; i < values.count; i++)
        sorted[i] = values[i].doubleValue;
    qsort(sorted, values.count, sizeof(double), compareDouble);
    double value = sorted[MIN(values.count - 1, (NSUInteger)(fraction * values.count))];
    free(sorted);
    return value * 1000;
}
static void pump(CFTimeInterval seconds) {
    CFTimeInterval end = CACurrentMediaTime() + seconds;
    while (CACurrentMediaTime() < end)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .01, false);
}

static void run(CAMetalLayer *layer, id<MTLCommandQueue> queue, id<MTLBuffer> source, NSUInteger count,
                double producerHz) {
    layer.maximumDrawableCount = count;
    pump(.3);
    const NSUInteger width = layer.drawableSize.width, height = layer.drawableSize.height;
    const NSUInteger stride = (width * 4 + 255) & ~(NSUInteger)255;
    NSMutableArray<NSNumber *> *handoff = [NSMutableArray array], *acquire = [NSMutableArray array];
    NSMutableArray<NSNumber *> *gaps = [NSMutableArray array];
    __block CFTimeInterval lastPresented = 0;
    __block NSUInteger skipped = 0, frames = 0;
    NSLock *lock = [NSLock new];
    dispatch_queue_t worker = dispatch_queue_create("probe.acquire", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    CFTimeInterval start = CACurrentMediaTime(), end = start + 3, next = start;
    while (CACurrentMediaTime() < end) {
        if (producerHz > 0) {
            while (CACurrentMediaTime() < next)
                pump(.0005);
            next += 1 / producerHz;
        }
        CFTimeInterval submitted = CACurrentMediaTime();
        dispatch_async(worker, ^{
          id<CAMetalDrawable> drawable = [layer nextDrawable];
          CFTimeInterval acquired = CACurrentMediaTime();
          [lock lock];
          [acquire addObject:@(acquired - submitted)];
          [lock unlock];
          id<MTLCommandBuffer> command = [queue commandBuffer];
          if (drawable) {
              id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
              [blit copyFromBuffer:source
                         sourceOffset:0
                    sourceBytesPerRow:stride
                  sourceBytesPerImage:stride * height
                           sourceSize:MTLSizeMake(width, height, 1)
                            toTexture:drawable.texture
                     destinationSlice:0
                     destinationLevel:0
                    destinationOrigin:MTLOriginMake(0, 0, 0)];
              [blit endEncoding];
              [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
                CFTimeInterval at = shown.presentedTime;
                [lock lock];
                if (at <= 0)
                    skipped++;
                else {
                    frames++;
                    [handoff addObject:@(at - submitted)];
                    if (lastPresented > 0)
                        [gaps addObject:@(at - lastPresented)];
                    lastPresented = at;
                }
                [lock unlock];
              }];
              [command presentDrawable:drawable];
          }
          [command addCompletedHandler:^(id<MTLCommandBuffer> finished) {
            dispatch_semaphore_signal(completed);
          }];
          [command commit];
        });
        while (dispatch_semaphore_wait(completed, DISPATCH_TIME_NOW))
            pump(.0005);
    }
    pump(.2);
    [lock lock];
    printf("drawables=%lu producer=%-5s fps=%5.1f skipped=%-3lu hand-off p50=%5.1f p99=%5.1f max=%5.1f  "
           "acquire p50=%5.1f max=%5.1f  gap p50=%5.1f p99=%5.1f max=%5.1f ms\n",
           (unsigned long)count, producerHz > 0 ? [NSString stringWithFormat:@"%.1f", producerHz].UTF8String : "free",
           frames / 3.0, (unsigned long)skipped, percentile(handoff, .5), percentile(handoff, .99),
           percentile(handoff, 1), percentile(acquire, .5), percentile(acquire, 1), percentile(gaps, .5),
           percentile(gaps, .99), percentile(gaps, 1));
    [lock unlock];
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 640, 400)
                                                       styleMask:NSWindowStyleMaskTitled
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        window.title = @"Swap queue probe";
        NSView *view = window.contentView;
        view.wantsLayer = YES;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;
        layer.opaque = YES;
        layer.frame = view.bounds;
        layer.drawableSize = CGSizeMake(2560, 1600);
        [view.layer addSublayer:layer];
        // A background accessory window is otherwise often occluded, and an occluded layer skips every present.
        window.level = NSStatusWindowLevel;
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
        [window orderFrontRegardless];
        const NSUInteger stride = (2560 * 4 + 255) & ~(NSUInteger)255;
        id<MTLBuffer> source = [device newBufferWithLength:stride * 1600 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        pump(.5);
        NSInteger hz = window.screen.maximumFramesPerSecond;
        BOOL visible = (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
        printf("screen maximumFramesPerSecond=%ld, window visible=%d, display asleep=%d\n", (long)hz, visible,
               CGDisplayIsAsleep(CGMainDisplayID()));
        if (!visible) {
            // An occluded layer skips every present, so no number below would mean anything.
            fprintf(stderr, "The probe window isn't visible; wake or unlock the display and run this again.\n");
            return 1;
        }
        for (NSNumber *producer in @[ @0, @60, @59.9, @30 ])
            for (NSNumber *count in @[ @3, @2 ])
                run(layer, queue, source, count.unsignedIntegerValue, producer.doubleValue);
    }
    return 0;
}
