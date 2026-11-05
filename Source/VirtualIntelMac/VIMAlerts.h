#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
/// Prefer the supplied window, then an active app window. AppKit queues sheets;
/// a standalone alert is used only when there is no window to attach to.
void VIMPresentAlert(NSAlert *alert, NSWindow *_Nullable window,
                     void (^_Nullable completion)(NSModalResponse response));
void VIMPresentError(NSError *_Nullable error, NSWindow *_Nullable window);
/// Marks an install-flow alert; all other alerts explicitly use the app icon.
void VIMSetInstallerAlertIcon(NSAlert *alert, NSString *guest);
void VIMSetAppAlertIcon(NSAlert *alert);
/// Whether this process is a --create-guest run, which nobody is there to answer.
BOOL VIMCreatingGuestFromArguments(void);
/// In a --create-guest run, prints the message to stderr and exits 1. Otherwise does nothing.
void VIMFailCreateGuest(NSString *message);
NS_ASSUME_NONNULL_END
