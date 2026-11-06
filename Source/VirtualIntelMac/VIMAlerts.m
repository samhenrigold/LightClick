#import "VIMAlerts.h"
#import <objc/runtime.h>

static char installerIconKey;
void VIMSetAppAlertIcon(NSAlert *alert) {
    alert.icon = NSApp.applicationIconImage ?: [NSImage imageNamed:NSImageNameApplicationIcon];
}
void VIMSetInstallerAlertIcon(NSAlert *alert, NSString *guest) {
    alert.icon = [NSImage imageNamed:[guest stringByAppendingString:@"Icon"]] ?: NSApp.applicationIconImage;
    objc_setAssociatedObject(alert, &installerIconKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL VIMCreatingGuestFromArguments(void) {
    return [NSProcessInfo.processInfo.arguments containsObject:@"--create-guest"];
}
void VIMFailCreateGuest(NSString *message) {
    if (!VIMCreatingGuestFromArguments())
        return;
    fprintf(stderr, "create-guest: %s\n", message.UTF8String);
    exit(1);
}

void VIMPresentAlert(NSAlert *alert, NSWindow *window, void (^completion)(NSModalResponse)) {
    NSCAssert(NSThread.isMainThread, @"Alerts belong to the main thread");
    VIMFailCreateGuest(alert.informativeText.length
                           ? [NSString stringWithFormat:@"%@ %@", alert.messageText, alert.informativeText]
                           : alert.messageText);
    if (!objc_getAssociatedObject(alert, &installerIconKey))
        VIMSetAppAlertIcon(alert);
    NSWindow *parent = window ?: NSApp.keyWindow ?: NSApp.mainWindow;
    while (parent.isSheet)
        parent = parent.sheetParent;
    if (!parent)
        for (NSWindow *candidate in NSApp.orderedWindows)
            if (candidate.visible && !candidate.isSheet && candidate.level == NSNormalWindowLevel) {
                parent = candidate;
                break;
            }
    if (parent) {
        if (!parent.visible)
            [parent makeKeyAndOrderFront:nil];
        [alert beginSheetModalForWindow:parent completionHandler:completion];
    } else {
        NSModalResponse response = [alert runModal];
        // Match sheet completion's asynchronous contract, including quit flows
        // whose initial applicationShouldTerminate call must return first.
        if (completion)
            dispatch_async(dispatch_get_main_queue(), ^{
              completion(response);
            });
    }
}
void VIMPresentError(NSError *error, NSWindow *window) {
    if (error)
        VIMPresentAlert([NSAlert alertWithError:error], window, nil);
}
