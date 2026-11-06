// Measures what a guest app receives from seamless input. A real NSView in the guest logs every event AppKit gives it,
// while scripted gestures and keys go in by each mechanism in seamless-inject.h, and each step reports what arrived.
//
//     seamless-input-guest probe [--mechanisms record,session,hid,pid,iohid]    Runs every step and prints the results.
//     seamless-input-guest live --port 7655 --seconds 60    Replays the host's real input from seamless-input-host.
//
// Run as root through the guest agent, by scripts/seamless-try input: the view runs as the console user, like a real
// app, and the injector as root, which needs no event-posting grant [memory]. `--host-test` runs on this host instead,
// posting only to its own process, so it can't touch anything else: see scripts/test-seamless-input.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include "seamless-inject.h"
#include <arpa/inet.h>
#include <copyfile.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

static double now(void) {
    struct timeval t;
    gettimeofday(&t, NULL);
    return t.tv_sec + t.tv_usec * 1e-6;
}
static int darwin_major(void) {
    char release[32] = "";
    size_t size = sizeof(release);
    sysctlbyname("kern.osrelease", release, &size, NULL, 0);
    return atoi(release);
}
#include "seamless-console.h"

// ---- The view side ----

static int logFD = -1;
static double logStart;
static void logLine(NSString *line) {
    NSString *stamped = [NSString stringWithFormat:@"%.3f %@\n", now() - logStart, line];
    const char *bytes = stamped.UTF8String;
    write(logFD, bytes, strlen(bytes));
}

static NSString *phaseName(NSEventPhase phase) { return [NSString stringWithFormat:@"%lu", (unsigned long)phase]; }

