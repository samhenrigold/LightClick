// Host side of the seamless-window demo: one borderless NSWindow per guest window, fed by seamless-guest, with pointer
// and keys sent back. Listens on loopback only; a guest reaches that as 10.0.2.2 over QEMU's user network.
//
//     seamless-viewer [--port 7654] [--self-test] [--exit-after SECONDS] [--png PATH] [--test-input X,Y]
//
// --self-test clicks and types into the first window, confirms on-screen pixels changed each time, and exits 0 or 1.
// --exit-after stops that long after the first window appears, or when the guest disconnects, prints what arrived,
// writes the window's last pixels to --png, and exits 0 if any frame came. --test-input clicks at X,Y (window points)
// and types one key, a few seconds into the run, over the same path as real input.
//
// shortcut: any local process can connect, and nothing authenticates it; a real design uses a private virtio port.
// shortcut: one process, so one Dock tile; generated per-app proxies are phase 2, see seamless-apps-design.md.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include "seamless-wire.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

static int connectionFD = -1; // Main thread.
static BOOL selfTest;
static double exitAfter;
static NSString *pngPath;
static NSPoint testClick = {-1, -1};

// Input is latest-wins and the reader mustn't wedge against us, so never block the main thread on a full socket.
static void sendToGuest(const uint8_t *bytes, size_t size) {
    if (connectionFD >= 0 && size)
        send(connectionFD, bytes, size, MSG_DONTWAIT);
}

@interface GuestWindow : NSWindow
@property uint32_t guestID;
@end
@implementation GuestWindow
- (BOOL)canBecomeKeyWindow {
    return YES;
}
- (BOOL)canBecomeMainWindow {
    return YES;
}
@end

