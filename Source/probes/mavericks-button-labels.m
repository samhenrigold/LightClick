// Offscreen regression probe: feed Mojave's white default-button title through
// the installed cell and inspect both AppKit's received color and rendered ink.
// No windows are shown and no desktop or display settings are changed.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <dlfcn.h>
static IMP nativeDrawTitle;
static NSColor *receivedColor;
@interface NSButtonCell (LCButtonTitleFieldProbe)
- (NSTextField *)_titleTextField;
- (void)_updateTitleTextFieldValue;
- (void)_updateTitleTextFieldWithFrame:(NSRect)frame inView:(NSView *)view;
@end
@interface LCOffscreenKeyWindow : NSWindow @end
@implementation LCOffscreenKeyWindow
- (BOOL)isKeyWindow {return YES;}
@end
static NSRect recordTitle(id self,SEL selector,NSAttributedString *title,NSRect frame,NSView *view) {
    [receivedColor release];receivedColor=[[title attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL]retain];
    return ((NSRect(*)(id,SEL,id,NSRect,id))nativeDrawTitle)(self,selector,title,frame,view);
}
int main(int argc,char **argv) {@autoreleasepool {
    if(argc!=3)return 64;
    // Exercise the nib-decoding hook as well as programmatic construction.
    NSButton *before=[[[NSButton alloc]initWithFrame:NSMakeRect(0,0,200,40)]autorelease];
    before.bezelStyle=NSRoundedBezelStyle;[before setButtonType:NSMomentaryPushInButton];
    NSData *archive=[NSKeyedArchiver archivedDataWithRootObject:before];
    setenv("MAVERICKS_APPEARANCE_DEFER","1",1);
    void *body=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    void (*install)(int)=body?dlsym(body,"MavericksAppearanceInstall"):NULL;
    if(!install){fprintf(stderr,"%s\n",dlerror());return 65;}install(2);
    [NSApplication sharedApplication];
    Method method=class_getInstanceMethod([NSButtonCell class],@selector(drawTitle:withFrame:inView:));
    nativeDrawTitle=method_getImplementation(method);method_setImplementation(method,(IMP)recordTitle);
    NSMutableArray *results=[NSMutableArray array];BOOL passed=YES;
    NSWindow *window=[[[LCOffscreenKeyWindow alloc]initWithContentRect:NSMakeRect(0,0,200,40)styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO]autorelease];
    NSArray *names=@[@"regular",@"small",@"mini",@"pressed",@"image-bearing",@"archived",@"disabled"];
    for(NSNumber *kind in @[@(NSMomentaryPushInButton),@(NSMomentaryLightButton),@(NSMomentaryChangeButton)])for(NSUInteger index=0;index<names.count;index++) {
        NSButton *button=index==5?[NSKeyedUnarchiver unarchiveObjectWithData:archive]:[[[NSButton alloc]initWithFrame:NSMakeRect(0,0,200,40)]autorelease];
        [button setButtonType:kind.unsignedIntegerValue];button.bezelStyle=NSRoundedBezelStyle;
        [window.contentView addSubview:button];button.keyEquivalent=@"\r";window.defaultButtonCell=(NSButtonCell *)button.cell;
        button.controlSize=index==1?NSSmallControlSize:index==2?NSMiniControlSize:NSRegularControlSize;
        button.enabled=index!=6;button.highlighted=index==3;
        if(index==4){button.image=[NSImage imageNamed:NSImageNameAddTemplate];button.imagePosition=NSImageLeft;}
        NSAttributedString *white=[[[NSAttributedString alloc]initWithString:@"Continue" attributes:@{NSForegroundColorAttributeName:[NSColor whiteColor],NSFontAttributeName:[NSFont systemFontOfSize:14]}]autorelease];
        button.attributedTitle=white;button.attributedAlternateTitle=white;
        NSBitmapImageRep *bitmap=[[[NSBitmapImageRep alloc]initWithBitmapDataPlanes:NULL pixelsWide:200 pixelsHigh:40 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0]autorelease];
        [NSGraphicsContext saveGraphicsState];[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
        [[NSColor whiteColor]setFill];NSRectFill(NSMakeRect(0,0,200,40));
        [receivedColor release];receivedColor=nil;
        [(NSButtonCell *)button.cell drawTitle:white withFrame:NSMakeRect(10,10,180,24) inView:button];
        [[NSGraphicsContext currentContext]flushGraphics];[NSGraphicsContext restoreGraphicsState];
        NSColor *rgb=[receivedColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        NSUInteger blackPixels=0;CGFloat minimum=1;
        for(NSInteger y=0;y<40;y++)for(NSInteger x=0;x<200;x++){
            NSColor *pixel=[[bitmap colorAtX:x y:y]colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            CGFloat maximum=MAX(pixel.redComponent,MAX(pixel.greenComponent,pixel.blueComponent));
            minimum=MIN(minimum,maximum);if(maximum<.1)blackPixels++;
        }
        BOOL black=rgb&&rgb.redComponent==0&&rgb.greenComponent==0&&rgb.blueComponent==0;
        BOOL ok=button.enabled?(black&&blackPixels>0):(rgb&&!black&&minimum>.1&&minimum<.9);
        button.wantsLayer=YES;NSButtonCell *cell=(NSButtonCell *)button.cell;
        [cell _updateTitleTextFieldWithFrame:button.bounds inView:button];[cell _updateTitleTextFieldValue];
        NSTextField *field=[cell _titleTextField];NSColor *fieldColor=[field.textColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        NSColor *attributed=[field.attributedStringValue attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];attributed=[attributed colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        BOOL fieldBlack=fieldColor&&fieldColor.redComponent==0&&fieldColor.greenComponent==0&&fieldColor.blueComponent==0;
        BOOL attributedBlack=attributed&&attributed.redComponent==0&&attributed.greenComponent==0&&attributed.blueComponent==0;
        BOOL fieldOK=field&&[field.cell backgroundStyle]==NSBackgroundStyleLight&&(button.enabled?(fieldBlack&&attributedBlack):(!fieldBlack&&fieldColor.redComponent==.5));
        ok&=fieldOK;
        passed&=ok;
        [results addObject:@{@"case":names[index],@"kind":kind,@"cellClass":NSStringFromClass([button.cell class]),@"passed":@(ok),@"layerTitleFieldPassed":@(fieldOK),@"forwardedRGB":rgb?@[@(rgb.redComponent),@(rgb.greenComponent),@(rgb.blueComponent)]:@[],@"blackPixels":@(blackPixels),@"minimumInk":@(minimum)}];
        NSString *file=[NSString stringWithFormat:@"%s/%@-%@.png",argv[2],kind,names[index]];
        [[bitmap representationUsingType:NSPNGFileType properties:@{}]writeToFile:file atomically:YES];
        [button removeFromSuperview];
    }
    method_setImplementation(method,nativeDrawTitle);
    puts([[[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:@{@"passed":@(passed),@"cases":results} options:NSJSONWritingPrettyPrinted error:NULL]encoding:NSUTF8StringEncoding]autorelease]UTF8String]);
    return passed?0:1;
}}