@interface ProbeView : NSView <NSTextInputClient>
@property(strong) NSString *name;
@property(strong) NSTrackingArea *area;
@end
@implementation ProbeView
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (BOOL)isFlipped {
    return YES;
}
- (void)logEvent:(NSEvent *)e name:(NSString *)what extra:(NSString *)extra {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    logLine([NSString stringWithFormat:@"ev win=%@ %@ type=%lu x=%.0f y=%.0f flags=%lx %@", self.name, what,
                                       (unsigned long)e.type, p.x, p.y, (unsigned long)e.modifierFlags, extra ?: @""]);
}
- (NSString *)phases:(NSEvent *)e {
    return [NSString stringWithFormat:@"phase=%@ momentum=%@", phaseName(e.phase), phaseName(e.momentumPhase)];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.area)
        [self removeTrackingArea:self.area];
    self.area =
        [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                     options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                             NSTrackingCursorUpdate | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                       owner:self
                                    userInfo:nil];
    [self addTrackingArea:self.area];
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
    logLine([NSString stringWithFormat:@"ev win=%@ acceptsFirstMouse key=%d", self.name, self.window.isKeyWindow]);
    return NO; // AppKit's default, so a first click only activates, which is what the host must preserve.
}
- (void)mouseDown:(NSEvent *)e {
    [self
        logEvent:e
            name:@"mouseDown"
           extra:[NSString stringWithFormat:@"clicks=%ld pressure=%.2f associated=%llx", (long)e.clickCount, e.pressure,
                                            [e respondsToSelector:@selector(associatedEventsMask)]
                                                ? (unsigned long long)e.associatedEventsMask
                                                : 0ULL]];
    [self.window makeFirstResponder:self];
}
- (void)mouseUp:(NSEvent *)e {
    [self logEvent:e name:@"mouseUp" extra:nil];
}
- (void)mouseDragged:(NSEvent *)e {
    [self logEvent:e name:@"mouseDragged" extra:nil];
}
- (void)rightMouseDown:(NSEvent *)e {
    [self logEvent:e name:@"rightMouseDown" extra:nil];
}
- (void)mouseMoved:(NSEvent *)e {
    [self logEvent:e name:@"mouseMoved" extra:nil];
}
- (void)mouseEntered:(NSEvent *)e {
    [self logEvent:e name:@"mouseEntered" extra:nil];
}
- (void)mouseExited:(NSEvent *)e {
    [self logEvent:e name:@"mouseExited" extra:nil];
}
- (void)cursorUpdate:(NSEvent *)e {
    [self logEvent:e name:@"cursorUpdate" extra:nil];
    [[NSCursor IBeamCursor] set];
}
- (void)scrollWheel:(NSEvent *)e {
    [self logEvent:e
              name:@"scrollWheel"
             extra:[NSString stringWithFormat:@"%@ precise=%d inverted=%d dx=%.3f dy=%.3f sx=%.3f sy=%.3f",
                                              [self phases:e], e.hasPreciseScrollingDeltas,
                                              e.isDirectionInvertedFromDevice, e.deltaX, e.deltaY, e.scrollingDeltaX,
                                              e.scrollingDeltaY]];
}
- (void)magnifyWithEvent:(NSEvent *)e {
    [self logEvent:e
              name:@"magnify"
             extra:[NSString stringWithFormat:@"%@ magnification=%.4f", [self phases:e], e.magnification]];
}
- (void)rotateWithEvent:(NSEvent *)e {
    [self logEvent:e name:@"rotate" extra:[NSString stringWithFormat:@"%@ rotation=%.3f", [self phases:e], e.rotation]];
}
- (void)swipeWithEvent:(NSEvent *)e {
    [self logEvent:e name:@"swipe" extra:[NSString stringWithFormat:@"dx=%.0f dy=%.0f", e.deltaX, e.deltaY]];
}
- (void)smartMagnifyWithEvent:(NSEvent *)e {
    [self logEvent:e name:@"smartMagnify" extra:nil];
}
- (void)quickLookWithEvent:(NSEvent *)e {
    [self logEvent:e name:@"quickLook" extra:nil];
}
- (void)beginGestureWithEvent:(NSEvent *)e {
    [self logEvent:e name:@"beginGesture" extra:nil];
}
- (void)endGestureWithEvent:(NSEvent *)e {
    [self logEvent:e name:@"endGesture" extra:nil];
}
// No such responder method on 10.9, where it's never called, and a compile-time name is all it takes on later ones.
- (void)pressureChangeWithEvent:(NSEvent *)e {
    [self logEvent:e
              name:@"pressureChange"
             extra:[NSString stringWithFormat:@"stage=%ld transition=%.3f pressure=%.3f", (long)e.stage,
                                              (double)e.stageTransition, e.pressure]];
}
- (void)keyDown:(NSEvent *)e {
    [self logEvent:e
              name:@"keyDown"
             extra:[NSString stringWithFormat:@"code=%d repeat=%d chars=[%@] raw=[%@]", e.keyCode, e.isARepeat,
                                              e.characters, e.charactersIgnoringModifiers]];
    [self.inputContext handleEvent:e];
}
- (void)keyUp:(NSEvent *)e {
    [self logEvent:e name:@"keyUp" extra:[NSString stringWithFormat:@"code=%d", e.keyCode]];
}
- (void)flagsChanged:(NSEvent *)e {
    [self logEvent:e name:@"flagsChanged" extra:[NSString stringWithFormat:@"code=%d", e.keyCode]];
}
- (BOOL)performKeyEquivalent:(NSEvent *)e {
    [self logEvent:e name:@"keyEquivalent" extra:[NSString stringWithFormat:@"code=%d", e.keyCode]];
    return YES;
}
// Dead keys and input methods report here. The text is what a real text view would have shown.
- (void)insertText:(id)text replacementRange:(NSRange)range {
    logLine([NSString stringWithFormat:@"ev win=%@ insertText [%@]", self.name,
                                       [text isKindOfClass:[NSAttributedString class]] ? [text string] : text]);
}
- (void)setMarkedText:(id)text selectedRange:(NSRange)selected replacementRange:(NSRange)range {
    logLine([NSString stringWithFormat:@"ev win=%@ setMarkedText [%@]", self.name,
                                       [text isKindOfClass:[NSAttributedString class]] ? [text string] : text]);
}
- (void)doCommandBySelector:(SEL)selector {
    logLine([NSString stringWithFormat:@"ev win=%@ command %@", self.name, NSStringFromSelector(selector)]);
}
- (void)unmarkText {
}
- (NSRange)selectedRange {
    return NSMakeRange(0, 0);
}
- (NSRange)markedRange {
    return NSMakeRange(NSNotFound, 0);
}
- (BOOL)hasMarkedText {
    return NO;
}
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual {
    return nil;
}
- (NSArray *)validAttributesForMarkedText {
    return @[];
}
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
    return NSZeroRect;
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return 0;
}
@end

