// The guest half of seamless integration: app discovery, the menu through Accessibility, reading badges and attention,
// and both directions of drag and drop. It imports nothing newer than 10.9, and also runs on this host under Rosetta,
// which is how scripts/test-seamless-integration checks the drags with nothing booted. See
// probes/seamless-integration.md.
//
//     seamless-integration-guest apps                       JSON array of installed apps.
//     seamless-integration-guest icon --path APP            The app's icon file, in base64.
//     seamless-integration-guest menu --app NAME [--top T]  The app's menu as JSON, for GuestMenuItem.
//     seamless-integration-guest menu-watch --app NAME --seconds N   Prints the app's menu notifications as they come.
//     seamless-integration-guest extras --app SystemUIServer  The menu extras.
//     seamless-integration-guest press --app NAME --path A/B   AXPress on that menu item.
//     seamless-integration-guest title --app NAME           The app's windows: titles and frames.
//     seamless-integration-guest open-file --path P [--with APP]   Opens a file or app, as Finder would.
//     seamless-integration-guest badge-self [--seconds N]   Sets its own badge and asks for attention, to read from
//     outside. seamless-integration-guest status --pid PID           What LaunchServices says about that app's badge
//     and attention. seamless-integration-guest screen                     The main display's size.
//     seamless-integration-guest drag-in --file F [--backend ns|coredrag] [--no-image] [--drive X,Y]
//     seamless-integration-guest drag-watch [--seconds N]   Reports each change of the drag pasteboard.
//     seamless-integration-guest drag-read                  Reports the drag pasteboard now, as a line of JSON.
//     seamless-integration-guest drag-sink [--seconds N] [--promises DIR]   Takes any drop, as a guest drag leaves a
//     window.
//
// Add --session to run a command in the console user's session, as scripts/seamless-integration-try does from the guest
// agent, which is root in the system session.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#include <copyfile.h>
#include "seamless-session-join.h"
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>

// Private CoreDrag, with the shapes SSDragHelper calls on 10.9 and 10.14.
typedef struct OpaqueCoreDrag *CoreDragRef;
typedef int CGSConnectionID;
extern CGSConnectionID CGSMainConnectionID(void);
extern OSStatus CoreDragRegisterClient(CGSConnectionID connection);
extern OSStatus CoreDragCreateWithPasteboardRef(PasteboardRef pasteboard, CoreDragRef *drag);
extern OSStatus CoreDragSetDropActions(CoreDragRef drag, UInt32 actions);
extern OSStatus CoreDragSetAllowableActions(CoreDragRef drag, UInt32 actions, Boolean isLocal);
extern OSStatus CoreDragSetInputProc(CoreDragRef drag, OSStatus (*proc)(void), void *context);
extern OSStatus CoreDragStartDragging(CoreDragRef drag, int flags, int reserved, CGPoint origin);
extern CoreDragRef CoreDragGetCurrentDrag(void);
extern OSStatus CoreDragCancelDrag(CoreDragRef drag);
extern OSStatus CoreDragGetDragWindow(CoreDragRef drag, CGWindowID *window);

static double now(void) { return [NSDate timeIntervalSinceReferenceDate]; }

static const char *option(int argc, char **argv, const char *name, const char *fallback) {
    for (int i = 1; i + 1 < argc; i++)
        if (!strcmp(argv[i], name))
            return argv[i + 1];
    return fallback;
}

static BOOL flag(int argc, char **argv, const char *name) {
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], name))
            return YES;
    return NO;
}

static void printJSON(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if (data) {
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
    }
    fflush(stdout);
}

// MARK: Session

static int darwinMajor(void) {
    char release[32] = "";
    size_t size = sizeof(release);
    sysctlbyname("kern.osrelease", release, &size, NULL, 0);
    return atoi(release);
}

