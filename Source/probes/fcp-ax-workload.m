// Surgical guest FCP menu/dialog inventory. No app launch, AX actions, input or screenshots.
// Initial mode deliberately inventories only; save-panel interaction needs observed controls.
// argv: 10.1|10.4.4 exact-owned-PID inventory
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <libproc.h>
#import <mach/mach_time.h>
#import <signal.h>

static NSUInteger nodes, failures;
static BOOL truncated, expired;
static double deadline;
static double clockNow(void) {
    mach_timebase_info_data_t scale; mach_timebase_info(&scale);
    return (double)mach_absolute_time()*scale.numer/scale.denom/1e9;
}
static BOOL room(void) {
    if (clockNow() >= deadline) { expired = YES; return NO; }
    if (nodes >= 416) { truncated = YES; return NO; }
    return YES;
}
static CFTypeRef attribute(AXUIElementRef element, CFStringRef name) {
    if (!room()) return NULL;
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, name, &value);
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
static NSMutableDictionary *header(AXUIElementRef element) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if (!room()) return result;
    nodes++;
    if (AXUIElementSetMessagingTimeout(element, .15) != kAXErrorSuccess) {
        failures++; result[@"observationError"] = @"messaging timeout unavailable"; return result;
    }
    for (NSString *key in @[@"AXRole",@"AXSubrole",@"AXTitle",@"AXDescription",@"AXValue",@"AXEnabled",@"AXIdentifier",@"AXMenuItemCmdChar",@"AXMenuItemCmdModifiers"]) {
        CFTypeRef value = attribute(element, (__bridge CFStringRef)key);
        id text = scalar(value); if (text) result[key] = text;
        if (value) CFRelease(value);
    }
    CFArrayRef actions = NULL;
    if (room()) {
        AXError error = AXUIElementCopyActionNames(element, &actions);
        if (error == kAXErrorSuccess && actions) {
            NSMutableArray *names = [NSMutableArray array];
            CFIndex count = CFArrayGetCount(actions);
            for (CFIndex i = 0; i < MIN(count,16); i++) {
                id name = scalar(CFArrayGetValueAtIndex(actions,i)); if (name) [names addObject:name];
            }
            if (count > 16) truncated = YES;
            result[@"availableActions"] = names; // Observed names only; never performed.
        } else if (error != kAXErrorAttributeUnsupported && error != kAXErrorNoValue) failures++;
        if (actions) CFRelease(actions);
    }
    return result;
}
static NSDictionary *subtree(AXUIElementRef element, NSUInteger depth, NSUInteger *budget) {
    if (!room() || !*budget) { truncated = YES; return @{}; }
    (*budget)--;
    NSMutableDictionary *result = header(element);
    CFTypeRef children = attribute(element,kAXChildrenAttribute);
    if (children && CFGetTypeID(children) == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(children); result[@"childCount"] = @(count);
        if (depth >= 7 && count) truncated = YES;
        else {
            NSMutableArray *items = [NSMutableArray array];
            for (CFIndex i = 0; i < MIN(count,64) && room() && *budget; i++) {
                CFTypeRef child = CFArrayGetValueAtIndex(children,i);
                if (child && CFGetTypeID(child) == AXUIElementGetTypeID()) {
                    NSMutableDictionary *item = [subtree((AXUIElementRef)child,depth+1,budget) mutableCopy];
                    item[@"childIndex"] = @(i); [items addObject:item];
                }
            }
            if (count > 64 || (CFIndex)items.count < count) truncated = YES;
            result[@"children"] = items;
        }
    }
    if (children) CFRelease(children);
    return result;
}
static BOOL matches(pid_t pid,NSString *expected) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0}, canonical[PATH_MAX] = {0};
    if (proc_pidpath(pid,path,sizeof(path)) <= 0 || !realpath(path,canonical)) return NO;
    return !strcmp(path,canonical) && [expected isEqualToString:[NSString stringWithUTF8String:path]];
}
static NSArray *windowsAndDialogs(AXUIElementRef application) {
    NSMutableArray *result = [NSMutableArray array];
    CFTypeRef windows = attribute(application,kAXWindowsAttribute);
    NSUInteger budget = 64;
    if (windows && CFGetTypeID(windows) == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(windows);
        if (count > 8) truncated = YES;
        for (CFIndex i = 0; i < MIN(count,8) && room() && budget; i++) {
            CFTypeRef value = CFArrayGetValueAtIndex(windows,i);
            if (!value || CFGetTypeID(value) != AXUIElementGetTypeID()) continue;
            AXUIElementRef window = (AXUIElementRef)value;
            NSMutableDictionary *item = header(window); budget--;
            item[@"windowIndex"] = @(i);
            NSString *role = item[@"AXRole"], *subrole = item[@"AXSubrole"];
            if ([role isEqualToString:@"AXSheet"] || [role isEqualToString:@"AXAlert"] || [subrole isEqualToString:@"AXDialog"] || [subrole isEqualToString:@"AXSystemDialog"]) {
                item[@"dialogTree"] = subtree(window,0,&budget);
            }
            CFTypeRef sheets = attribute(window,kAXChildrenAttribute);
            if (sheets && CFGetTypeID(sheets) == CFArrayGetTypeID()) {
                NSMutableArray *items = [NSMutableArray array];
                CFIndex sheetCount = CFArrayGetCount(sheets);
                for (CFIndex j = 0; j < MIN(sheetCount,32) && room() && budget; j++) {
                    CFTypeRef sheet = CFArrayGetValueAtIndex(sheets,j);
                    if (sheet && CFGetTypeID(sheet) == AXUIElementGetTypeID()) {
                        AXUIElementSetMessagingTimeout((AXUIElementRef)sheet,.15);
                        CFTypeRef roleValue = attribute((AXUIElementRef)sheet,kAXRoleAttribute);
                        id childRole = scalar(roleValue);
                        if ([childRole isEqualToString:@"AXSheet"] || [childRole isEqualToString:@"AXAlert"]) [items addObject:subtree((AXUIElementRef)sheet,0,&budget)];
                        if (roleValue) CFRelease(roleValue);
                    }
                }
                if (sheetCount > 32) truncated = YES;
                item[@"directChildCount"] = @(sheetCount);
                item[@"sheets"] = items;
            }
            if (sheets) CFRelease(sheets);
            [result addObject:item];
        }
    }
    if (windows) CFRelease(windows);
    return result;
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if (argc != 4 || strcmp(argv[3],"inventory")) {
            fprintf(stderr,"usage: fcp-ax-workload 10.1|10.4.4 exactPID inventory\n"); return 2;
        }
        NSString *variant = [NSString stringWithUTF8String:argv[1]];
        NSString *binary = [variant isEqualToString:@"10.1"] ? @"/Applications/Final Cut Pro.app/Contents/MacOS/Final Cut Pro" :
            [variant isEqualToString:@"10.4.4"] ? @"/Applications/Final Cut Pro Trial.app/Contents/MacOS/Final Cut Pro Trial" : nil;
        char *end = NULL; long number = strtol(argv[2],&end,10);
        if (!binary || !argv[2][0] || *end || number <= 1 || number > INT_MAX) return 2;
        pid_t pid = (pid_t)number;
        alarm(11); deadline = clockNow()+8;
        NSMutableDictionary *report = [@{@"result":@"INCONCLUSIVE",@"variant":variant,@"pid":@(pid),@"mode":@"inventory",
            @"expectedExecutable":binary,@"readOnly":@YES,@"trustRequested":@NO,@"actionsPerformed":@[]} mutableCopy];
        report[@"identityMatched"] = @(matches(pid,binary));
        report[@"axTrusted"] = @(AXIsProcessTrusted());
        if ([report[@"identityMatched"] boolValue]) {
            AXUIElementRef application = AXUIElementCreateApplication(pid);
            AXUIElementSetMessagingTimeout(application,.15);
            report[@"windows"] = windowsAndDialogs(application);
            CFTypeRef menuBar = attribute(application,kAXMenuBarAttribute);
            NSMutableArray *top = [NSMutableArray array];
            NSUInteger fileMatches = 0;
            AXUIElementRef file = NULL;
            if (menuBar && CFGetTypeID(menuBar) == AXUIElementGetTypeID()) {
                AXUIElementSetMessagingTimeout((AXUIElementRef)menuBar,.15);
                CFTypeRef children = attribute((AXUIElementRef)menuBar,kAXChildrenAttribute);
                if (children && CFGetTypeID(children) == CFArrayGetTypeID()) {
                    CFIndex count = CFArrayGetCount(children);
                    if (count > 24) truncated = YES;
                    for (CFIndex i = 0; i < MIN(count,24) && room(); i++) {
                        CFTypeRef child = CFArrayGetValueAtIndex(children,i);
                        if (!child || CFGetTypeID(child) != AXUIElementGetTypeID()) continue;
                        NSMutableDictionary *item = header((AXUIElementRef)child); item[@"topIndex"] = @(i); [top addObject:item];
                        if ([item[@"AXTitle"] isEqualToString:@"File"]) { fileMatches++; file = (AXUIElementRef)child; }
                    }
                    // Use only an actual unique File label. Never choose a menu by guessed index.
                    if (fileMatches == 1 && file) { NSUInteger budget = 320; report[@"fileMenu"] = subtree(file,0,&budget); }
                }
                if (children) CFRelease(children);
            }
            if (menuBar) CFRelease(menuBar);
            CFRelease(application);
            report[@"topMenus"] = top; report[@"fileLabelMatches"] = @(fileMatches);
            report[@"identityStillMatched"] = @(matches(pid,binary));
            if (fileMatches == 1 && report[@"fileMenu"] && [report[@"identityStillMatched"] boolValue]) report[@"result"] = @"MENU_INVENTORY";
        }
        report[@"nodes"] = @(nodes); report[@"attributeFailures"] = @(failures);
        report[@"truncated"] = @(truncated); report[@"deadlineExceeded"] = @(expired);
        report[@"qualification"] = @"Observed menu/dialog evidence only. No private library, import, export or rendering has been qualified.";
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:&error];
        if (!json || json.length > 1048576) return 3;
        fwrite(json.bytes,1,json.length,stdout); putchar('\n'); alarm(0); return 0;
    }
}
