// Host end of PassthroughOpenGL/seamless-gpu-replay-host.c: one borderless window per guest window, showing the
// IOSurface QEMU draws it into, at the desktop's level behind every other window and taking no clicks. Prints, each
// second and at the end, frames received, frames whose sampled pixels changed, and frames applied to a layer, and
// writes each window's last frame as a PNG. Those images are composed from pixels, not read from the screen.
//
//     xcrun clang -fobjc-arc -O2 -framework AppKit -framework QuartzCore -framework CoreImage -framework IOSurface \
//         probes/seamless-gpu-viewer.m -o Build/seamless/seamless-gpu-viewer
//     seamless-gpu-viewer SERVICE SECONDS PNG_PREFIX [--no-windows]
#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <servers/bootstrap.h>
#define SG_FRAME_MESSAGE 0x53474652
struct SGFrameMessage {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface;
    uint32_t window, frame, width, height;
    int32_t x, y;
};

@interface Seen : NSObject
@property NSWindow *window;
@property CALayer *layer;
@property uint32_t width, height, lastSent;
@property int x, y;
@property uint64_t received, changed, applied, lastHash, gaps;
@property uint64_t printedReceived, printedChanged, printedApplied;
@property IOSurfaceRef last;
@end
@implementation Seen
@end

static NSMutableDictionary<NSNumber *, Seen *> *seen;
static BOOL noWindows;
static NSString *prefix;

// PVG's surfaces say 1 byte an element, with a row as long as their width, for pixels of 4 bytes. Their size is right.
static size_t true_row(IOSurfaceRef surface) {
    size_t row = IOSurfaceGetBytesPerRow(surface), width = IOSurfaceGetWidth(surface);
    return row >= width * 4 ? row : (IOSurfaceGetAllocSize(surface) / IOSurfaceGetHeight(surface)) & ~(size_t)63;
}

// Sixteen rows, spread out. Reading them needs the GPU finished with the surface, and QEMU has checked its fence.
static uint64_t rows_hash(IOSurfaceRef surface) {
    if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL))
        return 0;
    const uint8_t *base = IOSurfaceGetBaseAddress(surface);
    size_t row = true_row(surface), height = IOSurfaceGetHeight(surface), width = IOSurfaceGetWidth(surface);
    uint64_t hash = 1469598103934665603ull;
    for (size_t r = 0; r < 16; r++) {
        const uint64_t *line = (const void *)(base + row * (height * r / 16));
        for (size_t x = 0; x < width / 2; x++)
            hash = (hash ^ line[x]) * 1099511628211ull;
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return hash;
}

