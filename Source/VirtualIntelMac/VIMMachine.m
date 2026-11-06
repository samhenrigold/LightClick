#import "VIMMachine.h"
#import "MachineKit-Swift.h"
#import "VIMGuestProfile.h"
#import "VIMNetworkDefaults.h"
#import "VIMLibraryLocation.h"
#import "VIMFirmwareBoot.h"
#import "VIMAutomaticSetup.h"
#import "VIMOSNaming.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <errno.h>

static BOOL Fail(NSError **error, NSString *message) {
    if (error)
        *error = [NSError errorWithDomain:@"VirtualIntelMac.Machine"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey : message}];
    return NO;
}
static BOOL Save(NSDictionary *value, NSURL *URL, NSError **error) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:error];
    return data && [data writeToURL:URL options:NSDataWritingAtomic error:error];
}
static BOOL OpenGLResearchEnabled(void) {
    NSArray *arguments = NSProcessInfo.processInfo.arguments;
    NSUInteger index = [arguments indexOfObject:@"--opengl-guest-research"];
    return index != NSNotFound && index + 1 < arguments.count && [arguments[index + 1] isEqual:@"1"];
}
static NSDictionary * (^const NetworkDefaults)(NSDictionary *, NSURL *,
                                               NSURL *) = ^NSDictionary *(NSDictionary *configuration, NSURL *library,
                                                                          NSURL *machine) {
  return VIMNetworkConfigurationWithDefaults(configuration, library, machine);
};
static int ConfigurationLock(NSURL *package, NSError **error) {
    NSURL *lock = [package URLByAppendingPathComponent:@"State/Configuration.lock"];
    int fd = open(lock.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat info;
    if (fd < 0 || fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_nlink != 1 || flock(fd, LOCK_EX | LOCK_NB)) {
        if (fd >= 0)
            close(fd);
        Fail(error, @"This Mac’s settings are being saved. Please try again.");
        return -1;
    }
    return fd;
}
static void RelocatedPackage(NSURL *old, NSURL *new, NSString *identifier) {
    [VIMMachineFiles updatePreferencesForPackageMovedFrom:old.path to:new.path];
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSNotificationCenter.defaultCenter
          postNotificationName:@"VIMMachineRelocated"
                        object:nil
                      userInfo:@{@"OldURL" : old, @"URL" : new, @"Identifier" : identifier}];
    });
}
@interface VIMMachine ()
@property NSNumber *cachedDiskCapacity;
- (nullable NSDictionary *)plist:(NSString *)relativePath;
@property(readonly) BOOL firmwareSelectsInstaller;
@end
@implementation VIMMachine
- (NSDictionary *)plist:(NSString *)relativePath {
    return [NSDictionary dictionaryWithContentsOfURL:[self.URL URLByAppendingPathComponent:relativePath]];
}
- (BOOL)firmwareSelectsInstaller {
    return VIMFirmwareBootTargetAtURL([self.URL URLByAppendingPathComponent:self.configuration[@"NVRAM"]]) ==
           VIMFirmwareBootInstaller;
}
- (NSString *)name {
    NSString *stem = self.URL.lastPathComponent.stringByDeletingPathExtension;
    // Legacy UUID packages retain their display name until safely migrated.
    return [[NSUUID alloc] initWithUUIDString:stem] && self.configuration[@"Name"] ? self.configuration[@"Name"] : stem;
}
- (NSString *)guest {
    return self.configuration[@"Guest"];
}
- (BOOL)preMetalGuest {
    return VIMGuestUsesOpenGLDesktop(self.guest);
}
- (BOOL)passthroughOpenGLEnabled {
    return [VIMMachineModel passthroughOpenGLEnabled:self.configuration];
}
- (BOOL)openGLResearchGuest {
    return self.preMetalGuest && OpenGLResearchEnabled();
}
- (uint64_t)diskCapacityBytes {
    if (self.cachedDiskCapacity)
        return self.cachedDiskCapacity.unsignedLongLongValue;
    uint64_t capacity = [VIMMachineFiles diskCapacityOfPackage:self.URL
                                                   recordedGiB:self.configuration[@"DiskGiB"]
                                                          disk:self.configuration[@"Disk"]];
    self.cachedDiskCapacity = @(capacity);
    return capacity;
}
- (NSDictionary *)editableConfiguration {
    return [VIMMachineModel editableConfiguration:self.configuration
                                          pending:[self plist:@"State/PendingConfiguration.plist"]];
}
- (NSString *)pendingName {
    return [VIMMachineModel pendingNameFrom:[self plist:@"State/PendingConfiguration.plist"]];
}
+ (instancetype)loadURL:(NSURL *)URL error:(NSError **)error {
    if (!URL.isFileURL || ![URL.pathExtension isEqual:@"vintelmac"]) {
        Fail(error, @"Choose a .vintelmac package.");
        return nil;
    }
    URL = URL.URLByResolvingSymlinksInPath;
    NSDictionary *c = [VIMMachineFiles loadConfigurationOfPackage:URL error:error];
    if (!c)
        return nil;
    VIMMachine *machine = [self new];
    machine->_URL = URL;
    machine->_configuration = [c copy];
    (void)machine.diskCapacityBytes; // Warm on the library's background scan.
    return machine;
}
- (BOOL)requiresInstallerDisplay {
    if (self.preMetalGuest)
        return YES;
    return [VIMMachineModel configuration:self.configuration
        requiresInstallerDisplayWithJournal:[self plist:@"State/GuestInstallation.plist"]
                                    updater:[self plist:@"State/UpdateDisplay.plist"]
                              nativeDisplay:[self plist:@"State/NativeBigSurDisplay.plist"]
                   firmwareSelectsInstaller:self.firmwareSelectsInstaller];
}
- (BOOL)prepareNativeBigSurDisplayWithGuestReport:(NSDictionary *)report error:(NSError **)error {
    // Runs on every status refresh. Other guests shouldn't read their firmware and state files for it.
    if (![self.guest isEqual:@"bigsur"])
        return NO;
    NSDictionary *record =
        [VIMMachineModel nativeBigSurDisplayRecordForConfiguration:self.configuration
                                                            report:report
                                                           journal:[self plist:@"State/GuestInstallation.plist"]
                                                           updater:[self plist:@"State/UpdateDisplay.plist"]
                                                     nativeDisplay:[self plist:@"State/NativeBigSurDisplay.plist"]
                                          firmwareSelectsInstaller:self.firmwareSelectsInstaller];
    return record && Save(record, [self.URL URLByAppendingPathComponent:@"State/NativeBigSurDisplay.plist"], error);
}
- (BOOL)prepareUpdaterDisplayForBoot:(NSError **)error {
    if (!self.hasPublishedGuestGraphics || !self.firmwareSelectsInstaller)
        return YES;
    NSDictionary *record = [VIMMachineModel updaterDisplayRecordForJournal:[self plist:@"State/GuestInstallation.plist"]
                                                                     guest:self.guest];
    // Without one, firmware still selects software video: don't invent an automatic-repair authorization.
    return !record || Save(record, [self.URL URLByAppendingPathComponent:@"State/UpdateDisplay.plist"], error);
}
- (BOOL)hasPublishedGuestGraphics {
    return [VIMMachineModel journal:[self plist:@"State/GuestInstallation.plist"]
        hasPublishedGraphicsForGuest:self.guest];
}
- (BOOL)rename:(NSString *)name error:(NSError **)error {
    if (![VIMMachineModel renameIsValid:name])
        return Fail(error, @"Enter a name of 1–128 characters without slashes, colons, or a leading dot.");
    int fd = ConfigurationLock(self.URL, error);
    if (fd < 0)
        return NO;
    NSURL *URL = [self.URL URLByAppendingPathComponent:@"State/PendingConfiguration.plist"];
    NSMutableDictionary *pending =
        [[NSDictionary dictionaryWithContentsOfURL:URL] mutableCopy] ?: [NSMutableDictionary dictionary];
    pending[@"RequestedBundleName"] = name;
    BOOL saved = Save(pending, URL, error);
    close(fd);
    return saved && [self applyPendingChanges:error];
}
- (BOOL)saveAutomaticSetup:(NSDictionary *)profile error:(NSError **)error {
    if (![VIMAutomaticSetup supportsGuest:self.guest] || ![self.configuration[@"InstallState"] isEqual:@"installing"] ||
        ![profile isKindOfClass:NSDictionary.class] || ![profile[@"FormatVersion"] isEqual:@1] ||
        ![profile[@"Enabled"] isEqual:@YES])
        return Fail(error, @"Automatic setup is only available for a new virtual Mac installation.");
    NSMutableSet *allowed = [NSMutableSet setWithArray:@[
        @"FormatVersion", @"Enabled", @"Username", @"FileSharing", @"RemoteLogin", @"CredentialIdentifier"
    ]];
    // Old saved transactions retain their one-time-login behavior. New UI
    // and CLI transactions explicitly request persistent automatic login.
    if (profile[@"AutomaticLogin"])
        [allowed addObject:@"AutomaticLogin"];
    if (![allowed isEqual:[NSSet setWithArray:profile.allKeys]])
        return Fail(error, @"Automatic setup contains an unsupported option.");
    if (![VIMAutomaticSetup validateUsername:profile[@"Username"] error:error] ||
        ![profile[@"CredentialIdentifier"] isKindOfClass:NSString.class] ||
        ![[NSUUID alloc] initWithUUIDString:profile[@"CredentialIdentifier"]])
        return Fail(error, @"Check the virtual Mac’s account and setup credential.");
    for (NSString *key in (profile[@"AutomaticLogin"] ? @[ @"FileSharing", @"RemoteLogin", @"AutomaticLogin" ]
                                                      : @[ @"FileSharing", @"RemoteLogin" ]))
        if (![profile[key] isKindOfClass:NSNumber.class] ||
            ([profile[key] doubleValue] != 0 && [profile[key] doubleValue] != 1))
            return Fail(error, @"Check the automatic sharing options.");
    NSDictionary *target = [self plist:@"State/InstallationTarget.plist"];
    NSDictionary *installer = [VIMAutomaticSetup installerConfigurationForVolumeUUID:target[@"VolumeUUID"] error:error];
    if (!installer)
        return NO;
    NSURL *lock = [self.URL URLByAppendingPathComponent:@"State/Session.lock"];
    int fd = open(lock.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat lockInfo;
    if (fd < 0 || fstat(fd, &lockInfo) || !S_ISREG(lockInfo.st_mode) || lockInfo.st_nlink != 1 ||
        flock(fd, LOCK_EX | LOCK_NB)) {
        if (fd >= 0)
            close(fd);
        return Fail(error, @"Stop this virtual Mac before changing its initial setup.");
    }
    @try {
        NSURL *journal = [self.URL URLByAppendingPathComponent:@"State/AutomaticSetup.plist"];
        if ([NSFileManager.defaultManager fileExistsAtPath:journal.path]) {
            NSDictionary *existing = [NSDictionary dictionaryWithContentsOfURL:journal];
            if (!existing)
                return Fail(error, @"The saved automatic setup state could not be read. It was not replaced.");
            for (NSString *key in allowed)
                if (![existing[key] isEqual:profile[key]])
                    return Fail(error, @"This Mac’s initial account setup has already been saved. Resume that setup "
                                       @"before changing it.");
            return YES; // Never reset an in-progress/completed journal to pending.
        }
        NSMutableDictionary *state = [profile mutableCopy];
        state[@"Guest"] = self.guest;
        state[@"MachineIdentifier"] = self.configuration[@"Identifier"];
        state[@"VolumeUUID"] = target[@"VolumeUUID"];
        state[@"Phase"] = @"pending";
        return Save(state, journal, error);
    } @finally {
        close(fd);
    }
}
- (BOOL)saveSettings:(NSDictionary *)settings error:(NSError **)error {
    // Stage edits independently of the live launch snapshot. Never rewrite the
    // active configuration or move a live package. Session locking decides when
    // publication is safe, including when another app process owns the VM.
    int edit = ConfigurationLock(self.URL, error);
    if (edit < 0)
        return NO;
    @try {
        if (![VIMMachineModel validateSettings:settings onEditableConfiguration:self.editableConfiguration error:error])
            return NO;
        NSURL *pendingURL = [self.URL URLByAppendingPathComponent:@"State/PendingConfiguration.plist"];
        NSMutableDictionary *pending =
            [[NSDictionary dictionaryWithContentsOfURL:pendingURL] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSMutableDictionary *values = [pending[@"Settings"] mutableCopy] ?: [NSMutableDictionary dictionary];
        [values addEntriesFromDictionary:settings];
        pending[@"Settings"] = values;
        if (!Save(pending, pendingURL, error))
            return NO;
    } @finally {
        close(edit);
    }
    return [self applyPendingChanges:error];
}
- (BOOL)applyPendingChanges:(NSError **)error {
    NSURL *lock = [self.URL URLByAppendingPathComponent:@"State/Session.lock"];
    int fd = open(lock.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat info;
    if (fd < 0 || fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_nlink != 1) {
        if (fd >= 0)
            close(fd);
        return Fail(error, @"This Mac’s configuration lock could not be opened.");
    }
    if (flock(fd, LOCK_EX | LOCK_NB)) {
        int issue = errno;
        close(fd);
        return issue == EWOULDBLOCK ? YES : Fail(error, @"This Mac’s configuration lock is unavailable.");
    }
    int edit = ConfigurationLock(self.URL, error);
    if (edit < 0) {
        close(fd);
        return NO;
    }
    @try {
        VIMMachine *fresh = [VIMMachine loadURL:self.URL error:error];
        if (!fresh)
            return NO;
        NSURL *old = self.URL, *pendingURL = [old URLByAppendingPathComponent:@"State/PendingConfiguration.plist"];
        NSDictionary *pending = [NSDictionary dictionaryWithContentsOfURL:pendingURL];
        NSDictionary *applied = [VIMMachineModel configuration:fresh.configuration applyingPending:pending error:error];
        if (!applied)
            return NO;
        NSMutableDictionary *c = [applied mutableCopy];
        NSDictionary *network =
            VIMNetworkConfigurationWithDefaults(c, self.URL.URLByDeletingLastPathComponent, self.URL);
        if (!network)
            return Fail(error, @"No local connection ports are available. Close unused virtual Macs or network "
                               @"services, then try again.");
        [c addEntriesFromDictionary:network];
        NSString *requested =
            [VIMMachineModel destinationNameForPackageStem:old.lastPathComponent.stringByDeletingPathExtension
                                                   pending:pending
                                             configuration:c];
        NSURL *destination = requested ? [VIMMachineModel newPackageURLForName:requested
                                                                     inLibrary:old.URLByDeletingLastPathComponent]
                                       : old;
        BOOL moved = ![destination isEqual:old];
        if (moved && ![NSFileManager.defaultManager moveItemAtURL:old toURL:destination error:error])
            return NO;
        BOOL needsSave = pending != nil || c[@"Name"] != nil || ![c isEqualToDictionary:fresh.configuration];
        c = [[VIMMachineModel configurationRemovingLegacyName:c] mutableCopy];
        if (needsSave && !Save(c, [destination URLByAppendingPathComponent:@"Machine.plist"], error)) {
            if (moved)
                [NSFileManager.defaultManager moveItemAtURL:destination toURL:old error:nil];
            return NO;
        }
        _URL = destination;
        _configuration = [c copy];
        if (moved)
            RelocatedPackage(old, destination, c[@"Identifier"]);
        if (pending && ![NSFileManager.defaultManager
                           removeItemAtURL:[destination URLByAppendingPathComponent:@"State/PendingConfiguration.plist"]
                                     error:error])
            return NO;
        return YES;
    } @finally {
        close(edit);
        flock(fd, LOCK_UN);
        close(fd);
    }
}
- (BOOL)claimAutomaticInstallationWithGuestReport:(NSDictionary *)report error:(NSError **)error {
    return [VIMMachineFiles claimAutomaticInstallationOfPackage:self.URL
                                                  configuration:self.configuration
                                                         report:report
                                                          error:error];
}
- (BOOL)claimAutomaticUpdateRepairWithGuestReport:(NSDictionary *)report error:(NSError **)error {
    return [VIMMachineFiles authorizeUpdateRepairOfPackage:self.URL
                                             configuration:self.configuration
                                                    report:report
                                                     claim:YES
                                                     error:error];
}
- (BOOL)canRepairUpdatedSystemWithGuestReport:(NSDictionary *)report error:(NSError **)error {
    return [VIMMachineFiles authorizeUpdateRepairOfPackage:self.URL
                                             configuration:self.configuration
                                                    report:report
                                                     claim:NO
                                                     error:error];
}
- (NSError * (^)(NSString *))passwordRemover {
    return ^NSError *(NSString *identifier) {
      NSError *failure = nil;
      return [VIMAutomaticSetup removePasswordForIdentifier:identifier error:&failure]
                 ? nil
                 : failure ?: [NSError errorWithDomain:@"VirtualIntelMac.Machine" code:1 userInfo:nil];
    };
}
- (void (^)(NSDictionary *))configurationAdopter {
    return ^(NSDictionary *configuration) {
      self->_configuration = [configuration copy];
    };
}
- (BOOL)retryInstallerCleanup:(NSError **)error {
    return [VIMMachineFiles retryInstallerCleanupOfPackage:self.URL
                                             configuration:self.configuration
                                             preMetalGuest:self.preMetalGuest
                                            removePassword:self.passwordRemover
                                                     adopt:self.configurationAdopter
                                                     error:error];
}
- (BOOL)validateOpenGLSetupReport:(NSDictionary *)report requirePixels:(BOOL)pixels error:(NSError **)error {
    if (![VIMMachineModel report:report
            isOpenGLSetupEvidenceOnConfiguration:self.configuration
                                          target:[self plist:@"State/InstallationTarget.plist"]
                                   requirePixels:pixels])
        return Fail(
            error,
            @"Matching installed-system and accelerated graphics evidence is required. The installer was retained.");
    return YES;
}
- (BOOL)prepareOpenGLRestartWithReport:(NSDictionary *)report error:(NSError **)error {
    // New graphics/GA files may not be loaded by this boot's WindowServer.
    // Restart is authorized by verified installed files/identity, not a fake
    // pixel result. Actual accelerated pixels are mandatory for completion.
    if (![self validateOpenGLSetupReport:report requirePixels:NO error:error])
        return NO;
    int lock = ConfigurationLock(self.URL, error);
    if (lock < 0)
        return NO;
    @try {
        NSDictionary *current = [self plist:@"Machine.plist"];
        if (![current[@"Identifier"] isEqual:self.configuration[@"Identifier"]])
            return Fail(error, @"This Mac’s configuration changed. Setup was not restarted.");
        NSDictionary *owner = [self plist:@"Installation/Ownership.plist"];
        if (current[@"InstallerMedia"] && ![VIMMachineModel ownership:owner namesConfiguration:current])
            return Fail(error, @"Installer ownership could not be confirmed. It was not detached.");
        NSURL *restart = [self.URL URLByAppendingPathComponent:@"State/LegacySetupRestart.plist"];
        if (!Save(@{
                @"FormatVersion" : @1,
                @"MachineIdentifier" : current[@"Identifier"],
                @"FromBootSessionUUID" : report[@"BootSessionUUID"],
                @"GuestReport" : report,
                @"RequestState" : @"prepared"
            },
                  restart, error))
            return NO;
        NSDictionary *config = [VIMMachineModel configurationRestartingForOpenGLSetup:current];
        if (!Save(config, [self.URL URLByAppendingPathComponent:@"Machine.plist"], error))
            return NO;
        _configuration = [config copy];
        return YES;
    } @finally {
        close(lock);
    }
}
- (BOOL)recordOpenGLRestartAcknowledged:(NSError **)error {
    int lock = ConfigurationLock(self.URL, error);
    if (lock < 0)
        return NO;
    @try {
        NSURL *path = [self.URL URLByAppendingPathComponent:@"State/LegacySetupRestart.plist"];
        NSMutableDictionary *state = [[NSDictionary dictionaryWithContentsOfURL:path] mutableCopy];
        if (![state[@"MachineIdentifier"] isEqual:self.configuration[@"Identifier"]])
            return Fail(error, @"The restart record no longer matches this Mac.");
        state[@"RequestState"] = @"acknowledged";
        return Save(state, path, error);
    } @finally {
        close(lock);
    }
}
- (BOOL)finishOpenGLSetupWithReport:(NSDictionary *)report error:(NSError **)error {
    if (![self validateOpenGLSetupReport:report requirePixels:YES error:error] ||
        ![report[@"DesktopRunning"] isEqual:@YES])
        return NO;
    NSDictionary *profile = [self plist:@"State/AutomaticSetup.plist"];
    if (![VIMMachineModel report:report hasFinishedFirstLoginWithAutomaticSetup:profile])
        return Fail(error, @"The first-login handoff has not completed. Its recovery records were retained.");
    int lock = ConfigurationLock(self.URL, error);
    if (lock < 0)
        return NO;
    @try {
        NSDictionary *current = [self plist:@"Machine.plist"];
        if (![current[@"Identifier"] isEqual:self.configuration[@"Identifier"]])
            return Fail(error, @"Restart this Mac without its installer before completing setup.");
        NSDictionary *config = [VIMMachineModel configurationFinishingOpenGLSetup:current error:error];
        if (!config)
            return NO;
        NSDictionary *receipt = @{
            @"FormatVersion" : @1,
            @"Phase" : @"graphics-verified",
            @"Guest" : self.guest,
            @"MachineIdentifier" : current[@"Identifier"],
            @"GuestReport" : report,
            @"VerifiedAt" : NSDate.date
        };
        if (!Save(receipt, [self.URL URLByAppendingPathComponent:@"State/LegacyGuestInstallation.plist"], error))
            return NO;
        if (!Save(config, [self.URL URLByAppendingPathComponent:@"Machine.plist"], error))
            return NO;
        _configuration = [config copy];
        // Completion no longer needs a host-side cleartext setup credential.
        // Retire it now, not only after the VM is eventually shut down.
        if (profile[@"CredentialIdentifier"] &&
            ![VIMAutomaticSetup removePasswordForIdentifier:profile[@"CredentialIdentifier"] error:error])
            return NO;
        return YES;
    } @finally {
        close(lock);
    }
}
- (BOOL)finishInstallationWithGuestReport:(NSDictionary *)report error:(NSError **)error {
    return [VIMMachineFiles finishInstallerCleanupOfPackage:self.URL
                                                     report:report
                                             removePassword:self.passwordRemover
                                                      adopt:self.configurationAdopter
                                                      error:error];
}
+ (instancetype)importDisk:(NSURL *)disk
                     guest:(NSString *)guest
                      name:(NSString *)name
                   library:(NSURL *)library
                  firmware:(NSURL *)firmware
                     nvram:(NSURL *)nvram
                 bootMedia:(NSURL *)bootMedia
                 qemuImage:(NSURL *)qemuImage
                     error:(NSError **)error {
    NSURL *package = [VIMMachinePackages importDisk:disk
                                              guest:guest
                                               name:name
                                            library:library
                                           firmware:firmware
                                              nvram:nvram
                                          bootMedia:bootMedia
                                          qemuImage:qemuImage
                                    networkDefaults:NetworkDefaults
                                              error:error];
    return package ? [self loadURL:package error:error] : nil;
}
+ (instancetype)createGuest:(NSString *)guest
                       name:(NSString *)name
                    diskGiB:(NSUInteger)diskGiB
                    library:(NSURL *)library
                   firmware:(NSURL *)firmware
                      nvram:(NSURL *)nvram
                  bootMedia:(NSURL *)bootMedia
                  installer:(NSURL *)installer
                  qemuImage:(NSURL *)qemuImage
                      error:(NSError **)error {
    NSURL *package = [VIMMachinePackages createGuest:guest
                                                name:name
                                             diskGiB:(NSInteger)diskGiB
                                             library:library
                                            firmware:firmware
                                               nvram:nvram
                                           bootMedia:bootMedia
                                           installer:installer
                                           qemuImage:qemuImage
                                            research:OpenGLResearchEnabled()
                                     networkDefaults:NetworkDefaults
                                               error:error];
    return package ? [self loadURL:package error:error] : nil;
}
@end
