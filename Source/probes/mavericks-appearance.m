// Bounded native AppKit appearance experiment. Modes: 0 stock, 1 process-local Lucida Grande,
// 2 original-font and control rendering. All hooks stay inside the test process.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#include <copyfile.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include "seamless-session-join.h"
static NSMutableArray *segmentDrawTrace;
@interface LCReferenceSegmentCell : NSSegmentedCell @end
@implementation LCReferenceSegmentCell
- (void)drawSegment:(NSInteger)segment inFrame:(NSRect)rect withView:(NSView *)view {
    if(!segmentDrawTrace)segmentDrawTrace=[NSMutableArray new];
    if(segmentDrawTrace.count<12)[segmentDrawTrace addObject:@{@"segment":@(segment),@"frame":NSStringFromRect(rect)}];
    [super drawSegment:segment inFrame:rect withView:view];
}
@end
static double now(void) { return [NSDate timeIntervalSinceReferenceDate]; }
static int darwin_major(void) {
    char release[32] = "";
    size_t size = sizeof(release);
    sysctlbyname("kern.osrelease", release, &size, NULL, 0);
    return atoi(release);
}

static pid_t console_finder(uid_t uid) {
    char command[64];
    snprintf(command, sizeof(command), "/usr/bin/pgrep -x -U %u Finder", uid);
    FILE *pipe = popen(command, "r");
    int pid = 0;
    if (pipe) {
        if (fscanf(pipe, "%d", &pid) != 1)
            pid = 0;
        pclose(pipe);
    }
    return pid;
}

