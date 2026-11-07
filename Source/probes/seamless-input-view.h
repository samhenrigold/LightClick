// The proxy window's content view on the host: captures everything a Mac can say about pointer, trackpad and keyboard,
// and sends it to the guest as the wire's messages. Sends from the event handler, on the main thread: no timer, no
// display link. `send` must not block. seamless-input-queue.h is the matching queue. See seamless-input.md for why each
// route is what it is.
#ifndef SEAMLESS_INPUT_VIEW_H
#define SEAMLESS_INPUT_VIEW_H
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include "seamless-wire.h"

// Which keys stay on the host. Everything else goes to the guest app, because a guest app's Cmd-Q and Cmd-W have to run
// its own save prompts. The proxy learns the app quit when its windows go. Cmd-Tab, Cmd-Space and Mission Control never
// arrive: the system takes those before any app, so there's nothing to route.
static inline BOOL SWIKeyStaysOnHost(unsigned short code, NSEventModifierFlags flags) {
    NSEventModifierFlags held = flags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                         NSEventModifierFlagControl | NSEventModifierFlagShift);
    if (!(held & NSEventModifierFlagCommand))
        return NO;
    switch (code) {
        case 4: // H: hide, and with Option hide others. The proxy is the app the Dock knows.
            return held == NSEventModifierFlagCommand ||
                   held == (NSEventModifierFlagCommand | NSEventModifierFlagOption);
        case 46: // M: minimize. The window is the host's.
            return held == NSEventModifierFlagCommand;
        case 50: // Grave: cycle windows, which only the host can see in order.
            return held == NSEventModifierFlagCommand ||
                   held == (NSEventModifierFlagCommand | NSEventModifierFlagShift);
        case 3: // F, with Control: full screen, which has to be the host's Space, not the guest's.
            return held == (NSEventModifierFlagCommand | NSEventModifierFlagControl);
        default:
            return NO;
    }
}

static inline uint8_t SWIPhaseFromNSEvent(NSEventPhase phase) {
    switch (phase) {
        case NSEventPhaseBegan:
            return SWP_BEGAN;
        case NSEventPhaseStationary:
        case NSEventPhaseChanged:
            return SWP_CHANGED;
        case NSEventPhaseEnded:
            return SWP_ENDED;
        case NSEventPhaseCancelled:
            return SWP_CANCELLED;
        case NSEventPhaseMayBegin:
            return SWP_MAY_BEGIN;
        default:
            return SWP_NONE;
    }
}
static inline uint8_t SWIMomentumFromNSEvent(NSEventPhase phase) {
    switch (phase) {
        case NSEventPhaseBegan:
            return SWM_MOMENTUM_BEGAN;
        case NSEventPhaseStationary:
        case NSEventPhaseChanged:
            return SWM_MOMENTUM_CHANGED;
        case NSEventPhaseEnded:
        case NSEventPhaseCancelled:
            return SWM_MOMENTUM_ENDED;
        default:
            return SWM_MOMENTUM_NONE;
    }
}

@interface SeamlessInputView : NSView <NSTextInputClient>
@property(copy) void (^send)(const uint8_t *bytes, size_t size);
@property uint32_t guestWindow;
// In a tree, the guest window a press is for. A press goes by position, which in the guest may be another window's.
@property uint32_t raisesWindow;
// With `absolute`, events carry guest screen points: this window's position on the host's screen, less this offset. For
// a window that follows the guest's, where window-relative points chase themselves during a drag.
@property BOOL absolute;
@property NSPoint guestOffset;
// Whether the host's input method composes, with commits sent as text. Otherwise raw keys go to the guest's own, which
// needs the same input source there: see forwardInputSource. Set from what the guest says it has.
@property BOOL hostComposes;
- (void)forwardInputSource;
@end

@implementation SeamlessInputView {
    NSMutableSet<NSNumber *> *_pressed;
    NSTextField *_marked;
    NSTrackingArea *_area;
    BOOL _lookSent;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    _pressed = [NSMutableSet set];
    return self;
}
- (BOOL)isFlipped {
    return YES;
}
- (BOOL)acceptsFirstResponder {
    return YES;
}
// Yes, so the guest decides. A click on a window that's in the background here is one on a window that's in the
// background there, as long as focus isn't handed over first, and guest AppKit then applies that app's own rule.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_area)
        [self removeTrackingArea:_area];
    // Only with this app active: the guest has one pointer, and it shouldn't jump because the host's passed over a window.
    // shortcut: a background window's hover doesn't update in the guest, as it would on a real Mac; a click there still carries its place.
    _area = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                         options:NSTrackingMouseMoved | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
                                           owner:self
                                        userInfo:nil];
    [self addTrackingArea:_area];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self];
    if (!self.window)
        return;
    [center addObserver:self
               selector:@selector(windowBecameKey:)
                   name:NSWindowDidBecomeKeyNotification
                 object:self.window];
    [center addObserver:self
               selector:@selector(windowResignedKey:)
                   name:NSWindowDidResignKeyNotification
                 object:self.window];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(forwardInputSource)
               name:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged
             object:nil];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
}

