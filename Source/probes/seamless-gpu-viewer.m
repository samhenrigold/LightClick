// Host end of PassthroughOpenGL/seamless-gpu-replay-host.c: one borderless window per guest window, showing the
// IOSurface QEMU draws it into, at the desktop's level behind every other window and taking no clicks. Prints, each
// second and at the end, frames received, frames whose sampled pixels changed, and frames applied to a layer, and
// writes each window's last frame as a PNG. Those images are composed from pixels, not read from the screen.
//
//     xcrun clang -fobjc-arc -O2 -framework AppKit -framework QuartzCore -framework CoreImage -framework IOSurface \
//         probes/seamless-gpu-viewer.m -o Build/seamless/seamless-gpu-viewer
//     seamless-gpu-viewer SERVICE SECONDS PNG_PREFIX [--no-windows] [--materials ROWS_FILE [--host-shadow]]
//
// With --materials, each window has the host's own material behind its surface, where ROWS_FILE (seamless-guest gpu
// --rows, rewritten as it changes) says, and a plain window behind it all that changes color. Each color's result is
// read from the screen by window ID, with what's below that window. --host-shadow has the host draw each window's
// shadow from its surface's alpha, for a surface with none.
#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
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
@property NSMutableArray<NSVisualEffectView *> *materials;
@property NSImage *shape;
@property uint64_t shapes;
@property NSString *materialKey;
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
static NSString *prefix, *materialsFile;
static NSWindow *backdropWindow;
static BOOL hostShadow;
static uint32_t frontmost;

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

// Any alpha is the window's: see seamless-ws-mojave.h.
static NSImage *shape_of(IOSurfaceRef surface) {
    size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface), row = true_row(surface);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:(NSInteger)width
                                                                    pixelsHigh:(NSInteger)height
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:(NSInteger)width * 4
                                                                  bitsPerPixel:32];
    if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL))
        return nil;
    const uint8_t *base = IOSurfaceGetBaseAddress(surface);
    uint8_t *to = rep.bitmapData;
    for (size_t y = 0; y < height; y++)
        for (size_t x = 0; x < width; x++)
            to[(y * width + x) * 4 + 3] = base[y * row + x * 4 + 3] ? 255 : 0;
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(width / 2.0, height / 2.0)];
    [image addRepresentation:rep];
    return image;
}