// Runs this program again inside the console user's session, as that user, and returns its status.
static int run_in_console_session(char **argv) {
    struct stat console = {0};
    pid_t finder = 0;
    // Short of guest-bench's request timeout, with the time limit in main.
    double waited = now();
    while (now() - waited < 300) {
        if (!stat("/dev/console", &console) && console.st_uid >= 501 && (finder = console_finder(console.st_uid)))
            break;
        sleep(2);
    }
    if (!finder) {
        fprintf(stderr, "gpu-bench: no one logged in to the desktop after 300 s\n");
        return 75;
    }
    // Let a desktop that has only just come up settle, or the first tests measure Finder and Dock starting.
    if (now() - waited > 5)
        sleep(30);
    // The agent's staging folder is root's alone.
    char dylib[256]={0};
    char self[4096], directory[] = "/tmp/gpu-bench.XXXXXX", copy[64], account[32];
    uint32_t length = sizeof(self);
    if (_NSGetExecutablePath(self, &length) || !mkdtemp(directory))
        return 74;
    snprintf(copy, sizeof(copy), "%s/gpu-bench", directory);
    snprintf(account, sizeof(account), "#%u", console.st_uid);
    if (chmod(directory, 0755) || copyfile(self, copy, NULL, COPYFILE_DATA) || chmod(copy, 0755))
        return 74;
    if(argv[3] && argv[3][0] && strcmp(argv[1],"--launch")) {
        snprintf(dylib,sizeof(dylib),"%s/Appearance.dylib",directory);
        if(copyfile(argv[3],dylib,NULL,COPYFILE_DATA)||chmod(dylib,0755)) return 74;
    }
    BOOL modern = darwin_major() >= 14;
    char target[16];
    snprintf(target, sizeof(target), "%d", modern ? (int)console.st_uid : finder);
    char *arguments[16] = {"/bin/launchctl",
                           modern ? "asuser" : "bsexec",
                           target,
                           "/usr/bin/sudo",
                           "-S",
                           "-u",
                           account,
                           "/usr/bin/env",
                           "-i",
                           "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                           copy};
    for (int i = 11, from = 1; i < 15 && argv[from]; i++, from++)
        arguments[i] = argv[from];
    if(dylib[0]) arguments[13]=dylib;
    fflush(NULL);
    pid_t child = fork();
    if (child == 0) {
        // -S with no input can't prompt.
        freopen("/dev/null", "r", stdin);
        if (modern) {
            execv(arguments[0], arguments);
        } else if (join_session_of(finder)) {
            printf("# ERROR couldn't join the session of Finder, pid %d: %s\n", finder, strerror(errno));
            fflush(stdout);
        } else {
            // Past launchctl: see seamless-session-join.h.
            execv(arguments[3], arguments + 3);
        }
        _exit(127);
    }
    int status = 1;
    if (child < 0 || waitpid(child, &status, 0) < 0)
        status = 1;
    if(dylib[0]) unlink(dylib);
    unlink(copy);
    rmdir(directory);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}


@interface LegacyBackground : NSView @end
@implementation LegacyBackground
- (BOOL)allowsVibrancy { return NO; }
- (void)drawRect:(NSRect)r {
    NSGradient *g = [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:.86 green:.89 blue:.92 alpha:1]
        endingColor:[NSColor colorWithCalibratedRed:.76 green:.80 blue:.85 alpha:1]] autorelease];
    [g drawInRect:self.bounds angle:90];
}
@end
@interface Target : NSObject
@property int clicks;
- (void)clicked:(id)sender;
@end
@implementation Target
- (void)clicked:(id)sender { self.clicks++; }
@end
static NSTextField *label(NSString *s, NSRect r) {
    NSTextField *t=[[[NSTextField alloc] initWithFrame:r] autorelease];
    t.stringValue=s; t.editable=NO; t.bordered=NO; t.drawsBackground=NO; return t;
}
int main(int argc,char **argv) { @autoreleasepool {
    if (geteuid()==0) return run_in_console_session(argv);
    NSDictionary *(*diagnostics)(void)=NULL;
    int mode=argc>1?atoi(argv[1]):0;
    CFArrayRef modes=CGDisplayCopyAllDisplayModes(CGMainDisplayID(),(CFDictionaryRef)@{(id)kCGDisplayShowDuplicateLowResolutionModes:@YES});
    CGDisplayModeRef choice=NULL;
    for(id obj in (NSArray *)modes) {
        CGDisplayModeRef candidate=(CGDisplayModeRef)obj;
        size_t width=CGDisplayModeGetWidth(candidate),height=CGDisplayModeGetHeight(candidate);
        if(width*2==CGDisplayModeGetPixelWidth(candidate) && height*2==CGDisplayModeGetPixelHeight(candidate) && width>=1024 && width<=1920 && height>=700) {
            if(!choice || (width==1280 && height==800)) choice=candidate;
            if(width==1280 && height==800) break;
        }
    }
    if(choice) CGDisplaySetDisplayMode(CGMainDisplayID(),choice,NULL);
    if(modes) CFRelease(modes);
    NSData *archivedUI=[NSKeyedArchiver archivedDataWithRootObject:[NSFont systemFontOfSize:13]];
    NSData *archivedDocumentFont=[NSKeyedArchiver archivedDataWithRootObject:[NSFont fontWithName:@"Helvetica" size:12]];
    NSMutableArray *archivedCells=[NSMutableArray array];
    for(NSNumber *kind in @[@0,@3,@4]) {
        NSButtonCell *cell=[[[NSButtonCell alloc] initTextCell:@"Archived control"] autorelease];[cell setButtonType:kind.integerValue];
        [archivedCells addObject:[NSKeyedArchiver archivedDataWithRootObject:cell]];
    }
    if(mode && argc>3) {
        setenv("MAVERICKS_APPEARANCE_DEFER","1",1);
        void *image=dlopen(argv[3],RTLD_NOW|RTLD_LOCAL);
        void (*install)(int)=image?dlsym(image,"MavericksAppearanceInstall"):NULL;
        if(!install) { fprintf(stderr,"Appearance library: %s\n",dlerror()); return 5; }
        install(mode);
        diagnostics=dlsym(image,"MavericksAppearanceDiagnostics");
    }
    Class effect=NSClassFromString(@"NSVisualEffectView");
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; [NSApp finishLaunching];
    NSWindow *w=[[[NSWindow alloc] initWithContentRect:NSMakeRect(80,80,840,500)
        styleMask:NSTitledWindowMask|NSClosableWindowMask|NSMiniaturizableWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];
    w.title=@"Mavericks appearance spike — native controls";
    NSView *v=w.contentView;
    NSView *sidebar;
    if(effect) { sidebar=[[[effect alloc] initWithFrame:NSMakeRect(0,0,190,500)] autorelease];
        [sidebar setValue:@7 forKey:@"material"]; }
    else sidebar=[[[LegacyBackground alloc] initWithFrame:NSMakeRect(0,0,190,500)] autorelease];
    for(int i=0;i<5;i++) [sidebar addSubview:label(@[@"FAVORITES",@"Applications",@"Documents",@"Downloads",@"Shared"][i],NSMakeRect(18,450-i*32,165,24))];
    [v addSubview:sidebar];
    [v addSubview:label(@"Standard AppKit controls",NSMakeRect(215,445,520,28))];
    Target *target=[[[Target alloc] init] autorelease];
    NSMutableArray *metrics=[NSMutableArray array];
    NSArray *titles=@[@"Default button",@"Checkbox",@"Radio button"];
    for(int i=0;i<3;i++) {
        NSButton *b=[[[NSButton alloc] initWithFrame:NSMakeRect(215,390-i*45,210,32)] autorelease];
        b.title=titles[i]; [b setButtonType:i==0?NSMomentaryPushInButton:i==1?NSSwitchButton:NSRadioButton];
        b.bezelStyle=NSRoundedBezelStyle; b.target=target; b.action=@selector(clicked:);
        if(i==0) b.keyEquivalent=@"\r"; [v addSubview:b];
        [metrics addObject:@{@"imagePosition":@(b.imagePosition),@"attributedTitle":[b.attributedTitle description],@"buttonKind":@([b.cell respondsToSelector:NSSelectorFromString(@"_buttonType")]?((NSUInteger(*)(id,SEL))[b.cell methodForSelector:NSSelectorFromString(@"_buttonType")])(b.cell,NSSelectorFromString(@"_buttonType")):NSUIntegerMax),@"imageRect":NSStringFromRect([b.cell imageRectForBounds:b.bounds]),@"titleRect":NSStringFromRect([b.cell titleRectForBounds:b.bounds]),@"imageName":b.image.name?:@"none",@"alternateImageName":b.alternateImage.name?:@"none",@"control":b.title,@"font":b.font.fontName?:@"",@"size":@(b.font.pointSize),@"cellWidth":@([b.cell cellSize].width),@"cellHeight":@([b.cell cellSize].height)}];
        [b performClick:nil];
    }
    NSPopUpButton *pop=[[[NSPopUpButton alloc] initWithFrame:NSMakeRect(470,390,300,28)] autorelease];
    [pop addItemsWithTitles:@[@"Popup menu selection",@"List view",@"Column view"]]; [v addSubview:pop];
    NSTextField *field=[[[NSTextField alloc] initWithFrame:NSMakeRect(470,340,300,25)] autorelease]; field.stringValue=@"Text metrics: Ag 0123456789"; [v addSubview:field];
    NSSlider *slider=[[[NSSlider alloc] initWithFrame:NSMakeRect(215,210,540,25)] autorelease]; slider.doubleValue=.6; [v addSubview:slider];
    NSProgressIndicator *progress=[[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(215,160,540,20)] autorelease]; progress.indeterminate=NO; progress.doubleValue=65; [v addSubview:progress];
    NSSegmentedControl *seg=[[[NSSegmentedControl alloc] initWithFrame:NSMakeRect(215,100,400,30)] autorelease]; if(!mode)object_setClass(seg.cell,[LCReferenceSegmentCell class]); seg.segmentCount=3; seg.target=target;seg.action=@selector(clicked:);
    for(int i=0;i<3;i++) [seg setLabel:@[@"Icons",@"List",@"Gallery"][i] forSegment:i]; [seg setSelected:YES forSegment:2]; [v addSubview:seg];
    if(mode==2 && [[NSFileManager defaultManager] fileExistsAtPath:@"/Library/Desktop Pictures/Mavericks Wave.jpg"])
        for(NSScreen *screen in [NSScreen screens]) [[NSWorkspace sharedWorkspace] setDesktopImageURL:[NSURL fileURLWithPath:@"/Library/Desktop Pictures/Mavericks Wave.jpg"] forScreen:screen options:@{} error:NULL];
    [w makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:3];
    while([end timeIntervalSinceNow]>0) { NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:.05] inMode:NSDefaultRunLoopMode dequeue:YES]; if(event) [NSApp sendEvent:event]; [NSApp updateWindows]; }
    if(argc>4 && !strcmp(argv[4],"disabled")) {
        NSMutableArray *queue=[NSMutableArray arrayWithObject:v];
        while(queue.count){NSView *item=[queue lastObject];[queue removeLastObject];if([item isKindOfClass:[NSControl class]])[(NSControl *)item setEnabled:NO];[queue addObjectsFromArray:item.subviews];}
    }
    if(argc>4 && !strcmp(argv[4],"inactive")) { [w resignKeyWindow]; [NSApp deactivate]; }
    if(argc>4 && !strncmp(argv[4],"progress",8)) progress.doubleValue=atof(argv[4]+8);
    BOOL requestedInactive=argc>4 && !strcmp(argv[4],"inactive");
    if(!requestedInactive){if(argc>4 && !strcmp(argv[4],"disabled"))[w makeFirstResponder:nil];[w makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
    [w display];[CATransaction flush];
    NSDate *settle=[NSDate dateWithTimeIntervalSinceNow:.5];
    while([settle timeIntervalSinceNow]>0) {NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:.02] inMode:NSDefaultRunLoopMode dequeue:YES];if(event)[NSApp sendEvent:event];[NSApp updateWindows];}
    [w display];[CATransaction flush];
    BOOL capturedKey=w.isKeyWindow,capturedActive=[NSApp isActive];
    NSDictionary *capturedStates=@{@"fieldEnabled":@(field.enabled),@"segmentsEnabled":@(seg.enabled),@"progressValue":@(progress.doubleValue)};
    CGImageRef cg=CGWindowListCreateImage(CGRectNull,kCGWindowListOptionIncludingWindow,(CGWindowID)w.windowNumber,kCGWindowImageBoundsIgnoreFraming);
    if(!cg) return 3;
    NSBitmapImageRep *rep=[[[NSBitmapImageRep alloc] initWithCGImage:cg] autorelease]; CGImageRelease(cg);
    NSString *path=argc>2?@(argv[2]):@"/tmp/appearance-spike.png";
    BOOL saved=[[rep representationUsingType:NSPNGFileType properties:@{}] writeToFile:path atomically:YES];
    NSMutableArray *segmentClicks=[NSMutableArray array];
    // Send actual window mouse events at centers and both sides of the original boundaries.
    NSInteger actionsBeforeSegments=target.clicks;
    NSArray *clickXs=@[@28.5,@56.5,@57.5,@78.5,@99.5,@100.5,@133.5];
    for(NSNumber *x in ((argc<=4 || !strcmp(argv[4],"active"))?clickXs:@[])) {
        NSPoint point=NSMakePoint(seg.frame.origin.x+x.doubleValue,NSMidY(seg.frame));
        NSEvent *up=[NSEvent mouseEventWithType:NSLeftMouseUp location:point modifierFlags:0 timestamp:1 windowNumber:w.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0];
        NSEvent *down=[NSEvent mouseEventWithType:NSLeftMouseDown location:point modifierFlags:0 timestamp:0 windowNumber:w.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
        [NSApp postEvent:up atStart:YES];[w sendEvent:down];
        [segmentClicks addObject:@{@"x":x,@"selected":@(seg.selectedSegment),@"actions":@(target.clicks-actionsBeforeSegments)}];
    }
    [seg setSelectedSegment:2];
    NSMutableArray *matrix=[NSMutableArray array];
    for(NSNumber *height in @[@18,@24,@32,@40]) for(NSNumber *kind in @[@0,@3,@4]) {
        NSButton *test=[[[NSButton alloc] initWithFrame:NSMakeRect(0,0,210,height.doubleValue)] autorelease];
        test.title=@"Sample"; [test setButtonType:kind.integerValue]; test.bezelStyle=NSRoundedBezelStyle;
        [matrix addObject:@{@"imageRect":NSStringFromRect([test.cell imageRectForBounds:test.bounds]),@"titleRect":NSStringFromRect([test.cell titleRectForBounds:test.bounds]),@"frameHeight":height,@"type":kind,@"cellWidth":@([test.cell cellSize].width),@"cellHeight":@([test.cell cellSize].height)}];
    }
    NSMutableArray *decodedCells=[NSMutableArray array];
    for(NSData *archive in archivedCells) {
        NSButtonCell *cell=[NSKeyedUnarchiver unarchiveObjectWithData:archive];
        [decodedCells addObject:@{@"class":NSStringFromClass(cell.class),@"font":cell.font.fontName,@"size":@(cell.font.pointSize),@"cellSize":NSStringFromSize(cell.cellSize),@"imageRect":NSStringFromRect([cell imageRectForBounds:NSMakeRect(0,0,210,32)]),@"titleRect":NSStringFromRect([cell titleRectForBounds:NSMakeRect(0,0,210,32)])}];
    }
    NSFont *decodedUI=[NSKeyedUnarchiver unarchiveObjectWithData:archivedUI];
    NSFont *decodedDocument=[NSKeyedUnarchiver unarchiveObjectWithData:archivedDocumentFont];
    NSMutableDictionary *fontRoles=[NSMutableDictionary dictionary];
    for(NSString *name in @[@"systemFontOfSize:",@"boldSystemFontOfSize:",@"menuFontOfSize:",@"menuBarFontOfSize:",@"messageFontOfSize:",@"labelFontOfSize:",@"titleBarFontOfSize:",@"controlContentFontOfSize:",@"toolTipsFontOfSize:",@"paletteFontOfSize:"]){
        SEL selector=NSSelectorFromString(name);if([NSFont respondsToSelector:selector]){NSFont *font=((id(*)(id,SEL,CGFloat))[NSFont methodForSelector:selector])([NSFont class],selector,0);fontRoles[name]=@{@"name":font.fontName,@"size":@(font.pointSize)};}
    }
    NSColor *focusColor=[[NSColor keyboardFocusIndicatorColor] colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    NSArray *focusRGBA=focusColor?@[@(focusColor.redComponent),@(focusColor.greenComponent),@(focusColor.blueComponent),@(focusColor.alphaComponent)]:@[];
    NSMutableDictionary *titleInfo=[NSMutableDictionary dictionary];
    id frameView=w.contentView.superview;
    for(NSString *name in @[@"_currentTitleTextFieldAttributedString",@"_normalTitleBarFillColor"]) {
        SEL selector=NSSelectorFromString(name);
        if([frameView respondsToSelector:selector]) {
            id value=((id(*)(id,SEL))[frameView methodForSelector:selector])(frameView,selector);
            titleInfo[name]=[value description]?:@"nil";
            if([value isKindOfClass:[NSAttributedString class]] && [value length]) {
                NSDictionary *attrs=[value attributesAtIndex:0 effectiveRange:NULL];NSMutableDictionary *details=[NSMutableDictionary dictionary];
                for(id key in attrs)details[[key description]]=[attrs[key] description];titleInfo[@"attributes"]=details;
            }
            if([value isKindOfClass:[NSColor class]] && [[value colorSpaceName] isEqual:NSPatternColorSpace]) value=[value patternImage];
            if([value isKindOfClass:[NSImage class]]) {
                NSString *path=[NSString stringWithFormat:@"/tmp/lc-titlebar-%d.tiff",mode];
                [[value TIFFRepresentation] writeToFile:path atomically:YES];titleInfo[@"textureFile"]=path;titleInfo[@"textureSize"]=NSStringFromSize([value size]);
            }
        }
    }
    SEL drawOriginalTitle=NSSelectorFromString(@"_drawTitleBarBackgroundInClipRect:");
    if(!mode && [frameView respondsToSelector:drawOriginalTitle]) {
        CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context=CGBitmapContextCreate(NULL,16,44,8,64,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(cs);
        [NSGraphicsContext saveGraphicsState];[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:context flipped:NO]];
        CGContextScaleCTM(context,2,2);CGContextTranslateCTM(context,-400,-500);
        ((void(*)(id,SEL,NSRect))[frameView methodForSelector:drawOriginalTitle])(frameView,drawOriginalTitle,NSMakeRect(400,500,8,22));
        [NSGraphicsContext restoreGraphicsState];CGImageRef image=CGBitmapContextCreateImage(context);
        NSBitmapImageRep *texture=[[[NSBitmapImageRep alloc] initWithCGImage:image] autorelease];texture.size=NSMakeSize(8,22);
        NSString *file=@"/tmp/lc-titlebar-render-0.tiff";[[texture TIFFRepresentation] writeToFile:file atomically:YES];titleInfo[@"renderTextureFile"]=file;
        CGImageRelease(image);CGContextRelease(context);
    }
    SEL titleSelector=NSSelectorFromString(@"_titleTextField");
    if([frameView respondsToSelector:titleSelector]) {
        id field=((id(*)(id,SEL))[frameView methodForSelector:titleSelector])(frameView,titleSelector);
        if([field respondsToSelector:@selector(font)]) {titleInfo[@"fontName"]=[[field font] fontName];titleInfo[@"fontSize"]=@([[field font] pointSize]);}
        if([field respondsToSelector:@selector(textColor)])titleInfo[@"textColor"]=[[field textColor] description];
    }
    titleInfo[@"factoryFont"]=[NSFont titleBarFontOfSize:0].fontName;
    titleInfo[@"factorySize"]=@([NSFont titleBarFontOfSize:0].pointSize);
    Ivar titleIvar=class_getInstanceVariable([frameView class],"_titleCell");
    if(titleIvar && ivar_getTypeEncoding(titleIvar)[0]=='@') {
        id cell=object_getIvar(frameView,titleIvar);
        if([cell respondsToSelector:@selector(font)]) {titleInfo[@"actualFont"]=[[cell font] fontName];titleInfo[@"actualSize"]=@([[cell font] pointSize]);}
    }
    NSMutableArray *segmentOptions=[NSMutableArray array];
    SEL optionSelector=NSSelectorFromString(@"_copyCoreUIBackgroundDrawOptionsForSegment:inView:drawFlags:");
    SEL rectSelector=NSSelectorFromString(@"_rectForSegment:inFrame:");
    for(NSInteger i=0;i<seg.segmentCount;i++) {
        NSMutableDictionary *row=[NSMutableDictionary dictionary];
        if([seg.cell respondsToSelector:optionSelector]) {
            NSUInteger flags=0;
            CFDictionaryRef options=((CFDictionaryRef(*)(id,SEL,NSInteger,id,NSUInteger *))[seg.cell methodForSelector:optionSelector])(seg.cell,optionSelector,i,seg,&flags);
            for(id key in (NSDictionary *)options) row[[key description]]=[[(NSDictionary *)options objectForKey:key] description];
            if(options)CFRelease(options);
        }
        if([seg.cell respondsToSelector:rectSelector]) {
            NSRect rect=((NSRect(*)(id,SEL,NSInteger,NSRect))[seg.cell methodForSelector:rectSelector])(seg.cell,rectSelector,i,seg.bounds);
            row[@"layoutRect"]=NSStringFromRect(rect);
            SEL lab=NSSelectorFromString(@"_labelRectForSegment:inFrame:withView:");
            if([seg.cell respondsToSelector:lab]) row[@"labelRect"]=NSStringFromRect(((NSRect(*)(id,SEL,NSInteger,NSRect,id))[seg.cell methodForSelector:lab])(seg.cell,lab,i,rect,seg));
            SEL legacyLabel=NSSelectorFromString(@"_legacy_labelRectForSegment:inFrame:withView:");
            if([seg.cell respondsToSelector:legacyLabel]) row[@"legacyLabelRect"]=NSStringFromRect(((NSRect(*)(id,SEL,NSInteger,NSRect,id))[seg.cell methodForSelector:legacyLabel])(seg.cell,legacyLabel,i,rect,seg));
            row[@"stringSize"]=NSStringFromSize([[seg labelForSegment:i] sizeWithAttributes:@{NSFontAttributeName:seg.font}]);
            SEL legacy=NSSelectorFromString(@"_legacy_rectForSegment:inFrame:");
            if([seg.cell respondsToSelector:legacy]) row[@"legacyLayoutRect"]=NSStringFromRect(((NSRect(*)(id,SEL,NSInteger,NSRect))[seg.cell methodForSelector:legacy])(seg.cell,legacy,i,seg.bounds));
        }
        [segmentOptions addObject:row];
    }
    NSMutableArray *segmentRaw=[NSMutableArray array];
    @try {for(id item in [seg.cell valueForKey:@"_segmentItems"]) {
        NSMutableDictionary *row=[NSMutableDictionary dictionary];
        for(NSString *key in @[@"_labelRect",@"_width",@"_shrinkage",@"_displayWidth"]) @try {row[key]=[[item valueForKey:key] description];} @catch(id exception){}
        [segmentRaw addObject:row];
    }} @catch(id exception){}
    NSMutableArray *segmentMetrics=[NSMutableArray array];
    for(NSInteger i=0;i<seg.segmentCount;i++) [segmentMetrics addObject:@{@"label":[seg labelForSegment:i],@"width":@([seg widthForSegment:i])}];
    NSDictionary *report=@{@"decodedCells":decodedCells,@"decodedUIFont":decodedUI.fontName,@"decodedDocumentFont":decodedDocument.fontName,@"fontRoles":fontRoles,@"capturedActive":@(capturedActive),@"capturedKey":@(capturedKey),@"capturedStates":capturedStates,@"segmentDrawTrace":segmentDrawTrace?:@[],@"segmentRaw":segmentRaw,@"segmentClicks":segmentClicks,@"focusRGBA":focusRGBA,@"titleInfo":titleInfo,@"progressViewClass":NSStringFromClass(progress.class),@"progressWantsLayer":@(progress.wantsLayer),@"progressWantsUpdateLayer":@(progress.wantsUpdateLayer),@"progressLayerClass":progress.layer?NSStringFromClass(progress.layer.class):@"none",@"appearanceDiagnostics":diagnostics?diagnostics():@{},@"segmentOptions":segmentOptions,@"segmentFont":seg.font.fontName,@"sliderCellSize":NSStringFromSize([slider.cell cellSize]),@"sliderKnobRect":NSStringFromRect([(NSSliderCell *)slider.cell knobRectFlipped:slider.isFlipped]),@"sliderBarRect":NSStringFromRect([(NSSliderCell *)slider.cell barRectFlipped:slider.isFlipped]),@"segmentFontSize":@(seg.font.pointSize),@"segmentCellSize":NSStringFromSize([seg.cell cellSize]),@"segments":segmentMetrics,@"metricMatrix":matrix,@"backingScale":@(w.backingScaleFactor),@"active":@([NSApp isActive]),@"keyWindow":@(w.isKeyWindow),@"mode":@(mode),@"systemFont":[NSFont systemFontOfSize:13].fontName,@"controls":metrics,
        @"actions":@(target.clicks),@"png":path,@"saved":@(saved),@"width":@(rep.pixelsWide),@"height":@(rep.pixelsHigh),@"materialHook":@(mode==2&&effect!=Nil)};
    puts([[[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL] encoding:NSUTF8StringEncoding] autorelease] UTF8String]);
    BOOL clicksPass=target.clicks==3+(NSInteger)segmentClicks.count;
    for(NSDictionary *click in segmentClicks) {double x=[click[@"x"] doubleValue];if([click[@"selected"] integerValue]!=(x<57?0:x<100?1:2))clicksPass=NO;}
    return saved && clicksPass?0:4;
} }
