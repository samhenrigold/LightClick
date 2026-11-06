// The session state its Swift helpers reach. The rest of the class's private state stays in VIMSession.m.
#import "VIMSession.h"
NS_ASSUME_NONNULL_BEGIN
@interface VIMSession ()
@property(nullable) VIMMachine *machine;
@property(nullable) NSTask *task;
// Swift knows these classes under other names, so they're `id` here.
@property(readonly, nullable) id controlConnection;
@property(readonly, nullable) id guestAgentConnection;
@property(nullable) id guestProgress;
- (id)currentSessionState;

@property NSTextField *guestStatus;
@property(nonatomic) BOOL preparing;
@property(nonatomic) BOOL preparationRequested;
@property(nonatomic) BOOL installationRequested;
@property BOOL repairArchivePending;
@property(nonatomic, nullable) NSDictionary *completionGuestReport;
- (void)logMessage:(NSString *)message;
- (void)showHeadlessRepairProgress:(NSString *)message;
- (void)showSetupNoticeAutomatic:(BOOL)automatic automaticLogin:(BOOL)automaticLogin restarting:(BOOL)restarting;
- (void)dismissSetupNotice;
- (void)refreshGuestStatus;
- (void)scheduleGuestStatusRetry;
- (void)scheduleGuestStatusRefreshAfter:(NSTimeInterval)delay;
- (void)updateClipboardForBoot:(NSString *)boot;
- (void)restoreDisplaySelectionForBoot:(NSString *)boot;
- (void)handoffToGraphics;
- (void)offerGraphicsRestart;
@property(nullable) NSString *runtimeDirectory;
/// Every session's machine, none of which may be on a device given to a guest.
@property(class, readonly) NSArray<NSURL *> *machineURLs;
@end
NS_ASSUME_NONNULL_END
