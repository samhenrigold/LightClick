#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <CoreText/CoreText.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <dlfcn.h>
static BOOL lcFontRenderingEnabled;
static int lcCoreTextReplacements;
static int namedImageReplacements;
static int originalResourceReplacements;
// Mojave material roles retain their native view hierarchy and interactions;
// a non-vibrant background supplies the corresponding pre-Yosemite surface.
@interface LCClassicMaterial : NSView
@property NSInteger material;
@property BOOL emphasized;
@property(retain) NSImage *shapeMask;
@end
@implementation LCClassicMaterial
- (NSView *)hitTest:(NSPoint)point {return nil;}
- (BOOL)allowsVibrancy {return NO;}
- (BOOL)wantsUpdateLayer {return YES;}
- (void)updateLayer {
    if(self.bounds.size.width<=0||self.bounds.size.height<=0)return;
    NSImage *surface=[[[NSImage alloc]initWithSize:self.bounds.size]autorelease];
    [surface lockFocus];[self drawRect:self.bounds];[surface unlockFocus];
    NSRect rect=NSMakeRect(0,0,surface.size.width,surface.size.height);
    self.layer.contents=(id)[surface CGImageForProposedRect:&rect context:nil hints:nil];
    self.layer.contentsGravity=@"resize";
    if(self.shapeMask){
        NSImage *mask=[[[NSImage alloc]initWithSize:self.bounds.size]autorelease];
        [mask lockFocus];[self.shapeMask drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];[mask unlockFocus];
        CALayer *layer=self.layer.mask;if(!layer){layer=[CALayer layer];self.layer.mask=layer;}
        layer.frame=self.bounds;layer.contents=(id)[mask CGImageForProposedRect:&rect context:nil hints:nil];
    }else self.layer.mask=nil;
}
- (void)dealloc {[_shapeMask release];[super dealloc];}
- (void)drawRect:(NSRect)dirty {
    NSInteger role=self.material;NSColor *top=nil,*bottom=nil;
    if(role==4) {
        NSImage *image=[NSImage imageNamed:self.emphasized?@"LCMavericksSourceListActive":@"LCMavericksSourceListInactive"];
        if(image){[image drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1 respectFlipped:self.isFlipped hints:nil];return;}
    }
    if(role==7){top=[NSColor colorWithSRGBRed:.86 green:.89 blue:.92 alpha:1];bottom=[NSColor colorWithSRGBRed:.76 green:.80 blue:.85 alpha:1];}
    else if(role==3||role==10){top=[NSColor colorWithWhite:.91 alpha:1];bottom=[NSColor colorWithWhite:.72 alpha:1];}
    else if(role==2||role==9||role==13||role==15){top=[NSColor colorWithWhite:.22 alpha:1];bottom=[NSColor colorWithWhite:.12 alpha:1];}
    else if(role==17){top=bottom=[NSColor colorWithSRGBRed:1 green:1 blue:.79 alpha:1];}
    else if(role==18){top=bottom=[NSColor whiteColor];}
    else if(role==22){top=bottom=[NSColor colorWithWhite:.51 alpha:1];}
    else {top=bottom=[NSColor colorWithWhite:(role==5||role==6)?.97:.93 alpha:1];}
    NSGradient *gradient=[[[NSGradient alloc]initWithStartingColor:bottom endingColor:top]autorelease];
    [gradient drawInRect:self.bounds angle:90];
}
@end
static NSFont *originalFont(CGFloat size, BOOL bold) {
    static NSArray *descriptors;
    if(!descriptors) descriptors=(NSArray *)CTFontManagerCreateFontDescriptorsFromURL((CFURLRef)[NSURL fileURLWithPath:@"/Library/Application Support/MavericksAppearance/Fonts/LucidaGrande.ttc"]);
    NSString *wanted=bold?@".LucidaGrandeUI-Bold":@".LucidaGrandeUI";
    for(id desc in descriptors) {
        NSString *name=[(NSString *)CTFontDescriptorCopyAttribute((CTFontDescriptorRef)desc,kCTFontNameAttribute) autorelease];
        if([name isEqual:wanted]) return [(NSFont *)CTFontCreateWithFontDescriptor((CTFontDescriptorRef)desc,size>0?size:13,NULL) autorelease];
    }
    return [NSFont fontWithName:bold?@"LucidaGrande-Bold":@"LucidaGrande" size:size>0?size:13];
}
@interface FontSpike : NSObject
+ (NSFont *)regular:(CGFloat)s;
+ (NSFont *)bold:(CGFloat)s;
+ (NSFont *)weighted:(CGFloat)s weight:(CGFloat)weight;
@end
@implementation FontSpike
+ (NSFont *)regular:(CGFloat)s {
    if(s<=0){NSString *role=NSStringFromSelector(_cmd);
        s=[role isEqual:@"labelFontOfSize:"]?10:[role isEqual:@"controlContentFontOfSize:"]?12:[role isEqual:@"menuBarFontOfSize:"]?14:([role isEqual:@"toolTipsFontOfSize:"]||[role isEqual:@"paletteFontOfSize:"])?11:13;
    }
    return originalFont(s,NO);
}
+ (NSFont *)bold:(CGFloat)s { return originalFont(s,YES); }
+ (NSFont *)weighted:(CGFloat)s weight:(CGFloat)weight {return originalFont(s,weight>=NSFontWeightMedium);}
@end
static IMP oldMove,oldMaterial,oldVibrancy;
static char materialBackgroundKey;
static void updateMaterial(NSVisualEffectView *view) {
    // Titlebar effects can own drawings that are not represented by child
    // views. Their original CoreUI frame renderer remains the shared path.
    LCClassicMaterial *background=objc_getAssociatedObject(view,&materialBackgroundKey);
    if(!view.window)return;
    if(view.material==3){[background removeFromSuperview];objc_setAssociatedObject(view,&materialBackgroundKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);return;}
    if(!background){background=[[[LCClassicMaterial alloc]initWithFrame:view.bounds]autorelease];background.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;background.wantsLayer=YES;[view addSubview:background positioned:NSWindowBelow relativeTo:nil];objc_setAssociatedObject(view,&materialBackgroundKey,background,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    if(background.material!=view.material){background.material=view.material;[background setNeedsDisplay:YES];}
    if(background.shapeMask!=view.maskImage){background.shapeMask=view.maskImage;[background setNeedsDisplay:YES];}
    BOOL active=view.state==NSVisualEffectStateActive||(view.state==NSVisualEffectStateFollowsWindowActiveState&&NSApp.isActive&&(view.window.isMainWindow||view.window.isKeyWindow));
    if(background.emphasized!=active){background.emphasized=active;[background setNeedsDisplay:YES];}
    BOOL dark=view.material==2||view.material==9||view.material==13||view.material==15;
    NSString *appearance=dark?NSAppearanceNameVibrantDark:NSAppearanceNameAqua;
    if(![view.appearance.name isEqual:appearance])[view setAppearance:[NSAppearance appearanceNamed:appearance]];
}
static void moved(id self,SEL cmd){((void(*)(id,SEL))oldMove)(self,cmd);updateMaterial(self);}
static void classicMaterial(id self,SEL cmd,NSInteger role){((void(*)(id,SEL,NSInteger))oldMaterial)(self,cmd,role);updateMaterial(self);}
static BOOL noVibrancy(id self,SEL cmd){return [(NSVisualEffectView *)self material]==3?((BOOL(*)(id,SEL))oldVibrancy)(self,cmd):NO;}
static void refreshMaterials(NSView *view){if([view isKindOfClass:[NSVisualEffectView class]])updateMaterial((NSVisualEffectView *)view);for(NSView *child in view.subviews)refreshMaterials(child);}
@interface LCClassicMaterialObserver : NSObject @end
@implementation LCClassicMaterialObserver
- (void)windowUpdated:(NSNotification *)notification {NSWindow *window=notification.object;if([window isKindOfClass:[NSWindow class]])refreshMaterials(window.contentView.superview?:window.contentView);}
@end

static void installOriginalArtRendering(void);
static void installProgressSubclass(void);
static void installSegmentSubclass(void);
static void installSliderSubclass(void);
static void installWindowBackground(void);
static void installButtonSubclass(void);
static void installArchivedFonts(void);
static void installNamedImages(void);
void MavericksAppearanceInstall(int mode) {
    static BOOL installed=NO;
    if(installed || mode==0) return;
    char version[32]={0}; size_t size=sizeof(version); sysctlbyname("kern.osrelease",version,&size,NULL,0);
    if(atoi(version)!=18) return; // This private-ABI experiment is qualified for Mojave only.
    installed=YES;lcFontRenderingEnabled=YES;
    if(mode==2) { installOriginalArtRendering(); installProgressSubclass(); installSegmentSubclass(); installSliderSubclass(); installButtonSubclass();
        if(getenv("MAVERICKS_APPEARANCE_EXPERIMENTAL_TITLEBAR") && !strcmp(getenv("MAVERICKS_APPEARANCE_EXPERIMENTAL_TITLEBAR"),"1"))installWindowBackground(); }
    if(mode) {
        for(NSString *n in @[@"systemFontOfSize:",@"menuFontOfSize:",@"messageFontOfSize:",@"labelFontOfSize:",@"titleBarFontOfSize:",@"controlContentFontOfSize:",@"menuBarFontOfSize:",@"toolTipsFontOfSize:",@"paletteFontOfSize:"]){
            Method m=class_getClassMethod([NSFont class],NSSelectorFromString(n));
            if(m) method_setImplementation(m,class_getMethodImplementation(object_getClass([FontSpike class]),@selector(regular:)));
        }
        method_setImplementation(class_getClassMethod([NSFont class],@selector(boldSystemFontOfSize:)),
            class_getMethodImplementation(object_getClass([FontSpike class]),@selector(bold:)));
    }
    Method weighted=class_getClassMethod([NSFont class],@selector(systemFontOfSize:weight:));
    if(weighted)method_setImplementation(weighted,class_getMethodImplementation(object_getClass([FontSpike class]),@selector(weighted:weight:)));
    installArchivedFonts();if(mode==2){installNamedImages();void(*catalogInstall)(void)=dlsym(RTLD_DEFAULT,"MavericksCatalogInstall");if(catalogInstall)catalogInstall();void(*coreUIInstall)(void)=dlsym(RTLD_DEFAULT,"MavericksCoreUIInstall");if(coreUIInstall)coreUIInstall();}
    Class effect=NSClassFromString(@"NSVisualEffectView");
    if(mode==2 && effect) {
        LCClassicMaterialObserver *observer=[LCClassicMaterialObserver new];[[NSNotificationCenter defaultCenter]addObserver:observer selector:@selector(windowUpdated:) name:NSWindowDidUpdateNotification object:nil];
        Method m=class_getInstanceMethod(effect,@selector(viewDidMoveToWindow));
        oldMove=method_getImplementation(m);
        class_addMethod(effect,@selector(viewDidMoveToWindow),(IMP)moved,"v@:");
        method_setImplementation(class_getInstanceMethod(effect,@selector(viewDidMoveToWindow)),(IMP)moved);
        Method material=class_getInstanceMethod(effect,@selector(setMaterial:));oldMaterial=method_getImplementation(material);method_setImplementation(material,(IMP)classicMaterial);
        oldVibrancy=class_getMethodImplementation(effect,@selector(allowsVibrancy));
        class_addMethod(effect,@selector(allowsVibrancy),(IMP)noVibrancy,"B@:");
        method_setImplementation(class_getInstanceMethod(effect,@selector(allowsVibrancy)),(IMP)noVibrancy);
    }

}
__attribute__((constructor)) static void initializeAppearance(void) {
    if(!getenv("MAVERICKS_APPEARANCE_DEFER")) MavericksAppearanceInstall(2);
}

// Original ArtFile bitmaps are selected by semantic control state. Cocoa retains its control model,
// target/action dispatch and accessibility; unsupported forms fall through to the original renderer.
static NSImage *art(NSString *name) {
    static NSMutableDictionary *cache;
    if(!cache) cache=[NSMutableDictionary new];
    NSImage *image=cache[name];
    if(!image){ image=[[[NSImage alloc] initWithContentsOfFile:[@"/Library/Application Support/MavericksAppearance/Art" stringByAppendingPathComponent:name]] autorelease];if(image) {
            NSString *retina=[name stringByReplacingOccurrencesOfString:@".png" withString:@"@2x.png"];
            NSData *data=[NSData dataWithContentsOfFile:[@"/Library/Application Support/MavericksAppearance/Art" stringByAppendingPathComponent:retina]];
            if(data && [name hasSuffix:@".png"]){NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:data];rep.size=image.size;[image addRepresentation:rep];}
            cache[name]=image;
        } }
    return image;
}
NSImage *MavericksAppearanceImage(NSString *name) { return art(name); }
static void threePart(NSImage *image, NSRect dst, CGFloat left, CGFloat right, BOOL flipped) {
    NSSize size=image.size;CGFloat middle=size.width-left-right;
    if(dst.size.width<left+right || middle<=0)return;
    CGFloat dx[3]={0,left,dst.size.width-right},dw[3]={left,dst.size.width-left-right,right};
    CGFloat sx[3]={0,left,size.width-right},sw[3]={left,middle,right};
    for(int i=0;i<3;i++)if(dw[i]>0&&sw[i]>0)[image drawInRect:NSMakeRect(dst.origin.x+dx[i],dst.origin.y,dw[i],dst.size.height) fromRect:NSMakeRect(sx[i],0,sw[i],size.height) operation:NSCompositeSourceOver fraction:1 respectFlipped:flipped hints:nil];
}
static IMP originalProgressDraw, originalProgressValue;
static int progressDrawCalls,progressFallbackCalls,buttonImageCalls,buttonBezelCalls,buttonTitleCalls;
static void progressDraw(NSProgressIndicator *view,SEL cmd,NSRect dirty) {
    progressDrawCalls++;
    NSImage *track=art(@"1425.png"),*fill=art(view.window.isKeyWindow?@"1309.png":@"1357.png");
    if(view.style!=NSProgressIndicatorBarStyle || view.indeterminate || view.controlSize!=NSRegularControlSize || !track || !fill) {
        progressFallbackCalls++;
        ((void(*)(id,SEL,NSRect))originalProgressDraw)(view,cmd,dirty);return;
    }
    NSRect bounds=view.bounds;NSRect frame=NSMakeRect(bounds.origin.x,floor(NSMidY(bounds)-9.5),bounds.size.width,19);
    frame.origin.y+=view.isFlipped?1:-1;
    threePart(track,frame,6,6,view.isFlipped);
    double fraction=(view.doubleValue-view.minValue)/(view.maxValue-view.minValue);fraction=MAX(0,MIN(1,fraction));
    NSRect inner=NSMakeRect(frame.origin.x+1,frame.origin.y+1,MAX(0,floor((frame.size.width-2)*fraction)),16);
    if(inner.size.width>0){[NSGraphicsContext saveGraphicsState];NSRect full=inner;full.size.width=frame.size.width-2;NSBezierPath *clip=[NSBezierPath bezierPathWithRoundedRect:full xRadius:3 yRadius:3];[clip addClip];
        [fill drawInRect:inner fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1 respectFlipped:view.isFlipped hints:nil];[NSGraphicsContext restoreGraphicsState];}
}
static void progressValue(NSProgressIndicator *view,SEL cmd,double value) {
    ((void(*)(id,SEL,double))originalProgressValue)(view,cmd,value);[view setNeedsDisplay:YES];
}
static NSColor *legacyWindowBackground(id self,SEL cmd) { return [NSColor colorWithSRGBRed:237.0/255 green:237.0/255 blue:237.0/255 alpha:1]; }
static NSColor *legacyDisabled(id self,SEL cmd) { return [NSColor colorWithSRGBRed:.5 green:.5 blue:.5 alpha:1]; }
static NSColor *legacyBlack(id self,SEL cmd) { NSString *name=[NSAppearance currentAppearance].name;return name&&[name rangeOfString:@"Dark"].location!=NSNotFound?[NSColor whiteColor]:[NSColor blackColor]; }
static void installOriginalArtRendering(void) {
    Method draw=class_getInstanceMethod([NSProgressIndicator class],@selector(drawRect:));originalProgressDraw=method_getImplementation(draw);
    class_addMethod([NSProgressIndicator class],@selector(drawRect:),(IMP)progressDraw,"v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    method_setImplementation(class_getInstanceMethod([NSProgressIndicator class],@selector(drawRect:)),(IMP)progressDraw);
    Method value=class_getInstanceMethod([NSProgressIndicator class],@selector(setDoubleValue:));originalProgressValue=method_getImplementation(value);method_setImplementation(value,(IMP)progressValue);
    Method color=class_getClassMethod([NSColor class],@selector(windowBackgroundColor));method_setImplementation(color,(IMP)legacyWindowBackground);
    method_setImplementation(class_getClassMethod([NSColor class],@selector(disabledControlTextColor)),(IMP)legacyDisabled);
    for(NSString *name in @[@"controlTextColor",@"windowFrameTextColor",@"labelColor"]) { Method m=class_getClassMethod([NSColor class],NSSelectorFromString(name));if(m)method_setImplementation(m,(IMP)legacyBlack); }
}

NSDictionary *MavericksAppearanceDiagnostics(void) { return @{@"originalResourceReplacements":@(originalResourceReplacements),@"namedImageReplacements":@(namedImageReplacements),@"coreTextFontReplacements":@(lcCoreTextReplacements),@"buttonImageCalls":@(buttonImageCalls),@"buttonBezelCalls":@(buttonBezelCalls),@"buttonTitleCalls":@(buttonTitleCalls),@"progressDrawCalls":@(progressDrawCalls),@"progressFallbackCalls":@(progressFallbackCalls),@"originalTrackLoaded":@(art(@"1425.png")!=nil)}; }

@interface LCClassicProgressIndicator : NSProgressIndicator @end
@implementation LCClassicProgressIndicator
- (BOOL)wantsUpdateLayer { return self.style==NSProgressIndicatorBarStyle && !self.indeterminate ? NO : [super wantsUpdateLayer]; }
- (void)drawRect:(NSRect)r { progressDraw(self,_cmd,r); }
@end
static IMP originalProgressFrameInit,originalProgressCoderInit;
static id classicProgressFrame(id self,SEL cmd,NSRect frame) {
    id object=((id(*)(id,SEL,NSRect))originalProgressFrameInit)(self,cmd,frame);
    if(object_getClass(object)==[NSProgressIndicator class])object_setClass(object,[LCClassicProgressIndicator class]);
    return object;
}
static id classicProgressCoder(id self,SEL cmd,id coder) {
    id object=((id(*)(id,SEL,id))originalProgressCoderInit)(self,cmd,coder);
    if(object_getClass(object)==[NSProgressIndicator class])object_setClass(object,[LCClassicProgressIndicator class]);
    return object;
}
static void installProgressSubclass(void) {
    Class cls=[NSProgressIndicator class];
    SEL frame=@selector(initWithFrame:),coder=@selector(initWithCoder:);
    originalProgressFrameInit=class_getMethodImplementation(cls,frame);originalProgressCoderInit=class_getMethodImplementation(cls,coder);
    class_addMethod(cls,frame,(IMP)classicProgressFrame,"@@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    method_setImplementation(class_getInstanceMethod(cls,frame),(IMP)classicProgressFrame);
    class_addMethod(cls,coder,(IMP)classicProgressCoder,"@@:@");method_setImplementation(class_getInstanceMethod(cls,coder),(IMP)classicProgressCoder);
}

@interface NSSegmentedCell (LCOriginalGeometry)
- (NSRect)_rectForSegment:(NSInteger)segment inFrame:(NSRect)frame;
- (NSRect)_labelRectForSegment:(NSInteger)segment inFrame:(NSRect)frame withView:(NSView *)view;
@end
static BOOL supportsOriginalSegments(NSSegmentedCell *cell) {
    if(cell.controlSize!=NSRegularControlSize || (cell.segmentStyle!=NSSegmentStyleAutomatic && cell.segmentStyle!=NSSegmentStyleRounded) || !art(@"1802.png"))return NO;
    for(NSInteger i=0;i<cell.segmentCount;i++)if([cell imageForSegment:i] || [cell menuForSegment:i])return NO;
    return YES;
}
@interface LCClassicSegmentedCell : NSSegmentedCell @end
@implementation LCClassicSegmentedCell
- (NSSize)cellSize {
    NSSize size=[super cellSize];if(supportsOriginalSegments(self)) {for(NSInteger i=0;i<self.segmentCount;i++)if([self widthForSegment:i]==0)size.width-=4;size.height=24;}return size;
}
- (NSRect)_rectForSegment:(NSInteger)segment inFrame:(NSRect)frame {
    NSRect rect=[super _rectForSegment:segment inFrame:frame];
    if(supportsOriginalSegments(self)) {for(NSInteger i=0;i<segment;i++)if([self widthForSegment:i]==0)rect.origin.x-=4;if([self widthForSegment:segment]==0)rect.size.width-=4;}
    return rect;
}
- (NSRect)_labelRectForSegment:(NSInteger)segment inFrame:(NSRect)frame withView:(NSView *)view {
    if(!supportsOriginalSegments(self))return [super _labelRectForSegment:segment inFrame:frame withView:view];
    NSSize size=[[self labelForSegment:segment] sizeWithAttributes:@{NSFontAttributeName:self.font}];
    NSRect rect=NSMakeRect(frame.origin.x,NSMidY(frame)-size.height/2,MIN(frame.size.width,size.width+4),size.height);
    NSRect backing=[view convertRectToBacking:rect];backing.origin.y=ceil(backing.origin.y);
    return [view convertRectFromBacking:backing];
}
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    if(!supportsOriginalSegments(self)){[super drawWithFrame:frame inView:view];return;}
    NSRect body=NSMakeRect(frame.origin.x,floor(NSMidY(frame)-12),self.cellSize.width,24);
    threePart(art(view.window.isKeyWindow&&self.enabled?@"1856.png":@"1838.png"),body,14,14,view.isFlipped);
    for(NSInteger i=0;i<self.segmentCount;i++)[self drawSegment:i inFrame:[self _rectForSegment:i inFrame:frame] withView:view];
}
- (void)drawSegment:(NSInteger)segment inFrame:(NSRect)frame withView:(NSView *)view {
    if(!supportsOriginalSegments(self)){[super drawSegment:segment inFrame:frame withView:view];return;}
    NSRect rect=frame;
    NSRect body=NSMakeRect(frame.origin.x,floor(NSMidY(frame)-12),frame.size.width,24);
    BOOL active=view.window.isKeyWindow,enabled=self.enabled&&[self isEnabledForSegment:segment];

    if([self isSelectedForSegment:segment]) {
        NSString *file=active&&enabled?@"1802.png":@"1848.png";
        NSRect selection=NSMakeRect(rect.origin.x,body.origin.y,rect.size.width,24);if(segment>0){selection.origin.x-=1;selection.size.width+=1;}
        [NSGraphicsContext saveGraphicsState];[[NSBezierPath bezierPathWithRect:selection] addClip];
        NSRect expanded=selection;if(segment>0){expanded.origin.x-=14;expanded.size.width+=14;}if(segment+1<self.segmentCount)expanded.size.width+=14;
        threePart(art(file),expanded,14,14,view.isFlipped);[NSGraphicsContext restoreGraphicsState];
    }
    if(segment>0) {
        BOOL selected=[self isSelectedForSegment:segment]||[self isSelectedForSegment:segment-1];
        NSImage *separator=art(selected?(active&&enabled?@"1803.png":@"1849.png"):(active&&enabled?@"1857.png":@"1839.png"));
        [separator drawInRect:NSMakeRect(rect.origin.x-1,body.origin.y,1,24) fromRect:NSMakeRect(12,0,1,24) operation:NSCompositeSourceOver fraction:1 respectFlipped:view.isFlipped hints:nil];
    }
    NSString *text=[self labelForSegment:segment];
    NSTextFieldCell *label=[[[NSTextFieldCell alloc] initTextCell:text] autorelease];
    label.font=self.font;label.alignment=NSLeftTextAlignment;label.bordered=NO;label.bezeled=NO;
    label.drawsBackground=NO;label.enabled=enabled;label.textColor=enabled?[NSColor blackColor]:[NSColor disabledControlTextColor];
    NSSize textSize=[text sizeWithAttributes:@{NSFontAttributeName:self.font}];
    NSRect textRect=NSMakeRect(rect.origin.x+(segment==0?11:8),NSMidY(rect)-8.5,ceil(textSize.width+4),17);
    if([self widthForSegment:segment]>0)textRect.origin.x=floor(NSMidX(rect)-textRect.size.width/2);
    [label drawWithFrame:textRect inView:view];
}
@end
static IMP originalSegmentFrameInit,originalSegmentCoderInit;
static void classicSegmentCell(id object) { if(object_getClass([object cell])==[NSSegmentedCell class])object_setClass([object cell],[LCClassicSegmentedCell class]); }
static id classicSegmentFrame(id self,SEL cmd,NSRect rect) { id object=((id(*)(id,SEL,NSRect))originalSegmentFrameInit)(self,cmd,rect);classicSegmentCell(object);return object; }
static id classicSegmentCoder(id self,SEL cmd,id coder) { id object=((id(*)(id,SEL,id))originalSegmentCoderInit)(self,cmd,coder);classicSegmentCell(object);return object; }
static void installSegmentSubclass(void) {
    Class cls=[NSSegmentedControl class];SEL frame=@selector(initWithFrame:),coder=@selector(initWithCoder:);
    originalSegmentFrameInit=class_getMethodImplementation(cls,frame);originalSegmentCoderInit=class_getMethodImplementation(cls,coder);
    class_addMethod(cls,frame,(IMP)classicSegmentFrame,"@@:{CGRect={CGPoint=dd}{CGSize=dd}}");method_setImplementation(class_getInstanceMethod(cls,frame),(IMP)classicSegmentFrame);
    class_addMethod(cls,coder,(IMP)classicSegmentCoder,"@@:@");method_setImplementation(class_getInstanceMethod(cls,coder),(IMP)classicSegmentCoder);
}

@interface LCClassicSliderCell : NSSliderCell @end
@implementation LCClassicSliderCell
- (BOOL)lcSupportsOriginalSlider {
    return self.sliderType==NSLinearSlider && self.controlSize==NSRegularControlSize && self.numberOfTickMarks==0 && self.controlView.bounds.size.width>self.controlView.bounds.size.height && art(@"1906.png");
}
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
    if(![self lcSupportsOriginalSlider]){[super drawBarInside:rect flipped:flipped];return;}
    NSString *file=!self.enabled?@"1966.png":self.controlView.window.isKeyWindow?@"1915.png":@"1972.png";
    threePart(art(file),rect,3,3,flipped);
}
- (void)drawKnob:(NSRect)rect {
    if(![self lcSupportsOriginalSlider]){[super drawKnob:rect];return;}
    NSString *file=!self.enabled?@"1927.png":self.highlighted?@"1957.png":@"1906.png";
    [art(file) drawInRect:rect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1 respectFlipped:self.controlView.isFlipped hints:nil];
}
@end
static IMP originalSliderFrameInit,originalSliderCoderInit;
static void classicSliderCell(id object) { if(object_getClass([object cell])==[NSSliderCell class])object_setClass([object cell],[LCClassicSliderCell class]); }
static id classicSliderFrame(id self,SEL cmd,NSRect rect) {id object=((id(*)(id,SEL,NSRect))originalSliderFrameInit)(self,cmd,rect);classicSliderCell(object);return object;}
static id classicSliderCoder(id self,SEL cmd,id coder) {id object=((id(*)(id,SEL,id))originalSliderCoderInit)(self,cmd,coder);classicSliderCell(object);return object;}
static void installSliderSubclass(void) {
    Class cls=[NSSlider class];SEL frame=@selector(initWithFrame:),coder=@selector(initWithCoder:);
    originalSliderFrameInit=class_getMethodImplementation(cls,frame);originalSliderCoderInit=class_getMethodImplementation(cls,coder);
    class_addMethod(cls,frame,(IMP)classicSliderFrame,"@@:{CGRect={CGPoint=dd}{CGSize=dd}}");method_setImplementation(class_getInstanceMethod(cls,frame),(IMP)classicSliderFrame);
    class_addMethod(cls,coder,(IMP)classicSliderCoder,"@@:@");method_setImplementation(class_getInstanceMethod(cls,coder),(IMP)classicSliderCoder);
}

@interface LCClassicTitlebarBackground : NSView @end
@implementation LCClassicTitlebarBackground
- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)stateChanged:(NSNotification *)notification { [self setNeedsDisplay:YES]; }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];[[NSNotificationCenter defaultCenter] removeObserver:self];
    if(self.window)for(NSString *name in @[NSWindowDidBecomeKeyNotification,NSWindowDidResignKeyNotification])[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stateChanged:) name:name object:self.window];
}
- (void)drawRect:(NSRect)dirty {
    NSImage *image=art(self.window.isKeyWindow?@"titlebar-active.tiff":@"titlebar-inactive.tiff");if(!image)return;
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0,-6,self.bounds.size.width,self.bounds.size.height+6) xRadius:4 yRadius:4] addClip];
    for(CGFloat x=0;x<self.bounds.size.width;x+=image.size.width) [image drawInRect:NSMakeRect(x,0,image.size.width,self.bounds.size.height) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1 respectFlipped:self.isFlipped hints:nil];
    // Theme-frame title text is drawn by its parent, so repaint it above this background.
    SEL title=NSSelectorFromString(@"_drawTitleStringInClip:");NSView *frame=self.superview;
    if([frame respondsToSelector:title]) {
        NSAffineTransform *transform=[NSAffineTransform transform];[transform translateXBy:-self.frame.origin.x yBy:-self.frame.origin.y];[transform concat];
        ((void(*)(id,SEL,NSRect))[frame methodForSelector:title])(frame,title,self.frame);
    }
    [NSGraphicsContext restoreGraphicsState];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self];[super dealloc]; }
