// Preserve native catalog metadata while substituting compatible original pixels.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
extern NSImage *MavericksAppearanceOriginalImage(NSString *,NSBundle *);
static char catalogBundleKey,originalImageKey,originalScaleKey,renderedImageKey;
static IMP nativeCatalogURL,nativeCatalogBundle,nativeCatalogName,nativeCatalogNameError,nativeCatalogImage,nativeImage,nativeCroppedImage;
static __thread BOOL renderingOriginal;
static NSUInteger requests,replacements,sizeMismatches;
static NSMutableArray *samples;
static NSBundle *bundleForURL(NSURL *url) {
    NSString *path=url.path;
    while(path.length>1){
        if([@[@"app",@"framework",@"bundle",@"prefPane",@"plugin",@"menu",@"xpc"]containsObject:path.pathExtension])return [NSBundle bundleWithPath:path];
        path=path.stringByDeletingLastPathComponent;
    }return nil;
}
static id catalogURL(id self,SEL cmd,NSURL *url,NSError **error) {
    id catalog=((id(*)(id,SEL,id,NSError **))nativeCatalogURL)(self,cmd,url,error);
    NSBundle *bundle=bundleForURL(url);
    if(catalog&&bundle)objc_setAssociatedObject(catalog,&catalogBundleKey,bundle,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return catalog;
}
static id catalogBundle(id cls,SEL cmd,NSBundle *bundle) {
    id catalog=((id(*)(id,SEL,id))nativeCatalogBundle)(cls,cmd,bundle);
    if(catalog&&[bundle isKindOfClass:[NSBundle class]])objc_setAssociatedObject(catalog,&catalogBundleKey,bundle,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return catalog;
}
static id catalogName(id self,SEL cmd,NSString *name,NSBundle *bundle) {
    id catalog=((id(*)(id,SEL,id,id))nativeCatalogName)(self,cmd,name,bundle);
    if(catalog&&[bundle isKindOfClass:[NSBundle class]])objc_setAssociatedObject(catalog,&catalogBundleKey,bundle,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return catalog;
}
static id catalogNameError(id self,SEL cmd,NSString *name,NSBundle *bundle,NSError **error) {
    id catalog=((id(*)(id,SEL,id,id,NSError **))nativeCatalogNameError)(self,cmd,name,bundle,error);
    if(catalog&&[bundle isKindOfClass:[NSBundle class]])objc_setAssociatedObject(catalog,&catalogBundleKey,bundle,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return catalog;
}
static id catalogImage(id self,SEL cmd,NSString *name,double scale,NSInteger idiom,NSUInteger subtype,NSInteger gamut,NSInteger direction,NSInteger horizontal,NSInteger vertical,NSUInteger memory,NSUInteger graphics,NSInteger appearance,id graphicsFallback,id subtypeFallback) {
    id image=((id(*)(id,SEL,id,double,NSInteger,NSUInteger,NSInteger,NSInteger,NSInteger,NSInteger,NSUInteger,NSUInteger,NSInteger,id,id))nativeCatalogImage)(self,cmd,name,scale,idiom,subtype,gamut,direction,horizontal,vertical,memory,graphics,appearance,graphicsFallback,subtypeFallback);
    if(!image||renderingOriginal)return image;
    NSBundle *bundle=objc_getAssociatedObject(self,&catalogBundleKey);
    NSImage *original=MavericksAppearanceOriginalImage(name,bundle);
    // Catalog names omit the public NS prefix and Template suffix. Resolve
    // only names actually exported by the original system image catalog.
    if(!original&&![name hasPrefix:@"NS"])original=MavericksAppearanceOriginalImage([@"NS"stringByAppendingString:[name stringByAppendingString:@"Template"]],nil);
    if(!original&&[name isEqual:@"ToolbarTagIcon"]&&([bundle.bundleIdentifier isEqual:@"com.apple.finder"]||[bundle.bundleIdentifier isEqual:@"com.apple.systemappearance"]))original=MavericksAppearanceOriginalImage(@"TagToolbarIconTemplate",[NSBundle bundleWithPath:@"/System/Library/CoreServices/Finder.app"]);
    if(original){objc_setAssociatedObject(image,&originalImageKey,original,OBJC_ASSOCIATION_RETAIN_NONATOMIC);objc_setAssociatedObject(image,&originalScaleKey,@(scale),OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    @synchronized(samples){requests++;if(samples.count<24)[samples addObject:@{@"name":name?:@"",@"bundle":bundle.bundleIdentifier?:@"",@"original":@(original!=nil)}];}
    return image;
}
static CGImageRef catalogPixels(id self,SEL cmd) {
    IMP native=cmd==NSSelectorFromString(@"croppedImage")?nativeCroppedImage:nativeImage;
    CGImageRef fallback=((CGImageRef(*)(id,SEL))native)(self,cmd);
    if(renderingOriginal||!fallback)return fallback;
    NSImage *original=objc_getAssociatedObject(self,&originalImageKey);if(!original)return fallback;
    CGFloat scale=[objc_getAssociatedObject(self,&originalScaleKey)doubleValue];
    size_t width=CGImageGetWidth(fallback),height=CGImageGetHeight(fallback);
    // Insets, cropping and view geometry belong to the native catalog. A name
    // alone is insufficient evidence that artwork can safely share those metrics.
    if(scale<=0||original.size.width*scale>width+.01||original.size.height*scale>height+.01){@synchronized(samples){sizeMismatches++;}return fallback;}
    CGImageRef cached=(CGImageRef)objc_getAssociatedObject(self,&renderedImageKey);if(cached)return cached;
    if(width>4096||height>4096)return fallback;
    renderingOriginal=YES;CGImageRef rendered=NULL;
    @try {
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context=CGBitmapContextCreate(NULL,width,height,8,0,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(space);
        if(context){
            [NSGraphicsContext saveGraphicsState];
            @try{[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:context flipped:NO]];CGFloat w=original.size.width*scale,h=original.size.height*scale;[original drawInRect:NSMakeRect(floor((width-w)/2),floor((height-h)/2),w,h)fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1 respectFlipped:NO hints:nil];}
            @finally{[NSGraphicsContext restoreGraphicsState];}
            rendered=CGBitmapContextCreateImage(context);CGContextRelease(context);
        }
        if(rendered){objc_setAssociatedObject(self,&renderedImageKey,(id)rendered,OBJC_ASSOCIATION_RETAIN_NONATOMIC);CGImageRelease(rendered);@synchronized(samples){replacements++;}}
    }@finally{renderingOriginal=NO;}
    return rendered?:fallback;
}
NSDictionary *MavericksCatalogDiagnostics(void){@synchronized(samples){return @{@"requests":@(requests),@"replacements":@(replacements),@"sizeMismatches":@(sizeMismatches),@"samples":samples?[[samples copy]autorelease]:@[]};}}
void MavericksCatalogInstall(void) {
    static BOOL installed;if(installed)return;installed=YES;samples=[NSMutableArray new];
    Class catalog=NSClassFromString(@"CUICatalog"),image=NSClassFromString(@"CUINamedImage");
    SEL lookup=NSSelectorFromString(@"_imageWithName:scaleFactor:deviceIdiom:deviceSubtype:displayGamut:layoutDirection:sizeClassHorizontal:sizeClassVertical:memoryClass:graphicsClass:appearanceIdentifier:graphicsFallBackOrder:deviceSubtypeFallBackOrder:");
    Method method=class_getInstanceMethod(catalog,lookup);
    if(!method||strcmp(method_getTypeEncoding(method),"@120@0:8@16d24q32Q40q48q56q64q72Q80Q88q96@104@112"))return;
    nativeCatalogImage=method_getImplementation(method);method_setImplementation(method,(IMP)catalogImage);
    method=class_getInstanceMethod(catalog,NSSelectorFromString(@"initWithURL:error:"));if(method){nativeCatalogURL=method_getImplementation(method);method_setImplementation(method,(IMP)catalogURL);}
    method=class_getInstanceMethod(catalog,NSSelectorFromString(@"initWithName:fromBundle:"));if(method){nativeCatalogName=method_getImplementation(method);method_setImplementation(method,(IMP)catalogName);}
    method=class_getInstanceMethod(catalog,NSSelectorFromString(@"initWithName:fromBundle:error:"));if(method){nativeCatalogNameError=method_getImplementation(method);method_setImplementation(method,(IMP)catalogNameError);}
    method=class_getClassMethod(catalog,NSSelectorFromString(@"defaultUICatalogForBundle:"));if(method){nativeCatalogBundle=method_getImplementation(method);method_setImplementation(method,(IMP)catalogBundle);}
    method=class_getInstanceMethod(image,NSSelectorFromString(@"image"));if(method){nativeImage=method_getImplementation(method);method_setImplementation(method,(IMP)catalogPixels);}
    method=class_getInstanceMethod(image,NSSelectorFromString(@"croppedImage"));if(method){nativeCroppedImage=method_getImplementation(method);method_setImplementation(method,(IMP)catalogPixels);}
}
