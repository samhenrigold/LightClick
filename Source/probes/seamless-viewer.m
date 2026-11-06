// Host side of the seamless-window demo: one borderless NSWindow per guest window, fed by seamless-guest, with pointer
// and keys sent back. Listens on loopback only; a guest reaches that as 10.0.2.2 over QEMU's user network.
//
//     seamless-viewer [--port 7654] [--self-test] [--exit-after SECONDS] [--png PATH] [--test-input X,Y] [--tree]
//
// --self-test clicks and types into the first window, confirms on-screen pixels changed each time, and exits 0 or 1.
// --exit-after stops that long after the first window appears, or when the guest disconnects, prints what arrived,
// writes the window's last pixels to --png, and exits 0 if any frame came. --test-input clicks at X,Y (window points)
// and types one key, a few seconds into the run, over the same path as real input.
//
// --tree shows the guest's whole window tree: each window where the guest has it, relative to the others, at its level
// and order, with the shadow and alpha in its pixels, and pointer events sent as guest screen coordinates. --png then
// names a prefix, and each window's last pixels are saved when it goes away, so menus survive to be looked at.
//
// shortcut: any local process can connect, and nothing authenticates it; a real design uses a private virtio port.
// shortcut: one process, so one Dock tile; generated per-app proxies are phase 2, see seamless-apps-design.md.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include "seamless-wire.h"
#include <arpa/inet.h>
#include <dlfcn.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

static int connectionFD = -1; // Main thread.
static BOOL selfTest;
static NSString *sessionSocketPath;
// A session the app started: the guest agent's channel, what to run, and the programs to put in the guest.
static NSString *channelPath, *guestAppName, *guestToolsPath;
static BOOL testSession;
static pid_t proxyPID;
static NSMutableDictionary<NSNumber *, NSString *> *documentPaths;
static NSMutableDictionary<NSNumber *, NSMutableData *> *documentsComing;
static NSMutableArray<NSString *> *documentsWaiting;
static NSString *testDragPath, *testDragOutFolder;
static NSArray<NSString *> *guestDragFiles;
static int proxyFD = -1; // Main thread. A connected proxy, when this viewer is its session process.
static NSString *testMenuPath;
static pid_t hidePID;
static BOOL testMotion;
static NSString *screenshotPrefix;
static BOOL treeMode;
static NSPoint guestOffset; // Host top-left-origin screen point = guest point + this.
static BOOL haveGuestOffset;
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
@property uint32_t order, margin;
@property(strong) id remoteContext;
@property(strong) NSData
    *lastMessage; // The struct SWMWindow, for showing it to a proxy that connects later. Its strings aren't used.