// The agent runs programs as root in the system session, which can't reach WindowServer. This runs the same arguments
// again as the console user, in their session, from a copy they can read: asuser from 10.10, bsexec into Finder before.
static int runInSession(int argc, char **argv) {
    struct stat console = {0};
    int finder = 0;
    for (double start = now(); now() - start < 300 && !finder; sleep(finder ? 0 : 2)) {
        if (stat("/dev/console", &console) || console.st_uid < 501)
            continue;
        char command[64];
        snprintf(command, sizeof(command), "/usr/bin/pgrep -x -U %u Finder", console.st_uid);
        FILE *pipe = popen(command, "r");
        if (pipe) {
            if (fscanf(pipe, "%d", &finder) != 1)
                finder = 0;
            pclose(pipe);
        }
    }
    if (!finder) {
        puts("# ERROR no one logged in to the desktop after 300 s");
        return 75;
    }
    // A fixed path, since the Accessibility grant in TCC.db names it.
    char self[4096], account[32], target[16];
    uint32_t length = sizeof(self);
    const char *directory = "/private/tmp/lc-seamless", *copy = "/private/tmp/lc-seamless/seamless-integration-guest";
    // The user's run of this tool writes its drag image and promises here, in a throwaway clone.
    mkdir(directory, 0777);
    chmod(directory, 0777);
    if (_NSGetExecutablePath(self, &length))
        return 74;
    if (strcmp(self, copy)) {
        unlink(copy);
        if (copyfile(self, copy, NULL, COPYFILE_DATA) || chmod(copy, 0755))
            return 74;
    }
    snprintf(account, sizeof(account), "#%u", console.st_uid);
    int modern = darwinMajor() >= 14;
    snprintf(target, sizeof(target), "%d", modern ? (int)console.st_uid : finder);
    char *arguments[64] = {"/bin/launchctl",
                           modern ? "asuser" : "bsexec",
                           target,
                           "/usr/bin/sudo",
                           "-S",
                           "-u",
                           account,
                           "/usr/bin/env",
                           "-i",
                           "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                           (char *)copy};
    int n = 11;
    for (int i = 1; i < argc && n < 62; i++)
        if (strcmp(argv[i], "--session"))
            arguments[n++] = argv[i];
    arguments[n] = NULL;
    fflush(NULL);
    pid_t child = fork();
    if (child == 0) {
        freopen("/dev/null", "r", stdin);
        if (modern) {
            execv(arguments[0], arguments);
        } else if (join_session_of(finder)) {
            printf("# ERROR couldn't join the session of Finder, pid %d: %s\n", finder, strerror(errno));
            fflush(stdout);
        } else {
            // Past launchctl: see seamless-session-join.h.
            execv(arguments[3], arguments + 3);
        }
        _exit(127);
    }
    int status = 1;
    if (child < 0 || waitpid(child, &status, 0) < 0)
        status = 1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

// MARK: Apps

static NSDictionary *describeDocumentType(NSDictionary *type) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if ([type[@"CFBundleTypeName"] isKindOfClass:NSString.class])
        result[@"name"] = type[@"CFBundleTypeName"];
    if ([type[@"CFBundleTypeRole"] isKindOfClass:NSString.class])
        result[@"role"] = type[@"CFBundleTypeRole"];
    result[@"contentTypes"] =
        [type[@"LSItemContentTypes"] isKindOfClass:NSArray.class] ? type[@"LSItemContentTypes"] : @[];
    result[@"extensions"] =
        [type[@"CFBundleTypeExtensions"] isKindOfClass:NSArray.class] ? type[@"CFBundleTypeExtensions"] : @[];
    result[@"osTypes"] =
        [type[@"CFBundleTypeOSTypes"] isKindOfClass:NSArray.class] ? type[@"CFBundleTypeOSTypes"] : @[];
    return result;
}

static int listApps(void) {
    double start = now();
    NSMutableArray *apps = [NSMutableArray array];
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *folder in
         @[ @"/Applications", @"/Applications/Utilities", @"/System/Library/CoreServices/Applications" ])
        for (NSString *name in
             [[manager contentsOfDirectoryAtPath:folder error:NULL] sortedArrayUsingSelector:@selector(compare:)]) {
            if (![name hasSuffix:@".app"])
                continue;
            NSString *path = [folder stringByAppendingPathComponent:name];
            NSDictionary *info = [NSDictionary
                dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
            NSString *identifier = info[@"CFBundleIdentifier"];
            if (![identifier isKindOfClass:NSString.class])
                continue;
            NSMutableDictionary *app = [NSMutableDictionary dictionary];
            app[@"bundleIdentifier"] = identifier;
            app[@"name"] = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: name.stringByDeletingPathExtension;
            app[@"guestPath"] = path;
            if (info[@"CFBundleShortVersionString"])
                app[@"version"] = info[@"CFBundleShortVersionString"];
            if (info[@"CFBundleIconFile"])
                app[@"iconFile"] = info[@"CFBundleIconFile"];
            if (info[@"LSMinimumSystemVersion"])
                app[@"minimumSystemVersion"] = info[@"LSMinimumSystemVersion"];
            NSMutableArray *types = [NSMutableArray array];
            for (NSDictionary *type in info[@"CFBundleDocumentTypes"])
                if ([type isKindOfClass:NSDictionary.class])
                    [types addObject:describeDocumentType(type)];
            app[@"documentTypes"] = types;
            NSMutableArray *schemes = [NSMutableArray array];
            for (NSDictionary *type in info[@"CFBundleURLTypes"])
                if ([type isKindOfClass:NSDictionary.class] &&
                    [type[@"CFBundleURLSchemes"] isKindOfClass:NSArray.class])
                    [schemes addObjectsFromArray:type[@"CFBundleURLSchemes"]];
            app[@"urlSchemes"] = schemes;
            [apps addObject:app];
        }
    printJSON(apps);
    printf("# apps %lu in %.0f ms\n", (unsigned long)apps.count, (now() - start) * 1000);
    return 0;
}

static int printIcon(const char *path) {
    NSString *app = @(path);
    NSDictionary *info =
        [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *icon = info[@"CFBundleIconFile"];
    if (![icon isKindOfClass:NSString.class])
        return 2;
    if (!icon.pathExtension.length)
        icon = [icon stringByAppendingPathExtension:@"icns"];
    NSData *data = [NSData dataWithContentsOfFile:[[app stringByAppendingPathComponent:@"Contents/Resources"]
                                                      stringByAppendingPathComponent:icon]];
    if (!data)
        return 3;
    puts([data base64EncodedStringWithOptions:0].UTF8String);
    return 0;
}

// MARK: Accessibility

static NSRunningApplication *runningApp(const char *name) {
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications)
        if ([app.localizedName isEqual:@(name)])
            return app;
    return nil;
}

static id attribute(AXUIElementRef element, CFStringRef name) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess || !value)
        return nil;
    return (__bridge_transfer id)value;
}