@interface ProbeController : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(strong) NSString *directory;
@property(strong) NSMutableArray *windows;
@property(strong) NSScrollView *scroller;
@end
@implementation ProbeController
- (NSWindow *)windowNamed:(NSString *)name frame:(NSRect)frame {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    window.title = name;
    window.delegate = self;
    window.releasedWhenClosed = NO;
    ProbeView *view = [[ProbeView alloc] initWithFrame:[window.contentView bounds]];
    view.name = name;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = view;
    [window makeFirstResponder:view];
    [self.windows addObject:window];
    return window;
}
- (void)windowDidBecomeKey:(NSNotification *)note {
    logLine([NSString stringWithFormat:@"ev win=%@ becameKey", [note.object title]]);
}
- (void)scrolled:(NSNotification *)note {
    logLine([NSString stringWithFormat:@"ev win=A scrollview y=%.1f", self.scroller.contentView.bounds.origin.y]);
}
// A real scroll view, to see whether AppKit's own momentum and elastic scrolling accept what's posted.
- (void)addScrollerTo:(NSWindow *)window {
    NSView *content = window.contentView;
    NSRect frame = NSMakeRect(0, content.bounds.size.height - 150, content.bounds.size.width, 150);
    self.scroller = [[NSScrollView alloc] initWithFrame:frame];
    self.scroller.hasVerticalScroller = YES;
    self.scroller.documentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, 4000)];
    self.scroller.contentView.postsBoundsChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scrolled:)
                                                 name:NSViewBoundsDidChangeNotification
                                               object:self.scroller.contentView];
    [content addSubview:self.scroller];
}
// TIS belongs to the console user, so the injector asks this process to change it.
- (void)poll {
    NSString *stop = [self.directory stringByAppendingPathComponent:@"stop"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:stop])
        exit(0);
    NSString *path = [self.directory stringByAppendingPathComponent:@"select-source"];
    NSString *wanted = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!wanted)
        return;
    unlink(path.fileSystemRepresentation);
    NSDictionary *filter = @{(__bridge NSString *)kTISPropertyInputSourceID : wanted};
    NSArray *found = CFBridgingRelease(TISCreateInputSourceList((__bridge CFDictionaryRef)filter, true));
    OSStatus status = found.count ? TISSelectInputSource((__bridge TISInputSourceRef)found[0]) : -1;
    TISInputSourceRef current = TISCopyCurrentKeyboardLayoutInputSource();
    logLine([NSString stringWithFormat:@"ev selected %@ status=%d now=%@ kbtype=%d", wanted, (int)status,
                                       current ? TISGetInputSourceProperty(current, kTISPropertyInputSourceID) : @"?",
                                       (int)LMGetKbdType()]);
    if (current)
        CFRelease(current);
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.windows = [NSMutableArray array];
    NSWindow *b = [self windowNamed:@"B" frame:NSMakeRect(420, 100, 420, 320)];
    NSWindow *a = [self windowNamed:@"A" frame:NSMakeRect(200, 140, 420, 320)];
    [self addScrollerTo:a];
    [b orderFront:nil];
    [a makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      // Top-left origin, as CGEvent locations use. The whole list goes in one write, so the injector can't half-read
      // it.
      CGFloat top = NSScreen.screens.firstObject.frame.size.height;
      NSMutableString *ready = [NSMutableString string];
      [ready appendFormat:@"pid %d\n", getpid()];
      for (NSWindow *window in self.windows) {
          NSRect f = window.frame;
          [ready appendFormat:@"%@ %ld %.0f %.0f %.0f %.0f\n", window.title, (long)window.windowNumber, f.origin.x,
                              top - NSMaxY(f), f.size.width, f.size.height];
      }
      NSString *path = [self.directory stringByAppendingPathComponent:@"ready"];
      [ready writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
      logLine([NSString stringWithFormat:@"view %@", [ready stringByReplacingOccurrencesOfString:@"\n"
                                                                                      withString:@"; "]]);
      logLine([NSString
          stringWithFormat:@"view swipeTrackingFromScroll=%d forceClick=%@",
                           NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                           [[NSUserDefaults standardUserDefaults] objectForKey:@"com.apple.trackpad.forceClick"]]);
      NSArray *sources = CFBridgingRelease(TISCreateInputSourceList(NULL, false));
      NSMutableArray *names = [NSMutableArray array];
      for (id source in sources) {
          NSString *name = (__bridge NSString *)TISGetInputSourceProperty((__bridge TISInputSourceRef)source,
                                                                          kTISPropertyInputSourceID);
          if (name)
              [names addObject:name];
      }
      logLine([NSString stringWithFormat:@"view enabled sources: %@", [names componentsJoinedByString:@" "]]);
    });
}
@end

static int run_view(NSString *directory) {
    logFD = open([directory stringByAppendingPathComponent:@"log"].fileSystemRepresentation,
                 O_WRONLY | O_APPEND | O_CREAT, 0666);
    if (logFD < 0)
        return 74;
    logStart = now();
    alarm(600);
    @autoreleasepool {
        ProbeController *controller = [ProbeController new];
        controller.directory = directory;
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        app.delegate = controller;
        [app run];
    }
    return 0;
}

// ---- The injecting side ----

struct Target {
    CGRect a, b;
    CGWindowID a_id, b_id;
    pid_t pid;
};

static int read_target(NSString *directory, struct Target *t) {
    NSString *path = [directory stringByAppendingPathComponent:@"ready"];
    for (double start = now(); now() - start < 60; usleep(100000)) {
        NSString *ready = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [ready componentsSeparatedByString:@"\n"]) {
            NSArray *f = [line componentsSeparatedByString:@" "];
            if (f.count == 2 && [f[0] isEqual:@"pid"])
                t->pid = [f[1] intValue];
            if (f.count == 6) {
                CGRect r = CGRectMake([f[2] doubleValue], [f[3] doubleValue], [f[4] doubleValue], [f[5] doubleValue]);
                if ([f[0] isEqual:@"A"]) {
                    t->a = r;
                    t->a_id = [f[1] intValue];
                } else {
                    t->b = r;
                    t->b_id = [f[1] intValue];
                }
            }
        }
        if (t->pid && t->a_id && t->b_id)
            return 1;
    }
    return 0;
}

