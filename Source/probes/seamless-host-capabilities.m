// What a stock, SIP-on host lets a seamless-window host do. Runs unprivileged and needs no TCC grant: it only touches
// windows it creates, and reads pixels back with ScreenCaptureKit's own-process filter.
//
//     xcrun clang -fobjc-arc -O1 -Wno-deprecated-declarations -framework AppKit -framework Metal -framework QuartzCore
//     \
//         -framework ScreenCaptureKit -framework CoreServices -framework Carbon \
//         probes/seamless-host-capabilities.m -o /tmp/seamless-host && /tmp/seamless-host
//
// It briefly shows small windows and activates its own child twice, then restores the previous front app.
// Not tried on purpose: SLSSetUniversalOwner (it could take ownership from the real Dock) and Space switching.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreServices/CoreServices.h>
#import <Carbon/Carbon.h>
#include <dlfcn.h>
#include <stdio.h>

typedef int CID;
static void *sym(const char *name) {
    static void *sky, *ls;
    if (!sky)
        sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!ls)
        ls = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    void *p = dlsym(RTLD_DEFAULT, name);
    if (!p && sky)
        p = dlsym(sky, name);
    if (!p && ls)
        p = dlsym(ls, name);
    return p;
}
#define CALL(type, name, ...) (((type)sym(name))(__VA_ARGS__))
static CID cid(void) { return ((CID (*)(void))sym("SLSMainConnectionID"))(); }

static void spin(double seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static NSDictionary *windowInfo(CGWindowID wid) {
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, wid));
    return list.firstObject;
}

static NSWindow *makeWindow(NSRect frame, NSColor *color) {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.backgroundColor = color;
    w.releasedWhenClosed = NO;
    [w orderFront:nil];
    return w;
}

// Reads its own window back through SCK, which needs no Screen Recording grant for the current process.
static void capturePixel(NSWindow *window, void (^done)(NSColor *)) {
    [SCShareableContent
        getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
          SCWindow *found = nil;
          for (SCWindow *w in content.windows)
              if (w.windowID == (CGWindowID)window.windowNumber)
                  found = w;
          if (!found) {
              fprintf(stderr, "SCK: no own window (%s)\n", error.localizedDescription.UTF8String ?: "none");
              done(nil);
              return;
          }
          SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:found];
          SCStreamConfiguration *config = [SCStreamConfiguration new];
          config.width = 64;
          config.height = 64;
          config.ignoreShadowsSingleWindow = YES;
          [SCScreenshotManager captureImageWithFilter:filter
                                        configuration:config
                                    completionHandler:^(CGImageRef image, NSError *captureError) {
                                      if (!image) {
                                          fprintf(stderr, "SCK capture failed: %s\n",
                                                  captureError.localizedDescription.UTF8String ?: "unknown");
                                          done(nil);
                                          return;
                                      }
                                      NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
                                      done([[rep colorAtX:rep.pixelsWide / 2 y:rep.pixelsHigh / 2]
                                          colorUsingColorSpace:NSColorSpace.sRGBColorSpace]);
                                    }];
        }];
}

// MARK: - Child roles

// A second app: stands in for a per-guest-app proxy. Prints its window number, then waits to be killed.
static int childWindow(NSString *displayName) {
    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize(64, 64)];
    [icon lockFocus];
    [NSColor.systemRedColor set];
    NSRectFill(NSMakeRect(0, 0, 64, 64));
    [icon unlockFocus];
    app.applicationIconImage = icon;
    if (displayName.length && sym("_LSSetApplicationInformationItem")) {
        CFStringRef *key = sym("_kLSDisplayNameKey");
        void *asn = ((void *(*)(void))sym("_LSGetCurrentApplicationASN"))();
        int e = -1;
        if (key && asn)
            e = ((int (*)(int, void *, CFStringRef, CFStringRef, void *))sym("_LSSetApplicationInformationItem"))(
                -2, asn, *key, (__bridge CFStringRef)displayName, NULL);
        printf("rename %d\n", e);
    }
    NSWindow *w = makeWindow(NSMakeRect(420, 80, 200, 120), NSColor.systemBlueColor);
    w.title = @"seamless-child";
    [app finishLaunching];
    printf("wid %ld\n", (long)w.windowNumber);
    fflush(stdout);
    [app run];
    return 0;
}

