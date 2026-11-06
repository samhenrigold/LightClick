// The input view in probes/seamless-input-view.h, for the proxy, which is Swift.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
/// An NSView that turns every pointer, trackpad and key event into seamless wire messages, in guest screen points, given
/// where this window's guest is on the host's screen.
NSView *SeamlessMakeInputView(NSRect frame, void (^send)(NSData *bytes));
void SeamlessInputViewSetGuestOffset(NSView *view, NSPoint offset);
/// A key equivalent the host's menu took: passes it on as the key itself, so the guest's responder chain decides.
void SeamlessInputViewForwardKeyEquivalent(NSView *view, NSEvent *event);
NS_ASSUME_NONNULL_END
