#import <AVFoundation/AVFoundation.h>
#import "VIMSession.h"
#import "VIMGuestFiles.h"
#import "VIMGuestProfile.h"
#import "VIMSymbolImages.h"
#import "AppDelegate.h"
#import "VIMMachine.h"
#import "MachineKit-Swift.h"
#import "VIMMetalView.h"
#import "VIMDisplayConnection.h"
#import "VIMQMPConnection.h"
#import "VIMGuestAgent.h"
#import "VIMGuestPreparation.h"
#import "VIMSMBService.h"
#import "VIMHostUSB.h"
#import "VIMUSBClient.h"
#import "VIMLibraryLocation.h"
#import "VIMGuestInstallation.h"
#import "VIMInstallerAssembly.h"
#import "VIMGuestBootPolicy.h"
#import "VIMGuestProgress.h"
#import "VIMHostSupport.h"
#import "VIMPlayButton.h"
#import "VIMAlerts.h"
#import "VIMDiscImage.h"
#import "VIMHostAudio.h"
#import "VIMNetworkDefaults.h"
#import "VIMNetworkClient.h"
#import "VIMClipboardBridge.h"
#import "VIMWindowGeometry.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#import "VIMResearchInput.h"
#import "VIMAutomaticSetup.h"
#import "VIMModernSetup.h"
#import "VIMOpenGLSetup.h"
#import "VIMOSNaming.h"
#import "VIMInstallerCatalog.h"
#import "VIMImageSlots.h"
#import "VIMLegacyTabletPolicy.h"
#import "Light_Click-Swift.h"

static NSMutableDictionary<NSString *, VIMSession *> *sessions;
static NSMutableDictionary<NSString *, NSUUID *> *pendingRosettaStarts;

@interface VIMSetupNoticeView : NSView
@property(nonatomic, weak) NSButton *closeButton;
@end
@implementation VIMSetupNoticeView
- (NSView *)hitTest:(NSPoint)point {
    // The guest display underneath keeps receiving pointer input. Only the
    // actual dismiss button is interactive, not the material or its text.
    return [self.closeButton hitTest:[self.closeButton.superview convertPoint:point fromView:self.superview]];
}
- (void)layout {
    [super layout];
    CGPathRef shape = CGPathCreateWithRoundedRect(NSRectToCGRect(self.bounds), 14, 14, NULL);
    self.layer.shadowPath = shape;
    CGPathRelease(shape);
}
@end
// Explicit local opt-in for unattended development; ordinary installs ask.
static BOOL VIMSkipsDevelopmentPowerConfirmation(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"VIMSkipPowerConfirmation"] ||
           [NSProcessInfo.processInfo.arguments containsObject:@"--development-no-power-confirmation"];
}
typedef NS_ENUM(NSUInteger, VIMBootOperation) { VIMBootStart, VIMBootPrepare, VIMBootInstall, VIMBootRepair };
static NSString *SessionKey(VIMMachine *machine) {
    return machine.configuration[@"Identifier"] ?: machine.URL.URLByResolvingSymlinksInPath.path;
}
static NSError *VIMSessionError(NSString *message) {
    return [NSError errorWithDomain:@"VirtualIntelMac.Session" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}
static BOOL VIMPrepareOpenGLSurfaceEndpoint(VIMDisplayConnection *connection, pid_t pid, NSString *runtimeDirectory,
                                            NSError **error) {
    NSError *failure = nil;
    NSString *service = [connection enableSurfaceTransportForRendererPID:pid error:&failure];
    if (!service) {
        if (error)
            *error = failure ?: VIMSessionError(@"The OpenGL renderer could not be connected.");
        return NO;
    }
    NSMutableArray<NSString *> *paths =
        [NSMutableArray arrayWithObject:[runtimeDirectory stringByAppendingPathComponent:@"graphics-endpoint.plist"]];
    NSString *explicitEndpoint = NSProcessInfo.processInfo.environment[@"VIM_OPENGL_DISPLAY_ENDPOINT"];
    if (explicitEndpoint.length)
        [paths addObject:explicitEndpoint];
    NSDictionary *description = @{@"Version" : @1, @"Service" : service, @"RendererPID" : @(pid)};
    for (NSString *path in paths) {
        NSDictionary *attributes =
            [NSFileManager.defaultManager attributesOfItemAtPath:path.stringByDeletingLastPathComponent error:NULL];
        BOOL privateDirectory = [attributes[NSFileType] isEqual:NSFileTypeDirectory] &&
                                [attributes[NSFileOwnerAccountID] unsignedIntValue] == getuid() &&
                                !([attributes[NSFilePosixPermissions] unsignedIntValue] & 0077);
        if (!privateDirectory || ![description writeToFile:path atomically:YES] ||
            ![NSFileManager.defaultManager setAttributes:@{
                NSFilePosixPermissions : @0600
            }
                                            ofItemAtPath:path
                                                   error:NULL]) {
            if (error)
                *error = VIMSessionError(@"The graphics display connection could not be prepared.");
            return NO;
        }
    }
    return YES;
}
@interface VIMStoppedMacView : NSView
@property NSImageView *wallpaper;
@property NSString *guest;
@property VIMPlayButton *playButton;
@property NSImageView *mark;
@property NSTextField *nameField;
- (instancetype)initWithGuest:(NSString *)guest name:(NSString *)name target:(id)target action:(SEL)action;
@end
@implementation VIMStoppedMacView
- (instancetype)initWithGuest:(NSString *)guest name:(NSString *)name target:(id)target action:(SEL)action {
    if ((self = [super initWithFrame:NSZeroRect])) {
        self.guest = guest;
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
        NSImage *image =
            [NSImage imageNamed:[guest stringByAppendingString:@"Wallpaper"]] ?: [NSImage imageNamed:@"tigerWallpaper"];
        self.wallpaper = [NSImageView imageViewWithImage:image];
        self.wallpaper.imageScaling = NSImageScaleProportionallyUpOrDown;
        // This presentation is frame-laid-out, not a sizing contract for the
        // window. Neither wallpaper size nor a capped proportional Play button
        // may propagate a minimum/maximum window width through Auto Layout.
        self.wallpaper.accessibilityElement = NO;
        [self addSubview:self.wallpaper];
        NSVisualEffectView *material = [NSVisualEffectView new];
        material.material = NSVisualEffectMaterialUnderWindowBackground;
        material.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        material.state = NSVisualEffectStateActive;
        material.frame = self.bounds;
        material.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        material.accessibilityElement = NO;
        [self addSubview:material];
        self.playButton = [VIMPlayButton new];
        self.playButton.target = target;
        self.playButton.action = action;
        self.playButton.bordered = NO;
        self.playButton.contentTintColor = NSColor.controlAccentColor;
        self.playButton.imageScaling = NSImageScaleProportionallyDown;
        self.playButton.toolTip = @"Start this Mac";
        self.playButton.accessibilityLabel = [@"Start " stringByAppendingString:name];
        self.playButton.keyEquivalent = @"\r";
        [self addSubview:self.playButton];
        NSImage *product = [NSImage imageNamed:[guest stringByAppendingString:@"ProductIcon"]];
        if (!product && !VIMGuestHasTrait(guest, VIMGuestTraitNoRoundelArtwork))
            product = [NSImage imageNamed:[guest stringByAppendingString:@"Roundel"]];
        self.mark = [NSImageView imageViewWithImage:product ?: NSApp.applicationIconImage];
        self.mark.imageScaling = NSImageScaleProportionallyUpOrDown;
        [self addSubview:self.mark];
        self.nameField = [NSTextField labelWithString:name];
        self.nameField.font = [NSFont systemFontOfSize:38 weight:NSFontWeightLight];
        self.nameField.textColor = NSColor.labelColor;
        self.nameField.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:self.nameField];
    }
    return self;
}
- (void)layout {
    [super layout];
    NSSize image = self.wallpaper.image.size;
    CGFloat scale = MAX(NSWidth(self.bounds) / MAX(1, image.width), NSHeight(self.bounds) / MAX(1, image.height));
    NSSize size = NSMakeSize(image.width * scale, image.height * scale);
    self.wallpaper.frame = NSMakeRect(NSMidX(self.bounds) - size.width / 2, NSMidY(self.bounds) - size.height / 2,
                                      size.width, size.height);
    CGFloat diameter = MIN(260, MAX(160, NSWidth(self.bounds) * .205));
    diameter = MIN(diameter, MAX(120, NSHeight(self.bounds) - 56 - 28 - 24));
    CGFloat bottom = NSMidY(self.bounds) - (diameter + 28 + 56) / 2;
    self.playButton.frame = NSMakeRect(NSMidX(self.bounds) - diameter / 2, bottom + 56 + 28, diameter, diameter);
    // A truncating NSTextField's intrinsic width can depend on its last frame.
    // Measure the full title instead, so repeated layouts never shrink it.
    NSSize titleSize = [self.nameField.stringValue sizeWithAttributes:@{NSFontAttributeName : self.nameField.font}];
    CGFloat nameWidth = MIN(ceil(titleSize.width) + 8, MAX(0, NSWidth(self.bounds) - 64 - 56 - 12));
    CGFloat identityWidth = 56 + 12 + nameWidth, nameHeight = ceil(titleSize.height) + 4;
    CGFloat left = NSMidX(self.bounds) - identityWidth / 2;
    self.mark.frame = NSMakeRect(left, bottom, 56, 56);
    self.nameField.frame = NSMakeRect(left + 56 + 12, bottom + (56 - nameHeight) / 2, nameWidth, nameHeight);
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.wallpaper.image = [NSImage imageNamed:[self.guest stringByAppendingString:@"Wallpaper"]];
    self.needsLayout = YES;
}
@end
static NSString *const VIMUSBMenuTitle = @"USB Devices";
static NSString *const VIMToolbarMenuTitleIdentifier = @"VIMToolbarMenuTitle";
static NSString *ToolbarMenuTitle(NSMenu *menu) {
    NSMenuItem *first = menu.itemArray.firstObject;
    return [first.identifier isEqual:VIMToolbarMenuTitleIdentifier] ? first.title : nil;
}
static NSMenu *WithToolbarMenuTitle(NSMenu *menu, NSString *title) {
    if (title.length && !ToolbarMenuTitle(menu)) {
        // Rebuilding a grouped pull-down menu removes AppKit's title slot.
        // Restore it before real actions/devices, or entry zero disappears.
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        item.identifier = VIMToolbarMenuTitleIdentifier;
        item.enabled = NO;
        [menu insertItem:item atIndex:0];
    }
    return menu;
}
// NSMenuToolbarItem copies menus while constructing its
// controls. NSMenu does not retain/copy its delegate contract for us. Preserve
// the logical kind and delegate so these copies stay live, not boot snapshots.
@interface VIMLiveDeviceMenu : NSMenu
@property(copy) NSString *deviceKind;
@end
@implementation VIMLiveDeviceMenu
- (id)copyWithZone:(NSZone *)zone {
    VIMLiveDeviceMenu *copy = [super copyWithZone:zone];
    copy.deviceKind = self.deviceKind;
    copy.delegate = self.delegate;
    return copy;
}
@end
@interface VIMSession () <NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate, NSToolbarDelegate>
@property VIMMachine *machine;
@property(readonly) VIMGuestSessionState *state;
- (void)logNote:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
@property NSTask *task;
@property NSFileHandle *log;
@property VIMMetalView *displayView;
@property VIMDisplayConnection *displayConnection;
@property VIMQMPConnection *control;
@property VIMGuestAgent *guestAgent;
@property VIMOpenGLSetup *openGLSetup;
@property BOOL openGLLargeResizeReady;
@property BOOL openGLSetupMediaAttached;
@property BOOL openGLRestartAttempted;
@property NSUInteger tabletTrim;
@property VIMGuestProgress *guestProgress;
@property NSData *guestStatusTool;
@property NSTextField *guestStatus;
@property NSView *setupNotice;
@property(copy) NSString *setupNoticeHeading;
@property(copy) NSString *closedSetupNoticeHeading;
@property BOOL previewSetupNotice;
@property NSTimer *guestTimer;
@property NSURL *pendingHostConnectionURL;
@property(copy) void (^pendingHostConnectionCompletion)(NSError *);
- (void)servicePendingHostConnection;
@property NSString *diagnosticDirectory;
@property VIMSessionDiagnostics *diagnostics;
@property NSDictionary *observedDisplayMode;
- (void)applyDisplayMode:(NSString *)mode completion:(void (^)(NSDictionary *, NSError *))completion;
@property(weak) NSWindow *diagnosticAboutWindow;
@property(nonatomic) BOOL preparationRequested;
@property(nonatomic) BOOL installationRequested;
@property BOOL automaticInstallation;
@property NSArray<NSDate *> *recentGuestReboots;
@property NSTimer *handoffTimer;
@property(nonatomic) NSDictionary *completionGuestReport;
@property BOOL repairArchivePending;
@property(nonatomic) BOOL preparing;
@property VIMInstallationActivity *sleepActivity;
@property NSString *lastGuestMessage;
@property NSTextField *status;
@property NSString *runtimeDirectory;
@property NSButton *shutdownButton;
@property NSTimer *resizeTimer;
@property NSSize lastRequestedSize;
@property BOOL resizeArmed;
@property NSString *sleepDisabledBoot;
@property NSString *mavericksSMBCheckedBoot;
@property VIMClipboardBridge *clipboard;
@property VIMClipboardBridge *powerBridge;
@property NSString *powerConfiguredBoot;
@property NSDate *powerRetryAfter;
@property VIMSMBService *smbService;
@property VIMNetworkClient *networkClient;
@property BOOL networkStarting;
@property BOOL clipboardSharingEnabled;
@property NSString *clipboardFailure;
@property NSString *clipboardConfiguredBoot;
@property NSDate *clipboardRetryAfter;
@property NSMutableDictionary<NSString *, NSString *> *usbAttached;
@property NSArray<NSDictionary *> *audioOutputChoices;
@property NSArray<NSDictionary *> *audioInputChoices;
@property BOOL audioChoicesPending;
@property NSArray<NSString *> *guestIPAddresses;
@property NSTimer *statusTimer;
@property BOOL statusPending;
@property BOOL runStateQueryFailed;
@property NSString *lastRunState;
@property BOOL wakePending;
@property VIMModernSetup *modernSetup;
@property NSTimer *controlRetryTimer;
@property NSTimer *controlStallTimer;
@property BOOL controlStallShown;
@property VIMUSBClient *usbClient;
- (void)ensureUSBClient;
@property BOOL usbOperationPending;
@property int machineLock;
@property NSStackView *statePanel;
@property NSTextField *stateLabel;
@property NSButton *stateAction;
@property(nonatomic) BOOL retinaEnabled;
@property(nonatomic) NSString *displayMode;
@property NSString *displayToolDirectory;
@property VIMImageDrives *imageDrives;
@end
@implementation VIMSession
+ (void)initialize {
    if (self != VIMSession.class)
        return;
    [NSNotificationCenter.defaultCenter addObserverForName:@"VIMMachineRelocated"
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
                                                  VIMSession *session = sessions[note.userInfo[@"Identifier"]];
                                                  if (session && !session.task.running) {
                                                      VIMMachine *fresh = [VIMMachine loadURL:note.userInfo[@"URL"]
                                                                                        error:nil];
                                                      if (fresh) {
                                                          session.machine = fresh;
                                                          [session showStoppedScreen];
                                                      }
                                                  }
                                                }];
}
- (void)logNote:(NSString *)format, ... {
    va_list arguments;
    va_start(arguments, format);
    NSString *note = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    [self.log
        writeData:[[NSString stringWithFormat:@"\n[Light Click] %@\n", note] dataUsingEncoding:NSUTF8StringEncoding]];
}
- (void)applyLifecycleEvent:(VIMSessionEvent)event {
    NSString *before = self.state.lifecycleDescription;
    [self.state applyEvent:event];
    if (![before isEqual:self.state.lifecycleDescription])
        [self logNote:@"Session: %@ -> %@", before, self.state.lifecycleDescription];
}
- (void)updateInstallationActivity {
    NSDictionary *config = self.machine.configuration;
    BOOL active = [self.guestSessionState keepsHostAwakeWithInstallerMedia:config[@"InstallerMedia"] != nil
                                                              installState:config[@"InstallState"]
                                                          completionReport:self.completionGuestReport != nil];
    if (active && !self.sleepActivity)
        self.sleepActivity = [VIMInstallationActivity beginWithReason:@"Installing macOS in a virtual Mac"];
    else if (!active)
        self.sleepActivity = nil;
}
- (void)setPreparing:(BOOL)value {
    _preparing = value;
    [self updateInstallationActivity];
}
- (void)setPreparationRequested:(BOOL)value {
    _preparationRequested = value;
    [self updateInstallationActivity];
}
- (void)setInstallationRequested:(BOOL)value {
    _installationRequested = value;
    [self updateInstallationActivity];
}
- (void)setCompletionGuestReport:(NSDictionary *)value {
    _completionGuestReport = value;
    [self updateInstallationActivity];
}
- (instancetype)initWithWindow:(NSWindow *)window {
    if ((self = [super initWithWindow:window])) {
        _machineLock = -1;
        _state = [VIMGuestSessionState new];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(refreshUSBToolbar:)
                                                   name:@"VIMHostUSBChanged"
                                                 object:nil];
        VIMStartHostUSBNotifications();
    }
    return self;
}
+ (void)showMachineWindow:(VIMMachine *)machine {
    NSAssert(NSThread.isMainThread, @"Session UI is main-thread owned");
    if (!sessions)
        sessions = [NSMutableDictionary dictionary];
    NSString *key = SessionKey(machine);
    VIMSession *session = sessions[key];
    if (!session) {
        session = [[self alloc] initWithWindow:nil];
        session.machine = machine;
        sessions[key] = session;
        [session showStoppedScreen];
    } else if (!session.task.running) {
        session.machine = machine;
        [session showStoppedScreen];
    }
    [session showWindow:nil];
    [session.window makeKeyAndOrderFront:nil];
}
- (void)ensureWindow {
    [self refreshAudioChoices];
    BOOL created = self.window == nil;
    if (created)
        self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 740)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.windowController = self;
    self.window.title = self.machine.name;
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    [self.window setFrameAutosaveName:[@"Guest-" stringByAppendingString:(self.machine.configuration[@"Identifier"]
                                                                              ?: self.machine.name)]];
    self.window.minSize = NSMakeSize(640, 440);
    self.window.acceptsMouseMovedEvents = YES;
    if (created) {
        BOOL restored = [self.window setFrameUsingName:self.window.frameAutosaveName];
        NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
        NSRect available = NSInsetRect(screen.visibleFrame, 24, 24);
        CGFloat chrome = NSHeight(self.window.frame) - NSHeight(self.window.contentView.frame);
        NSSize content = self.window.contentView.bounds.size;
        if (!restored) {
            // Standard logical desktop sizes, fitted to usable space (not the
            // physical panel pixels). Leave host Dock/menu bar and room around
            // the window visible. Saved user sizes still take precedence.
            NSSize chosen = VIMDefaultGuestContentSize(screen.visibleFrame.size, chrome);
            [self.window setContentSize:chosen];
            [self.window center];
        } else if (NSWidth(self.window.frame) > NSWidth(available) ||
                   NSHeight(self.window.frame) > NSHeight(available)) {
            CGFloat fit = MIN(NSWidth(available) / MAX(1, content.width),
                              (NSHeight(available) - chrome) / MAX(1, content.height));
            [self.window setContentSize:NSMakeSize(floor(content.width * fit), floor(content.height * fit))];
        }
        // A saved frame from a larger/disconnected monitor must remain usable.
        [self.window setFrame:[self.window constrainFrameRect:self.window.frame toScreen:screen] display:NO];
    }
}
- (void)installWindowControls:(BOOL)running {
    while (self.window.titlebarAccessoryViewControllers.count)
        [self.window removeTitlebarAccessoryViewControllerAtIndex:0];
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:running ? @"GuestRunning" : @"GuestStopped"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    toolbar.allowsUserCustomization = NO;
    self.window.toolbar = toolbar;
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    // SDL device selection is currently next-start only. Keep it in Sound
    // settings, not among controls that imply a live device change.
    return @[
        NSToolbarFlexibleSpaceItemIdentifier, @"GuestApps", @"GuestCPU", @"GuestUSB", @"GuestOptical", @"GuestNetwork",
        @"GuestSharing", @"GuestControls", @"GuestSettings"
    ];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarDefaultItemIdentifiers:toolbar];
}
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
        itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
    willBeInsertedIntoToolbar:(BOOL)insert {
    NSDictionary *devices = @{
        @"GuestApps" : @[ @"Download Apps…", @"appstore", @"downloadApps:" ],
        @"GuestCPU" : @[ @"CPU & Memory", @"cpu", @"showCPUSettings:" ],
        @"GuestSharing" : @[ @"Shared Folders", @"folder", @"showSharingSettings:" ]
    };
    NSArray *device = devices[identifier];
    if (device) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = device[0];
        item.toolTip = device[0];
        item.image = [identifier isEqual:@"GuestApps"]
                         ? VIMAppsSymbolImage()
                         : [NSImage imageWithSystemSymbolName:device[1] accessibilityDescription:device[0]];
        item.target = self;
        item.action = NSSelectorFromString(device[2]);
        return item;
    }
    if ([identifier isEqual:@"GuestOptical"]) {
        NSMenuToolbarItem *item = [[NSMenuToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"CD/DVD";
        item.toolTip = @"CD/DVD";
        item.image = [NSImage imageWithSystemSymbolName:@"opticaldisc" accessibilityDescription:nil];
        item.showsIndicator = NO;
        item.menu = WithToolbarMenuTitle([self deviceMenuForKind:@"CD/DVD"], @"CD/DVD");
        return item;
    }
    if ([identifier isEqual:@"GuestNetwork"] || [identifier isEqual:@"GuestAudio"]) {
        BOOL network = [identifier isEqual:@"GuestNetwork"];
        NSMenuToolbarItem *item = [[NSMenuToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = network ? @"Network" : @"Sound";
        item.toolTip = item.label;
        item.showsIndicator = NO;
        item.image = [NSImage imageWithSystemSymbolName:network ? @"network" : @"speaker.wave.2"
                               accessibilityDescription:nil];
        item.menu = WithToolbarMenuTitle([self deviceMenuForKind:network ? @"Network" : @"Sound Output"], item.label);
        return item;
    }
    if ([identifier isEqual:@"GuestUSB"]) {
        NSMenuToolbarItem *item = [[NSMenuToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"USB";
        item.toolTip = @"Connect USB devices to this Mac";
        item.showsIndicator = NO;
        item.image = [NSImage imageWithSystemSymbolName:@"cable.connector" accessibilityDescription:nil];
        item.menu = WithToolbarMenuTitle([self deviceMenuForKind:@"USB"], @"USB");
        return item;
    }
    if ([identifier isEqual:@"GuestControls"]) {
        NSMenuToolbarItem *controls = [[NSMenuToolbarItem alloc] initWithItemIdentifier:identifier];
        controls.label = @"Controls";
        controls.toolTip = @"Control this Mac";
        controls.showsIndicator = NO;
        controls.image = [NSImage imageWithSystemSymbolName:@"power" accessibilityDescription:nil];
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Controls"];
        NSArray *titles = @[ @"Shut Down", @"Reset…", @"Force Stop…" ];
        NSArray *actions = @[
            NSStringFromSelector(@selector(shutdown:)), NSStringFromSelector(@selector(resetMachine:)),
            NSStringFromSelector(@selector(forceStop:))
        ];
        for (NSUInteger i = 0; i < titles.count; i++) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:titles[i]
                                                          action:NSSelectorFromString(actions[i])
                                                   keyEquivalent:@""];
            item.target = self;
            [menu addItem:item];
        }
        menu.delegate = self;
        controls.menu = menu;
        return controls;
    }
    NSToolbarItem *gear = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    gear.label = @"Configure";
    gear.toolTip = @"Configure this Mac";
    gear.image = [NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:nil];
    gear.target = self;
    gear.action = @selector(configureMachine:);
    return gear;
}
- (void)showStoppedScreen {
    [self ensureWindow];
    [self installWindowControls:NO];
    self.window.subtitle = @"";
    self.displayMode = VIMDisplayMode(self.machine.editableConfiguration);
    self.retinaEnabled = ![self.displayMode isEqual:@"scaled"];
    VIMStoppedMacView *content = [[VIMStoppedMacView alloc] initWithGuest:self.machine.guest
                                                                     name:self.machine.name
                                                                   target:self
                                                                   action:@selector(startAgain:)];
    self.window.contentView = content;
    self.window.minSize = NSMakeSize(440, 320);
    self.window.maxSize = NSMakeSize(100000, 100000);
    [self.window makeFirstResponder:content.playButton];
}
+ (BOOL)openMachine:(VIMMachine *)machine error:(NSError **)error {
    return [self requestMachine:machine operation:VIMBootStart error:error];
}
+ (BOOL)prepareMachine:(VIMMachine *)machine error:(NSError **)error {
    return [self requestMachine:machine operation:VIMBootPrepare error:error];
}
+ (BOOL)installMachine:(VIMMachine *)machine error:(NSError **)error {
    return [self requestMachine:machine operation:VIMBootInstall error:error];
}
+ (BOOL)repairMachine:(VIMMachine *)machine error:(NSError **)error {
    return [self requestMachine:machine operation:VIMBootRepair error:error];
}
+ (BOOL)performBootOperation:(VIMBootOperation)operation machine:(VIMMachine *)machine error:(NSError **)error {
    switch (operation) {
        case VIMBootStart:
            return [self openMachineAfterHostCheck:machine error:error];
        case VIMBootPrepare:
            return [self prepareMachineAfterHostCheck:machine error:error];
        case VIMBootInstall:
            return [self installMachineAfterHostCheck:machine error:error];
        case VIMBootRepair:
            return [self repairMachineAfterHostCheck:machine error:error];
    }
    return NO;
}
+ (BOOL)requestMachine:(VIMMachine *)machine operation:(VIMBootOperation)operation error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Session UI is main-thread owned");
#if defined(__arm64__)
    // These guests use the native host PassthroughOpenGL executor, not the
    // Intel PVG helper. Their TCG CPU does not require Rosetta to be installed.
    if (machine.preMetalGuest)
        return [self performBootOperation:operation machine:machine error:error];
    NSString *key = SessionKey(machine);
    // Focusing an already running VM is not a new boot. Every actual start,
    // including installer VGA and automatic restarts, must pass a fresh probe.
    VIMSession *existing = sessions[key];
    if (existing.task.running || existing.networkStarting)
        return [self performBootOperation:operation machine:machine error:error];
    if (pendingRosettaStarts[key])
        return YES;
    if (!pendingRosettaStarts)
        pendingRosettaStarts = [NSMutableDictionary new];
    NSUUID *request = NSUUID.UUID;
    pendingRosettaStarts[key] = request;
    VIMCheckRosettaForBoot(^(BOOL missing, NSError *failure) {
      if (![pendingRosettaStarts[key] isEqual:request])
          return; // quit/stop cancelled it
      [pendingRosettaStarts removeObjectForKey:key];
      NSWindow *window = sessions[key].window ?: NSApp.mainWindow;
      if (failure) {
          VIMPresentError(failure, window);
          return;
      }
      if (missing) {
          VIMPresentRosettaRequiredAlert(window);
          return;
      }
      // No disk lock, network helper, QEMU process or install transaction is
      // touched until actual Intel execution succeeds. Never retry after an
      // alert: the user starts again after completing Apple's installation.
      if (![self performBootOperation:operation machine:machine error:&failure])
          VIMPresentError(failure, window);
    });
    return YES; // asynchronous start request accepted, not a running-VM claim
#else
    return [self performBootOperation:operation machine:machine error:error];
#endif
}
+ (BOOL)openMachineAfterHostCheck:(VIMMachine *)machine error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Session UI is main-thread owned");
    if (![machine applyPendingChanges:error])
        return NO;
    machine = [VIMMachine loadURL:machine.URL error:error];
    if (!machine)
        return NO;
    NSString *notice = VIMHostUpdateNotice(NSProcessInfo.processInfo.operatingSystemVersion);
    if (notice) {
        if (error)
            *error = VIMSessionError(notice);
        return NO;
    }
    if (!sessions)
        sessions = [NSMutableDictionary dictionary];
    NSString *key = SessionKey(machine);
    VIMSession *existing = sessions[key];
    if (existing.task.running || existing.networkStarting) {
        [existing showWindow:nil];
        [existing.window makeKeyAndOrderFront:nil];
        return YES;
    }
    NSError *cleanupError = nil;
    [machine retryInstallerCleanup:&cleanupError];
    // Cleanup may have retired routing even when deletion failed. Reload before
    // constructing arguments so a stale library model cannot remount the ISO.
    machine = [VIMMachine loadURL:machine.URL error:error];
    if (!machine)
        return NO;
    // Each boot owns fresh asynchronous transports; only the native window is
    // transferred, so callbacks from an old boot cannot mutate the new one.
    VIMSession *session = [[self alloc] initWithWindow:existing.window];
    session.machine = machine;
    if (![VIMNetworkMode(machine.configuration) isEqual:@"shared"]) {
        session.networkClient = [VIMNetworkClient new];
        session.networkStarting = YES;
        if (existing)
            existing.window = nil;
        sessions[key] = session;
        [session showStoppedScreen];
        NSString *bridge = machine.configuration[@"BridgeInterface"];
        if (!bridge.length)
            bridge = VIMNetworkDefaultBridge() ?: @"";
        [session.networkClient startMode:VIMNetworkMode(machine.configuration)
                                  bridge:bridge
                              completion:^(NSError *failure) {
                                if (!session.networkStarting)
                                    return;
                                session.networkStarting = NO;
                                if (!failure && [session launch:&failure]) {
                                    [session continueFromSession:existing];
                                    [session recordOpened:cleanupError];
                                    return;
                                }
                                [session cleanUp];
                                [session showStoppedScreen];
                                if (failure)
                                    VIMPresentError(failure, session.window);
                              }];
        return YES;
    }
    if (![session launch:error]) {
        if (existing)
            [session showStoppedScreen];
        return NO;
    }
    [session continueFromSession:existing];
    if (existing) {
        existing.window = nil;
        session.window.windowController = session;
        session.window.delegate = session;
    }
    sessions[key] = session;
    [session recordOpened:cleanupError];
    return YES;
}
/// A relaunch can get here after a Rosetta check, once the old session's exit handler has moved on, so what the new
/// session needs waits on the old one until it has started.
- (void)continueFromSession:(VIMSession *)previous {
    self.recentGuestReboots = previous.recentGuestReboots;
    self.pendingHostConnectionURL = previous.pendingHostConnectionURL;
    self.pendingHostConnectionCompletion = previous.pendingHostConnectionCompletion;
    previous.pendingHostConnectionURL = nil;
    previous.pendingHostConnectionCompletion = nil;
}
/// A session has started, whichever way it got there.
- (void)recordOpened:(NSError *)cleanupError {
    if (cleanupError) {
        self.guestStatus.stringValue =
            [NSString stringWithFormat:@"Installer cleanup pending: %@", cleanupError.localizedDescription];
        [self logNote:@"Cleanup retry: %@", cleanupError.localizedDescription];
    }
    NSMutableDictionary *opened = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"VIMLastOpened"] mutableCopy]
                                      ?: [NSMutableDictionary dictionary];
    opened[SessionKey(self.machine)] = NSDate.date;
    [NSUserDefaults.standardUserDefaults setObject:opened forKey:@"VIMLastOpened"];
    [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
}
+ (BOOL)hasRunningMachines {
    for (VIMSession *session in sessions.allValues)
        if (session.task.running || session.networkStarting)
            return YES;
    return NO;
}
+ (BOOL)isRunningMachine:(VIMMachine *)machine {
    return sessions[SessionKey(machine)].task.running;
}
+ (void)enableGuestRemoteLogin:(VIMMachine *)machine completion:(void (^)(NSError *))completion {
    VIMSession *session = sessions[SessionKey(machine)];
    if (!session.guestSessionState.mayRunGuestAction) {
        completion(VIMSessionError(@"Start this Mac and wait for setup to finish, then try again. You can also enable "
                                   @"Remote Login in the virtual Mac’s Sharing preferences."));
        return;
    }
    session.state.guestPending = YES;
    void (^finish)(NSError *) = ^(NSError *error) {
      session.state.guestPending = NO;
      // The one-shot readiness timer may have fired while this user action
      // owned the agent. Resume the production loop, including verification.
      [session refreshGuestStatus];
      completion(error);
    };
    [session.guestAgent enableRemoteLoginWithCompletion:finish];
}
+ (NSString *)statusForMachine:(VIMMachine *)machine {
    VIMSession *session = sessions[SessionKey(machine)];
    BOOL installing = machine.preMetalGuest
                          ? ![machine.configuration[@"InstallState"] ?: @"installed" isEqual:@"installed"]
                          : machine.requiresInstallerDisplay;
    return [VIMSessionRunState statusForRunning:session.task.running
                                       runState:session.lastRunState
                                     installing:installing];
}
+ (void)openGuestPreferences:(NSString *)pane machine:(VIMMachine *)machine completion:(void (^)(NSError *))completion {
    VIMSession *session = sessions[SessionKey(machine)];
    if (!session.guestSessionState.mayRunGuestAction) {
        completion(VIMSessionError(@"Start this Mac, sign in and wait for setup to finish, then try again. You can "
                                   @"also open System Preferences inside the virtual Mac."));
        return;
    }
    session.state.guestPending = YES;
    void (^finish)(NSError *) = ^(NSError *error) {
      session.state.guestPending = NO;
      [session refreshGuestStatus];
      completion(error);
    };
    [session.guestAgent connectWithCompletion:^(NSError *error) {
      if (error) {
          finish(error);
          return;
      }
      [session.guestAgent openPreferencesPane:pane completion:finish];
    }];
}
+ (void)openHostConnection:(NSURL *)URL inMachine:(VIMMachine *)machine completion:(void (^)(NSError *))completion {
    VIMSession *session = sessions[SessionKey(machine)];
    if (!session.task.running) {
        completion(VIMSessionError(@"Start the virtual Mac and sign in to its desktop, then try again."));
        return;
    }
    NSString *host = [self networkDetailsForMachine:machine][@"HostAddress"];
    if (!host.length || ![URL.host isEqual:host]) {
        completion(
            VIMSessionError(@"This Mac’s network address changed. Reopen File Sharing or Remote Login and try again."));
        return;
    }
    if (session.pendingHostConnectionURL) {
        completion(VIMSessionError(@"A connection is already waiting to open in this virtual Mac."));
        return;
    }
    session.pendingHostConnectionURL = URL;
    session.pendingHostConnectionCompletion = completion;
    [session servicePendingHostConnection];
}
- (void)servicePendingHostConnection {
    if (!self.pendingHostConnectionURL || !self.guestAgentFree)
        return;
    NSURL *URL = self.pendingHostConnectionURL;
    void (^completion)(NSError *) = self.pendingHostConnectionCompletion;
    self.pendingHostConnectionURL = nil;
    self.pendingHostConnectionCompletion = nil;
    NSString *host = [VIMSession networkDetailsForMachine:self.machine][@"HostAddress"];
    if (!host.length || ![URL.host isEqual:host]) {
        completion(
            VIMSessionError(@"This Mac’s network address changed. Reopen File Sharing or Remote Login and try again."));
        return;
    }
    self.state.guestPending = YES;
    void (^finish)(NSError *) = ^(NSError *error) {
      self.state.guestPending = NO;
      [self refreshGuestStatus];
      completion(error);
    };
    [self.guestAgent connectWithCompletion:^(NSError *error) {
      if (error) {
          finish(error);
          return;
      }
      [self.guestAgent openHostConnection:URL completion:finish];
    }];
}
+ (BOOL)prepareMachineAfterHostCheck:(VIMMachine *)machine error:(NSError **)error {
    if (!VIMGuestHasTrait(machine.guest, VIMGuestTraitParavirtualizedGraphics)) {
        if (error)
            *error = VIMSessionError(@"Guest preparation supports Mojave, Catalina and Big Sur.");
        return NO;
    }
    if (![self openMachineAfterHostCheck:machine error:error])
        return NO;
    VIMSession *session = sessions[SessionKey(machine)];
    if (session.preparing || session.preparationRequested) {
        if (error)
            *error = VIMSessionError(@"Guest preparation is already active.");
        return NO;
    }
    session.preparationRequested = YES;
    [session refreshGuestStatus];
    return YES;
}
+ (void)stopAll {
    [pendingRosettaStarts removeAllObjects];
    for (VIMSession *session in sessions.allValues) {
        if (session.networkStarting) {
            [session cleanUp];
            [session showStoppedScreen];
        }
        if (session.task.running) {
            [session applyLifecycleEvent:VIMSessionEventForceStopRequested];
            [session.task terminate];
        }
    }
}
+ (NSArray<NSString *> *)runningMachineNames {
    NSMutableArray *names = [NSMutableArray array];
    for (VIMSession *session in sessions.allValues)
        if (session.task.running)
            [names addObject:session.machine.name];
    return names;
}
+ (void)requestShutdownAll {
    [pendingRosettaStarts removeAllObjects];
    for (VIMSession *session in sessions.allValues)
        if (session.networkStarting) {
            [session cleanUp];
            [session showStoppedScreen];
        }
    for (VIMSession *session in sessions.allValues)
        if (session.guestSessionState.mayShutDownForQuit)
            [session shutdown:self];
}
+ (BOOL)installMachineAfterHostCheck:(VIMMachine *)machine error:(NSError **)error {
    if (machine.preMetalGuest) {
        // The native installer/bootstrap coordinator is created by launch.
        // Do not send these guests through the newer PVG preparation agent.
        if ([machine.configuration[@"InstallState"] isEqual:@"installed"]) {
            if (error)
                *error = VIMSessionError(
                    @"This Mac is already installed. Start it to check and repair its graphics support automatically.");
            return NO;
        }
        return [self openMachineAfterHostCheck:machine error:error];
    }
    NSURL *journal = [machine.URL URLByAppendingPathComponent:@"State/GuestInstallation.plist"];
    if ([NSFileManager.defaultManager fileExistsAtPath:journal.path]) {
        if (error)
            *error = VIMSessionError(@"An installation record already exists. Check its saved outcome before starting "
                                     @"another installation.");
        return NO;
    }
    if (![self prepareMachineAfterHostCheck:machine error:error])
        return NO;
    sessions[SessionKey(machine)].installationRequested = YES;
    return YES;
}
+ (BOOL)repairMachineAfterHostCheck:(VIMMachine *)machine error:(NSError **)error {
    if (!VIMGuestHasTrait(machine.guest, VIMGuestTraitParavirtualizedGraphics)) {
        if (error)
            *error = VIMSessionError(@"Repair supports Mojave, Catalina and Big Sur.");
        return NO;
    }
    if (![self openMachineAfterHostCheck:machine error:error])
        return NO;
    VIMSession *session = sessions[SessionKey(machine)];
    if (session.preparing || session.preparationRequested || session.state.repairRequested) {
        if (error)
            *error = VIMSessionError(@"Guest setup is already active.");
        return NO;
    }
    session.state.repairRequested = YES;
    session.state.explicitRepair = YES;
    [session refreshGuestStatus];
    return YES;
}
- (BOOL)launch:(NSError **)error {
    NSString *installer = self.machine.configuration[@"InstallerMedia"];
    if (installer.length) {
        NSURL *URL = [self.machine.configuration[@"InstallerMediaShared"] boolValue]
                         ? [NSURL fileURLWithPath:installer]
                         : [self.machine.URL URLByAppendingPathComponent:installer];
        if (![VIMInstallerAssembly validatePreparedMedia:URL guest:self.machine.guest error:error])
            return NO;
    }
    // Development root is an explicit debug preference, never an implicit
    // dependency on a developer's checkout in the shipping app.
    NSString *root = VIMDevelopmentSourceRoot();
#if defined(__arm64__)
    BOOL appleSilicon = YES;
#else
    BOOL appleSilicon = NO;
    int translated = 0;
    size_t translatedSize = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &translatedSize, NULL, 0) == 0 && translated) {
        if (error)
            *error = VIMSessionError(@"Open the Apple silicon version of Light Click. The Intel app cannot use "
                                     @"hardware virtualization through Rosetta.");
        return NO;
    }