// ---- Focus ----

- (void)sendModifiers:(NSEventModifierFlags)flags {
    uint8_t out[32];
    self.send(out, swm_put_u32_message(out, sizeof(out), SWM_MODIFIERS, (uint32_t)flags));
}
- (void)windowBecameKey:(NSNotification *)note {
    [self forwardInputSource];
    // Modifiers may have changed while another app was front: Cmd-Tab back arrives with Command still held.
    [self sendModifiers:NSEvent.modifierFlags & 0xFFFFFFFF];
    // A click that brought this window forward has to reach the guest with the guest window still in the background,
    // or a click-through the app would refuse becomes a real click. It's sent from mouseDown:, which raises it.
    NSEventType type = NSApp.currentEvent.type;
    if (type == NSEventTypeLeftMouseDown || type == NSEventTypeRightMouseDown || type == NSEventTypeOtherMouseDown)
        return;
    uint8_t out[32];
    self.send(out, swm_put_u32_message(out, sizeof(out), SWM_FOCUS, self.guestWindow));
}
// Cmd-Tab away never delivers the key-up, and a guest with Command stuck down turns every later key into a shortcut.
- (void)windowResignedKey:(NSNotification *)note {
    for (NSNumber *code in _pressed.allObjects)
        [self sendKey:code.unsignedShortValue down:NO flags:0];
    [_pressed removeAllObjects];
    [self sendModifiers:0];
}

// ---- Pointer ----

- (NSPoint)wirePointFor:(NSEvent *)event {
    if (!self.absolute)
        return [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint screen = [self.window convertPointToScreen:event.locationInWindow];
    return NSMakePoint(screen.x - self.guestOffset.x,
                       NSScreen.screens.firstObject.frame.size.height - screen.y - self.guestOffset.y);
}
- (void)sendPointer:(uint8_t)kind button:(uint8_t)button event:(NSEvent *)event {
    NSPoint p = [self wirePointFor:event];
    if (kind == SWM_DOWN && self.raisesWindow) {
        uint8_t raise[64];
        self.send(raise, swm_put_u32_message(raise, sizeof(raise), SWM_RAISE, self.raisesWindow));
    }
    struct SWMPointer e = {self.absolute ? 0 : self.guestWindow,
                           kind,
                           button,
                           (uint8_t)MIN(kind == SWM_MOVE ? 0 : event.clickCount, 255),
                           (int32_t)lround(p.x * 16),
                           (int32_t)lround(p.y * 16),
                           (uint32_t)event.modifierFlags};
    uint8_t out[64];
    self.send(out, swm_put_pointer(out, sizeof(out), &e));
}
static inline uint8_t SWIButton(NSEvent *event) { return event.buttonNumber > 2 ? 2 : (uint8_t)event.buttonNumber; }
- (void)mouseMoved:(NSEvent *)e {
    // Only the window that's really under the pointer: one of this app's can be behind another of its own.
    if ([NSWindow windowNumberAtPoint:NSEvent.mouseLocation belowWindowWithWindowNumber:0] == self.window.windowNumber)
        [self sendPointer:SWM_MOVE button:0 event:e];
}
- (void)mouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    [self sendPointer:SWM_DOWN button:0 event:e];
}
- (void)mouseDragged:(NSEvent *)e {
    [self sendPointer:SWM_DRAG button:0 event:e];
}
- (void)mouseUp:(NSEvent *)e {
    [self sendPointer:SWM_UP button:0 event:e];
}
- (void)rightMouseDown:(NSEvent *)e {
    [self sendPointer:SWM_DOWN button:1 event:e];
}
- (void)rightMouseDragged:(NSEvent *)e {
    [self sendPointer:SWM_DRAG button:1 event:e];
}
- (void)rightMouseUp:(NSEvent *)e {
    [self sendPointer:SWM_UP button:1 event:e];
}
- (void)otherMouseDown:(NSEvent *)e {
    [self sendPointer:SWM_DOWN button:SWIButton(e) event:e];
}
- (void)otherMouseDragged:(NSEvent *)e {
    [self sendPointer:SWM_DRAG button:SWIButton(e) event:e];
}
- (void)otherMouseUp:(NSEvent *)e {
    [self sendPointer:SWM_UP button:SWIButton(e) event:e];
}