static void gesture(struct SWIContext *c, CGPoint p, uint8_t kind, uint8_t phase, uint8_t momentum, float a, float b,
                    uint32_t flags, uint8_t stage) {
    struct SWMGesture g = {0, kind, phase, momentum, stage, 0, 0, a, b, 0, flags, 0};
    swi_gesture(c, &g, p);
    usleep(16000);
}

static void script_scroll(struct SWIContext *c, CGPoint p) {
    gesture(c, p, SWG_SCROLL, SWP_MAY_BEGIN, 0, 0, 0, SWG_PRECISE, 0);
    gesture(c, p, SWG_SCROLL, SWP_BEGAN, 0, 0, -3, SWG_PRECISE, 0);
    for (int i = 0; i < 6; i++)
        gesture(c, p, SWG_SCROLL, SWP_CHANGED, 0, 0, -12.5f, SWG_PRECISE, 0);
    gesture(c, p, SWG_SCROLL, SWP_ENDED, 0, 0, 0, SWG_PRECISE, 0);
    gesture(c, p, SWG_SCROLL, SWP_NONE, SWM_MOMENTUM_BEGAN, 0, -20, SWG_PRECISE, 0);
    for (int i = 0; i < 6; i++)
        gesture(c, p, SWG_SCROLL, SWP_NONE, SWM_MOMENTUM_CHANGED, 0, -10.f / (float)(i + 1), SWG_PRECISE, 0);
    gesture(c, p, SWG_SCROLL, SWP_NONE, SWM_MOMENTUM_ENDED, 0, 0, SWG_PRECISE, 0);
}
static void script_two_phase(struct SWIContext *c, CGPoint p, uint8_t kind, float amount) {
    gesture(c, p, SWG_BEGIN, 0, 0, 0, 0, 0, kind);
    gesture(c, p, kind, SWP_BEGAN, 0, amount, 0, 0, 0);
    for (int i = 0; i < 4; i++)
        gesture(c, p, kind, SWP_CHANGED, 0, amount, 0, 0, 0);
    gesture(c, p, kind, SWP_ENDED, 0, 0, 0, 0, 0);
    gesture(c, p, SWG_END, 0, 0, 0, 0, 0, kind);
}

struct Step {
    const char *name;
    // Each must appear between this step's marker and the next, for a pass.
    const char *expect[5];
    int minimum_darwin; // 0 for all.
    void (*run)(struct SWIContext *, const struct Target *);
};

static CGPoint a_point(const struct Target *t) { return CGPointMake(t->a.origin.x + 40, t->a.origin.y + 60); }
static CGPoint b_free_point(const struct Target *t) {
    return CGPointMake(CGRectGetMaxX(t->b) - 40, t->b.origin.y + 60);
}
static CGPoint overlap_point(const struct Target *t) {
    return CGPointMake((t->b.origin.x + CGRectGetMaxX(t->a)) / 2,
                       (MAX(t->a.origin.y, t->b.origin.y) + MIN(CGRectGetMaxY(t->a), CGRectGetMaxY(t->b))) / 2);
}

static void click_at(struct SWIContext *c, CGPoint p, uint32_t flags) {
    struct SWMPointer m = {0, SWM_MOVE, 0, 0, 0, 0, flags};
    swi_pointer(c, &m, p);
    usleep(50000);
    m.kind = SWM_DOWN;
    m.clicks = 1;
    swi_pointer(c, &m, p);
    usleep(50000);
    m.kind = SWM_UP;
    swi_pointer(c, &m, p);
    usleep(100000);
}
static void tap(struct SWIContext *c, uint16_t code, uint32_t flags) {
    swi_key(c, code, 1, flags);
    usleep(30000);
    swi_key(c, code, 0, flags);
    usleep(60000);
}