static NSArray *axChildren(AXUIElementRef element) {
    NSArray *children = attribute(element, kAXChildrenAttribute);
    return [children isKindOfClass:NSArray.class] ? children : @[];
}

static NSUInteger menuItems;

static NSDictionary *describeMenuItem(AXUIElementRef item) {
    menuItems++;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSString *title = attribute(item, kAXTitleAttribute);
    result[@"title"] = [title isKindOfClass:NSString.class] ? title : @"";
    NSNumber *enabled = attribute(item, kAXEnabledAttribute);
    result[@"isEnabled"] = enabled ?: @YES;
    NSString *mark = attribute(item, CFSTR("AXMenuItemMarkChar"));
    if ([mark isKindOfClass:NSString.class] && mark.length)
        result[@"mark"] = mark;
    NSString *key = attribute(item, CFSTR("AXMenuItemCmdChar"));
    if ([key isKindOfClass:NSString.class] && key.length)
        result[@"key"] = key;
    NSNumber *virtualKey = attribute(item, CFSTR("AXMenuItemCmdVirtualKey"));
    if ([virtualKey isKindOfClass:NSNumber.class])
        result[@"virtualKey"] = virtualKey;
    NSNumber *modifiers = attribute(item, CFSTR("AXMenuItemCmdModifiers"));
    result[@"modifiers"] = [modifiers isKindOfClass:NSNumber.class] ? modifiers : @0;
    // Every item has one; on an alternate it names the item replaced while Option is held.
    id primary = attribute(item, CFSTR("AXMenuItemPrimaryUIElement"));
    if (primary && !CFEqual((__bridge CFTypeRef)primary, item))
        result[@"isAlternate"] = @YES;
    for (id child in axChildren(item))
        if ([attribute((__bridge AXUIElementRef)child, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXMenuRole]) {
            NSMutableArray *children = [NSMutableArray array];
            for (id entry in axChildren((__bridge AXUIElementRef)child))
                [children addObject:describeMenuItem((__bridge AXUIElementRef)entry)];
            result[@"children"] = children;
        }
    return result;
}

// `only` reads one top-level menu, which is what opening it needs, and is far cheaper than the whole bar.
static int dumpMenu(const char *name, const char *only) {
    NSRunningApplication *app = runningApp(name);
    printf("# trusted %d, %s pid %d\n", AXIsProcessTrusted(), name, app.processIdentifier);
    if (!app)
        return 2;
    AXUIElementRef element = AXUIElementCreateApplication(app.processIdentifier);
    double start = now();
    id bar = attribute(element, kAXMenuBarAttribute);
    if (!bar) {
        puts("# ERROR no menu bar through Accessibility");
        CFRelease(element);
        return 3;
    }
    NSMutableArray *items = [NSMutableArray array];
    for (id child in axChildren((__bridge AXUIElementRef)bar))
        if (!only || [attribute((__bridge AXUIElementRef)child, kAXTitleAttribute) isEqual:@(only)])
            [items addObject:describeMenuItem((__bridge AXUIElementRef)child)];
    double elapsed = (now() - start) * 1000;
    printJSON(items);
    printf("# menu_read_ms %.1f items %lu\n", elapsed, (unsigned long)menuItems);
    CFRelease(element);
    return 0;
}

static void menuNotification(AXObserverRef observer, AXUIElementRef element, CFStringRef name, void *context) {
    printf("%.3f %s title=%s\n", now(), [(__bridge NSString *)name UTF8String],
           [[attribute(element, kAXTitleAttribute) description] UTF8String]);
    fflush(stdout);
}

// Which Accessibility notifications an app sends about its menus, since a mirror's cache depends on them.
static int watchMenu(const char *name, double seconds) {
    NSRunningApplication *app = runningApp(name);
    if (!app)
        return 2;
    AXObserverRef observer = NULL;
    if (AXObserverCreate(app.processIdentifier, menuNotification, &observer) != kAXErrorSuccess)
        return 3;
    AXUIElementRef element = AXUIElementCreateApplication(app.processIdentifier);
    NSArray *names = @[
        (__bridge id)kAXMenuOpenedNotification, (__bridge id)kAXMenuClosedNotification,
        (__bridge id)kAXMenuItemSelectedNotification, (__bridge id)kAXFocusedWindowChangedNotification,
        (__bridge id)kAXMainWindowChangedNotification, (__bridge id)kAXFocusedUIElementChangedNotification,
        (__bridge id)kAXTitleChangedNotification, (__bridge id)kAXCreatedNotification,
        (__bridge id)kAXValueChangedNotification, (__bridge id)kAXApplicationActivatedNotification
    ];
    for (NSString *notification in names) {
        AXError error = AXObserverAddNotification(observer, element, (__bridge CFStringRef)notification, NULL);
        printf("# %s %d\n", notification.UTF8String, error);
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), kCFRunLoopDefaultMode);
    puts("ready");
    fflush(stdout);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    CFRelease(element);
    return 0;
}

