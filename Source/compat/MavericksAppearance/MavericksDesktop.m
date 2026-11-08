// Desktop hooks run inside the real Mojave shell processes in the disposable guest.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <sys/sysctl.h>
extern BOOL MavericksAppearanceProcessSupported(void);
extern NSDictionary *MavericksAppearanceDiagnostics(void);
extern NSDictionary *MavericksCoreUIDiagnostics(void);
extern NSDictionary *MavericksCatalogDiagnostics(void);

@interface LCGlassDockShelf : CALayer @end
@implementation LCGlassDockShelf
- (void)drawInContext:(CGContextRef)c {
    CGRect r=self.bounds;CGFloat w=r.size.width,h=r.size.height,lip=MIN(7,h*.15),inset=MIN(26,h*.48);
    CGContextSaveGState(c);
    CGMutablePathRef plane=CGPathCreateMutable();CGPathMoveToPoint(plane,NULL,0,lip);
    CGPathAddLineToPoint(plane,NULL,w,lip);CGPathAddLineToPoint(plane,NULL,w-inset,h-1);
    CGPathAddLineToPoint(plane,NULL,inset,h-1);CGPathCloseSubpath(plane);
    CGContextAddPath(c,plane);CGContextClip(c);
    CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat colors[]={.68,.71,.74,.95, .90,.92,.94,.65, .73,.77,.80,.70};CGFloat stops[]={0,.65,1};
    CGGradientRef gradient=CGGradientCreateWithColorComponents(cs,colors,stops,3);
    CGContextDrawLinearGradient(c,gradient,CGPointMake(0,lip),CGPointMake(0,h),0);
    CGGradientRelease(gradient);CGColorSpaceRelease(cs);CGContextRestoreGState(c);
    CGContextAddPath(c,plane);CGContextSetRGBStrokeColor(c,.98,.99,1,.80);CGContextSetLineWidth(c,1);CGContextStrokePath(c);CGPathRelease(plane);
    CGContextSetRGBFillColor(c,.66,.69,.72,.94);CGContextFillRect(c,CGRectMake(0,0,w,lip));
    CGContextSetRGBStrokeColor(c,.24,.27,.30,.7);CGContextMoveToPoint(c,0,0.5);CGContextAddLineToPoint(c,w,.5);CGContextStrokePath(c);
}
@end
static IMP originalFloorLayout;
static IMP originalIndicatorDisplay;
static char shelfKey;
static CGImageRef originalDockGlass(void) {
    static CGImageRef image;static dispatch_once_t once;
    dispatch_once(&once,^{CGDataProviderRef data=CGDataProviderCreateWithFilename("/Library/Application Support/MavericksAppearance/Art/mavericks-glass@2x.png");if(data){image=CGImageCreateWithPNGDataProvider(data,NULL,YES,kCGRenderingIntentDefault);CGDataProviderRelease(data);}});
    return image;
}
static CGImageRef originalDockIndicator(void) {
    static CGImageRef image;static dispatch_once_t once;
    dispatch_once(&once,^{CGDataProviderRef data=CGDataProviderCreateWithFilename("/System/Library/CoreServices/Dock.app/Contents/Resources/indicator_medium@2x.png");if(data){image=CGImageCreateWithPNGDataProvider(data,NULL,YES,kCGRenderingIntentDefault);CGDataProviderRelease(data);}});
    return image;
}
static void displayClassicIndicator(CALayer *layer,SEL cmd) {
    CGImageRef image=originalDockIndicator();
    if(image&&layer.bounds.size.width>layer.bounds.size.height*1.5){layer.contents=(id)image;layer.contentsGravity=kCAGravityResize;return;}
    if(originalIndicatorDisplay)((void(*)(id,SEL))originalIndicatorDisplay)(layer,cmd);
}
static void restyleDockIndicators(CALayer *layer,int depth) {
    if(!layer||depth>5)return;
    if([NSStringFromClass(layer.class)isEqual:@"DOCKIndicatorLayer"]&&originalDockIndicator()){
        CGRect frame=layer.frame;CGFloat center=CGRectGetMidX(frame);
        layer.backgroundColor=CGColorGetConstantColor(kCGColorClear);layer.cornerRadius=0;layer.opaque=NO;layer.mask=nil;layer.filters=nil;layer.compositingFilter=nil;
        layer.zPosition=1000;
        layer.contentsScale=2;layer.needsDisplayOnBoundsChange=YES;
        layer.frame=CGRectMake(center-27,0,54,12);[layer setNeedsDisplay];
    }
    for(CALayer *child in layer.sublayers)restyleDockIndicators(child,depth+1);
}
static CGImageRef originalDockSeparator(void) {
    static CGImageRef image;static dispatch_once_t once;
    dispatch_once(&once,^{CGDataProviderRef data=CGDataProviderCreateWithFilename("/System/Library/CoreServices/Dock.app/Contents/Resources/separator@2x.png");if(data){image=CGImageCreateWithPNGDataProvider(data,NULL,YES,kCGRenderingIntentDefault);CGDataProviderRelease(data);}});return image;
}
static char separatorKey;
static void collectDockIcons(CALayer *layer,CALayer *floor,BOOL tile,BOOL excluded,int depth,NSMutableArray *images) {
    if(!layer||layer==floor||depth>12||layer.hidden||layer.opacity<.01)return;
    NSString *name=[NSStringFromClass(layer.class)stringByAppendingFormat:@" %@",layer.name?:@""];
    tile=tile||[name rangeOfString:@"tile"options:NSCaseInsensitiveSearch].location!=NSNotFound;
    for(NSString *part in @[@"shadow",@"badge",@"indicator",@"reflection"])if([name rangeOfString:part options:NSCaseInsensitiveSearch].location!=NSNotFound)excluded=YES;
    if(excluded)return;
    id contents=layer.contents;CGRect bounds=layer.bounds;
    if(tile&&contents&&CFGetTypeID((CFTypeRef)contents)==CGImageGetTypeID()&&bounds.size.width>=24&&bounds.size.width<=192&&bounds.size.height>=24&&bounds.size.height<=192){
        CGRect rect=[layer convertRect:bounds toLayer:floor];
        [images addObject:@{@"contents":contents,@"rect":[NSValue valueWithRect:NSRectFromCGRect(rect)],@"gravity":layer.contentsGravity?:kCAGravityResizeAspect}];
    }
    for(CALayer *child in layer.sublayers)collectDockIcons(child,floor,tile,excluded,depth+1,images);
}
static void updateDockReflections(CALayer *floor,CALayer *shelf) {
    CALayer *container=shelf.sublayers.firstObject;
    if(!container){container=[CALayer layer];container.name=@"Mavericks icon reflections";container.masksToBounds=YES;[shelf addSublayer:container];
        CAGradientLayer *fade=[CAGradientLayer layer];fade.colors=@[(id)CGColorGetConstantColor(kCGColorClear),(id)CGColorGetConstantColor(kCGColorBlack)];fade.locations=@[@0,@.34];fade.startPoint=CGPointMake(.5,0);fade.endPoint=CGPointMake(.5,1);container.mask=fade;container.opacity=.38;}
    container.frame=shelf.bounds;container.mask.frame=container.bounds;
    NSMutableArray *images=[NSMutableArray array];CALayer *root=floor.superlayer;
    if(root.superlayer)root=root.superlayer;
    collectDockIcons(root,floor,NO,NO,0,images);
    NSArray *previous=container.sublayers;NSMutableArray *reflections=[NSMutableArray array];NSUInteger index=0;
    for(NSDictionary *image in images){CGRect source=NSRectToCGRect([image[@"rect"]rectValue]);
        if(CGRectGetMinY(source)<0||CGRectGetMinY(source)>floor.bounds.size.height)continue;
        CALayer *reflection=index<previous.count?previous[index]:[CALayer layer];index++;
        reflection.contents=image[@"contents"];reflection.contentsGravity=image[@"gravity"];reflection.contentsScale=shelf.contentsScale;
        reflection.transform=CATransform3DIdentity;
        reflection.frame=CGRectMake(source.origin.x-shelf.frame.origin.x,source.origin.y-shelf.frame.origin.y-source.size.height,source.size.width,source.size.height);
        reflection.transform=CATransform3DMakeScale(1,-1,1);[reflections addObject:reflection];
    }
    container.sublayers=reflections;
}
static void classicFloorLayout(CALayer *floor,SEL cmd) {
    ((void(*)(id,SEL))originalFloorLayout)(floor,cmd);
    if(floor.bounds.size.width<floor.bounds.size.height || floor.bounds.size.width<50)return;
    LCGlassDockShelf *shelf=objc_getAssociatedObject(floor,&shelfKey);
    if(!shelf) {
        shelf=[LCGlassDockShelf layer];shelf.name=@"Mavericks glass shelf";
        shelf.contentsScale=[NSScreen mainScreen].backingScaleFactor?:2;
        shelf.shadowColor=CGColorGetConstantColor(kCGColorBlack);shelf.shadowOpacity=.45;shelf.shadowRadius=4;shelf.shadowOffset=CGSizeMake(0,-2);
        objc_setAssociatedObject(floor,&shelfKey,shelf,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [floor addSublayer:shelf];
    }
    // The native floor owns only the background; Dock tiles and their event handling remain siblings.
    for(CALayer *child in floor.sublayers)if(child!=shelf){
        CGRect frame=child.frame;BOOL separator=objc_getAssociatedObject(child,&separatorKey)!=nil||([NSStringFromClass(child.class)isEqual:@"CALayer"]&&frame.size.width<=2&&frame.size.height>=15);
        if(separator&&originalDockSeparator()){
            objc_setAssociatedObject(child,&separatorKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);CGFloat center=CGRectGetMidX(frame);
            child.hidden=NO;child.backgroundColor=CGColorGetConstantColor(kCGColorClear);child.borderWidth=0;child.contents=(id)originalDockSeparator();child.contentsScale=2;child.contentsGravity=kCAGravityResize;child.frame=CGRectMake(center-14.5,0,29,66);child.zPosition=10;
        }else child.hidden=YES;
    }
    floor.backgroundColor=CGColorGetConstantColor(kCGColorClear);floor.borderWidth=0;floor.masksToBounds=NO;
    [CATransaction begin];[CATransaction setDisableActions:YES];shelf.frame=floor.bounds;
    CGImageRef glass=originalDockGlass();
    if(glass){CGRect frame=floor.bounds;frame.size.height=MIN(frame.size.height,43);
        CALayer *root=floor.superlayer;if(root.superlayer)root=root.superlayer;NSMutableArray *icons=[NSMutableArray array];collectDockIcons(root,floor,NO,NO,0,icons);
        CGFloat left=0,right=frame.size.width;
        for(NSDictionary *icon in icons){CGRect r=NSRectToCGRect([icon[@"rect"]rectValue]);left=MIN(left,CGRectGetMinX(r)-28);right=MAX(right,CGRectGetMaxX(r)+28);}
        frame.origin.x=left;frame.size.width=right-left;shelf.frame=frame;shelf.contents=(id)glass;shelf.contentsScale=2;shelf.contentsGravity=kCAGravityResize;shelf.contentsCenter=CGRectMake(.5,.5,0,0);shelf.shadowOpacity=0;}
    else [shelf setNeedsDisplay];
    updateDockReflections(floor,shelf);CALayer *root=floor.superlayer;if(root.superlayer)root=root.superlayer;restyleDockIndicators(root,0);[CATransaction commit];
}
static NSDictionary *layerTree(CALayer *layer,int depth) {
    if(!layer || depth>7)return @{};NSMutableArray *children=[NSMutableArray array];
    for(CALayer *child in layer.sublayers)[children addObject:layerTree(child,depth+1)];
    return @{@"class":NSStringFromClass(layer.class),@"name":layer.name?:@"",@"frame":NSStringFromRect(NSRectFromCGRect(layer.frame)),@"hidden":@(layer.hidden),@"children":children};
}
static NSDictionary *viewTree(NSView *view,int depth) {
    if(!view || depth>9)return @{};NSMutableArray *children=[NSMutableArray array];
    for(NSView *child in view.subviews)[children addObject:viewTree(child,depth+1)];
    NSMutableDictionary *row=[NSMutableDictionary dictionaryWithDictionary:@{@"class":NSStringFromClass(view.class),@"frame":NSStringFromRect(view.frame),@"hidden":@(view.hidden),@"children":children}];
    if(view.layer)row[@"layer"]=layerTree(view.layer,0);
    if([view isKindOfClass:[NSVisualEffectView class]])row[@"material"]=@([(NSVisualEffectView *)view material]);
    if([view isKindOfClass:[NSTableView class]]) {
        NSTableView *table=(NSTableView *)view;NSMutableArray *available=[NSMutableArray array];
        [table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *item,NSInteger index){NSMutableDictionary *r=[NSMutableDictionary dictionaryWithDictionary:@{@"index":@(index),@"class":NSStringFromClass(item.class),@"selected":@(item.isSelected)}];if(item.isSelected)r[@"view"]=viewTree(item,0);[available addObject:r];}];
        row[@"table"]=@{@"selection":table.selectedRowIndexes.description,@"rows":available,@"highlight":@(table.selectionHighlightStyle)};
    }
    return row;
}
static void restyleFinderView(NSView *view,BOOL sidebar) {
    sidebar=sidebar || [NSStringFromClass(view.class) containsString:@"Sidebar"];
    if(sidebar) {
        if([view isKindOfClass:[NSScrollView class]])[(NSScrollView *)view setDrawsBackground:NO];
        if([view isKindOfClass:[NSTableView class]] && ![[(NSTableView *)view backgroundColor] isEqual:[NSColor clearColor]])[(NSTableView *)view setBackgroundColor:[NSColor clearColor]];
    }
    for(NSView *child in view.subviews)restyleFinderView(child,sidebar);
}
@interface LCFinderAppearanceController : NSObject @end
@implementation LCFinderAppearanceController
- (void)update:(NSNotification *)note {
    for(NSWindow *window in NSApp.windows)if([NSStringFromClass(window.class) isEqual:@"TBrowserWindow"])restyleFinderView(window.contentView,NO);
}
@end
static void reportDesktop(void) {
    NSMutableDictionary *classes=[NSMutableDictionary dictionary];unsigned count=0;Class *all=objc_copyClassList(&count);
    for(unsigned i=0;i<count;i++) {
        NSString *name=NSStringFromClass(all[i]);
        if(!([name containsString:@"Floor"] || [name containsString:@"Tile"] || [name containsString:@"MenuBar"] || [name containsString:@"StatusBar"] || [name containsString:@"Sidebar"]))continue;
        unsigned n=0;Method *methods=class_copyMethodList(all[i],&n);NSMutableArray *list=[NSMutableArray array];
        for(unsigned j=0;j<n;j++)[list addObject:@{@"selector":NSStringFromSelector(method_getName(methods[j])),@"encoding":@(method_getTypeEncoding(methods[j]))}];
        free(methods);classes[name]=list;
    }
    free(all);NSMutableArray *windows=[NSMutableArray array];
    for(NSWindow *window in NSApp.windows)[windows addObject:@{@"class":NSStringFromClass(window.class),@"title":window.title?:@"",@"frame":NSStringFromRect(window.frame),@"view":viewTree(window.contentView.superview,0)}];
    NSMutableArray *contexts=[NSMutableArray array];Class contextClass=NSClassFromString(@"CAContext");SEL contextsSelector=NSSelectorFromString(@"allContexts");
    if([contextClass respondsToSelector:contextsSelector]) {
        id allContexts=((id(*)(id,SEL))[contextClass methodForSelector:contextsSelector])(contextClass,contextsSelector);
        if([allContexts isKindOfClass:[NSArray class]])for(id context in allContexts) @try {
            id layer=[context valueForKey:@"layer"];if([layer isKindOfClass:[CALayer class]])[contexts addObject:layerTree(layer,0)];
        } @catch(id exception){}
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"catalogImages":MavericksCatalogDiagnostics(),@"coreUI":MavericksCoreUIDiagnostics(),@"appearanceDiagnostics":MavericksAppearanceDiagnostics(),@"contexts":contexts,@"classes":classes,@"windows":windows} options:0 error:NULL];
    [data writeToFile:[@"/tmp/MavericksAppearance-" stringByAppendingFormat:@"%@.json",[NSProcessInfo processInfo].processName] atomically:YES];
}
__attribute__((constructor)) static void initializeDesktop(void) {
    if(!MavericksAppearanceProcessSupported())return;
    char release[32]={0};size_t size=sizeof(release);sysctlbyname("kern.osrelease",release,&size,NULL,0);if(atoi(release)!=18)return;
    NSString *name=[NSProcessInfo processInfo].processName;
    if(![@[@"Dock",@"Finder",@"SystemUIServer"] containsObject:name])return;
    if([name isEqual:@"Finder"]) {
        LCFinderAppearanceController *controller=[LCFinderAppearanceController new];
        [[NSNotificationCenter defaultCenter] addObserver:controller selector:@selector(update:) name:NSWindowDidUpdateNotification object:nil];
    }
    if([name isEqual:@"Dock"]) {
        Class indicator=NSClassFromString(@"DOCKIndicatorLayer");SEL draw=@selector(display);
        if(indicator){Method method=class_getInstanceMethod(indicator,draw);originalIndicatorDisplay=method_getImplementation(method);class_addMethod(indicator,draw,(IMP)displayClassicIndicator,method_getTypeEncoding(method));method_setImplementation(class_getInstanceMethod(indicator,draw),(IMP)displayClassicIndicator);}
        Class floor=NSClassFromString(@"Dock.FloorLayer")?:NSClassFromString(@"DOCKFloorLayer");SEL selector=@selector(layoutSublayers);
        if(floor) {
            Method method=class_getInstanceMethod(floor,selector);originalFloorLayout=method_getImplementation(method);
            class_addMethod(floor,selector,(IMP)classicFloorLayout,method_getTypeEncoding(method));
            method_setImplementation(class_getInstanceMethod(floor,selector),(IMP)classicFloorLayout);
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{reportDesktop();});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{reportDesktop();});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),dispatch_get_main_queue(),^{reportDesktop();});
}
