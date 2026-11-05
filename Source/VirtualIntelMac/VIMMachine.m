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

static BOOL EFIDisk(NSURL *URL) {
    int fd = open(URL.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0)
        return NO;
    char signature[8];
    ssize_t count = pread(fd, signature, sizeof(signature), 512);
    close(fd);
    return count == sizeof(signature) && memcmp(signature, "EFI PART", 8) == 0;
}

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
static BOOL Supported(NSString *guest) { return VIMGuestIsSupported(guest); }
static BOOL NameValid(id name) { return [VIMMachineModel nameIsValid:name]; }
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
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
        if ([key hasPrefix:@"VIMLibraryOrder-"] || [key isEqual:@"VIMRegisteredPackages"]) {
            NSArray *paths = [defaults arrayForKey:key];
            if (![paths containsObject:old.path])
                continue;
            NSMutableArray *updated = [paths mutableCopy];
            for (NSUInteger i = 0; i < updated.count; i++)
                if ([updated[i] isEqual:old.path])
                    updated[i] = new.path;
            [defaults setObject:updated forKey:key];
        } else if ([key hasPrefix:@"VIMLibraryKnown-"]) {
            NSMutableDictionary *known = [[defaults dictionaryForKey:key] mutableCopy];
            if (!known[old.path])
                continue;
            known[new.path] = known[old.path];
            [known removeObjectForKey:old.path];
            [defaults setObject:known forKey:key];
        }
    }
    NSMutableDictionary *job = [[defaults dictionaryForKey:@"VIMCreationJob"] mutableCopy];
    if ([job[@"Machine"] isEqual:old.path]) {
        job[@"Machine"] = new.path;
        [defaults setObject:job forKey:@"VIMCreationJob"];
    }
    NSString *oldKey = [@"VIMGuestUsername-" stringByAppendingString:old.path],
             *newKey = [@"VIMGuestUsername-" stringByAppendingString:new.path];
    if ([defaults objectForKey:oldKey]) {
        [defaults setObject:[defaults objectForKey:oldKey] forKey:newKey];
        [defaults removeObjectForKey:oldKey];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSNotificationCenter.defaultCenter
          postNotificationName:@"VIMMachineRelocated"
                        object:nil
                      userInfo:@{@"OldURL" : old, @"URL" : new, @"Identifier" : identifier}];
    });
}
static BOOL Run(NSURL *executable, NSArray *arguments, NSURL *log, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createFileAtPath:log.path contents:nil attributes:nil])
        return Fail(error, @"Cannot create import log.");
    NSFileHandle *output = [NSFileHandle fileHandleForWritingToURL:log error:error];
    if (!output)
        return NO;
    NSTask *task = [NSTask new];
    task.executableURL = executable;
    task.arguments = arguments;
    task.standardOutput = output;
    task.standardError = output;
    BOOL launched = [task launchAndReturnError:error];
    if (launched)
        [task waitUntilExit];
    [output closeFile];
    if (!launched)
        return NO;
    return task.terminationStatus == 0 ||
           Fail(
               error,
               [NSString stringWithFormat:
                             @"The disk tool could not complete the operation. See %@. Source disks were not modified.",
                             log.path]);
}
// Only called inside a freshly created, unpublished package. Never format an
// existing guest disk. Sparse staging keeps large logical disks cheap on exFAT.
static BOOL CreateFormattedDisk(NSURL *stage, NSURL *qemuImage, NSUInteger diskGiB, BOOL recordTarget,
                                NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *seed = [stage URLByAppendingPathComponent:@"Disks/Formatting.sparsebundle"];
    NSURL *disk = [stage URLByAppendingPathComponent:@"Disks/System.qcow2"];
    NSURL *hdiutil = [NSURL fileURLWithPath:@"/usr/bin/hdiutil"];
    NSURL * (^log)(NSString *) = ^NSURL *(NSString *name) {
      return [stage URLByAppendingPathComponent:[@"Logs/" stringByAppendingString:name]];
    };
    if (!Run(hdiutil,
             @[
                 @"create", @"-size", [NSString stringWithFormat:@"%lug", diskGiB], @"-type", @"SPARSEBUNDLE",
                 @"-layout", @"GPTSPUD", @"-fs", @"Journaled HFS+", @"-volname", @"Macintosh HD", seed.path
             ],
             log(@"FormatDisk.log"), error))
        return NO;
    NSURL *attachLog = log(@"AttachFormattingDisk.log");
    if (!Run(hdiutil, @[ @"attach", @"-nomount", @"-readonly", @"-plist", seed.path ], attachLog, error))
        return NO;
    // hdiutil on newer hosts appends a deprecation warning to the merged log.
    NSString *output = [NSString stringWithContentsOfURL:attachLog encoding:NSUTF8StringEncoding error:error];
    NSRange start = [output rangeOfString:@"<?xml"], end = [output rangeOfString:@"</plist>"];
    NSDictionary *attached = nil;
    if (output && start.location != NSNotFound && end.location != NSNotFound && end.location >= start.location) {
        NSData *plist = [[output substringWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)]
            dataUsingEncoding:NSUTF8StringEncoding];
        attached = [NSPropertyListSerialization propertyListWithData:plist options:0 format:nil error:error];
    }
    NSString *device = nil;
    for (NSDictionary *entity in attached[@"system-entities"])
        if ([entity[@"content-hint"] isEqual:@"GUID_partition_scheme"])
            device = entity[@"dev-entry"];
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^/dev/disk[0-9]+$"
                                                                             options:0
                                                                               error:nil];
    if (![device isKindOfClass:NSString.class] || ![pattern numberOfMatchesInString:device
                                                                            options:0
                                                                              range:NSMakeRange(0, device.length)]) {
        // Detach by our exact image path if the plist was not understood.
        Run(hdiutil, @[ @"detach", seed.path ], log(@"DetachFormattingDisk.log"), nil);
        return Fail(error, @"Cannot identify the newly formatted virtual disk. See AttachFormattingDisk.log.");
    }
    NSString *raw = [device stringByReplacingOccurrencesOfString:@"/dev/disk" withString:@"/dev/rdisk"];
    if (recordTarget) {
        NSString *slice = nil;
        for (NSDictionary *entity in attached[@"system-entities"])
            if ([entity[@"content-hint"] isEqual:@"Apple_HFS"]) {
                if (slice) {
                    slice = nil;
                    break;
                }
                slice = entity[@"dev-entry"];
            }
        NSRegularExpression *validSlice = [NSRegularExpression regularExpressionWithPattern:@"^/dev/disk[0-9]+s[0-9]+$"
                                                                                    options:0
                                                                                      error:NULL];
        BOOL found = [slice isKindOfClass:NSString.class] && [slice hasPrefix:[device stringByAppendingString:@"s"]] &&
                     [validSlice numberOfMatchesInString:slice options:0 range:NSMakeRange(0, slice.length)] == 1;
        NSURL *metadata = log(@"FormattedVolume.plist");
        if (found)
            found = Run([NSURL fileURLWithPath:@"/usr/sbin/diskutil"], @[ @"info", @"-plist", slice ], metadata, error);
        NSDictionary *volume = found ? [NSDictionary dictionaryWithContentsOfURL:metadata] : nil;
        NSString *UUID = volume[@"VolumeUUID"];
        if (![UUID isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:UUID] ||
            !Save(
                @{@"FormatVersion" : @1,
                  @"VolumeUUID" : UUID,
                  @"Filesystem" : @"HFS+"},
                [stage URLByAppendingPathComponent:@"State/InstallationTarget.plist"], error)) {
            Run(hdiutil, @[ @"detach", device ], log(@"DetachFormattingDisk.log"), nil);
            return Fail(error, @"The new Macintosh HD could not be identified safely for automatic installation.");
        }
    }
    BOOL converted =
        Run(qemuImage, @[ @"convert", @"-f", @"raw", @"-O", @"qcow2", raw, disk.path ], log(@"CreateDisk.log"), error);
    NSError *detachError = nil;
    BOOL detached = Run(hdiutil, @[ @"detach", device ], log(@"DetachFormattingDisk.log"), &detachError);
    if (!converted)
        return NO;
    if (!detached) {
        if (error)
            *error = detachError;
        return NO;
    }
    // Discard only our generated seed after conversion and successful detach.
    return [fm removeItemAtURL:seed error:error];
}
@interface VIMMachine ()
@property NSNumber *cachedDiskCapacity;
- (BOOL)authorizeUpdateRepair:(NSDictionary *)report claim:(BOOL)claim error:(NSError **)error;
- (nullable NSDictionary *)plist:(NSString *)relativePath;
@property(readonly) BOOL firmwareSelectsInstaller;
@end
/// Media the app prepared lives in its own Downloads/Preparation/<UUID>
/// attempt and is never reused for another Mac. Once the owner is installed,
/// delete that attempt unless another Mac in the library still references it.
static BOOL RemovePreparedMedia(NSString *path, NSURL *owner) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"VIMKeepInstallers"])
        return NO;
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath)
        return NO;
    NSURL *media = [NSURL fileURLWithPath:path].URLByResolvingSymlinksInPath;
    NSURL *attempt = [VIMMachineModel preparedMediaAttemptForMedia:media owner:owner];
    if (!attempt)
        return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *prefix = [attempt.path stringByAppendingString:@"/"];
    NSDictionary *creation = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"VIMCreationJob"];
    NSString *creatingMedia = creation[@"Media"];
    if ([creatingMedia isKindOfClass:NSString.class] &&
        [creatingMedia.stringByResolvingSymlinksInPath hasPrefix:prefix])
        return NO;
    for (NSURL *sibling in [fm contentsOfDirectoryAtURL:owner.URLByDeletingLastPathComponent
                             includingPropertiesForKeys:nil
                                                options:0
                                                  error:nil]
             ?: @[]) {
        if (![sibling.pathExtension isEqual:@"vintelmac"] ||
            [sibling.URLByResolvingSymlinksInPath.path isEqual:owner.URLByResolvingSymlinksInPath.path])
            continue;
        NSDictionary *config =
            [NSDictionary dictionaryWithContentsOfURL:[sibling URLByAppendingPathComponent:@"Machine.plist"]];
        if (!config)
            return NO;
        NSString *other = config[@"InstallerMedia"];
        if ([other isKindOfClass:NSString.class] && [other.stringByResolvingSymlinksInPath hasPrefix:prefix])
            return NO;
    }
    return [fm removeItemAtURL:attempt error:nil];
}
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
    uint64_t capacity = 0;
    NSNumber *recorded = self.configuration[@"DiskGiB"];
    if ([recorded isKindOfClass:NSNumber.class] && recorded.doubleValue > 0 && recorded.doubleValue <= 1048576)
        capacity = (uint64_t)(recorded.doubleValue * (1ULL << 30));
    NSString *path = self.configuration[@"Disk"];
    if (!capacity && [path isKindOfClass:NSString.class] && path.length) {
        int fd = open([self.URL URLByAppendingPathComponent:path].fileSystemRepresentation,
                      O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        struct stat info;
        unsigned char header[32];
        if (fd >= 0) {
            // QCOW2 v2/v3: big-endian virtual size at bytes 24–31. Never read
            // disk contents, traverse snapshots, or launch a tool to paint a row.
            if (!fstat(fd, &info) && S_ISREG(info.st_mode) && pread(fd, header, sizeof(header), 0) == sizeof(header) &&
                !memcmp(header, "QFI\xfb", 4) && header[4] == 0 && header[5] == 0 && header[6] == 0 &&
                (header[7] == 2 || header[7] == 3)) {
                uint64_t size;
                memcpy(&size, header + 24, sizeof(size));
                capacity = CFSwapInt64BigToHost(size);
            }
            close(fd);
        }
    }
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
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:[URL URLByAppendingPathComponent:@"Machine.plist"]
                                         options:0
                                           error:&readError];
    if (!data) {
        if (error)
            *error = [NSError
                errorWithDomain:@"VirtualIntelMac.Machine"
                           code:1
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"This Mac isn’t available. Reconnect its drive or locate its current folder.",
                           NSUnderlyingErrorKey : readError
                               ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil]
                       }];
        return nil;
    }
    id c = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:error];
    if (![VIMMachineModel validateConfiguration:c package:URL error:error])
        return nil;
    VIMMachine *machine = [self new];
    machine->_URL = URL;
    machine->_configuration = [c copy];
    (void)machine.diskCapacityBytes; // Warm on the library's background scan.
    return machine;
}
- (BOOL)requiresInstallerDisplay {
    return [VIMMachineModel configuration:self.configuration
        requiresInstallerDisplayWithJournal:[self plist:@"State/GuestInstallation.plist"]
                                    updater:[self plist:@"State/UpdateDisplay.plist"]
                              nativeDisplay:[self plist:@"State/NativeBigSurDisplay.plist"]
                   firmwareSelectsInstaller:self.firmwareSelectsInstaller];
}
- (BOOL)prepareNativeBigSurDisplayWithGuestReport:(NSDictionary *)report error:(NSError **)error {
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
    if (![VIMMachineModel report:report admitsAutomaticInstallationOnConfiguration:self.configuration])
        return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in @[ @"GuestPreparation.plist", @"GuestInstallation.plist", @"AutomaticInstallation.plist" ])
        if ([fm fileExistsAtPath:[self.URL URLByAppendingPathComponent:[@"State" stringByAppendingPathComponent:name]]
                                     .path])
            return NO;
    if (![VIMMachineModel ownership:[self plist:@"Installation/Ownership.plist"]
            admitsClaimByConfiguration:self.configuration])
        return NO;
    NSDictionary *claim = @{
        @"FormatVersion" : @1,
        @"MachineIdentifier" : self.configuration[@"Identifier"],
        @"Phase" : @"claimed",
        @"GuestReport" : report,
        @"StartedAt" : NSDate.date
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:claim
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:error];
    return data && [data writeToURL:[self.URL URLByAppendingPathComponent:@"State/AutomaticInstallation.plist"]
                            options:NSDataWritingWithoutOverwriting
                              error:error];
}
- (BOOL)claimAutomaticUpdateRepairWithGuestReport:(NSDictionary *)report error:(NSError **)error {
    return [self authorizeUpdateRepair:report claim:YES error:error];
}
- (BOOL)canRepairUpdatedSystemWithGuestReport:(NSDictionary *)report error:(NSError **)error {
    return [self authorizeUpdateRepair:report claim:NO error:error];
}
- (BOOL)authorizeUpdateRepair:(NSDictionary *)report claim:(BOOL)claim error:(NSError **)error {
    // Unlike initial installation, repair must not require Finder: an update may replace the very driver or framework
    // that permits WindowServer to run. The verified transaction and the exclusive once-per-build claim below remain
    // mandatory before authorizing any write.
    if (![VIMMachineModel report:report admitsUpdateRepairForGuest:self.guest])
        return NO;
    NSString *build = report[@"ProductBuildVersion"];
    int lock = ConfigurationLock(self.URL, error);
    if (lock < 0)
        return NO;
    @try {
        NSURL *journal = [self.URL URLByAppendingPathComponent:@"State/GuestInstallation.plist"];
        NSDictionary *state = [NSDictionary dictionaryWithContentsOfURL:journal];
        NSString *identity = state[@"TransactionID"];
        NSDictionary *verified = state[@"PostBootVerification"] ?: state[@"PreviousPostBootVerification"];
        // A read-only reconciliation after an update can already have reported
        // an old-build verification failure. Retain the last proven success;
        // never treat an unverified/interrupted new write as permission to
        // retry. A failed read of a completed *old-build* transaction is
        // different: the retained Metal proof, ID, disk and build must agree.
        if (![VIMMachineModel verifiedInstallationSuperseded:state report:report])
            return NO;
        NSString *previous = verified[@"ProductBuildVersion"];
        if (!claim)
            return YES;
        NSURL *directory = [self.URL URLByAppendingPathComponent:@"State/UpdateRepairs" isDirectory:YES];
        if (mkdir(directory.fileSystemRepresentation, 0700) && errno != EEXIST)
            return Fail(error, @"The macOS update’s graphics setup record could not be saved. Make sure the library "
                               @"drive is connected and writable, then restart the virtual Mac.");
        struct stat info;
        if (lstat(directory.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode))
            return Fail(
                error,
                @"The macOS update repair records folder is not a regular folder. No automatic repair was started.");
        NSURL *claim = [directory URLByAppendingPathComponent:[build stringByAppendingPathExtension:@"plist"]];
        NSDictionary *record = @{
            @"FormatVersion" : @1,
            @"MachineIdentifier" : self.configuration[@"Identifier"],
            @"Phase" : @"claimed",
            @"PreviousTransactionID" : identity,
            @"PreviousBuild" : previous,
            @"GuestReport" : report,
            @"StartedAt" : NSDate.date
        };
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0
                                                                   error:error];
        NSError *writeError = nil;
        if (data && [data writeToURL:claim options:NSDataWritingWithoutOverwriting error:&writeError])
            return YES;
        // Recover only a pre-dispatch failure: the old proven journal is still
        // present with its original ID and a failed *read*. A dispatched new
        // installation exclusively creates a new ID/journal after archival,
        // so it cannot satisfy this condition. Never reuse that new attempt.
        if (writeError.code == NSFileWriteFileExistsError && [writeError.domain isEqual:NSCocoaErrorDomain]) {
            NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:claim];
            if (![VIMMachineModel journal:state
                    allowsRepairRecoveryOfClaim:saved
                                  configuration:self.configuration
                                         report:report])
                return NO;
            NSMutableDictionary *recovery = [saved mutableCopy];
            recovery[@"Phase"] = @"preflight-recovered";
            recovery[@"RecoveredAt"] = NSDate.date;
            recovery[@"RecoveryGuestReport"] = report;
            // A separate durable transition bounds this migration to once,
            // even if preparation subsequently fails or the app restarts.
            return Save(recovery, claim, error);
        }
        if (error && writeError)
            *error = writeError;
        return NO;
    } @finally {
        close(lock);
    }
}
- (BOOL)retryInstallerCleanup:(NSError **)error {
    if (self.preMetalGuest)
        return [self retryOpenGLInstallerCleanup:error];
    NSDictionary *pending = [self plist:@"State/Install.plist"];
    if (![pending[@"Phase"] isEqual:@"cleanup-pending"]) {
        // Verification is durable, but the session's completionGuestReport is
        // not. Recover it after an app restart/close instead of indefinitely
        // retaining the installer when the original session no longer exists.
        NSDictionary *installation = [self plist:@"State/GuestInstallation.plist"];
        if (!self.configuration[@"InstallerMedia"] || ![installation[@"Phase"] isEqual:@"graphics-verified"])
            return YES;
        NSDictionary *observed = [self plist:@"State/GuestStatus.plist"];
        NSDictionary *report = observed[@"Report"];
        if (![report isKindOfClass:NSDictionary.class])
            return Fail(error, @"Saved guest status is unavailable. Installer media was retained.");
        // finishInstallation rechecks the transaction, boot, volume, guest,
        // ownership and stopped-session lock before changing any media.
        return [self finishInstallationWithGuestReport:report error:error];
    }
    if (![pending[@"Identifier"] isEqual:self.configuration[@"Identifier"]] ||
        ![pending[@"GuestReport"] isKindOfClass:NSDictionary.class])
        return Fail(error, @"Saved installer cleanup does not match this Mac. Media was retained.");
    return [self finishInstallationWithGuestReport:pending[@"GuestReport"] error:error];
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
- (BOOL)retryOpenGLInstallerCleanup:(NSError **)error {
    NSDictionary *finished = [self plist:@"State/Install.plist"];
    if ([finished[@"Phase"] isEqual:@"complete"] && [finished[@"Identifier"] isEqual:self.configuration[@"Identifier"]])
        return YES;
    NSDictionary *receipt = [self plist:@"State/LegacyGuestInstallation.plist"];
    if (![receipt[@"Phase"] isEqual:@"graphics-verified"])
        return YES;
    // Called before session acquisition or after QEMU exit, never on a live
    // optical backend. Use the same lifetime lock as modern cleanup.
    int fd = open([[self.URL URLByAppendingPathComponent:@"State/Session.lock"] fileSystemRepresentation],
                  O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB)) {
        if (fd >= 0)
            close(fd);
        return Fail(error, @"Shut down this Mac before retiring its installer files.");
    }
    @try {
        VIMMachine *fresh = [VIMMachine loadURL:self.URL error:error];
        if (!fresh)
            return NO;
        if (fresh.configuration[@"InstallerMedia"] || ![fresh.configuration[@"InstallState"] isEqual:@"installed"] ||
            ![receipt[@"MachineIdentifier"] isEqual:fresh.configuration[@"Identifier"]])
            return Fail(error, @"Installer cleanup is not yet authorized for this Mac.");
        NSDictionary *owner = [self plist:@"Installation/Ownership.plist"];
        if (!owner)
            return YES;
        if (![owner[@"MachineIdentifier"] isEqual:fresh.configuration[@"Identifier"]])
            return Fail(error, @"Installer ownership changed. Its files were retained.");
        BOOL removed = RemovePreparedMedia(owner[@"Media"], self.URL);
        NSDictionary *profile = [self plist:@"State/AutomaticSetup.plist"];
        if (profile[@"CredentialIdentifier"] &&
            ![VIMAutomaticSetup removePasswordForIdentifier:profile[@"CredentialIdentifier"] error:error])
            return NO;
        return Save(@{
            @"Phase" : @"complete",
            @"Identifier" : fresh.configuration[@"Identifier"],
            @"InstallerDetached" : @YES,
            @"SharedMediaRetained" : @(!removed),
            @"CompletedAt" : NSDate.date
        },
                    [self.URL URLByAppendingPathComponent:@"State/Install.plist"], error);
    } @finally {
        close(fd);
    }
}
- (BOOL)finishInstallationWithGuestReport:(NSDictionary *)report error:(NSError **)error {
    NSURL *lock = [self.URL URLByAppendingPathComponent:@"State/Session.lock"];
    int fd = open(lock.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat info;
    if (fd < 0 || fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_nlink != 1 || flock(fd, LOCK_EX | LOCK_NB)) {
        if (fd >= 0)
            close(fd);
        return Fail(error, @"Shut down this Mac before finishing installer cleanup.");
    }
    @try {
        VIMMachine *fresh = [VIMMachine loadURL:self.URL error:error];
        if (!fresh)
            return NO;
        NSDictionary *state = [self plist:@"State/GuestInstallation.plist"];
        NSDictionary *verified = state[@"PostBootVerification"];
        if (![VIMMachineModel journal:state authorizesInstallerCleanupWithReport:report guest:fresh.guest])
            return Fail(
                error,
                @"Matching completed guest installation and graphics verification are required. Media was retained.");
        NSURL *media = [self.URL URLByAppendingPathComponent:@"Installation/Installer.iso"];
        NSDictionary *owner = [self plist:@"Installation/Ownership.plist"];
        // Shared library media belongs to the download cache, not this VM. Detach
        // it after verification, but never delete another VM's or user's ISO.
        if ([fresh.configuration[@"InstallerMediaShared"] isEqual:@YES]) {
            if (![VIMMachineModel ownership:owner namesConfiguration:fresh.configuration])
                return Fail(error, @"Installer reference does not match its record.");
            NSDictionary *config = [VIMMachineModel configurationFinishingWithSharedInstaller:fresh.configuration];
            if (!Save(config, [self.URL URLByAppendingPathComponent:@"Machine.plist"], error))
                return NO;
            _configuration = [config copy];
            BOOL removed = RemovePreparedMedia(fresh.configuration[@"InstallerMedia"], self.URL);
            return Save(@{
                @"Phase" : @"complete",
                @"Identifier" : config[@"Identifier"],
                @"InstallerDetached" : @YES,
                @"SharedMediaRetained" : @(!removed),
                @"CompletedAt" : NSDate.date
            },
                        [self.URL URLByAppendingPathComponent:@"State/Install.plist"], error);
        }
        if (![VIMMachineModel ownership:owner admitsOwnedCleanupByConfiguration:fresh.configuration])
            return Fail(error, @"Installer ownership could not be established. Media was retained.");
        // Never follow a relocated Installation directory or delete a linked file.
        if (![media.URLByResolvingSymlinksInPath.path isEqual:media.path])
            return Fail(error, @"Installer media has been relocated. Automatic cleanup is unavailable.");
        BOOL exists = lstat(media.fileSystemRepresentation, &info) == 0;
        if (!exists && errno != ENOENT)
            return Fail(error, @"Cannot inspect installer media.");
        if (exists && (!S_ISREG(info.st_mode) || info.st_nlink != 1 || info.st_size <= 0 ||
                       (uint64_t)info.st_size != [owner[@"Size"] unsignedLongLongValue]))
            return Fail(error, @"Installer media no longer matches its ownership record.");
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *key in @[ @"BootMedia", @"Disk", @"Firmware", @"NVRAM" ])
            if ([[[self.URL URLByAppendingPathComponent:fresh.configuration[key]] URLByResolvingSymlinksInPath].path
                    isEqual:media.path])
                return Fail(error, @"Installer media is still used by another device in this Mac.");
        NSArray *siblings = [fm contentsOfDirectoryAtURL:self.URL.URLByDeletingLastPathComponent
                              includingPropertiesForKeys:nil
                                                 options:0
                                                   error:error];
        if (!siblings)
            return NO;
        for (NSURL *sibling in siblings) {
            if (![sibling.pathExtension isEqual:@"vintelmac"] ||
                [sibling.URLByResolvingSymlinksInPath.path isEqual:self.URL.path])
                continue;
            NSDictionary *config =
                [NSDictionary dictionaryWithContentsOfURL:[sibling URLByAppendingPathComponent:@"Machine.plist"]];
            if (!config)
                return Fail(error, @"Another Mac's configuration could not be checked. Media was retained.");
            for (NSString *key in @[ @"InstallerMedia", @"BootMedia", @"Disk", @"Firmware", @"NVRAM" ]) {
                NSString *relative = config[key];
                if (![relative isKindOfClass:NSString.class])
                    continue;
                NSURL *reference = [sibling URLByAppendingPathComponent:relative].URLByResolvingSymlinksInPath;
                if ([reference.path isEqual:media.path])
                    return Fail(error, @"Another Mac still references this installer.");
            }
        }
        NSDictionary *config = [VIMMachineModel configurationFinishingWithOwnedInstaller:fresh.configuration];
        // Persist the validated evidence before retiring routing. A deletion or
        // final journal failure can then be retried after app/process restart.
        if (!Save(@{
                @"Phase" : @"cleanup-pending",
                @"Identifier" : config[@"Identifier"],
                @"TransactionID" : verified[@"TransactionID"],
                @"GuestReport" : report,
                @"UpdatedAt" : NSDate.date
            },
                  [self.URL URLByAppendingPathComponent:@"State/Install.plist"], error))
            return NO;
        // Config first: a crash can leave surplus media, never a dangling boot
        // reference. A subsequent call can finish the same cleanup idempotently.
        if (!Save(config, [self.URL URLByAppendingPathComponent:@"Machine.plist"], error))
            return NO;
        _configuration = [config copy];
        BOOL keep = [NSUserDefaults.standardUserDefaults boolForKey:@"VIMKeepInstallers"];
        if (exists && !keep && ![fm removeItemAtURL:media error:error])
            return NO;
        return Save(@{
            @"Phase" : @"complete",
            @"Identifier" : config[@"Identifier"],
            @"TransactionID" : verified[@"TransactionID"],
            @"InstallerMediaRemoved" : @(!keep),
            @"CompletedAt" : NSDate.date
        },
                    [self.URL URLByAppendingPathComponent:@"State/Install.plist"], error);
    } @finally {
        flock(fd, LOCK_UN);
        close(fd);
    }
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
    if (!Supported(guest) || !NameValid(name)) {
        Fail(error, @"Unsupported guest or invalid name.");
        return nil;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    library = [VIMLibraryLocation machinesURLForLibrary:library];
    if (![fm createDirectoryAtURL:library withIntermediateDirectories:YES attributes:nil error:error])
        return nil;
    for (NSURL *input in @[ disk, firmware, nvram, bootMedia, qemuImage ]) {
        NSNumber *regular = nil;
        if (!input.isFileURL || ![input getResourceValue:&regular forKey:NSURLIsRegularFileKey error:error] ||
            !regular.boolValue)
            return nil;
    }
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSURL *stage = [library URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.importing", identifier]];
    NSURL *destination = [VIMMachineModel newPackageURLForName:name inLibrary:library];
    name = destination.lastPathComponent.stringByDeletingPathExtension;
    if (![fm createDirectoryAtURL:stage withIntermediateDirectories:NO attributes:nil error:error])
        return nil;
    // Import is a snapshot copy: qemu-img reads/locks the entire source chain.
    // Never use -U (force-share), rebase originals, or copy a live writable disk.
    NSURL *info = [stage URLByAppendingPathComponent:@"SourceDisk.json"];
    if (!Run(qemuImage, @[ @"info", @"--output=json", disk.path ], info, error))
        return nil;
    NSData *infoData = [NSData dataWithContentsOfURL:info];
    NSDictionary *metadata = infoData ? [NSJSONSerialization JSONObjectWithData:infoData options:0 error:error] : nil;
    if (![metadata isKindOfClass:NSDictionary.class] || ![metadata[@"format"] isEqual:@"qcow2"] ||
        ![metadata[@"virtual-size"] isKindOfClass:NSNumber.class]) {
        Fail(error, @"Import requires a valid QCOW2 disk.");
        return nil;
    }
    NSDictionary *space = [fm attributesOfFileSystemForPath:library.path error:error];
    // Conservative worst-case admission; sparse output usually uses much less.
    unsigned long long required = [metadata[@"virtual-size"] unsignedLongLongValue];
    unsigned long long free = [space[NSFileSystemFreeSize] unsignedLongLongValue];
    if (!required || free < required || free - required < (2ULL << 30)) {
        Fail(error, @"The selected library needs more free space for a safe import.");
        return nil;
    }
    for (NSString *directory in @[ @"Disks", @"Firmware", @"Logs", @"State" ])
        if (![fm createDirectoryAtURL:[stage URLByAppendingPathComponent:directory]
                withIntermediateDirectories:NO
                                 attributes:nil
                                      error:error])
            return nil;
    NSDictionary *journal = @{@"Phase" : @"importing", @"Source" : disk.path, @"Identifier" : identifier};
    if (!Save(journal, [stage URLByAppendingPathComponent:@"State/Import.plist"], error))
        return nil;
    NSURL *target = [stage URLByAppendingPathComponent:@"Disks/System.qcow2"];
    if (!Run(qemuImage, @[ @"convert", @"-p", @"-f", @"qcow2", @"-O", @"qcow2", disk.path, target.path ],
             [stage URLByAppendingPathComponent:@"Logs/Import.log"], error))
        return nil;
    if (!Run(qemuImage, @[ @"info", @"--output=json", target.path ], [stage URLByAppendingPathComponent:@"Disk.json"],
             error))
        return nil;
    NSDictionary *result = [NSJSONSerialization
        JSONObjectWithData:[NSData dataWithContentsOfURL:[stage URLByAppendingPathComponent:@"Disk.json"]]
                   options:0
                     error:error];
    if (![result isKindOfClass:NSDictionary.class] || result[@"backing-filename"] ||
        ![result[@"virtual-size"] isEqual:metadata[@"virtual-size"]]) {
        Fail(error, @"The imported disk did not pass the independence check.");
        return nil;
    }
    NSArray *sources = @[ firmware, nvram, bootMedia ];
    BOOL efiDisk = EFIDisk(bootMedia);
    NSArray *paths =
        @[ @"Firmware/CODE.fd", @"Firmware/NVRAM.fd", efiDisk ? @"Firmware/EFI.img" : @"Firmware/OpenCore.iso" ];
    for (NSUInteger i = 1; i < 2; i++)
        if (![fm copyItemAtURL:[sources[i] URLByResolvingSymlinksInPath]
                         toURL:[stage URLByAppendingPathComponent:paths[i]]
                         error:error])
            return nil;
    NSDictionary *c = VIMNetworkConfigurationWithDefaults(@{
        @"FormatVersion" : @1,
        @"Identifier" : identifier,
        @"Guest" : guest,
        @"Disk" : @"Disks/System.qcow2",
        @"Firmware" : paths[0],
        @"NVRAM" : paths[1],
        @"BootMedia" : paths[2],
        @"BootMediaKind" : efiDisk ? @"efi-disk" : @"legacy-opencore-iso",
        @"CPUCount" : @4,
        @"MemoryMiB" : @4096,
        @"FirmwareSource" : @"application",
        @"InstallState" : @"imported-prepared",
        @"ImportedFrom" : disk.path
    },
                                                          library, destination);
    if (!c) {
        Fail(
            error,
            @"No local connection ports are available. Close unused virtual Macs or network services, then try again.");
        return nil;
    }
    if (!Save(c, [stage URLByAppendingPathComponent:@"Machine.plist"], error) ||
        !Save(@{@"Phase" : @"complete", @"Source" : disk.path},
              [stage URLByAppendingPathComponent:@"State/Import.plist"], error) ||
        ![fm moveItemAtURL:stage toURL:destination error:error])
        return nil;
    return [self loadURL:destination error:error];
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
    if (!Supported(guest) || !NameValid(name) || diskGiB < 40 || diskGiB > 2048 || !library.isFileURL) {
        Fail(error, @"Choose a supported macOS version, a name, and a disk size from 40 to 2048 GB.");
        return nil;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    library = [VIMLibraryLocation machinesURLForLibrary:library];
    if (![fm createDirectoryAtURL:library withIntermediateDirectories:YES attributes:nil error:error])
        return nil;
    for (NSURL *input in @[ firmware, nvram, bootMedia, installer, qemuImage ]) {
        NSNumber *regular = nil;
        // Bundled per-OS firmware paths intentionally alias the shared image.
        // Validate the actual file, just as copying and runtime lookup do;
        // NSURLIsRegularFileKey on the alias itself reports a symbolic link.
        if (!input.isFileURL ||
            ![input.URLByResolvingSymlinksInPath getResourceValue:&regular forKey:NSURLIsRegularFileKey error:error] ||
            !regular.boolValue) {
            Fail(error, @"A required firmware, installer, or disk tool file is missing.");
            return nil;
        }
    }
    NSDictionary *attributes = [fm attributesOfItemAtPath:installer.path error:error];
    NSDictionary *space = [fm attributesOfFileSystemForPath:library.path error:error];
    if (!attributes || !space)
        return nil;
    uint64_t imageSize = [attributes[NSFileSize] unsignedLongLongValue];
    uint64_t free = [space[NSFileSystemFreeSize] unsignedLongLongValue];
    // Installer media is shared in place, not copied into every VM. The disk
    // is sparse: require room for an installed system, not its full capacity.
    uint64_t diskSize = MIN((uint64_t)diskGiB, 24ULL) << 30;
    if (!imageSize || free < diskSize + (2ULL << 30)) {
        Fail(error, @"The library needs enough free space for the requested disk.");
        return nil;
    }
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSURL *stage = [library URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.creating", identifier]];
    NSURL *destination = [VIMMachineModel newPackageURLForName:name inLibrary:library];
    name = destination.lastPathComponent.stringByDeletingPathExtension;
    if (![fm createDirectoryAtURL:stage withIntermediateDirectories:NO attributes:nil error:error])
        return nil;
    for (NSString *folder in @[ @"Disks", @"Firmware", @"State", @"Logs", @"Installation" ])
        if (![fm createDirectoryAtURL:[stage URLByAppendingPathComponent:folder]
                withIntermediateDirectories:NO
                                 attributes:nil
                                      error:error])
            return nil;
    if (!Save(@{@"Phase" : @"creating", @"Identifier" : identifier},
              [stage URLByAppendingPathComponent:@"State/Install.plist"], error))
        return nil;
    BOOL tigerResearch = [guest isEqual:@"tiger"] && OpenGLResearchEnabled();
    // The new-disk identity is needed by native unattended installation too,
    // independent of which graphics stack this release uses.
    if (!CreateFormattedDisk(stage, qemuImage, diskGiB, YES, error))
        return nil;
    NSArray *sources = @[ firmware, nvram, bootMedia, installer ];
    BOOL efiDisk = EFIDisk(bootMedia);
    NSArray *paths = @[
        @"Firmware/CODE.fd", @"Firmware/NVRAM.fd", efiDisk ? @"Firmware/EFI.img" : @"Firmware/OpenCore.iso",
        installer.URLByResolvingSymlinksInPath.path
    ];
    for (NSUInteger i = tigerResearch ? 0 : 1; i < (tigerResearch ? 3 : 2); i++)
        if (![fm copyItemAtURL:[sources[i] URLByResolvingSymlinksInPath]
                         toURL:[stage URLByAppendingPathComponent:paths[i]]
                         error:error])
            return nil;
    // Ownership identity is distinct from BootMedia. Later cleanup must verify
    // it and authoritative guest completion; a desktop frame is not completion.
    if (!Save(@{@"FormatVersion" : @1, @"MachineIdentifier" : identifier, @"Media" : paths[3], @"Size" : @(imageSize)},
              [stage URLByAppendingPathComponent:@"Installation/Ownership.plist"], error))
        return nil;
    NSMutableDictionary *configuration = [VIMNetworkConfigurationWithDefaults(@{
        @"FormatVersion" : @1,
        @"Identifier" : identifier,
        @"Guest" : guest,
        @"CPUCount" : @4,
        @"MemoryMiB" : @4096,
        @"Disk" : @"Disks/System.qcow2",
        @"DiskGiB" : @(diskGiB),
        @"Firmware" : paths[0],
        @"NVRAM" : paths[1],
        @"BootMedia" : paths[2],
        @"BootMediaKind" : efiDisk ? @"efi-disk" : @"legacy-opencore-iso",
        @"FirmwareSource" : @"application",
        @"InstallerMediaShared" : @YES,
        @"InstallerMedia" : paths[3],
        @"InstallerMediaKind" : EFIDisk(installer) ? @"disk" : @"optical",
        @"InstallState" : @"installing"
    },
                                                                              library, destination) mutableCopy];
    if (!configuration) {
        Fail(
            error,
            @"No local connection ports are available. Close unused virtual Macs or network services, then try again.");
        return nil;
    }
    if (tigerResearch) {
        configuration[@"FirmwareSource"] = @"package";
    }
    if ([guest isEqual:@"tiger"]) {
        configuration[@"LegacyDisplayAdapter"] = @"vmware";
        configuration[@"DisplayMode"] = @"scaled";
        configuration[@"PassthroughOpenGLEnabled"] = @NO;
    }
    if (VIMGuestUsesOpenGLDesktop(guest)) {
        configuration[@"LegacyDisplayAdapter"] = @"vmware";
        configuration[@"PassthroughOpenGLEnabled"] = @YES;
    }
    if (!Save(configuration, [stage URLByAppendingPathComponent:@"Machine.plist"], error) ||
        !Save(@{@"Phase" : @"awaiting-os-install", @"Identifier" : identifier},
              [stage URLByAppendingPathComponent:@"State/Install.plist"], error) ||
        ![fm moveItemAtURL:stage toURL:destination error:error])
        return nil;
    return [self loadURL:destination error:error];
}
@end