// Guest menu extras, which an app or SystemUIServer lists apart from its menu bar.
static int dumpExtras(const char *name) {
    NSRunningApplication *app = runningApp(name);
    if (!app)
        return 2;
    AXUIElementRef element = AXUIElementCreateApplication(app.processIdentifier);
    id bar = attribute(element, CFSTR("AXExtrasMenuBar"));
    NSMutableArray *titles = [NSMutableArray array];
    for (id child in axChildren((__bridge AXUIElementRef)bar))
        [titles addObject:attribute((__bridge AXUIElementRef)child, kAXDescriptionAttribute) ?: attribute((__bridge AXUIElementRef)child, kAXTitleAttribute) ?: @""];
    printJSON(titles);
    CFRelease(element);
    return bar ? 0 : 3;
}

static int pressMenu(const char *name, const char *path) {
    NSRunningApplication *app = runningApp(name);
    if (!app)
        return 2;
    AXUIElementRef element = AXUIElementCreateApplication(app.processIdentifier);
    id current = attribute(element, kAXMenuBarAttribute);
    for (NSString *part in [@(path) componentsSeparatedByString:@"/"]) {
        id next = nil;
        for (id child in axChildren((__bridge AXUIElementRef)current)) {
            id candidate = child;
            if ([attribute((__bridge AXUIElementRef)candidate, kAXRoleAttribute)
                    isEqual:(__bridge NSString *)kAXMenuRole])
                for (id item in axChildren((__bridge AXUIElementRef)candidate))
                    if ([attribute((__bridge AXUIElementRef)item, kAXTitleAttribute) isEqual:part])
                        next = item;
            if ([attribute((__bridge AXUIElementRef)candidate, kAXTitleAttribute) isEqual:part])
                next = candidate;
        }
        if (!next) {
            printf("# ERROR no menu item %s\n", part.UTF8String);
            CFRelease(element);
            return 3;
        }
        current = next;
    }
    double start = now();
    AXError error = AXUIElementPerformAction((__bridge AXUIElementRef)current, kAXPressAction);
    printf("# press error %d in %.1f ms\n", error, (now() - start) * 1000);
    CFRelease(element);
    return error == kAXErrorSuccess ? 0 : 4;
}