@end
static IMP originalWindowInit;
static id classicWindowInit(id self,SEL cmd,NSRect rect,NSUInteger style,NSBackingStoreType backing,BOOL defer) {
    NSWindow *window=((id(*)(id,SEL,NSRect,NSUInteger,NSBackingStoreType,BOOL))originalWindowInit)(self,cmd,rect,style,backing,defer);
    if(object_getClass(window)==[NSWindow class] && style&NSTitledWindowMask && !(style&NSFullSizeContentViewWindowMask) && art(@"titlebar-active.tiff")) {
        NSView *frame=window.contentView.superview;window.titlebarAppearsTransparent=YES;
        LCClassicTitlebarBackground *view=[[[LCClassicTitlebarBackground alloc] initWithFrame:NSMakeRect(0,frame.bounds.size.height-22,frame.bounds.size.width,22)] autorelease];
        view.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
        [frame addSubview:view positioned:NSWindowBelow relativeTo:nil];
    }
    return window;
}
static void installWindowBackground(void) {
    Class cls=[NSWindow class];SEL sel=@selector(initWithContentRect:styleMask:backing:defer:);
    originalWindowInit=class_getMethodImplementation(cls,sel);method_setImplementation(class_getInstanceMethod(cls,sel),(IMP)classicWindowInit);
}