static void show(uint32_t windowID, IOSurfaceRef surface, uint32_t width, uint32_t height, int x, int y,
                 uint32_t sent) {
    NSNumber *key = @(windowID & 0xffff);
    Seen *s = seen[key];
    if (!s) {
        s = [Seen new];
        seen[key] = s;
    }
    if (windowID & 0x10000) {
        s.shape = shape_of(surface);
        s.shapes++;
        s.materialKey = nil;
        return;
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
            NSView *top = [[NSView alloc] initWithFrame:s.window.contentView.bounds];
            top.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            top.wantsLayer = YES;
            [s.window.contentView addSubview:top];
            s.layer = top.layer;
            s.layer.contentsGravity = kCAGravityResize;
            s.layer.contentsScale = 2;
            s.window.hasShadow = hostShadow;
            [s.window orderFront:nil];
        }
        if (hostShadow)
            dispatch_async(dispatch_get_main_queue(), ^{
              [s.window invalidateShadow];
            });
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

// shortcut: the guest's material numbers as read on 18G103 in light appearance. The dark ones aren't read yet.
static NSVisualEffectMaterial host_material(int material) {
    switch (material) {
        case 3:
            return NSVisualEffectMaterialMenu;
        case 4:
            return NSVisualEffectMaterialSheet;
        case 5:
            return NSVisualEffectMaterialSidebar;
        case 19:
            return NSVisualEffectMaterialSelection;
        case 21:
        case 25:
            return NSVisualEffectMaterialTitlebar;
        default:
            return NSVisualEffectMaterialWindowBackground;
    }
}

// One effect view for each of the window's backdrops, in the order they're drawn, masked to where it is.
static void apply_materials(void) {
    NSString *text = [NSString stringWithContentsOfFile:materialsFile encoding:NSUTF8StringEncoding error:NULL];
    if (!text)
        return;
    NSMutableDictionary *origins = [NSMutableDictionary new];
    NSMutableDictionary<NSNumber *, NSMutableArray<NSArray *> *> *byWindow = [NSMutableDictionary new];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        unsigned id = 0, order = 0, material = 0, active = 0, blend = 0, frames = 0, n = 0;
        float x, y, w, h, s;
        if (sscanf(line.UTF8String, "row %u id %u frames %u content %f,%f", &n, &id, &frames, &x, &y) == 5)
            origins[@(id)] = @[ @(x), @(y) ];
        else if (sscanf(line.UTF8String,
                        "backdrop id %u order %u material %u active %u blend %u rect %f,%f %fx%f saturation %f", &id,
                        &order, &material, &active, &blend, &x, &y, &w, &h, &s) == 10) {
            if (!byWindow[@(id)])
                byWindow[@(id)] = [NSMutableArray new];
            [byWindow[@(id)] addObject:@[ @(order), @(material), @(x), @(y), @(w), @(h), @(active) ]];
        }
    }
    // In the guest's layout and order: rows are front first, so back to front here.
    NSMutableArray<NSNumber *> *order = [NSMutableArray new];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        unsigned n = 0, id = 0;
        if (sscanf(line.UTF8String, "row %u id %u", &n, &id) == 2 && seen[@(id)].window)
            [order insertObject:@(id) atIndex:0];
    }
    CGFloat screenHeight = NSScreen.screens[0].frame.size.height;
    if (order.count)
        frontmost = order.lastObject.unsignedIntValue;
    for (NSNumber *key in seen)
        if (![order containsObject:key])
            [seen[key].window orderOut:nil];
    for (NSNumber *key in order) {
        Seen *s = seen[key];
        NSArray *origin = origins[key];
        [s.window
            setFrame:NSMakeRect([origin[0] floatValue], screenHeight - [origin[1] floatValue] - 25 - s.height / 2.0,
                                s.width / 2.0, s.height / 2.0)
             display:NO];
        [s.window orderFront:nil];
    }
    for (NSNumber *key in seen) {
        Seen *s = seen[key];
        NSArray *rows = byWindow[key];
        NSArray *origin = origins[key];
        NSString *wanted = [NSString stringWithFormat:@"%@ %@ %ux%u", rows, origin, s.width, s.height];
        if (!s.window || !origin || [wanted isEqual:s.materialKey])
            continue;
        s.materialKey = wanted;
        for (NSVisualEffectView *view in s.materials)
            [view removeFromSuperview];
        s.materials = [NSMutableArray new];
        CGFloat ox = [origin[0] floatValue], oy = [origin[1] floatValue];
        NSRect bounds = s.window.contentView.bounds;
        NSView *top = s.window.contentView.subviews.lastObject;
        // One view for each material, a selection over the sidebar it's in. 26 is what a vibrant text or icon cuts out
        // of the material under it, and needs nothing of the host's.
        for (int pass = 0; pass < 32; pass++) {
            int material = pass == 31 ? 19 : pass == 19 ? -1 : pass;
            NSMutableArray *rects = [NSMutableArray new];
            int active = 0;
            for (NSArray *row in rows)
                if ([row[1] intValue] == material && material != 26) {
                    active |= [row[6] intValue];
                    [rects addObject:row];
                }
            if (!rects.count)
                continue;
            // The menu bar's materials come out with no alpha at all, and it's a rectangle anyway.
            NSImage *shape = material == 21 || material == 25 ? nil : s.shape;
            NSImage *mask = [NSImage imageWithSize:bounds.size
                                           flipped:YES
                                    drawingHandler:^BOOL(NSRect dst) {
                                      [NSColor.blackColor set];
                                      for (NSArray *row in rects)
                                          NSRectFill(NSMakeRect([row[2] floatValue] - ox, [row[3] floatValue] - oy,
                                                                [row[4] floatValue], [row[5] floatValue]));
                                      if (shape)
                                          [shape drawInRect:NSMakeRect(0, 0, shape.size.width, shape.size.height)
                                                    fromRect:NSZeroRect
                                                   operation:NSCompositingOperationDestinationIn
                                                    fraction:1
                                              respectFlipped:YES
                                                       hints:nil];
                                      return YES;
                                    }];
            NSVisualEffectView *view = [[NSVisualEffectView alloc] initWithFrame:bounds];
            view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            view.material = host_material(material);
            view.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            view.state = active ? NSVisualEffectStateActive : NSVisualEffectStateInactive;
            view.maskImage = mask;
            // The first drawn is the furthest back, and the last is under the surface.
            [s.window.contentView addSubview:view positioned:NSWindowBelow relativeTo:top];
            [s.materials addObject:view];
        }
    }
}