static void step_scroll(struct SWIContext *c, const struct Target *t) { script_scroll(c, a_point(t)); }
static void step_wheel(struct SWIContext *c, const struct Target *t) {
    for (int i = 0; i < 3; i++)
        gesture(c, a_point(t), SWG_SCROLL, 0, 0, 0, -2, 0, 0);
}
static void step_scrollview(struct SWIContext *c, const struct Target *t) {
    script_scroll(c, CGPointMake(t->a.origin.x + 100, CGRectGetMaxY(t->a) - 60));
    usleep(300000);
}
static void step_magnify(struct SWIContext *c, const struct Target *t) {
    script_two_phase(c, a_point(t), SWG_MAGNIFY, 0.1f);
}
static void step_rotate(struct SWIContext *c, const struct Target *t) {
    script_two_phase(c, a_point(t), SWG_ROTATE, 5);
}
static void step_swipe(struct SWIContext *c, const struct Target *t) {
    gesture(c, a_point(t), SWG_SWIPE, SWP_ENDED, 0, 1, 0, 0, 0);
    gesture(c, a_point(t), SWG_SWIPE, SWP_ENDED, 0, 0, -1, 0, 0);
}
static void step_smart(struct SWIContext *c, const struct Target *t) {
    gesture(c, a_point(t), SWG_SMART_MAGNIFY, 0, 0, 0, 0, 0, 0);
}
static void step_look(struct SWIContext *c, const struct Target *t) {
    gesture(c, a_point(t), SWG_QUICK_LOOK, 0, 0, 0, 0, 0, 0);
}
static void step_pressure(struct SWIContext *c, const struct Target *t) {
    CGPoint p = a_point(t);
    struct SWMPointer m = {0, SWM_DOWN, 0, 1, 0, 0, 0};
    swi_pointer(c, &m, p);
    gesture(c, p, SWG_PRESSURE, SWP_BEGAN, 0, 0.2f, 0.1f, 0, 1);
    gesture(c, p, SWG_PRESSURE, SWP_CHANGED, 0, 0.6f, 0.6f, 0, 1);
    gesture(c, p, SWG_PRESSURE, SWP_CHANGED, 0, 0.3f, 0.3f, 0, 2);
    gesture(c, p, SWG_PRESSURE, SWP_CHANGED, 0, 0.9f, 0, 0, 2);
    gesture(c, p, SWG_PRESSURE, SWP_ENDED, 0, 0, -1, 0, 0);
    m.kind = SWM_UP;
    swi_pointer(c, &m, p);
    usleep(100000);
}
static void step_hover(struct SWIContext *c, const struct Target *t) {
    struct SWMPointer m = {0, SWM_MOVE, 0, 0, 0, 0, 0};
    swi_pointer(c, &m, a_point(t));
    usleep(100000);
    swi_pointer(c, &m, CGPointMake(a_point(t).x + 10, a_point(t).y + 10));
    usleep(100000);
    swi_pointer(c, &m, b_free_point(t));
    usleep(100000);
    swi_pointer(c, &m, a_point(t));
    usleep(100000);
}
static void step_first_click(struct SWIContext *c, const struct Target *t) {
    click_at(c, b_free_point(t), 0); // B isn't key: AppKit asks acceptsFirstMouse, and activates it.
    usleep(200000);
    click_at(c, b_free_point(t), 0); // Now key: an ordinary click.
    click_at(c, a_point(t), 0); // Hand key back to A, for the steps that follow.
    click_at(c, a_point(t), 0);
    usleep(200000);
}
static void step_key(struct SWIContext *c, const struct Target *t) {
    (void)t;
    tap(c, 0, 0);
}
static void step_repeat(struct SWIContext *c, const struct Target *t) {
    (void)t;
    // D, which has no press-and-hold accents to swallow the repeat.
    swi_key(c, 2, 1, 0);
    usleep(30000);
    swi_key(c, 2, 1, 0);
    usleep(30000);
    swi_key(c, 2, 0, 0);
    usleep(60000);
}
static void step_modifiers(struct SWIContext *c, const struct Target *t) {
    (void)t;
    swi_modifiers(c, kCGEventFlagMaskShift | 0x2);
    usleep(50000);
    tap(c, 0, kCGEventFlagMaskShift | 0x2);
    swi_modifiers(c, 0);
    usleep(50000);
}
static void step_equivalent(struct SWIContext *c, const struct Target *t) {
    (void)t;
    swi_modifiers(c, kCGEventFlagMaskCommand | 0x8);
    tap(c, 40, kCGEventFlagMaskCommand | 0x8); // Cmd-K.
    swi_modifiers(c, 0);
    usleep(50000);
}
static void step_dead(struct SWIContext *c, const struct Target *t) {
    (void)t;
    tap(c, 14, kCGEventFlagMaskAlternate); // Option-E, a dead key on the U.S. layout.
    tap(c, 14, 0); // E, which composes to e-acute.
}
static void step_text(struct SWIContext *c, const struct Target *t) {
    (void)t;
    const char *text = "\xC3\xA9\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E\xF0\x9F\x98\x80"; // e-acute, 3 kanji, an emoji.
    swi_text(c, text, strlen(text));
    usleep(100000);
}
static NSString *gDirectory;
static void select_source(NSString *identifier) {
    [identifier writeToFile:[gDirectory stringByAppendingPathComponent:@"select-source"]
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:nil];
    usleep(600000);
}
static void step_layout(struct SWIContext *c, const struct Target *t) {
    (void)t;
    select_source(@"com.apple.keylayout.French");
    tap(c, 0, 0); // The key labelled A in the U.S. layout gives q in French.
    select_source(@"com.apple.keylayout.US");
}
static void step_iso_jis(struct SWIContext *c, const struct Target *t) {
    (void)t;
    tap(c, 10, 0); // ISO section key. The app's QMP table has no entry for this.
    tap(c, 94, 0); // JIS underscore.
    tap(c, 93, 0); // JIS yen.
    tap(c, 102, 0); // JIS eisu.
    tap(c, 104, 0); // JIS kana.
    tap(c, 105, 0); // F13.
    tap(c, 63, 0); // Fn.
}
static void step_control(struct SWIContext *c, const struct Target *t) {
    click_at(c, overlap_point(t), 0); // Where A covers B, ordering decides: A gets it.
}
static void step_routed(struct SWIContext *c, const struct Target *t) {
    // The same point, addressed to the window underneath. What a compositor hook needs, with no desktop to hit test.
    enum SWIMechanism mechanism = c->mechanism;
    c->mechanism = SWI_PID;
    c->pid = t->pid;
    c->window = t->b_id;
    c->window_origin = t->b.origin;
    click_at(c, overlap_point(t), 0);
    c->mechanism = mechanism;
    c->window = 0;
}