#endif
    // Explicit development qualification of recovery/update environments that
    // do not contain the installed system's graphics support. This never edits
    // the VM receipt or discards its verified graphics transaction.
    BOOL installerDisplay = self.machine.requiresInstallerDisplay ||
                            [NSProcessInfo.processInfo.arguments containsObject:@"--installer-display"];
    BOOL openGLDirectDisplay = self.machine.preMetalGuest &&
                               [self.machine.configuration[@"LegacyDisplayAdapter"] isEqual:@"vmware"] &&
                               self.machine.passthroughOpenGLEnabled;
    // A VMware adapter alone does not establish hardware cursor delivery.
    // Recovery can use that adapter for its framebuffer while drawing its
    // pointer into the scanout. The installed graphics path reports a glyph.
    self.displayView.softwareCursor = installerDisplay && !openGLDirectDisplay;
    NSString *qemu =
        [root stringByAppendingPathComponent:installerDisplay ? @"artifacts/host-arm64/qemu-arm64-app-installer"
                                                              : @"artifacts/host-arm64/qemu-arm64-alternate-lookup-v2"];
    NSString *helper = [root stringByAppendingPathComponent:@"artifacts/host-arm64/apple-gfx-helper-app"];
    NSString *donor =
        [root stringByAppendingPathComponent:@"artifacts/host-arm64/donor-v2/Out/System/Library/Frameworks/"
                                             @"ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics"];
    NSString *bios = [root stringByAppendingPathComponent:@"vendor/qemu/pc-bios"];
    NSString *llvm =
        [root stringByAppendingPathComponent:@"artifacts/mojave/reference/payload/System/Library/PrivateFrameworks/"
                                             @"GPUCompiler.framework/Versions/31001/Libraries/libLLVM.dylib"];
    if (!appleSilicon) {
        qemu = [root stringByAppendingPathComponent:@"artifacts/host-intel/qemu-system-x86_64-app"];
        helper = [root stringByAppendingPathComponent:@"artifacts/host-intel/apple-gfx-helper-app"];
    }
    if (!root.length) {
        NSString *runtime = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Runtime"];
        qemu = [runtime stringByAppendingPathComponent:@"bin/qemu-system-x86_64"];
        helper = [runtime stringByAppendingPathComponent:@"bin/apple-gfx-helper"];
        donor = [runtime stringByAppendingPathComponent:
                             @"Donor/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics"];
        bios = [runtime stringByAppendingPathComponent:@"pc-bios"];
        llvm = [runtime stringByAppendingPathComponent:@"Donor/libLLVM.dylib"];
    }
    // macOS 27 removed the Intel guest protocol from system PVG. Earlier
    // systems load their system Intel slice normally (in the helper on ARM).
    BOOL extractedDonor = appleSilicon && NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
    if (!extractedDonor)
        donor = @"/System/Library/Frameworks/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics";
    BOOL mojave = [self.machine.guest isEqual:@"mojave"];
    // System frameworks can live only in the dyld cache; dlopen in the helper
    // is authoritative for that path, not fileExistsAtPath.
    NSArray *required =
        installerDisplay ? @[ qemu, bios ]
                         : (appleSilicon ? (extractedDonor ? @[ qemu, helper, donor, bios ] : @[ qemu, helper, bios ])
                                         : @[ qemu, bios ]);
    for (NSString *path in required)
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            if (error)
                *error = VIMSessionError([@"Missing runtime resource: " stringByAppendingString:path]);
            return NO;
        }
    if (appleSilicon && mojave && !installerDisplay && ![NSFileManager.defaultManager fileExistsAtPath:llvm]) {
        if (error)
            *error = VIMSessionError(@"The Mojave shader compiler repair resource is missing.");
        return NO;
    }
    NSURL *lockURL = [self.machine.URL URLByAppendingPathComponent:@"State/Session.lock"];
    self.machineLock = [VIMLaunchMedia acquireSessionLockAtPath:lockURL.path];
    if (self.machineLock < 0) {
        if (error)
            *error = VIMSessionError(@"This Mac is already in use, or its session lock could not be opened. Close its "
                                     @"other session before starting it here.");
        return NO;
    }
    char directory[] = "/tmp/vim-session.XXXXXX";
    if (!mkdtemp(directory)) {
        close(self.machineLock);
        self.machineLock = -1;
        if (error)
            *error = VIMSessionError(@"Could not create the VM session directory.");
        return NO;
    }
    self.runtimeDirectory = @(directory);
    [self ensureWindow];
    self.window.title = self.machine.name;
    self.window.contentView = [NSView new];
    NSView *content = self.window.contentView;
    self.displayView = [[VIMMetalView alloc] initWithFrame:NSZeroRect];
    self.displayView.translatesAutoresizingMaskIntoConstraints = NO;
    self.displayView.nearestNeighborScaling = [self.displayScalingFilter isEqual:@"nearest"];
    self.status = [NSTextField labelWithString:@"Starting…"];
    self.status.textColor = NSColor.secondaryLabelColor;
    self.guestStatus = [NSTextField labelWithString:@"Waiting for macOS…"];
    self.guestStatus.textColor = NSColor.secondaryLabelColor;
    self.guestStatus.lineBreakMode = NSLineBreakByTruncatingTail;
    self.shutdownButton = [NSButton buttonWithTitle:@"Shut Down" target:self action:@selector(shutdown:)];
    self.shutdownButton.enabled = NO;
    // Status labels remain diagnostic models, not permanent guest chrome.
    [content addSubview:self.displayView];
    [NSLayoutConstraint activateConstraints:@[
        [self.displayView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.displayView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.displayView.topAnchor constraintEqualToAnchor:content.topAnchor],
        [self.displayView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]
    ]];
    self.previewSetupNotice = [NSUserDefaults.standardUserDefaults boolForKey:@"VIMDebugShowSetupNotice"];
    self.closedSetupNoticeHeading = nil;
    if (self.previewSetupNotice)
        [self showSetupNoticeAutomatic:YES automaticLogin:YES restarting:NO];
    [self installWindowControls:YES];
    if (installerDisplay) {
        // The unaccelerated framebuffer remains 1280x800. Fit its window in
        // logical points on smaller hosts without changing that guest mode.
        NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
        CGFloat chrome = NSHeight(self.window.frame) - NSHeight(content.frame);
        CGFloat fit = MIN(
            1., MIN((NSWidth(screen.visibleFrame) - 48) / 1280., (NSHeight(screen.visibleFrame) - chrome - 48) / 800.));
        [self.window setContentSize:NSMakeSize(floor(1280 * fit), floor(800 * fit))];
        [self.window center];
    }
    self.stateLabel = [NSTextField wrappingLabelWithString:@""];
    self.stateLabel.textColor = NSColor.whiteColor;
    self.stateLabel.alignment = NSTextAlignmentCenter;
    self.stateAction = [NSButton buttonWithTitle:@"Start" target:self action:@selector(startAgain:)];
    self.statePanel = [NSStackView stackViewWithViews:@[ self.stateLabel, self.stateAction ]];
    self.statePanel.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.statePanel.spacing = 16;
    self.statePanel.hidden = YES;
    self.statePanel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.statePanel];
    [NSLayoutConstraint activateConstraints:@[
        [self.statePanel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [self.statePanel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [self.statePanel.widthAnchor constraintLessThanOrEqualToConstant:400]
    ]];
    __weak VIMSession *weakSelf = self;
    self.displayConnection = [[VIMDisplayConnection alloc] initWithView:self.displayView
                                                                failure:^(NSError *failure) {
                                                                  VIMSession *session = weakSelf;
                                                                  if (session.task.running)
                                                                      session.status.stringValue =
                                                                          failure.localizedDescription;
                                                                }
                                                                  error:error];
    if (!self.displayConnection) {
        [self cleanUp];
        return NO;
    }
    // External renderer: authenticate its exact PID before launch.
    // In-process OpenGL instead authenticates the spawned QEMU below,
    // while the guest remains paused. No arbitrary first-peer authentication.
    NSString *rendererPID = NSProcessInfo.processInfo.environment[@"VIM_OPENGL_RENDERER_PID"];
    NSString *inprocessLibrary = NSProcessInfo.processInfo.environment[@"VIM_PASSTHROUGH_OPENGL_INPROCESS_LIBRARY"];
    if (openGLDirectDisplay && !inprocessLibrary && !rendererPID.length) {
        NSString *bundled = [NSBundle.mainBundle.resourcePath
            stringByAppendingPathComponent:@"Runtime/bin/libVIMPassthroughOpenGLHost.dylib"];
        if ([NSFileManager.defaultManager isReadableFileAtPath:bundled])
            inprocessLibrary = bundled;
    }
    BOOL openGLInprocess = openGLDirectDisplay && inprocessLibrary != nil;
    if (openGLInprocess &&
        (!inprocessLibrary.isAbsolutePath || ![NSFileManager.defaultManager isReadableFileAtPath:inprocessLibrary])) {
        if (error)
            *error = VIMSessionError(@"The OpenGL graphics library is missing or unreadable.");
        [self cleanUp];
        return NO;
    }
    if (openGLDirectDisplay && !openGLInprocess && rendererPID.length) {
        int pid = 0;
        NSScanner *scanner = [NSScanner scannerWithString:rendererPID];
        NSError *surfaceError = nil;
        if (![scanner scanInt:&pid] || !scanner.isAtEnd || pid <= 0 ||
            !VIMPrepareOpenGLSurfaceEndpoint(self.displayConnection, pid, self.runtimeDirectory, &surfaceError)) {
            if (error)
                *error = surfaceError ?: VIMSessionError(@"The OpenGL renderer could not be connected.");
            [self cleanUp];
            return NO;
        }
    }
    self.displayMode = installerDisplay ? @"scaled" : VIMDisplayMode(self.machine.configuration);
    self.retinaEnabled = ![self.displayMode isEqual:@"scaled"];
    [content layoutSubtreeIfNeeded];
    CGFloat initialScale =
        [self.displayMode isEqual:@"retina"] ? 2 : (self.retinaEnabled ? self.window.backingScaleFactor : 1);
    NSSize initialPixels =
        VIMRequestedGuestPixelSize(self.displayView.bounds.size, initialScale, self.machine.preMetalGuest,
                                   [self.displayMode isEqual:@"retina"], NO);
    // Queue before connection: both in-process PVG and the Rosetta helper
    // receive the window size as soon as their private display channel opens.
    if (!installerDisplay)
        [self.displayConnection
            requestWidth:initialPixels.width
                  height:initialPixels.height
                 density:self.machine.preMetalGuest ? ([self.displayMode isEqual:@"retina"] ? 2 : 1) : 0];
    NSString *qmp = [self.runtimeDirectory stringByAppendingPathComponent:@"control"];
    self.control = [[VIMQMPConnection alloc] initWithSocketPath:qmp];
    __weak VIMSession *eventSession = self;
    self.control.lifecycleEventHandler = ^(NSDictionary *event) {
      VIMSession *session = eventSession;
      if (!session)
          return;
      VIMQMPEvent *qmp = [[VIMQMPEvent alloc] initWithEvent:event];
      switch (qmp.kind) {
          case VIMQMPEventKindDeviceDeleted:
              [session.usbClient deviceWasDeleted:event[@"data"][@"device"] control:session.control];
              [session.imageDrives deviceDeleted:qmp.device];
              break;
          case VIMQMPEventKindReset:
              session.guestIPAddresses = nil;
              session.displayToolDirectory = nil;
              session.displayView.displaySleeping = YES;
              session.displayView.displaySleeping = NO;
              break;
          case VIMQMPEventKindSuspend:
          case VIMQMPEventKindShutdown:
              if (qmp.expectsGuestReboot)
                  [session applyLifecycleEvent:VIMSessionEventGuestRebootExpected];
              session.displayView.displaySleeping = YES;
              session.statePanel.hidden = YES;
              if (qmp.kind == VIMQMPEventKindSuspend) {
                  session.lastRunState = @"suspended";
                  session.status.stringValue = @"Sleeping";
              }
              break;
          case VIMQMPEventKindWakeup:
              session.lastRunState = @"running";
              session.displayView.displaySleeping = NO;
              session.statePanel.hidden = YES;
              session.status.stringValue = @"Running";
              break;
          case VIMQMPEventKindTrayOpened: {
              NSDictionary *removed = [session.imageDrives trayOpenedOnDevice:qmp.device];
              NSDictionary *settings = VIMImageClearedSelections(session.machine.editableConfiguration, removed);
              NSError *failure = nil;
              if (settings.count && ![session.machine saveSettings:settings error:&failure])
                  VIMPresentError(failure, session.window);
              if (settings.count)
                  [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
              break;
          }
          case VIMQMPEventKindOther:
              break;
      }
      NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
      NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
      [session logNote:@"Lifecycle: %@", line];
    };
    self.guestAgent = [[VIMGuestAgent alloc]
        initWithSocketPath:[self.runtimeDirectory stringByAppendingPathComponent:@"guest-agent"]];
    if ([@[ @"mojave", @"catalina" ] containsObject:self.machine.guest])
        self.guestAgent.recoverySocketPath = [self.runtimeDirectory stringByAppendingPathComponent:@"recovery-agent"];
    self.state.openGLDesktopMonitoring = NO;
    self.openGLSetupMediaAttached = NO;
    self.openGLLargeResizeReady = NO;
    self.mavericksSMBCheckedBoot = nil;
    self.guestAgent.preMetalGuest = self.machine.preMetalGuest;
    self.guestAgent.tigerGuest = [self.machine.guest isEqual:@"tiger"];
    if (self.machine.preMetalGuest)
        self.guestAgent.processPollInterval = 1;
    if (self.machine.preMetalGuest) {
        self.openGLSetup = [[VIMOpenGLSetup alloc] initWithMachine:self.machine
                                                             agent:self.guestAgent
                                                           control:self.control];
        self.openGLSetup.showProgress = ^(BOOL automatic, BOOL automaticLogin) {
          VIMSession *session = weakSelf;
          if (session.task.running && !session.state.shutdownRequested)
              [session showSetupNoticeAutomatic:automatic automaticLogin:automaticLogin restarting:NO];
        };
    } else {
        self.modernSetup = [[VIMModernSetup alloc] initWithMachine:self.machine agent:self.guestAgent];
        self.modernSetup.progress = ^(NSString *message) {
          weakSelf.guestStatus.stringValue = message;
        };
        self.modernSetup.showAccountProgress = ^(BOOL automaticLogin) {
          VIMSession *session = weakSelf;
          // Retries after a failure stay quiet: the notice would otherwise flash on every one.
          if (!session.task.running || session.state.shutdownRequested || session.state.presentedSetupFailures.count)
              return;
          [session showSetupNoticeAutomatic:YES automaticLogin:automaticLogin restarting:NO];
        };
    }
    self.state.developmentSetupDeferred =
        [NSProcessInfo.processInfo.arguments containsObject:@"--development-defer-guest-setup"];
    NSString *statusTool =
        self.guestAgent.tigerGuest ? VIMGuestFileURL(@"OpenGLGuests/tiger/opengl-desktop-status").path
        : self.machine.preMetalGuest
            ? VIMGuestFileURL([NSString stringWithFormat:@"OpenGLGuests/%@/opengl-desktop-status", self.machine.guest])
                  .path
        : root.length ? [root stringByAppendingPathComponent:@"prebuilt/tools/guest-status"]
                      : VIMGuestFileURL(@"GuestTools/guest-status").path;
    self.guestStatusTool = [NSData dataWithContentsOfFile:statusTool];
    NSDictionary *config = self.machine.configuration;
    [self applyLifecycleEvent:VIMSessionEventLaunchStarted];
    BOOL classicInstaller = self.machine.preMetalGuest && [config[@"InstallerMedia"] length] > 0 &&
                            [config[@"InstallState"] isEqual:@"installing"];
    self.displayMode =
        (installerDisplay && !openGLDirectDisplay) || classicInstaller ? @"scaled" : VIMDisplayMode(config);
    if (openGLDirectDisplay && self.supportsRetinaDisplay && !config[@"DisplayMode"] && !config[@"RetinaEnabled"] &&
        self.window.backingScaleFactor <= 1)
        self.displayMode = @"scaled";
    self.retinaEnabled = ![self.displayMode isEqual:@"scaled"];
    self.observedDisplayMode = nil;
    self.state.networkLinkConnected = !config[@"NetworkConnected"] || [config[@"NetworkConnected"] boolValue];
    NSArray *launchArguments = NSProcessInfo.processInfo.arguments;
    VIMLaunchOptions *options = [[VIMLaunchOptions alloc] initWithArguments:launchArguments
                                                               appleSilicon:appleSilicon
                                                              researchGuest:self.machine.openGLResearchGuest
                                                                      error:error];
    if (!options) {
        [self cleanUp];
        return NO;
    }
    BOOL packageResearchFirmware =
        self.machine.openGLResearchGuest && ![config[@"FirmwareSource"] isEqual:@"application"];
    // Old research guests retain their own known-compatible OpenCore and CODE
    // files. Never apply the supported guests' EFI boot policy or root patches.
    NSString *efiOverride =
        options.guestEFI
            ?: (packageResearchFirmware ? [self.machine.URL.path stringByAppendingPathComponent:config[@"BootMedia"]]
                                        : nil);
    VIMLaunchFirmware *firmware = [[VIMLaunchFirmware alloc]
        initWithDirectory:root.length
                              ? [root stringByAppendingPathComponent:@"Build/DevelopmentFirmware"]
                              : [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Runtime/Firmware"]
           guestDirectory:packageResearchFirmware ? @"mojave" : self.machine.guest
                bootMedia:efiOverride
                    error:error];
    if (!firmware) {
        [self cleanUp];
        return NO;
    }
    BOOL signatureOnly =
        [VIMGuestBootPolicy readyAtURL:[self.machine.URL URLByAppendingPathComponent:@"State/BootPolicy.plist"]
                                 guest:self.machine.guest
                            identifier:config[@"Identifier"]];
    NSString * (^machinePath)(NSString *) = ^NSString *(NSString *key) {
      return [self.machine.URL.path stringByAppendingPathComponent:config[key]];
    };
    self.task = [NSTask new];
    self.task.executableURL = [NSURL fileURLWithPath:qemu];
    // Interactive VM execution is user-initiated work, not a maintenance job.
    // Match UTM's launcher policy; guest realtime audio runs inside ordinary
    // vCPU threads and cannot promote those host threads itself.
    self.task.qualityOfService = NSQualityOfServiceUserInitiated;
    if (self.networkClient.socket)
        self.task.standardInput = self.networkClient.socket;
    NSMutableArray<NSString *> *savedImages = [NSMutableArray new];
    for (NSUInteger slot = 0; slot < VIMImageSlotCount; slot++)
        [savedImages addObject:VIMImageSlotPath(config, slot)];
    VIMLaunchMedia *media = [[VIMLaunchMedia alloc] initWithPaths:savedImages
                                                          inspect:^id(NSString *path) {
                                                            NSError *failure = nil;
                                                            return VIMOpticalImageFormat(path, &failure) ?: failure;
                                                          }];
    if (media.refusal) {
        if (error)
            *error = VIMFriendlyDiscImageError(media.refusedPath, media.refusal);
        [self cleanUp];
        return NO;
    }
    NSDictionary<NSNumber *, NSString *> *unavailableImages = media.unavailable;
    self.imageDrives = [[VIMImageDrives alloc] initWithControl:self.control
                                                           bus:VIMImageUSBBus(self.machine.guest)
                                                      basePort:(NSInteger)VIMImageUSBPort(self.machine.guest, 0)
                                                     slotCount:VIMImageSlotCount];
    self.imageDrives.describeFailure = ^NSError *(NSString *path, NSError *failure) {
      return VIMFriendlyDiscImageError(path, failure);
    };
    NSString *optical = nil, *opticalFormat = nil;
    NSMutableArray<LaunchImage *> *additionalImages = [NSMutableArray new];
    for (VIMLaunchMediaImage *image in media.images) {
        [self.imageDrives startWithImage:image.path format:image.format slot:image.slot];
        if (image.slot) {
            [additionalImages addObject:[[LaunchImage alloc] initWithSlot:image.slot
                                                                     path:image.path
                                                                   format:image.format]];
        } else {
            optical = image.path;
            opticalFormat = image.format;
        }
    }
    NSString *setupMedia = nil;
    if (self.machine.preMetalGuest && config[@"InstallerMedia"]) {
        NSError *setupError = nil;
        NSURL *policy = [VIMAutomaticSetup configurationMediaForMachine:self.machine error:&setupError];
        if (setupError) {
            if (error)
                *error = setupError;
            [self cleanUp];
            return NO;
        }
        self.openGLSetupMediaAttached = policy != nil;
        setupMedia = policy.path;
    }
    NSMutableDictionary<NSNumber *, NSString *> *audioDeviceNames = [NSMutableDictionary new];
    for (NSNumber *input in @[ @NO, @YES ]) {
        NSString *name = [VIMLaunchMedia audioDeviceNameForSelection:VIMAudioSelection(config, input.boolValue)
                                                             devices:^NSArray * {
                                                               return VIMHostAudioDevices(input.boolValue);
                                                             }
                                                               error:error];
        if (!name) {
            [self cleanUp];
            return NO;
        }
        if (name.length)
            audioDeviceNames[input] = name;
    }
    LaunchInput *launch = [LaunchInput new];
    launch.guest = self.machine.guest;
    launch.machineName = self.machine.name;
    launch.machinePath = self.machine.URL.path;
    launch.configuration = config;
    launch.processArguments = launchArguments;
    launch.inheritedEnvironment = NSProcessInfo.processInfo.environment;
    launch.appleSilicon = appleSilicon;
    launch.preMetalGuest = self.machine.preMetalGuest;
    launch.openGLResearchGuest = self.machine.openGLResearchGuest;
    launch.passthroughOpenGLEnabled = self.machine.passthroughOpenGLEnabled;
    launch.installerDisplay = installerDisplay;
    launch.hasPublishedGuestGraphics = self.machine.hasPublishedGuestGraphics;
    launch.bootPolicySignatureOnly = signatureOnly;
    launch.bootMediaOverridden = efiOverride != nil;
    launch.biosPath = bios;
    launch.firmwarePath = packageResearchFirmware ? machinePath(@"Firmware") : firmware.codePath;
    launch.nvramPath = machinePath(@"NVRAM");
    launch.bootMediaPath = firmware.bootMediaPath;
    launch.diskPath = machinePath(@"Disk");
    if (config[@"InstallerMedia"])
        launch.installerPath =
            [config[@"InstallerMediaShared"] boolValue] ? config[@"InstallerMedia"] : machinePath(@"InstallerMedia");
    launch.runtimeDirectory = self.runtimeDirectory;
    launch.qmpPath = qmp;
    launch.helperPath = helper;
    launch.donorPath = donor;
    launch.llvmPath = llvm;
    launch.displaySocketPath = self.displayConnection.socketPath;
    if (openGLInprocess)
        launch.inprocessOpenGLLibrary = inprocessLibrary;
    launch.vramServiceIdentifier = NSUUID.UUID.UUIDString;
    launch.guestWidth = (NSInteger)initialPixels.width;
    launch.guestHeight = (NSInteger)initialPixels.height;
    launch.displayMode = self.displayMode;
    launch.backingScaleFactor = self.window.backingScaleFactor;
    launch.supportsRetinaDisplay = self.supportsRetinaDisplay;
    launch.legacyDisplayRefreshMS = [NSUserDefaults.standardUserDefaults integerForKey:@"VIMLegacyDisplayRefreshMS"];
    launch.networkMode = VIMNetworkMode(config);
    launch.macAddress = VIMNetworkMACAddress(config);
    launch.researchCPUModel = options.researchCPUModel;
    launch.systemDiskInterface = options.systemDiskInterface;
    launch.audioOutputSelection = VIMAudioSelection(config, NO);
    // Opening the microphone blocks QEMU until TCC answers, and a session has no window to ask from.
    // shortcut: a seamless session has no microphone, until QEMU can open it when the guest does.
    BOOL seamless = [NSProcessInfo.processInfo.arguments containsObject:@"--seamless-session"];
    // Without a grant, opening the microphone waits on a TCC answer before the guest can start. Settings asks for it.
    BOOL microphoneAllowed = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] ==
                             AVAuthorizationStatusAuthorized;
    launch.audioInputSelection = seamless || !microphoneAllowed ? @"disabled" : VIMAudioSelection(config, YES);
    launch.audioOutputRate = (NSInteger)VIMHostOutputSampleRate(VIMAudioSelection(config, NO));
    launch.audioInputRate = (NSInteger)VIMHostInputSampleRate(launch.audioInputSelection);
    launch.audioOutputDeviceName = audioDeviceNames[@NO];
    launch.audioInputDeviceName = audioDeviceNames[@YES];
    if (optical.length) {
        launch.opticalPath = optical;
        launch.opticalFormat = opticalFormat;
    }
    launch.additionalImages = additionalImages;
    launch.imageUSBBus = VIMImageUSBBus(self.machine.guest);
    launch.imageUSBBasePort = (NSInteger)VIMImageUSBPort(self.machine.guest, 0);
    launch.setupMediaPath = setupMedia;
    LaunchPlan *plan = [[LaunchPlan alloc] initWithInput:launch];
    if (!plan) {
        if (error)
            *error = VIMSessionError(@"This Mac's configuration could not be read. It was not started.");
        [self cleanUp];
        return NO;
    }
    self.task.arguments = plan.arguments;
    self.task.environment = plan.environment;
    if (![self.machine prepareUpdaterDisplayForBoot:error]) {
        [self cleanUp];
        return NO;
    }
    NSString *logPath = [self.machine.URL.path stringByAppendingPathComponent:@"State/session.log"];
    if (![NSFileManager.defaultManager fileExistsAtPath:logPath])
        [NSFileManager.defaultManager createFileAtPath:logPath contents:nil attributes:nil];
    self.log = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!self.log) {
        if (error)
            *error = VIMSessionError(@"Could not open the VM session log.");
        [self cleanUp];
        return NO;
    }
    [self.log seekToEndOfFile];
    self.task.standardOutput = self.log;
    self.task.standardError = self.log;
    [self logNote:@"Memory ordering: normal runtime barriers"];
    [self logNote:@"%@ runtime: %@", root.length ? @"Development override" : @"Bundled", qemu];
    if (options.researchCPUModel)
        [self logNote:@"Research CPU comparison: %@", options.researchCPUModel];
    if (options.systemDiskInterface)
        [self logNote:@"Development system disk interface: %@", options.systemDiskInterface];
    self.task.terminationHandler = ^(NSTask *task) {
      dispatch_async(dispatch_get_main_queue(), ^{
        VIMSession *session = weakSelf;
        if (!session || session.task != task)
            return;
        [session.control drainLifecycleEventsAfterExitWithCompletion:^{
          SessionExitPlan *exitPlan =
              [session.state exitPlanWithExited:task.terminationReason == NSTaskTerminationReasonExit
                              terminationStatus:task.terminationStatus
                             recentGuestReboots:session.recentGuestReboots];
          BOOL relaunch = exitPlan.relaunch;
          session.status.stringValue = exitPlan.statusText;
          session.displayView.displaySleeping = YES;
          session.stateLabel.stringValue = exitPlan.stateText;
          session.statePanel.hidden = NO;
          session.stateAction.hidden = NO;
          // For the session that replaces this one to carry on with: see continueFromSession.
          session.recentGuestReboots = exitPlan.guestReboot ? exitPlan.recentGuestReboots : nil;
          NSURL *waitingURL = relaunch ? session.pendingHostConnectionURL : nil;
          void (^waitingCompletion)(NSError *) = relaunch ? session.pendingHostConnectionCompletion : nil;
          if (relaunch) {
              session.pendingHostConnectionURL = nil;
              session.pendingHostConnectionCompletion = nil;
          }
          session.shutdownButton.enabled = NO;
          [session cleanUp];
          if (exitPlan.showStoppedScreen)
              [session showStoppedScreen];
          if (exitPlan.rebootLoop)
              VIMPresentError(VIMSessionError(@"This Mac restarted repeatedly and was stopped. Open Session Details to "
                                              @"check its boot log, then try starting it again."),
                              session.window);
          if (exitPlan.closeWindow)
              [session.window close];
          if (!relaunch && VIMCreatingGuestFromArguments()) {
              // The window would wait for a click on Start. Cleanup above finished an install that was verified.
              if ([session.machine.configuration[@"InstallState"] isEqual:@"installed"])
                  exit(0);
              VIMFailCreateGuest(
                  [NSString stringWithFormat:@"%@ before the installation finished.", exitPlan.statusText]);
          }
          // Successful openMachine publishes its own library notification once
          // the replacement owns the session lock. Do not invite background
          // maintenance into the gap between cleanup and that acquisition.
          if (!relaunch)
              [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
          if (relaunch) {
              NSError *failure = nil;
              VIMMachine *fresh = [VIMMachine loadURL:session.machine.URL error:&failure];
              NSWindow *previousWindow = session.window;
              NSRect previousFrame = previousWindow.frame;
              // The new session chooses its own safe display hardware. A valid
              // setup/privacy restart must also work before graphics publishing;
              // requiring acceleration here strands an otherwise bootable VM.
              session.pendingHostConnectionURL = waitingURL;
              session.pendingHostConnectionCompletion = waitingCompletion;
              if (fresh && [VIMSession openMachine:fresh error:&failure]) {
                  VIMSession *replacement = sessions[SessionKey(fresh)];
                  [replacement.window setFrame:previousFrame display:YES];
                  if (replacement.window != previousWindow)
                      [previousWindow close];
              } else {
                  session.guestStatus.stringValue =
                      failure.localizedDescription ?: @"Restart paused: graphics installation needs recovery.";
                  VIMFailCreateGuest(session.guestStatus.stringValue);
                  [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
                  session.pendingHostConnectionURL = nil;
                  session.pendingHostConnectionCompletion = nil;
                  if (waitingCompletion)
                      waitingCompletion(
                          failure ?: VIMSessionError(@"The virtual Mac couldn’t restart to open the connection."));
              }
          }
        }];
      });
    };
    if (![self.task launchAndReturnError:error]) {
        [self cleanUp];
        return NO;
    }
    [self applyLifecycleEvent:VIMSessionEventEmulatorStarted];
    if (openGLInprocess) {
        rendererPID = [NSString stringWithFormat:@"%d", self.task.processIdentifier];
        if (!VIMPrepareOpenGLSurfaceEndpoint(self.displayConnection, self.task.processIdentifier, self.runtimeDirectory,
                                             error)) {
            [self.task terminate];
            [self cleanUp];
            return NO;
        }
    }
    if (openGLDirectDisplay) {
        NSDictionary *env = self.task.environment;
        NSString *service = env[@"VIM_OPENGL_VRAM_SERVICE"], *endpoint = env[@"VIM_OPENGL_VRAM_ENDPOINT"];
        int pid = 0;
        NSScanner *scanner = [NSScanner scannerWithString:rendererPID ?: @""];
        if (service.length && endpoint.length && [scanner scanInt:&pid] && scanner.isAtEnd && pid > 0) {
            NSDictionary *attributes =
                [NSFileManager.defaultManager attributesOfItemAtPath:endpoint.stringByDeletingLastPathComponent
                                                               error:NULL];
            BOOL privateDirectory = [attributes[NSFileType] isEqual:NSFileTypeDirectory] &&
                                    [attributes[NSFileOwnerAccountID] unsignedIntValue] == getuid() &&
                                    !([attributes[NSFilePosixPermissions] unsignedIntValue] & 0077);
            NSDictionary *description = @{
                @"Version" : @1,
                @"Service" : service,
                @"RendererPID" : @(pid),
                @"ProducerPID" : @(self.task.processIdentifier)
            };
            if (!privateDirectory || ![description writeToFile:endpoint atomically:YES] ||
                ![NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions : @0600}
                                                ofItemAtPath:endpoint
                                                       error:NULL]) {
                if (openGLInprocess) {
                    if (error)
                        *error = VIMSessionError(@"The graphics memory connection could not be prepared.");
                    [self.task terminate];
                    [self cleanUp];
                    return NO;
                }
                [self logNote:@"Shared graphics memory endpoint unavailable; using copied "
                              @"graphics fallback."];
            }
        }
    }
    if ([config[@"FileSharingEnabled"] boolValue] && [VIMNetworkMode(config) isEqual:@"shared"]) {
        self.smbService = [[VIMSMBService alloc] initWithMachine:self.machine
                                                            port:[config[@"FileSharingPort"] unsignedShortValue]];
        NSError *sharingError = nil;
        if (![self.smbService start:&sharingError])
            [self logNote:@"%@", sharingError.localizedDescription];
    }
    [self updateInstallationActivity];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    if (unavailableImages.count) {
        NSDictionary *settings = VIMImageClearedSelections(self.machine.editableConfiguration, unavailableImages);
        NSError *failure = nil;
        BOOL forgotten = !settings.count || [self.machine saveSettings:settings error:&failure];
        if (settings.count)
            [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
        VIMUnavailableImagesNotice *notice = [[VIMUnavailableImagesNotice alloc] initWithImages:unavailableImages
                                                                                      forgotten:forgotten];
        NSAlert *alert = [NSAlert new];
        alert.messageText = notice.title;
        alert.informativeText = notice.detail;
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Connect Image…"];
        VIMPresentAlert(alert, self.window, ^(NSModalResponse response) {
          if (response == NSAlertSecondButtonReturn)
              [VIMSession chooseOpticalMediaForMachine:self.machine window:self.window];
        });
    }
    self.resizeArmed = !installerDisplay || (openGLDirectDisplay && !classicInstaller);
    // Before QMP, QEMU can be stuck in device setup with nothing on the display. Say so, and leave the emulator alone.
    self.controlStallTimer = [NSTimer scheduledTimerWithTimeInterval:VIMGuestSessionState.controlStallSeconds
                                                             repeats:NO
                                                               block:^(NSTimer *timer) {
                                                                 [weakSelf noteControlStall];
                                                               }];
    [self connectControlWithCompletion:^(NSError *failure) {
      VIMSession *session = weakSelf;
      if (!session.task.running)
          return;
      [session noteControlAnswered];
      session.status.stringValue = failure ? failure.localizedDescription : @"Running";
      session.shutdownButton.enabled = failure == nil;
      if (!failure) {
          [session.window.contentView layoutSubtreeIfNeeded];
          [session scheduleResize];
      }
      // Seed the known installed/installer range before delivering input;
      // the later bound-driver observation can still override it.
      session.state.legacyTabletGuest = VIMUsesLegacyTabletCalibration(session.machine.guest);
      session.state.legacyTabletObserved = NO;
      session.tabletTrim = VIMInitialTabletTrim(session.machine.guest, classicInstaller);
      void (^sendInput)(NSArray *, void (^)(void)) = ^(NSArray *events, void (^answered)(void)) {
        void (^observer)(CFTimeInterval, NSError *) = weakSelf.displayView.diagnosticInputObserver;
        CFTimeInterval inputQueued = observer ? CACurrentMediaTime() : 0;
        [weakSelf.control execute:@"input-send-event"
                        arguments:@{@"events" : events}
                       completion:^(id result, NSError *error) {
                         if (observer)
                             observer(inputQueued, error);
                         [weakSelf.displayView noteInputReply];
                         if (error && weakSelf.task.running)
                             weakSelf.status.stringValue = error.localizedDescription;
                         if (answered)
                             answered();
                       }];
      };
      // VIM_INPUT_COALESCE=0 sends every move as its own round trip again.
      VIMInputMotionCoalescer *motionCoalescer =
          [NSProcessInfo.processInfo.environment[@"VIM_INPUT_COALESCE"] isEqualToString:@"0"]
              ? nil
              : [[VIMInputMotionCoalescer alloc] initWithSend:sendInput];
      if (!failure)
          session.displayView.inputHandler = ^(NSArray *events) {
            if ([weakSelf.lastRunState isEqual:@"suspended"]) {
                if (weakSelf.wakePending)
                    return;
                weakSelf.wakePending = YES;
                [weakSelf.control execute:@"system_wakeup"
                    arguments:@{}
                    completion:^(id result, NSError *error) {
                      weakSelf.wakePending = NO;
                      if (!error) {
                          weakSelf.lastRunState = nil;
                          [weakSelf.displayView releasePressedKeys];
                          [weakSelf refreshRunState];
                      } else
                          weakSelf.status.stringValue = error.localizedDescription;
                    }];
                return;
            }
            events = [VIMTabletCalibration eventsFrom:events trim:(NSInteger)weakSelf.tabletTrim];
            // Research workloads account for one reply per input they queue.
            if (motionCoalescer && !weakSelf.displayView.diagnosticInputObserver)
                [motionCoalescer submitEvents:events];
            else
                sendInput(events, nil);
          };
      if (!failure) {
          if (config[@"NetworkConnected"] && ![config[@"NetworkConnected"] boolValue])
              [session.control execute:@"set_link"
                  arguments:@{
                      @"name" : @"ethernet",
                      @"up" : @NO
                  }
                  completion:^(id result, NSError *error) {
                    if (error) {
                        VIMPresentError(error, session.window);
                        return;
                    }
                    [session.control execute:@"cont"
                        arguments:@{}
                        completion:^(id result, NSError *failure) {
                          if (failure)
                              VIMPresentError(failure, session.window);
                        }];
                  }];
          // A newly opened guest accepts typing immediately, without requiring
          // a mouse click on its framebuffer first. Don't steal focus if the
          // user has already switched to another window during startup.
          if (openGLInprocess && !(config[@"NetworkConnected"] && ![config[@"NetworkConnected"] boolValue]))
              [session.control execute:@"cont"
                  arguments:@{}
                  completion:^(id result, NSError *error) {
                    if (error)
                        VIMPresentError(error, session.window);
                  }];
          if (session.window.isKeyWindow)
              [session.window makeFirstResponder:session.displayView];
          [session refreshRunState];
          [session refreshGuestStatus];
          session.statusTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                                repeats:YES
                                                                  block:^(NSTimer *timer) {
                                                                    [weakSelf refreshRunState];
                                                                    [weakSelf servicePendingHostConnection];
                                                                    [weakSelf serviceDiagnosticRequest];
                                                                  }];
          session.diagnosticDirectory =
              [VIMSessionDiagnostics directoryForArguments:NSProcessInfo.processInfo.arguments
                                               machinePath:session.machine.URL.URLByResolvingSymlinksInPath.path
                                                identifier:session.machine.configuration[@"Identifier"]];
          if (session.diagnosticDirectory) {
              session.diagnostics = [[VIMSessionDiagnostics alloc]
                  initWithDirectory:session.diagnosticDirectory
                            control:session.control
                              agent:session.guestAgent
                         statusTool:session.guestStatusTool
                          memoryMiB:[session.machine.configuration[@"MemoryMiB"] unsignedLongLongValue]];
              session.diagnostics.isRunning = ^BOOL {
                return weakSelf.task.running;
              };
          }
      }
    }];
    return YES;
}
- (void)noteControlStall {
    if (!self.guestSessionState.controlStalled)
        return;
    self.controlStallShown = YES;
    NSString *notice = VIMGuestSessionState.controlStallNotice;
    [self logNote:@"QEMU has not answered on its control connection after %.0f seconds.",
                  VIMGuestSessionState.controlStallSeconds];
    self.status.stringValue = notice;
    self.stateLabel.stringValue = notice;
    self.stateAction.hidden = YES;
    self.statePanel.hidden = NO;
}
- (void)noteControlAnswered {
    self.state.controlConnected = YES;
    [self.controlStallTimer invalidate];
    self.controlStallTimer = nil;
    if (!self.controlStallShown)
        return;
    self.controlStallShown = NO;
    self.statePanel.hidden = YES;
    [self logNote:@"QEMU answered on its control connection."];
}
- (void)connectControlWithCompletion:(void (^)(NSError *))completion {
    if (!self.task.running)
        return;
    __weak VIMSession *weakSelf = self;
    [self.control connectWithCompletion:^(NSError *error) {
      VIMSession *session = weakSelf;
      if (!session.task.running)
          return;
      if (!error) {
          completion(nil);
          return;
      }
      // Cold Rosetta startup / busy TCG can outlast the initial greeting.
      // Retry the same authenticated app-owned socket, not guest services.
      // Otherwise a visible installer can permanently have no input handler.
      session.status.stringValue = error.localizedDescription;
      [session.controlRetryTimer invalidate];
      session.controlRetryTimer =
          [NSTimer scheduledTimerWithTimeInterval:2
                                          repeats:NO
                                            block:^(NSTimer *timer) {
                                              [weakSelf connectControlWithCompletion:completion];
                                            }];
    }];
}
- (void)serviceDiagnosticRequest {
    // Explicit development opt-in. Reuse the app-owned serial connection;
    // a second QGA client would steal replies and interrupt guest setup.
    if (!self.diagnostics || self.state.diagnosticPending)
        return;
    NSDictionary *command =
        [self.diagnostics takeRequestWhileAgentBusy:self.state.guestPending || self.preparing ||
                                                    self.state.bootPolicyPending || self.state.clipboardPending];
    if (!command)
        return;
    self.state.diagnosticPending = YES;
    void (^finish)(NSDictionary *) = ^(NSDictionary *result) {
      [self.diagnostics writeResult:result];
      self.state.diagnosticPending = NO;
      // Resume provisioning deferred while this command owned the agent.
      // In particular, an explicit clipboard-on request must not wait for
      // the next minute-long status refresh after releasing that ownership.
      [self updateClipboardForBoot:self.state.usernameBoot];
    };
    if ([command[@"Action"] isEqual:@"capture"]) {
        [self.displayView capturePNG:^(NSData *png) {
          BOOL saved = [png writeToFile:[self.diagnosticDirectory stringByAppendingPathComponent:@"Frame.png"]
                             atomically:YES];
          finish(@{@"Captured" : @(saved)});
        }];
        return;
    }
    if ([command[@"Action"] isEqual:@"cursor-state"]) {
        finish([self.displayView cursorDiagnostics]);
        return;
    }
    if ([command[@"Action"] isEqual:@"display-fingerprint"]) {
        if (![command[@"Enabled"] isKindOfClass:NSNumber.class]) {
            finish(@{@"Error" : @"Choose fingerprint measurement on or off."});
            return;
        }
        BOOL enabled = [command[@"Enabled"] boolValue];
        NSDictionary *observed = nil;
        if (!enabled)
            observed = self.displayView.frameDiagnostics;
        [self.displayView setFingerprintMeasurementEnabled:enabled];
        [self.displayView setFingerprintTraceEnabled:enabled];
        // Return the final observed generation/trace before disarming it.
        finish(@{@"Frame" : observed ?: self.displayView.frameDiagnostics, @"MeasurementEnabledAfter" : @(enabled)});
        return;
    }
    if ([command[@"Action"] isEqual:@"pointer-workload"]) {
        __weak VIMSession *weakSelf = self;
        VIMResearchPointerWorkload(
            self.displayView, command,
            ^BOOL {
              return weakSelf.task.running;
            },
            finish);
        return;
    }
    if ([command[@"Action"] isEqual:@"key-workload"]) {
        __weak VIMSession *weakSelf = self;
        VIMResearchKeyWorkload(
            self.displayView, command,
            ^BOOL {
              return weakSelf.task.running;
            },
            finish);
        return;
    }
    if ([command[@"Action"] isEqual:@"display-buffer-count"]) {
        NSNumber *count = command[@"Count"];
        if (!self.machine.openGLResearchGuest || ![count isKindOfClass:NSNumber.class] ||
            (count.doubleValue != 2 && count.doubleValue != 3) ||
            ![self.displayView setPresentationDrawableCount:count.unsignedIntegerValue]) {
            finish(@{@"Error" : @"Choose a Metal swap-queue depth of 2 or 3 for a research Mac."});
            return;
        }
        finish(@{@"Frame" : self.displayView.frameDiagnostics});
        return;
    }
    if ([command[@"Action"] isEqual:@"display-acquire-async"]) {
        if (!self.machine.openGLResearchGuest || ![command[@"Enabled"] isKindOfClass:NSNumber.class]) {
            finish(@{@"Error" : @"This presentation experiment requires a research Mac and Enabled boolean."});
            return;
        }
        self.displayView.asynchronousDrawableAcquisition = [command[@"Enabled"] boolValue];
        finish(@{@"Frame" : self.displayView.frameDiagnostics});
        return;
    }
    if ([@[ @"passthrough-opengl-release-bql", @"opengl-pirq-f-pic" ] containsObject:command[@"Action"] ?: @""]) {
        BOOL routing = [command[@"Action"] isEqual:@"opengl-pirq-f-pic"];
        NSNumber *enabled = command[routing ? @"Route" : @"Enabled"];
        if (!self.machine.openGLResearchGuest || (enabled && ![enabled isKindOfClass:NSNumber.class])) {
            finish(@{@"Error" : @"This diagnostic requires a research Mac and an optional Enabled boolean."});
            return;
        }
        if (routing && enabled &&
            (enabled.doubleValue != enabled.unsignedIntegerValue || enabled.unsignedIntegerValue > 255)) {
            finish(@{@"Error" : @"Choose the exact original or masked routing byte (0–255)."});
            return;
        }
        NSArray *parents = @[ @"/machine/peripheral-anon", @"/machine/unattached", @"/machine/peripheral" ];
        __block NSUInteger remaining = parents.count;
        NSMutableArray *matches = [NSMutableArray array];
        for (NSString *parent in parents)
            [self.control execute:@"qom-list"
                        arguments:@{@"path" : parent}
                       completion:^(id objects, NSError *error) {
                         dispatch_async(dispatch_get_main_queue(), ^{
                           if (!error && [objects isKindOfClass:NSArray.class])
                               for (NSDictionary *entry in objects)
                                   if ([entry[@"type"] isEqual:routing ? @"child<ICH9-LPC>" : @"child<vmware-svga>"] &&
                                       [entry[@"name"] isKindOfClass:NSString.class])
                                       [matches addObject:[parent stringByAppendingPathComponent:entry[@"name"]]];
                           if (--remaining)
                               return;
                           if (matches.count != 1) {
                               finish(@{@"Error" : @"A unique research hardware device was not found."});
                               return;
                           }
                           NSMutableDictionary *args = [@{
                               @"path" : matches.firstObject,
                               @"property" : routing ? @"x-pirq-f-pic-route" : @"x-passthrough-opengl-release-bql"
                           } mutableCopy];
                           if (enabled)
                               args[@"value"] = routing ? enabled : @([enabled boolValue]);
                           [self.control execute:enabled ? @"qom-set" : @"qom-get"
                                       arguments:args
                                      completion:^(id value, NSError *failure) {
                                        finish(failure?@{@"Error":failure.localizedDescription}:@{routing?@"Route":@"Enabled":enabled?(routing?enabled:@([enabled boolValue])):value?:@NO});
                                      }];
                         });
                       }];
        return;
    }
    if ([command[@"Action"] isEqual:@"fullscreen"]) {
        if (![command[@"Enabled"] isKindOfClass:NSNumber.class]) {
            finish(@{@"Error" : @"Choose fullscreen on or off."});
            return;
        }
        BOOL desired = [command[@"Enabled"] boolValue];
        if (((self.window.styleMask & NSWindowStyleMaskFullScreen) != 0) == desired) {
            finish(
                @{@"Changed" : @NO, @"FullScreen" : @(desired), @"Frame" : self.displayView.frameDiagnostics ?: @{}});
            return;
        }
        __block BOOL ended = NO;
        __block id observer = nil;
        __weak VIMSession *weakSelf = self;
        void (^complete)(BOOL) = ^(BOOL notified) {
          if (ended)
              return;
          ended = YES;
          if (observer) {
              [NSNotificationCenter.defaultCenter removeObserver:observer];
              observer = nil;
          }
          VIMSession *session = weakSelf;
          BOOL actual = (session.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
          if (!notified || actual != desired) {
              finish(@{@"Error" : @"The fullscreen window transition did not finish.", @"FullScreen" : @(actual)});
              return;
          }
          finish(
              @{@"Changed" : @YES, @"FullScreen" : @(actual), @"Frame" : session.displayView.frameDiagnostics ?: @{}});
        };
        observer = [NSNotificationCenter.defaultCenter
            addObserverForName:desired ? NSWindowDidEnterFullScreenNotification : NSWindowDidExitFullScreenNotification
                        object:self.window
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(),
                                     ^{
                                       complete(YES);
                                     });
                    }];
        [NSApp activateIgnoringOtherApps:YES];
        [self.window makeKeyAndOrderFront:nil];
        // The real View menu targets this exact AppKit action. No alternate
        // emulator/display path, synthetic host input or window geometry hack.
        [self.window toggleFullScreen:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          complete(NO);
        });
        return;
    }
    if ([command[@"Action"] isEqual:@"display-state"]) {
        NSMenu *view = [NSApp.mainMenu itemWithTitle:@"View"].submenu;
        [view update];
        NSMenu *menu = [view itemWithTitle:self.supportsRetinaDisplay ? @"Retina Resolution" : @"Resolution"].submenu;
        [menu update];
        NSMutableArray *items = [NSMutableArray new];
        for (NSMenuItem *item in menu.itemArray)
            if (item.target == self && item.action == @selector(changeRetinaMode:))
                [items addObject:@{
                    @"Title" : item.title,
                    @"Selected" : @(item.state == NSControlStateValueOn),
                    @"Enabled" : @(item.enabled)
                }];
        finish(@{
            @"Mode" : self.displayMode ?: @"",
            @"Pending" : @(self.state.displayModePending),
            @"FullScreen" : @((self.window.styleMask & NSWindowStyleMaskFullScreen) != 0),
            @"Frame" : self.displayView.frameDiagnostics ?: @{},
            @"PowerObserver" :
                @{@"Connected" : @(self.powerBridge.connected), @"Transport" : self.powerBridge.diagnosticState ?: @{}},
            @"LastVerifiedSelection" : self.observedDisplayMode ?: @{},
            @"MenuItems" : items
        });
        return;
    }
    if ([command[@"Action"] isEqual:@"display-mode"]) {
        if (!self.task.running) {
            finish(@{@"Error" : @"Start the virtual Mac before qualifying its display."});
            return;
        }
        [self applyDisplayMode:command[@"Mode"]
                    completion:^(NSDictionary *observed, NSError *error) {
                      finish(error ? @{@"Error" : error.localizedDescription}
                                   : @{@"Applied" : @YES,
                                       @"Mode" : self.displayMode,
                                       @"Observed" : observed ?: @{}});
                    }];
        return;
    }
    if ([command[@"Action"] isEqual:@"display-request"]) {
        if (!self.task.running) {
            finish(@{@"Error" : @"Start the virtual Mac before asking for a display size."});
            return;
        }
        // Past what the window would ask for, to find what a guest display can do: probes/seamless-driver.py. This only
        // offers the size; the guest selects it. Remembering it stops a pending resize timer from undoing it.
        NSUInteger width = [command[@"Width"] unsignedIntegerValue], height = [command[@"Height"] unsignedIntegerValue];
        self.lastRequestedSize = NSMakeSize(width, height);
        [self.displayConnection requestWidth:width height:height density:[command[@"Density"] unsignedIntegerValue]];
        finish(@{@"Requested" : @YES});
        return;
    }
    if ([command[@"Action"] isEqual:@"network-details"]) {
        NSMutableDictionary *details = [[VIMSession networkDetailsForMachine:self.machine] mutableCopy];
        NSMutableArray *items = [NSMutableArray new];
        for (NSMenuItem *item in [self deviceMenuForKind:@"Network"].itemArray)
            if (!item.separatorItem)
                [items addObject:item.title];
        details[@"MenuItems"] = items;
        finish(details);
        return;
    }
    if ([command[@"Action"] isEqual:@"configuration"]) {
        NSString *pane = command[@"Pane"];
        if (![@[ @"General", @"Graphics", @"Network", @"Sound", @"File Sharing", @"Remote Login", @"Clipboard" ]
                containsObject:pane]) {
            finish(@{@"Error" : @"Choose a supported configuration pane."});
            return;
        }
        [VIMMachineSettings showForMachine:self.machine
                                   section:[@[ @"File Sharing", @"Remote Login", @"Clipboard" ] containsObject:pane]
                                               ? @"Sharing"
                                               : ([pane isEqual:@"General"] ? @"General" : @"Hardware")category:pane
                                    window:self.window];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
          NSError *error = nil;
          BOOL saved = [VIMMachineSettings
              captureForMachine:self.machine
                          toURL:[NSURL fileURLWithPath:[self.diagnosticDirectory
                                                           stringByAppendingPathComponent:@"Configuration.png"]]
                          error:&error];
          finish(error ? @{@"Error" : error.localizedDescription} : @{@"Captured" : @(saved)});
        });
        return;
    }
    if ([command[@"Action"] isEqual:@"usb-devices"]) {
        finish(@{@"Devices" : VIMHostUSBDevices(), @"Attached" : self.usbAttached ?: @{}});
        return;
    }
    if ([command[@"Action"] isEqual:@"menu-state"]) {
        if ([command[@"Context"] isEqual:@"library"])
            [(id)NSApp.delegate showLibrary:nil];
        else if ([command[@"Context"] isEqual:@"about"]) {
            [(id)NSApp.delegate showAbout:nil];
            if ([NSApp.keyWindow isKindOfClass:NSPanel.class])
                self.diagnosticAboutWindow = NSApp.keyWindow;
        } else if ([command[@"Context"] isEqual:@"guest"]) {
            [self.diagnosticAboutWindow performClose:nil];
            self.diagnosticAboutWindow = nil;
            [NSApp activateIgnoringOtherApps:YES];
            [self.window makeKeyAndOrderFront:nil];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
          NSMutableDictionary *state = [NSMutableDictionary new];
          for (NSString *name in @[ @"File", @"Actions", @"Devices" ]) {
              NSMenuItem *root = [NSApp.mainMenu itemWithTitle:name];
              [root.submenu update];
              NSMutableArray *items = [NSMutableArray new];
              for (NSMenuItem *item in root.submenu.itemArray)
                  if (!item.separatorItem)
                      [items addObject:@{@"Title" : item.title, @"Enabled" : @(item.enabled)}];
              state[name] = @{@"Present" : @(root != nil), @"Hidden" : @(root.hidden), @"Items" : items};
          }
          finish(state);
        });
        return;
    }
    if ([command[@"Action"] isEqual:@"usb-storage-access"]) {
        NSDictionary *selected = nil;
        for (NSDictionary *device in VIMHostUSBDevices())
            if ([device[@"LocationID"] isEqual:command[@"LocationID"]])
                selected = device;
        if (!selected) {
            finish(@{@"Error" : @"The requested physical USB device is not connected."});
            return;
        }
        NSMutableArray *protected = [NSMutableArray new];
        for (VIMSession *session in sessions.allValues)
            if (session.machine.URL)
                [protected addObject:session.machine.URL];
        VIMHostRequestUSBStorageAccess(selected, protected, ^(NSError *error) {
          finish(error ? @{@"Error" : error.localizedDescription}
                       : @{@"PreflightCompleted" : @YES,
                           @"CaptureVerified" : @NO});
        });
        return;
    }
    if ([command[@"Action"] isEqual:@"usb-interface-policy"]) {
        NSDictionary *selected = nil;
        for (NSDictionary *device in VIMHostUSBDevices())
            if ([device[@"LocationID"] isEqual:command[@"LocationID"]])
                selected = device;
        if (!selected) {
            finish(@{@"Error" : @"The requested physical USB device is not connected."});
            return;
        }
        [self ensureUSBClient];
        [self.usbClient checkStorageInterface:selected
                                inUserSession:[command[@"UserSession"] isEqual:@YES]
                                   completion:^(NSDictionary *result, NSError *error) {
                                     finish(error ? @{@"Error" : error.localizedDescription} : result);
                                   }];
        return;
    }
    if ([command[@"Action"] isEqual:@"usb-connect"] || [command[@"Action"] isEqual:@"usb-disconnect"]) {
        if (!self.task.running || self.usbOperationPending) {
            finish(@{@"Error" : @"USB is not ready for another operation."});
            return;
        }
        NSDictionary *selected = nil;
        for (NSDictionary *device in VIMHostUSBDevices())
            if ([device[@"LocationID"] isEqual:command[@"LocationID"]])
                selected = device;
        if (!selected) {
            finish(@{@"Error" : @"The requested physical USB device is not connected."});
            return;
        }
        [self ensureUSBClient];
        NSString *identifier = selected[@"Identifier"];
        self.usbOperationPending = YES;
        void (^done)(NSError *) = ^(NSError *error) {
          self.usbOperationPending = NO;
          if (!error) {
              if ([command[@"Action"] isEqual:@"usb-disconnect"])
                  [self.usbAttached removeObjectForKey:identifier];
              else {
                  if (!self.usbAttached)
                      self.usbAttached = [NSMutableDictionary new];
                  self.usbAttached[identifier] = selected[@"Name"];
              }
          }
          finish(error ? @{@"Error" : error.localizedDescription} : @{@"Attached" : self.usbAttached ?: @{}});
        };
        if ([command[@"Action"] isEqual:@"usb-disconnect"]) {
            [self.usbClient disconnectDevice:identifier control:self.control completion:done];
            return;
        }
        NSMutableArray *protected =
            [NSMutableArray arrayWithObjects:NSBundle.mainBundle.bundleURL, VIMLibraryLocation.rootURL, nil];
        for (VIMSession *session in sessions.allValues)
            if (session.machine.URL)
                [protected addObject:session.machine.URL];
        NSError *error = nil;
        NSDictionary *storage = VIMHostUSBStorageInfo(selected, protected, &error);
        if (!storage || [storage[@"Protected"] boolValue]) {
            done(error ?: VIMSessionError(@"The selected USB device contains the app or a virtual Mac library."));
            return;
        }
        void (^connect)(void) = ^{
          [self.usbClient prepareWithCompletion:^(NSError *failure) {
            if (failure) {
                done(failure);
                return;
            }
            [self.usbClient connectDevice:selected
                                processID:self.task.processIdentifier
                                directory:self.runtimeDirectory
                                  control:self.control
                               completion:done];
          }];
        };
        BOOL mounted = [storage[@"MountedVolumes"] count] > 0;
        if (mounted && ![command[@"Unmount"] isEqual:@YES]) {
            done(VIMSessionError(@"Explicit normal-unmount confirmation is required."));
            return;
        }
        VIMHostRequestUSBStorageAccess(selected, protected, ^(NSError *failure) {
          if (failure) {
              done(failure);
              return;
          }
          if (!self.task.running) {
              done(VIMSessionError(@"This virtual Mac has stopped."));
              return;
          }
          // Developer harness can confirm only normal unmount, never force.
          if (mounted)
              VIMHostReleaseUSBDisks(selected, protected, NO, ^(NSError *error) {
                if (error)
                    done(error);
                else
                    connect();
              });
          else
              connect();
        });
        return;
    }
    if ([command[@"Action"] isEqual:@"insert-disc"]) {
        NSString *issue = [VIMSessionDiagnostics issueWithImageRequest:command slotCount:VIMImageSlotCount];
        if (issue) {
            finish(@{@"Error" : issue});
            return;
        }
        NSString *path = command[@"Path"];
        NSNumber *slot = command[@"Slot"] ?: @0;
        [VIMSession insertImage:path
                           slot:slot.unsignedIntegerValue
                        machine:self.machine
                     completion:^(NSError *error) {
                       if (error) {
                           finish(@{@"Error" : error.localizedDescription});
                           return;
                       }
                       NSMutableArray *images = [NSMutableArray new];
                       for (NSDictionary *image in [VIMSession connectedImagesForMachine:self.machine]) {
                           NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Disconnect"
                                                                         action:@selector(ejectOpticalMedia:)
                                                                  keyEquivalent:@""];
                           item.representedObject = image[@"Slot"];
                           NSMutableDictionary *entry = [image mutableCopy];
                           entry[@"CanDisconnect"] = @([self validateMenuItem:item]);
                           [images addObject:entry];
                       }
                       finish(@{
                           @"Inserted" : @(path.length > 0),
                           @"Images" : images,
                           @"MediaChangePending" : @(self.imageDrives.changePending)
                       });
                     }];
        return;
    }
    if ([command[@"Action"] isEqual:@"shutdown-vm"]) {
        if (self.preparing || self.preparationRequested) {
            finish(@{@"Error" : @"Wait for guest setup to finish before shutting down."});
            return;
        }
        [self shutdown:self];
        finish(@{@"Requested" : @(self.state.shutdownRequested)});
        return;
    }
    if ([command[@"Action"] isEqual:@"resume-setup"]) {
        if (!self.machine.preMetalGuest || !self.task.running || self.state.guestPending || self.preparing ||
            self.preparationRequested) {
            finish(@{@"Error" : @"This Mac is not ready to resume its saved setup."});
            return;
        }
        // Explicit diagnostic request, same production coordinator and Keychain
        // input path. Never accept a password in the diagnostic request files.
        self.state.developmentSetupDeferred = NO;
        [self.openGLSetup requestInstallerResume];
        finish(@{@"Requested" : @YES});
        [self checkGraphicsSetup:self];
        return;
    }
    if ([command[@"Action"] isEqual:@"force-stop-vm"]) {
        if (!VIMSkipsDevelopmentPowerConfirmation()) {
            finish(@{
                @"Error" :
                    @"Force-stop diagnostics require VIMSkipPowerConfirmation or --development-no-power-confirmation."
            });
            return;
        }
        [self forceStop:self];
        finish(@{@"Requested" : @YES});
        return;
    }
    if ([command[@"Action"] isEqual:@"input"]) {
        NSArray *events = command[@"Events"];
        NSString *issue =
            [VIMSessionDiagnostics issueWithInputBatch:events ready:self.task.running && self.displayView.inputHandler];
        if (issue) {
            finish(@{@"Error" : issue});
            return;
        }
        self.displayView.inputHandler(events);
        finish(@{@"Queued" : @YES});
        return;
    }
    if ([command[@"Action"] isEqual:@"clipboard"]) {
        NSNumber *enabled = command[@"Enabled"];
        NSError *error = nil;
        if (enabled && ![self.machine saveSettings:@{@"ClipboardEnabled" : enabled} error:&error]) {
            finish(@{@"Error" : error.localizedDescription});
            return;
        }
        if (enabled)
            [self updateClipboardForBoot:self.state.usernameBoot];
        finish(@{
            @"Enabled" : @(!self.machine.editableConfiguration[@"ClipboardEnabled"] ||
                           [self.machine.editableConfiguration[@"ClipboardEnabled"] isEqual:@YES]),
            @"Connected" : @(self.clipboard.isConnected),
            @"ExchangeAllowed" : @(self.clipboard.exchangeAllowed && self.clipboard.exchangeAllowed()),
            @"ApplicationActive" : @(NSApp.active),
            @"WindowKey" : @(self.window.keyWindow),
            @"DisplaySleeping" : @(self.displayView.displaySleeping),
            @"Provisioning" : @(self.state.clipboardPending),
            @"Failure" : self.clipboardFailure ?: @"",
            @"Transport" : self.clipboard.diagnosticState ?: @{}
        });
        return;
    }
    [self.diagnostics handleCommand:command finish:finish];
}
- (void)enforceGuestSleepPolicyForBoot:(NSString *)boot nativeIdleGuard:(BOOL)guarded {
    if (!boot.length || [boot isEqual:self.sleepDisabledBoot] || !self.task.running)
        return;
    // v1 has no reliable S3/S4 resume on either graphics stack. Apply the
    // same native root-domain policy to Pre-Metal desktops too; their status
    // branch returns before the modern setup path below. Keep display sleep
    // independent. One cold command per boot, no per-frame or idle polling.
    self.sleepDisabledBoot = boot;
    NSArray *arguments = [self.guestSessionState sleepPolicyArgumentsWithNativeIdleGuard:guarded];
    if (!arguments)
        return;
    NSString *runtime = self.runtimeDirectory;
    __weak VIMSession *weakSelf = self;
    [self.guestAgent runExecutable:@"/usr/bin/pmset"
                         arguments:arguments
                           timeout:30
                        completion:^(NSDictionary *result, NSError *failure) {
                          VIMSession *session = weakSelf;
                          // A late failure from an old session must not clear a newer boot's
                          // confirmed policy or schedule work against a replacement VM process.
                          if (![session.runtimeDirectory isEqual:runtime] || ![session.sleepDisabledBoot isEqual:boot])
                              return;
                          if (failure || ![result[@"exitcode"] isEqual:@0])
                              session.sleepDisabledBoot = nil;
                        }];
}
- (VIMGuestSessionState *)guestSessionState {
    // Only what lives elsewhere. Everything else the state already holds.
    VIMGuestSessionState *state = self.state;
    state.guest = self.machine.guest;
    state.running = self.task.running;
    state.preparing = self.preparing;
    state.preparationRequested = self.preparationRequested;
    state.installationRequested = self.installationRequested;
    state.runState = self.lastRunState;
    state.hasStatusTool = self.guestStatusTool.length > 0;
    state.hasModernSetup = self.modernSetup != nil;
    state.passthroughOpenGLEnabled = self.machine.passthroughOpenGLEnabled;
    state.hasGuestAddresses = self.guestIPAddresses.count > 0;
    return state;
}
- (VIMGuestStatusPolicy *)statusPolicyForReport:(NSDictionary *)report error:(NSError *)error {
    return [[VIMGuestStatusPolicy alloc] initWithReport:report failed:error != nil session:self.guestSessionState];
}
- (void)refreshGuestStatus {
    __weak VIMSession *weakSelf = self;
    switch (self.guestSessionState.nextRefreshStep) {
        case VIMGuestRefreshStepBusy:
            return;
        case VIMGuestRefreshStepRetryAfterCommand: {
            // A one-shot status timer may fire during a diagnostic command. Keep
            // the normal production readiness/verification loop alive afterward.
            [self scheduleGuestStatusRefreshAfter:15];
            return;
        }
        case VIMGuestRefreshStepNativeTigerInstallation:
            // Native Tiger installation is available before its separate GL
            // payload is qualified. Do not run Darwin9 controls or display a
            // false missing-accelerator error during the native installer.
            // Enabling the actual GL profile later must use the normal strict
            // coordinator/verification gates; never mark setup complete here.
            self.guestStatus.stringValue = @"Mac OS X Tiger — native installation";
            return;
        case VIMGuestRefreshStepSetupPaused:
            // Process-local development opt-in only: keep the real boot, drivers,
            // display and agent available while inspecting a cold native service.
            // Explicit --resume-setup enters the unchanged production coordinator.
            self.guestStatus.stringValue = @"Automatic setup paused for diagnostics";
            return;
        case VIMGuestRefreshStepOpenGLSetup:
            [self refreshOpenGLSetup];
            return;
        case VIMGuestRefreshStepStatusToolMissing:
            self.guestStatus.stringValue = @"Guest setup tool is missing";
            return;
        case VIMGuestRefreshStepCollectStatus:
            break;
    }
    self.state.guestPending = YES;
    [self.guestAgent connectWithCompletion:^(NSError *error) {
      VIMSession *session = weakSelf;
      if (!session.task.running)
          return;
      if (error) {
          [session finishGuestStatus:nil error:error];
          return;
      }
      if (session.machine.preMetalGuest) {
          VIMGuestAgent *agent = session.guestAgent;
          [agent collectInstalledOpenGLDesktopStatus:^(NSDictionary *report, NSError *failure) {
            VIMSession *current = weakSelf;
            if (current.guestAgent != agent || !current.task.running)
                return;
            if (![current statusPolicyForReport:report error:failure].needsTabletProbe) {
                [current finishGuestStatus:report error:failure];
                return;
            }
            // The installer uses its own fallback. At the installed
            // desktop, inspect the bound driver once on this boot.
            current.state.legacyTabletObserved = YES;
            [agent runExecutable:@"/usr/sbin/ioreg"
                       arguments:@[ @"-r", @"-c", @"IOHIDEventDriver", @"-d", @"1", @"-l", @"-w", @"0" ]
                         timeout:0
                      completion:^(NSDictionary *reply, NSError *ignored) {
                        VIMSession *live = weakSelf;
                        if (live.guestAgent != agent || !live.task.running)
                            return;
                        if (!ignored && [reply[@"exitcode"] isEqual:@0]) {
                            NSString *registry = [[NSString alloc] initWithData:reply[@"stdout"] ?: NSData.data
                                                                       encoding:NSUTF8StringEncoding];
                            NSNumber *trim = VIMObservedTabletTrim(registry);
                            if (trim)
                                live.tabletTrim = trim.unsignedIntegerValue;
                        }
                        [live finishGuestStatus:report error:nil];
                      }];
          }];
          return;
      }
      [session.guestAgent collectStatusWithTool:session.guestStatusTool
                                     completion:^(NSDictionary *report, NSError *failure) {
                                       [weakSelf finishGuestStatus:report error:failure];
                                     }];
    }];
}
- (void)scheduleGuestStatusRefreshAfter:(NSTimeInterval)delay {
    __weak VIMSession *weakSelf = self;
    [self.guestTimer invalidate];
    self.guestTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                      repeats:NO
                                                        block:^(NSTimer *timer) {
                                                          [weakSelf refreshGuestStatus];
                                                        }];
}
- (void)scheduleGuestStatusRetry {
    // Nothing else restarts this loop after finishGuestStatus cancels its timer.
    if (!self.task.running)
        return;
    [self scheduleGuestStatusRefreshAfter:15];
}
- (void)dismissSetupNotice {
    if (self.previewSetupNotice)
        return;
    [self removeSetupNotice];
}
- (void)removeSetupNotice {
    [self.setupNotice removeFromSuperview];
    self.setupNotice = nil;
    self.setupNoticeHeading = nil;
}
- (void)closeSetupNotice:(id)sender {
    self.closedSetupNoticeHeading = self.setupNoticeHeading;
    [self removeSetupNotice];
    [self.window makeFirstResponder:self.displayView];
}
- (void)showSetupNoticeAutomatic:(BOOL)automatic automaticLogin:(BOOL)automaticLogin restarting:(BOOL)restarting {
    VIMSetupNoticeCopy *copy = [[VIMSetupNoticeCopy alloc] initWithAutomatic:automatic
                                                              automaticLogin:automaticLogin
                                                                  restarting:restarting
                                                               preMetalGuest:self.machine.preMetalGuest];
    [self showSetupNoticeWithTitle:copy.title detail:copy.detail];
}
- (void)showSetupNoticeWithTitle:(NSString *)heading detail:(NSString *)message {
    if (self.previewSetupNotice && (self.setupNotice || self.closedSetupNoticeHeading))
        return;
    if ([self.closedSetupNoticeHeading isEqualToString:heading] || [self.setupNoticeHeading isEqualToString:heading])
        return;
    [self removeSetupNotice];
    NSView *content = self.window.contentView;
    VIMSetupNoticeView *notice = [VIMSetupNoticeView new];
    notice.wantsLayer = YES;
    notice.layer.shadowColor = NSColor.blackColor.CGColor;
    notice.layer.shadowOpacity = .32;
    notice.layer.shadowRadius = 14;
    notice.layer.shadowOffset = CGSizeMake(0, -5);
    notice.translatesAutoresizingMaskIntoConstraints = NO;
    NSVisualEffectView *material = [NSVisualEffectView new];
    material.material = NSVisualEffectMaterialHUDWindow;
    material.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    material.state = NSVisualEffectStateActive;
    material.wantsLayer = YES;
    material.layer.cornerRadius = 14;
    material.layer.cornerCurve = kCACornerCurveContinuous;
    material.layer.masksToBounds = YES;
    material.translatesAutoresizingMaskIntoConstraints = NO;
    [notice addSubview:material];
    NSTextField *title = [NSTextField labelWithString:heading];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    NSImageView *symbol = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"gearshape.fill"
                                                                    accessibilityDescription:nil]];
    symbol.contentTintColor = NSColor.secondaryLabelColor;
    NSStackView *header = [NSStackView stackViewWithViews:@[ symbol, title ]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 7;
    NSTextField *detail = [NSTextField wrappingLabelWithString:message];
    detail.textColor = NSColor.secondaryLabelColor;
    NSProgressIndicator *progress = [NSProgressIndicator new];
    progress.style = NSProgressIndicatorStyleBar;
    progress.controlSize = NSControlSizeSmall;
    progress.indeterminate = YES;
    progress.accessibilityLabel = @"Setup in progress";
    NSStackView *labels = [NSStackView stackViewWithViews:@[ header, progress, detail ]];
    labels.orientation = NSUserInterfaceLayoutOrientationVertical;
    labels.alignment = NSLayoutAttributeLeading;
    labels.spacing = 6;
    labels.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *close = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill"
                                                          accessibilityDescription:@"Close Setup Notice"]
                                         target:self
                                         action:@selector(closeSetupNotice:)];
    close.bordered = NO;
    close.toolTip = @"Close Setup Notice";
    [close setAccessibilityLabel:@"Close Setup Notice"];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [material addSubview:labels];
    [material addSubview:close];
    notice.closeButton = close;
    [content addSubview:notice positioned:NSWindowAbove relativeTo:self.displayView];
    NSLayoutConstraint *preferredWidth = [notice.widthAnchor constraintEqualToConstant:420];
    preferredWidth.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        preferredWidth, [notice.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [notice.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24],
        [notice.widthAnchor constraintLessThanOrEqualToAnchor:content.widthAnchor constant:-32],
        [material.leadingAnchor constraintEqualToAnchor:notice.leadingAnchor],
        [material.trailingAnchor constraintEqualToAnchor:notice.trailingAnchor],
        [material.topAnchor constraintEqualToAnchor:notice.topAnchor],
        [material.bottomAnchor constraintEqualToAnchor:notice.bottomAnchor],
        [labels.leadingAnchor constraintEqualToAnchor:notice.leadingAnchor constant:20],
        [labels.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-10],
        [labels.topAnchor constraintEqualToAnchor:notice.topAnchor constant:16],
        [labels.bottomAnchor constraintEqualToAnchor:notice.bottomAnchor constant:-16],
        [close.trailingAnchor constraintEqualToAnchor:notice.trailingAnchor constant:-12],
        [close.topAnchor constraintEqualToAnchor:notice.topAnchor constant:10],
        [close.widthAnchor constraintEqualToConstant:24], [close.heightAnchor constraintEqualToConstant:24],
        [detail.widthAnchor constraintEqualToAnchor:labels.widthAnchor],
        [progress.widthAnchor constraintEqualToAnchor:labels.widthAnchor]
    ]];
    [progress startAnimation:nil];
    self.setupNotice = notice;
    self.setupNoticeHeading = heading;
}
- (void)refreshOpenGLSetup {
    self.state.guestPending = YES;
    __weak VIMSession *weakSelf = self;
    [self.openGLSetup advance:^(NSDictionary *outcome, NSError *error) {
      VIMSession *session = weakSelf;
      if (!session)
          return;
      session.state.guestPending = NO;
      if (!session.task.running || session.state.shutdownRequested)
          return;
      if (error) {
          [session dismissSetupNotice];
          session.guestStatus.stringValue = error.localizedDescription;
          VIMPresentError(error, session.window);
          return; // no ambiguous automatic retry
      }
      VIMOpenGLSetupOutcome *decision = [[VIMOpenGLSetupOutcome alloc] initWithOutcome:outcome];
      NSString *waiting = [decision waitingMessageForOSName:VIMOperatingSystemName(session.machine.guest)];
      switch (decision.step) {
          case VIMOpenGLSetupStepAskForPassword:
              [session askForOpenGLSetupPasswordForUser:outcome[@"Username"]];
              break;
          case VIMOpenGLSetupStepMonitorDesktop:
              [session dismissSetupNotice];
              if (decision.leftSystemUnchanged)
                  [session logNote:@"Automatic OpenGL setup left the current system unchanged; "
                                   @"continuing desktop monitoring."];
              session.state.openGLDesktopMonitoring = YES;
              [session refreshGuestStatus];
              break;
          case VIMOpenGLSetupStepInstallerRunning:
              [session dismissSetupNotice];
              session.guestStatus.stringValue = waiting;
              break;
          case VIMOpenGLSetupStepRestart:
              if (!session.openGLRestartAttempted)
                  [session restartForOpenGLSetup:outcome decision:decision];
              break;
          case VIMOpenGLSetupStepFinish:
              [session finishOpenGLSetupWithReport:outcome[@"Report"]];
              break;
          case VIMOpenGLSetupStepWaitAndAskAgain:
              session.guestStatus.stringValue = waiting;
              [session scheduleGuestStatusRetry];
              break;
      }
    }];
}
- (void)askForOpenGLSetupPasswordForUser:(NSString *)username {
    [self dismissSetupNotice];
    NSAlert *alert = [NSAlert new];
    VIMSetInstallerAlertIcon(alert, self.machine.guest);
    alert.messageText = @"Enter the virtual Mac’s password";
    alert.informativeText = [NSString
        stringWithFormat:@"Enter the password you chose for “%@” in this virtual Mac to resume its saved setup. "
                         @"Your existing account won’t be replaced. This password won’t be saved on this Mac.",
                         username ?: @""];
    NSSecureTextField *password = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    password.placeholderString = @"Virtual Mac password";
    alert.accessoryView = password;
    [alert addButtonWithTitle:@"Continue"];
    [alert addButtonWithTitle:@"Not Now"];
    alert.window.initialFirstResponder = password;
    self.guestStatus.stringValue = @"A password is needed to resume setup";
    VIMPresentAlert(alert, self.window, ^(NSModalResponse response) {
      NSString *value = response == NSAlertFirstButtonReturn ? password.stringValue : nil;
      password.stringValue = @"";
      if (!value || !self.task.running || self.state.shutdownRequested)
          return;
      NSError *failure = nil;
      if (![self.openGLSetup providePassword:value error:&failure]) {
          VIMPresentError(failure, self.window);
          return;
      }
      [self refreshOpenGLSetup];
    });
}
- (void)restartForOpenGLSetup:(NSDictionary *)outcome decision:(VIMOpenGLSetupOutcome *)decision {
    void (^restart)(void) = ^{
      if (!self.task.running || self.state.shutdownRequested)
          return;
      NSError *failure = nil;
      if (![self.machine prepareOpenGLRestartWithReport:outcome[@"Report"] error:&failure]) {
          [self dismissSetupNotice];
          VIMPresentError(failure, self.window);
          return;
      }
      self.openGLRestartAttempted = YES;
      [self applyLifecycleEvent:VIMSessionEventGuestRebootExpected];
      [self updateInstallationActivity];
      self.guestStatus.stringValue = @"Finishing setup — restarting this Mac…";
      if (decision.showsRestartNotice) {
          NSDictionary *profile = [NSDictionary
              dictionaryWithContentsOfURL:[self.machine.URL URLByAppendingPathComponent:@"State/AutomaticSetup.plist"]];
          [self showSetupNoticeAutomatic:decision.automatic
                          automaticLogin:[(profile[@"AutomaticLogin"] ?: @YES) boolValue]
                              restarting:YES];
      }
      [self.guestAgent requestRestartWithCompletion:^(NSError *issue) {
        if (!issue) {
            NSError *saveError = nil;
            [self.machine recordOpenGLRestartAcknowledged:&saveError];
            if (saveError)
                VIMPresentError(saveError, self.window);
        } else if (self.task.running) {
            [self dismissSetupNotice];
            self.guestStatus.stringValue = @"Restart was not confirmed. Restart from the Apple menu to "
                                           @"continue setup. Your setup records were retained.";
        }
      }];
    };
    if ([decision restartsWithoutAskingWhenCreatingGuest:VIMCreatingGuestFromArguments()]) {
        restart();
        return;
    }
    [self dismissSetupNotice];
    NSAlert *alert = [NSAlert new];
    VIMSetAppAlertIcon(alert);
    alert.messageText = decision.restartPromptTitle;
    alert.informativeText = decision.restartPromptDetail;
    [alert addButtonWithTitle:@"Restart"];
    [alert addButtonWithTitle:@"Later"];
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse result) {
                    if (result == NSAlertFirstButtonReturn)
                        restart();
                    else if (decision.monitorsDesktopIfDeclined) {
                        self.state.openGLDesktopMonitoring = YES;
                        [self refreshGuestStatus];
                    }
                  }];
}
- (void)finishOpenGLSetupWithReport:(NSDictionary *)report {
    [self dismissSetupNotice];
    NSError *failure = nil;
    if (![self.machine finishOpenGLSetupWithReport:report error:&failure]) {
        VIMPresentError(
            failure
                ?: VIMSessionError(
                       @"Setup could not yet be verified. Its installer and recovery records were retained."),
            self.window);
        return;
    }
    self.completionGuestReport = report;
    self.openGLLargeResizeReady = YES;
    self.lastRequestedSize = NSZeroSize;
    [self scheduleResize];
    self.guestStatus.stringValue = @"Graphics support is ready";
    [self retireOpenGLSetupDiscWithReport:report];
    [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
    // The persistent receipt ends setup work for this boot. On a later
    // boot the guest bootstrap checks native files for update repair.
    self.state.openGLDesktopMonitoring = YES;
    [self refreshGuestStatus];
}
- (void)retireOpenGLSetupDiscWithReport:(NSDictionary *)report {
    if (!self.openGLSetupMediaAttached)
        return;
    NSURL *receipt = [self.machine.URL URLByAppendingPathComponent:@"State/LegacySetupMedia.plist"];
    [self.guestAgent retireSetupDiscOwnedBy:[NSDictionary dictionaryWithContentsOfURL:receipt]
                          machineIdentifier:self.machine.configuration[@"Identifier"]
                                     report:report
                                    control:self.control
                                    ejected:^{
                                      self.openGLSetupMediaAttached = NO;
                                    }];
}
- (BOOL)prepareMavericksSMBForBoot:(NSString *)boot {
    if (![self.machine.guest isEqual:@"mavericks"] || [self.mavericksSMBCheckedBoot isEqual:boot] ||
        self.state.shutdownRequested)
        return NO;
    self.mavericksSMBCheckedBoot = boot;
    NSURL *tool = VIMGuestFileURL(@"OpenGLGuests/mavericks/mavericks-smb-compat");
    NSURL *allocator = VIMGuestFileURL(@"GuestTools/codesign_allocate");
    if (![tool checkResourceIsReachableAndReturnError:nil] || ![allocator checkResourceIsReachableAndReturnError:nil])
        return NO;
    self.state.guestPending = YES;
    VIMGuestAgent *agent = self.guestAgent;
    __weak VIMSession *weakSelf = self;
    [agent applySMBCompatibilityTool:tool
                           allocator:allocator
                          completion:^(NSString *failure) {
                            VIMSession *session = weakSelf;
                            if (session.guestAgent != agent || !session.task.running)
                                return;
                            session.state.guestPending = NO;
                            if (failure)
                                [session
                                    logNote:@"Mavericks File Sharing compatibility could not be applied: %@", failure];
                            [session refreshGuestStatus];
                          }];
    return YES;
}
- (void)finishGuestStatus:(NSDictionary *)report error:(NSError *)error {
    self.state.guestPending = NO;
    if (!self.task.running)
        return;
    // Asked afresh at each step: the steps below change the flags later steps read.
    VIMGuestStatusPolicy * (^policy)(void) = ^VIMGuestStatusPolicy * {
      return [self statusPolicyForReport:report error:error];
    };
    NSArray *previousAddresses = self.guestIPAddresses;
    if (policy().consoleUserChanged) {
        [self.clipboard stop];
        self.clipboard = nil;
        self.clipboardConfiguredBoot = nil;
        self.state.consoleUID = policy().reportedConsoleUID;
        self.clipboardRetryAfter = nil;
        self.state.usernameBoot = nil;
        // Preserve an explicitly entered Remote Login account while no
        // console user is known; a fresh valid observation replaces it.
    }
    self.guestIPAddresses = [policy() guestAddressesReplacing:previousAddresses
                                                   macAddress:VIMNetworkMACAddress(self.machine.configuration)
                                                     isUsable:^BOOL(NSString *address) {
                                                       return VIMNetworkUsableIPv4(address);
                                                     }];
    if (![previousAddresses ?: @[] isEqual:self.guestIPAddresses ?: @[]])
        [NSNotificationCenter.defaultCenter postNotificationName:@"VIMNetworkChanged" object:self.machine];
    if (self.machine.preMetalGuest) {
        NSString *boot = [report[@"BootSessionUUID"] isKindOfClass:NSString.class] ? report[@"BootSessionUUID"] : nil;
        VIMGuestStatusPolicy *preMetal = policy();
        BOOL desktop = preMetal.preMetalDesktopReady;
        self.guestStatus.stringValue =
            desktop ? [NSString stringWithFormat:@"%@ %@", VIMOperatingSystemName(self.machine.guest),
                                                 report[@"ProductVersion"] ?: @""]
                    : @"Waiting for guest desktop services…";
        if (desktop)
            [self applyLifecycleEvent:VIMSessionEventDesktopReached];
        if (desktop && boot.length) {
            if ([self prepareMavericksSMBForBoot:boot])
                return;
            NSString *username = report[@"ConsoleUsername"];
            if ([username isKindOfClass:NSString.class] && username.length) {
                self.state.usernameBoot = boot;
                NSString *key = [@"VIMGuestUsername-" stringByAppendingString:self.machine.URL.path];
                BOOL changed = ![[NSUserDefaults.standardUserDefaults stringForKey:key] isEqual:username];
                [NSUserDefaults.standardUserDefaults setObject:username forKey:key];
                if (changed)
                    [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
            }
            self.resizeArmed = YES;
            if (![self.state.displaySizedBoot isEqual:boot]) {
                self.state.displaySizedBoot = boot;
                self.lastRequestedSize = NSZeroSize;
                [self scheduleResize];
            }
            [self enforceGuestSleepPolicyForBoot:boot
                                 nativeIdleGuard:[report[@"IdleSleepGuardRegistered"] isEqual:@YES]];
            [self updateClipboardForBoot:boot];
        }
        [self scheduleGuestStatusRefreshAfter:preMetal.preMetalRefreshInterval];
        return; // Desktop evidence never authorizes modern Metal patching.
    }
    if (self.completionGuestReport && (error || ![VIMMachineModel report:report
                                                    stillMatchesCompletionReport:self.completionGuestReport]))
        self.completionGuestReport = nil;
    NSString *message = nil;
    if (error) {
        // A stock guest has no agent until its VirtIO driver/launchd are ready.
        // Keep the framebuffer/input live and retry without rebooting the VM.
        message = error.localizedDescription;
        self.guestStatus.stringValue = @"Waiting for macOS guest services…";
    } else if (!policy().isFromThisGuest) {
        message = @"The guest version does not match this Mac’s configuration.";
        self.guestStatus.stringValue = message;
    } else {
        NSString *version = [report[@"ProductVersion"] isKindOfClass:NSString.class] ? report[@"ProductVersion"] : @"";
        BOOL installed = [VIMMachineModel reportIsLiveInstalledSystem:report];
        self.guestStatus.stringValue =
            [NSString stringWithFormat:@"%@ %@%@", VIMOperatingSystemName(self.machine.guest), version,
                                       installed ? @"" : @" — setup in progress"];
        // Evidence only. Never modify InstallerMedia/boot routing here: a live
        // desktop is not proof that the required patch transaction succeeded.
        NSDictionary *record = @{
            @"ObservedAt" : NSDate.date,
            @"Session" : self.runtimeDirectory.lastPathComponent,
            @"Transport" : self.guestAgent.transportName,
            @"PrivilegedAgentVerified" : @YES,
            @"Report" : report
        };
        NSError *saveError = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0
                                                                   error:&saveError];
        if (data)
            [data writeToURL:[self.machine.URL URLByAppendingPathComponent:@"State/GuestStatus.plist"]
                     options:NSDataWritingAtomic
                       error:&saveError];
        message = saveError ? saveError.localizedDescription : self.guestStatus.stringValue;
    }
    self.guestStatus.toolTip = message;
    if (![message isEqual:self.lastGuestMessage]) {
        self.lastGuestMessage = message;
        [self logNote:@"Guest status: %@", message];
    }
    [self.guestTimer invalidate];
    if (policy().mayCheckNativeDisplay) {
        NSError *nativeError = nil;
        if ([self.machine prepareNativeBigSurDisplayWithGuestReport:report error:&nativeError]) {
            [self logNote:@"Installed Big Sur has native PVG; switching Setup Assistant to "
                          @"accelerated graphics. Guest patches and installer cleanup remain pending."];
            [self handoffToGraphics];
            self.guestStatus.stringValue = @"Starting native Big Sur graphics for Setup Assistant…";
            return;
        }
        if (nativeError) {
            self.guestStatus.stringValue = nativeError.localizedDescription;
            // The save can succeed once the library has room again.
            [self scheduleGuestStatusRetry];
            return;
        }
    }
    if (policy().mayAdvanceModernSetup) {
        self.state.guestPending = YES;
        NSString *runtime = self.runtimeDirectory;
        __weak VIMSession *weakSelf = self;
        [self.modernSetup advanceReport:report
                             completion:^(NSDictionary *outcome, NSError *failure) {
                               VIMSession *session = weakSelf;
                               if (!session.task.running || ![session.runtimeDirectory isEqual:runtime])
                                   return;
                               session.state.guestPending = NO;
                               if (failure) {
                                   [session dismissSetupNotice];
                                   NSString *message = failure.localizedDescription;
                                   session.guestStatus.stringValue = message;
                                   if ([session.guestSessionState presentsSetupFailure:message]) {
                                       session.state.presentedSetupFailures =
                                           [session.state.presentedSetupFailures setByAddingObject:message];
                                       VIMPresentError(failure, session.window);
                                   }
                                   // Each step is journaled and rechecks its target, and a dispatched or failed install
                                   // isn't redone.
                                   [session scheduleGuestStatusRetry];
                                   return;
                               }
                               if ([outcome[@"Handled"] isEqual:@YES]) {
                                   session.guestStatus.stringValue = outcome[@"Message"] ?: @"Installing macOS…";
                                   if ([outcome[@"Restart"] isEqual:@YES]) {
                                       [session handoffToGraphics];
                                       // First-boot shutdown may wait for native cache/service
                                       // work. Keep the one acknowledged handoff pending until
                                       // actual exit; do not expire it and dispatch another one.
                                       [session.handoffTimer invalidate];
                                       session.handoffTimer = nil;
                                       session.guestStatus.stringValue =
                                           outcome[@"Message"] ?: @"Restarting to sign in…";
                                       return;
                                   }
                                   [session scheduleGuestStatusRefreshAfter:15];
                               } else {
                                   [session dismissSetupNotice];
                                   session.state.modernSetupReportActive = YES;
                                   [session finishGuestStatus:report error:nil];
                                   session.state.modernSetupReportActive = NO;
                               }
                             }];
        return;
    }
    NSString *boot = [report[@"BootSessionUUID"] isKindOfClass:NSString.class] ? report[@"BootSessionUUID"] : nil;
    BOOL priorBootPolicy =
        [VIMGuestBootPolicy readyAtURL:[self.machine.URL URLByAppendingPathComponent:@"State/BootPolicy.plist"]
                                 guest:self.machine.guest
                            identifier:self.machine.configuration[@"Identifier"]];
    if ([policy()
            needsBootPolicyCheckWithPolicyReady:priorBootPolicy
                           bootingGuestFirmware:[NSProcessInfo.processInfo.arguments containsObject:@"--guest-efi"]]) {
        // Before graphics preparation's normal restart, publish/verify the
        // one guest preference needed by identity-preserving boot firmware.
        // A previously verified, same-volume guest may be checked before the
        // desktop: the missing preference can itself prevent WindowServer.
        // Existing guests are not restarted behind the user's back.
        self.state.bootPolicyCheckedBoot = boot;
        self.state.bootPolicyPending = YES;
        self.guestStatus.stringValue = @"Preparing guest privacy compatibility…";
        NSString *runtime = self.runtimeDirectory;
        __weak VIMSession *weakSelf = self;
        [VIMGuestBootPolicy
            prepareWithAgent:self.guestAgent
                      report:report
                  identifier:self.machine.configuration[@"Identifier"]
                     journal:[self.machine.URL URLByAppendingPathComponent:@"State/BootPolicy.plist"]
                       tools:VIMGuestFileURL(@"GuestTools")
                  completion:^(BOOL ready, NSError *failure) {
                    VIMSession *session = weakSelf;
                    if (!session.task.running || ![session.runtimeDirectory isEqual:runtime])
                        return;
                    session.state.bootPolicyPending = NO;
                    NSString *message = ready ? @"Guest privacy compatibility verified." : failure.localizedDescription;
                    [session
                        logNote:@"Boot policy: %@", message ?: @"Verification did not finish; legacy boot retained."];
                    NSDictionary *saved = [NSDictionary
                        dictionaryWithContentsOfURL:[session.machine.URL
                                                        URLByAppendingPathComponent:@"State/BootPolicy.plist"]];
                    if (ready && [VIMMachineModel report:report bootPolicyRepairNeedsRestart:saved]) {
                        // amfid/WindowServer may already have cached the earlier
                        // policy. Restart only a known repaired, pre-desktop boot;
                        // use the normal shutdown handoff, never a hard reset.
                        [session handoffToGraphics];
                        session.guestStatus.stringValue = @"Guest compatibility restored — restarting this Mac…";
                        return;
                    }
                    // Collect a fresh boot/build identity after the operation,
                    // never feed a stale report back into installation admission.
                    [session refreshGuestStatus];
                  }];
        return;
    }
    if (policy().needsDisplayResize) {
        // Guest preferences can restore a saved 1× mode after the initial
        // connection. Reassert the current window's backing size once at login.
        self.state.displaySizedBoot = boot;
        self.lastRequestedSize = NSZeroSize;
        [self scheduleResize];
    }
    if (!error)
        [self enforceGuestSleepPolicyForBoot:boot nativeIdleGuard:[report[@"IdleSleepGuardRegistered"] isEqual:@YES]];
    // Reserve initial graphics staging before ancillary display/clipboard
    // helpers can acquire the same agent's transfer owner. Big Sur already
    // has native PVG at this first desktop, unlike unaccelerated older guests.
    if (policy().mayClaimAutomaticInstallation) {
        NSError *claimError = nil;
        if ([self.machine claimAutomaticInstallationWithGuestReport:report error:&claimError]) {
            self.preparationRequested = YES;
            self.installationRequested = YES;
            self.automaticInstallation = YES;
            [self logNote:@"macOS setup completed; beginning initial graphics installation."];
        } else if (claimError)
            self.guestStatus.stringValue = claimError.localizedDescription;
    }
    if (policy().needsDisplayPowerBridge)
        [self updateBridgeForBoot:boot displayPowerOnly:YES];
    if (policy().needsConsoleUsername) {
        // Remote Login needs the guest account's short name. Learn it from the
        // signed-in console user once per boot/session; invalidate it when
        // the console owner changes. Settings still asks before first login.
        self.state.usernameBoot = boot;
        NSNumber *expectedUID = self.state.consoleUID;
        NSString *runtime = self.runtimeDirectory;
        __weak VIMSession *weakSelf = self;
        [self.guestAgent
            runExecutable:@"/usr/bin/stat"
                arguments:@[ @"-f", @"%u %Su", @"/dev/console" ]
                  timeout:15
               completion:^(NSDictionary *result, NSError *failure) {
                 VIMSession *session = weakSelf;
                 if (!session.task.running || ![session.runtimeDirectory isEqual:runtime] ||
                     ![session.state.usernameBoot isEqual:boot] || ![session.state.consoleUID isEqual:expectedUID])
                     return;
                 NSString *text = [[NSString alloc] initWithData:result[@"stdout"] ?: NSData.data
                                                        encoding:NSUTF8StringEncoding];
                 NSString *username = !failure && [result[@"exitcode"] isEqual:@0]
                                          ? [VIMMachineModel consoleUsernameFromStatOutput:text expectedUID:expectedUID]
                                          : nil;
                 if (!username) {
                     session.state.usernameBoot = nil;
                     return;
                 }
                 [NSUserDefaults.standardUserDefaults
                     setObject:username
                        forKey:[@"VIMGuestUsername-" stringByAppendingString:session.machine.URL.path]];
                 [session updateClipboardForBoot:boot];
               }];
    }
    NSURL *installJournal = [self.machine.URL URLByAppendingPathComponent:@"State/GuestInstallation.plist"];
    if (policy().needsUpdateRepairCheck)
        self.state.verifiedUpdateRepair = [self.machine canRepairUpdatedSystemWithGuestReport:report error:nil];
    if (policy().mayClaimUpdateRepair) {
        NSError *claimError = nil;
        if ([self.machine claimAutomaticUpdateRepairWithGuestReport:report error:&claimError]) {
            self.state.repairRequested = YES;
            self.state.verifiedUpdateRepair = YES;
            [self logNote:@"Guest macOS build changed; beginning graphics repair from the "
                          @"updated system files."];
        } else if (claimError) {
            self.guestStatus.stringValue = claimError.localizedDescription;
            [self logNote:@"Automatic update repair: %@", claimError.localizedDescription];
        }
    }
    if (policy().mayBeginRepair) {
        self.state.repairRequested = NO;
        self.preparing = YES;
        self.completionGuestReport = nil;
        void (^beginRepair)(NSError *) = ^(NSError *failure) {
          self.preparing = NO;
          if (failure) {
              self.repairArchivePending = NO;
              self.state.updateRepairHeld = YES;
              self.guestStatus.stringValue = failure.localizedDescription;
              VIMPresentError(failure, self.window);
              [self scheduleGuestStatusRetry];
              return;
          }
          if (!self.task.running)
              return;
          self.state.reconciledBoot = nil;
          self.preparationRequested = YES;
          self.installationRequested = YES;
          [self refreshGuestStatus];
        };
        // Imported development VMs may predate transactional installation.
        // A missing receipt is not a malformed receipt: create a new fully
        // backed-up transaction, without inventing a successful old outcome.
        // Existing records must still pass reconciliation before any repair.
        if ([NSFileManager.defaultManager fileExistsAtPath:installJournal.path]) {
            self.repairArchivePending = YES;
            NSDictionary *updated =
                [self.machine canRepairUpdatedSystemWithGuestReport:report error:nil] ? report : nil;
            [VIMGuestInstallation checkForRepairWithAgent:self.guestAgent
                                                  journal:installJournal
                                            updatedSystem:updated
                                               completion:beginRepair];
        } else
            beginRepair(nil);
        return;
    }
    if ([policy()
            needsReconciliationWithJournalExists:[NSFileManager.defaultManager fileExistsAtPath:installJournal.path]]) {
        self.state.reconciliationAttempts = policy().nextReconciliationAttempt;
        self.preparing = YES;
        self.state.reconciledBoot = boot;
        self.completionGuestReport = nil;
        NSDictionary *prior = [NSDictionary dictionaryWithContentsOfURL:installJournal];
        BOOL changed = [VIMMachineModel report:report reconciliationVerifiesAfterRebootWithJournal:prior];
        __weak VIMSession *weakSession = self;
        [VIMGuestInstallation
            reconcileWithAgent:self.guestAgent
                       journal:installJournal
             verifyAfterReboot:changed
                    completion:^(NSDictionary *result, NSError *failure) {
                      VIMSession *session = weakSession;
                      if (!session)
                          return;
                      session.preparing = NO;
                      if (!session.task.running)
                          return;
                      BOOL verified = !failure && [VIMMachineModel report:report isVerifiedByReconciliation:result];
                      // Desktop availability can precede Metal readiness. Permit at
                      // most three read-only checks per boot, separated by the normal
                      // 60-second timer. Never repeat installation or relax hashes.
                      if (verified)
                          session.state.reconciliationAttempts = 3;
                      if (verified && session.machine.configuration[@"InstallerMedia"]) {
                          session.completionGuestReport = report;
                          // The owned backend remains open until shutdown/cleanup,
                          // but its installer volumes need not stay on the desktop.
                          __weak VIMSession *weakCurrent = session;
                          [session.guestAgent ejectEmulatedVolumes:@[
                              @"/Volumes/macOS Base System", @"/Volumes/Install macOS Mojave",
                              @"/Volumes/Install macOS Catalina", @"/Volumes/Install macOS Big Sur"
                          ]
                                                             while:^BOOL {
                                                               VIMSession *current = weakCurrent;
                                                               return current.task.running &&
                                                                      current.completionGuestReport;
                                                             }];
                      }
                      NSString *message = failure.localizedDescription
                                              ?: [VIMMachineModel reconciliationMessageForResult:result
                                                                                        verified:verified];
                      session.guestStatus.stringValue = message;
                      [session logNote:@"Reconciliation: %@", message];
                      // This boot checks no more, so the run could only wait forever.
                      if (!verified && session.state.reconciliationAttempts >= 3)
                          VIMFailCreateGuest(message);
                      // Console discovery may have completed while this read-only
                      // check held preparing=YES. Resume clipboard provisioning now,
                      // not at the next minute-long desktop status refresh. Do not
                      // let a stale callback configure another boot's GUI session.
                      if ([session.state.reconciledBoot isEqual:boot]) {
                          [session updateClipboardForBoot:boot];
                          [session restoreDisplaySelectionForBoot:boot];
                      }
                      [session scheduleGuestStatusRefreshAfter:60];
                    }];
        return;
    }
    if (policy().mayBeginPreparation) {
        self.preparationRequested = NO;
        self.preparing = YES;
        self.window.subtitle = @"Finishing setup…";
        NSURL *runtime = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Runtime"];
        __weak VIMSession *weakSession = self;
        [VIMGuestPreparation prepareWithAgent:self.guestAgent
            report:report
            runtime:runtime
            journal:[self.machine.URL URLByAppendingPathComponent:@"State/GuestPreparation.plist"]
            control:self.control
            allowHeadlessRepair:self.state.verifiedUpdateRepair && ![report[@"DesktopRunning"] isEqual:@YES]
            progress:^(NSString *progress) {
              VIMSession *current = weakSession;
              current.guestStatus.stringValue = progress;
              if (current.state.verifiedUpdateRepair && ![report[@"DesktopRunning"] isEqual:@YES]) {
                  current.displayView.displaySleeping = YES;
                  current.statePanel.hidden = NO;
                  current.stateAction.hidden = YES;
                  current.stateLabel.stringValue =
                      [progress stringByAppendingString:@"\nKeep this Mac running while graphics support is restored."];
              }
            }
            completion:^(NSDictionary *receipt, NSError *failure) {
              VIMSession *session = weakSession;
              if (!session)
                  return;
              session.preparing = NO;
              session.window.subtitle = @"";
              if (!session.task.running)
                  return;
              session.guestProgress = [VIMGuestProgress progressWithAgent:session.guestAgent
                                                                  receipt:receipt[@"GuestProgress"]];
              BOOL install = session.installationRequested;
              session.installationRequested = NO;
              if (install && !failure) {
                  session.preparing = YES;
                  session.guestStatus.stringValue = @"Installing graphics support — do not shut down this Mac…";
                  session.window.subtitle = @"Installing Graphics Drivers…";
                  if (!session.state.verifiedUpdateRepair)
                      [session showSetupNoticeAutomatic:NO automaticLogin:NO restarting:NO];
                  void (^applyPrepared)(NSError *) = ^(NSError *archiveError) {
                    if (archiveError) {
                        [session dismissSetupNotice];
                        session.preparing = NO;
                        session.window.subtitle = @"";
                        session.guestStatus.stringValue = archiveError.localizedDescription;
                        [session.guestProgress
                            updateMode:@"failed"
                              fraction:0
                               message:
                                   @"The previous installation record could not be preserved. Nothing was installed."
                            completion:nil];
                        session.state.updateRepairHeld = YES;
                        VIMPresentError(archiveError, session.window);
                        [session scheduleGuestStatusRetry];
                        return;
                    }
                    [VIMGuestInstallation
                        applyWithAgent:session.guestAgent
                           preparation:receipt
                               journal:[session.machine.URL
                                           URLByAppendingPathComponent:@"State/GuestInstallation.plist"]
                            completion:^(NSDictionary *outcome, NSError *installError) {
                              VIMSession *current = weakSession;
                              if (!current)
                                  return;
                              current.preparing = NO;
                              current.window.subtitle = @"";
                              [current dismissSetupNotice];
                              NSString *result = installError.localizedDescription
                                                     ?: @"Graphics files installed — restart required for verification";
                              current.guestStatus.stringValue = result;
                              if (installError) {
                                  BOOL restored = [outcome[@"Phase"] isEqual:@"rolled-back"];
                                  [current.guestProgress
                                      updateMode:restored ? @"failed" : @"working"
                                        fraction:restored ? 0 : -1
                                         message:
                                             restored
                                                 ? @"Setup couldn’t finish. The original system files were restored."
                                                 : @"Setup status couldn’t be confirmed. Keep this Mac running and "
                                                   @"check Session Details in the Light Click app."
                                      completion:nil];
                              }
                              [current logNote:@"Installation: %@", result];
                              if (installError)
                                  VIMFailCreateGuest(result);
                              current.state.reconciledBoot = nil;
                              switch ([[current statusPolicyForReport:report error:nil]
                                  followUpAfterInstallation:installError ? nil : outcome
                                   requiresInstallerDisplay:current.machine.requiresInstallerDisplay]) {
                                  case VIMInstallationFollowUpHandOff:
                                      [current handoffToGraphics];
                                      return;
                                  case VIMInstallationFollowUpOfferRestart:
                                      [current offerGraphicsRestart];
                                      return;
                                  case VIMInstallationFollowUpKeepPolling:
                                      break;
                              }
                              [current scheduleGuestStatusRefreshAfter:60];
                              // No unconditional reboot: uncertain outcomes and
                              // rollback must never be mistaken for success.
                            }];
                  };
                  // Keep the prior valid display handoff until preparation
                  // succeeds. Otherwise a staging-only failure incorrectly
                  // turns the next boot back into an unaccelerated installer.
                  if (session.repairArchivePending) {
                      session.repairArchivePending = NO;
                      [VIMGuestInstallation
                          archiveForRepairWithAgent:session.guestAgent
                                            journal:[session.machine.URL
                                                        URLByAppendingPathComponent:@"State/GuestInstallation.plist"]
                                      updatedSystem:([session.machine canRepairUpdatedSystemWithGuestReport:report
                                                                                                      error:nil]
                                                         ? report
                                                         : nil)completion:applyPrepared];
                  } else
                      applyPrepared(nil);
                  return;
              }
              NSString *message = failure.localizedDescription ?: @"Guest files prepared — installation pending";
              session.guestStatus.stringValue = message;
              if (!failure)
                  [session.guestProgress updateMode:@"complete"
                                           fraction:1
                                            message:@"Support files are prepared. No system files were installed."
                                         completion:nil];
              [session logNote:@"Preparation: %@", message];
              if (failure)
                  VIMFailCreateGuest(message);
              // Explicit request runs once. No automatic retry of uncertain writes.
              [session scheduleGuestStatusRefreshAfter:60];
            }];
        return;
    }
    if (policy().needsDesktopServices) {
        [self applyLifecycleEvent:VIMSessionEventDesktopReached];
        [self updateClipboardForBoot:boot];
        [self restoreDisplaySelectionForBoot:boot];
    }
    [self scheduleGuestStatusRefreshAfter:policy().refreshInterval];
}
- (void)restoreDisplaySelectionForBoot:(NSString *)boot {
    // Updating the PVG panel's pixel size does not select macOS's logical
    // 1x/2x mode. Reassert the saved selection once after login, using the same
    // console helper as the menu. Never poll or run a guest tool per resize.
    if (![self.guestSessionState allowsDisplaySelectionForBoot:boot] || !self.machine.hasPublishedGuestGraphics)
        return;
    NSString *runtime = self.runtimeDirectory;
    self.state.displaySelectedBoot = boot;
    [self applyDisplayMode:self.displayMode
                completion:^(NSDictionary *observed, NSError *failure) {
                  if (!self.task.running || ![runtime isEqual:self.runtimeDirectory])
                      return;
                  if (failure) {
                      self.state.displaySelectedBoot = nil;
                      // Retry only through the ordinary cold readiness pass. A slow TCG
                      // hot-plug must not become an immediate status/selection loop.
                      self.state.displaySelectionRetryAfter = [NSDate dateWithTimeIntervalSinceNow:60];
                      [self logNote:@"Initial display selection pending: %@", failure.localizedDescription];
                  } else
                      self.state.displaySelectionRetryAfter = nil;
                }];
}
- (void)refreshRunState {
    if (self.statusPending || !self.task.running)
        return;
    self.statusPending = YES;
    __weak VIMSession *weakSelf = self;
    [self.control execute:@"query-status"
                arguments:@{}
               completion:^(id result, NSError *error) {
                 VIMSession *session = weakSelf;
                 session.statusPending = NO;
                 if (!session.task.running)
                     return;
                 if (error) {
                     session.runStateQueryFailed = YES;
                     session.status.stringValue = error.localizedDescription;
                     return;
                 }
                 NSString *state = [result isKindOfClass:NSDictionary.class] ? result[@"status"] : nil;
                 if (![state isKindOfClass:NSString.class] ||
                     ([state isEqual:session.lastRunState] && !session.runStateQueryFailed))
                     return;
                 // Restore the visible status after a transient control timeout even if
                 // the VM stayed running throughout it. Preserve the last known sleep
                 // state while disconnected so input can still request a wakeup.
                 session.runStateQueryFailed = NO;
                 session.lastRunState = state;
                 [session updateInstallationActivity];
                 [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
                 session.displayView.displaySleeping = [VIMSessionRunState isDisplayAsleep:state];
                 session.statePanel.hidden = YES;
                 session.stateAction.hidden = YES;
                 session.status.stringValue = [VIMSessionRunState labelFor:state];
                 BOOL failed = [VIMSessionRunState isFailure:state];
                 if (failed) {
                     session.displayView.displaySleeping = YES;
                     session.statePanel.hidden = NO;
                     session.stateLabel.stringValue = [session.status.stringValue
                         stringByAppendingString:@". Open Controls → Session Details for more information."];
                 }
                 [session logNote:@"QEMU state: %@", state];
                 if (failed)
                     VIMFailCreateGuest(session.status.stringValue);
               }];
}
- (void)offerGraphicsRestart {
    if (self.guestProgress) {
        __weak VIMSession *weakSelf = self;
        if (VIMCreatingGuestFromArguments()) {
            // Answers the guest window's Restart button, which a --create-guest run never shows.
            [self.guestProgress updateMode:@"close"
                                  fraction:1
                                   message:@""
                                completion:^(NSError *closeError) {
                                  [weakSelf handoffToGraphics];
                                }];
            return;
        }
        self.preparing = YES;
        [self.guestProgress updateMode:@"restart"
                              fraction:1
                               message:@"Graphics support is installed. Restart your virtual Mac to activate it."
                            completion:^(NSError *error) {
                              VIMSession *session = weakSelf;
                              if (!session.task.running)
                                  return;
                              if (error) {
                                  session.preparing = NO;
                                  [session offerHostGraphicsRestart];
                                  return;
                              }
                              [session.guestProgress waitForRestartChoice:^(NSString *choice, NSError *failure) {
                                VIMSession *current = weakSelf;
                                if (!current.task.running)
                                    return;
                                current.preparing = NO;
                                if (failure) {
                                    current.guestStatus.stringValue = failure.localizedDescription;
                                    [current offerHostGraphicsRestart];
                                    return;
                                }
                                [current.guestProgress
                                    updateMode:@"close"
                                      fraction:1
                                       message:@""
                                    completion:^(NSError *closeError) {
                                      if ([choice isEqual:@"restart"])
                                          [current handoffToGraphics];
                                      else {
                                          current.guestStatus.stringValue =
                                              @"Graphics support installed. Restart when you’re ready to finish setup.";
                                          [current scheduleGuestStatusRefreshAfter:60];
                                      }
                                    }];
                              }];
                            }];
        return;
    }
    [self offerHostGraphicsRestart];
}
- (void)offerHostGraphicsRestart {
    if (VIMCreatingGuestFromArguments()) {
        [self handoffToGraphics];
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Restart to finish graphics setup?";
    alert.informativeText = @"Graphics support has been installed. Save your work before restarting this virtual Mac. "
                            @"You can also shut down and open it again later.";
    [alert addButtonWithTitle:@"Restart Now"];
    [alert addButtonWithTitle:@"Later"];
    VIMSetInstallerAlertIcon(alert, self.machine.guest);
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
                    if (response == NSAlertFirstButtonReturn && self.task.running)
                        [self handoffToGraphics];
                    else
                        self.guestStatus.stringValue =
                            @"Graphics support installed. Restart when you’re ready to finish setup.";
                  }];
}
- (void)handoffToGraphics {
    if (!self.guestSessionState.mayHandOff)
        return;
    self.automaticInstallation = NO;
    [self applyLifecycleEvent:VIMSessionEventHandoffRequested];
    self.guestStatus.stringValue = @"Graphics support installed — restarting this Mac…";
    __weak VIMSession *weakSelf = self;
    // Changing emulated display hardware needs a new QEMU process, not an
    // in-guest reboot. Never force termination if macOS cannot shut down.
    // A --create-guest run has nobody to finish a late shutdown by hand, and an emulated guest can be slow to stop.
    self.handoffTimer = [NSTimer
        scheduledTimerWithTimeInterval:VIMCreatingGuestFromArguments() ? 1800 : 180
                               repeats:NO
                                 block:^(NSTimer *timer) {
                                   [weakSelf
                                       cancelHandoffSaying:@"Shutdown is taking longer than expected. Shut down this "
                                                           @"Mac, then open it again to finish setup."];
                                 }];
    [self.guestAgent runExecutable:@"/sbin/shutdown"
                         arguments:@[ @"-h", @"now" ]
                           timeout:20
                        completion:^(NSDictionary *result, NSError *error) {
                          // The transport normally disappears during shutdown. Only a
                          // definite command failure cancels the handoff immediately.
                          VIMSession *session = weakSelf;
                          if (!error && result && ![result[@"exitcode"] isEqual:@0])
                              [session cancelHandoffSaying:@"Automatic shutdown failed. Shut down this Mac, then open "
                                                           @"it again to finish setup."];
                        }];
}
- (void)cancelHandoffSaying:(NSString *)message {
    [self applyLifecycleEvent:VIMSessionEventHandoffCancelled];
    [self.handoffTimer invalidate];
    if (!self.task.running)
        return;
    self.guestStatus.stringValue = message;
    VIMFailCreateGuest(message);
    [self refreshGuestStatus];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(startAgain:))
        item.state = self.task.running ? NSControlStateValueOn : NSControlStateValueOff;
    NSNumber *rule = [self.guestSessionState enablesMenuAction:NSStringFromSelector(item.action)
                                                  controlReady:self.shutdownButton.enabled];
    if (rule)
        return rule.boolValue;
    if (item.action == @selector(copyGuestIPAddress:))
        return self.task.running && self.state.networkLinkConnected &&
               [self.guestIPAddresses containsObject:item.representedObject];
    if (item.action == @selector(ejectOpticalMedia:))
        return !self.imageDrives.changePending &&
               [self.class imageRecordForMachine:self.machine
                                            slot:[item.representedObject unsignedIntegerValue]] != nil;
    if (item.action == @selector(changeRetinaMode:)) {
        item.state = [self.displayMode isEqual:@[ @"space", @"retina", @"scaled" ][item.tag]] ? NSControlStateValueOn
                                                                                              : NSControlStateValueOff;
        return !self.state.displayModePending && (item.tag != 1 || self.supportsRetinaDisplay);
    }
    if (item.action == @selector(changeDisplayScalingFilter:)) {
        item.state =
            [self.displayScalingFilter isEqual:item.representedObject] ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(showGuestDiagnostics:))
        return YES;
    BOOL idle = self.guestSessionState.graphicsActionsEnabled;
    BOOL recorded = [NSFileManager.defaultManager
        fileExistsAtPath:[self.machine.URL URLByAppendingPathComponent:@"State/GuestInstallation.plist"].path];
    if (item.action == @selector(openScreenSharing:))
        return self.guestAgentFree && [self.machine.editableConfiguration[@"ScreenSharingEnabled"] boolValue] &&
               [VIMMachineModel screenSharingURLForConfiguration:self.machine.configuration];
    if (item.action == @selector(checkGraphicsSetup:))
        return idle && recorded;
    if (item.action == @selector(finishGraphicsSetup:))
        return idle && VIMGuestHasTrait(self.machine.guest, VIMGuestTraitParavirtualizedGraphics);
    return YES;
}
- (void)menuWillOpen:(NSMenu *)menu {
    [self.displayView releasePressedKeys];
    // Toolbar menus can be opened without AppKit requesting menuNeedsUpdate.
    // Enumerate metadata at opening, just like the menu-bar Devices submenu.
    [self menuNeedsUpdate:menu];
}
- (NSMenu *)deviceMenuForKind:(NSString *)kind {
    VIMLiveDeviceMenu *menu = [[VIMLiveDeviceMenu alloc] initWithTitle:[kind isEqual:@"USB"] ? VIMUSBMenuTitle : kind];
    menu.deviceKind = menu.title;
    menu.delegate = self;
    if ([kind isEqual:@"USB"])
        [self populateUSBMenu:menu];
    else
        [self populateDeviceMenu:menu];
    return menu;
}
- (NSMenuItem *)addDeviceItem:(NSString *)title action:(SEL)action toMenu:(NSMenu *)menu {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    return item;
}
- (void)refreshAudioChoices {
    if (self.audioChoicesPending)
        return;
    self.audioChoicesPending = YES;
    __weak VIMSession *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSArray *outputs = VIMHostAudioDevices(NO), *inputs = VIMHostAudioDevices(YES);
      dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.audioOutputChoices = outputs;
        weakSelf.audioInputChoices = inputs;
        weakSelf.audioChoicesPending = NO;
      });
    });
}
- (void)populateDeviceMenu:(NSMenu *)menu {
    if ([menu isKindOfClass:VIMLiveDeviceMenu.class])
        menu.title = ((VIMLiveDeviceMenu *)menu).deviceKind;
    NSString *toolbarTitle = ToolbarMenuTitle(menu);
    [menu removeAllItems];
    WithToolbarMenuTitle(menu, toolbarTitle);
    NSDictionary *config = self.machine.editableConfiguration;
    if ([menu.title isEqual:@"CD/DVD"]) {
        [self addItems:[VIMDeviceMenus imagesMenuWithImages:[VIMSession connectedImagesForMachine:self.machine]
                                                  slotCount:VIMImageSlotCount]
                toMenu:menu];
    } else if ([menu.title isEqual:@"Network"]) {
        BOOL connected = self.task.running ? self.state.networkLinkConnected
                                           : (!config[@"NetworkConnected"] || [config[@"NetworkConnected"] boolValue]);
        [self addItems:[VIMDeviceMenus
                           networkMenuConnected:connected
                                           mode:VIMNetworkMode(self.task.running ? self.machine.configuration : config)
                                        running:self.task.running
                                      addresses:self.guestIPAddresses
                                  screenSharing:[VIMMachineModel screenSharingAvailableOnConfiguration:config]
                                screenSharingOn:[config[@"ScreenSharingEnabled"] boolValue]]
                toMenu:menu];
    } else if ([menu.title isEqual:@"Sound Output"] || [menu.title isEqual:@"Microphone"]) {
        BOOL input = [menu.title isEqual:@"Microphone"];
        [self addItems:[VIMDeviceMenus soundMenuForInput:input
                                                selected:VIMAudioSelection(config, input)
                                                 devices:input ? self.audioInputChoices : self.audioOutputChoices]
                toMenu:menu];
        [self refreshAudioChoices];
    } else if ([menu.title isEqual:@"Keyboard"]) {
        [self addItems:VIMDeviceMenus.keyboardMenu toMenu:menu];
    }
}
- (void)addItems:(NSArray<VIMDeviceMenuItem *> *)items toMenu:(NSMenu *)menu {
    for (VIMDeviceMenuItem *entry in items) {
        if (entry.isSeparator) {
            [menu addItem:NSMenuItem.separatorItem];
            continue;
        }
        NSMenuItem *item = [self addDeviceItem:entry.title
                                        action:entry.action ? NSSelectorFromString(entry.action) : nil
                                        toMenu:menu];
        item.enabled = entry.isEnabled;
        item.state = entry.isOn ? NSControlStateValueOn : NSControlStateValueOff;
        item.tag = entry.tag;
        item.representedObject = entry.representedObject;
        item.toolTip = entry.toolTip;
        if (entry.symbol)
            item.image = [NSImage imageWithSystemSymbolName:entry.symbol accessibilityDescription:nil];
    }
}
- (void)showOpticalSettings:(id)sender {
    [VIMMachineSettings showForMachine:self.machine section:@"Hardware" category:@"CD/DVD" window:self.window];
}
- (void)copyGuestIPAddress:(NSMenuItem *)sender {
    // The menu may have stayed open through a network change. Never copy a
    // stale address or a non-address represented object from another action.
    if (!self.task.running || !self.state.networkLinkConnected ||
        ![self.guestIPAddresses containsObject:sender.representedObject])
        return;
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:sender.representedObject forType:NSPasteboardTypeString];
}
- (void)changeNetworkConnection:(NSMenuItem *)sender {
    NSString *mode = sender.tag ? @[ @"shared", @"host", @"bridged" ][sender.tag - 1]
                                : VIMNetworkMode(self.machine.editableConfiguration);
    [VIMSession changeNetworkMode:mode
                        connected:sender.tag != 0
                          machine:self.machine
                           window:self.window
                       completion:^(NSError *error) {
                         if (error)
                             VIMPresentError(error, self.window);
                       }];
}
- (void)changeAudioChoice:(NSMenuItem *)sender {
    NSDictionary *choice = sender.representedObject;
    NSError *error = nil;
    BOOL input = [choice[@"Input"] boolValue];
    if ([VIMAudioSelection(self.machine.editableConfiguration, input) isEqual:choice[@"UID"]])
        return;
    if (![self.machine saveSettings:@{
            @"AudioEnabled" : @YES,
            (input ? @"AudioInputDevice" : @"AudioOutputDevice") : choice[@"UID"]
        }
                              error:&error]) {
        VIMPresentError(error, self.window);
        return;
    }
    if (self.task.running) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = input ? @"Restart to change the microphone" : @"Restart to change sound output";
        alert.informativeText = @"Your selection is saved. It will take effect the next time this virtual Mac starts.";
        [alert addButtonWithTitle:@"OK"];
        VIMPresentAlert(alert, self.window, nil);
    } else
        [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if ([menu isKindOfClass:VIMLiveDeviceMenu.class])
        menu.title = ((VIMLiveDeviceMenu *)menu).deviceKind;
    if ([menu.title isEqual:VIMUSBMenuTitle] || [menu.title isEqual:@"USB"])
        [self populateUSBMenu:menu];
    else if ([@[ @"CD/DVD", @"Network", @"Sound Output", @"Microphone", @"Keyboard" ] containsObject:menu.title])
        [self populateDeviceMenu:menu];
}
- (void)refreshUSBToolbar:(NSNotification *)notification {
    for (NSToolbarItem *top in self.window.toolbar.items) {
        if ([top.itemIdentifier isEqual:@"GuestUSB"] && [top isKindOfClass:NSMenuToolbarItem.class])
            [self populateUSBMenu:((NSMenuToolbarItem *)top).menu];
    }
}
/// Lists host devices; a checkmark means the device is connected to the guest.
- (void)populateUSBMenu:(NSMenu *)menu {
    NSString *toolbarTitle = ToolbarMenuTitle(menu);
    [menu removeAllItems];
    WithToolbarMenuTitle(menu, toolbarTitle);
    [self addItems:[VIMDeviceMenus usbMenuWithDevices:VIMHostUSBDevices()
                                             attached:self.usbAttached
                                              pending:self.usbOperationPending]
            toMenu:menu];
}
- (void)ensureUSBClient {
    if (!self.usbClient) {
        self.usbClient = [VIMUSBClient new];
        self.usbClient.useUSB2Storage = VIMGuestHasTrait(self.machine.guest, VIMGuestTraitUSB2StoragePassthrough);
    }
}
- (void)toggleUSBDevice:(NSMenuItem *)sender {
    if (self.usbOperationPending || !self.task.running)
        return;
    NSDictionary *device = sender.representedObject;
    NSString *identifier = device[@"Identifier"];
    if (!self.usbAttached)
        self.usbAttached = [NSMutableDictionary dictionary];
    __weak VIMSession *weakSelf = self;
    if (self.usbAttached[identifier]) {
        self.usbOperationPending = YES;
        [self.usbClient disconnectDevice:identifier
                                 control:self.control
                              completion:^(NSError *error) {
                                weakSelf.usbOperationPending = NO;
                                if (error)
                                    VIMPresentError(error, weakSelf.window);
                                else
                                    [weakSelf.usbAttached removeObjectForKey:identifier];
                              }];
        return;
    }
    NSMutableArray *protected =
        [NSMutableArray arrayWithObjects:NSBundle.mainBundle.bundleURL, VIMLibraryLocation.rootURL, nil];
    for (VIMSession *session in sessions.allValues)
        if (session.machine.URL)
            [protected addObject:session.machine.URL];
    NSError *failure = nil;
    NSDictionary *storage = VIMHostUSBStorageInfo(device, protected, &failure);
    if (!storage || [storage[@"Protected"] boolValue]) {
        VIMPresentError(failure
                            ?: VIMSessionError(@"This device contains Light Click, a virtual Mac, or its library and "
                                               @"cannot be unmounted. Move those files to another drive first."),
                        self.window);
        return;
    }
    void (^connect)(void) = ^{
      VIMSession *session = weakSelf;
      if (!session.task.running)
          return;
      session.usbOperationPending = YES;
      [session ensureUSBClient];
      [session.usbClient prepareWithCompletion:^(NSError *error) {
        if (error || !weakSelf.task.running) {
            weakSelf.usbOperationPending = NO;
            if (error)
                VIMPresentError(error, weakSelf.window);
            return;
        }
        [weakSelf.usbClient connectDevice:device
                                processID:weakSelf.task.processIdentifier
                                directory:weakSelf.runtimeDirectory
                                  control:weakSelf.control
                               completion:^(NSError *captureError) {
                                 weakSelf.usbOperationPending = NO;
                                 if (captureError)
                                     VIMPresentError(captureError, weakSelf.window);
                                 else
                                     weakSelf.usbAttached[identifier] = device[@"Name"];
                               }];
      }];
    };
    void (^requestAccess)(void (^)(void)) = ^(void (^next)(void)) {
      weakSelf.usbOperationPending = YES;
      VIMHostRequestUSBStorageAccess(device, protected, ^(NSError *error) {
        weakSelf.usbOperationPending = NO;
        if (error) {
            VIMPresentError(error, weakSelf.window);
            return;
        }
        if (weakSelf.task.running)
            next();
      });
    };
    if (![storage[@"MountedVolumes"] count]) {
        requestAccess(connect);
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Connect “%@” to this virtual Mac?", device[@"Name"]];
    alert.informativeText = @"Its disks must first be unmounted from this Mac. Save your work on this device before "
                            @"continuing. They’ll be available to the virtual Mac instead.";
    [alert addButtonWithTitle:@"Unmount and Connect"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Force Unmount…"];
    VIMPresentAlert(alert, self.window, ^(NSModalResponse response) {
      if (response == NSAlertSecondButtonReturn)
          return;
      void (^unmount)(BOOL) = ^(BOOL force) {
        requestAccess(^{
          weakSelf.usbOperationPending = YES;
          [weakSelf releaseUSBDisks:device
                          protected:protected
                              force:force
                         completion:^{
                           connect();
                         }];
        });
      };
      if (response == NSAlertFirstButtonReturn) {
          unmount(NO);
          return;
      }
      NSAlert *confirm = [NSAlert new];
      confirm.messageText = [NSString stringWithFormat:@"Force unmount “%@”?", device[@"Name"]];
      confirm.informativeText = @"Unsaved changes on this device may be lost. Close apps using it first if possible.";
      [confirm addButtonWithTitle:@"Force Unmount and Connect"];
      [confirm addButtonWithTitle:@"Cancel"];
      VIMPresentAlert(confirm, weakSelf.window, ^(NSModalResponse answer) {
        if (answer == NSAlertFirstButtonReturn)
            unmount(YES);
      });
    });
}
- (void)releaseUSBDisks:(NSDictionary *)device
              protected:(NSArray *)protected
                  force:(BOOL)force
             completion:(void (^)(void))completion {
    __weak VIMSession *weakSelf = self;
    VIMHostReleaseUSBDisks(device, protected, force, ^(NSError *error) {
      VIMSession *session = weakSelf;
      session.usbOperationPending = NO;
      if (!error) {
          completion();
          return;
      }
      if (force) {
          VIMPresentError(error, session.window);
          return;
      }
      NSAlert *alert = [NSAlert new];
      alert.messageText = [NSString stringWithFormat:@"“%@” couldn’t be unmounted", device[@"Name"]];
      alert.informativeText = @"Close apps using this device and try again, or force unmount it to connect it to the "
                              @"virtual Mac. Forcing an unmount can lose unsaved changes on the device.";
      [alert addButtonWithTitle:@"Cancel"];
      [alert addButtonWithTitle:@"Force Unmount and Connect"];
      VIMPresentAlert(alert, session.window, ^(NSModalResponse answer) {
        if (answer == NSAlertSecondButtonReturn && weakSelf.task.running) {
            weakSelf.usbOperationPending = YES;
            [weakSelf releaseUSBDisks:device protected:protected force:YES completion:completion];
        }
      });
    });
}
- (void)releaseGuestKeys {
    [self.displayView releasePressedKeys];
}
- (void)sendShortcut:(NSArray<NSString *> *)keys {
    [self releaseGuestKeys];
    NSMutableArray *codes = [NSMutableArray array];
    for (NSString *key in keys)
        [codes addObject:@{@"type" : @"qcode", @"data" : key}];
    [self.control execute:@"send-key"
                arguments:@{@"keys" : codes, @"hold-time" : @50}
               completion:^(id result, NSError *error) {
                 if (error)
                     VIMPresentError(error, self.window);
               }];
}
- (void)undo:(id)sender {
    [self sendShortcut:@[ @"meta_l", @"z" ]];
}
- (void)cut:(id)sender {
    [self sendShortcut:@[ @"meta_l", @"x" ]];
}
- (void)copy:(id)sender {
    [self sendShortcut:@[ @"meta_l", @"c" ]];
}
- (void)paste:(id)sender {
    [self sendShortcut:@[ @"meta_l", @"v" ]];
}
- (void)selectAll:(id)sender {
    [self sendShortcut:@[ @"meta_l", @"a" ]];
}
- (void)sendForceQuitKey:(id)sender {
    [self sendShortcut:@[ @"meta_l", @"alt", @"esc" ]];
}
- (void)sendMenuShortcut:(NSMenuItem *)sender {
    [self sendShortcut:sender.representedObject];
}
- (void)resetMachine:(id)sender {
    if (!self.guestSessionState.mayForceReset)
        return;
    void (^reset)(void) = ^{
      if (!self.guestSessionState.mayForceReset)
          return;
      [self applyLifecycleEvent:VIMSessionEventResetRequested];
      [self.displayView releasePressedKeys];
      self.displayView.displaySleeping = YES;
      NSTask *ownedTask = self.task;
      [ownedTask terminate];
      // Independent of QMP, QGA and any guest OS service. A wedged BQL must
      // not leave an explicitly requested force reset waiting forever.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.task == ownedTask && ownedTask.running)
            kill(ownedTask.processIdentifier, SIGKILL);
      });
    };
    if (VIMSkipsDevelopmentPowerConfirmation()) {
        reset();
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Reset this Mac?";
    alert.informativeText = @"This forcibly restarts the virtual Mac. Unsaved work will be lost, and an installation "
                            @"in progress may be interrupted.";
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Reset"];
    VIMPresentAlert(alert, self.window, ^(NSModalResponse response) {
      if (response == NSAlertSecondButtonReturn)
          reset();
    });
}
- (void)changeRetinaMode:(NSMenuItem *)sender {
    if (sender.tag < 0 || sender.tag > 2 || self.state.displayModePending)
        return;
    if (self.state.diagnosticPending) {
        VIMPresentError(
            VIMSessionError(@"Wait for the current guest operation to finish, then change the resolution again."),
            self.window);
        return;
    }
    [self applyDisplayMode:@[ @"space", @"retina", @"scaled" ][sender.tag]
                completion:^(NSDictionary *observed, NSError *error) {
                  if (error)
                      VIMPresentError(error, self.window);
                }];
}
- (BOOL)supportsRetinaDisplay {
    return VIMGuestSupportsRetinaDisplay(self.machine.editableConfiguration);
}
- (NSString *)displayScalingFilter {
    return VIMDisplayScalingFilter(self.machine.editableConfiguration);
}
+ (void)displayScalingPreferencesChangedForMachine:(VIMMachine *)machine {
    VIMSession *session = sessions[SessionKey(machine)];
    session.displayView.nearestNeighborScaling = [session.displayScalingFilter isEqual:@"nearest"];
    [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
}
- (void)changeDisplayScalingFilter:(NSMenuItem *)sender {
    NSString *filter = sender.representedObject;
    if (![@[ @"linear", @"nearest" ] containsObject:filter])
        return;
    NSError *error = nil;
    if (![self.machine saveSettings:@{@"DisplayScalingFilter" : filter} error:&error]) {
        VIMPresentError(error, self.window);
        return;
    }
    [VIMSession displayScalingPreferencesChangedForMachine:self.machine];
}
- (void)applyDisplayMode:(NSString *)mode completion:(void (^)(NSDictionary *, NSError *))completion {
    if (![@[ @"space", @"retina", @"scaled" ] containsObject:mode]) {
        completion(nil, VIMSessionError(@"Choose More Space, Retina or Scaled."));
        return;
    }
    if ([mode isEqual:@"retina"] && !self.supportsRetinaDisplay) {
        completion(nil, VIMSessionError(
                            @"This version of Mac OS X supports More Space and Scaled, but not Retina resolution."));
        return;
    }
    NSError *error = nil;
    NSDictionary *settings = @{@"DisplayMode" : mode, @"RetinaEnabled" : @(![mode isEqual:@"scaled"])};
    if (!self.task.running) {
        if (![self.machine saveSettings:settings error:&error]) {
            completion(nil, error);
            return;
        }
        self.displayMode = mode;
        self.retinaEnabled = ![mode isEqual:@"scaled"];
        [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
        completion(nil, nil);
        return;
    }
    if (!self.resizeArmed || self.preparing || self.state.guestPending || self.preparationRequested ||
        self.state.clipboardPending || self.state.bootPolicyPending || self.state.displayModePending) {
        completion(
            nil,
            VIMSessionError(
                @"Wait until macOS has reached the desktop and setup has finished, then change the resolution again."));
        return;
    }
    CGFloat factor = [mode isEqual:@"scaled"] ? 1 : ([mode isEqual:@"retina"] ? 2 : self.window.backingScaleFactor);
    NSSize requested = VIMRequestedGuestPixelSize(self.displayView.bounds.size, factor, self.machine.preMetalGuest,
                                                  [mode isEqual:@"retina"], self.openGLLargeResizeReady);
    NSUInteger width = requested.width, height = requested.height;
    [self.resizeTimer invalidate];
    self.state.displayModePending = YES;
    self.state.guestPending = YES;
    void (^finished)(NSDictionary *, NSError *) = ^(NSDictionary *observed, NSError *failure) {
      self.state.displayModePending = NO;
      self.state.guestPending = NO;
      if (!failure) {
          NSError *saveError = nil;
          [self.machine saveSettings:settings error:&saveError];
          self.displayMode = mode;
          self.retinaEnabled = ![mode isEqual:@"scaled"];
          self.lastRequestedSize = NSMakeSize(width, height);
          self.observedDisplayMode = observed;
          if (saveError)
              failure = saveError;
          [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
      } else {
          self.lastRequestedSize = NSZeroSize;
          [self scheduleResize];
      }
      completion(observed, failure);
      [self refreshGuestStatus];
    };
    void (^selectMode)(void) = ^{
      // Keep the existing panel/frame transport; choose the 1×/2× mode
      // actually advertised by macOS, rather than recreating the GPU.
      [self.displayConnection requestWidth:width
                                    height:height
                                   density:self.machine.preMetalGuest ? ([mode isEqual:@"retina"] ? 2 : 1) : 0];
      [self.guestAgent
          runExecutable:@"/usr/bin/stat"
              arguments:@[ @"-f", @"%u", @"/dev/console" ]
                timeout:10
             completion:^(NSDictionary *result, NSError *failure) {
               NSString *uid = [[NSString alloc] initWithData:result[@"stdout"] ?: NSData.data
                                                     encoding:NSUTF8StringEncoding];
               uid = [uid stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
               if (failure || ![result[@"exitcode"] isEqual:@0] || uid.integerValue < 501 ||
                   [uid rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location !=
                       NSNotFound) {
                   finished(nil,
                            failure ?: VIMSessionError(@"Sign in to this Mac before changing its display resolution."));
                   return;
               }
               NSString *tool = self.machine.preMetalGuest
                                    ? @"/Library/Application Support/Virtual Intel Mac/GuestTools/guest-display"
                                    : [self.displayToolDirectory stringByAppendingPathComponent:@"guest-display"];
               NSArray *arguments =
                   @[ @(width).stringValue, @(height).stringValue, [mode isEqual:@"retina"] ? @"2" : @"1" ];
               [self.guestAgent
                   runConsoleExecutable:tool
                              arguments:arguments
                                timeout:15
                             completion:^(NSDictionary *reply, NSError *issue) {
                               NSString *detail = [[NSString alloc] initWithData:reply[@"stderr"] ?: NSData.data
                                                                        encoding:NSUTF8StringEncoding];
                               id observed = [NSJSONSerialization JSONObjectWithData:reply[@"stdout"] ?: NSData.data
                                                                             options:0
                                                                               error:nil];
                               BOOL verified = [observed isKindOfClass:NSDictionary.class] &&
                                               [observed[@"PixelWidth"] isEqual:@(width)] &&
                                               [observed[@"PixelHeight"] isEqual:@(height)] &&
                                               [observed[@"Scale"] isEqual:([mode isEqual:@"retina"] ? @2 : @1)];
                               NSString *explanation =
                                   self.state.displayPolicyRestartRequired && [mode isEqual:@"retina"]
                                       ? @"Restart this virtual Mac once to finish enabling Retina display modes."
                                       : [@"macOS couldn’t apply and verify that display resolution. "
                                             stringByAppendingString:detail.length
                                                                         ? detail
                                                                         : @"Try again after the desktop appears."];
                               NSError *error =
                                   issue
                                       ?: ([reply[@"exitcode"] isEqual:@0] && verified ? nil
                                                                                       : VIMSessionError(explanation));
                               finished(verified ? observed : nil, error);
                             }];
             }];
    };
    if (self.machine.preMetalGuest || self.displayToolDirectory) {
        selectMode();
        return;
    }
    NSURL *tools = VIMGuestFileURL(
        self.machine.preMetalGuest ? [@"OpenGLGuests/" stringByAppendingString:self.machine.guest] : @"GuestTools");
    [self.guestAgent
        stageFiles:@{@"guest-display" : [tools URLByAppendingPathComponent:@"guest-display"]}
          progress:nil
        completion:^(NSDictionary *receipt, NSError *failure) {
          if (failure) {
              finished(nil, failure);
              return;
          }
          NSString *directory = receipt[@"Directory"];
          [self.guestAgent
              runExecutable:@"/bin/chmod"
                  arguments:@[ @"0755", [directory stringByAppendingPathComponent:@"guest-display"] ]
                    timeout:10
                 completion:^(NSDictionary *result, NSError *issue) {
                   if (issue || ![result[@"exitcode"] isEqual:@0]) {
                       finished(nil, issue ?: VIMSessionError(@"The display helper couldn’t be prepared."));
                       return;
                   }
                   // The verified helper executes as the console user. Permit exact
                   // path traversal, not directory listing or modification. This
                   // staging directory contains only the two non-secret binaries.
                   [self.guestAgent
                       runExecutable:@"/bin/chmod"
                           arguments:@[ @"0711", directory ]
                             timeout:10
                          completion:^(NSDictionary *secured, NSError *problem) {
                            if (problem || ![secured[@"exitcode"] isEqual:@0]) {
                                finished(nil,
                                         problem
                                             ?: VIMSessionError(
                                                    @"The display helper couldn’t be made available to the desktop."));
                                return;
                            }
                            self.displayToolDirectory = directory;
                            [self.guestAgent
                                runExecutable:[directory stringByAppendingPathComponent:@"guest-display"]
                                    arguments:@[ @"--prepare-policy" ]
                                      timeout:0
                                   completion:^(NSDictionary *policy, NSError *policyError) {
                                     id observed =
                                         [NSJSONSerialization JSONObjectWithData:policy[@"stdout"] ?: NSData.data
                                                                         options:0
                                                                           error:nil];
                                     if (policyError || ![policy[@"exitcode"] isEqual:@0] ||
                                         ![observed isKindOfClass:NSDictionary.class]) {
                                         finished(nil, policyError
                                                           ?: VIMSessionError(
                                                                  @"The native Retina display policy couldn’t be "
                                                                  @"prepared. Try again after restarting this Mac."));
                                         return;
                                     }
                                     self.state.displayPolicyRestartRequired =
                                         [observed[@"RestartRequired"] isEqual:@YES];
                                     selectMode();
                                   }];
                          }];
                 }];
        }];
}
- (void)showNetworkSettings:(id)sender {
    [VIMMachineSettings showForMachine:self.machine section:@"Hardware" category:@"Network" window:self.window];
}
- (BOOL)guestAgentFree {
    return self.guestSessionState.guestAgentFree;
}
- (void)applyGuestScreenSharing:(BOOL)enabled completion:(void (^)(NSError *))completion {
    NSArray *steps = [VIMMachineModel screenSharingCommandsForGuest:self.machine.guest enabling:enabled];
    if (!steps || !self.guestAgentFree) {
        completion(VIMSessionError(@"Start this Mac and wait for setup to finish, then try again."));
        return;
    }
    self.state.guestPending = YES;
    void (^finish)(NSError *) = ^(NSError *error) {
      self.state.guestPending = NO;
      [self refreshGuestStatus];
      completion(error);
    };
    [self.guestAgent applyScreenSharingSteps:steps enabling:enabled completion:finish];
}
- (void)toggleScreenSharing:(id)sender {
    NSDictionary *settings = self.machine.editableConfiguration;
    BOOL enable = ![settings[@"ScreenSharingEnabled"] boolValue];
    // The guest first: a setting that says off while the service still runs would be worse than an error.
    [self applyGuestScreenSharing:enable
                       completion:^(NSError *error) {
                         NSMutableDictionary *changes = [@{@"ScreenSharingEnabled" : @(enable)} mutableCopy];
                         if (!settings[@"ScreenSharingPort"])
                             changes[@"ScreenSharingPort"] =
                                 VIMSuggestedForwardPorts(self.machine.URL.URLByDeletingLastPathComponent,
                                                          self.machine.URL)[@"ScreenSharingPort"];
                         NSError *failure = error;
                         if (!failure)
                             [self.machine saveSettings:changes error:&failure];
                         if (failure) {
                             VIMPresentError(failure, self.window);
                             return;
                         }
                         if (enable && ![VIMMachineModel screenSharingURLForConfiguration:self.machine.configuration]) {
                             NSAlert *alert = [NSAlert new];
                             alert.messageText = @"Screen Sharing is on in the virtual Mac";
                             alert.informativeText = @"Restart this virtual Mac to connect to it from this Mac.";
                             [alert addButtonWithTitle:@"OK"];
                             VIMPresentAlert(alert, self.window, nil);
                         }
                       }];
}
- (void)openScreenSharing:(id)sender {
    NSURL *URL = [VIMMachineModel screenSharingURLForConfiguration:self.machine.configuration];
    // Enabling is idempotent, and a guest that's been reinstalled or restored has lost it. Screen Sharing asks for the
    // guest's account itself, so no name or password ever passes through here.
    [self applyGuestScreenSharing:YES
                       completion:^(NSError *error) {
                         if (error)
                             VIMPresentError(error, self.window);
                         else
                             [NSWorkspace.sharedWorkspace openURL:URL];
                       }];
}
+ (void)clipboardPreferencesChangedForMachine:(VIMMachine *)machine {
    VIMSession *session = sessions[SessionKey(machine)];
    [session updateClipboardForBoot:session.state.usernameBoot];
}
- (void)updateClipboardForBoot:(NSString *)boot {
    [self updateBridgeForBoot:boot displayPowerOnly:YES];
    [self updateBridgeForBoot:boot displayPowerOnly:NO];
}
- (void)updateBridgeForBoot:(NSString *)boot displayPowerOnly:(BOOL)powerOnly {
    // Installer VGA's legacy wire reader does not implement PVG power requests.
    // Do not send them into that unaccelerated producer.
    if (powerOnly && (self.displayView.softwareCursor || self.machine.preMetalGuest))
        return;
    NSDictionary *settings = self.machine.editableConfiguration;
    BOOL enabled = !settings[@"ClipboardEnabled"] || [settings[@"ClipboardEnabled"] isEqual:@YES];
    if (!powerOnly)
        self.clipboardSharingEnabled = enabled;
    if (!powerOnly && !enabled) {
        [self.clipboard stop];
        self.clipboard = nil;
        self.clipboardConfiguredBoot = nil;
        self.clipboardRetryAfter = nil;
        return;
    }
    if (!boot.length || (!powerOnly && !self.state.consoleUID) || !self.guestSessionState.mayProvisionHelpers)
        return;
    VIMClipboardBridge *current = powerOnly ? self.powerBridge : self.clipboard;
    if (current.isConnected && [boot isEqual:powerOnly ? self.powerConfiguredBoot : self.clipboardConfiguredBoot])
        return;
    if ((powerOnly ? self.powerRetryAfter : self.clipboardRetryAfter).timeIntervalSinceNow > 0)
        return;
    NSError *failure = nil;
    if (!current) {
        current = [VIMClipboardBridge new];
        current.displayPowerOnly = powerOnly;
        if (powerOnly)
            self.powerBridge = current;
        else
            self.clipboard = current;
        __weak VIMSession *weakSelf = self;
        // This is evaluated by the 200 ms pasteboard timer and every receive.
        // Settings changes explicitly call updateClipboardForBoot; never read
        // PendingConfiguration.plist from a removable disk in this hot path.
        current.exchangeAllowed = ^BOOL {
          VIMSession *session = weakSelf;
          return !powerOnly && session && session.task.running && NSApp.active && session.window.keyWindow &&
                 !session.displayView.displaySleeping && session.clipboardSharingEnabled;
        };
        current.displayPowerChanged = ^(BOOL sleeping) {
          if (powerOnly)
              [weakSelf.displayConnection requestDisplaySleeping:sleeping];
        };
        __weak VIMClipboardBridge *bridge = current;
        current.connectionLost = ^{
          VIMSession *session = weakSelf;
          if (!session.task.running || !bridge || (powerOnly ? session.powerBridge : session.clipboard) != bridge)
              return;
          [bridge stop];
          if (powerOnly) {
              session.powerBridge = nil;
              session.powerConfiguredBoot = nil;
              session.powerRetryAfter = [NSDate dateWithTimeIntervalSinceNow:60];
              [session.displayConnection requestDisplaySleeping:NO];
          } else {
              session.clipboard = nil;
              session.clipboardConfiguredBoot = nil;
              session.clipboardRetryAfter = [NSDate dateWithTimeIntervalSinceNow:60];
          }
          if (!powerOnly) {
              session.state.consoleUID = nil;
              session.state.usernameBoot = nil;
          }
          // Re-observe the console before provisioning: after logout, the
          // old UID/token is not authority to restart a GUI helper.
          [session refreshGuestStatus];
        };
    }
    if (![current startWithSocketPath:[self.runtimeDirectory
                                          stringByAppendingPathComponent:powerOnly ? @"displaypower" : @"clipboard"]
                                error:&failure]) {
        [current stop];
        if (powerOnly) {
            self.powerBridge = nil;
            self.powerRetryAfter = [NSDate dateWithTimeIntervalSinceNow:60];
        } else {
            self.clipboard = nil;
            self.clipboardRetryAfter = [NSDate dateWithTimeIntervalSinceNow:60];
        }
        return;
    }
    NSString *token = current.token, *configName = powerOnly ? @"DisplayPower.json" : @"Clipboard.json";
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{
        @"UID" : self.state.consoleUID ?: @0,
        @"Transport" : self.machine.preMetalGuest ? @"isa-serial" : @"virtio-serial",
        @"Token" : token,
        @"DisplayPowerOnly" : @(powerOnly)
    }
                                                   options:0
                                                     error:NULL];
    NSURL *configuration = [NSURL fileURLWithPath:[self.runtimeDirectory stringByAppendingPathComponent:configName]];
    if (![data writeToURL:configuration options:NSDataWritingAtomic error:NULL])
        return;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions : @0600}
                                   ofItemAtPath:configuration.path
                                          error:NULL];
    NSURL *tools = VIMGuestFileURL(
        self.machine.preMetalGuest ? [@"OpenGLGuests/" stringByAppendingString:self.machine.guest] : @"GuestTools");
    self.state.clipboardPending = YES;
    if (powerOnly)
        self.powerRetryAfter = [NSDate dateWithTimeIntervalSinceNow:60];
    else
        self.clipboardRetryAfter = [NSDate dateWithTimeIntervalSinceNow:60];
    __weak VIMSession *weakSelf = self;
    void (^finish)(NSString *) = ^(NSString *failedStep) {
      VIMSession *session = weakSelf;
      session.state.clipboardPending = NO;
      VIMClipboardBridge *bridge = powerOnly ? session.powerBridge : session.clipboard;
      if (![bridge.token isEqual:token])
          return;
      if (!failedStep) {
          if (powerOnly)
              session.powerConfiguredBoot = boot;
          else {
              session.clipboardFailure = nil;
              session.clipboardConfiguredBoot = boot;
          }
          [bridge awaitGuestHandshake];
          // Let the independent clipboard provision after display setup releases
          // ownership; do not wait another minute or race the guest-agent channel.
          if (powerOnly)
              [session updateBridgeForBoot:boot displayPowerOnly:NO];
          else
              [session restoreDisplaySelectionForBoot:boot];
          return;
      }
      NSString *message = [NSString stringWithFormat:@"Guest %@ %@ did not finish.",
                                                     powerOnly ? @"display-power observer" : @"clipboard", failedStep];
      if (![session.clipboardFailure isEqual:message])
          [session logNote:@"%@", message];
      [bridge stop];
      if (powerOnly)
          session.powerBridge = nil;
      else {
          session.clipboardFailure = message;
          session.clipboard = nil;
      }
    };
    if (self.machine.preMetalGuest) {
        [self.guestAgent provisionInstalledHelperWithConfiguration:data completion:finish];
        return;
    }
    [self.guestAgent provisionHelper:[tools URLByAppendingPathComponent:@"guest-clipboard"]
                       configuration:configuration
                               named:configName
                         stillWanted:^BOOL {
                           VIMSession *session = weakSelf;
                           return session.task.running &&
                                  [(powerOnly ? session.powerBridge : session.clipboard).token isEqual:token];
                         }
                          completion:finish];
}
+ (void)setNetworkConnected:(BOOL)connected machine:(VIMMachine *)machine completion:(void (^)(NSError *))completion {
    VIMSession *session = sessions[SessionKey(machine)];
    if (!session.task.running) {
        completion(nil);
        return;
    }
    [session.control execute:@"set_link"
                   arguments:@{@"name" : @"ethernet", @"up" : @(connected)}
                  completion:^(id result, NSError *error) {
                    if (!error) {
                        session.state.networkLinkConnected = connected;
                        if (!connected)
                            session.guestIPAddresses = nil;
                        [NSNotificationCenter.defaultCenter postNotificationName:@"VIMNetworkChanged" object:machine];
                        if (connected)
                            [session refreshGuestStatus];
                    }
                    completion(error);
                  }];
}
+ (NSDictionary *)networkDetailsForMachine:(VIMMachine *)machine {
    VIMSession *session = sessions[SessionKey(machine)];
    BOOL running = session.task.running;
    NSDictionary *config = running ? session.machine.configuration : machine.editableConfiguration;
    NSString *mode = VIMNetworkMode(config), *host = nil;
    if ([mode isEqual:@"shared"])
        host = @"10.0.2.2";
    else if (running)
        host = [mode isEqual:@"bridged"] ? VIMNetworkHostAddress(session.networkClient.details[@"BridgeInterface"])
                                         : session.networkClient.details[@"HostAddress"];
    BOOL connected = running && session.state.networkLinkConnected;
    return @{
        @"Mode" : mode,
        @"Running" : @(running),
        @"Connected" : @(connected),
        @"HostAddress" : host ?: @"",
        @"GuestAddresses" : connected ? (session.guestIPAddresses ?: @[]) : @[]
    };
}
+ (void)changeNetworkMode:(NSString *)mode
                connected:(BOOL)connected
                  machine:(VIMMachine *)machine
                   window:(NSWindow *)window
               completion:(void (^)(NSError *))completion {
    VIMSession *session = sessions[SessionKey(machine)];
    BOOL different = session.task.running && ![VIMNetworkMode(session.machine.configuration) isEqual:mode];
    NSError *error = nil;
    if (![machine saveSettings:@{@"NetworkMode" : mode, @"NetworkConnected" : @(connected)} error:&error]) {
        completion(error);
        return;
    }
    if (different && connected) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Restart to change networks";
        alert.informativeText = @"Your network selection is saved and will take effect the next time this virtual Mac "
                                @"starts. Its current connection stays active until then.";
        [alert addButtonWithTitle:@"OK"];
        VIMPresentAlert(alert, window, nil);
        completion(nil);
    } else
        [self setNetworkConnected:connected machine:machine completion:completion];
    [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
}
- (void)downloadApps:(id)sender {
    NSString *version = @"";
    for (NSDictionary *entry in [VIMInstallerCatalog currentCatalogWithError:nil].supportedInstallers)
        if ([entry[@"Guest"] isEqual:self.machine.guest]) {
            version = entry[@"Version"];
            break;
        }
    NSURLComponents *URL =
        [NSURLComponents componentsWithString:@"https://nfzerox.github.io/virtual-mac/intel/app/index.html"];
    URL.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"os" value:version],
        [NSURLQueryItem
            queryItemWithName:@"vm"
                        value:[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @""]
    ];
    [NSWorkspace.sharedWorkspace openURL:URL.URL];
}
- (void)showCPUSettings:(id)sender {
    [VIMMachineSettings showForMachine:self.machine section:@"Hardware" category:@"CPU & Memory" window:self.window];
}
- (void)showDiskSettings:(id)sender {
    [VIMMachineSettings showForMachine:self.machine section:@"Hardware" category:@"Hard Disk" window:self.window];
}
+ (void)chooseOpticalMediaForMachine:(VIMMachine *)machine window:(NSWindow *)window {
    [self chooseImageForMachine:machine slot:NSNotFound window:window];
}
+ (void)chooseImageForMachine:(VIMMachine *)machine slot:(NSUInteger)slot window:(NSWindow *)window {
    NSArray *connected = [self connectedImagesForMachine:machine];
    if (connected.count >= VIMImageSlotCount) {
        VIMPresentError(
            VIMSessionError(@"Four images are already connected. Disconnect an image before adding another."), window);
        return;
    }
    if (slot != NSNotFound && [self imageRecordForMachine:machine slot:slot]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Disconnect the current image first";
        alert.informativeText =
            @"Eject the image in the virtual Mac, then choose Disconnect before connecting a different image.";
        [alert addButtonWithTitle:@"OK"];
        VIMPresentAlert(alert, window, nil);
        return;
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"iso"], [UTType typeWithFilenameExtension:@"cdr"],
        [UTType typeWithFilenameExtension:@"dmg"]
    ];
    panel.allowsMultipleSelection = slot == NSNotFound;
    panel.prompt = @"Connect";
    panel.message = @"Choose ISO, CDR or supported unencrypted DMG images. Each image connects to its own read-only "
                    @"drive, without copying or conversion.";
    [panel beginSheetModalForWindow:window
                  completionHandler:^(NSModalResponse response) {
                    if (response != NSModalResponseOK)
                        return;
                    NSArray<NSURL *> *URLs = panel.URLs;
                    if (URLs.count > VIMImageSlotCount - [self connectedImagesForMachine:machine].count) {
                        VIMPresentError(VIMSessionError(@"There aren’t enough empty image drives for this selection. "
                                                        @"Choose fewer images or disconnect an existing image first."),
                                        window);
                        return;
                    }
                    __block void (^next)(NSUInteger);
                    next = ^(NSUInteger index) {
                      if (index >= URLs.count) {
                          next = nil;
                          return;
                      }
                      NSUInteger target = slot;
                      if (target == NSNotFound)
                          for (target = 0; target < VIMImageSlotCount; target++)
                              if (![self imageRecordForMachine:machine slot:target])
                                  break;
                      [self insertImage:URLs[index].path
                                   slot:target
                                machine:machine
                             completion:^(NSError *error) {
                               if (error) {
                                   next = nil;
                                   VIMPresentError(error, window);
                                   return;
                               }
                               next(index + 1);
                             }];
                    };
                    next(0);
                  }];
}
+ (NSDictionary *)imageRecordForMachine:(VIMMachine *)machine slot:(NSUInteger)slot {
    if (slot >= VIMImageSlotCount)
        return nil;
    VIMSession *session = sessions[SessionKey(machine)];
    if (session.task.running) {
        NSDictionary *active = [session.imageDrives mediaInSlot:(NSInteger)slot];
        if (active)
            return active;
        NSString *saved = VIMImageSlotPath(machine.editableConfiguration, slot);
        // Even if saving a disconnect failed, keep its saved selection visible
        // and removable. It is not a mounted guest medium and needs no eject.
        return saved.length ? @{@"Path" : saved, @"Connected" : @NO} : nil;
    }
    NSString *path = VIMImageSlotPath(machine.editableConfiguration, slot);
    return path.length ? @{@"Path" : path} : nil;
}
+ (NSArray<NSDictionary *> *)connectedImagesForMachine:(VIMMachine *)machine {
    NSMutableArray *images = [NSMutableArray new];
    for (NSUInteger slot = 0; slot < VIMImageSlotCount; slot++) {
        NSDictionary *record = [self imageRecordForMachine:machine slot:slot];
        if (record) {
            NSMutableDictionary *entry = [record mutableCopy];
            entry[@"Slot"] = @(slot);
            [images addObject:entry];
        }
    }
    return images;
}
+ (NSString *)connectedOpticalMediaForMachine:(VIMMachine *)machine {
    return [self imageRecordForMachine:machine slot:0][@"Path"] ?: @"";
}
+ (void)ejectOpticalMediaForMachine:(VIMMachine *)machine window:(NSWindow *)window {
    [self ejectImageForMachine:machine slot:0 window:window];
}
+ (void)ejectImageForMachine:(VIMMachine *)machine slot:(NSUInteger)slot window:(NSWindow *)window {
    [self insertImage:@""
                 slot:slot
              machine:machine
           completion:^(NSError *error) {
             if (!error)
                 return;
             VIMSession *session = sessions[SessionKey(machine)];
             if (!session.task.running || session.imageDrives.changePending) {
                 VIMPresentError(error, window);
                 return;
             }
             NSAlert *alert = [NSAlert new];
             alert.messageText = @"The image couldn’t be disconnected";
             alert.informativeText =
                 @"Close apps using the image and eject it in the virtual Mac’s Finder, then try again. If it still "
                 @"can’t be ejected, shut down the virtual Mac before disconnecting it. Forcing a mounted image to "
                 @"disconnect can leave macOS waiting for a disk that is no longer available.";
             [alert addButtonWithTitle:@"OK"];
             VIMPresentAlert(alert, window, nil);
           }];
}
+ (void)setOpticalMedia:(NSString *)path machine:(VIMMachine *)machine window:(NSWindow *)window {
    [self insertOpticalMedia:path
                     machine:machine
                  completion:^(NSError *error) {
                    if (error)
                        VIMPresentError(error, window);
                  }];
}
+ (void)insertOpticalMedia:(NSString *)path machine:(VIMMachine *)machine completion:(void (^)(NSError *))completion {
    [self insertImage:path slot:0 machine:machine completion:completion];
}
+ (void)insertImage:(NSString *)path
               slot:(NSUInteger)slot
            machine:(VIMMachine *)machine
         completion:(void (^)(NSError *))completion {
    if (slot >= VIMImageSlotCount) {
        completion(VIMSessionError(@"Choose an available image drive."));
        return;
    }
    NSError *validation = nil;
    NSString *format = path.length ? VIMOpticalImageFormat(path, &validation) : nil;
    if (path.length && !format) {
        completion(validation);
        return;
    }
    VIMSession *session = sessions[SessionKey(machine)];
    void (^save)(NSError *) = ^(NSError *failure) {
      NSError *error = failure;
      if (!error)
          [machine saveSettings:VIMImageSlotSettings(machine.editableConfiguration, slot, path) error:&error];
      if (!error)
          [NSNotificationCenter.defaultCenter postNotificationName:@"VIMLibraryChanged" object:nil];
      completion(error);
    };
    void (^apply)(NSError *) = ^(NSError *error) {
      if (error) {
          completion(error);
          return;
      }
      NSString *current = [self imageRecordForMachine:machine slot:slot][@"Path"];
      if (path.length && current.length) {
          completion(
              [current isEqual:path] ? nil : VIMSessionError(@"Disconnect the current image before choosing another."));
          return;
      }
      if (!session.task.running) {
          save(nil);
          return;
      }
      [session.imageDrives changeImage:path format:format slot:(NSInteger)slot completion:save];
    };
    if (!path.length) {
        apply(nil);
        return;
    }
    NSString *root = VIMDevelopmentSourceRoot();
    NSString *tool =
        root.length
            ? [NSDictionary
                  dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:@"Build/RuntimeLocation.plist"]]
                  [@"Directory"]
            : [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Runtime/bin"];
    if (!tool.length) {
        completion(VIMSessionError(@"Open the complete Light Click app to connect disk images."));
        return;
    }
    VIMCheckOpticalImage(path, format, [tool stringByAppendingPathComponent:@"qemu-img"], apply);
}
- (void)chooseOpticalMedia:(id)sender {
    [VIMSession chooseOpticalMediaForMachine:self.machine window:self.window];
}
- (void)ejectOpticalMedia:(NSMenuItem *)sender {
    [VIMSession ejectImageForMachine:self.machine
                                slot:[sender.representedObject unsignedIntegerValue]
                              window:self.window];
}
- (void)showSoundSettings:(id)sender {
    [VIMMachineSettings showForMachine:self.machine section:@"Hardware" category:@"Sound" window:self.window];
}
- (void)showMicrophoneSettings:(id)sender {
    [VIMMachineSettings requestMicrophoneAccessFromWindow:self.window];
}
- (void)showSharingSettings:(id)sender {
    [VIMMachineSettings showForMachine:self.machine section:@"Sharing" category:@"File Sharing" window:self.window];
}
- (void)showSSHSettings:(id)sender {
    [VIMMachineSettings showForMachine:self.machine section:@"Options" category:@"Remote Login" window:self.window];
}
- (void)showKeyboardSettings:(id)sender {
    [VIMMachineSettings showForMachine:self.machine
                               section:@"Hardware"
                              category:@"Mouse & Keyboard"
                                window:self.window];
}
- (void)takeScreenshot:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[ UTTypePNG ];
    panel.nameFieldStringValue = [self.machine.name stringByAppendingString:@".png"];
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
                    if (response != NSModalResponseOK)
                        return;
                    [self.displayView capturePNG:^(NSData *png) {
                      NSError *error = nil;
                      if (!png)
                          error = VIMSessionError(@"There isn’t a guest picture to save yet. Wake this Mac or wait for "
                                                  @"its desktop, then try again.");
                      else
                          [png writeToURL:panel.URL options:NSDataWritingAtomic error:&error];
                      if (error)
                          VIMPresentError(error, self.window);
                    }];
                  }];
}
- (IBAction)configureMachine:(id)sender {
    [VIMMachineSettings showForMachine:self.machine window:self.window completion:nil];
}
- (IBAction)showInstallationGuide:(id)sender {
    NSAlert *alert = [NSAlert new];
    VIMSetInstallerAlertIcon(alert, self.machine.guest);
    NSString *os = VIMOperatingSystemName(self.machine.guest);
    alert.messageText = [@"Installing " stringByAppendingString:os];
    NSDictionary *setup = [NSDictionary
        dictionaryWithContentsOfURL:[self.machine.URL URLByAppendingPathComponent:@"State/AutomaticSetup.plist"]];
    BOOL automatic = [setup[@"Enabled"] boolValue];
    NSString *instructions =
        automatic ? @"Your virtual Mac will install the operating system and create your account automatically. You "
                    @"don’t need to erase the disk or choose Reinstall."
        : VIMGuestHasTrait(self.machine.guest, VIMGuestTraitRestoreDVD)
            ? @"Follow the installer’s onscreen instructions and select Macintosh HD as the destination."
            : [NSString stringWithFormat:@"In %@ Utilities, choose Reinstall %@, then select Macintosh HD as the "
                                         @"destination. Don’t select the Base System; it contains the installer.",
                                         os, os];
    alert.informativeText =
        [instructions stringByAppendingString:
                          @"\n\nYour Mac may restart several times. Graphics support is installed automatically after "
                          @"setup. Keep this Mac running while setup finishes. Installation may take up to 2 hours."];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}
