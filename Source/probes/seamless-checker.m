// A checkerboard behind everything in a guest, at an offset /tmp/seamless-check-offset says, for comparing what a
// guest's material does to what's behind it with what a host's does: seamless-gpu-viewer draws the same one with
// SEAMLESS_CHECKER set.
//
// clang -arch x86_64 -mmacosx-version-min=10.14 -fno-objc-arc -framework Cocoa seamless-checker.m
#import <Cocoa/Cocoa.h>

@interface CheckerView : NSView
@property int offset;
@end
@implementation CheckerView
- (BOOL)isFlipped {
    return YES;
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [NSColor.whiteColor setFill];
    NSRectFill(self.bounds);
    [NSColor.blackColor setFill];
    for (int y = 0; y < self.bounds.size.height; y += 40)
        for (int x = -80 + self.offset % 80 + (y / 40 % 2) * 40; x < self.bounds.size.width; x += 80)
            NSRectFill(NSMakeRect(x, y, 40, 40));
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSScreen.mainScreen.frame
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        window.level = kCGDesktopWindowLevel;
        window.ignoresMouseEvents = YES;
        CheckerView *view = [[CheckerView alloc] initWithFrame:window.contentView.bounds];
        window.contentView = view;
        [window setFrame:NSScreen.mainScreen.frame display:YES];
        [window orderFrontRegardless];
        [NSTimer scheduledTimerWithTimeInterval:0.25
                                        repeats:YES
                                          block:^(NSTimer *timer) {
                                            (void)timer;
                                            int offset =
                                                [NSString stringWithContentsOfFile:@"/tmp/seamless-check-offset"
                                                                          encoding:NSUTF8StringEncoding
                                                                             error:NULL]
                                                    .intValue;
                                            if (offset != view.offset) {
                                                view.offset = offset;
                                                view.needsDisplay = YES;
                                            }
                                          }];
        [app run];
    }
    return 0;
}
