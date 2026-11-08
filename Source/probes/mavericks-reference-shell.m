// Inspect the actual original Dock scene; all exported Apple artwork stays in Build.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <sys/sysctl.h>
static NSString *directory=@"/tmp/MavericksReferenceShell";
static NSMutableArray *floors;
static NSMutableArray *floorLayers;
static int sequence;
static void prepareFloor(CALayer *layer) {
    if([NSStringFromClass(layer.class)isEqual:@"DOCKGlassFloorLayer"])@try{
        [layer setValue:@YES forKey:@"overrideMirror"];
        SEL selector=NSSelectorFromString(@"forceMirrorUpdate");if([layer respondsToSelector:selector])((void(*)(id,SEL))[layer methodForSelector:selector])(layer,selector);
    }@catch(id exception){}
    for(CALayer *child in layer.sublayers)prepareFloor(child);
}
static id describe(id object) {return object?[object description]:@"";}
static NSString *saveImage(CGImageRef image,NSString *stem) {
    if(!image)return @"";
    NSBitmapImageRep *rep=[[[NSBitmapImageRep alloc]initWithCGImage:image]autorelease];
    NSString *name=[stem stringByAppendingString:@".png"];
    [[rep representationUsingType:NSPNGFileType properties:@{}]writeToFile:[directory stringByAppendingPathComponent:name]atomically:YES];return name;
}
static NSDictionary *tree(CALayer *layer,int depth) {
    if(depth>14)return @{};int index=sequence++;
    NSMutableDictionary *result=[NSMutableDictionary dictionaryWithDictionary:@{@"index":@(index),@"class":NSStringFromClass(layer.class),@"name":layer.name?:@"",@"bounds":NSStringFromRect(NSRectFromCGRect(layer.bounds)),@"frame":NSStringFromRect(NSRectFromCGRect(layer.frame)),@"position":NSStringFromPoint(NSPointFromCGPoint(layer.position)),@"anchor":NSStringFromPoint(NSPointFromCGPoint(layer.anchorPoint)),@"opacity":@(layer.opacity),@"hidden":@(layer.hidden),@"contentsGravity":layer.contentsGravity?:@"",@"contentsCenter":NSStringFromRect(NSRectFromCGRect(layer.contentsCenter)),@"contentsScale":@(layer.contentsScale),@"transform":[NSValue valueWithCATransform3D:layer.transform].description,@"background":describe((id)layer.backgroundColor),@"compositingFilter":describe(layer.compositingFilter)}];
    id contents=layer.contents;if(contents && CFGetTypeID((CFTypeRef)contents)==CGImageGetTypeID())result[@"image"]=saveImage((CGImageRef)contents,[NSString stringWithFormat:@"layer-%d",index]);
    NSMutableArray *filters=[NSMutableArray array];for(id filter in layer.filters){NSMutableDictionary *props=[NSMutableDictionary dictionaryWithObject:describe(filter)forKey:@"description"];
        for(NSString *key in @[@"name",@"type",@"inputColor0",@"inputColor1",@"inputAmount",@"inputRadius",@"inputAngle",@"inputPoint0",@"inputPoint1",@"inputBounds",@"inputMaskImage",@"inputImage"]){@try{id value=[filter valueForKey:key];if(value)props[key]=describe(value);}@catch(id exception){}}
        [filters addObject:props];}result[@"filters"]=filters;
    NSMutableArray *children=[NSMutableArray array];for(CALayer *child in layer.sublayers)[children addObject:tree(child,depth+1)];result[@"children"]=children;
    if(layer.mask)result[@"mask"]=tree(layer.mask,depth+1);
    if([NSStringFromClass(layer.class)rangeOfString:@"floor"options:NSCaseInsensitiveSearch].location!=NSNotFound){
        if([NSStringFromClass(layer.class)isEqual:@"DOCKGlassFloorLayer"]){[floorLayers addObject:layer];@try{CALayer *glass=[layer valueForKey:@"_glassLayer"];if(glass)result[@"detachedGlass"]=tree(glass,depth+1);result[@"mirrorOn"]=[layer valueForKey:@"mirrorOn"];result[@"mirrorOff"]=[layer valueForKey:@"_mirrorOff"];result[@"mirrorDisabled"]=[layer valueForKey:@"_dontEverShowMirror"];}@catch(id exception){}}
        [floors addObject:result];CGRect bounds=layer.bounds;
        if(bounds.size.width>1&&bounds.size.width<4096&&bounds.size.height>1&&bounds.size.height<2048){
            CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);CGContextRef context=CGBitmapContextCreate(NULL,ceil(bounds.size.width*2),ceil(bounds.size.height*2),8,0,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(cs);
            CGContextScaleCTM(context,2,2);CGContextTranslateCTM(context,-bounds.origin.x,-bounds.origin.y);[layer renderInContext:context];CGImageRef image=CGBitmapContextCreateImage(context);result[@"render"]=saveImage(image,[NSString stringWithFormat:@"floor-%d",index]);CGImageRelease(image);CGContextRelease(context);
        }
    }
    return result;
}
static void exportScene(void) {
    [[NSFileManager defaultManager]createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    floors=[NSMutableArray new];floorLayers=[NSMutableArray new];NSMutableArray *contexts=[NSMutableArray array],*windows=[NSMutableArray array];
    Class cls=NSClassFromString(@"CAContext");SEL selector=NSSelectorFromString(@"allContexts");
    if([cls respondsToSelector:selector])for(id context in ((id(*)(id,SEL))[cls methodForSelector:selector])(cls,selector))@try{id layer=[context valueForKey:@"layer"];if([layer isKindOfClass:[CALayer class]]){prepareFloor(layer);[contexts addObject:tree(layer,0)];}}@catch(id exception){}
    for(NSWindow *window in NSApp.windows)if(window.contentView.layer)[windows addObject:tree(window.contentView.layer,0)];
    NSMutableDictionary *classes=[NSMutableDictionary dictionary];unsigned count=0;Class *list=objc_copyClassList(&count);
    for(unsigned i=0;i<count;i++){NSString *name=NSStringFromClass(list[i]);if([name rangeOfString:@"floor"options:NSCaseInsensitiveSearch].location==NSNotFound&&[name rangeOfString:@"dock"options:NSCaseInsensitiveSearch].location==NSNotFound)continue;unsigned n=0;Method *methods=class_copyMethodList(list[i],&n);NSMutableArray *rows=[NSMutableArray array];for(unsigned j=0;j<n;j++)[rows addObject:@{@"name":NSStringFromSelector(method_getName(methods[j])),@"encoding":@(method_getTypeEncoding(methods[j]))}];free(methods);classes[name]=rows;}free(list);
    NSMutableArray *hidden=[NSMutableArray array],*captures=[NSMutableArray array];
    [CATransaction begin];[CATransaction setDisableActions:YES];
    for(CALayer *floor in floorLayers){for(CALayer *sibling in floor.superlayer.sublayers)if(sibling!=floor&&!sibling.hidden){[hidden addObject:sibling];sibling.hidden=YES;}for(CALayer *child in floor.sublayers)if(!child.hidden){[hidden addObject:child];child.hidden=YES;}}
    [CATransaction commit];[CATransaction flush];[[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.7]];
    NSArray *windowList=(NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID);
    for(NSDictionary *window in windowList)if([window[(id)kCGWindowOwnerPID]intValue]==getpid()){
        CGWindowID identifier=[window[(id)kCGWindowNumber]unsignedIntValue];CGImageRef image=CGWindowListCreateImage(CGRectNull,kCGWindowListOptionIncludingWindow,identifier,kCGWindowImageBoundsIgnoreFraming|kCGWindowImageBestResolution);
        if(image){NSString *file=saveImage(image,[NSString stringWithFormat:@"composited-floor-window-%u",identifier]);[captures addObject:@{@"window":window,@"image":file,@"width":@(CGImageGetWidth(image)),@"height":@(CGImageGetHeight(image))}];CGImageRelease(image);}
    }
    [windowList release];[CATransaction begin];[CATransaction setDisableActions:YES];for(CALayer *layer in hidden)layer.hidden=NO;[CATransaction commit];[CATransaction flush];
    [[NSJSONSerialization dataWithJSONObject:@{@"contexts":contexts,@"windows":windows,@"floors":floors,@"classes":classes,@"compositedFloors":captures}options:NSJSONWritingPrettyPrinted error:NULL]writeToFile:[directory stringByAppendingPathComponent:@"scene.json"]atomically:YES];
}
__attribute__((constructor))static void start(void){char release[32];size_t size=sizeof(release);sysctlbyname("kern.osrelease",release,&size,NULL,0);[[NSString stringWithFormat:@"%@ %s",[NSProcessInfo processInfo].processName,release]writeToFile:@"/tmp/MavericksReferenceLoaded.txt"atomically:YES encoding:NSUTF8StringEncoding error:NULL];if(atoi(release)!=13||![[NSProcessInfo processInfo].processName isEqual:@"Dock"])return;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{exportScene();});}