static const struct Step gesture_steps[] = {
    {"scroll", {"scrollWheel", "phase=1 ", "phase=8 ", "momentum=1", "momentum=8"}, 0, step_scroll},
    {"wheel", {"scrollWheel", "precise=0"}, 0, step_wheel},
    {"scrollview", {"scrollview y="}, 0, step_scrollview},
    {"magnify", {"magnify", "phase=1 ", "phase=8 ", "magnification=0.1"}, 0, step_magnify},
    {"rotate", {"rotate", "phase=1 ", "rotation=5"}, 0, step_rotate},
    {"swipe", {"swipe", "dx=1", "dy=-1"}, 0, step_swipe},
    {"smart-magnify", {"smartMagnify"}, 0, step_smart},
    {"quick-look", {"quickLook"}, 0, step_look},
    {"pressure", {"pressureChange", "stage=2"}, 14, step_pressure},
};
static const struct Step input_steps[] = {
    {"hover", {"mouseMoved", "mouseEntered", "mouseExited", "cursorUpdate"}, 0, step_hover},
    {"first-click", {"win=B acceptsFirstMouse key=0", "win=B becameKey", "win=B mouseDown"}, 0, step_first_click},
    {"key", {"keyDown", "chars=[a]", "insertText [a]", "keyUp"}, 0, step_key},
    {"repeat", {"repeat=0", "repeat=1"}, 0, step_repeat},
    {"modifiers", {"flagsChanged", "code=56", "chars=[A]"}, 0, step_modifiers},
    {"key-equivalent", {"keyEquivalent", "code=40"}, 0, step_equivalent},
    {"dead-key", {"\xC3\xA9"}, 0, step_dead},
    {"text", {"\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E", "\xF0\x9F\x98\x80"}, 0, step_text},
    {"layout", {"now=com.apple.keylayout.French", "chars=[q]"}, 0, step_layout},
    {"iso-jis", {"code=10", "code=94", "code=102", "code=105", "code=63"}, 0, step_iso_jis},
    {"route-control", {"win=A mouseDown"}, 0, step_control},
    {"route-to-window", {"win=B mouseDown"}, 0, step_routed},
};

static void marker(NSString *line) { logLine([NSString stringWithFormat:@"# step %@", line]); }

static int inject_all(NSString *directory, NSArray *mechanisms, int host_test) {
    gDirectory = directory;
    struct Target t = {0};
    if (!read_target(directory, &t)) {
        puts("# ERROR the test window never came up");
        return 75;
    }
    logFD = open([directory stringByAppendingPathComponent:@"log"].fileSystemRepresentation, O_WRONLY | O_APPEND);
    logStart = now();
    // A process each, so a mechanism that crashes on a private call's unexpected signature costs only its own steps.
    // The parent makes no window server connection for them to inherit.
    for (NSUInteger i = 0; i <= mechanisms.count; i++) {
        pid_t child = fork();
        if (child < 0)
            return 71;
        if (child) {
            int status = 0;
            waitpid(child, &status, 0);
            if (!WIFEXITED(status) || WEXITSTATUS(status))
                logLine([NSString stringWithFormat:@"ev injector died, status %d, after the step above", status]);
            continue;
        }
        struct SWIContext c = {SWI_SESSION, t.pid, 0, CGPointZero, 0, 0, {0}, 0};
        if (i == 0) {
            c.mechanism = host_test ? SWI_PID : SWI_SESSION;
            for (size_t n = 0; n < sizeof(input_steps) / sizeof(input_steps[0]); n++) {
                // The host test only reaches the process, so ordering can't decide anything, and the layout is the
                // user's.
                void (*run)(struct SWIContext *, const struct Target *) = input_steps[n].run;
                if (host_test && (run == step_control || run == step_routed || run == step_first_click ||
                                  run == step_layout || run == step_hover))
                    continue;
                marker([NSString stringWithFormat:@"%s %s", input_steps[n].name, swi_mechanism_names[c.mechanism]]);
                run(&c, &t);
                usleep(150000);
            }
            _exit(0);
        }
        NSString *name = mechanisms[i - 1];
        for (int m = 0; m < SWI_MECHANISM_COUNT; m++)
            if ([name isEqual:@(swi_mechanism_names[m])])
                c.mechanism = (enum SWIMechanism)m;
        // Addressed to the window, or a post to a process lands nowhere.
        c.window = c.mechanism == SWI_PID ? t.a_id : 0;
        c.window_origin = t.a.origin;
        for (size_t n = 0; n < sizeof(gesture_steps) / sizeof(gesture_steps[0]); n++) {
            marker([NSString stringWithFormat:@"%s %@", gesture_steps[n].name, name]);
            gesture_steps[n].run(&c, &t);
            usleep(150000);
        }
        _exit(0);
    }
    marker(@"end");
    return 0;
}

