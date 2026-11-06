#import <Cocoa/Cocoa.h>
@interface VIMMenuController : NSObject <NSMenuDelegate, NSMenuItemValidation>
// `library` is a VIMLibraryViewController, from Swift.
- (instancetype)initWithLibrary:(id)library;
@end
