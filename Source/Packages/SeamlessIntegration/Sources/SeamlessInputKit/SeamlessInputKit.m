#import "SeamlessInputKit.h"
#include "../../../../probes/seamless-input-view.h"

NSView *SeamlessMakeInputView(NSRect frame, void (^send)(NSData *bytes)) {
    SeamlessInputView *view = [[SeamlessInputView alloc] initWithFrame:frame];
    view.absolute = YES;
    view.send = ^(const uint8_t *data, size_t size) {
      send([NSData dataWithBytes:data length:size]);
    };
    return view;
}

void SeamlessInputViewSetRaisesWindow(NSView *view, uint32_t window) { ((SeamlessInputView *)view).raisesWindow = window; }
void SeamlessInputViewSetGuestOffset(NSView *view, NSPoint offset) { ((SeamlessInputView *)view).guestOffset = offset; }

void SeamlessInputViewForwardKeyEquivalent(NSView *view, NSEvent *event) {
    SeamlessInputView *input = (SeamlessInputView *)view;
    [input sendKey:event.keyCode down:YES flags:event.modifierFlags];
    [input sendKey:event.keyCode down:NO flags:event.modifierFlags];
}
