// The session state its Swift helpers reach. The rest of the class's private state stays in VIMSession.m.
#import "VIMSession.h"
NS_ASSUME_NONNULL_BEGIN
@interface VIMSession ()
@property(nullable) VIMMachine *machine;
@property(nullable) NSTask *task;
@property(readonly, nullable) id controlConnection; // A VIMQMPConnection, which Swift knows under another name.
@property(nullable) NSString *runtimeDirectory;
/// Every session's machine, none of which may be on a device given to a guest.
@property(class, readonly) NSArray<NSURL *> *machineURLs;
@end
NS_ASSUME_NONNULL_END
