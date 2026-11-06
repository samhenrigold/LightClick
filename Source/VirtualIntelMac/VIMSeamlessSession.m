#import "VIMSeamlessSession.h"
#import <AppKit/AppKit.h>
#import "VIMMachine.h"

static NSString *VIMSeamlessOption(NSString *name) {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    NSUInteger index = [arguments indexOfObject:name];
    return index != NSNotFound && index + 1 < arguments.count ? arguments[index + 1] : nil;
}

@implementation VIMSeamlessSession

+ (void)prepareIfRequested {
    if (!VIMSeamlessOption(@"--seamless-session"))
        return;
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
    // The machine's and library's windows are what say a VM is there. A sheet on one goes with it; an alert is a panel
    // of its own, and still shows. No notification does this: an inactive app with no events doesn't update its
    // windows. Clear as well as ordered out, since with the Mac's display asleep WindowServer's list still calls them
    // on screen, whatever AppKit says, and nothing here can tell whether that would show. shortcut: they exist, on a
    // timer, so one can flash on screen for a moment, until VIMSession can run without a window.
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.25
                                            repeats:YES
                                              block:^(NSTimer *unused) {
                                                for (NSWindow *window in NSApp.windows)
                                                    if (window.visible && ![window isKindOfClass:NSPanel.class]) {
                                                        window.alphaValue = 0;
                                                        window.ignoresMouseEvents = YES;
                                                        [window orderOut:nil];
                                                    }
                                              }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

+ (void)startIfRequested:(void (^)(void))finished {
    NSString *socket = VIMSeamlessOption(@"--seamless-session"), *guestApp = VIMSeamlessOption(@"--seamless-app"),
             *root = VIMSeamlessOption(@"--guest-diagnostics-root"), *machinePath = VIMSeamlessOption(@"--open-vm");
    if (!socket)
        return;
    VIMMachine *machine = machinePath ? [VIMMachine loadURL:[NSURL fileURLWithPath:machinePath] error:nil] : nil;
    NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:machine.configuration[@"Identifier"] ?: @""];
    NSString *tools = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Seamless"];
    NSString *program = [tools stringByAppendingPathComponent:@"seamless-viewer"];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:program];
    NSMutableArray *arguments = [@[
        @"--tree", @"--port", @"0", @"--session-socket", socket, @"--channel",
        [root stringByAppendingPathComponent:identifier.UUIDString] ?: @"", @"--guest-app", guestApp ?: @"",
        @"--guest-tools", tools
    ] mutableCopy];
    NSString *extra = NSProcessInfo.processInfo.environment[@"LC_SEAMLESS_VIEWER_ARGS"];
    if (extra.length)
        [arguments addObjectsFromArray:[extra componentsSeparatedByString:@"\n"]];
    task.arguments = arguments;
    NSString *log = [socket stringByAppendingPathExtension:@"log"];
    [NSFileManager.defaultManager createFileAtPath:log contents:nil attributes:@{NSFilePosixPermissions : @0600}];
    task.standardOutput = [NSFileHandle fileHandleForWritingAtPath:log] ?: NSFileHandle.fileHandleWithNullDevice;
    task.standardError = task.standardOutput;
    task.terminationHandler = ^(NSTask *ended) {
      dispatch_async(dispatch_get_main_queue(), finished);
    };
    NSError *error = nil;
    if (!identifier || !guestApp || !root || ![task launchAndReturnError:&error]) {
        NSLog(@"The seamless session couldn't start: %@", error ?: @"missing arguments");
        finished();
    }
}

@end
