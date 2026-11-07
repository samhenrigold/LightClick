// One app with two animated windows, for telling whether a covered window goes quiet because the app stops drawing or
// because the compositor leaves it out. Run as an app, in a guest's session. /tmp/seamless-two-mode says what animates:
// "draw", AppKit drawing from a timer, or "ca", a Core Animation animation the app has no part in once it's set. When
// /tmp/seamless-two-cover appears, the second window goes under the first, covered exactly. /tmp/seamless-two.txt has
// each window's counts, each second.
//
// clang -arch x86_64 -mmacosx-version-min=10.9 -fno-objc-arc -framework Cocoa -framework QuartzCore
// seamless-two-windows.m
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

@interface TwoView : NSView
@property unsigned long long draws;
@end
@implementation TwoView
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    self.draws = self.draws + 1;
    [NSColor.whiteColor setFill];
    NSRectFill(self.bounds);
    [NSColor.blueColor setFill];
    NSRectFill(NSMakeRect((CGFloat)(self.draws * 4 % 400), 100, 100, 100));
}
@end

@interface TwoApp : NSObject <NSApplicationDelegate>
@end
@implementation TwoApp {
    NSWindow *windows[2];
    TwoView *views[2];
    unsigned long long ticks;
    BOOL covered, drawing;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    NSString *mode = [NSString stringWithContentsOfFile:@"/tmp/seamless-two-mode"
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    drawing = ![[mode stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqual:@"ca"];
    for (int i = 0; i < 2; i++) {
        windows[i] = [[NSWindow alloc] initWithContentRect:NSMakeRect(120 + i * 560, 200, 500, 400)
                                                 styleMask:NSTitledWindowMask
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
        windows[i].title = i ? @"Second" : @"First";
        views[i] = [[TwoView alloc] initWithFrame:NSMakeRect(0, 0, 500, 400)];
        windows[i].contentView = views[i];
        if (!drawing) {
            views[i].wantsLayer = YES;
            CALayer *square = [CALayer layer];
            square.frame = CGRectMake(0, 100, 100, 100);
            square.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
            [views[i].layer addSublayer:square];
            CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"position.x"];
            move.fromValue = @50;
            move.toValue = @450;
            move.duration = 2;
            move.repeatCount = HUGE_VALF;
            move.autoreverses = YES;
            [square addAnimation:move forKey:@"move"];
        }
        [windows[i] orderFront:nil];
    }
    [NSApp activateIgnoringOtherApps:YES];
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(report) userInfo:nil repeats:YES];
}
- (void)tick {
    ticks++;
    if (drawing)
        for (int i = 0; i < 2; i++)
            views[i].needsDisplay = YES;
    if (!covered && !access("/tmp/seamless-two-cover", F_OK)) {
        covered = YES;
        [windows[1] setFrameOrigin:windows[0].frame.origin];
        [windows[1] orderBack:nil];
        [windows[0] orderFront:nil];
    }
}
- (void)report {
    NSMutableString *text = [NSMutableString string];
    for (int i = 0; i < 2; i++)
        [text appendFormat:@"%c id=%ld ticks=%llu draws=%llu visible=%d\n", 'A' + i, (long)windows[i].windowNumber,
                           ticks, views[i].draws, (windows[i].occlusionState & NSWindowOcclusionStateVisible) != 0];
    [text writeToFile:@"/tmp/seamless-two.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        TwoApp *delegate = [[TwoApp alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
