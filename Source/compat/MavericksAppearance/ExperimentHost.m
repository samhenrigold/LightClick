// Applied only to the cloned experiment app. Keep its optional Seamless prearming off the diagnostics agent.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <stdlib.h>
static IMP nativeWindowOrder;
static void hiddenWindowOrder(NSWindow *window,SEL cmd,NSWindowOrderingMode place,NSInteger relative) {((void(*)(id,SEL,NSWindowOrderingMode,NSInteger))nativeWindowOrder)(window,cmd,NSWindowOut,relative);}
static void noPrearm(id self,SEL cmd,id session) {}
__attribute__((constructor)) static void initializeExperimentOwner(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
    if(getenv("LC_APPEARANCE_HIDDEN")) {Method order=class_getInstanceMethod([NSWindow class],@selector(orderWindow:relativeTo:));nativeWindowOrder=method_getImplementation(order);method_setImplementation(order,(IMP)hiddenWindowOrder);}
    Class cls=NSClassFromString(@"VIMSeamlessHost");
    if(!cls){unsigned n=0;Class *all=objc_copyClassList(&n);for(unsigned i=0;i<n;i++)if([NSStringFromClass(all[i]) hasSuffix:@".VIMSeamlessHost"]){cls=all[i];break;}free(all);}
    Method method=class_getClassMethod(cls,NSSelectorFromString(@"prepareFor:"));
    if(method)method_setImplementation(method,(IMP)noPrearm);
    NSString *result=method?@"Automatic Seamless preparation disabled for this experiment":@"ERROR: Seamless preparation method missing";
    [result writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"AppearanceControlOwner.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
