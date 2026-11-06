// The session state its Swift helpers reach. The rest of the class's private state stays in VIMSession.m.
#import "VIMSession.h"
@class VIMMetalView;
NS_ASSUME_NONNULL_BEGIN
@interface VIMSession ()
@property(nullable) VIMMachine *machine;
@property(nullable) NSTask *task;
// Swift knows these classes under other names, so they're `id` here.
@property(readonly, nullable) id controlConnection;
@property(readonly, nullable) id guestAgentConnection;
@property(nullable) id guestProgress;
@property(readonly, nullable) id usbDevicesObject;
@property(readonly, nullable) id imageDrivesObject;
- (id)currentSessionState;

@property NSTextField *guestStatus;
@property(nullable) VIMMetalView *displayView;
@property(nullable) NSTextField *status;
@property(nullable) NSStackView *statePanel;
@property(nullable) NSTextField *stateLabel;
@property(nullable) NSButton *stateAction;
@property(nullable) NSButton *shutdownButton;
@property(nullable) NSArray<NSString *> *guestIPAddresses;
@property(nullable) NSString *displayToolDirectory;
@property(nullable) NSString *lastRunState;
@property(nullable) NSArray<NSDate *> *recentGuestReboots;
@property(nullable) NSURL *pendingHostConnectionURL;
@property(nullable, copy) void (^pendingHostConnectionCompletion)(NSError *_Nullable);
- (void)noteGuestRebootExpected;
- (void)requestGuestDisplaySleeping:(BOOL)sleeping;
- (void)cleanUp;
- (void)showStoppedScreen;
+ (nullable VIMSession *)sessionForMachine:(VIMMachine *)machine NS_SWIFT_NAME(session(for:));
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