@interface GuestView : NSView
@property NSMutableData *pixels;
@property uint32_t pixelWidth, pixelHeight, guestID;
@property BOOL dirty;
@property NSSize points;
@property NSInteger buttons;
- (void)sendKind:(uint8_t)kind button:(uint8_t)button event:(NSEvent *)event;
@end
@implementation GuestView
- (BOOL)isFlipped {
    return YES;
}
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}
- (BOOL)wantsUpdateLayer {
    return YES;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas)
        [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc]
                              initWithRect:NSZeroRect
                                   options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                     owner:self
                                  userInfo:nil]];
}
- (void)sendKind:(uint8_t)kind button:(uint8_t)button event:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    struct SWMPointer e = {self.guestID,
                           kind,
                           button,
                           (uint8_t)MIN(event.type == NSEventTypeMouseMoved ? 0 : event.clickCount, 255),
                           (int32_t)lround(p.x * 16),
                           (int32_t)lround(p.y * 16),
                           (uint32_t)(event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask)};
    uint8_t out[64];
    sendToGuest(out, swm_put_pointer(out, sizeof(out), &e));
}
- (void)mouseMoved:(NSEvent *)event {
    [self sendKind:SWM_MOVE button:0 event:event];
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    // A guest title-bar drag can't work through window-relative coordinates: the host window would follow the guest
    // window and the pointer would never appear to move. Let the host's window manager run it, as RDP's local
    // move-resize does. 22 points tall, skipping the traffic lights; correct for Aqua on 10.9 only, which is all this
    // demo claims.
    if (p.y < 22 && p.x > 70) {
        [self.window performWindowDragWithEvent:event];
        return;
    }
    [self.window makeFirstResponder:self];
    [self sendKind:SWM_DOWN button:0 event:event];
}
- (void)mouseDragged:(NSEvent *)event {
    [self sendKind:SWM_DRAG button:0 event:event];
}
- (void)mouseUp:(NSEvent *)event {
    [self sendKind:SWM_UP button:0 event:event];
}
- (void)rightMouseDown:(NSEvent *)event {
    [self sendKind:SWM_DOWN button:1 event:event];
}
- (void)rightMouseDragged:(NSEvent *)event {
    [self sendKind:SWM_DRAG button:1 event:event];
}
- (void)rightMouseUp:(NSEvent *)event {
    [self sendKind:SWM_UP button:1 event:event];
}
- (void)sendKey:(uint16_t)code down:(BOOL)down flags:(NSEventModifierFlags)flags {
    struct SWMKey k = {code, (uint8_t)down, (uint32_t)(flags & NSEventModifierFlagDeviceIndependentFlagsMask)};
    uint8_t out[32];
    sendToGuest(out, swm_put_key(out, sizeof(out), &k));
}
- (void)keyDown:(NSEvent *)event {
    [self sendKey:event.keyCode down:YES flags:event.modifierFlags];
}
- (void)keyUp:(NSEvent *)event {
    [self sendKey:event.keyCode down:NO flags:event.modifierFlags];
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.window.firstResponder != self)
        return NO;
    // AppKit won't deliver the key-up of a consumed command equivalent.
    [self sendKey:event.keyCode down:YES flags:event.modifierFlags];
    [self sendKey:event.keyCode down:NO flags:event.modifierFlags];
    return YES;
}
- (void)flagsChanged:(NSEvent *)event {
    NSEventModifierFlags mask = 0;
    switch (event.keyCode) {
        case 54:
        case 55:
            mask = NSEventModifierFlagCommand;
            break;
        case 56:
        case 60:
            mask = NSEventModifierFlagShift;
            break;
        case 58:
        case 61:
            mask = NSEventModifierFlagOption;
            break;
        case 59:
        case 62:
            mask = NSEventModifierFlagControl;
            break;
        default:
            return;
    }
    [self sendKey:event.keyCode down:(event.modifierFlags & mask) != 0 flags:event.modifierFlags];
}
- (void)present {
    if (!self.dirty || !self.pixels)
        return;
    self.dirty = NO;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    // shortcut: copies the frame into a new image, which is fine at this demo's rates; phase 2 replaces all this with
    // the display path's own surface.
    CGContextRef context =
        CGBitmapContextCreate(self.pixels.mutableBytes, self.pixelWidth, self.pixelHeight, 8, self.pixelWidth * 4,
                              space, kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(space);
    if (!context)
        return;
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.contents = (__bridge id)image;
    [CATransaction commit];
    CGImageRelease(image);
    [self.window invalidateShadow];
}
@end

@interface Controller : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSMutableDictionary<NSNumber *, GuestWindow *> *windows;
@property int port;
@property NSUInteger framesShown, bytesShown;
@property CFTimeInterval firstFrame;
@property NSMutableArray<NSString *> *seenTitles;
@end

// Reads back this process's own window through SCK, which needs no Screen Recording grant.
static void centerPixel(NSWindow *window, void (^done)(uint32_t bgra)) {
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content,
                                                                                 NSError *error) {
      SCWindow *found = nil;
      for (SCWindow *w in content.windows)
          if (w.windowID == (CGWindowID)window.windowNumber)
              found = w;
      if (!found) {
          done(0);
          return;
      }
      SCStreamConfiguration *config = [SCStreamConfiguration new];
      config.width = 32;
      config.height = 32;
      [SCScreenshotManager captureImageWithFilter:[[SCContentFilter alloc] initWithDesktopIndependentWindow:found]
                                    configuration:config
                                completionHandler:^(CGImageRef image, NSError *captureError) {
                                  uint32_t pixel = 0;
                                  if (image) {
                                      CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
                                      CGContextRef c = CGBitmapContextCreate(
                                          &pixel, 1, 1, 8, 4, space,
                                          kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
                                      // The middle of the window, clear of the test pattern's moving bar.
                                      CGContextDrawImage(c, CGRectMake(-16, -16, 32, 32), image);
                                      CGContextRelease(c);
                                      CGColorSpaceRelease(space);
                                  }
                                  dispatch_async(dispatch_get_main_queue(), ^{
                                    done(pixel);
                                  });
                                }];
    }];
}

