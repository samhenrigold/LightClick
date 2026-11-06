// VIMLibraryLocation lives in the MachineKit package. The panel and icon are here because they present through the app.
#import <Cocoa/Cocoa.h>
#import "MachineKit-Swift.h"

NS_ASSUME_NONNULL_BEGIN
@interface VIMLibraryLocation (Interface)
+ (NSImage *)folderIcon;
+ (void)chooseFromWindow:(nullable NSWindow *)window completion:(void (^)(BOOL changed))completion;
@end
NS_ASSUME_NONNULL_END
