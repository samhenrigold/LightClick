// Read-only FCP launch observation; no AX actions, screenshots, input or trust requests.
// x86_64 macOS10.9+, argv: 10.1|10.4.4 exact-owned-app-PID. Never launches an app.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <libproc.h>
#import <signal.h>
#import <sys/stat.h>
#import <mach/mach_time.h>

static NSUInteger nodes, failures;
static BOOL truncated, expired;
static double deadline;
static double now(void) {
    mach_timebase_info_data_t scale; mach_timebase_info(&scale);
    return (double)mach_absolute_time() * scale.numer / scale.denom / 1e9;
}
static BOOL available(void) {
    if (now() >= deadline) { expired = YES; return NO; }
    if (nodes >= 256) { truncated = YES; return NO; }
    return YES;
}
static CFTypeRef copyAttribute(AXUIElementRef element, CFStringRef key) {
    if (!available()) return NULL;
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, key, &value);
    if (error != kAXErrorSuccess && error != kAXErrorNoValue && error != kAXErrorAttributeUnsupported) failures++;
    return value;
}
static id scalar(CFTypeRef value) {
    if (!value) return nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        NSString *text = (__bridge NSString *)value;
        if (text.length > 512) { truncated = YES; return [text substringToIndex:512]; }
        return text;
    }
    if (CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID()) return (__bridge id)value;
    return nil;
}
static NSDictionary *tree(AXUIElementRef element, NSUInteger depth) {
    if (!available()) return @{};
    nodes++;
    if (AXUIElementSetMessagingTimeout(element, .2) != kAXErrorSuccess) { failures++; return @{@"observationError":@"messaging timeout unavailable"}; }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *attributes = @[@"AXRole", @"AXSubrole", @"AXTitle", @"AXDescription", @"AXValue", @"AXEnabled"];
    for (NSString *key in attributes) {
        CFTypeRef value = copyAttribute(element, (__bridge CFStringRef)key);
        id text = scalar(value);
        if (text) result[key] = text;
        if (value) CFRelease(value);
    }
    CFTypeRef children = copyAttribute(element, kAXChildrenAttribute);
    if (children && CFGetTypeID(children) == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(children);
        result[@"childCount"] = @(count);
        if (depth >= 7 && count) truncated = YES;
        else {
            NSMutableArray *items = [NSMutableArray array];
            for (CFIndex i = 0; i < MIN(count, 32) && available(); i++) {
                CFTypeRef child = CFArrayGetValueAtIndex(children, i);
                if (child && CFGetTypeID(child) == AXUIElementGetTypeID()) [items addObject:tree((AXUIElementRef)child, depth+1)];
            }
            if (count > 32) truncated = YES;
            result[@"children"] = items;
        }
    }
    if (children) CFRelease(children);
    return result;
}
static BOOL identity(pid_t pid, NSString *expected) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    char resolved[PATH_MAX] = {0};
    if (!realpath(path, resolved)) return NO;
    return [expected isEqualToString:[NSString stringWithUTF8String:path]] && !strcmp(path, resolved);
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "usage: fcp-ax-observe 10.1|10.4.4 exactPID\n"); return 2; }
        NSString *version = [NSString stringWithUTF8String:argv[1]];
        NSString *app = [version isEqualToString:@"10.1"] ? @"/Applications/Final Cut Pro.app" :
                        [version isEqualToString:@"10.4.4"] ? @"/Applications/Final Cut Pro Trial.app" : nil;
        char *end = NULL; long value = strtol(argv[2], &end, 10);
        if (!app || !argv[2][0] || *end || value <= 1 || value > INT_MAX) return 2;
        pid_t pid = (pid_t)value;
        NSString *binary = [app stringByAppendingPathComponent:[version isEqualToString:@"10.1"] ? @"Contents/MacOS/Final Cut Pro" : @"Contents/MacOS/Final Cut Pro Trial"];
        NSMutableDictionary *report = [@{@"result":@"INCONCLUSIVE", @"pid":@(pid), @"version":version,
            @"expectedExecutable":binary, @"readOnly":@YES, @"trustRequested":@NO} mutableCopy];
        alarm(11); // Last-resort bound if an AX transport ignores its messaging timeout.
        BOOL matched = identity(pid, binary);
        report[@"identityMatched"] = @(matched);
        report[@"axTrusted"] = @(AXIsProcessTrusted()); // Observation only; deliberately no prompting API.
        if (matched) {
            deadline = now()+8;
            AXUIElementRef application = AXUIElementCreateApplication(pid);
            AXError timeoutError = AXUIElementSetMessagingTimeout(application, .2);
            report[@"messagingTimeoutError"] = @(timeoutError);
            CFTypeRef windows = copyAttribute(application, kAXWindowsAttribute);
            NSMutableArray *observed = [NSMutableArray array];
            if (windows && CFGetTypeID(windows) == CFArrayGetTypeID()) {
                CFIndex count = CFArrayGetCount(windows);
                report[@"windowCount"] = @(count);
                if (count > 8) truncated = YES;
                for (CFIndex i = 0; i < MIN(count, 8) && available(); i++) {
                    CFTypeRef window = CFArrayGetValueAtIndex(windows, i);
                    if (CFGetTypeID(window) == AXUIElementGetTypeID()) [observed addObject:tree((AXUIElementRef)window, 0)];
                }
            }
            if (windows) CFRelease(windows);
            report[@"windows"] = observed;
            CFTypeRef menu = copyAttribute(application, kAXMenuBarAttribute);
            if (menu && CFGetTypeID(menu) == AXUIElementGetTypeID()) report[@"menuBar"] = tree((AXUIElementRef)menu, 0);
            if (menu) CFRelease(menu);
            CFRelease(application);
            report[@"identityStillMatched"] = @(identity(pid,binary));
            report[@"nodes"] = @(nodes); report[@"attributeFailures"] = @(failures);
            report[@"truncated"] = @(truncated); report[@"deadlineExceeded"] = @(expired);
            if ([report[@"identityStillMatched"] boolValue] && observed.count && !expired && !failures) report[@"result"] = @"OBSERVED_WINDOWS";
        }
        // OBSERVED_WINDOWS is evidence, not an assertion of usable editing/GPU support.
        report[@"qualification"] = @"Inspect window/menu/alert evidence; observation alone does not qualify GPU or workload.";
        NSError *error = nil; NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:&error];
        if (!json || json.length > 1048576) return 3;
        fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
        alarm(0);
        return 0;
    }
}