// ---- Trackpad ----

- (void)sendGesture:(uint8_t)kind event:(NSEvent *)event a:(double)a b:(double)b c:(double)c stage:(uint8_t)stage {
    NSPoint p = [self wirePointFor:event];
    struct SWMGesture g = {self.absolute ? 0 : self.guestWindow,
                           kind,
                           0,
                           0,
                           stage,
                           (int32_t)lround(p.x * 16),
                           (int32_t)lround(p.y * 16),
                           (float)a,
                           (float)b,
                           (float)c,
                           0,
                           (uint32_t)event.modifierFlags};
    if (event.type == NSEventTypeScrollWheel) {
        g.flags = (event.hasPreciseScrollingDeltas ? SWG_PRECISE : 0) |
                  (event.isDirectionInvertedFromDevice ? SWG_INVERTED : 0);
        g.momentum = SWIMomentumFromNSEvent(event.momentumPhase);
    }
    if (event.type != NSEventTypeBeginGesture && event.type != NSEventTypeEndGesture &&
        event.type != NSEventTypeQuickLook && event.type != NSEventTypeSmartMagnify && event.type != NSEventTypeSwipe)
        g.phase = SWIPhaseFromNSEvent(event.phase);
    uint8_t out[64];
    self.send(out, swm_put_gesture(out, sizeof(out), &g));
}
- (void)scrollWheel:(NSEvent *)e {
    [self sendGesture:SWG_SCROLL event:e a:e.scrollingDeltaX b:e.scrollingDeltaY c:e.deltaZ stage:0];
}
- (void)magnifyWithEvent:(NSEvent *)e {
    [self sendGesture:SWG_MAGNIFY event:e a:e.magnification b:0 c:0 stage:0];
}
- (void)rotateWithEvent:(NSEvent *)e {
    [self sendGesture:SWG_ROTATE event:e a:e.rotation b:0 c:0 stage:0];
}
- (void)swipeWithEvent:(NSEvent *)e {
    [self sendGesture:SWG_SWIPE event:e a:e.deltaX b:e.deltaY c:0 stage:0];
}
- (void)smartMagnifyWithEvent:(NSEvent *)e {
    [self sendGesture:SWG_SMART_MAGNIFY event:e a:0 b:0 c:0 stage:0];
}
- (void)quickLookWithEvent:(NSEvent *)e {
    if (!_lookSent)
        [self sendGesture:SWG_QUICK_LOOK event:e a:0 b:0 c:0 stage:0];
    _lookSent = e.pressure > 0; // A force click can report here as well as through stage 2, and a tap has no pressure.
}
// Pressure goes on for apps that read it. A guest has no force-capable device, so its AppKit won't treat this as a
// force click by itself (NSEvent's associatedEventsMask asks the device), and Look Up has to be asked for: see
// seamless-input.md.
- (void)pressureChangeWithEvent:(NSEvent *)e {
    [self sendGesture:SWG_PRESSURE event:e a:e.pressure b:e.stageTransition c:0 stage:(uint8_t)e.stage];
    if (e.stage >= 2 && !_lookSent) {
        [self sendGesture:SWG_QUICK_LOOK event:e a:0 b:0 c:0 stage:0];
        _lookSent = YES;
    } else if (e.stage == 0)
        _lookSent = NO;
}

// ---- Keyboard ----

- (void)sendKey:(unsigned short)code down:(BOOL)down flags:(NSEventModifierFlags)flags {
    struct SWMKey k = {code, (uint8_t)down, (uint32_t)flags};
    uint8_t out[32];
    self.send(out, swm_put_key(out, sizeof(out), &k));
    if (down)
        [_pressed addObject:@(code)];
    else
        [_pressed removeObject:@(code)];
}
- (void)keyDown:(NSEvent *)e {
    if (self.hostComposes && [self.inputContext handleEvent:e])
        return; // Back through insertText: or doCommandBySelector:.
    [self sendKey:e.keyCode down:YES flags:e.modifierFlags];
}
- (void)keyUp:(NSEvent *)e {
    if ([_pressed containsObject:@(e.keyCode)])
        [self sendKey:e.keyCode down:NO flags:e.modifierFlags];
}
- (BOOL)performKeyEquivalent:(NSEvent *)e {
    if (self.window.firstResponder != self || !(e.modifierFlags & NSEventModifierFlagCommand) ||
        SWIKeyStaysOnHost(e.keyCode, e.modifierFlags))
        return NO; // On to the proxy's menu, which owns Hide, Minimize and so on.
    // AppKit won't deliver the key-up of a consumed command equivalent.
    [self sendKey:e.keyCode down:YES flags:e.modifierFlags];
    [self sendKey:e.keyCode down:NO flags:e.modifierFlags];
    return YES;
}
- (void)flagsChanged:(NSEvent *)e {
    NSEventModifierFlags mask;
    switch (e.keyCode) {
        case 54:
            mask = 0x10; // Device-dependent bits, so left and right stay separate.
            break;
        case 55:
            mask = 0x8;
            break;
        case 56:
            mask = 0x2;
            break;
        case 60:
            mask = 0x4;
            break;
        case 58:
            mask = 0x20;
            break;
        case 61:
            mask = 0x40;
            break;
        case 59:
            mask = 0x1;
            break;
        case 62:
            mask = 0x2000;
            break;
        case 63:
            mask = NSEventModifierFlagFunction;
            break;
        case 57: // Caps Lock toggles: a press and a release each time.
            [self sendKey:57 down:YES flags:e.modifierFlags];
            [self sendKey:57 down:NO flags:e.modifierFlags];
            return;
        default:
            return; // A focus notification with keyCode 0 isn't the A key.
    }
    [self sendKey:e.keyCode down:(e.modifierFlags & mask) != 0 flags:e.modifierFlags];
}