// Reads the log back: one result line per step, then the raw lines, so what a mechanism delivered is on the record.
static int report(NSString *directory) {
    NSString *log = [NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"log"]
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    if (!log) {
        puts("# ERROR no log");
        return 74;
    }
    int failures = 0, darwin = darwin_major();
    NSArray *sections = [log componentsSeparatedByString:@"# step "];
    printf("darwin %d\n", darwin);
    printf("%-18s %-8s %-6s %s\n", "step", "how", "result", "events");
    for (NSUInteger i = 1; i < sections.count; i++) {
        NSString *section = sections[i];
        NSArray *words = [[section componentsSeparatedByString:@"\n"][0] componentsSeparatedByString:@" "];
        if (words.count < 2)
            continue;
        const struct Step *found = NULL;
        for (size_t s = 0; s < sizeof(gesture_steps) / sizeof(gesture_steps[0]); s++)
            if (!strcmp(gesture_steps[s].name, [words[0] UTF8String]))
                found = &gesture_steps[s];
        for (size_t s = 0; s < sizeof(input_steps) / sizeof(input_steps[0]); s++)
            if (!strcmp(input_steps[s].name, [words[0] UTF8String]))
                found = &input_steps[s];
        if (!found)
            continue;
        int pass = 1;
        NSMutableString *missing = [NSMutableString string];
        for (int e = 0; e < 5 && found->expect[e]; e++)
            if ([section rangeOfString:@(found->expect[e])].location == NSNotFound) {
                pass = 0;
                [missing appendFormat:@" no[%s]", found->expect[e]];
            }
        NSUInteger events = [section componentsSeparatedByString:@" ev "].count - 1;
        const char *verdict = pass ? "yes" : "NO";
        if (found->minimum_darwin > darwin)
            verdict = pass ? "yes?!" : "n/a";
        else if (!pass)
            failures++;
        printf("%-18s %-8s %-6s %lu%s\n", [words[0] UTF8String], [words[1] UTF8String], verdict, (unsigned long)events,
               missing.UTF8String);
    }
    printf("# %d steps failed. Raw log:\n", failures);
    fflush(stdout);
    fputs(log.UTF8String, stdout);
    return 0;
}

// Replays the host's real input against the same view, so a person with a trackpad can see what a guest app gets.
static int live(NSString *directory, const char *host, int port, double seconds) {
    struct Target t = {0};
    if (!read_target(directory, &t)) {
        puts("# ERROR the test window never came up");
        return 75;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0), on = 1;
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, host, &address.sin_addr);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) {
        printf("# ERROR can't reach %s:%d\n", host, port);
        return 3;
    }
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    struct timeval quick = {0, 200000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &quick, sizeof(quick));
    logFD = open([directory stringByAppendingPathComponent:@"log"].fileSystemRepresentation, O_WRONLY | O_APPEND);
    logStart = now();
    marker(@"live session");
    gDirectory = directory;
    struct SWIContext c = {darwin_major() < 14 ? SWI_RECORD : SWI_SESSION, t.pid, 0, CGPointZero, 0, 0, {0}, 0};
    struct SWIContext keys = c;
    keys.mechanism = SWI_SESSION;
    uint8_t buffer[8192];
    size_t have = 0;
    for (double start = now(); now() - start < seconds;) {
        ssize_t n = recv(fd, buffer + have, sizeof(buffer) - have, 0);
        if (n == 0)
            break;
        if (n < 0)
            continue;
        have += (size_t)n;
        size_t offset = 0, used = 0;
        struct SWMMessage m;
        enum SWMParse result;
        while ((result = swm_parse(buffer + offset, have - offset, &m, &used)) == SWM_OK) {
            CGPoint origin = t.a.origin;
            if (m.type == SWM_GESTURE) {
                CGPoint p = {origin.x + m.u.gesture.x / 16.0, origin.y + m.u.gesture.y / 16.0};
                swi_gesture(&c, &m.u.gesture, p);
            } else if (m.type == SWM_POINTER) {
                CGPoint p = {origin.x + m.u.pointer.x / 16.0, origin.y + m.u.pointer.y / 16.0};
                swi_pointer(&keys, &m.u.pointer, p);
            } else if (m.type == SWM_KEY)
                swi_key(&keys, m.u.key.keycode, m.u.key.down, m.u.key.flags);
            else if (m.type == SWM_MODIFIERS)
                swi_modifiers(&keys, m.u.modifiers);
            else if (m.type == SWM_TEXT && m.u.text.kind == SWT_INSERT)
                swi_text(&keys, m.u.text.bytes, m.u.text.length);
            else if (m.type == SWM_TEXT && m.u.text.kind == SWT_INPUT_SOURCE)
                select_source([[NSString alloc] initWithBytes:m.u.text.bytes
                                                       length:m.u.text.length
                                                     encoding:NSUTF8StringEncoding]);
            offset += used;
        }
        if (result == SWM_BAD)
            break;
        memmove(buffer, buffer + offset, have - offset);
        have -= offset;
    }
    marker(@"end");
    return 0;
}