- (IBAction)showSessionDetails:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Session Details";
    VIMSetAppAlertIcon(alert);
    alert.informativeText =
        [NSString stringWithFormat:@"%@\n\n%@", self.status.stringValue, self.guestStatus.stringValue];
    [alert addButtonWithTitle:@"Done"];
    [alert addButtonWithTitle:@"Show Diagnostic Files"];
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse result) {
                    if (result == NSAlertSecondButtonReturn)
                        [self showGuestDiagnostics:self];
                  }];
}
- (IBAction)startAgain:(id)sender {
    NSError *error = nil;
    if (![VIMSession openMachine:self.machine error:&error])
        VIMPresentError(error, self.window);
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (self.networkStarting) {
        [self cleanUp];
        return YES;
    }
    if (!self.task.running)
        return YES;
    [self.displayView releasePressedKeys];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Close this Mac’s window?";
    VIMSetAppAlertIcon(alert);
    alert.informativeText = @"Keep it running in the background, or shut down macOS. Save your work inside this Mac "
                            @"before shutting down. You can return to it from the library.";
    [alert addButtonWithTitle:@"Keep Running"];
    [alert addButtonWithTitle:@"Shut Down"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse result) {
                    if (result == NSAlertFirstButtonReturn)
                        [self.window orderOut:nil];
                    else if (result == NSAlertSecondButtonReturn) {
                        [self applyLifecycleEvent:VIMSessionEventCloseRequested];
                        [self shutdown:self];
                    }
                  }];
    return NO;
}
- (IBAction)showGuestDiagnostics:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[self.machine.URL URLByAppendingPathComponent:@"State"]];
}
- (IBAction)checkGraphicsSetup:(id)sender {
    if (!self.guestSessionState.mayStartGraphicsAction)
        return;
    self.state.reconciledBoot = nil;
    [self refreshGuestStatus];
}
- (IBAction)finishGraphicsSetup:(id)sender {
    if (!self.guestSessionState.mayStartGraphicsAction)
        return;
    NSURL *journal = [self.machine.URL URLByAppendingPathComponent:@"State/GuestInstallation.plist"];
    BOOL repair = [NSFileManager.defaultManager fileExistsAtPath:journal.path];
    NSAlert *alert = [NSAlert new];
    alert.messageText = repair ? @"Repair graphics support?" : @"Finish graphics setup?";
    VIMSetInstallerAlertIcon(alert, self.machine.guest);
    alert.informativeText =
        repair
            ? @"Save your work first. We’ll check the previous installation, retain its recovery records, and prepare "
              @"fresh graphics support for this macOS build. Keep this Mac running until repair finishes, then restart "
              @"it. An unfinished or uncertain installation will not be replaced."
            : @"Save your work in this Mac first. Light Click will prepare and install its graphics support. This can "
              @"take several minutes. Keep this Mac running until setup finishes, then shut it down and open it again.";
    [alert addButtonWithTitle:repair ? @"Repair" : @"Finish Setup"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
                    if (response != NSAlertFirstButtonReturn || !self.task.running)
                        return;
                    if (repair) {
                        NSError *failure = nil;
                        if (![VIMSession repairMachine:self.machine error:&failure])
                            VIMPresentError(failure, self.window);
                        return;
                    }
                    NSError *error = nil;
                    if (![VIMSession installMachine:self.machine error:&error]) {
                        self.guestStatus.stringValue = error.localizedDescription;
                        VIMPresentError(error, self.window);
                    }
                  }];
}
- (void)shutdown:(id)sender {
    if (!self.guestSessionState.mayRequestShutdown)
        return;
    [self applyLifecycleEvent:VIMSessionEventShutdownRequested];
    self.shutdownButton.enabled = NO;
    [self.displayView releasePressedKeys];
    self.guestStatus.stringValue = @"Asking macOS to shut down…";
    void (^request)(void) = ^{
      [self.guestAgent connectWithCompletion:^(NSError *connectionError) {
        if (!self.task.running)
            return;
        if (connectionError) {
            [self applyLifecycleEvent:VIMSessionEventShutdownFailed];
            self.shutdownButton.enabled = YES;
            // The agent can disappear before QMP reports guest shutdown. A
            // transport error is not proof that tools are missing, and a
            // modal alert here can outlive an otherwise successful shutdown.
            self.guestStatus.stringValue =
                @"The shutdown request couldn’t be confirmed. This Mac may already be shutting down. If it stays on, "
                @"choose Shut Down inside the virtual Mac, or use Force Stop.";
            self.guestStatus.toolTip = connectionError.localizedDescription;
            [self logNote:@"Shutdown connection: %@", connectionError.localizedDescription];
            return;
        }
        [self.guestAgent requestShutdownWithCompletion:^(NSError *error) {
          if (!self.task.running)
              return;
          // Do not send a second shutdown or an ACPI sleep request after an
          // ambiguous agent disconnect. The task's exit is the completion.
          self.guestStatus.stringValue =
              error ? @"Shutdown has not been confirmed. Wait for your virtual Mac to finish, or use Force Stop if it "
                      @"is unresponsive."
                    : [NSString stringWithFormat:@"%@ is shutting down…", VIMOperatingSystemName(self.machine.guest)];
        }];
      }];
    };
    if ([self.lastRunState isEqual:@"paused"] || [self.lastRunState isEqual:@"suspended"]) {
        [self.control execute:[self.lastRunState isEqual:@"paused"] ? @"cont" : @"system_wakeup"
                    arguments:@{}
                   completion:^(id result, NSError *error) {
                     if (error) {
                         [self applyLifecycleEvent:VIMSessionEventShutdownFailed];
                         self.shutdownButton.enabled = YES;
                         VIMPresentError(error, self.window);
                         return;
                     }
                     request();
                   }];
    } else
        request();
}
- (void)forceStop:(id)sender {
    if (!self.task.running)
        return;
    void (^stop)(void) = ^{
      if (!self.task.running)
          return;
      [self applyLifecycleEvent:VIMSessionEventForceStopRequested];
      [self.task terminate];
    };
    if (VIMSkipsDevelopmentPowerConfirmation()) {
        stop();
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Force stop this Mac?";
    VIMSetAppAlertIcon(alert);
    alert.informativeText = @"Unsaved work will be lost. Try Shut Down first.";
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Force Stop"];
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse result) {
                    if (result == NSAlertSecondButtonReturn)
                        stop();
                  }];
}
- (void)cleanUp {
    [self applyLifecycleEvent:VIMSessionEventEmulatorStopped];
    self.previewSetupNotice = NO;
    [self dismissSetupNotice];
    void (^waitingCompletion)(NSError *) = self.pendingHostConnectionCompletion;
    self.pendingHostConnectionURL = nil;
    self.pendingHostConnectionCompletion = nil;
    if (waitingCompletion)
        waitingCompletion(
            VIMSessionError(@"The virtual Mac stopped before the connection could open. Start it and try again."));
    [self.controlRetryTimer invalidate];
    self.controlRetryTimer = nil;
    [self.controlStallTimer invalidate];
    self.controlStallTimer = nil;
    self.state.bootPolicyPending = NO;
    self.state.bootPolicyCheckedBoot = nil;
    self.networkStarting = NO;
    [self.networkClient stop];
    self.networkClient = nil;
    self.guestIPAddresses = nil;
    [self.usbClient stop];
    self.usbClient = nil;
    self.usbOperationPending = NO;
    self.usbAttached = nil;
    [self.smbService stop];
    self.smbService = nil;
    [self.clipboard stop];
    self.clipboard = nil;
    self.state.clipboardPending = NO;
    self.clipboardConfiguredBoot = nil;
    [self.powerBridge stop];
    self.powerBridge = nil;
    self.powerConfiguredBoot = nil;
    self.powerRetryAfter = nil;
    self.sleepActivity = nil;
    self.state.displaySelectedBoot = nil;
    self.state.displaySelectionRetryAfter = nil;
    self.state.displayPolicyRestartRequired = NO;
    self.state.updateRepairHeld = NO;
    self.state.presentedSetupFailures = NSSet.set;
    [self.handoffTimer invalidate];
    self.handoffTimer = nil;
    [self.guestTimer invalidate];
    self.guestTimer = nil;
    [self.guestAgent close];
    [self.statusTimer invalidate];
    self.statusTimer = nil;
    [self.resizeTimer invalidate];
    self.resizeTimer = nil;
    self.displayView.inputHandler = nil;
    [self.displayConnection stop];
    [self.displayView discardFrameStorage];
    [self.control close];
    [self.log closeFile];
    self.log = nil;
    if (self.runtimeDirectory) {
        unlink([self.runtimeDirectory stringByAppendingPathComponent:@"control"].fileSystemRepresentation);
        unlink([self.runtimeDirectory stringByAppendingPathComponent:@"guest-agent"].fileSystemRepresentation);
        unlink([self.runtimeDirectory stringByAppendingPathComponent:@"recovery-agent"].fileSystemRepresentation);
        rmdir(self.runtimeDirectory.fileSystemRepresentation);
    }
    // Only called before launch or after NSTask reports termination.
    if (self.machineLock >= 0) {
        close(self.machineLock);
        self.machineLock = -1;
    }
    if (self.completionGuestReport && !self.task.running) {
        NSError *error = nil;
        BOOL finished = self.machine.preMetalGuest
                            ? [self.machine retryInstallerCleanup:&error]
                            : [self.machine finishInstallationWithGuestReport:self.completionGuestReport error:&error];
        self.guestStatus.stringValue =
            finished ? @"Installation complete — installer media removed"
                     : [NSString stringWithFormat:@"Installer cleanup pending: %@", error.localizedDescription];
        self.completionGuestReport = nil;
    }
    if (self.machine && !self.task.running) {
        NSError *error = nil;
        if (![self.machine retryInstallerCleanup:&error])
            self.guestStatus.stringValue = error.localizedDescription;
        error = nil;
        if (![self.machine applyPendingChanges:&error])
            self.guestStatus.stringValue = error.localizedDescription;
        self.window.title = self.machine.name;
    }
}
- (void)windowDidResignKey:(NSNotification *)notification {
    [self.displayView releasePressedKeys];
}
- (void)windowDidResize:(NSNotification *)notification {
    [self scheduleResize];
}
- (void)windowDidChangeBackingProperties:(NSNotification *)notification {
    [self scheduleResize];
}
- (void)windowDidEndLiveResize:(NSNotification *)notification {
    [self scheduleResize];
}
- (NSApplicationPresentationOptions)window:(NSWindow *)window
      willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)options {
    return options | NSApplicationPresentationAutoHideToolbar | NSApplicationPresentationAutoHideMenuBar;
}
- (void)scheduleResize {
    if (!self.resizeArmed || self.state.displayModePending)
        return;
    [self.resizeTimer invalidate];
    __weak VIMSession *weakSelf = self;
    self.resizeTimer = [NSTimer
        scheduledTimerWithTimeInterval:0.15
                               repeats:NO
                                 block:^(NSTimer *timer) {
                                   VIMSession *session = weakSelf;
                                   if (!session.task.running)
                                       return;
                                   BOOL retina = [session.displayMode isEqual:@"retina"];
                                   CGFloat factor =
                                       retina ? 2 : (session.retinaEnabled ? session.window.backingScaleFactor : 1);
                                   NSSize pixels = VIMRequestedGuestPixelSize(session.displayView.bounds.size, factor,
                                                                              session.machine.preMetalGuest, retina,
                                                                              session.openGLLargeResizeReady);
                                   if (NSEqualSizes(pixels, session.lastRequestedSize))
                                       return;
                                   session.lastRequestedSize = pixels;
                                   [session.displayConnection
                                       requestWidth:pixels.width
                                             height:pixels.height
                                            density:session.machine.preMetalGuest ? (retina ? 2 : 1) : 0];
                                 }];
}
@end