// The guest's layout has to match, or a dead key or an AZERTY key means something else there.
- (void)forwardInputSource {
    TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
    NSString *identifier =
        source ? (__bridge NSString *)TISGetInputSourceProperty(source, kTISPropertyInputSourceID) : nil;
    const char *bytes = identifier.UTF8String;
    if (bytes && strlen(bytes) <= SWM_MAX_TEXT) {
        struct SWMText t = {self.guestWindow, SWT_INPUT_SOURCE, (uint16_t)strlen(bytes), bytes};
        uint8_t out[SWM_HEADER_SIZE + SWM_TEXT_FIXED + SWM_MAX_TEXT];
        self.send(out, swm_put_text(out, sizeof(out), &t));
    }
    if (source)
        CFRelease(source);
}

// ---- Host input method, for when the guest doesn't have the same one ----

- (void)insertText:(id)text replacementRange:(NSRange)range {
    NSString *string = [text isKindOfClass:[NSAttributedString class]] ? [text string] : text;
    [self unmarkText];
    const char *bytes = string.UTF8String;
    size_t length = bytes ? strlen(bytes) : 0;
    uint8_t out[SWM_HEADER_SIZE + SWM_TEXT_FIXED + SWM_MAX_TEXT];
    for (size_t at = 0; at < length;) {
        size_t count = MIN(length - at, SWM_MAX_TEXT);
        while (count && at + count < length && (bytes[at + count] & 0xC0) == 0x80)
            count--; // Not through a UTF-8 sequence.
        struct SWMText t = {self.guestWindow, SWT_INSERT, (uint16_t)count, bytes + at};
        self.send(out, swm_put_text(out, sizeof(out), &t));
        at += count;
    }
}
// shortcut: composition shows in a small field by the pointer, since no public API puts marked text into a guest app.
// Upgrade with AX's bounds for the guest's selected range, to place it at the caret.
- (void)setMarkedText:(id)text selectedRange:(NSRange)selected replacementRange:(NSRange)range {
    NSString *string = [text isKindOfClass:[NSAttributedString class]] ? [text string] : text;
    if (!string.length) {
        [self unmarkText];
        return;
    }
    if (!_marked) {
        _marked = [NSTextField labelWithString:@""];
        _marked.drawsBackground = YES;
        _marked.backgroundColor = NSColor.textBackgroundColor;
        [self addSubview:_marked];
    }
    _marked.stringValue = string;
    [_marked sizeToFit];
    NSPoint p = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    [_marked setFrameOrigin:p];
}
- (void)unmarkText {
    [_marked removeFromSuperview];
    _marked = nil;
}
// A key the input method didn't want, such as Return with nothing composing: send it as the key it was.
- (void)doCommandBySelector:(SEL)selector {
    NSEvent *e = NSApp.currentEvent;
    if (e.type == NSEventTypeKeyDown)
        [self sendKey:e.keyCode down:YES flags:e.modifierFlags];
}
- (BOOL)hasMarkedText {
    return _marked != nil;
}
- (NSRange)markedRange {
    return _marked ? NSMakeRange(0, _marked.stringValue.length) : NSMakeRange(NSNotFound, 0);
}
- (NSRange)selectedRange {
    return NSMakeRange(NSNotFound, 0);
}
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual {
    return nil;
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
    NSPoint p = NSEvent.mouseLocation;
    return NSMakeRect(p.x, p.y, 0, 20);
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return NSNotFound;
}
@end
#endif