@property(strong) CALayer *remoteLayer;
@property NSPoint guestOrigin;
@property int layer_;
@property(copy) NSString *label;
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
    uint32_t target = self.guestID;
    if (treeMode) {
        NSPoint screen = NSEvent.mouseLocation;
        p = NSMakePoint(screen.x - guestOffset.x,
                        NSScreen.screens.firstObject.frame.size.height - screen.y - guestOffset.y);
        target = 0;
    }
    struct SWMPointer e = {target,
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
    if (!treeMode && p.y < 22 && p.x > 70) {
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
    self.remoteLayer.contents = (__bridge id)image;
    [CATransaction commit];
    CGImageRelease(image);
    [self.window invalidateShadow];
    if (self.remoteLayer)
        [CATransaction flush];
}
@end

@interface Controller : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSMutableDictionary<NSNumber *, GuestWindow *> *windows;
@property int port;
@property NSUInteger framesShown, bytesShown;
@property CFTimeInterval firstFrame;
- (void)sendToProxy:(NSDictionary *)message;
- (void)sendMenu:(NSData *)json;
- (void)pressMenu:(NSString *)path;
- (void)applyTreeWindow:(GuestWindow *)window message:(const struct SWMWindow *)w;
- (void)saveWindow:(GuestWindow *)window;
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

static NSData *lastMenu;

@implementation Controller
- (void)fail:(const char *)why {
    fprintf(stderr, "self-test FAILED: %s\n", why);
    exit(1);
}
- (void)saveWindow:(GuestWindow *)window {
    GuestView *view = (GuestView *)window.contentView;
    if (!pngPath || !view.layer.contents || !treeMode)
        return;
    // Partly transparent pixels are the shadow and any glass: the proof that alpha survived the whole path.
    const uint8_t *pixels = view.pixels.bytes;
    size_t total = (size_t)view.pixelWidth * view.pixelHeight, clear = 0, partial = 0;
    for (size_t i = 0; i < total; i++) {
        uint8_t a = pixels[i * 4 + 3];
        clear += !a;
        partial += a && a != 255;
    }
    NSString *path = [pngPath stringByAppendingFormat:@"-%u.png", window.guestID];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)view.layer.contents];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    printf("window %u layer %d %s: %ux%u, %.0f%% clear, %.1f%% partial alpha, %s\n", window.guestID, view.layer_,
           view.label.UTF8String, view.pixelWidth, view.pixelHeight, total ? 100.0 * clear / total : 0,
           total ? 100.0 * partial / total : 0, path.UTF8String);
    fflush(stdout);
}
// The proxy .app holds the real windows and this process holds their pixels, in a layer it hosts across processes.
- (void)sendToProxy:(NSDictionary *)message {
    if (proxyFD < 0)
        return;
    NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] mutableCopy];
    [line appendBytes:"\n" length:1];
    for (size_t sent = 0; sent < line.length;) {
        ssize_t n = write(proxyFD, (const char *)line.bytes + sent, line.length - sent);
        if (n <= 0)
            return;
        sent += (size_t)n;
    }
}
- (void)showInProxy:(GuestWindow *)window message:(const struct SWMWindow *)w {
    GuestView *view = (GuestView *)window.contentView;
    if (!view.remoteLayer) {
        Class contextClass = NSClassFromString(@"CAContext");
        static int (*connection)(void);
        if (!connection)
            connection = dlsym(dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
                               "SLSMainConnectionID");
        id (*make)(id, SEL, int, NSDictionary *) =
            (void *)[contextClass methodForSelector:NSSelectorFromString(@"contextWithCGSConnection:options:")];
        view.remoteContext = make(contextClass, NSSelectorFromString(@"contextWithCGSConnection:options:"),
                                  connection(), @{@"kCAContextCIFilterBehavior" : @"ignore"});
        view.remoteLayer = [CALayer layer];
        view.remoteLayer.anchorPoint = CGPointZero;
        view.remoteLayer.contentsGravity = kCAGravityResize;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [view.remoteContext setValue:view.remoteLayer forKey:@"layer"];
        [CATransaction commit];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    view.remoteLayer.frame = CGRectMake(0, 0, window.frame.size.width, window.frame.size.height);
    [CATransaction commit];
    [CATransaction flush];
    [self sendToProxy:@{
        @"showSurface" : @{
            @"id" : @(w->window),
            @"contextID" : [view.remoteContext valueForKey:@"contextId"],
            @"x" : @(window.frame.origin.x),
            @"y" : @(window.frame.origin.y),
            @"width" : @(window.frame.size.width),
            @"height" : @(window.frame.size.height),
            @"margin" : @(w->margin),
            @"level" : @(w->layer),
            @"alpha" : @(w->alpha / 65536.0),
            @"order" : @(w->order),
            @"title" : window.title ?: @"",
            @"offsetX" : @(guestOffset.x),
            @"offsetY" : @(guestOffset.y)
        }
    }];
}
// Everything a proxy says is untrusted only in that it arrives on a private socket; what matters here is keeping the
// guest in sync. Its input is already in wire format.
- (void)handleProxyLine:(NSData *)line {
    NSDictionary *event = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![event isKindOfClass:NSDictionary.class])
        return;
    NSDictionary *input = event[@"input"];
    if (input) {
        NSData *bytes = [[NSData alloc] initWithBase64EncodedString:input[@"bytes"] options:0];
        sendToGuest(bytes.bytes, bytes.length);
    } else if (event[@"dragEntered"]) {
        NSDictionary *drag = event[@"dragEntered"];
        [self sendGuestPointer:SWM_MOVE window:drag];
        NSArray<NSString *> *paths = drag[@"paths"];
        for (NSString *path in paths)
            [self sendDocument:path flags:SWD_DRAG | (path == paths.lastObject ? SWD_DRAG_START : 0)];
    } else if (event[@"dragMoved"]) {
        [self sendGuestPointer:SWM_DRAG window:event[@"dragMoved"]];
    } else if (event[@"dragDropped"]) {
        [self sendGuestPointer:SWM_DRAG window:event[@"dragDropped"]];
        [self sendGuestPointer:SWM_UP window:event[@"dragDropped"]];
    } else if (event[@"dragExited"]) {
        uint8_t out[32];
        sendToGuest(out, swm_put_u32_message(out, sizeof(out), SWM_DRAG_CANCEL, 0));
    } else if (event[@"pointerLeftWithButtonDown"]) {
        uint8_t out[32];
        sendToGuest(out, swm_put_u32_message(out, sizeof(out), SWM_DRAG_QUERY, 0));
    } else if (event[@"promiseRequested"]) {
        [self sendGuestFileForPromise:event[@"promiseRequested"]];
    } else if (event[@"openDocuments"]) {
        for (NSString *path in event[@"openDocuments"][@"paths"])
            [self sendDocument:path flags:0];
    } else if (event[@"hello"]) {
        printf("# proxy said hello: %s\n", [event[@"hello"] description].UTF8String);
        proxyPID = [event[@"hello"][@"pid"] intValue];
        fflush(stdout);
        if (lastMenu)
            [self sendMenu:lastMenu];
    } else if (event[@"activated"]) {
        uint8_t out[32];
        sendToGuest(
            out, swm_put_u32_message(out, sizeof(out), SWM_FOCUS, self.windows.allKeys.firstObject.unsignedIntValue));
    } else if (event[@"menuChosen"])
        [self pressMenu:[event[@"menuChosen"][@"path"] componentsJoinedByString:@"/"]];
    else if (event[@"quit"]) {
        if (channelPath && connectionFD >= 0) {
            uint8_t out[32];
            sendToGuest(out, swm_put_u32_message(out, sizeof(out), SWM_QUIT_APP, 0));
            puts("# the proxy asked to quit, so the guest app was asked");
        } else {
            // shortcut: quitting before the guest is up leaves the app to shut the machine down, which waits for its
            // agent.
            [self sendToProxy:@{@"terminate" : @{}}];
            if (channelPath)
                exit(0);
        }
    }
}
// A file of the host's goes into the guest and opens there. It waits if the guest isn't here yet.
- (void)sendDocument:(NSString *)path flags:(uint8_t)flags {
    if (connectionFD < 0) {
        [documentsWaiting addObject:path];
        return;
    }
    static uint32_t nextDocument;
    NSData *file = [NSData dataWithContentsOfFile:path];
    NSData *name = [path.lastPathComponent dataUsingEncoding:NSUTF8StringEncoding];
    if (!file || name.length > 255) {
        printf("# can't send %s: only plain files go to the guest\n", path.UTF8String);
        return;
    }
    uint32_t identifier = ++nextDocument;
    documentPaths[@(identifier)] = path;
    NSMutableData *out = [NSMutableData dataWithLength:SWM_HEADER_SIZE + SWM_DOCUMENT_FIXED + 255 + SWM_DOCUMENT_PIECE];
    NSUInteger offset = 0;
    do {
        uint32_t piece = (uint32_t)MIN(file.length - offset, SWM_DOCUMENT_PIECE);
        size_t prefix = swm_put_document_prefix(out.mutableBytes, identifier, offset + piece == file.length, flags,
                                                name.bytes, (uint16_t)name.length, piece);
        memcpy((uint8_t *)out.mutableBytes + prefix, (const uint8_t *)file.bytes + offset, piece);
        sendToGuest(out.bytes, prefix + piece);
        offset += piece;
    } while (offset < file.length);
    printf("# sent %s to the guest, %lu bytes\n", path.UTF8String, (unsigned long)file.length);
}
// A host drag's point is in the proxy window's points from its top left, shadow included.
- (void)sendGuestPointer:(enum SWMPointerKind)kind window:(NSDictionary *)place {
    GuestView *view = (GuestView *)self.windows[place[@"windowID"]].contentView;
    if (!view)
        return;
    struct SWMPointer pointer = {.kind = (uint8_t)kind, .clicks = 1};
    pointer.x = (int32_t)((view.guestOrigin.x + [place[@"x"] doubleValue] - view.margin) * 16);
    pointer.y = (int32_t)((view.guestOrigin.y + [place[@"y"] doubleValue] - view.margin) * 16);
    uint8_t out[64];
    sendToGuest(out, swm_put_pointer(out, sizeof(out), &pointer));
}
// Finder gave a destination for a promised file. It's only ever a file the guest's drag pasteboard named, matched by
// its name.
- (void)sendGuestFileForPromise:(NSDictionary *)promise {
    NSString *destination = promise[@"destination"], *found = nil;
    for (NSString *path in guestDragFiles)
        if ([path.lastPathComponent isEqual:destination.lastPathComponent])
            found = path;
    NSUInteger index = [promise[@"id"] unsignedIntegerValue];
    if (!found && index >= 1 && index <= guestDragFiles.count)
        found = guestDragFiles[index - 1];
    if (!found) {
        [self
            sendToProxy:@{@"promiseFulfilled" : @{@"id" : promise[@"id"], @"error" : @"The guest has no such file."}}];
        return;
    }
    uint32_t identifier = 0x80000000u | (uint32_t)index;
    documentPaths[@(identifier)] = destination;
    NSData *text = [found dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *out = [NSMutableData dataWithLength:SWM_HEADER_SIZE + 4];
    swm_header(out.mutableBytes, SWM_DRAG_SEND, (uint32_t)text.length + 4);
    swm_w32((uint8_t *)out.mutableBytes + SWM_HEADER_SIZE, identifier);
    [out appendData:text];
    sendToGuest(out.bytes, out.length);
    printf("# asked the guest for %s, to %s\n", found.UTF8String, destination.UTF8String);
}
// The guest is untrusted: it only ever names a document this session sent it, and the file goes where that came from.
- (void)receiveDocument:(const uint8_t *)bytes length:(uint32_t)length {
    if (length < SWM_DOCUMENT_FIXED)
        return;
    NSNumber *identifier = @(swm_r32(bytes));
    size_t offset = SWM_DOCUMENT_FIXED + (size_t)swm_r16(bytes + 6);
    NSString *path = documentPaths[identifier];
    if (!path || offset > length)
        return;
    NSMutableData *coming = documentsComing[identifier];
    if (!coming)
        coming = documentsComing[identifier] = [NSMutableData data];
    [coming appendBytes:bytes + offset length:length - offset];
    if (coming.length > (NSUInteger)1 << 32) {
        [documentsComing removeObjectForKey:identifier];
        return;
    }
    if (bytes[4]) {
        NSError *error = nil;
        BOOL wrote = [coming writeToFile:path options:NSDataWritingAtomic error:&error];
        printf("# the guest saved %s, %lu bytes: %s\n", path.UTF8String, (unsigned long)coming.length,
               wrote ? "written" : error.localizedDescription.UTF8String);
        [documentsComing removeObjectForKey:identifier];
        if (identifier.unsignedIntValue & 0x80000000u) {
            NSNumber *promise = @(identifier.unsignedIntValue & 0x7fffffffu);
            [documentPaths removeObjectForKey:identifier];
            [self sendToProxy:@{
                @"promiseFulfilled" : wrote ? @{@"id" : promise}
                                            : @{@"id" : promise, @"error" : error.localizedDescription}
            }];
        }
    }
    fflush(stdout);
}
- (NSDictionary *)channelRequest:(NSDictionary *)command timeout:(double)timeout {
    NSString *result = [channelPath stringByAppendingPathComponent:@"Result.json"];
    NSString *temporary = [channelPath stringByAppendingPathComponent:@"Request.tmp"];
    unlink(result.fileSystemRepresentation);
    [[NSJSONSerialization dataWithJSONObject:command options:0 error:nil] writeToFile:temporary atomically:NO];
    rename(temporary.fileSystemRepresentation,
           [channelPath stringByAppendingPathComponent:@"Request.json"].fileSystemRepresentation);
    for (double waited = 0; waited < timeout; waited += 0.2) {
        if (getppid() == 1)
            exit(1); // The app has gone, and the machine with it.
        NSData *data = [NSData dataWithContentsOfFile:result];
        NSDictionary *answer = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([answer isKindOfClass:NSDictionary.class])
            return answer;
        usleep(200000);
    }
    return @{@"Error" : @"timed out"};
}
- (NSDictionary *)channelRun:(NSString *)executable arguments:(NSArray<NSString *> *)arguments timeout:(double)timeout {
    return [self channelRequest:@{@"Executable" : executable, @"Arguments" : arguments} timeout:timeout];
}
- (NSString *)stageInGuest:(NSString *)name {
    NSString *transfer = [channelPath stringByAppendingPathComponent:@"Transfer.bin"];
    unlink(transfer.fileSystemRepresentation);
    if (![NSFileManager.defaultManager copyItemAtPath:[guestToolsPath stringByAppendingPathComponent:name]
                                               toPath:transfer
                                                error:nil])
        return nil;
    NSDictionary *staged = [self channelRequest:@{@"Action" : @"stage-probe"} timeout:900];
    NSString *directory = staged[@"Transfer"][@"Directory"];
    return directory ? [directory stringByAppendingPathComponent:@"Transfer.bin"] : nil;
}
- (void)failSession:(NSString *)why {
    printf("# ERROR the session stopped: %s\n", why.UTF8String);
    fflush(stdout);
    dispatch_sync(dispatch_get_main_queue(), ^{
      [self sendToProxy:@{@"terminate" : @{}}];
    });
    exit(1);
}
// What scripts/seamless-try's driver does for a probe, for a real session: waits for the guest, gets it ready and runs
// the app's windows until the app quits. The app shuts the machine down when this process exits.
- (void)driveSession {
    for (double waited = 0; ![NSFileManager.defaultManager fileExistsAtPath:channelPath]; waited += 1) {
        if (waited > 600 || getppid() == 1)
            exit(1);
        sleep(1);
    }
    NSString *windowServer = @"/System/Library/LaunchDaemons/com.apple.WindowServer.plist";
    for (int attempt = 0;; attempt++) {
        if (attempt > 2)
            [self failSession:@"the hook isn't there after a restart"];
        // The agent isn't there until well into the boot, and answers with an error until it is.
        NSDictionary *release = nil;
        for (double started = CFAbsoluteTimeGetCurrent(); ![release[@"ExitCode"] isEqual:@0]; sleep(5)) {
            if (CFAbsoluteTimeGetCurrent() - started > 900)
                [self failSession:[NSString stringWithFormat:@"no answer from the guest: %@", release]];
            release = [self channelRun:@"/usr/bin/uname" arguments:@[ @"-r" ] timeout:900];
        }
        if (![release[@"Stdout"] hasPrefix:@"13."])
            break; // shortcut: only 10.9 has a hook, and the others run by capture alone.
        NSDictionary *found = [self channelRun:@"/usr/bin/grep"
                                     arguments:@[ @"-q", @"seamless-ws-hook", windowServer ]
                                       timeout:60];
        if ([found[@"ExitCode"] isEqual:@0])
            break;
        // Uses a restart, once, since launchd only reads a job's environment when it loads.
        puts("# first session on this machine: installing the hook and restarting the guest");
        fflush(stdout);
        NSString *hook = [self stageInGuest:@"seamless-ws-hook.dylib"];
        NSString *install = [NSString
            stringWithFormat:@"set -e; rm -f /var/tmp/seamless-ws.table; cp \"$1\" /var/tmp/seamless-ws-hook.dylib; "
                             @"chmod 755 /var/tmp/seamless-ws-hook.dylib; "
                             @"/usr/libexec/PlistBuddy -c \"Add :EnvironmentVariables dict\" %1$@ || true; "
                             @"/usr/libexec/PlistBuddy -c \"Add :EnvironmentVariables:DYLD_INSERT_LIBRARIES string "
                             @"/var/tmp/seamless-ws-hook.dylib\" %1$@; /usr/bin/plutil -lint %1$@; "
                             @"(sleep 5; /sbin/reboot) >/dev/null 2>&1 &",
                             windowServer];
        NSDictionary *done =
            hook ? [self channelRun:@"/bin/sh" arguments:@[ @"-c", install, @"sh", hook ] timeout:120] : nil;
        if (![done[@"ExitCode"] isEqual:@0])
            [self failSession:[NSString stringWithFormat:@"couldn't install the hook: %@", done]];
        // The hook makes its table once WindowServer loads it, so this is the new boot, however long the old one took
        // to go.
        for (double started = CFAbsoluteTimeGetCurrent(); ![[self channelRun:@"/bin/test"
                                                                   arguments:@[ @"-e", @"/var/tmp/seamless-ws.table" ]
                                                                     timeout:900][@"ExitCode"] isEqual:@0];
             sleep(5))
            if (CFAbsoluteTimeGetCurrent() - started > 900)
                [self failSession:@"the guest didn't come back from its restart"];
    }
    NSString *tool = [self stageInGuest:@"seamless-guest"];
    NSString *menuTool = [self stageInGuest:@"seamless-integration-guest"];
    if (!tool || !menuTool)
        [self failSession:@"couldn't put the programs in the guest"];
    // 10.9 asks TCC about the responsible process, and from a daemon that's the agent.
    NSMutableString *setup = [NSMutableString
        stringWithString:
            @"mkdir -p /tmp/sg; chmod 755 /tmp/sg; cp \"$1\" /tmp/sg/g; cp \"$2\" /tmp/sg/ig; chmod 755 /tmp/sg/g "
            @"/tmp/sg/ig; /usr/bin/sqlite3 \"/Library/Application Support/com.apple.TCC/TCC.db\" \""];
    for (NSString *client in @[
             @"/private/tmp/sg/ig", @"/tmp/sg/ig", @"/private/tmp/sg/g", @"/usr/bin/sudo", @"/usr/bin/env",
             @"/Library/Application Support/Virtual Intel Mac/GuestTools/opengl-install-bootstrap"
         ])
        [setup appendFormat:@"INSERT OR REPLACE INTO access (service,client,client_type,allowed,prompt_count) VALUES "
                            @"('kTCCServiceAccessibility','%@',1,1,1);",
                            client];
    [setup appendString:@"\"; /usr/bin/killall tccd; sleep 2"];
    [self channelRun:@"/bin/sh" arguments:@[ @"-c", setup, @"sh", tool, menuTool ] timeout:120];
    printf("# running %s in the guest\n", guestAppName.UTF8String);
    fflush(stdout);
    NSDictionary *ran =
        [self channelRun:@"/usr/bin/env"
               arguments:@[
                   @"SEAMLESS_RUN_IN_PLACE=1", @"/tmp/sg/g", @"tree", @"--app", guestAppName, @"--open", @"--session",
                   testSession ? @"--test-badge" : @"--session", @"--hook", @"--menu-tool", @"/tmp/sg/ig", @"--port",
                   @(self.port).stringValue, @"--seconds", @"0"
               ]
                 timeout:1e9];
    printf("# the guest's side ended, exit %s\n%s\n%s\n", [ran[@"ExitCode"] description].UTF8String,
           [ran[@"Stdout"] description].UTF8String, [(ran[@"Stderr"] ?: ran[@"Error"]) description].UTF8String);
    fflush(stdout);
    dispatch_sync(dispatch_get_main_queue(), ^{
      [self sendToProxy:@{@"terminate" : @{}}];
    });
    usleep(200000);
    exit(0);
}
// With nobody at the host: dirty a new document as well as the opened one, quit the way the Dock's menu does, and
// answer the prompt that brings.
- (void)runTestSession {
    void (^after)(double, dispatch_block_t) = ^(double seconds, dispatch_block_t step) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(),
                     step);
    };
    after(10, ^{
      puts("# test: typing in the document");
      [self sendToProxy:@{@"testInput" : @{}}];
    });
    after(20, ^{
      [self pressMenu:@"File/New"];
    });
    after(32, ^{
      puts("# test: typing in the new document");
      [self sendToProxy:@{@"testInput" : @{}}];
    });
    // The file drag, driven as the proxy would report it: a real drop in the guest, then a drag that leaves the window.
    void (^dragStep)(NSString *, NSMutableDictionary *) = ^(NSString *name, NSMutableDictionary *fields) {
      NSNumber *target = nil;
      NSInteger best = NSIntegerMax;
      for (NSNumber *key in self.windows) {
          GuestView *view = (GuestView *)self.windows[key].contentView;
          if (view.layer_ == 0 && view.order < best) {
              best = view.order;
              target = key;
          }
      }
      GuestView *view = (GuestView *)self.windows[target].contentView;
      fields[@"windowID"] = target ?: @0;
      fields[@"x"] = @(self.windows[target].frame.size.width / 2);
      fields[@"y"] = @(self.windows[target].frame.size.height / 2 + view.margin / 2);
      NSData *line = [NSJSONSerialization dataWithJSONObject:@{name : fields} options:0 error:nil];
      printf("# test: %s %s\n", name.UTF8String, fields.description.UTF8String);
      [self handleProxyLine:line];
    };
    if (testDragPath) {
        after(40, ^{
          dragStep(@"dragEntered", [@{@"paths" : @[ testDragPath ]} mutableCopy]);
        });
        after(52, ^{
          dragStep(@"dragDropped", [NSMutableDictionary dictionary]);
        });
        after(60, ^{
          [self takeScreenshot];
          dragStep(@"dragEntered", [@{@"paths" : @[ testDragPath ]} mutableCopy]);
        });
        after(72, ^{
          dragStep(@"dragMoved", [NSMutableDictionary dictionary]);
          [self handleProxyLine:[@"{\"pointerLeftWithButtonDown\":{\"windowID\":0}}"
                                    dataUsingEncoding:NSUTF8StringEncoding]];
        });
        after(82, ^{
          NSString *destination = [testDragOutFolder stringByAppendingPathComponent:testDragPath.lastPathComponent];
          [self handleProxyLine:[NSJSONSerialization dataWithJSONObject:@{
                    @"promiseRequested" : @{@"id" : @1, @"destination" : destination}
                }
                                                                options:0
                                                                  error:nil]];
        });
    }
    double quitAt = testDragPath ? 92 : 44;
    after(quitAt, ^{
      printf("# test: asking the proxy, pid %d, to quit\n", proxyPID);
      [[NSRunningApplication runningApplicationWithProcessIdentifier:proxyPID] terminate];
    });
    after(quitAt + 106, ^{
      puts("# ERROR test: the guest app didn't exit after the answer");
      // Ends the guest's side normally, which brings its log back with it.
      shutdown(connectionFD, SHUT_RDWR);
    });
    after(quitAt + 16, ^{
      NSMutableArray *titles = [NSMutableArray array];
      for (GuestWindow *window in self.windows.allValues)
          [titles addObject:[NSString stringWithFormat:@"%u %@ %gx%g", window.guestID, window.title,
                                                       window.frame.size.width, window.frame.size.height]];
      printf("# test: at the prompt, windows are: %s\n", [titles componentsJoinedByString:@"; "].UTF8String);
      fflush(stdout);
      [self takeScreenshot];
      // Return: the default button, Save.
      for (int down = 1; down >= 0; down--) {
          struct SWMKey key = {.keycode = 36, .down = (uint8_t)down};
          uint8_t out[64];
          sendToGuest(out, swm_put_key(out, sizeof(out), &key));
      }
    });
}
- (void)pressMenu:(NSString *)path {
    NSData *text = [path dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *out = [NSMutableData dataWithLength:SWM_HEADER_SIZE];
    swm_header(out.mutableBytes, SWM_MENU_PRESS, (uint32_t)text.length);
    [out appendData:text];
    sendToGuest(out.bytes, out.length);
    printf("# asked the guest to press %s\n", path.UTF8String);
}
- (void)sendMenu:(NSData *)json {
    lastMenu = json;
    NSArray *items = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![items isKindOfClass:NSArray.class])
        return;
    printf("# menu with %lu top items reached the session\n", (unsigned long)items.count);
    fflush(stdout);
    // The enum's unlabeled payload, as Swift's Codable writes it.
    [self sendToProxy:@{@"setMenuBar" : @{@"_0" : items}}];
}
- (void)listenForProxy {
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, sessionSocketPath.fileSystemRepresentation, sizeof(address.sun_path));
    unlink(address.sun_path);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || chmod(address.sun_path, 0600) ||
        listen(listener, 4)) {
        perror("proxy socket");
        exit(1);
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      for (;;) {
          int client = accept(listener, NULL, NULL);
          if (client < 0)
              continue;
          dispatch_sync(dispatch_get_main_queue(), ^{
            proxyFD = client;
            for (GuestWindow *window in self.windows.allValues)
                if (((GuestView *)window.contentView).lastMessage)
                    [self showInProxy:window message:((GuestView *)window.contentView).lastMessage.bytes];
          });
          NSMutableData *pending = [NSMutableData data];
          uint8_t chunk[65536];
          for (ssize_t n; (n = read(client, chunk, sizeof(chunk))) > 0;) {
              [pending appendBytes:chunk length:(NSUInteger)n];
              const uint8_t *bytes = pending.bytes;
              const uint8_t *newline;
              while ((newline = memchr(pending.bytes, '\n', pending.length))) {
                  NSData *line = [pending subdataWithRange:NSMakeRange(0, (NSUInteger)(newline - bytes))];
                  dispatch_sync(dispatch_get_main_queue(), ^{
                    [self handleProxyLine:line];
                  });
                  [pending replaceBytesInRange:NSMakeRange(0, (NSUInteger)(newline - bytes) + 1)
                                     withBytes:NULL
                                        length:0];
                  bytes = pending.bytes;
              }
          }
          close(client);
          dispatch_sync(dispatch_get_main_queue(), ^{
            proxyFD = -1;
          });
      }
    });
}
- (void)reorderWindows {
    NSArray<GuestWindow *> *sorted =
        [self.windows.allValues sortedArrayUsingComparator:^NSComparisonResult(GuestWindow *a, GuestWindow *b) {
          uint32_t x = ((GuestView *)a.contentView).order, y = ((GuestView *)b.contentView).order;
          return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame;
        }];
    for (GuestWindow *window in sorted)
        [window orderFront:nil];
}
- (void)applyTreeWindow:(GuestWindow *)window message:(const struct SWMWindow *)w {
    GuestView *view = (GuestView *)window.contentView;
    CGFloat primary = NSScreen.screens.firstObject.frame.size.height;
    if (!haveGuestOffset) {
        // Keeps this first window's guest position on the host's screen, near the middle.
        NSRect screen = NSScreen.mainScreen.visibleFrame;
        guestOffset =
            NSMakePoint(NSMidX(screen) - (w->x + w->width / 2.0), primary - NSMidY(screen) - (w->y + w->height / 2.0));
        haveGuestOffset = YES;
    }
    CGFloat side = w->margin, width = w->width + 2 * side, height = w->height + 2 * side;
    NSRect frame =
        NSMakeRect(w->x - side + guestOffset.x, primary - (w->y - side + guestOffset.y) - height, width, height);
    if (!NSEqualRects(window.frame, frame)) {
        [window setFrame:frame display:NO];
        // Only the window itself takes clicks, or its invisible shadow would block whatever is behind it.
        static int (*newRegion)(const CGRect *, void **);
        static int (*eventShape)(int, CGWindowID, void *);
        static int (*connection)(void);
        static dispatch_once_t once;
        dispatch_once(&once, ^{
          void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
          newRegion = dlsym(RTLD_DEFAULT, "CGSNewRegionWithRect");
          eventShape = sky ? dlsym(sky, "SLSSetWindowEventShape") : NULL;
          connection = sky ? dlsym(sky, "SLSMainConnectionID") : NULL;
        });
        void *region = NULL;
        CGRect content = CGRectMake(side, side, w->width, w->height);
        if (newRegion && eventShape && connection && !newRegion(&content, &region))
            eventShape(connection(), (CGWindowID)window.windowNumber, region);
    }
    window.level = w->layer;
    window.hasShadow = NO;
    window.alphaValue = w->alpha / 65536.0;
    view.margin = w->margin;
    view.guestOrigin = NSMakePoint(w->x, w->y);
    view.layer_ = w->layer;
    BOOL reordered = view.order != w->order || !window.visible;
    view.order = w->order;
    view.lastMessage = [NSData dataWithBytes:w length:sizeof(*w)];
    if (sessionSocketPath)
        [self showInProxy:window message:w];
    else if (reordered)
        [self reorderWindows];
}
// What these windows look like together: every window's exact pixels at its position, level and order, over gray. It's
// composed here, not read from the screen, so it works with the host's display asleep.
- (void)takeScreenshot {
    NSArray<GuestWindow *> *sorted =
        [self.windows.allValues sortedArrayUsingComparator:^NSComparisonResult(GuestWindow *a, GuestWindow *b) {
          uint32_t x = ((GuestView *)a.contentView).order, y = ((GuestView *)b.contentView).order;
          if (a.level != b.level)
              return a.level < b.level ? NSOrderedAscending : NSOrderedDescending;
          return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame;
        }];
    NSRect all = NSZeroRect;
    for (GuestWindow *window in sorted)
        all = NSIsEmptyRect(all) ? window.frame : NSUnionRect(all, window.frame);
    static unsigned shot;
    if (!NSIsEmptyRect(all)) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context =
            CGBitmapContextCreate(NULL, (size_t)all.size.width * 2, (size_t)all.size.height * 2, 8, 0, space,
                                  kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
        CGColorSpaceRelease(space);
        CGContextSetGrayFillColor(context, 0.72, 1);
        CGContextFillRect(context, CGRectMake(0, 0, all.size.width * 2, all.size.height * 2));
        CGContextScaleCTM(context, 2, 2);
        for (GuestWindow *window in sorted) {
            CGImageRef image = (__bridge CGImageRef)window.contentView.layer.contents;
            if (!image)
                continue;
            CGContextSetAlpha(context, window.alphaValue);
            CGContextDrawImage(context,
                               CGRectMake(NSMinX(window.frame) - NSMinX(all), NSMinY(window.frame) - NSMinY(all),
                                          window.frame.size.width, window.frame.size.height),
                               image);
        }
        CGImageRef composed = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:composed];
        NSString *path = [screenshotPrefix stringByAppendingFormat:@"-%02u.png", shot++];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
        CGImageRelease(composed);
    }
    [self performSelector:@selector(takeScreenshot) withObject:nil afterDelay:3];
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
    for (GuestWindow *window in self.windows.allValues)
        [self saveWindow:window];
    GuestView *view = (GuestView *)self.windows.allValues.firstObject.contentView;
    if (pngPath && view.layer.contents && !treeMode) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)view.layer.contents];
        BOOL saved = [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:pngPath
                                                                                             atomically:YES];
        printf("# last frame %ux%u %s %s\n", view.pixelWidth, view.pixelHeight, saved ? "saved to" : "NOT saved to",
               pngPath.UTF8String);
    }
    fflush(stdout);
    exit(self.framesShown ? 0 : 1);
}
// Scroll, drag by the title bar and resize by the corner, in the demo's quiet seconds, after its sheet has gone. Sent
// as a host would: guest screen points, moving a step at a time, while the host window follows the guest's.
- (void)sendTestMotion:(GuestWindow *)window {
    GuestView *view = (GuestView *)window.contentView;
    static const double start = 20;
    void (^at)(double, void (^)(void)) = ^(double when, void (^what)(void)) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(when * NSEC_PER_SEC)), dispatch_get_main_queue(), what);
    };
    void (^pointer)(uint8_t, double, double) = ^(uint8_t kind, double x, double y) {
      uint8_t out[64];
      struct SWMPointer e = {
          0, kind, 0, kind == SWM_MOVE || kind == SWM_DRAG ? 0 : 1, (int32_t)(x * 16), (int32_t)(y * 16), 0};
      sendToGuest(out, swm_put_pointer(out, sizeof(out), &e));
    };
    void (^stroke)(double, double, double, double, double) = ^(double when, double x, double y, double dx, double dy) {
      at(when, ^{
        NSPoint o = view.guestOrigin;
        pointer(SWM_MOVE, o.x + x, o.y + y);
        pointer(SWM_DOWN, o.x + x, o.y + y);
        printf("# stroke from %g,%g, window at %g,%g %gx%g\n", o.x + x, o.y + y, o.x, o.y, view.points.width,
               view.points.height);
        for (int i = 1; i <= 12; i++)
            at(i * 0.08, ^{
              pointer(SWM_DRAG, o.x + x + dx * i / 12, o.y + y + dy * i / 12);
            });
        at(13 * 0.08 + 0.2, ^{
          pointer(SWM_UP, o.x + x + dx, o.y + y + dy);
        });
      });
    };
    at(start, ^{
      NSPoint o = view.guestOrigin;
      puts("# scrolling");
      for (int i = 0; i < 40; i++)
          at(i * 0.03, ^{
            uint8_t out[64];
            struct SWMGesture g = {0,
                                   SWG_SCROLL,
                                   i == 0    ? SWP_BEGAN
                                   : i == 39 ? SWP_ENDED
                                             : SWP_CHANGED,
                                   0,
                                   0,
                                   (int32_t)((o.x + 150) * 16),
                                   (int32_t)((o.y + 160) * 16),
                                   0,
                                   -12,
                                   0,
                                   SWG_PRECISE,
                                   0};
            sendToGuest(out, swm_put_gesture(out, sizeof(out), &g));
          });
    });
    stroke(start + 3, 200, 10, 180, 120);
    at(start + 6, ^{
      printf("# after the drag: window at %g,%g %gx%g\n", view.guestOrigin.x, view.guestOrigin.y, view.points.width,
             view.points.height);
    });
    // The bottom right corner, from the top-left origin it still has.
    at(start + 6.1, ^{
      stroke(0, view.points.width - 4, view.points.height - 4, 160, 110);
    });
    at(start + 10, ^{
      printf("# after the resize: window at %g,%g %gx%g\n", view.guestOrigin.x, view.guestOrigin.y, view.points.width,
             view.points.height);
      fflush(stdout);
    });
}
- (void)sendTestInput:(GuestWindow *)window {
    // In a tree the demo's schedule leaves only its first seconds for this, and the window can't be addressed: all
    // events are in guest screen points.
    uint64_t pause = treeMode ? NSEC_PER_SEC : 3 * NSEC_PER_SEC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, pause), dispatch_get_main_queue(), ^{
      uint8_t out[64];
      GuestView *view = (GuestView *)window.contentView;
      uint32_t target = treeMode ? 0 : window.guestID;
      int32_t x = (int32_t)((testClick.x + (treeMode ? view.guestOrigin.x : 0)) * 16),
              y = (int32_t)((testClick.y + (treeMode ? view.guestOrigin.y : 0)) * 16);
      struct SWMPointer move = {target, SWM_MOVE, 0, 0, x, y, 0};
      sendToGuest(out, swm_put_pointer(out, sizeof(out), &move));
      struct SWMPointer down = {target, SWM_DOWN, 0, 1, x, y, 0};
      sendToGuest(out, swm_put_pointer(out, sizeof(out), &down));
      struct SWMPointer up = {target, SWM_UP, 0, 1, x, y, 0};
      sendToGuest(out, swm_put_pointer(out, sizeof(out), &up));
      puts("# sent the test click");
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, pause), dispatch_get_main_queue(), ^{
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
        if (treeMode)
            [self applyTreeWindow:window message:w];
        else if (created)
            [window makeKeyAndOrderFront:nil];
        if (created) {
            if (treeMode && NSApp.keyWindow == nil && !sessionSocketPath)
                [window makeKeyWindow];
            [window makeFirstResponder:view];
            view.label = owner;
            if (selfTest)
                [self selfTestWindow:window];
            static BOOL shooting;
            if (screenshotPrefix && !shooting) {
                shooting = YES;
                [self performSelector:@selector(takeScreenshot) withObject:nil afterDelay:1];
            }
            // With a proxy, it's the proxy's own input view that gets exercised.
            static BOOL proxyTested;
            if (testClick.x >= 0 && sessionSocketPath && !proxyTested) {
                proxyTested = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                  puts("# asked the proxy to click and type");
                  [self sendToProxy:@{@"testInput" : @{}}];
                });
            }
            // Only once: a tree's later windows aren't what the click is aimed at.
            static BOOL tested;
            if (testClick.x >= 0 && !tested && !sessionSocketPath &&
                (!treeMode || [title hasPrefix:@"Seamless demo"])) {
                tested = YES;
                [self sendTestInput:window];
                if (testMotion)
                    [self sendTestMotion:window];
            }
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
        [self saveWindow:window];
        [self.windows removeObjectForKey:@(m->u.window_id)];
        [window close];
        [self sendToProxy:@{@"removeSurface" : @{@"id" : @(m->u.window_id)}}];
    } else if (m->type == SWM_DOCUMENT) {
        [self receiveDocument:m->u.data.bytes length:m->u.data.length];
    } else if (m->type == SWM_DRAG_STATE) {
        NSDictionary *state = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:m->u.data.bytes
                                                                                     length:m->u.data.length]
                                                              options:0
                                                                error:nil];
        NSArray *files = [state isKindOfClass:NSDictionary.class] ? state[@"files"] : nil;
        NSMutableArray<NSString *> *strings = [NSMutableArray array];
        for (id file in [files isKindOfClass:NSArray.class] ? files : @[])
            if ([file isKindOfClass:NSString.class])
                [strings addObject:file];
        guestDragFiles = strings;
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *file in strings)
            [names addObject:file.lastPathComponent];
        printf("# the guest is dragging %lu files\n", (unsigned long)names.count);
        if (names.count)
            [self sendToProxy:@{@"beginDragOut" : @{@"names" : names}}];
    } else if (m->type == SWM_APP_STATE) {
        NSDictionary *state = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:m->u.data.bytes
                                                                                     length:m->u.data.length]
                                                              options:0
                                                                error:nil];
        if ([state isKindOfClass:NSDictionary.class]) {
            NSString *badge = state[@"badge"];
            printf("# app state: %s\n", state.description.UTF8String);
            // Swift's Codable for an Optional payload: an absent value is nil.
            [self sendToProxy:@{
                @"setBadge" : [badge isKindOfClass:NSString.class] && badge.length ? @{@"_0" : badge} : @{}
            }];
            if ([state[@"attention"] isEqual:@YES])
                [self sendToProxy:@{@"requestAttention" : @{@"critical" : @YES}}];
        }
    } else if (m->type == SWM_APP_GONE) {
        puts("# the guest app has exited");
        [self sendToProxy:@{@"terminate" : @{}}];
    } else if (m->type == SWM_MENU) {
        [self sendMenu:[NSData dataWithBytes:m->u.data.bytes length:m->u.data.length]];
        static BOOL pressed, testing;
        if (testSession && !testing) {
            testing = YES;
            [self runTestSession];
        }
        if (testMenuPath && !pressed) {
            pressed = YES;
            // After the proxy's click and key, so the effect can be told from theirs.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
              [self pressMenu:testMenuPath];
            });
        }
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
      NSArray<NSString *> *waiting = [documentsWaiting copy];
      [documentsWaiting removeAllObjects];
      for (NSString *path in waiting)
          [self sendDocument:path flags:0];
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
    socklen_t bound = sizeof(address);
    getsockname(listener, (struct sockaddr *)&address, &bound);
    self.port = ntohs(address.sin_port);
    printf("Listening on 127.0.0.1:%d, which a guest reaches as 10.0.2.2:%d\n", self.port, self.port);
    if (channelPath) {
        documentPaths = [NSMutableDictionary dictionary];
        documentsComing = [NSMutableDictionary dictionary];
        documentsWaiting = [NSMutableArray array];
        [NSThread detachNewThreadSelector:@selector(driveSession) toTarget:self withObject:nil];
    }
    if (sessionSocketPath) {
        [self listenForProxy];
        // shortcut: until a headless launch exists, the VM's own window is hidden, not absent.
        if (hidePID)
            [[NSRunningApplication runningApplicationWithProcessIdentifier:hidePID] hide];
    }
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
    if (!sessionSocketPath)
        [NSApp activateIgnoringOtherApps:YES];
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        // A proxy can go at any moment, and a session's log goes to a file that should be current if this ends badly.
        signal(SIGPIPE, SIG_IGN);
        setvbuf(stdout, NULL, _IOLBF, 0);
        Controller *controller = [Controller new];
        controller.port = 7654;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--self-test"))
                selfTest = YES;
            else if (!strcmp(argv[i], "--screenshots") && i + 1 < argc)
                screenshotPrefix = @(argv[++i]);
            else if (!strcmp(argv[i], "--session-socket") && i + 1 < argc)
                sessionSocketPath = @(argv[++i]);
            else if (!strcmp(argv[i], "--channel") && i + 1 < argc)
                channelPath = @(argv[++i]);
            else if (!strcmp(argv[i], "--guest-app") && i + 1 < argc)
                guestAppName = @(argv[++i]);
            else if (!strcmp(argv[i], "--guest-tools") && i + 1 < argc)
                guestToolsPath = @(argv[++i]);
            else if (!strcmp(argv[i], "--test-session"))
                testSession = YES;
            else if (!strcmp(argv[i], "--test-drag") && i + 2 < argc) {
                testDragPath = @(argv[++i]);
                testDragOutFolder = @(argv[++i]);
            } else if (!strcmp(argv[i], "--test-menu") && i + 1 < argc)
                testMenuPath = @(argv[++i]);
            else if (!strcmp(argv[i], "--hide-pid") && i + 1 < argc)
                hidePID = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--test-motion"))
                testMotion = YES;
            else if (!strcmp(argv[i], "--tree"))
                treeMode = YES;
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
        // As a proxy's session, it's a background process with no window of its own.
        app.activationPolicy =
            sessionSocketPath ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular;
        app.delegate = controller;
        [app run];
    }
    return 0;
}