// Hosts another process's CAContext in this process's window, reports the pixel it sees, keeps running.
static int childHost(uint32_t contextID, NSRect crop) {
    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyAccessory;
    NSWindow *w = makeWindow(NSMakeRect(640, 80, crop.size.width, crop.size.height), NSColor.blackColor);
    NSView *view = w.contentView;
    view.wantsLayer = YES;
    CALayer *host = [NSClassFromString(@"CALayerHost") layer];
    if (!host) {
        puts("hosted no-class");
        return 1;
    }
    [host setValue:@(contextID) forKey:@"contextId"];
    host.anchorPoint = CGPointZero;
    host.frame = view.bounds;
    [view.layer addSublayer:host];
    [CATransaction flush];
    [app finishLaunching];
    void (^__block report)(void) = ^{
      capturePixel(w, ^(NSColor *color) {
        printf("hosted %.2f %.2f %.2f\n", color.redComponent, color.greenComponent, color.blueComponent);
        fflush(stdout);
      });
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), report);
    [NSTimer scheduledTimerWithTimeInterval:1.5
                                    repeats:YES
                                      block:^(NSTimer *t) {
                                        report();
                                      }];
    printf("wid %ld\n", (long)w.windowNumber);
    fflush(stdout);
    [app run];
    return 0;
}