static void show(uint32_t windowID, IOSurfaceRef surface, uint32_t width, uint32_t height, int x, int y,
                 uint32_t sent) {
    NSNumber *key = @(windowID);
    Seen *s = seen[key];
    if (!s) {
        s = [Seen new];
        seen[key] = s;
    }
    if (s.lastSent && sent != s.lastSent + 1)
        s.gaps += sent - s.lastSent - 1;
    s.lastSent = sent;
    s.received++;
    uint64_t hash = rows_hash(surface);
    if (hash != s.lastHash)
        s.changed++;
    s.lastHash = hash;
    if (!noWindows) {
        if (!s.window) {
            NSRect frame = NSMakeRect(x / 2.0, 900 - (y + (int)height) / 2.0, width / 2.0, height / 2.0);
            s.window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
            s.window.level = kCGDesktopWindowLevel;
            s.window.ignoresMouseEvents = YES;
            s.window.opaque = NO;
            s.window.backgroundColor = NSColor.clearColor;
            s.window.hasShadow = NO;
            s.window.collectionBehavior = NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorTransient;
            s.window.contentView.wantsLayer = YES;
            s.layer = s.window.contentView.layer;
            s.layer.contentsGravity = kCAGravityResize;
            [s.window orderBack:nil];
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        s.layer.contents = (__bridge id)surface;
        [CATransaction commit];
        s.applied++;
    }
    s.width = width;
    s.height = height;
    s.x = x;
    s.y = y;
    CFRetain(surface);
    if (s.last)
        CFRelease(s.last);
    s.last = surface;
}

static void report(BOOL final) {
    for (NSNumber *key in seen) {
        Seen *s = seen[key];
        if (s.received == s.printedReceived && !final)
            continue;
        printf(
            "%s window %u %ux%u at %d,%d received %llu (+%llu) changed %llu (+%llu) applied %llu (+%llu) gaps %llu\n",
            final ? "total" : "tick", key.unsignedIntValue, s.width, s.height, s.x, s.y, s.received,
            s.received - s.printedReceived, s.changed, s.changed - s.printedChanged, s.applied,
            s.applied - s.printedApplied, s.gaps);
        s.printedReceived = s.received;
        s.printedChanged = s.changed;
        s.printedApplied = s.applied;
    }
    fflush(stdout);
}

static void save(void) {
    for (NSNumber *key in seen) {
        Seen *s = seen[key];
        if (!s.last)
            continue;
        if (s.window) {
            // One window, read from the screen: that its layer shows the surface. Fails with the display asleep.
            NSString *path = [NSString stringWithFormat:@"%@-%u-screen.png", prefix, key.unsignedIntValue];
            NSTask *task = [NSTask
                launchedTaskWithLaunchPath:@"/usr/sbin/screencapture"
                                 arguments:@[
                                     @"-x", [NSString stringWithFormat:@"-l%ld", (long)s.window.windowNumber], path
                                 ]];
            [task waitUntilExit];
        }
        IOSurfaceRef surface = s.last;
        printf("surface %u: %zux%zu row %zu alloc %zu format %08x planes %zu elem %zu\n", key.unsignedIntValue,
               IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), IOSurfaceGetBytesPerRow(surface),
               IOSurfaceGetAllocSize(surface), IOSurfaceGetPixelFormat(surface), IOSurfaceGetPlaneCount(surface),
               IOSurfaceGetBytesPerElement(surface));
        // As a GPU consumer sees it, which is what a layer shows, whatever the CPU's view of the memory is.
        CIImage *seenByGPU = [CIImage imageWithIOSurface:surface];
        if (seenByGPU) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCIImage:seenByGPU];
            NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png writeToFile:[NSString stringWithFormat:@"%@-%u-gpu.png", prefix, key.unsignedIntValue] atomically:YES];
        }
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
        size_t w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface), row = true_row(surface);
        const uint8_t *base = IOSurfaceGetBaseAddress(surface);
        size_t clear = 0, opaque = 0;
        for (size_t y = 0; y < h; y++)
            for (size_t x = 0; x < w; x++) {
                uint8_t a = base[y * row + x * 4 + 3];
                clear += a == 0;
                opaque += a == 255;
            }
        printf("final window %u %zux%zu alpha: clear %.1f%% opaque %.1f%% other %.1f%%\n", key.unsignedIntValue, w, h,
               100.0 * clear / (w * h), 100.0 * opaque / (w * h), 100.0 * (w * h - clear - opaque) / (w * h));
        // A copy: a surface's row bytes can be more than a bitmap context takes.
        uint8_t *rows = malloc(w * h * 4);
        for (size_t y = 0; y < h; y++)
            memcpy(rows + y * w * 4, base + y * row, w * 4);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef bitmap = CGBitmapContextCreate(rows, w, h, 8, w * 4, space,
                                                    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGImageRef image = bitmap ? CGBitmapContextCreateImage(bitmap) : NULL;
        // Its colors alone, whatever its alpha says.
        CGContextRef solid =
            CGBitmapContextCreate(rows, w, h, 8, w * 4, space, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        CGImageRef colors = solid ? CGBitmapContextCreateImage(solid) : NULL;
        if (colors) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:colors];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:[NSString stringWithFormat:@"%@-%u-colors.png", prefix, key.unsignedIntValue]
                 atomically:YES];
            CGImageRelease(colors);
        }
        if (solid)
            CGContextRelease(solid);
        if (image) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
            NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png writeToFile:[NSString stringWithFormat:@"%@-%u.png", prefix, key.unsignedIntValue] atomically:YES];
            CGImageRelease(image);
        }
        if (bitmap)
            CGContextRelease(bitmap);
        CGColorSpaceRelease(space);
        free(rows);
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    }
    fflush(stdout);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4)
            return 2;
        int seconds = atoi(argv[2]);
        prefix = @(argv[3]);
        noWindows = argc > 4 && !strcmp(argv[4], "--no-windows");
        seen = [NSMutableDictionary new];
        mach_port_t port = MACH_PORT_NULL;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
        mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
        if (bootstrap_register(bootstrap_port, argv[1], port)) {
            fprintf(stderr, "can't register %s\n", argv[1]);
            return 1;
        }
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyProhibited;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
          for (;;) {
              struct {
                  struct SGFrameMessage message;
                  mach_msg_max_trailer_t trailer;
              } packet;
              if (mach_msg(&packet.message.header, MACH_RCV_MSG, 0, sizeof(packet), port, 0, 0))
                  continue;
              struct SGFrameMessage m = packet.message;
              if (m.header.msgh_id != SG_FRAME_MESSAGE)
                  continue;
              IOSurfaceRef surface = IOSurfaceLookupFromMachPort(m.surface.name);
              mach_port_deallocate(mach_task_self(), m.surface.name);
              if (!surface)
                  continue;
              dispatch_async(dispatch_get_main_queue(), ^{
                show(m.window, surface, m.width, m.height, m.x, m.y, m.frame);
                CFRelease(surface);
              });
          }
        });
        [NSTimer scheduledTimerWithTimeInterval:1
                                        repeats:YES
                                          block:^(NSTimer *timer) {
                                            report(NO);
                                          }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          report(YES);
          save();
          exit(0);
        });
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t term =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(term, ^{
          report(YES);
          save();
          exit(0);
        });
        dispatch_resume(term);
        [NSApp run];
    }
    return 0;
}