// Exact standard cells use Mojave's inspected type and layout ABI, including decoded nib cells.
// Custom cells, attributed colors and unsupported layouts keep their renderer.
@interface NSButtonCell (LCMojaveButtonGeometry)
- (NSUInteger)_buttonType;
- (void)_imageRect:(NSRect *)image titleRect:(NSRect *)title forBounds:(NSRect)bounds;
@end
@interface LCClassicButtonCell : NSButtonCell @end
@implementation LCClassicButtonCell
- (NSInteger)lcOriginalKind {
    if(self.controlSize!=NSRegularControlSize || ![self respondsToSelector:@selector(_buttonType)])return -1;
    NSInteger value=(NSInteger)[self _buttonType];
    BOOL leading=self.imagePosition==NSImageLeft || (self.imagePosition==NSImageLeading && self.controlView.userInterfaceLayoutDirection==NSUserInterfaceLayoutDirectionLeftToRight);
    if((value==NSSwitchButton || value==NSRadioButton) && !leading)return -1;
    NSAttributedString *title=self.attributedTitle;
    for(NSUInteger i=0;i<title.length;i++) {
        NSColor *color=[title attribute:NSForegroundColorAttributeName atIndex:i effectiveRange:NULL];
        if(color){NSColor *rgb=[color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if(!rgb || rgb.redComponent!=0 || rgb.greenComponent!=0 || rgb.blueComponent!=0)return -1;
        }
    }
    if(value==NSMomentaryPushInButton && (self.bezelStyle!=NSRoundedBezelStyle || self.image))return -1;
    return value==NSSwitchButton||value==NSRadioButton||value==NSMomentaryPushInButton?value:-1;
}
- (NSSize)cellSize {
    NSSize size=[super cellSize];NSInteger kind=[self lcOriginalKind];
    if(kind==NSSwitchButton || kind==NSRadioButton)size.height=32;
    return size;
}
- (void)_imageRect:(NSRect *)image titleRect:(NSRect *)title forBounds:(NSRect)bounds {
    [super _imageRect:image titleRect:title forBounds:bounds];NSInteger kind=[self lcOriginalKind];
    if(kind==NSSwitchButton || kind==NSRadioButton) {
        if(image)image->origin.y=floor(NSMidY(bounds)-image->size.height/2);
        if(title)title->origin.y=floor(NSMidY(bounds)-title->size.height/2)-1;
    } else if(kind==NSMomentaryPushInButton && title) title->origin.y=floor(NSMidY(bounds)-title->size.height/2)-3;
}
- (BOOL)_subclassOverridesDrawImage {return [self lcOriginalKind]>=0;}
- (void)drawImage:(NSImage *)image withFrame:(NSRect)rect inView:(NSView *)view {
    NSInteger kind=[self lcOriginalKind];
    if(kind!=NSSwitchButton && kind!=NSRadioButton){[super drawImage:image withFrame:rect inView:view];return;}
    BOOL active=view.window.isKeyWindow,pressed=self.highlighted;
    NSInteger offset=self.state==NSMixedState?0:self.state==NSOffState?2:4;
    NSInteger base=kind==NSSwitchButton?(!self.enabled?123:pressed?114:active?87:132):(!self.enabled?1527:pressed?1518:active?1491:1536);
    NSImage *original=art([NSString stringWithFormat:@"%04ld.png",(long)(base+offset)]);
    if(!original){[super drawImage:image withFrame:rect inView:view];return;}
    buttonImageCalls++;
    [original drawInRect:rect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1 respectFlipped:view.isFlipped hints:nil];
}
- (void)drawBezelWithFrame:(NSRect)rect inView:(NSView *)view {
    if([self lcOriginalKind]!=NSMomentaryPushInButton){[super drawBezelWithFrame:rect inView:view];return;}
    BOOL defaultButton=[self.keyEquivalent isEqual:@"\r"] && view.window.isKeyWindow;
    NSString *file=!self.enabled?@"1450.png":!view.window.isKeyWindow?@"1453.png":self.highlighted?(defaultButton?@"1443.png":@"1457.png"):defaultButton?@"1445.png":@"1459.png";
    if(!art(file)){[super drawBezelWithFrame:rect inView:view];return;}
    buttonBezelCalls++;NSRect body=NSMakeRect(rect.origin.x,NSMidY(rect)-16,rect.size.width,32);
    threePart(art(file),body,20,20,view.isFlipped);
}
- (NSRect)drawTitle:(NSAttributedString *)title withFrame:(NSRect)frame inView:(NSView *)view {
    if([self lcOriginalKind]<0)return [super drawTitle:title withFrame:frame inView:view];
    buttonTitleCalls++;
    NSMutableAttributedString *text=[[title mutableCopy] autorelease];
    NSString *appearance=view.effectiveAppearance.name;BOOL dark=[self lcOriginalKind]!=NSMomentaryPushInButton&&appearance&&[appearance rangeOfString:@"Dark"].location!=NSNotFound;
    [text addAttribute:NSForegroundColorAttributeName value:self.enabled?(dark?[NSColor whiteColor]:[NSColor blackColor]):[NSColor disabledControlTextColor] range:NSMakeRange(0,text.length)];
    return [super drawTitle:text withFrame:frame inView:view];
}
@end
static IMP originalButtonFrameInit,originalButtonCoderInit,originalButtonCellCoderInit;
static void classicButtonCell(id object) {if(object_getClass([object cell])==[NSButtonCell class])object_setClass([object cell],[LCClassicButtonCell class]);}
static id classicButtonCellCoder(id self,SEL cmd,id coder) {
    id object=((id(*)(id,SEL,id))originalButtonCellCoderInit)(self,cmd,coder);
    if(object_getClass(object)==[NSButtonCell class])object_setClass(object,[LCClassicButtonCell class]);return object;
}
static id classicButtonFrame(id self,SEL cmd,NSRect rect) {id object=((id(*)(id,SEL,NSRect))originalButtonFrameInit)(self,cmd,rect);classicButtonCell(object);return object;}
static id classicButtonCoder(id self,SEL cmd,id coder) {id object=((id(*)(id,SEL,id))originalButtonCoderInit)(self,cmd,coder);classicButtonCell(object);return object;}
static void installButtonSubclass(void) {
    Class cell=[NSButtonCell class];SEL cellCoder=@selector(initWithCoder:);
    originalButtonCellCoderInit=class_getMethodImplementation(cell,cellCoder);
    class_addMethod(cell,cellCoder,(IMP)classicButtonCellCoder,"@@:@");method_setImplementation(class_getInstanceMethod(cell,cellCoder),(IMP)classicButtonCellCoder);
    Class cls=[NSButton class];SEL frame=@selector(initWithFrame:),coder=@selector(initWithCoder:);
    originalButtonFrameInit=class_getMethodImplementation(cls,frame);originalButtonCoderInit=class_getMethodImplementation(cls,coder);
    class_addMethod(cls,frame,(IMP)classicButtonFrame,"@@:{CGRect={CGPoint=dd}{CGSize=dd}}");method_setImplementation(class_getInstanceMethod(cls,frame),(IMP)classicButtonFrame);
    class_addMethod(cls,coder,(IMP)classicButtonCoder,"@@:@");method_setImplementation(class_getInstanceMethod(cls,coder),(IMP)classicButtonCoder);
}

static IMP originalFontDecoder,originalFontDescriptorFactory;
static NSFont *legacyDescriptor(NSFontDescriptor *descriptor,CGFloat size) {
    NSString *name=[descriptor objectForKey:NSFontNameAttribute];NSFontSymbolicTraits traits=descriptor.symbolicTraits;
    if((![name hasPrefix:@".AppleSystemUIFont"] && ![name hasPrefix:@".SFNS"]) || [name rangeOfString:@"Mono"].location!=NSNotFound || traits&(NSFontMonoSpaceTrait|NSFontItalicTrait|NSFontExpandedTrait|NSFontCondensedTrait))return nil;
    return originalFont(size>0?size:descriptor.pointSize,(traits&NSFontBoldTrait)!=0 || [name rangeOfString:@"Bold"].location!=NSNotFound || [name rangeOfString:@"Semibold"].location!=NSNotFound);
}
static id classicFontDescriptor(id cls,SEL cmd,NSFontDescriptor *descriptor,CGFloat size) {
    NSFont *font=legacyDescriptor(descriptor,size);return font?:((id(*)(id,SEL,id,CGFloat))originalFontDescriptorFactory)(cls,cmd,descriptor,size);
}
static id classicFontDecoder(id self,SEL cmd,NSCoder *coder) {
    NSFont *decoded=((id(*)(id,SEL,id))originalFontDecoder)(self,cmd,coder);
    NSFont *replacement=legacyDescriptor(decoded.fontDescriptor,decoded.pointSize);
    if(!replacement)return decoded;[replacement retain];[decoded release];return replacement;
}
static void installArchivedFonts(void) {
    Method factory=class_getClassMethod([NSFont class],@selector(fontWithDescriptor:size:));
    if(factory){originalFontDescriptorFactory=method_getImplementation(factory);method_setImplementation(factory,(IMP)classicFontDescriptor);}
    Method decoder=class_getInstanceMethod([NSFont class],@selector(initWithCoder:));
    if(decoder){originalFontDecoder=method_getImplementation(decoder);method_setImplementation(decoder,(IMP)classicFontDecoder);}
}

// CoreText clients (menu rendering and private framework controls included) bypass NSFont factories.
// Interpose their UI font construction at process launch, retaining native fonts for explicit document faces.
static __thread BOOL lcInsideFontConstruction;
static CTFontRef originalUIFontReplacement(CTFontRef font) {
    if(!font || !lcFontRenderingEnabled)return font;
    @autoreleasepool {
        NSString *name=(NSString *)CTFontCopyPostScriptName(font);
        CTFontSymbolicTraits traits=CTFontGetSymbolicTraits(font);
        BOOL system=[name hasPrefix:@".SFNS"] || [name hasPrefix:@".SFUI"] || [name hasPrefix:@".AppleSystemUIFont"];
        BOOL supported=system && !(traits&(kCTFontMonoSpaceTrait|kCTFontItalicTrait|kCTFontExpandedTrait|kCTFontCondensedTrait)) && [name rangeOfString:@"Mono"].location==NSNotFound;
        BOOL bold=(traits&kCTFontBoldTrait)!=0 || [name rangeOfString:@"Bold"].location!=NSNotFound || [name rangeOfString:@"Semibold"].location!=NSNotFound;
        [name release];if(!supported)return font;
        CTFontRef replacement=(CTFontRef)CFRetain((CTFontRef)originalFont(CTFontGetSize(font),bold));
        if(replacement){lcCoreTextReplacements++;CFRelease(font);return replacement;}
        return font;
    }
}
static CTFontRef classicCTUIFont(CTFontUIFontType type,CGFloat size,CFStringRef language) {
    BOOL nested=lcInsideFontConstruction;lcInsideFontConstruction=YES;
    CTFontRef font=CTFontCreateUIFontForLanguage(type,size,language);
    if(!nested)font=originalUIFontReplacement(font);lcInsideFontConstruction=nested;return font;
}
static CTFontRef classicCTDescriptor(CTFontDescriptorRef descriptor,CGFloat size,const CGAffineTransform *matrix) {
    BOOL nested=lcInsideFontConstruction;lcInsideFontConstruction=YES;
    CTFontRef font=CTFontCreateWithFontDescriptor(descriptor,size,matrix);
    if(!nested)font=originalUIFontReplacement(font);lcInsideFontConstruction=nested;return font;
}
static CTFontRef classicCTName(CFStringRef name,CGFloat size,const CGAffineTransform *matrix) {
    BOOL nested=lcInsideFontConstruction;lcInsideFontConstruction=YES;
    CTFontRef font=CTFontCreateWithName(name,size,matrix);
    if(!nested)font=originalUIFontReplacement(font);lcInsideFontConstruction=nested;return font;
}
#define LC_FONT_INTERPOSE(replacement,original) \
    __attribute__((used)) static struct {const void *replace;const void *original;} \
    lc_interpose_##original __attribute__((section("__DATA,__interpose")))={(const void *)(replacement),(const void *)(original)}
LC_FONT_INTERPOSE(classicCTUIFont,CTFontCreateUIFontForLanguage);
LC_FONT_INTERPOSE(classicCTDescriptor,CTFontCreateWithFontDescriptor);
LC_FONT_INTERPOSE(classicCTName,CTFontCreateWithName);

static IMP nativeImageNamed,nativeBundleImage;
static NSMutableDictionary *nativePrivateImageMethods;
static NSImage *originalNamedImage(NSString *name) {
    if(![name isKindOfClass:[NSString class]] || [name containsString:@"/"])return nil;
    static NSMutableDictionary *images;static NSDictionary *metadata;static dispatch_once_t once;
    dispatch_once(&once,^{
        images=[NSMutableDictionary new];NSMutableDictionary *map=[NSMutableDictionary dictionary];
        NSData *data=[NSData dataWithContentsOfFile:@"/Library/Application Support/MavericksAppearance/NamedImages/manifest.json"];
        NSDictionary *manifest=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
        for(NSDictionary *row in manifest[@"images"])map[row[@"name"]]=row;metadata=[map copy];
    });
    NSString *key=[name stringByDeletingPathExtension];NSDictionary *row=metadata[key];if(!row)return nil;
    @synchronized(images){NSImage *cached=images[key];if(cached)return cached;}
    NSString *base=@"/Library/Application Support/MavericksAppearance/NamedImages";
    NSImage *image=[[[NSImage alloc] initWithContentsOfFile:[base stringByAppendingPathComponent:[key stringByAppendingString:@".png"]]] autorelease];
    if(!image)return nil;NSSize size=NSMakeSize([row[@"width"] doubleValue],[row[@"height"] doubleValue]);image.size=size;
    NSData *retina=[NSData dataWithContentsOfFile:[base stringByAppendingPathComponent:[key stringByAppendingString:@"@2x.png"]]];
    if(retina){NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:retina];rep.size=size;[image addRepresentation:rep];}
    image.template=[row[@"template"] boolValue];
    @synchronized(images){images[key]=image;namedImageReplacements++;}
    return image;
}
static NSImage *loadOriginalResourceImage(NSString *name,NSBundle *bundle) {
    if(![name isKindOfClass:[NSString class]]||[name containsString:@"/"]||![bundle isKindOfClass:[NSBundle class]])return nil;
    static NSSet *paths;static NSCache *cache;static dispatch_once_t once;
    dispatch_once(&once,^{NSData *data=[NSData dataWithContentsOfFile:@"/Library/Application Support/MavericksAppearance/LegacyResources.json"];id array=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;NSMutableSet *resolved=[NSMutableSet set];if([array isKindOfClass:[NSArray class]])for(NSString *path in array)[resolved addObject:[path stringByResolvingSymlinksInPath]];paths=[resolved copy];cache=[NSCache new];cache.countLimit=256;});
    NSString *path=[[bundle pathForImageResource:name]stringByResolvingSymlinksInPath];
    if(![paths containsObject:path])return nil;
    NSImage *image=[cache objectForKey:path];
    if(!image){image=[[[NSImage alloc]initWithContentsOfFile:path]autorelease];if(!image)return nil;
        if([[path stringByDeletingPathExtension]hasSuffix:@"@2x"])image.size=NSMakeSize(image.size.width/2,image.size.height/2);
        else if([[path pathExtension]caseInsensitiveCompare:@"png"]==NSOrderedSame){NSString *retina=[[[path stringByDeletingPathExtension]stringByAppendingString:@"@2x"]stringByAppendingPathExtension:path.pathExtension];if([paths containsObject:retina]){NSImageRep *rep=[NSBitmapImageRep imageRepWithContentsOfFile:retina];if(rep){rep.size=image.size;[image addRepresentation:rep];}}}
        if([name hasSuffix:@"Template"])image.template=YES;[cache setObject:image forKey:path];}
    originalResourceReplacements++;return image;
}
static __thread BOOL loadingOriginalResource;
static NSImage *originalResourceImage(NSString *name,NSBundle *bundle) {
    if(loadingOriginalResource)return nil;loadingOriginalResource=YES;
    @try{return loadOriginalResourceImage(name,bundle);}@finally{loadingOriginalResource=NO;}
}
static NSImage *classicImageNamed(id cls,SEL cmd,NSString *name) {return originalNamedImage(name)?:originalResourceImage(name,[NSBundle mainBundle])?:((id(*)(id,SEL,id))nativeImageNamed)(cls,cmd,name);}
static NSImage *classicBundleImage(id bundle,SEL cmd,NSString *name) {return originalNamedImage(name)?:originalResourceImage(name,bundle)?:((id(*)(id,SEL,id))nativeBundleImage)(bundle,cmd,name);}
static NSImage *classicPrivateImage(id cls,SEL cmd,NSString *name) {
    NSImage *replacement=originalNamedImage(name)?:originalResourceImage(name,[NSBundle mainBundle]);if(replacement)return replacement;
    IMP native=[nativePrivateImageMethods[NSStringFromSelector(cmd)]pointerValue];
    return ((id(*)(id,SEL,id))native)(cls,cmd,name);
}
static NSImage *classicCatalogImage(id cls,SEL cmd,NSString *name,id bundle) {
    NSImage *replacement=originalNamedImage(name)?:originalResourceImage(name,bundle?:[NSBundle mainBundle]);if(replacement)return replacement;
    IMP native=[nativePrivateImageMethods[NSStringFromSelector(cmd)]pointerValue];
    return ((id(*)(id,SEL,id,id))native)(cls,cmd,name,bundle);
}
static void installNamedImages(void) {
    nativePrivateImageMethods=[NSMutableDictionary new];
    for(NSString *name in @[@"_imageNamed:",@"_coreUIImageWithName:",@"_searchForImageNamed:",@"_searchForSystemImageNamed:",@"_catalogIconImageWithName:bundle:",@"_catalogImageWithName:bundle:"]) {
        Method method=class_getClassMethod([NSImage class],NSSelectorFromString(name));if(!method)continue;
        nativePrivateImageMethods[name]=[NSValue valueWithPointer:method_getImplementation(method)];
        method_setImplementation(method,[name containsString:@"bundle:"]?(IMP)classicCatalogImage:(IMP)classicPrivateImage);
    }
    Method image=class_getClassMethod([NSImage class],@selector(imageNamed:));nativeImageNamed=method_getImplementation(image);method_setImplementation(image,(IMP)classicImageNamed);
    Method bundle=class_getInstanceMethod([NSBundle class],@selector(imageForResource:));
    if(bundle){nativeBundleImage=method_getImplementation(bundle);method_setImplementation(bundle,(IMP)classicBundleImage);}
}

NSImage *MavericksAppearanceOriginalImage(NSString *name,NSBundle *bundle){return originalNamedImage(name)?:originalResourceImage(name,bundle);}