// A minimal app inside a generated bundle: records what LaunchServices hands it.
@interface ProxyDelegate : NSObject <NSApplicationDelegate>
@property NSString *marker;
@end
@implementation ProxyDelegate
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    [[urls.firstObject path] writeToFile:self.marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
@end
static int childProxy(void) {
    NSApplication *app = NSApplication.sharedApplication;
    ProxyDelegate *delegate = [ProxyDelegate new];
    delegate.marker = [NSBundle.mainBundle.bundlePath stringByAppendingString:@".opened"];
    app.delegate = delegate;
    makeWindow(NSMakeRect(860, 80, 160, 100), NSColor.systemGreenColor);
    [app run];
    return 0;
}

// MARK: - Parent

@interface Child : NSObject
@property NSTask *task;
@property NSPipe *output;
@property NSMutableArray<NSString *> *lines;
@end
@implementation Child
@end

static Child *spawnChild(NSArray *arguments) {
    Child *child = [Child new];
    child.task = [NSTask new];
    child.task.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]];
    child.task.arguments = arguments;
    child.output = [NSPipe pipe];
    child.task.standardOutput = child.output;
    child.lines = [NSMutableArray array];
    __weak Child *weak = child;
    child.output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
      NSString *text = [[NSString alloc] initWithData:h.availableData encoding:NSUTF8StringEncoding];
      Child *c = weak;
      @synchronized(c.lines) {
          [c.lines addObjectsFromArray:[text componentsSeparatedByString:@"\n"]];
      }
    };
    [child.task launchAndReturnError:nil];
    return child;
}
static NSString *waitLine(Child *child, NSString *prefix, double timeout) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (end.timeIntervalSinceNow > 0) {
        @synchronized(child.lines) {
            for (NSString *line in child.lines)
                if ([line hasPrefix:prefix])
                    return line;
        }
        spin(0.05);
    }
    return nil;
}
static NSString *shell(NSString *command) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    t.arguments = @[ @"-c", command ];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError = p;
    [t launchAndReturnError:nil];
    NSData *d = [p.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *launchServicesRow(pid_t pid) {
    return shell([NSString stringWithFormat:@"lsappinfo list | grep -B4 -E 'pid = %d ' | grep -oE '^ *[0-9]+\\) "
                                            @"\"[^\"]*\"|bundleID=[^ ]*|type=\"[A-Za-z]+\"' | tr '\\n' ' '",
                                            pid]);
}

static void symbols(void) {
    puts("== Private symbols present on this OS");
    const char *names[] = {"SLSMainConnectionID",
                           "SLSSetWindowLevel",
                           "SLSGetWindowLevel",
                           "SLSSetWindowAlpha",
                           "SLSMoveWindow",
                           "SLSOrderWindow",
                           "SLSSetWindowShape",
                           "SLSSetWindowEventShape",
                           "SLSSetWindowShadowParameters",
                           "SLSSetWindowTags",
                           "SLSCopySpacesForWindows",
                           "SLSMoveWindowsToManagedSpace",
                           "SLSCopyManagedDisplaySpaces",
                           "SLSManagedDisplaySetCurrentSpace",
                           "SLSFindWindowAndOwner",
                           "SLSCopyWindowProperty",
                           "SLSHWCaptureWindowList",
                           "SLSSetUniversalOwner",
                           "CGSSetWindowLevel",
                           "_SLPSSetFrontProcessWithOptions",
                           "SLPSPostEventRecordTo",
                           "_LSSetApplicationInformationItem",
                           "_LSCopyApplicationInformationItem",
                           "_LSGetCurrentApplicationASN",
                           "_LSApplicationCheckIn",
                           "_RegisterApplication",
                           "CGRequestScreenCaptureAccess",
                           "CGWindowListCreateImage"};
    for (size_t i = 0; i < sizeof(names) / sizeof(*names); i++)
        printf("  %-40s %s\n", names[i], sym(names[i]) ? "yes" : "NO");
}

static void windowOps(const char *label, CGWindowID wid) {
    printf("== Window operations on %s window %u (error, then what WindowServer reports)\n", label, wid);
    NSDictionary *before = windowInfo(wid);
    int level = 0;
    int e;
    e = CALL(int (*)(CID, CGWindowID, int), "SLSSetWindowLevel", cid(), wid, 25);
    CALL(int (*)(CID, CGWindowID, int *), "SLSGetWindowLevel", cid(), wid, &level);
    spin(0.1);
    printf("  SetWindowLevel 25      err=%d SLSGetWindowLevel=%d kCGWindowLayer=%s\n", e, level,
           [windowInfo(wid)[@"kCGWindowLayer"] description].UTF8String);
    e = CALL(int (*)(CID, CGWindowID, float), "SLSSetWindowAlpha", cid(), wid, 0.5f);
    spin(0.1);
    printf("  SetWindowAlpha .5      err=%d alpha=%s\n", e,
           [windowInfo(wid)[@"kCGWindowAlpha"] description].UTF8String);
    CGPoint target = CGPointMake(300, 300);
    e = CALL(int (*)(CID, CGWindowID, const CGPoint *), "SLSMoveWindow", cid(), wid, &target);
    spin(0.1);
    printf("  MoveWindow 300,300     err=%d bounds=%s\n", e,
           [[windowInfo(wid)[@"kCGWindowBounds"] description] stringByReplacingOccurrencesOfString:@"\n"
                                                                                        withString:@" "]
               .UTF8String);
    e = CALL(int (*)(CID, CGWindowID, int, CGWindowID), "SLSOrderWindow", cid(), wid, 0, 0);
    spin(0.1);
    printf("  OrderWindow out        err=%d onscreen=%s\n", e,
           [windowInfo(wid)[@"kCGWindowIsOnscreen"] description].UTF8String ?: "(absent)");
    e = CALL(int (*)(CID, CGWindowID, int, CGWindowID), "SLSOrderWindow", cid(), wid, 1, 0);
    e = CALL(int (*)(CID, CGWindowID, float, float, int, int), "SLSSetWindowShadowParameters", cid(), wid, 10.f, 0.5f,
             0, 5);
    printf("  SetShadowParameters    err=%d\n", e);
    uint64_t tags[2] = {1ull << 1, 0};
    e = CALL(int (*)(CID, CGWindowID, uint64_t *, int), "SLSSetWindowTags", cid(), wid, tags, 64);
    printf("  SetWindowTags          err=%d\n", e);
    CFTypeRef title = NULL;
    e = CALL(int (*)(CID, CGWindowID, CFStringRef, CFTypeRef *), "SLSCopyWindowProperty", cid(), wid,
             CFSTR("kCGSWindowTitle"), &title);
    printf("  CopyWindowProperty     err=%d title=%s\n", e,
           title ? [(__bridge id)title description].UTF8String : "(none)");
    NSArray *space = CFBridgingRelease(CALL(CFArrayRef (*)(CID, int, CFArrayRef), "SLSCopySpacesForWindows", cid(), 7,
                                            (__bridge CFArrayRef) @[ @(wid) ]));
    printf("  CopySpacesForWindows   spaces=%lu\n", (unsigned long)space.count);
    if (space.count) {
        // Moving to the Space it's already on proves the permission without visibly moving anything.
        CALL(void (*)(CID, CFArrayRef, uint64_t), "SLSMoveWindowsToManagedSpace", cid(),
             (__bridge CFArrayRef) @[ @(wid) ], [space.firstObject unsignedLongLongValue]);
        printf("  MoveWindowsToManagedSpace (same Space) returned; no error channel\n");
    }
    (void)before;
}

static void hitTest(NSWindow *window) {
    puts("== Event shape on an own window, read back through WindowServer's hit test");
    CGWindowID wid = (CGWindowID)window.windowNumber;
    window.level = NSStatusWindowLevel; // Above anything else at that point on a busy desktop.
    spin(0.1);
    CGRect bounds;
    CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)windowInfo(wid)[@"kCGWindowBounds"], &bounds);
    CGPoint inside = CGPointMake(bounds.origin.x + 20, bounds.origin.y + 20);
    CGPoint hole = CGPointMake(CGRectGetMaxX(bounds) - 20, CGRectGetMaxY(bounds) - 20);
    typedef int (*Find)(CID, int, int, int, const CGPoint *, CGPoint *, CGWindowID *, CID *);
    CGPoint out;
    CGWindowID hitA = 0, hitB = 0;
    CID owner = 0;
    CALL(Find, "SLSFindWindowAndOwner", cid(), 0, 1, 0, &hole, &out, &hitB, &owner);
    printf("  before shaping: corner hit %u\n", hitB);
    void *region = NULL;
    CGRect keep = CGRectMake(0, 0, 60, 60);
    ((int (*)(const CGRect *, void **))sym("CGSNewRegionWithRect"))(&keep, &region);
    int e = CALL(int (*)(CID, CGWindowID, void *), "SLSSetWindowEventShape", cid(), wid, region);
    spin(0.2);
    CALL(Find, "SLSFindWindowAndOwner", cid(), 0, 1, 0, &inside, &out, &hitA, &owner);
    CALL(Find, "SLSFindWindowAndOwner", cid(), 0, 1, 0, &hole, &out, &hitB, &owner);
    printf("  SetWindowEventShape err=%d; window %u: inside hit %u, hole hit %u\n", e, wid, hitA, hitB);
}