static int printWindows(const char *name) {
    NSRunningApplication *app = runningApp(name);
    if (!app)
        return 2;
    AXUIElementRef element = AXUIElementCreateApplication(app.processIdentifier);
    NSMutableArray *windows = [NSMutableArray array];
    for (id window in attribute(element, kAXWindowsAttribute)) {
        AXUIElementRef reference = (__bridge AXUIElementRef)window;
        CGPoint position = CGPointZero;
        CGSize size = CGSizeZero;
        id positionValue = attribute(reference, kAXPositionAttribute),
           sizeValue = attribute(reference, kAXSizeAttribute);
        if (positionValue)
            AXValueGetValue((__bridge AXValueRef)positionValue, kAXValueCGPointType, &position);
        if (sizeValue)
            AXValueGetValue((__bridge AXValueRef)sizeValue, kAXValueCGSizeType, &size);
        [windows addObject:@{
            @"title" : attribute(reference, kAXTitleAttribute) ?: @"",
            @"x" : @(position.x),
            @"y" : @(position.y),
            @"w" : @(size.width),
            @"h" : @(size.height)
        }];
    }
    printJSON(windows);
    CFRelease(element);
    return 0;
}

static int openFile(const char *path, const char *with) {
    NSString *file = @(path);
    BOOL opened = with ? [NSWorkspace.sharedWorkspace openFile:file withApplication:@(with)]
                       : [NSWorkspace.sharedWorkspace openFile:file];
    printf("opened %d\n", opened);
    return opened ? 0 : 3;
}

// MARK: Badge and attention

static int badgeSelf(double seconds) {
    [NSApplication sharedApplication];
    NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
    NSApp.dockTile.badgeLabel = @"7";
    // Requires not being frontmost, which is true of a tool started from the agent.
    NSInteger request = [NSApp requestUserAttention:NSCriticalRequest];
    printf("ready pid %d request %ld\n", getpid(), (long)request);
    fflush(stdout);
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
    return 0;
}

static int status(int pid) {
    char command[128];
    snprintf(command, sizeof(command), "/usr/bin/lsappinfo info -only StatusLabel -app pid=%d", pid);
    double start = now();
    int result = system(command);
    printf("# lsappinfo_ms %.0f\n", (now() - start) * 1000);
    fflush(stdout);
    snprintf(command, sizeof(command),
             "/usr/bin/lsappinfo info -all -app pid=%d | /usr/bin/grep -i -E 'attention|bounce'", pid);
    system(command);
    return result;
}

// MARK: Drag in

@interface Shield : NSWindow
@property(copy) void (^onMouseDown)(NSEvent *event);
@end
@implementation Shield
- (BOOL)canBecomeKeyWindow {
    return YES;
}
- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSLeftMouseDown && self.onMouseDown) {
        void (^handler)(NSEvent *) = self.onMouseDown;
        self.onMouseDown = nil;
        handler(event);
        return;
    }
    [super sendEvent:event];
}
@end

@interface DragSource : NSObject <NSDraggingSource>
@end
@implementation DragSource
- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationCopy | NSDragOperationGeneric | NSDragOperationLink;
}
- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation {
    printf("drag_ended at %.0f,%.0f operation %lu\n", point.x, point.y, (unsigned long)operation);
    fflush(stdout);
    exit(operation ? 0 : 5);
}
@end