static const char *option(int argc, char **argv, const char *name, const char *fallback) {
    for (int i = 1; i + 1 < argc; i++)
        if (!strcmp(argv[i], name))
            return argv[i + 1];
    return fallback;
}
static int has_flag(int argc, char **argv, const char *name) {
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], name))
            return 1;
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *command = argc > 1 ? argv[1] : "";
    int in_session = has_flag(argc, argv, "--in-session"), host_test = has_flag(argc, argv, "--host-test");
    if (!strcmp(command, "view")) {
        if (geteuid() == 0 && !in_session)
            return run_in_console_session(argc, argv, 1);
        return run_view(@(option(argc, argv, "--directory", "/tmp")));
    }
    if (!strcmp(command, "inject") || !strcmp(command, "inject-live")) {
        if (geteuid() == 0 && !in_session)
            return run_in_console_session(argc, argv, 0);
        NSString *directory = @(option(argc, argv, "--directory", "/tmp"));
        if (!strcmp(command, "inject-live"))
            return live(directory, option(argc, argv, "--host", "10.0.2.2"), atoi(option(argc, argv, "--port", "7655")),
                        atof(option(argc, argv, "--seconds", "60")));
        NSArray *mechanisms = [@(option(argc, argv, "--mechanisms", "")) componentsSeparatedByString:@","];
        return inject_all(directory, mechanisms, host_test);
    }
    if (strcmp(command, "probe") && strcmp(command, "live")) {
        fputs("usage: seamless-input-guest probe [--mechanisms a,b] | live --port P --seconds S\n", stderr);
        return 64;
    }
    // On anything newer than Big Sur this is a host, where a posted event would land on the user's real apps.
    if (darwin_major() > 20 && !host_test) {
        fputs("This is for a guest. See scripts/test-seamless-input for the host.\n", stderr);
        return 64;
    }
    alarm(900);
    char template[] = "/tmp/seamless-input.XXXXXX";
    if (!mkdtemp(template) || chmod(template, 0777))
        return 74;
    NSString *directory = @(template);
    char self[4096];
    uint32_t length = sizeof(self);
    if (_NSGetExecutablePath(self, &length))
        return 74;
    close(open([directory stringByAppendingPathComponent:@"log"].fileSystemRepresentation, O_CREAT | O_WRONLY, 0666));
    chmod([directory stringByAppendingPathComponent:@"log"].fileSystemRepresentation, 0666);
    pid_t view = fork();
    if (!view) {
        char *arguments[] = {self, "view", "--directory", template, NULL};
        execv(self, arguments);
        _exit(127);
    }
    pid_t injector = fork();
    if (!injector) {
        const char *mechanisms = option(argc, argv, "--mechanisms", host_test ? "pid" : "record,session,hid,pid,iohid");
        if (!strcmp(command, "probe")) {
            char *arguments[] = {self,
                                 "inject",
                                 "--directory",
                                 template,
                                 "--mechanisms",
                                 (char *)mechanisms,
                                 host_test ? "--host-test" : NULL,
                                 NULL};
            execv(self, arguments);
        } else {
            char *arguments[] = {self,          "inject-live",
                                 "--directory", template,
                                 "--port",      (char *)option(argc, argv, "--port", "7655"),
                                 "--seconds",   (char *)option(argc, argv, "--seconds", "60"),
                                 "--host",      (char *)option(argc, argv, "--host", "10.0.2.2"),
                                 NULL};
            execv(self, arguments);
        }
        _exit(127);
    }
    int status = 1;
    waitpid(injector, &status, 0);
    close(open([directory stringByAppendingPathComponent:@"stop"].fileSystemRepresentation, O_CREAT | O_WRONLY, 0666));
    int ignored;
    waitpid(view, &ignored, 0);
    int result = report(directory);
    NSFileManager *files = [NSFileManager defaultManager];
    [files removeItemAtPath:directory error:nil];
    return WIFEXITED(status) && WEXITSTATUS(status) ? WEXITSTATUS(status) : result;
}