// What's on the screen at this window and below it, which at the desktop's level is only this tool's windows and the
// wallpaper: that the host's material samples what's really there.
static void read_with_below(uint32_t window, CGRect rect, NSString *path) {
    typedef CGImageRef (*Create)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);
    Create create = (Create)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    CGImageRef image = create
                           ? create(rect, kCGWindowListOptionIncludingWindow | kCGWindowListOptionOnScreenBelowWindow,
                                    window, kCGWindowImageBestResolution)
                           : NULL;
    if (!image) {
        printf("no image for window %u\n", window);
        return;
    }
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    CGImageRelease(image);
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
        if (argc > 5 && !strcmp(argv[4], "--materials"))
            materialsFile = @(argv[5]);
        hostShadow = argc > 6 && !strcmp(argv[6], "--host-shadow");
        seen = [NSMutableDictionary new];
        mach_port_t port = MACH_PORT_NULL;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
        mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
        // Every window comes at once when the mode goes on, and a sender doesn't wait.
        mach_port_limits_t limits = {MACH_PORT_QLIMIT_LARGE};
        mach_port_set_attributes(mach_task_self(), port, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&limits,
                                 MACH_PORT_LIMITS_INFO_COUNT);
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
              // With SEAMLESS_STALL_MS, a consumer that falls behind: every so often it stops taking frames, then
              // counts any surface that comes twice in what built up meanwhile. The producer reused that one with
              // nobody having seen it.
              static uint32_t backlog[256][2], backlog_count, taken, reused;
              static int in_backlog;
              static const char *stall;
              if (!stall)
                  stall = getenv("SEAMLESS_STALL_MS") ?: "";
              if (*stall && !in_backlog && ++taken % 30 == 0) {
                  usleep((useconds_t)atoi(stall) * 1000);
                  in_backlog = 1;
                  backlog_count = 0;
              }
              kern_return_t got = mach_msg(&packet.message.header, MACH_RCV_MSG | (in_backlog ? MACH_RCV_TIMEOUT : 0),
                                           0, sizeof(packet), port, 0, 0);
              if (got == MACH_RCV_TIMED_OUT)
                  in_backlog = 0;
              if (got)
                  continue;
              struct SGFrameMessage m = packet.message;
              if (m.header.msgh_id != SG_FRAME_MESSAGE) {
                  mach_msg_destroy(&m.header);
                  continue;
              }
              IOSurfaceRef surface = IOSurfaceLookupFromMachPort(m.surface.name);
              mach_port_deallocate(mach_task_self(), m.surface.name);
              // This frame's hold on its surface, given up once the next one for the window has taken its place.
              mach_port_t hold = m.header.msgh_remote_port;
              if (!surface) {
                  if (hold)
                      mach_port_deallocate(mach_task_self(), hold);
                  continue;
              }
              if (in_backlog) {
                  uint32_t id = IOSurfaceGetID(surface);
                  for (uint32_t i = 0; i < backlog_count; i++)
                      if (backlog[i][0] == m.window && backlog[i][1] == id)
                          fprintf(stderr, "stall: window %u surface reused unseen, %u so far\n", m.window, ++reused);
                  if (backlog_count < 256) {
                      backlog[backlog_count][0] = m.window;
                      backlog[backlog_count++][1] = id;
                  }
              }
              dispatch_async(dispatch_get_main_queue(), ^{
                static NSMutableDictionary *held;
                if (!held)
                    held = [NSMutableDictionary new];
                show(m.window, surface, m.width, m.height, m.x, m.y, m.frame);
                CFRelease(surface);
                NSNumber *previous = held[@(m.window)];
                if (previous)
                    mach_port_deallocate(mach_task_self(), previous.unsignedIntValue);
                if (hold)
                    held[@(m.window)] = @(hold);
              });
          }
        });
        [NSTimer scheduledTimerWithTimeInterval:1
                                        repeats:YES
                                          block:^(NSTimer *timer) {
                                            report(NO);
                                          }];
        if (materialsFile) {
            [NSTimer scheduledTimerWithTimeInterval:0.5
                                            repeats:YES
                                              block:^(NSTimer *timer) {
                                                apply_materials();
                                              }];
            // Stepped by a file's appearing, so a run can read each color when it's ready.
            __block int step = 0;
            backdropWindow = [[NSWindow alloc]
                initWithContentRect:NSMakeRect(0, NSScreen.screens[0].frame.size.height - 777, 1152, 752)
                          styleMask:NSWindowStyleMaskBorderless
                            backing:NSBackingStoreBuffered
                              defer:NO];
            backdropWindow.level = kCGDesktopWindowLevel;
            backdropWindow.ignoresMouseEvents = YES;
            backdropWindow.backgroundColor = NSColor.redColor;
            backdropWindow.collectionBehavior =
                NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorTransient;
            [backdropWindow orderBack:nil];
            NSArray *colors = @[ NSColor.redColor, NSColor.blueColor, NSColor.greenColor, NSColor.blackColor ];
            NSArray *names = @[ @"red", @"blue", @"green", @"black" ];
            // With SEAMLESS_CHECKER, seamless-checker.m's checkerboard at four offsets, to compare with a guest's.
            if (getenv("SEAMLESS_CHECKER")) {
                NSMutableArray *patterns = [NSMutableArray new];
                for (int offset = 0; offset < 80; offset += 20) {
                    NSImage *tile = [NSImage imageWithSize:NSMakeSize(80, 80)
                                                   flipped:YES
                                            drawingHandler:^BOOL(NSRect dst) {
                                              (void)dst;
                                              [NSColor.whiteColor set];
                                              NSRectFill(NSMakeRect(0, 0, 80, 80));
                                              [NSColor.blackColor set];
                                              for (int y = 0; y < 80; y += 40)
                                                  for (int x = -80 + offset + (y / 40 % 2) * 40; x < 80; x += 80)
                                                      NSRectFill(NSMakeRect(x, y, 40, 40));
                                              return YES;
                                            }];
                    [patterns addObject:[NSColor colorWithPatternImage:tile]];
                }
                colors = patterns;
                names = @[ @"o0", @"o20", @"o40", @"o60" ];
                backdropWindow.backgroundColor = colors[0];
            }
            [NSTimer
                scheduledTimerWithTimeInterval:5
                                       repeats:YES
                                         block:^(NSTimer *timer) {
                                           if (step >= (int)colors.count)
                                               return;
                                           if (![NSFileManager.defaultManager
                                                   fileExistsAtPath:[materialsFile stringByAppendingString:@".go"]])
                                               return;
                                           [NSFileManager.defaultManager
                                               removeItemAtPath:[materialsFile stringByAppendingString:@".go"]
                                                          error:NULL];
                                           read_with_below(
                                               seen[@(frontmost)].window.windowNumber, CGRectMake(0, 25, 1152, 752),
                                               [NSString stringWithFormat:@"%@-scene-%@.png", prefix, names[step]]);
                                           step++;
                                           if (step < (int)colors.count)
                                               backdropWindow.backgroundColor = colors[step];
                                           printf("step %d\n", step);
                                           fflush(stdout);
                                         }];
        }
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