// Covers every screen, so the mouse down that starts the drag reaches this tool and clicks nothing else. This is what
// SSDragHelper's CreateShieldWindows does, at the same level, closing them before dragging so they don't take the drop.
static NSArray *makeShields(void (^onMouseDown)(NSEvent *)) {
    NSMutableArray *shields = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        Shield *shield = [[Shield alloc] initWithContentRect:screen.frame
                                                   styleMask:NSBorderlessWindowMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
        shield.backgroundColor = NSColor.whiteColor;
        shield.alphaValue = 0.01;
        shield.opaque = NO;
        // Explicitly: a nearly clear window passes clicks through otherwise.
        shield.ignoresMouseEvents = NO;
        shield.releasedWhenClosed = NO;
        shield.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
        shield.level = CGWindowLevelForKey(kCGStatusWindowLevelKey);
        shield.onMouseDown = onMouseDown;
        [shield orderFrontRegardless];
        [shields addObject:shield];
    }
    return shields;
}

static volatile sig_atomic_t cancelRequested;
static void requestCancel(int signal) { cancelRequested = signal != 0; }
static OSStatus coreDragInput(void) {
    if (cancelRequested)
        CoreDragCancelDrag(CoreDragGetCurrentDrag());
    return 0;
}

// What SSDragHelper's ReceiveDrag does on both versions, without its promise keeper: the files are already reachable.
static int runCoreDrag(NSArray *paths) {
    PasteboardRef pasteboard = NULL;
    OSStatus error = PasteboardCreate(kPasteboardUniqueName, &pasteboard);
    if (error)
        return 10;
    PasteboardClear(pasteboard);
    NSUInteger index = 1;
    for (NSString *path in paths) {
        NSData *url = [[NSURL fileURLWithPath:path].absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        PasteboardPutItemFlavor(pasteboard, (PasteboardItemID)index++, kUTTypeFileURL, (__bridge CFDataRef)url, 0);
    }
    error = CoreDragRegisterClient(CGSMainConnectionID());
    printf("# CoreDragRegisterClient %d\n", (int)error);
    CoreDragRef drag = NULL;
    error = CoreDragCreateWithPasteboardRef(pasteboard, &drag);
    printf("# CoreDragCreateWithPasteboardRef %d\n", (int)error);
    if (error)
        return 11;
    CoreDragSetDropActions(drag, 5);
    CoreDragSetAllowableActions(drag, 1, 1);
    CoreDragSetInputProc(drag, coreDragInput, NULL);
    signal(SIGTERM, requestCancel);
    double start = now();
    error = CoreDragStartDragging(drag, 6, 0, CGPointZero);
    printf("drag_ended coredrag status %d after %.2f s\n", (int)error, now() - start);
    fflush(stdout);
    return error ? 12 : 0;
}

// Posts the pointer path a host would send through the tablet, for machines where nothing else drives it.
static void drive(CGPoint to) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      usleep(300000);
      CGEventRef here = CGEventCreate(NULL);
      CGPoint from = CGEventGetLocation(here);
      CFRelease(here);
      CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, from, kCGMouseButtonLeft);
      CGEventPost(kCGHIDEventTap, down);
      CFRelease(down);
      usleep(300000);
      for (int step = 1; step <= 30; step++) {
          CGPoint point = {from.x + (to.x - from.x) * step / 30, from.y + (to.y - from.y) * step / 30};
          CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDragged, point, kCGMouseButtonLeft);
          CGEventPost(kCGHIDEventTap, move);
          CFRelease(move);
          usleep(20000);
      }
      usleep(500000);
      CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, to, kCGMouseButtonLeft);
      CGEventPost(kCGHIDEventTap, up);
      CFRelease(up);
    });
}