@implementation Controller
- (void)fail:(const char *)why {
    fprintf(stderr, "self-test FAILED: %s\n", why);
    exit(1);
}
// Prints what the guest sent, keeps its last pixels, and exits.
- (void)finishRun {
    double seconds = self.framesShown ? CACurrentMediaTime() - self.firstFrame : 0;
    printf("viewer_frames %lu count\n", (unsigned long)self.framesShown);
    printf("viewer_rate %.1f /s\n", seconds > 0 ? self.framesShown / seconds : 0);
    printf("viewer_received %.2f MB/s\n", seconds > 0 ? self.bytesShown / seconds / 1e6 : 0);
    printf("viewer_windows %lu count\n", (unsigned long)self.seenTitles.count);
    for (NSString *line in self.seenTitles)
        printf("# %s\n", line.UTF8String);
    GuestView *view = (GuestView *)self.windows.allValues.firstObject.contentView;
    if (pngPath && view.layer.contents) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)view.layer.contents];
        BOOL saved = [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:pngPath
                                                                                             atomically:YES];
        printf("# last frame %ux%u %s %s\n", view.pixelWidth, view.pixelHeight, saved ? "saved to" : "NOT saved to",
               pngPath.UTF8String);
    }
    fflush(stdout);
    exit(self.framesShown ? 0 : 1);
}
- (void)sendTestInput:(GuestWindow *)window {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      uint8_t out[64];
      int32_t x = (int32_t)(testClick.x * 16), y = (int32_t)(testClick.y * 16);
      struct SWMPointer move = {window.guestID, SWM_MOVE, 0, 0, x, y, 0};
      sendToGuest(out, swm_put_pointer(out, sizeof(out), &move));
      struct SWMPointer down = {window.guestID, SWM_DOWN, 0, 1, x, y, 0};
      sendToGuest(out, swm_put_pointer(out, sizeof(out), &down));
      struct SWMPointer up = {window.guestID, SWM_UP, 0, 1, x, y, 0};
      sendToGuest(out, swm_put_pointer(out, sizeof(out), &up));
      puts("# sent the test click");
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        uint8_t bytes[32];
        struct SWMKey press = {0, 1, 0}; // The A key.
        sendToGuest(bytes, swm_put_key(bytes, sizeof(bytes), &press));
        struct SWMKey release = {0, 0, 0};
        sendToGuest(bytes, swm_put_key(bytes, sizeof(bytes), &release));
        puts("# sent the test key");
        fflush(stdout);
      });
    });
}
- (void)selfTestWindow:(GuestWindow *)window {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      centerPixel(window, ^(uint32_t before) {
        uint8_t out[64];
        struct SWMPointer down = {window.guestID, SWM_DOWN, 0, 1, 100 * 16, 100 * 16, 0};
        sendToGuest(out, swm_put_pointer(out, sizeof(out), &down));
        struct SWMPointer up = {window.guestID, SWM_UP, 0, 1, 100 * 16, 100 * 16, 0};
        sendToGuest(out, swm_put_pointer(out, sizeof(out), &up));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          centerPixel(window, ^(uint32_t afterClick) {
            uint8_t keyBytes[32];
            struct SWMKey key = {49, 1, 0};
            sendToGuest(keyBytes, swm_put_key(keyBytes, sizeof(keyBytes), &key));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
              centerPixel(window, ^(uint32_t afterKey) {
                printf("center pixel BGRA: start %08x, after click %08x, after key %08x\n", before, afterClick,
                       afterKey);
                double seconds = CACurrentMediaTime() - self.firstFrame;
                printf("%lu frames, %.1f fps, %.1f MB/s over TCP\n", (unsigned long)self.framesShown,
                       self.framesShown / seconds, self.bytesShown / seconds / 1e6);
                // Start is green, then blue with no green, then red with no green.
                if (!before || ((before >> 8) & 255) < 128)
                    [self fail:"the first frame isn't green on screen"];
                if ((afterClick & 255) < 128 || ((afterClick >> 8) & 255) >= 128)
                    [self fail:"the click didn't reach the guest and come back as pixels"];
                if (((afterKey >> 16) & 255) < 128)
                    [self fail:"the key didn't reach the guest and come back as pixels"];
                puts("self-test ok");
                exit(0);
              });
            });
          });
        });
      });
    });
}
- (void)apply:(const struct SWMMessage *)m {
    if (m->type == SWM_WINDOW) {
        const struct SWMWindow *w = &m->u.window;
        GuestWindow *window = self.windows[@(w->window)];
        NSSize size = NSMakeSize(w->width, w->height);
        BOOL created = !window;
        if (created) {
            window = [[GuestWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
            window.opaque = NO;
            window.backgroundColor = NSColor.clearColor;
            window.hasShadow = YES;
            window.guestID = w->window;
            window.delegate = self;
            window.releasedWhenClosed = NO;
            GuestView *view = [[GuestView alloc] initWithFrame:window.contentLayoutRect];
            view.guestID = w->window;
            view.wantsLayer = YES;
            view.layer.contentsGravity = kCAGravityResize;
            window.contentView = view;
            [window center];
            self.windows[@(w->window)] = window;
        }
        NSString *title = [[NSString alloc] initWithBytes:w->title
                                                   length:w->title_length
                                                 encoding:NSUTF8StringEncoding];
        window.title = title ?: @"";
        NSString *owner = [[NSString alloc] initWithBytes:w->owner
                                                   length:w->owner_length
                                                 encoding:NSUTF8StringEncoding];
        NSString *seen =
            [NSString stringWithFormat:@"window %u of %@, \"%@\", %dx%d points, %ux%u pixels", w->window, owner,
                                       window.title, w->width, w->height, w->pixel_width, w->pixel_height];
        if (![self.seenTitles containsObject:seen])
            [self.seenTitles addObject:seen];
        GuestView *view = (GuestView *)window.contentView;
        view.points = size;
        if (!NSEqualSizes(window.frame.size, size)) {
            // Guest windows grow downward from a fixed top-left, so keep the host's top-left too.
            NSRect frame = window.frame;
            frame.origin.y = NSMaxY(frame) - size.height;
            frame.size = size;
            [window setFrame:frame display:NO];
        }
        if (view.pixelWidth != w->pixel_width || view.pixelHeight != w->pixel_height) {
            view.pixelWidth = w->pixel_width;
            view.pixelHeight = w->pixel_height;
            view.pixels = [NSMutableData dataWithLength:(NSUInteger)w->pixel_width * w->pixel_height * 4];
        }
        if (created) {
            [window makeKeyAndOrderFront:nil];
            [window makeFirstResponder:view];
            if (selfTest)
                [self selfTestWindow:window];
            if (testClick.x >= 0)
                [self sendTestInput:window];
            if (exitAfter > 0)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(exitAfter * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                 [self finishRun];
                               });
        }
    } else if (m->type == SWM_FRAME) {
        const struct SWMFrame *f = &m->u.frame;
        GuestView *view = (GuestView *)self.windows[@(f->window)].contentView;
        // The guest chooses all of these: the parser bounded the band by full_*, and this ties full_* to our buffer.
        if (!view.pixels || f->full_width != view.pixelWidth || f->full_height != view.pixelHeight)
            return;
        uint8_t *base = view.pixels.mutableBytes;
        size_t stride = (size_t)view.pixelWidth * 4, row = (size_t)f->width * 4;
        for (uint32_t y = 0; y < f->height; y++)
            memcpy(base + (f->y + y) * stride + (size_t)f->x * 4, f->pixels + y * row, row);
        view.dirty = YES;
        [view present];
        if (!self.framesShown)
            self.firstFrame = CACurrentMediaTime();
        self.framesShown++;
        self.bytesShown += row * f->height;
    } else if (m->type == SWM_GONE) {
        GuestWindow *window = self.windows[@(m->u.window_id)];
        [self.windows removeObjectForKey:@(m->u.window_id)];
        [window close];
    } else if (m->type == SWM_HELLO && m->u.version != SWM_VERSION)
        NSLog(@"Guest protocol %u, not %u", m->u.version, SWM_VERSION);
}
- (void)windowDidBecomeKey:(NSNotification *)note {
    uint8_t out[32];
    sendToGuest(out, swm_put_u32_message(out, sizeof(out), SWM_FOCUS, ((GuestWindow *)note.object).guestID));
}
- (void)serve:(int)client {
    dispatch_sync(dispatch_get_main_queue(), ^{
      connectionFD = client;
    });
    size_t capacity = 1 << 20, have = 0;
    uint8_t *buffer = malloc(capacity);
    for (BOOL alive = buffer != NULL; alive;) {
        ssize_t n = recv(client, buffer + have, capacity - have, 0);
        if (n <= 0)
            break;
        have += (size_t)n;
        size_t offset = 0;
        for (;;) {
            struct SWMMessage m;
            size_t used = 0;
            enum SWMParse result = swm_parse(buffer + offset, have - offset, &m, &used);
            if (result == SWM_BAD) {
                NSLog(@"Invalid message from the guest; dropping it.");
                alive = NO;
                break;
            }
            if (result == SWM_NEED_MORE) {
                // Safe: the parser has already checked this size against the frame's limits.
                if (used > capacity) {
                    uint8_t *larger = realloc(buffer, used);
                    if (!larger) {
                        alive = NO;
                        break;
                    }
                    buffer = larger;
                    capacity = used;
                }
                break;
            }
            // Synchronous so `m` can keep pointing into the buffer, and so a slow window throttles the guest.
            dispatch_sync(dispatch_get_main_queue(), ^{
              [self apply:&m];
            });
            offset += used;
        }
        memmove(buffer, buffer + offset, have - offset);
        have -= offset;
    }
    free(buffer);
    close(client);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (exitAfter > 0)
          [self finishRun];
      connectionFD = -1;
      for (GuestWindow *window in self.windows.allValues)
          [window close];
      [self.windows removeAllObjects];
      if (selfTest)
          [self fail:"the guest disconnected early"];
    });
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.windows = [NSMutableDictionary dictionary];
    self.seenTitles = [NSMutableArray array];
    int listener = socket(AF_INET, SOCK_STREAM, 0), on = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)self.port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 1)) {
        perror("listen");
        exit(1);
    }
    printf("Listening on 127.0.0.1:%d, which a guest reaches as 10.0.2.2:%d\n", self.port, self.port);
    fflush(stdout);
    if (selfTest)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          [self fail:"timed out"];
        });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
      for (;;) {
          int client = accept(listener, NULL, NULL);
          if (client < 0)
              continue;
          int yes = 1;
          setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
          setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
          [self serve:client];
      }
    });
    [NSApp activateIgnoringOtherApps:YES];
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        Controller *controller = [Controller new];
        controller.port = 7654;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--self-test"))
                selfTest = YES;
            else if (!strcmp(argv[i], "--exit-after") && i + 1 < argc)
                exitAfter = atof(argv[++i]);
            else if (!strcmp(argv[i], "--png") && i + 1 < argc)
                pngPath = @(argv[++i]);
            else if (!strcmp(argv[i], "--test-input") && i + 1 < argc) {
                NSArray<NSString *> *parts = [@(argv[++i]) componentsSeparatedByString:@","];
                if (parts.count == 2)
                    testClick = NSMakePoint(parts[0].doubleValue, parts[1].doubleValue);
            } else if (!strcmp(argv[i], "--port") && i + 1 < argc)
                controller.port = atoi(argv[++i]);
        }
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        app.delegate = controller;
        [app run];
    }
    return 0;
}