static void activation(Child *child, CGWindowID wid) {
    puts("== Activating a child from a non-frontmost parent");
    NSRunningApplication *previous = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSRunningApplication *target =
        [NSRunningApplication runningApplicationWithProcessIdentifier:child.task.processIdentifier];
    printf("  bundleless child in lsappinfo: %s\n", launchServicesRow(child.task.processIdentifier).UTF8String);
    BOOL asked = [target activateWithOptions:0];
    spin(0.5);
    printf("  NSRunningApplication activate: returned %d, frontmost now pid %d\n", asked,
           NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
    if (!target.active) {
        ProcessSerialNumber psn = {0, 0};
        GetProcessForPID(child.task.processIdentifier, &psn);
        int e =
            CALL(int (*)(ProcessSerialNumber *, CGWindowID, int), "_SLPSSetFrontProcessWithOptions", &psn, wid, 0x200);
        spin(0.5);
        printf("  _SLPSSetFrontProcessWithOptions: err=%d, frontmost now pid %d\n", e,
               NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
    }
    printf("  child pid %d; restoring pid %d\n", child.task.processIdentifier, previous.processIdentifier);
    [previous activateWithOptions:0];
    ProcessSerialNumber psn = {0, 0};
    GetProcessForPID(previous.processIdentifier, &psn);
    CALL(int (*)(ProcessSerialNumber *, CGWindowID, int), "_SLPSSetFrontProcessWithOptions", &psn, 0, 0x200);
}

static void generatedBundle(void) {
    puts("== Generated proxy bundle: ad-hoc signed, registered, opened by document");
    NSString *root = [NSHomeDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Application Support/seamless-probe-%d",
                                                                  getpid()]];
    NSString *appPath = [root stringByAppendingPathComponent:@"TextEdit (Mavericks).app"];
    NSString *macos = [appPath stringByAppendingPathComponent:@"Contents/MacOS"];
    [NSFileManager.defaultManager createDirectoryAtPath:macos withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *identifier = [NSString stringWithFormat:@"gold.samhenri.LightClick.probe.guestapp%d", getpid()];
    NSString *extension = [NSString stringWithFormat:@"gsdoc%d", getpid()];
    NSDictionary *plist = @{
        @"CFBundleIdentifier" : identifier,
        @"CFBundleExecutable" : @"proxy",
        @"CFBundleName" : @"TextEdit (Mavericks)",
        @"CFBundlePackageType" : @"APPL",
        @"NSPrincipalClass" : @"NSApplication",
        @"CFBundleDocumentTypes" : @[ @{
            @"CFBundleTypeExtensions" : @[ extension ],
            @"CFBundleTypeName" : @"Guest document",
            @"CFBundleTypeRole" : @"Editor",
            @"LSHandlerRank" : @"Owner"
        } ]
    };
    [plist writeToFile:[appPath stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES];
    NSString *executable = [macos stringByAppendingPathComponent:@"proxy"];
    [NSFileManager.defaultManager copyItemAtPath:NSProcessInfo.processInfo.arguments[0] toPath:executable error:nil];
    NSString *sign = shell([NSString stringWithFormat:@"/usr/bin/codesign --force -s - '%@' 2>&1 | tail -1", appPath]);
    printf("  codesign: %s\n", sign.UTF8String);
    NSURL *url = [NSURL fileURLWithPath:appPath];
    OSStatus registered = LSRegisterURL((__bridge CFURLRef)url, true);
    spin(0.5);
    printf("  LSRegisterURL: %d\n", registered);
    printf("  URLForApplicationWithBundleIdentifier: %s\n",
           [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:identifier].path.UTF8String ?: "(none)");
    NSString *doc = [root stringByAppendingPathComponent:[@"note." stringByAppendingString:extension]];
    [@"x" writeToFile:doc atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSArray *handlers = [NSWorkspace.sharedWorkspace URLsForApplicationsToOpenURL:[NSURL fileURLWithPath:doc]];
    BOOL offered = NO;
    for (NSURL *handler in handlers)
        offered = offered || [handler.path isEqual:appPath];
    printf("  offered as a handler for .%s: %d of %lu handlers\n", extension.UTF8String, offered,
           (unsigned long)handlers.count);
    __block BOOL opened = NO;
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.activates = NO;
    [NSWorkspace.sharedWorkspace
                    openURLs:@[ [NSURL fileURLWithPath:doc] ]
        withApplicationAtURL:url
               configuration:config
           completionHandler:^(NSRunningApplication *app, NSError *error) {
             opened = YES;
             printf("  opened: pid %d bundle %s error %s\n", app.processIdentifier,
                    app.bundleIdentifier.UTF8String ?: "(none)", error.localizedDescription.UTF8String ?: "none");
             fflush(stdout);
           }];
    for (int i = 0; i < 60 && !opened; i++)
        spin(0.1);
    spin(1.5);
    NSString *marker = [appPath stringByAppendingString:@".opened"];
    printf("  proxy received openURLs: %s\n", [NSFileManager.defaultManager fileExistsAtPath:marker] ? "yes" : "NO");
    NSRunningApplication *running =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier].firstObject;
    if (running) {
        printf("  lsappinfo: %s\n", launchServicesRow(running.processIdentifier).UTF8String);
        [running forceTerminate];
    }
    spin(0.3);
    LSRegisterURL((__bridge CFURLRef)url, false);
    shell([NSString stringWithFormat:@"/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                                     @"LaunchServices.framework/Support/lsregister -u '%@'",
                                     appPath]);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static void fill(id<CAMetalDrawable> drawable, id<MTLCommandQueue> queue, double r, double g, double b,
                 void (^presented)(CFTimeInterval)) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1);
    id<MTLCommandBuffer> command = [queue commandBuffer];
    [[command renderCommandEncoderWithDescriptor:pass] endEncoding];
    if (presented)
        [drawable addPresentedHandler:^(id<MTLDrawable> d) {
          presented(d.presentedTime);
        }];
    [command presentDrawable:drawable];
    [command commit];
}

// CAContext in this process, CALayerHost in a child window: the proxy holds the NSWindow and Dock tile while another
// process owns the pixels. Two contents-rect crops of one IOSurface prove a single shared frame can feed many windows.
static void hostedLayers(void) {
    puts("== Cross-process layer hosting (CAContext to CALayerHost), no entitlement");
    Class contextClass = NSClassFromString(@"CAContext");
    id (*make)(id, SEL, CID, NSDictionary *) =
        (void *)[contextClass methodForSelector:NSSelectorFromString(@"contextWithCGSConnection:options:")];
    id context = make(contextClass, NSSelectorFromString(@"contextWithCGSConnection:options:"), cid(),
                      @{@"kCAContextCIFilterBehavior" : @"ignore"});
    uint32_t contextID = [[context valueForKey:@"contextId"] unsignedIntValue];
    printf("  CAContext id %u\n", contextID);

    NSDictionary *properties = @{
        (id)kIOSurfaceWidth : @640,
        (id)kIOSurfaceHeight : @360,
        (id)kIOSurfaceBytesPerElement : @4,
        (id)kIOSurfacePixelFormat : @(0x42475241)
    };
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    IOSurfaceLock(surface, 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(surface);
    size_t stride = IOSurfaceGetBytesPerRow(surface);
    for (int y = 0; y < 360; y++)
        for (int x = 0; x < 640; x++) {
            uint8_t *p = base + y * stride + x * 4;
            int magenta = x >= 320; // Left half green, right half magenta.
            p[0] = magenta ? 255 : 0;
            p[1] = magenta ? 0 : 255;
            p[2] = magenta ? 255 : 0;
            p[3] = 255;
        }
    IOSurfaceUnlock(surface, 0, NULL);

    CALayer *root = [CALayer layer];
    root.anchorPoint = CGPointZero;
    root.frame = CGRectMake(0, 0, 320, 360);
    root.contents = (__bridge id)surface;
    root.contentsRect = CGRectMake(0.5, 0, 0.5, 1); // The right half, as one guest window's crop.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [context setValue:root forKey:@"layer"];
    [CATransaction commit];
    [CATransaction flush];

    Child *host = spawnChild(@[ @"--child-host", @(contextID).stringValue, @"320", @"360" ]);
    NSString *line = waitLine(host, @"hosted", 12);
    printf("  child sees crop (want magenta 1 0 1 ~): %s\n", line.UTF8String ?: "NO REPORT");
    NSString *widLine = waitLine(host, @"wid", 1);

    // Same hosted path, now a live CAMetalLayer: does a hosted layer present at the panel's full rate?
    puts("== Present rate of a CAMetalLayer, hosted cross-process vs. this process's own window");
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    printf("  panel maximumFramesPerSecond %ld, %s\n", (long)NSScreen.mainScreen.maximumFramesPerSecond,
           device.name.UTF8String);
    for (int hosted = 1; hosted >= 0; hosted--) {
        CAMetalLayer *metal = [CAMetalLayer layer];
        metal.device = device;
        metal.pixelFormat = MTLPixelFormatBGRA8Unorm;
        metal.anchorPoint = CGPointZero;
        metal.frame = CGRectMake(0, 0, 320, 360);
        metal.drawableSize = CGSizeMake(320, 360);
        metal.opaque = YES;
        NSWindow *own = nil;
        if (hosted) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [root addSublayer:metal];
            [CATransaction commit];
        } else {
            own = makeWindow(NSMakeRect(1000, 80, 320, 360), NSColor.blackColor);
            own.contentView.wantsLayer = YES;
            [own.contentView.layer addSublayer:metal];
        }
        [CATransaction flush];
        spin(0.2);
        NSMutableArray<NSNumber *> *stamps = [NSMutableArray array];
        double start = CACurrentMediaTime();
        __block BOOL running = YES;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
          int frame = 0;
          while (CACurrentMediaTime() - start < 3) {
              @autoreleasepool {
                  id<CAMetalDrawable> d = metal.nextDrawable;
                  if (!d)
                      continue;
                  fill(d, queue, frame++ & 1, 0.2, 0.2, ^(CFTimeInterval when) {
                    if (when > 0)
                        @synchronized(stamps) {
                            [stamps addObject:@(when)];
                        }
                  });
              }
          }
          running = NO;
        });
        while (running)
            spin(0.05);
        spin(0.2);
        NSArray *sorted = [stamps sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray *gaps = [NSMutableArray array];
        for (NSUInteger i = 1; i < sorted.count; i++)
            [gaps addObject:@(([sorted[i] doubleValue] - [sorted[i - 1] doubleValue]) * 1000)];
        [gaps sortUsingSelector:@selector(compare:)];
        double median = gaps.count ? [gaps[gaps.count / 2] doubleValue] : 0,
               p99 = gaps.count ? [gaps[gaps.count * 99 / 100] doubleValue] : 0;
        printf("  %s: %lu frames presented in 3 s, gap median %.2f ms, p99 %.2f ms\n", hosted ? "hosted " : "in-proc",
               (unsigned long)sorted.count, median, p99);
        [metal removeFromSuperlayer];
        [own close];
    }
    (void)widLine;
    [host.task terminate];
    CFRelease(surface);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSBundle *main = NSBundle.mainBundle;
        if ([main.bundleIdentifier hasPrefix:@"gold.samhenri.LightClick.probe.guestapp"])
            return childProxy();
        if (argc >= 2 && !strcmp(argv[1], "--child-window"))
            return childWindow(argc > 2 ? @(argv[2]) : nil);
        if (argc >= 5 && !strcmp(argv[1], "--child-host"))
            return childHost((uint32_t)atoi(argv[2]), NSMakeRect(0, 0, atoi(argv[3]), atoi(argv[4])));

        setbuf(stdout, NULL);
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app finishLaunching];
        printf("macOS %s, SIP: %s\n", NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String,
               shell(@"csrutil status").UTF8String);
        printf("AXIsProcessTrusted %d, screen capture preflight %d\n", AXIsProcessTrusted(),
               CGPreflightScreenCaptureAccess());
        symbols();

        NSWindow *own = makeWindow(NSMakeRect(200, 80, 200, 120), NSColor.systemOrangeColor);
        spin(0.2);
        windowOps("this process's own", (CGWindowID)own.windowNumber);
        [own orderFront:nil];
        own.alphaValue = 1;
        hitTest(own);

        Child *child = spawnChild(@[ @"--child-window", @"TextEdit (Mavericks)" ]);
        NSString *line = waitLine(child, @"wid ", 8);
        CGWindowID wid = (CGWindowID)[line substringFromIndex:4].intValue;
        printf("Child rename line: %s\n", waitLine(child, @"rename", 1).UTF8String ?: "(none)");
        spin(0.3);
        windowOps("ANOTHER process's", wid);
        activation(child, wid);
        [child.task terminate];

        generatedBundle();
        hostedLayers();
        puts("done");
    }
    return 0;
}