static int dragIn(NSArray *paths, const char *backend, BOOL image, const char *driveTo) {
    [NSApplication sharedApplication];
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
    __block NSArray *shields;
    static DragSource *source;
    source = [DragSource new];
    BOOL coreDrag = !strcmp(backend, "coredrag");
    shields = makeShields(^(NSEvent *event) {
      for (NSWindow *shield in shields)
          [shield orderOut:nil];
      double started = now();
      if (coreDrag) {
          dispatch_async(dispatch_get_main_queue(), ^{
            exit(runCoreDrag(paths));
          });
          return;
      }
      NSMutableArray *items = [NSMutableArray array];
      NSWindow *window = event.window;
      for (NSString *path in paths) {
          NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:[NSURL fileURLWithPath:path]];
          NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:path];
          // In seamless mode the host draws the real image, so the guest's would double it inside the crop.
          NSSize size = image ? NSMakeSize(64, 64) : NSMakeSize(1, 1);
          NSPoint at = event.locationInWindow;
          [item setDraggingFrame:NSMakeRect(at.x - size.width / 2, at.y - size.height / 2, size.width, size.height)
                        contents:icon];
          [items addObject:item];
      }
      [window.contentView beginDraggingSessionWithItems:items event:event source:source];
      printf("drag_started ns in %.1f ms\n", (now() - started) * 1000);
      fflush(stdout);
    });
    [NSApp activateIgnoringOtherApps:YES];
    // After the shields have reached the screen, which they haven't yet on Mojave: until then a press goes straight
    // through.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
      printf("ready backend %s\n", backend);
      fflush(stdout);
    });
    if (driveTo) {
        double x, y;
        if (sscanf(driveTo, "%lf,%lf", &x, &y) == 2)
            drive(CGPointMake(x, y));
    }
    // Give up rather than leave shields over the desktop if no mouse down ever comes.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      puts("# ERROR timed out");
      exit(6);
    });
    [NSApp run];
    return 0;
}

// MARK: Drag out

static void describeDragPasteboard(NSPasteboard *pasteboard) {
    NSMutableDictionary *report = [NSMutableDictionary dictionary];
    report[@"changeCount"] = @(pasteboard.changeCount);
    report[@"types"] = pasteboard.types ?: @[];
    id files = [pasteboard propertyListForType:NSFilenamesPboardType];
    if ([files isKindOfClass:NSArray.class])
        report[@"files"] = files;
    id promised = [pasteboard propertyListForType:NSFilesPromisePboardType];
    if ([promised isKindOfClass:NSArray.class])
        report[@"promisedTypes"] = promised;
    printJSON(report);
}

static int dragWatch(double seconds) {
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithName:NSDragPboard];
    NSInteger last = pasteboard.changeCount;
    printf("ready changeCount %ld\n", (long)last);
    fflush(stdout);
    for (double start = now(); now() - start < seconds; usleep(50000))
        if (pasteboard.changeCount != last) {
            last = pasteboard.changeCount;
            describeDragPasteboard(pasteboard);
        }
    return 0;
}

// The drag's image is its own window; CoreDrag names it.
static void saveDragImage(const char *path) {
    CGWindowID window = 0;
    CoreDragRef drag = CoreDragGetCurrentDrag();
    OSStatus error = drag ? CoreDragGetDragWindow(drag, &window) : -1;
    printf("# drag window %u error %d\n", window, (int)error);
    if (!window || error)
        return;
    CGImageRef image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, window,
                                               kCGWindowImageBoundsIgnoreFraming);
    if (!image)
        return;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    [[rep representationUsingType:NSPNGFileType properties:@{}] writeToFile:@(path) atomically:YES];
    printf("# drag image %zux%zu at %s\n", CGImageGetWidth(image), CGImageGetHeight(image), path);
    CGImageRelease(image);
}

@interface SinkView : NSView <NSDraggingDestination>
@property NSString *promises;
@end
@implementation SinkView
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    printf("sink_entered\n");
    describeDragPasteboard(info.draggingPasteboard);
    saveDragImage("/private/tmp/lc-seamless/drag-image.png");
    return NSDragOperationCopy;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    return NSDragOperationCopy;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    printf("sink_performed\n");
    if (self.promises && [info.draggingPasteboard.types containsObject:NSFilesPromisePboardType]) {
        NSArray *names = [info namesOfPromisedFilesDroppedAtDestination:[NSURL fileURLWithPath:self.promises]];
        printJSON(@{@"promisedNames" : names ?: @[]});
    }
    return YES;
}
- (void)concludeDragOperation:(id<NSDraggingInfo>)info {
    puts("sink_concluded");
    fflush(stdout);
    dispatch_async(dispatch_get_main_queue(), ^{
      exit(0);
    });
}
@end

