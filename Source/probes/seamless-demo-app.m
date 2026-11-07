// A guest app with the awkward window kinds a seamless host must reproduce: a popover past its window's edge, a child
// panel, a translucent window, a real menu and a sheet. It shows each on a schedule, so a run needs no input. A counter
// keeps changing, to measure a live window; a click on its button and typing into its field show in its title.
// Built into seamless-guest as `seamless-guest demo-app`.
#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#include <stdlib.h>
#include <unistd.h>

// A GL surface over a window's backing, which WindowServer composites separately: what a backing store alone can't
// show.
@interface SeamlessGLView : NSOpenGLView
@property unsigned frames;
@end
@implementation SeamlessGLView
- (void)drawRect:(NSRect)dirty {
    if (!self.frames)
        fputs("gl-demo: first draw\n", stderr);
    double phase = (double)(++self.frames % 60) / 60;
    glClearColor(phase, 1 - phase, 0.3, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glBegin(GL_TRIANGLES);
    glColor3f(1, 1, 1);
    glVertex2f(-0.6, -0.6);
    glVertex2f(0.6, -0.6);
    glVertex2f((float)(phase * 2 - 1), 0.7);
    glEnd();
    [self.openGLContext flushBuffer];
}
- (void)tick:(NSTimer *)timer {
    self.needsDisplay = YES;
}
@end

@interface SeamlessDemo : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property(retain) NSWindow *window;
@property(retain) NSPopover *popover;
@property(retain) NSView *anchor;
@property(retain) NSMenu *menu;
@property(retain) NSTextField *counter;
@property unsigned ticks;
@end

@implementation SeamlessDemo
- (void)tick {
    self.counter.stringValue = [NSString stringWithFormat:@"Frame %u", ++self.ticks];
}
- (void)clicked:(id)sender {
    self.window.title = [self.window.title stringByAppendingString:@" clicked"];
}
- (void)controlTextDidChange:(NSNotification *)note {
    self.window.title = [self.window.title stringByAppendingString:@" typed"];
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    if (getenv("SEAMLESS_MATERIAL_FIXTURE")) {
        // A persistent, active backdrop, independent of whichever stock apps happen to have one. The ordinary demo's
        // translucent panel is alpha only, and its menu/sheet disappear before the desktop test reaches materials.
        if (@available(macOS 10.14, *)) {
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 180, 420, 260)
                                                           styleMask:NSTitledWindowMask | NSClosableWindowMask
                                                             backing:NSBackingStoreBuffered
                                                               defer:NO];
            window.title = @"Seamless materials fixture";
            NSVisualEffectView *effect = [[NSVisualEffectView alloc] initWithFrame:window.contentView.bounds];
            effect.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            effect.material = NSVisualEffectMaterialSidebar;
            effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            effect.state = NSVisualEffectStateActive;
            window.contentView = effect;
            NSTextField *counter = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 100, 360, 24)];
            counter.bezeled = NO;
            counter.editable = NO;
            counter.drawsBackground = NO;
            [effect addSubview:counter];
            self.counter = counter;
            self.window = window;
            [window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            [NSTimer scheduledTimerWithTimeInterval:1.0 / 30
                                             target:self
                                           selector:@selector(tick)
                                           userInfo:nil
                                            repeats:YES];
            fprintf(stderr, "materials-fixture ready pid %d window %ld\n", getpid(), (long)window.windowNumber);
            fflush(stderr);
        } else {
            fputs("materials-fixture unsupported: requires Mojave or later\n", stderr);
            [NSApp terminate:nil];
        }
        return;
    }
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(300, 300, 420, 260)
                                                   styleMask:NSTitledWindowMask | NSClosableWindowMask |
                                                             NSMiniaturizableWindowMask | NSResizableWindowMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Seamless demo";
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 200, 380, 24)];
    label.stringValue = @"A popover, a panel, a menu and a sheet are coming.";
    label.bezeled = NO;
    label.editable = NO;
    label.drawsBackground = NO;
    [window.contentView addSubview:label];
    NSButton *anchor = [[NSButton alloc] initWithFrame:NSMakeRect(320, 110, 90, 32)];
    anchor.title = @"Anchor";
    anchor.bezelStyle = NSRoundedBezelStyle;
    [window.contentView addSubview:anchor];
    anchor.target = self;
    anchor.action = @selector(clicked:);
    self.anchor = anchor;
    NSTextField *counter = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 20, 200, 24)];
    counter.bezeled = NO;
    counter.editable = NO;
    counter.drawsBackground = NO;
    [window.contentView addSubview:counter];
    self.counter = counter;
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    // Something to scroll, resizing with the window, as a real document would.
    NSScrollView *scroller = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 50, 280, 100)];
    scroller.hasVerticalScroller = YES;
    scroller.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 280, 100)];
    text.autoresizingMask = NSViewWidthSizable;
    NSMutableString *lines = [NSMutableString string];
    for (int i = 1; i <= 200; i++)
        [lines appendFormat:@"Line %d of a document to scroll\n", i];
    text.string = lines;
    scroller.documentView = text;
    [window.contentView addSubview:scroller];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 160, 200, 24)];
    field.delegate = self;
    [window.contentView addSubview:field];
    self.window = window;
    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:field];
    [NSApp activateIgnoringOtherApps:YES];
    [self performSelector:@selector(showPopover) withObject:nil afterDelay:3];
    [self performSelector:@selector(showPanels) withObject:nil afterDelay:6];
    [self performSelector:@selector(showMenu) withObject:nil afterDelay:9];
    [self performSelector:@selector(showSheet) withObject:nil afterDelay:13];
}
- (void)showGL {
    fputs("gl-demo: making window\n", stderr);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(60, 480, 240, 180)
                                                   styleMask:NSTitledWindowMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"OpenGL";
    NSOpenGLPixelFormatAttribute attributes[] = {NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated, 0};
    NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    fprintf(stderr, "gl-demo: pixel format %p\n", format);
    SeamlessGLView *view = [[SeamlessGLView alloc] initWithFrame:NSMakeRect(0, 0, 240, 180) pixelFormat:format];
    fprintf(stderr, "gl-demo: view %p context %p\n", view, view.openGLContext);
    [window.contentView addSubview:view];
    [window orderFront:nil];
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 target:view selector:@selector(tick:) userInfo:nil repeats:YES];
}
// Opens to the right of a button near the window's right edge, so most of it is past the window.
- (void)showPopover {
    NSViewController *controller = [[NSViewController alloc] init];
    NSTextField *text = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 140)];
    text.stringValue = @"Popover past the window's edge";
    text.bezeled = NO;
    text.editable = NO;
    text.drawsBackground = NO;
    text.alignment = NSCenterTextAlignment;
    controller.view = text;
    NSPopover *popover = [[NSPopover alloc] init];
    popover.contentViewController = controller;
    popover.behavior = NSPopoverBehaviorApplicationDefined;
    popover.contentSize = NSMakeSize(260, 140);
    self.popover = popover;
    [popover showRelativeToRect:self.anchor.bounds ofView:self.anchor preferredEdge:NSMaxXEdge];
}
- (void)showPanels {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(60, 60, 200, 110)
                                                styleMask:NSTitledWindowMask | NSUtilityWindowMask
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.title = @"Child panel";
    panel.floatingPanel = YES;
    [self.window addChildWindow:panel ordered:NSWindowAbove];
    [panel orderFront:nil];
    NSWindow *glass = [[NSWindow alloc] initWithContentRect:NSMakeRect(780, 60, 160, 160)
                                                  styleMask:NSBorderlessWindowMask
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    glass.opaque = NO;
    glass.backgroundColor = [NSColor colorWithCalibratedRed:0.1 green:0.4 blue:0.9 alpha:0.45];
    glass.hasShadow = YES;
    glass.title = @"Translucent";
    [glass orderFront:nil];
}
- (void)cancelMenu {
    [self.menu cancelTracking];
}
- (void)showMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Demo"];
    for (NSString *title in @[ @"First item", @"Second item", @"Third item", @"Fourth item" ])
        [menu addItemWithTitle:title action:NULL keyEquivalent:@""];
    self.menu = menu;
    [self performSelector:@selector(cancelMenu)
               withObject:nil
               afterDelay:3
                  inModes:@[ NSEventTrackingRunLoopMode, NSDefaultRunLoopMode ]];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(20, 180) inView:self.window.contentView];
}
- (void)endSheet:(NSWindow *)sheet {
    [NSApp endSheet:sheet];
    [sheet orderOut:nil];
}
- (void)showSheet {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"A sheet, attached to its window";
    [alert beginSheetModalForWindow:self.window modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
    [self performSelector:@selector(endSheet:) withObject:alert.window afterDelay:3];
}
@end

// Its own process, so that if GL stalls, it doesn't stop the rest of the demo.
@interface SeamlessGLDemo : NSObject <NSApplicationDelegate>
@end
@implementation SeamlessGLDemo
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [[[SeamlessDemo alloc] init] showGL];
}
@end

int seamless_gl_demo_main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        SeamlessGLDemo *demo = [[SeamlessGLDemo alloc] init];
        app.delegate = demo;
        [app run];
    }
    return 0;
}

// An update of the display, in a session that may have nothing else drawing, by a window nobody will see for a moment.
// It covers the display, as an update only goes through the windows where it changes.
void seamless_poke_update(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyProhibited;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSScreen.mainScreen.frame
                                                       styleMask:NSBorderlessWindowMask
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        window.alphaValue = 0.01;
        // Over the menu bar, and all of the display: a window drawn whole has to fit in the update, with its shadow,
        // and one that stops at the menu bar leaves out any window near it.
        window.level = NSScreenSaverWindowLevel;
        [window setFrame:NSScreen.mainScreen.frame display:NO];
        [window orderFrontRegardless];
        [window displayIfNeeded];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        [window close];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        [window release];
    }
}

int seamless_demo_app_main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        SeamlessDemo *demo = [[SeamlessDemo alloc] init];
        app.delegate = demo;
        [app run];
    }
    return 0;
}
