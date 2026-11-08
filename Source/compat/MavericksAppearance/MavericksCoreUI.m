// Route shared system artwork through the original, privately namespaced engine.
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <objc/runtime.h>
extern int CUIDraw(void *,CGRect,CGContextRef,CFDictionaryRef,CFDictionaryRef *);
typedef int (*LCDraw)(void *,CGRect,CGContextRef,CFDictionaryRef,CFDictionaryRef *);
typedef Boolean (*LCExists)(void *,CFDictionaryRef);
static LCDraw legacyDraw;
static LCExists legacyExists;
typedef int (*LCLayerContents)(void *,CFDictionaryRef,CGImageRef *,CGRect *);
static LCLayerContents legacyContents;
static unsigned long originalDraws,fallbackDraws,originalLayerContents;
static NSMutableDictionary *observed;
static NSMutableSet *widgets;
static NSDictionary *widgetAliases;
static __thread BOOL inside;
static void loadEngine(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        char release[32]={0};size_t size=sizeof(release);sysctlbyname("kern.osrelease",release,&size,NULL,0);
        if(atoi(release)!=18 || getenv("MAVERICKS_DISABLE_COREUI"))return;
        void *handle=dlopen("/Library/Application Support/MavericksAppearance/LoreUI.framework/Versions/A/LoreUI",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
        if(handle){
            legacyDraw=dlsym(handle,"CUIDraw");legacyExists=dlsym(handle,"CUIExists");legacyContents=dlsym(handle,"CUICreateLayerContents");
            widgets=[NSMutableSet new];
            NSData *data=[NSData dataWithContentsOfFile:@"/Library/Application Support/MavericksAppearance/LoreUI.framework/Resources/Bridge.json"];
            NSDictionary *manifest=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
            for(NSString *name in manifest[@"widgets"]){id *value=dlsym(handle,name.UTF8String);if(value&&*value)[widgets addObject:*value];}
            id *textured=dlsym(handle,"kCUIWidgetButtonSegmentedTextured");
            id *zoom=dlsym(handle,"kCUIWidgetTitleBarZoomBox");
            widgetAliases=[@{@"kCUIWidgetButtonSegmentedSeparatedToolbar":textured?*textured:@"segmentedbutton",@"kCUIWidgetButtonSegmentedToolbar":textured?*textured:@"segmentedbutton",@"kCUIWidgetButtonSegmentedSeparated":@"segmentedbutton",@"kCUIWidgetTitleBarFullScreenEnter":zoom?*zoom:@"titlebarzoom"}retain];
        }
        observed=[NSMutableDictionary new];
    });
}
NSDictionary *MavericksCoreUIDiagnostics(void) {
    return @{@"loaded":@(legacyDraw!=NULL),@"originalDraws":@(originalDraws),@"originalLayerContents":@(originalLayerContents),@"fallbackDraws":@(fallbackDraws),@"widgets":observed?:@{}};
}
static IMP nativeLayerContents;
static CGImageRef classicLayerContents(id appearance,SEL selector,NSDictionary *options,CGRect *center) {
    if(inside)return ((CGImageRef(*)(id,SEL,id,CGRect *))nativeLayerContents)(appearance,selector,options,center);
    inside=YES;loadEngine();
    NSString *widget=options[@"widget"];NSMutableDictionary *adapted=nil;
    if(widget&&widgetAliases[widget]){adapted=[[options mutableCopy]autorelease];adapted[@"widget"]=widgetAliases[widget];}
    NSDictionary *parameters=adapted?:options;CGImageRef image=NULL;CGRect originalCenter=CGRectZero;
    if(legacyContents && [widgets containsObject:parameters[@"widget"]] && ![widget isEqual:@"image"]){
        int status=legacyContents(NULL,(CFDictionaryRef)parameters,&image,&originalCenter);
        if(status==0&&image){if(center)*center=originalCenter;originalLayerContents++;inside=NO;return image;}
        if(image)CGImageRelease(image);
    }
    inside=NO;return ((CGImageRef(*)(id,SEL,id,CGRect *))nativeLayerContents)(appearance,selector,options,center);
}
void MavericksCoreUIInstall(void) {
    static BOOL installed;if(installed)return;installed=YES;
    SEL selector=NSSelectorFromString(@"_createLayerContents:contentsCenter:");Method method=class_getInstanceMethod([NSAppearance class],selector);
    if(method){nativeLayerContents=method_getImplementation(method);method_setImplementation(method,(IMP)classicLayerContents);}
}
// Some original widgets paint a missing-resource diagnostic before returning an
// error. Render transactionally, so a fallback never leaves those pixels behind.
static int renderOriginal(CGRect rect,CGContextRef destination,CFDictionaryRef options,CFDictionaryRef *result) {
    CGAffineTransform transform=CGContextGetCTM(destination);
    if(!isfinite(transform.a*transform.d-transform.b*transform.c)||fabs(transform.a*transform.d-transform.b*transform.c)<1e-10)return -50;
    CGRect area=CGRectIntersection(CGRectInset(rect,-16,-16),CGContextGetClipBoundingBox(destination));
    CGRect device=CGRectIntegral(CGRectApplyAffineTransform(area,transform));
    if(CGRectIsEmpty(device)||!isfinite(device.size.width)||!isfinite(device.size.height)||device.size.width>8192||device.size.height>8192||device.size.width*device.size.height>8388608)return -50;
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef candidate=CGBitmapContextCreate(NULL,(size_t)device.size.width,(size_t)device.size.height,8,0,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(space);
    if(!candidate)return -108;
    CGContextTranslateCTM(candidate,-device.origin.x,-device.origin.y);CGContextConcatCTM(candidate,transform);
    CFDictionaryRef measurements=NULL;int status=legacyDraw(NULL,rect,candidate,options,&measurements);
    if(status==0){CGImageRef image=CGBitmapContextCreateImage(candidate);if(image){CGContextSaveGState(destination);CGContextConcatCTM(destination,CGAffineTransformInvert(transform));CGContextDrawImage(destination,device,image);CGContextRestoreGState(destination);CGImageRelease(image);}else status=-108;}
    if(status==0&&result)*result=measurements;else if(measurements)CFRelease(measurements);
    CGContextRelease(candidate);return status;
}
static int classicCUIDraw(void *renderer,CGRect rect,CGContextRef context,CFDictionaryRef options,CFDictionaryRef *result) {
    if(inside)return CUIDraw(renderer,rect,context,options,result);
    inside=YES;loadEngine();
    NSDictionary *parameters=(NSDictionary *)options;id widget=parameters[@"widget"];
    NSMutableDictionary *adapted=nil;
    if(widget && widgetAliases[widget]){adapted=[[parameters mutableCopy]autorelease];adapted[@"widget"]=widgetAliases[widget];}
    // In 10.9 CUIExists tests named-image availability only, not widget availability.
    // Use the actual exported widget vocabulary for control rendering.
    CFDictionaryRef drawingOptions=(CFDictionaryRef)(adapted?:parameters);
    BOOL supported=legacyDraw && widget && ([widgets containsObject:((NSDictionary *)drawingOptions)[@"widget"]] && ![widget isEqual:@"image"]);
    if([widget isEqual:@"image"] && parameters[@"imageNameKey"] && legacyExists)supported=legacyExists(NULL,options);
    if(widget)@synchronized(observed){
        NSString *name=[widget description];NSDictionary *prior=observed[name];
        if(!prior)observed[name]=@{@"supported":@(supported),@"parameters":[parameters description]};
    }
    int status;
    if(supported) {
        status=renderOriginal(rect,context,drawingOptions,result);
        @synchronized(observed){NSMutableDictionary *entry=[[observed[[widget description]]mutableCopy]autorelease];entry[@"lastStatus"]=@(status);observed[[widget description]]=entry;}
        if(status==0)originalDraws++;
        else {fallbackDraws++;status=CUIDraw(renderer,rect,context,options,result);}
    } else {fallbackDraws++;status=CUIDraw(renderer,rect,context,options,result);}
    inside=NO;return status;
}
__attribute__((used)) static struct {const void *replacement;const void *original;}
    interposeDraw __attribute__((section("__DATA,__interpose")))={(const void *)classicCUIDraw,(const void *)CUIDraw};