// Held off-screen from the user: the pointer enters it only once a drag has left a proxy, and the guest's source sees a
// completed copy, so nothing slides back and Finder's file stays where it is.
static int dragSink(double seconds, const char *promises) {
    [NSApplication sharedApplication];
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
    NSRect frame = NSScreen.mainScreen.frame;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSBorderlessWindowMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.backgroundColor = NSColor.whiteColor;
    window.alphaValue = 0.01;
    window.opaque = NO;
    window.ignoresMouseEvents = NO;
    window.level = CGWindowLevelForKey(kCGStatusWindowLevelKey);
    SinkView *view = [[SinkView alloc] initWithFrame:frame];
    view.promises = promises ? @(promises) : nil;
    [view registerForDraggedTypes:@[
        NSFilenamesPboardType, NSFilesPromisePboardType, NSPasteboardTypeString, NSPasteboardTypeTIFF,
        NSPasteboardTypePNG, NSPasteboardTypeRTF, NSURLPboardType, (__bridge NSString *)kUTTypeData,
        (__bridge NSString *)kUTTypeItem
    ]];
    window.contentView = view;
    [window orderFrontRegardless];
    printf("ready sink %.0fx%.0f\n", frame.size.width, frame.size.height);
    fflush(stdout);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      puts("# sink timed out");
      exit(6);
    });
    [NSApp run];
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        if (argc < 2) {
            fputs("Usage: seamless-integration-guest "
                  "apps|icon|menu|menu-watch|extras|press|title|open-file|badge-self|status|screen|drag-in|drag-watch|"
                  "drag-sink "
                  "...\n",
                  stderr);
            return 64;
        }
        const char *command = argv[1];
        if (flag(argc, argv, "--session") && !getuid())
            return runInSession(argc, argv);
        const char *app = option(argc, argv, "--app", "TextEdit");
        double seconds = atof(option(argc, argv, "--seconds", "30"));
        if (!strcmp(command, "apps"))
            return listApps();
        if (!strcmp(command, "icon"))
            return printIcon(option(argc, argv, "--path", ""));
        if (!strcmp(command, "menu"))
            return dumpMenu(app, option(argc, argv, "--top", NULL));
        if (!strcmp(command, "menu-watch"))
            return watchMenu(app, seconds);
        if (!strcmp(command, "extras"))
            return dumpExtras(app);
        if (!strcmp(command, "press"))
            return pressMenu(app, option(argc, argv, "--path", ""));
        if (!strcmp(command, "title"))
            return printWindows(app);
        if (!strcmp(command, "open-file"))
            return openFile(option(argc, argv, "--path", ""), option(argc, argv, "--with", NULL));
        if (!strcmp(command, "badge-self"))
            return badgeSelf(seconds);
        if (!strcmp(command, "status"))
            return status(atoi(option(argc, argv, "--pid", "0")));
        if (!strcmp(command, "screen")) {
            NSRect frame = NSScreen.mainScreen.frame;
            printf("screen %.0f %.0f backing %.1f\n", frame.size.width, frame.size.height,
                   NSScreen.mainScreen.backingScaleFactor);
            return 0;
        }
        if (!strcmp(command, "drag-in")) {
            NSMutableArray *paths = [NSMutableArray array];
            for (int i = 2; i + 1 < argc; i++)
                if (!strcmp(argv[i], "--file"))
                    [paths addObject:@(argv[i + 1])];
            if (!paths.count)
                return 64;
            return dragIn(paths, option(argc, argv, "--backend", "ns"), !flag(argc, argv, "--no-image"),
                          option(argc, argv, "--drive", NULL));
        }
        if (!strcmp(command, "drag-read")) {
            describeDragPasteboard([NSPasteboard pasteboardWithName:NSDragPboard]);
            return 0;
        }
        if (!strcmp(command, "drag-watch"))
            return dragWatch(seconds);
        if (!strcmp(command, "drag-sink"))
            return dragSink(seconds, option(argc, argv, "--promises", NULL));
        return 64;
    }
}
