// Runs what InstallerKit decides: tool commands, per-guest media and edits, what inputs are, receipts and messages.
// What's left here is ordering, process supervision and file operations.
//
// Every disk write is marked WRITES or ERASES. Each stays inside the fresh job directory it created, the working
// copy attached from that job, an app-owned completed download, or a temporary directory of its own. Originals are only
// ever attached read-only, a device is only ever read, and nothing here runs a command that can erase or partition a
// disk.
#import "VIMInstallerAssembly.h"
#import "VIMGuestFiles.h"
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <errno.h>
#import <math.h>
#import "VIMLibraryLocation.h"
#import "VIMInstallerSource.h"
#import "VIMInstallerCatalog.h"
#import "VIMTigerRestoreProfile.h"
#import "VIMTigerInstallerSupport.h"
#include "VIMHFSInstallerDisk.h"
#include <sys/file.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

static BOOL AssemblyError(NSError **error, VIMAssemblyFailure failure) {
    if (error)
        *error = [VIMAssemblyFailureError errorForFailure:failure];
    return NO;
}
static BOOL RegularFile(NSURL *URL) {
    NSNumber *regular = nil;
    return URL.isFileURL && [URL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil] && regular.boolValue;
}
static BOOL NonemptyFile(NSURL *URL) {
    NSNumber *size = nil;
    return RegularFile(URL) && [URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil] &&
           size.unsignedLongLongValue > 0;
}
// Only for newly generated output, never an original installer or VM disk.
// A successful image-tool exit and mounted readback can both see cached data.
// Commit the output before retiring its working files, and use a fresh POSIX
// size rather than an NSURL resource-value cache for the completion receipt.
static NSNumber *FlushGeneratedImage(NSURL *URL, NSError **error) {
    // Read-write only to flush: writes no bytes. Refuses a symlink, a hard link or a file replaced meanwhile.
    int fd = open(URL.fileSystemRepresentation, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    struct stat before, after, path;
    BOOL valid =
        fd >= 0 && !fstat(fd, &before) && S_ISREG(before.st_mode) && before.st_nlink == 1 && before.st_size > 0;
    int result = -1;
    if (valid) {
        do {
            result = fsync(fd);
        } while (result < 0 && errno == EINTR);
    }
    if (valid && result == 0) {
        do {
            result = fcntl(fd, F_FULLFSYNC);
        } while (result < 0 && errno == EINTR);
        // Some external filesystems do not implement the stronger drive-cache
        // operation. Their successful fsync is still required, not ignored.
        if (result < 0 && (errno == EINVAL || errno == ENOTSUP))
            result = 0;
    }
    valid = valid && result == 0 && !fstat(fd, &after) && after.st_size == before.st_size &&
            !lstat(URL.fileSystemRepresentation, &path) && S_ISREG(path.st_mode) && path.st_dev == after.st_dev &&
            path.st_ino == after.st_ino && path.st_size == after.st_size;
    if (fd >= 0 && close(fd))
        valid = NO;
    if (!valid) {
        AssemblyError(error, VIMAssemblyFailureImageNotSavedReliably);
        return nil;
    }
    return @(after.st_size);
}
// WRITES a file on the generated working copy, never a source installer. Keeps
// its inode and catalog owner, and adds write permission only while saving.
static BOOL RewriteGeneratedFile(NSURL *file, NSData *bytes, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSNumber *mode = [fm attributesOfItemAtPath:file.path error:error][NSFilePosixPermissions];
    if (!mode)
        return NO;
    BOOL saved = [fm setAttributes:@{
                     NSFilePosixPermissions : @(mode.unsignedIntValue | 0200)
                 }
                      ofItemAtPath:file.path
                             error:error] &&
                 bytes && [bytes writeToURL:file options:0 error:error];
    NSError *restore = nil;
    if (![fm setAttributes:@{NSFilePosixPermissions : mode} ofItemAtPath:file.path error:&restore]) {
        if (error)
            *error = restore;
        return NO;
    }
    return saved;
}
static BOOL UnlinkedDirectory(NSURL *URL) {
    struct stat st;
    return !lstat(URL.fileSystemRepresentation, &st) && S_ISDIR(st.st_mode);
}
static BOOL LeopardRestoreProfile(NSURL *mount, NSString *guest, NSError **error) {
    return [VIMInstallerInspection restoreDiscIsCompleteAtMount:mount guest:guest] ||
           AssemblyError(error, VIMAssemblyFailureIncompleteLeopardDisc);
}
// Receipts are written last, so one's presence means everything before it finished.
// WRITES a job's receipt, atomically.
static BOOL WriteReceipt(NSDictionary *receipt, NSURL *URL, NSError **error) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:receipt
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:error];
    return data && [data writeToURL:URL options:NSDataWritingAtomic error:error];
}
static NSURL *MountDirectory(NSError **error) {
    // macOS rejected our mount point beneath the external exFAT volume.
    // Only this empty mount point is local; all image bytes stay on scratch.
    NSURL *URL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:[@"vim-installer-mount-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager createDirectoryAtURL:URL
                                withIntermediateDirectories:NO
                                                 attributes:@{
                                                     NSFilePosixPermissions : @0700
                                                 }
                                                      error:error])
        return nil;
    return URL;
}
@interface VIMInstallerAssembly ()
@property NSURL *job;
@property NSUInteger step;
@property NSURL *lastLog;
@property double workFraction;
@property double workEnd;
@property NSTimeInterval workEstimate;
@property NSString *stage;
@property NSString *progressGuest;
- (NSURL *)assembleMavericks:(NSURL *)esd
                       guest:(NSString *)guest
                jobDirectory:(NSURL *)directory
                       error:(NSError **)error;
- (NSURL *)assembleClassicDiskImage:(NSURL *)image
                              guest:(NSString *)guest
                       jobDirectory:(NSURL *)directory
                              error:(NSError **)error;
- (BOOL)removeRestoreModelRestrictionAtMount:(NSURL *)mount error:(NSError **)error;
- (BOOL)prepareLeopardRecoveryMemoryAtMount:(NSURL *)mount error:(NSError **)error;
- (BOOL)prepareSerialRecoveryAtMount:(NSURL *)mount error:(NSError **)error;
- (void)completedWork:(double)fraction;
- (BOOL)perform:(VIMToolInvocation *)command error:(NSError **)error;
@end
static bool HFSInstallerProgress(uint64_t completed, uint64_t total, void *context) {
    VIMInstallerAssembly *assembly = (__bridge VIMInstallerAssembly *)context;
    double fraction = .96 + .03 * (double)completed / (double)total;
    // Check cancellation every transfer; publish at most 30 visible updates.
    if (fraction - assembly.workFraction >= .001)
        [assembly completedWork:fraction];
    return !assembly.cancelled;
}
static bool HFSExtractionProgress(uint64_t completed, uint64_t total, void *context) {
    VIMInstallerAssembly *assembly = (__bridge VIMInstallerAssembly *)context;
    double fraction = .45 + .11 * (double)completed / (double)total;
    if (fraction - assembly.workFraction >= .001)
        [assembly completedWork:fraction];
    return !assembly.cancelled;
}
@implementation VIMInstallerAssembly
- (BOOL)extractWorkingHFSVolume:(NSURL *)working error:(NSError **)error {
    NSURL *mounted = MountDirectory(error);
    if (!mounted)
        return NO;
    NSURL *volume = [working.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Recovery-volume.img"];
    BOOL attached = [self perform:[VIMToolInvocation attachReadOnlyIgnoringOwnersImage:working.path
                                                                            mountPoint:mounted.path]
                            error:error];
    BOOL copied = NO;
    if (attached && [self perform:[VIMToolInvocation deviceInfoForMountPoint:mounted.path] error:error]) {
        VIMImagePartitionDevice *device =
            [VIMImagePartitionDevice deviceFromInfo:[NSDictionary dictionaryWithContentsOfURL:self.lastLog]
                                       requiringHFS:YES];
        if (device) {
            // WRITES the job's new volume (O_EXCL). Reads the raw node of the image attached read-only above, and
            // only a device that InstallerKit recognizes as that image's HFS partition.
            copied = VIMCopyHFSInstallerVolume(device.rawPath.fileSystemRepresentation, volume.fileSystemRepresentation,
                                               HFSExtractionProgress, (__bridge void *)self) == 0;
            if (!copied)
                AssemblyError(error, self.cancelled ? VIMAssemblyFailureCancelledWithDownloadSaved
                                                    : VIMAssemblyFailureHfsVolumeCopyFailed);
        } else
            AssemblyError(error, VIMAssemblyFailureHfsPartitionUnidentified);
    }
    BOOL detached = YES;
    if (attached) {
        NSError *issue = nil;
        detached = [self perform:[VIMToolInvocation detachMountPoint:mounted.path] error:&issue];
        if (!detached && error)
            *error = issue;
    }
    if (detached)
        rmdir(mounted.fileSystemRepresentation);
    if (!copied || !detached)
        return NO;
    // Only replace our unmounted generated working image. HFS catalog bytes,
    // UUID, system owners and blessing are preserved by the native block copy.
    // ERASES the job's own working image, by replacing it with its extracted volume.
    if (rename(volume.fileSystemRepresentation, working.fileSystemRepresentation))
        return AssemblyError(error, VIMAssemblyFailureWorkingVolumeNotSaved);
    return YES;
}
- (BOOL)prepareSerialRecoveryAtMount:(NSURL *)mount error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *tool = self.recoveryControlTool ?: VIMGuestFileURL(@"GuestTools/guest-recovery-agent");
    if (!NonemptyFile(tool))
        return AssemblyError(error, VIMAssemblyFailureInstallerSupportMissing);
    NSURL *rc = [mount URLByAppendingPathComponent:@"private/etc/rc.install"];
    NSString *original = [NSString stringWithContentsOfURL:rc encoding:NSUTF8StringEncoding error:error];
    if (!original)
        return NO;
    // com.apple.install.cd launches rc.install, not the retained rc.cdrom.
    if (![VIMRecoveryText hasSerialHook:original])
        return AssemblyError(error, VIMAssemblyFailureSerialHookUnrecognized);
    NSURL *destination = [mount URLByAppendingPathComponent:@"usr/libexec/guest-recovery-agent"];
    // WRITES the attached working copy, after the hook above proved this is the measured rc.install.
    if (![fm copyItemAtURL:tool toURL:destination error:error] || ![fm setAttributes:@{NSFilePosixPermissions : @0755}
                                                                        ofItemAtPath:destination.path
                                                                               error:error])
        return NO;
    NSURL *hook = [mount URLByAppendingPathComponent:@"private/etc/rc.cdrom.local"];
    return ![fm fileExistsAtPath:hook.path] &&
           [VIMRecoveryText.serialHookScript writeToURL:hook atomically:NO encoding:NSUTF8StringEncoding error:error] &&
           [fm setAttributes:@{NSFilePosixPermissions : @0755} ofItemAtPath:hook.path error:error];
}
- (BOOL)prepareLeopardRecoveryMemoryAtMount:(NSURL *)mount error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *model = [mount URLByAppendingPathComponent:@"usr/libexec/cpu_check"];
    // WRITES the attached working copy: a recognized model check, then rc.cdrom's RAMDisk budgets.
    if ([fm fileExistsAtPath:model.path]) {
        NSString *bypass = [VIMRecoveryText bypassingModelCheck:[NSString stringWithContentsOfURL:model
                                                                                         encoding:NSUTF8StringEncoding
                                                                                            error:NULL]];
        if (bypass && !RewriteGeneratedFile(model, [bypass dataUsingEncoding:NSUTF8StringEncoding], error))
            return NO;
    }
    NSURL *script = [mount URLByAppendingPathComponent:@"etc/rc.cdrom"];
    if (![fm fileExistsAtPath:script.path])
        return YES;
    NSString *text = [NSString stringWithContentsOfURL:script encoding:NSUTF8StringEncoding error:error];
    if (!text)
        return NO;
    return RewriteGeneratedFile(
        script, [[VIMRecoveryText raisingRAMDiskBudgets:text] dataUsingEncoding:NSUTF8StringEncoding], error);
}
+ (BOOL)validatePreparedMedia:(NSURL *)URL guest:(NSString *)guest error:(NSError **)error {
    return [VIMInstallerInspection validatePreparedMedia:URL guest:guest error:error];
}
+ (void)retireCompletedDownloads:(NSDictionary<NSString *, NSURL *> *)files {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSURL *file in files.allValues) {
        NSURL *directory = file.URLByDeletingLastPathComponent;
        // Do not follow symlinks or remove arbitrary caller-provided sources.
        if (![VIMDownloadRetirement isOwnedPayload:file] || !UnlinkedDirectory(directory))
            continue;
        int fd = open([directory URLByAppendingPathComponent:@"Download.lock"].fileSystemRepresentation,
                      O_RDWR | O_NOFOLLOW | O_CLOEXEC);
        struct stat st;
        if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_nlink != 1 || flock(fd, LOCK_EX | LOCK_NB)) {
            if (fd >= 0)
                close(fd);
            continue;
        }
        NSDictionary *record =
            [NSDictionary dictionaryWithContentsOfURL:[directory URLByAppendingPathComponent:@"Download.plist"]];
        if (!lstat(file.fileSystemRepresentation, &st) && S_ISREG(st.st_mode) && st.st_nlink == 1 &&
            [VIMDownloadRetirement record:record allowsRemovalOfPayloadWithSize:st.st_size]) {
            // Payload first, then the completion record: interruption leaves a
            // stale record, which beginTransfer can safely restart below.
            // ERASES a completed download: only an owned payload path, holding its lock, a plain single-link file of
            // the recorded length, from an approved source.
            if ([fm removeItemAtURL:file error:nil])
                [fm removeItemAtURL:[directory URLByAppendingPathComponent:@"Download.plist"] error:nil];
        }
        close(fd);
    }
}
+ (NSDictionary<NSString *, NSURL *> *)retainedInstallerForGuest:(NSString *)guest library:(NSURL *)library {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"VIMKeepInstallers"])
        return @{};
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *root = [VIMLibraryLocation installersURLForMachines:library].URLByResolvingSymlinksInPath;
    NSArray *attempts =
        [[fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0
                                 error:nil] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
          NSDate *ad = nil, *bd = nil;
          [a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil];
          [b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil];
          return [bd compare:ad];
        }];
    NSMutableDictionary *found = [NSMutableDictionary new];
    for (NSURL *attempt in attempts) {
        if (![[NSUUID alloc] initWithUUIDString:attempt.lastPathComponent] || !UnlinkedDirectory(attempt))
            continue;
        NSURL *mediaDir = [attempt URLByAppendingPathComponent:@"Media"];
        NSDictionary *media =
            [NSDictionary dictionaryWithContentsOfURL:[mediaDir URLByAppendingPathComponent:@"Media.plist"]];
        NSString *mediaName = [VIMPreparationRecords retainedImageNameInRecord:media guest:guest];
        if (!found[@"Media"] && mediaName) {
            NSURL *url = [mediaDir URLByAppendingPathComponent:mediaName];
            struct stat st;
            if (UnlinkedDirectory(mediaDir) && !lstat(url.fileSystemRepresentation, &st) && S_ISREG(st.st_mode) &&
                st.st_size > 0 && st.st_size == [media[@"Size"] longLongValue])
                found[@"Media"] = url;
        }
        NSURL *assembly = [attempt URLByAppendingPathComponent:@"Assembly"];
        NSDictionary *record =
            [NSDictionary dictionaryWithContentsOfURL:[assembly URLByAppendingPathComponent:@"Assembly.plist"]];
        NSString *name = [VIMPreparationRecords installerNameInRecord:record guest:guest];
        if (!found[@"SourceInstaller"] && name) {
            NSURL *url = [assembly URLByAppendingPathComponent:name];
            if (UnlinkedDirectory(assembly) && UnlinkedDirectory(url) &&
                [self validateInstallerApplication:url guest:guest error:nil])
                found[@"SourceInstaller"] = url;
        }
        if (found.count == 2)
            break;
    }
    return found;
}
+ (NSString *)guestForInstallerApplication:(NSURL *)URL error:(NSError **)error {
    if (RegularFile(URL) && ![URL.pathExtension.lowercaseString isEqual:@"app"]) {
        // Selection is a worker operation: inspect the actual read-only DVD,
        // never infer its OS from a filename or the selected creation row.
        if (![VIMInstallerInspection validateRestoreDiscImage:URL error:error])
            return nil;
        NSURL *mount = MountDirectory(error), *logs = MountDirectory(error);
        if (!mount || !logs) {
            if (mount)
                rmdir(mount.fileSystemRepresentation);
            if (logs)
                rmdir(logs.fileSystemRepresentation);
            return nil;
        }
        VIMInstallerAssembly *worker = [self new];
        worker.job = logs;
        BOOL attached = [worker perform:[VIMToolInvocation attachReadOnlyImage:URL.path mountPoint:mount.path]
                                  error:error];
        NSString *guest = nil;
        if (attached) {
            NSDictionary *version = [NSDictionary
                dictionaryWithContentsOfURL:
                    [mount URLByAppendingPathComponent:@"System/Library/CoreServices/SystemVersion.plist"]];
            // Versions name one disc each, so nothing falls through to another's checks.
            NSString *candidate = [VIMInstallerInspection restoreDiscGuestForProductVersion:version[@"ProductVersion"]];
            BOOL complete = [VIMGuestMediaPlan planForGuest:candidate].restoreDisc == VIMRestoreDiscKindTiger
                                ? VIMTigerValidateRestoreDVD(mount, error)
                                : [VIMInstallerInspection restoreDiscIsCompleteAtMount:mount guest:candidate];
            if (complete)
                guest = candidate;
            else
                AssemblyError(error, VIMAssemblyFailureUnsupportedRestoreDisc);
        }
        NSError *detachError = nil;
        BOOL detached = !attached || [worker perform:[VIMToolInvocation detachMountPoint:mount.path]
                                               error:&detachError];
        if (detached) {
            rmdir(mount.fileSystemRepresentation);
            // ERASES this probe's own temporary log directory.
            [NSFileManager.defaultManager removeItemAtURL:logs error:nil];
        } else {
            if (error)
                *error = detachError;
            guest = nil;
        }
        return guest;
    }
    NSDictionary *info =
        [NSDictionary dictionaryWithContentsOfURL:[URL URLByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *guest = [VIMInstallerInspection guestForBundleIdentifier:info[@"CFBundleIdentifier"]];
    if (!guest) {
        AssemblyError(error, VIMAssemblyFailureUnsupportedInstaller);
        return nil;
    }
    return [self validateInstallerApplication:URL guest:guest error:error] ? guest : nil;
}
+ (BOOL)validateInstallerApplication:(NSURL *)URL guest:(NSString *)guest error:(NSError **)error {
    return [VIMInstallerInspection validateInstaller:URL guest:guest error:error];
}
- (void)report:(NSString *)stage {
    self.stage = stage;
    if (self.progress)
        dispatch_async(dispatch_get_main_queue(), ^{
          if (self.progress)
              self.progress(stage);
        });
}
- (void)completedWork:(double)fraction {
    self.workFraction = MAX(self.workFraction, fraction);
    fraction = self.workFraction;
    if (self.workProgress)
        dispatch_async(dispatch_get_main_queue(), ^{
          if (self.workProgress)
              self.workProgress(fraction);
        });
}
- (void)nextWorkTo:(double)end seconds:(NSTimeInterval)seconds {
    self.workEnd = end;
    self.workEstimate = seconds;
}
// Apple's recovery installer is CS_RESTRICT on Mavericks, so dyld removes
// DYLD_INSERT_LIBRARIES even though the root-only authorization is valid.
// Preserve the original app for manual installation. The separate automatic
// app is the same native code/resources, ad-hoc signed for this generated image.
// Its ONLY omitted entitlement permits securityd credential stashing for an
// existing encrypted installation; our authorization accepts only a new empty
// HFS target. Unknown entitlements fail closed instead of silently stripping.
- (BOOL)removeRestoreModelRestrictionAtMount:(NSURL *)mount error:(NSError **)error {
    // Retail and model-specific restore DVDs have different eligibility
    // scripts. Change only the generated copy's native installation-check
    // hook, not a hardcoded model list or arbitrary JavaScript body.
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *package = [mount URLByAppendingPathComponent:@"System/Installation/Packages/OSInstall.mpkg"];
    BOOL flat = [VIMInstallerInspection fileIsInstallerPackage:package];
    NSURL *expanded = [self.job URLByAppendingPathComponent:@"RestoreDistribution"];
    // WRITES inside the job, then the attached working copy's OSInstall package or distribution.
    if (flat && (![fm createDirectoryAtURL:expanded withIntermediateDirectories:NO attributes:nil error:error] ||
                 ![self perform:[VIMToolInvocation extractArchive:package.path into:expanded.path] error:error]))
        return NO;
    NSURL *distribution = flat ? [expanded URLByAppendingPathComponent:@"Distribution"]
                               : [package URLByAppendingPathComponent:@"Contents/OSInstall.dist"];
    // Some retail discs express no hardware gate as a Distribution at all.
    // Let their native package installer try rather than require restore logic.
    if (!flat && ![fm fileExistsAtPath:distribution.path])
        return YES;
    NSString *patched = [VIMRecoveryText
        openingInstallationPlan:[NSString stringWithContentsOfURL:distribution
                                                         encoding:NSUTF8StringEncoding
                                                            error:error]
               selectingRosetta:
                   [fm fileExistsAtPath:[mount URLByAppendingPathComponent:@"System/Installation/Packages/Rosetta.pkg"]
                                            .path]];
    if (!patched)
        return AssemblyError(error, VIMAssemblyFailureInstallationPlanUnreadable);
    if (!flat)
        return RewriteGeneratedFile(distribution, [patched dataUsingEncoding:NSUTF8StringEncoding], error);
    if (![patched writeToURL:distribution atomically:NO encoding:NSUTF8StringEncoding error:error])
        return NO;
    NSURL *output = [self.job URLByAppendingPathComponent:@"OSInstall-virtual.mpkg"];
    // xar's -C applies ONLY to extraction. During creation it silently logs
    // missing relative files yet exits zero, producing an empty archive.
    // Give the child a real cwd, then extract/read back its actual members.
    NSArray *entries = [fm contentsOfDirectoryAtPath:expanded.path error:error];
    if (!entries.count)
        return NO;
    if (![self perform:[VIMToolInvocation createArchive:output.path members:entries directory:expanded.path]
                 error:error])
        return NO;
    NSURL *verify = [self.job URLByAppendingPathComponent:@"RestoreDistributionReadback"];
    if (![fm createDirectoryAtURL:verify withIntermediateDirectories:NO attributes:nil error:error] ||
        ![self perform:[VIMToolInvocation extractArchive:output.path into:verify.path] error:error] ||
        ![[NSString stringWithContentsOfURL:[verify URLByAppendingPathComponent:@"Distribution"]
                                   encoding:NSUTF8StringEncoding
                                      error:error] isEqual:patched])
        return AssemblyError(error, VIMAssemblyFailureSnowLeopardPackagesUnverified);
    NSData *bytes = [NSData dataWithContentsOfURL:output options:0 error:error];
    if (!bytes.length || bytes.length > 8 * 1024 * 1024)
        return NO;
    return RewriteGeneratedFile(package, bytes, error);
}
// WRITES the attached working copy. Stops at the first refusal.
- (BOOL)applyRecoveryEdit:(VIMRecoveryEdit *)edit
                  atMount:(NSURL *)mount
                  support:(NSURL *)support
                    guest:(NSString *)guest
                    error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *target = edit.path ? [mount URLByAppendingPathComponent:edit.path] : nil;
    switch (edit.kind) {
        case VIMRecoveryEditKindInstallSupport:
            return [fm createDirectoryAtURL:target.URLByDeletingLastPathComponent
                       withIntermediateDirectories:YES
                                        attributes:nil
                                             error:error] &&
                   [self perform:[VIMToolInvocation copy:support.path to:target.path timeout:180] error:error];
        case VIMRecoveryEditKindCreateScript:
            return ![fm fileExistsAtPath:target.path] &&
                   [edit.contents writeToURL:target atomically:NO encoding:NSUTF8StringEncoding error:error] &&
                   [fm setAttributes:@{NSFilePosixPermissions : @0755} ofItemAtPath:target.path error:error];
        case VIMRecoveryEditKindPatchStartup: {
            NSString *patched = [edit patched:[NSString stringWithContentsOfURL:target
                                                                       encoding:NSUTF8StringEncoding
                                                                          error:error]];
            if (!patched)
                return AssemblyError(error, edit.unrecognizedFailure);
            return RewriteGeneratedFile(target, [patched dataUsingEncoding:NSUTF8StringEncoding], error);
        }
        case VIMRecoveryEditKindSymlink:
            return [fm createSymbolicLinkAtURL:target
                            withDestinationURL:[NSURL fileURLWithPath:edit.destination]
                                         error:error];
        case VIMRecoveryEditKindPrepareAutomaticInstaller:
            return [self prepareAutomaticInstallerAtMount:mount guest:guest error:error];
    }
}
- (BOOL)prepareAutomaticInstallerAtMount:(NSURL *)mount guest:(NSString *)guest error:(NSError **)error {
    NSString *executable = [VIMGuestMediaPlan planForGuest:guest].recoveryInstallerPath;
    NSURL *binary = [mount URLByAppendingPathComponent:[executable substringFromIndex:1]];
    NSURL *original =
        binary.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSURL *automatic = [mount URLByAppendingPathComponent:@"System/Installation/CDIS/VirtualIntelMac Installer.app"];
    SecStaticCodeRef code = NULL;
    CFDictionaryRef information = NULL;
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)binary, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess)
        status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information);
    if (code)
        CFRelease(code);
    NSDictionary *details = CFBridgingRelease(information),
                 *entitlements = details[(__bridge NSString *)kSecCodeInfoEntitlementsDict];
    if (status != errSecSuccess || !details || ![VIMRecoveryText acceptsAutomaticInstallerEntitlements:entitlements])
        return AssemblyError(error, VIMAssemblyFailureAutomaticLaunchPolicyUnrecognized);
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:automatic.path])
        return AssemblyError(error, VIMAssemblyFailureAutomaticInstallerAlreadyPresent);
    // WRITES the job, then a new app on the attached working copy. The original app and its signature are untouched.
    NSURL *policy = [self.job URLByAppendingPathComponent:@"AutomaticInstallerEntitlements.plist"];
    NSData *empty = [NSPropertyListSerialization dataWithPropertyList:@{}
                                                               format:NSPropertyListXMLFormat_v1_0
                                                              options:0
                                                                error:error];
    if (!empty || ![empty writeToURL:policy options:NSDataWritingAtomic error:error])
        return NO;
    return [self perform:[VIMToolInvocation copy:original.path to:automatic.path timeout:180] error:error] &&
           [self perform:[VIMToolInvocation signAdHocApplication:automatic.path entitlements:policy.path]
                   error:error] &&
           [self perform:[VIMToolInvocation verifySignatureOfApplication:automatic.path] error:error];
}
// No shell, package scripts, privileged installer invocation, or output pipes.
// Logs stay in the job; a child producing much output cannot deadlock its parent.
- (BOOL)perform:(VIMToolInvocation *)command error:(NSError **)error {
    NSString *path = command.path;
    BOOL cleanup = command.isCleanup;
    if (self.cancelled && !cleanup)
        return AssemblyError(error, VIMAssemblyFailureCancelledWithDownloadsRetained);
    NSURL *log = [self.job
        URLByAppendingPathComponent:[NSString stringWithFormat:@"%02lu-%@.log", ++self.step, path.lastPathComponent]];
    self.lastLog = log;
    int fd = open(log.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0)
        return AssemblyError(error, VIMAssemblyFailureCannotCreateLog);
    NSFileHandle *output = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    if (command.workingDirectory)
        task.currentDirectoryURL = [NSURL fileURLWithPath:command.workingDirectory];
    task.arguments = command.launchArguments;
    BOOL percentOutput = command.reportsPercent;
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"LC_ALL"] = @"C";
    environment[@"LANG"] = @"C";
    task.environment = environment;
    task.standardOutput = output;
    task.standardError = output;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    dispatch_semaphore_t ended = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *finished) {
      dispatch_semaphore_signal(ended);
    };
    if (![task launchAndReturnError:error])
        return NO;
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    double begin = self.workFraction, end = MAX(begin, self.workEnd);
    NSString *timingKey = [VIMToolProgress timingKeyForGuest:self.progressGuest stage:self.stage invocation:command];
    double learned = [NSUserDefaults.standardUserDefaults doubleForKey:timingKey];
    double estimate = learned > 0 ? learned : MAX(1, self.workEstimate);
    NSFileHandle *reader = percentOutput ? [NSFileHandle fileHandleForReadingFromURL:log error:nil] : nil;
    NSMutableData *pending = [NSMutableData data];
    double toolFraction = -1;
    NSTimeInterval lastUpdate = 0;
    BOOL interrupted = NO;
    while (dispatch_semaphore_wait(ended, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC))) {
        NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - start;
        if (end > begin && elapsed - lastUpdate >= .5) {
            lastUpdate = elapsed;
            if (reader) {
                [pending appendData:[reader readDataOfLength:65536]];
                NSString *lines = [[NSString alloc] initWithData:pending encoding:NSUTF8StringEncoding];
                NSRange newline = [lines rangeOfString:@"\n" options:NSBackwardsSearch];
                if (newline.location != NSNotFound) {
                    NSString *complete = [lines substringToIndex:newline.location + 1];
                    toolFraction = [VIMToolProgress reportedFractionInLines:complete after:toolFraction];
                    NSUInteger consumed = [complete lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                    [pending replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
                }
            }
            double fraction = [VIMToolProgress fractionWithReported:toolFraction elapsed:elapsed estimate:estimate];
            [self completedWork:begin + (end - begin) * fraction];
            double operationRemaining = [VIMToolProgress secondsRemainingWithReported:toolFraction
                                                                              elapsed:elapsed
                                                                             estimate:estimate];
            double seconds = operationRemaining + (1 - end) * 240;
            if (self.timeRemaining)
                dispatch_async(dispatch_get_main_queue(), ^{
                  if (self.timeRemaining)
                      self.timeRemaining(seconds);
                });
        }
        if ((self.cancelled && !cleanup) || NSProcessInfo.processInfo.systemUptime - start > command.timeout) {
            interrupted = YES;
            [task terminate];
            if (dispatch_semaphore_wait(ended, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) {
                if (task.running)
                    kill(task.processIdentifier, SIGKILL);
                [task waitUntilExit];
            }
            break;
        }
    }
    [reader closeFile];
    [output closeFile];
    if (interrupted)
        return AssemblyError(error, VIMAssemblyFailureTimedOutOrCancelled);
    if (task.terminationStatus == 0) {
        if (end > begin) {
            double duration = NSProcessInfo.processInfo.systemUptime - start;
            [NSUserDefaults.standardUserDefaults setDouble:[VIMToolProgress learnedDurationAfter:learned
                                                                                        measured:duration]
                                                    forKey:timingKey];
            [self completedWork:end];
        }
        return YES;
    }
    if (error)
        *error = [VIMToolProgress toolFailureWithStatus:task.terminationStatus log:log.path];
    return NO;
}
- (NSURL *)assembleClassicDiskImage:(NSURL *)image
                              guest:(NSString *)guest
                       jobDirectory:(NSURL *)directory
                              error:(NSError **)error {
    VIMGuestMediaPlan *plan = [VIMGuestMediaPlan planForGuest:guest];
    NSString *name = plan.installerApplicationName, *package = plan.diskImagePackageName;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!package || !RegularFile(image) || !directory.isFileURL || [fm fileExistsAtPath:directory.path]) {
        AssemblyError(error, VIMAssemblyFailureIncompleteDownload);
        return nil;
    }
    NSDictionary *space = [fm attributesOfFileSystemForPath:directory.URLByDeletingLastPathComponent.path error:error];
    if (!space)
        return nil;
    if ([space[NSFileSystemFreeSize] unsignedLongLongValue] < VIMScratchRequirement.assembly) {
        AssemblyError(error, VIMAssemblyFailureAssemblyNeedsSpace);
        return nil;
    }
    // WRITES the new job directory, which is the ownership boundary: it must not already exist.
    if (![fm createDirectoryAtURL:directory
            withIntermediateDirectories:NO
                             attributes:@{NSFilePosixPermissions : @0700}
                                  error:error])
        return nil;
    self.job = directory;
    self.step = 0;
    self.progressGuest = guest;
    NSString *source = [VIMInstallerCatalog fileForGuest:guest role:@"diskimage"][@"URL"];
    if (!source) {
        AssemblyError(error, VIMAssemblyFailureNoCatalogRecord);
        return nil;
    }
    [self report:@"Verifying the original Apple download…"];
    // Historical packages have expired Apple certificates. Authenticate the
    // exact approved image bytes instead of weakening global signature policy.
    if (![VIMInstallerSource verifyFile:image source:[NSURL URLWithString:source] error:error])
        return nil;
    NSURL *mount = MountDirectory(error);
    if (!mount)
        return nil;
    BOOL mounted = [self perform:[VIMToolInvocation attachReadOnlyImage:image.path mountPoint:mount.path] error:error];
    BOOL unpacked = NO;
    NSURL *expanded = [directory URLByAppendingPathComponent:@"Expanded"];
    if (mounted) {
        [self report:@"Unpacking the original Mac OS X installer…"];
        [self nextWorkTo:.35 seconds:90];
        // WRITES the job's Expanded directory. The image stays attached read-only.
        unpacked = [self perform:[VIMToolInvocation expandPackage:[mount URLByAppendingPathComponent:package].path
                                                             into:expanded.path]
                           error:error];
    }
    NSError *issue = nil;
    BOOL detached = [self perform:[VIMToolInvocation detachMountPoint:mount.path] error:&issue];
    if (detached)
        rmdir(mount.fileSystemRepresentation);
    if (!unpacked || !detached) {
        if (unpacked && error)
            *error = issue;
        return nil;
    }
    // Both pinned Apple products place their app in Payload and their ESD as
    // a sibling. This is the package script's data-placement step, not execution
    // of that script on a modern host (and does not require administrator access).
    NSURL *component = [expanded URLByAppendingPathComponent:package];
    NSURL *app = [directory URLByAppendingPathComponent:name];
    // WRITES inside the job: moves the app and its ESD out of Expanded.
    if (![fm moveItemAtURL:[component URLByAppendingPathComponent:[@"Payload" stringByAppendingPathComponent:name]]
                     toURL:app
                     error:error])
        return nil;
    NSURL *support = [app URLByAppendingPathComponent:@"Contents/SharedSupport"];
    if (![fm createDirectoryAtURL:support withIntermediateDirectories:YES attributes:nil error:error] ||
        ![fm moveItemAtURL:[component URLByAppendingPathComponent:@"InstallESD.dmg"]
                     toURL:[support URLByAppendingPathComponent:@"InstallESD.dmg"]
                     error:error] ||
        ![self.class validateInstallerApplication:app guest:guest error:error])
        return nil;
    // ERASES the job's own Expanded directory.
    if (![fm removeItemAtURL:expanded error:error])
        return nil;
    if (!WriteReceipt([VIMPreparationRecords pinnedImageReceiptForGuest:guest installer:name],
                      [directory URLByAppendingPathComponent:@"Assembly.plist"], error))
        return nil;
    [self completedWork:.45];
    return app;
}
- (NSURL *)assembleMavericks:(NSURL *)esd
                       guest:(NSString *)guest
                jobDirectory:(NSURL *)directory
                       error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!RegularFile(esd) || !directory.isFileURL || [fm fileExistsAtPath:directory.path]) {
        AssemblyError(error, VIMAssemblyFailureIncompleteMavericksDownload);
        return nil;
    }
    NSDictionary *space = [fm attributesOfFileSystemForPath:directory.URLByDeletingLastPathComponent.path error:error];
    if (!space)
        return nil;
    if ([space[NSFileSystemFreeSize] unsignedLongLongValue] < VIMScratchRequirement.assembly) {
        AssemblyError(error, VIMAssemblyFailureAssemblyNeedsSpace);
        return nil;
    }
    // WRITES the new job directory, which is the ownership boundary: it must not already exist.
    if (![fm createDirectoryAtURL:directory
            withIntermediateDirectories:NO
                             attributes:@{NSFilePosixPermissions : @0700}
                                  error:error])
        return nil;
    self.job = directory;
    self.step = 0;
    self.progressGuest = guest;
    [self report:@"Verifying the Mavericks installer…"];
    NSString *location = [VIMInstallerCatalog fileForGuest:guest role:@"esd"][@"URL"];
    if (!location) {
        AssemblyError(error, VIMAssemblyFailureNoMavericksCatalogRecord);
        return nil;
    }
    NSURL *source = [NSURL URLWithString:location];
    if (![VIMInstallerSource verifyFile:esd source:source error:error])
        return nil;
    NSURL *outer = MountDirectory(error), *base = nil, *app = nil;
    if (!outer)
        return nil;
    BOOL outerMounted = NO, baseMounted = NO, success = NO;
    NSDictionary *completedReceipt = nil;
    @try {
        outerMounted = [self perform:[VIMToolInvocation attachReadOnlyImage:esd.path mountPoint:outer.path]
                               error:error];
        if (!outerMounted)
            return nil;
        if (!RegularFile([outer URLByAppendingPathComponent:@"BaseSystem.dmg"]) ||
            !RegularFile([outer URLByAppendingPathComponent:@"Packages/OSInstall.mpkg"])) {
            AssemblyError(error, VIMAssemblyFailureMavericksDownloadIncomplete);
            return nil;
        }
        base = MountDirectory(error);
        if (!base)
            return nil;
        baseMounted = [self
            perform:[VIMToolInvocation attachReadOnlyImage:[outer URLByAppendingPathComponent:@"BaseSystem.dmg"].path
                                                mountPoint:base.path]
              error:error];
        if (!baseMounted)
            return nil;
        NSDictionary *version =
            [NSDictionary dictionaryWithContentsOfURL:
                              [base URLByAppendingPathComponent:@"System/Library/CoreServices/SystemVersion.plist"]];
        VIMGuestMediaPlan *plan = [VIMGuestMediaPlan planForGuest:guest];
        if (![plan matchesProductVersion:version[@"ProductVersion"]]) {
            AssemblyError(error, VIMAssemblyFailureMavericksVersionMismatch);
            return nil;
        }
        app = [directory URLByAppendingPathComponent:plan.installerApplicationName];
        [self report:@"Preparing the original Mavericks installer…"];
        [self nextWorkTo:.2 seconds:10];
        // WRITES the app and its support files inside the job. Both images stay attached read-only.
        if (![self perform:[VIMToolInvocation copy:[base URLByAppendingPathComponent:app.lastPathComponent].path
                                                to:app.path
                                           timeout:300]
                     error:error])
            return nil;
        NSURL *support = [app URLByAppendingPathComponent:@"Contents/SharedSupport"];
        if (![fm createDirectoryAtURL:support withIntermediateDirectories:YES attributes:nil error:error])
            return nil;
        [self nextWorkTo:.43 seconds:90];
        if (![self perform:[VIMToolInvocation copy:esd.path
                                                to:[support URLByAppendingPathComponent:@"InstallESD.dmg"].path
                                           timeout:1800]
                     error:error])
            return nil;
        for (NSString *file in @[ @"BaseSystem.dmg", @"BaseSystem.chunklist" ])
            if (![fm copyItemAtURL:[outer URLByAppendingPathComponent:file]
                             toURL:[support URLByAppendingPathComponent:file]
                             error:error])
                return nil;
        NSDictionary *metadata = @{@"System Image Info" : @{@"version" : version[@"ProductVersion"]}};
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:metadata
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:error];
        if (!data ||
            ![data writeToURL:[support URLByAppendingPathComponent:@"InstallInfo.plist"]
                      options:NSDataWritingAtomic
                        error:error] ||
            ![self.class validateInstallerApplication:app guest:guest error:error])
            return nil;
        completedReceipt = [VIMPreparationRecords recoveryPayloadReceiptForGuest:guest
                                                                       installer:app.lastPathComponent
                                                                  productVersion:version[@"ProductVersion"]
                                                                    productBuild:version[@"ProductBuildVersion"]];
        success = YES;
    } @finally {
        for (NSURL *mount in base ? @[ base, outer ] : @[ outer ]) {
            // Each successfully attached image is detached exactly once.
            BOOL mounted = mount == base ? baseMounted : outerMounted;
            if (mounted) {
                NSError *issue = nil;
                if (![self perform:[VIMToolInvocation detachMountPoint:mount.path] error:&issue]) {
                    success = NO;
                    if (error && !*error)
                        *error = issue;
                } else
                    rmdir(mount.fileSystemRepresentation);
            } else
                rmdir(mount.fileSystemRepresentation);
            if (mount == outer)
                outerMounted = NO;
        }
    }
    if (success) {
        if (!WriteReceipt(completedReceipt, [directory URLByAppendingPathComponent:@"Assembly.plist"], error))
            return nil;
        [self completedWork:.45];
        return app;
    }
    return nil;
}
- (NSURL *)assembleGuest:(NSString *)guest
                   files:(NSDictionary<NSString *, NSURL *> *)files
            jobDirectory:(NSURL *)directory
                   error:(NSError **)error {
    if (NSThread.isMainThread) {
        AssemblyError(error, VIMAssemblyFailureMainThreadAssembly);
        return nil;
    }
    // A restore DVD is already a complete bootable installation system. It
    // has no InstallAssistant to manufacture or extract. Keep the completed
    // original until its generated replacement has been verified.
    VIMGuestMediaPlan *plan = [VIMGuestMediaPlan planForGuest:guest];
    if (plan.route == VIMAssemblyRouteRestoreDisc) {
        if (!NonemptyFile(files[@"diskimage"])) {
            AssemblyError(error, VIMAssemblyFailureMissingRestoreDiscDownload);
            return nil;
        }
        return files[@"diskimage"];
    }
    if (plan.route == VIMAssemblyRouteRecoveryESD)
        return [self assembleMavericks:files[@"esd"] guest:guest jobDirectory:directory error:error];
    if (plan.route == VIMAssemblyRouteClassicDiskImage)
        return [self assembleClassicDiskImage:files[@"diskimage"] guest:guest jobDirectory:directory error:error];
    BOOL splitInstaller = plan.route == VIMAssemblyRouteSplitPackages;
    NSString *name = plan.installerApplicationName;
    if (!name || !directory.isFileURL || !RegularFile(files[@"assistant"]) ||
        (splitInstaller && (!RegularFile(files[@"recovery"]) || !RegularFile(files[@"esd"])))) {
        AssemblyError(error, VIMAssemblyFailureUnsupportedInputs);
        return nil;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *space = [fm attributesOfFileSystemForPath:directory.URLByDeletingLastPathComponent.path error:error];
    if (!space)
        return nil;
    if ([space[NSFileSystemFreeSize] unsignedLongLongValue] < VIMScratchRequirement.assembly) {
        AssemblyError(error, VIMAssemblyFailureAssemblyNeedsScratchSpace);
        return nil;
    }
    // A fresh directory is the ownership boundary; never reuse or clear user paths.
    // WRITES the new job directory, which is the ownership boundary: it must not already exist.
    if ([fm fileExistsAtPath:directory.path] || ![fm createDirectoryAtURL:directory
                                                    withIntermediateDirectories:NO
                                                                     attributes:@{NSFilePosixPermissions : @0700}
                                                                          error:error]) {
        if (error && !*error)
            AssemblyError(error, VIMAssemblyFailureNeedsNewAssemblyJob);
        return nil;
    }
    self.job = directory;
    self.step = 0;
    self.progressGuest = guest;
    [self report:@"Checking the Apple installer package…"];
    [self nextWorkTo:.05 seconds:5];
    if (![self perform:[VIMToolInvocation checkSignatureOfPackage:files[@"assistant"].path] error:error])
        return nil;
    if (![VIMRecoveryText isSignedAppleSoftware:[NSString stringWithContentsOfURL:self.lastLog
                                                                         encoding:NSUTF8StringEncoding
                                                                            error:error]]) {
        AssemblyError(error, VIMAssemblyFailurePackageNotSignedByApple);
        return nil;
    }
    NSURL *expanded = [directory URLByAppendingPathComponent:@"Expanded"];
    [self completedWork:.05];
    [self report:@"Unpacking the installer…"];
    [self nextWorkTo:.30 seconds:splitInstaller ? 45 : 180];
    // WRITES the job's Expanded directory, only after pkgutil called this signed Apple Software.
    if (![self perform:[VIMToolInvocation expandPackage:files[@"assistant"].path into:expanded.path] error:error])
        return nil;
    // Apple packages may be a single component or a product archive containing components.
    NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:expanded
                                 includingPropertiesForKeys:@[ NSURLIsSymbolicLinkKey ]
                                                    options:0
                                               errorHandler:^BOOL(NSURL *url, NSError *issue) {
                                                 return NO;
                                               }];
    for (NSURL *URL in enumerator) {
        NSNumber *link = nil;
        [URL getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
        if (link.boolValue) {
            [enumerator skipDescendants];
            continue;
        }
        if ([URL.lastPathComponent isEqual:name]) {
            [candidates addObject:URL];
            [enumerator skipDescendants];
        }
    }
    if (candidates.count != 1) {
        AssemblyError(error, VIMAssemblyFailurePackageInstallerAmbiguous);
        return nil;
    }
    NSURL *app = [directory URLByAppendingPathComponent:name];
    if (![fm moveItemAtURL:candidates.firstObject toURL:app error:error])
        return nil;
    NSURL *support = [app URLByAppendingPathComponent:@"Contents/SharedSupport" isDirectory:YES];
    if (![fm createDirectoryAtURL:support withIntermediateDirectories:YES attributes:nil error:error])
        return nil;
    // All package members we need now live in the app. This may itself contain
    // several GB of unused payload; never carry it through media conversion.
    // ERASES the job's own Expanded directory, once the app has moved out.
    if (![fm removeItemAtURL:expanded error:error])
        return nil;
    if (!splitInstaller) {
        // Apple's link_shared_support.zsh links PACKAGE_PATH itself here, not
        // the inner SharedSupport.dmg archive member. The outer file is a
        // signed XAR/UDIF hybrid: recovery can boot the inner image, but the
        // installer cannot authenticate it and reports a damaged installer.
        // Copy the already verified original byte-for-byte, without running
        // package scripts or linking it to a download we subsequently retire.
        NSURL *destination = [support URLByAppendingPathComponent:@"SharedSupport.dmg"];
        // ERASES the moved app's own SharedSupport.dmg, inside the job, to replace it with the verified original.
        if ([fm fileExistsAtPath:destination.path] && ![fm removeItemAtURL:destination error:error])
            return nil;
        [self report:@"Adding Apple’s signed installation package…"];
        [self completedWork:.30];
        [self nextWorkTo:.43 seconds:120];
        if (![self perform:[VIMToolInvocation copy:files[@"assistant"].path to:destination.path timeout:1800]
                     error:error])
            return nil;
    }
    if (splitInstaller) {
        [self completedWork:.30];
        [self report:@"Adding recovery and installation files…"];
        [self nextWorkTo:.32 seconds:10];
        NSURL *mount = MountDirectory(error);
        if (!mount)
            return nil;
        BOOL attached = [self perform:[VIMToolInvocation attachReadOnlyImage:files[@"recovery"].path
                                                                  mountPoint:mount.path]
                                error:error];
        BOOL copied = attached;
        if (attached) {
            for (NSString *file in @[
                     @"BaseSystem.dmg", @"BaseSystem.chunklist", @"AppleDiagnostics.dmg", @"AppleDiagnostics.chunklist"
                 ]) {
                NSURL *source = [mount URLByAppendingPathComponent:file];
                if (self.cancelled || !RegularFile(source)) {
                    copied = AssemblyError(error, VIMAssemblyFailureRecoveryFilesMissing);
                    break;
                }
                // WRITES inside the job's app. The recovery image stays attached read-only.
                if (![fm copyItemAtURL:source toURL:[support URLByAppendingPathComponent:file] error:error]) {
                    copied = NO;
                    break;
                }
            }
        }
        // Also attempt cleanup on a timed-out attach, which can have mounted before exiting.
        NSError *detachError = nil;
        BOOL detached = [self perform:[VIMToolInvocation detachMountPoint:mount.path] error:&detachError];
        if (detached)
            rmdir(mount.fileSystemRepresentation);
        if (!copied)
            return nil;
        if (!detached) {
            if (error)
                *error = detachError;
            return nil;
        }
        if (self.cancelled) {
            AssemblyError(error, VIMAssemblyFailureCancelledWithDownloadsRetained);
            return nil;
        }
        // This multi-GB copy must honor Cancel/Quit, unlike a blocking
        // NSFileManager copy. Use the same bounded child lifecycle as unpacking.
        NSURL *esdDestination = [support URLByAppendingPathComponent:@"InstallESD.dmg"];
        if ([fm fileExistsAtPath:esdDestination.path]) {
            AssemblyError(error, VIMAssemblyFailureUnexpectedInstallESD);
            return nil;
        }
        [self report:@"Copying macOS installation data…"];
        [self completedWork:.36];
        [self nextWorkTo:.43 seconds:75];
        // WRITES inside the job's app, refusing the unexpected existing ESD above.
        if (![self perform:[VIMToolInvocation copy:files[@"esd"].path to:esdDestination.path timeout:1800] error:error])
            return nil;
    }
    NSString *payload = splitInstaller ? @"InstallESD.dmg" : @"SharedSupport.dmg";
    if (![self.class validateInstallerApplication:app guest:guest error:error])
        return nil;
    [self nextWorkTo:.45 seconds:3];
    if (![self perform:[VIMToolInvocation imageInfoForImage:[support URLByAppendingPathComponent:payload].path]
                 error:error])
        return nil;
    if (!WriteReceipt([VIMPreparationRecords assembledReceiptForGuest:guest installer:name],
                      [directory URLByAppendingPathComponent:@"Assembly.plist"], error))
        return nil;
    [self report:@"Installer assembled. Bootable media preparation is next."];
    [self completedWork:.45];
    return app;
}
- (NSURL *)createRecoveryMediaFromInstaller:(NSURL *)installer
                                      guest:(NSString *)guest
                               jobDirectory:(NSURL *)directory
                                      error:(NSError **)error {
    if (NSThread.isMainThread) {
        AssemblyError(error, VIMAssemblyFailureMainThreadMedia);
        return nil;
    }
    VIMGuestMediaPlan *plan = [VIMGuestMediaPlan planForGuest:guest];
    BOOL tiger = plan.restoreDisc == VIMRestoreDiscKindTiger, snow = plan.restoreDisc == VIMRestoreDiscKindSnowLeopard,
         leopard = plan.restoreDisc == VIMRestoreDiscKindLeopard,
         restoreDVD = plan.restoreDisc != VIMRestoreDiscKindNone;
    if (!restoreDVD && ![self.class validateInstallerApplication:installer guest:guest error:error])
        return nil;
    BOOL classic = plan.bootsCDISInstaller, bootstrap = plan.usesBootstrap;
    NSURL *openGLSupport =
        self.openGLSupportDirectory ?: VIMGuestFileURL([@"OpenGLGuests/" stringByAppendingString:guest]);
    if (bootstrap && ![VIMInstallerInspection validateGuestSupport:openGLSupport error:error])
        return nil;
    if (tiger && (!VIMTigerControlPayload(openGLSupport, error) || !VIMTigerInstallerGraphics(openGLSupport, error) ||
                  !VIMTigerInstallerAudio(openGLSupport, error)))
        return nil;
    NSString *name = plan.usesRecoveryMedia ? plan.installerApplicationName : nil;
    NSURL *base =
        restoreDVD ? installer : [installer URLByAppendingPathComponent:@"Contents/SharedSupport/BaseSystem.dmg"];
    NSURL *esd =
        restoreDVD ? installer : [installer URLByAppendingPathComponent:@"Contents/SharedSupport/InstallESD.dmg"];
    if (!name || (!restoreDVD && ![installer.pathExtension.lowercaseString isEqual:@"app"]) || !directory.isFileURL ||
        (!classic && !RegularFile(base)) || !RegularFile(esd)) {
        AssemblyError(error, VIMAssemblyFailureUnsupportedMediaInputs);
        return nil;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *space = [fm attributesOfFileSystemForPath:directory.URLByDeletingLastPathComponent.path error:error];
    if (!space)
        return nil;
    if ([space[NSFileSystemFreeSize] unsignedLongLongValue] < VIMScratchRequirement.recoveryMedia) {
        AssemblyError(error, VIMAssemblyFailureRecoveryMediaNeedsScratchSpace);
        return nil;
    }
    if ([fm fileExistsAtPath:directory.path]) {
        AssemblyError(error, VIMAssemblyFailureNeedsNewMediaJob);
        return nil;
    }
    // WRITES the new job directory, which is the ownership boundary: it must not already exist.
    if (![fm createDirectoryAtURL:directory
            withIntermediateDirectories:NO
                             attributes:@{NSFilePosixPermissions : @0700}
                                  error:error])
        return nil;
    self.job = directory;
    self.step = 0;
    self.progressGuest = guest;
    if (classic && !RegularFile(base)) {
        // Original old installers keep BaseSystem inside InstallESD. Extract
        // into OUR job, never add files to a user-selected installer app.
        NSURL *sourceMount = MountDirectory(error);
        if (!sourceMount)
            return nil;
        BOOL mounted = [self perform:[VIMToolInvocation attachReadOnlyImage:esd.path mountPoint:sourceMount.path]
                               error:error];
        BOOL copied = mounted;
        base = [directory URLByAppendingPathComponent:@"Original-BaseSystem.dmg"];
        if (mounted)
            // WRITES inside the job, never a user-selected installer app.
            copied = [fm copyItemAtURL:[sourceMount URLByAppendingPathComponent:@"BaseSystem.dmg"]
                                 toURL:base
                                 error:error];
        NSError *issue = nil;
        BOOL detached = [self perform:[VIMToolInvocation detachMountPoint:sourceMount.path] error:&issue];
        if (detached)
            rmdir(sourceMount.fileSystemRepresentation);
        if (!copied || !detached) {
            if (copied && error)
                *error = issue;
            return nil;
        }
    }
    NSURL *mount = MountDirectory(error);
    if (!mount)
        return nil;
    // Keep HFS metadata and symlinks inside an image even when the library is
    // on exFAT. A directory copy on that filesystem cannot represent BaseSystem.
    VIMWorkingImageBackend *backend = [VIMWorkingImageBackend
        backendForMacOSMajorVersion:NSProcessInfo.processInfo.operatingSystemVersion.majorVersion];
    BOOL modernImages = backend.isDiskutil;
    NSURL *working = [directory URLByAppendingPathComponent:backend.workingImageName];
    [self report:@"Reading installer recovery system…"];
    [self completedWork:.45];
    [self nextWorkTo:.56 seconds:25];
    BOOL converted = NO;
    if (leopard) {
        // 9J3050 is an APM/ISO hybrid, unlike Snow's naked HFS volume. Copy
        // its actual HFS partition, not Boot Camp/partition-map bytes. Source
        // devices of our own mounted image are readable by this app's UID.
        NSURL *original = MountDirectory(error);
        if (!original)
            return nil;
        BOOL sourceAttached = [self perform:[VIMToolInvocation attachReadOnlyIgnoringOwnersImage:base.path
                                                                                      mountPoint:original.path]
                                      error:error];
        if (sourceAttached && LeopardRestoreProfile(original, guest, error) &&
            [self perform:[VIMToolInvocation deviceInfoForMountPoint:original.path] error:error]) {
            VIMImagePartitionDevice *device =
                [VIMImagePartitionDevice deviceFromInfo:[NSDictionary dictionaryWithContentsOfURL:self.lastLog]
                                           requiringHFS:NO];
            if (device) {
                if (modernImages) {
                    // The block node is exclusively owned by the mounted
                    // filesystem. Use that same image partition's raw node
                    // for read-only copying, never unmount a user's disk.
                    // WRITES the job's working copy (O_EXCL), reading this image's own partition read-only.
                    converted = VIMCopyHFSInstallerVolume(device.rawPath.fileSystemRepresentation,
                                                          working.fileSystemRepresentation, HFSExtractionProgress,
                                                          (__bridge void *)self) == 0;
                    if (!converted)
                        AssemblyError(error, self.cancelled ? VIMAssemblyFailureCancelledWithDownloadSaved
                                                            : VIMAssemblyFailureLeopardVolumeCopyFailed);
                } else
                    // WRITES the job's working copy. The device is only its source.
                    converted = [self perform:[VIMToolInvocation createWorkingImageFromDevice:device at:working.path]
                                        error:error];
            } else
                AssemblyError(error, VIMAssemblyFailureLeopardPartitionUnidentified);
        }
        if (sourceAttached) {
            NSError *issue = nil;
            if (![self perform:[VIMToolInvocation detachMountPoint:original.path] error:&issue]) {
                converted = NO;
                if (error)
                    *error = issue;
            }
        }
        rmdir(original.fileSystemRepresentation);
    } else
        // WRITES the job's working copy. The installer's image is only its source.
        converted = [self perform:[VIMToolInvocation createWorkingImageFrom:base.path at:working.path backend:backend]
                            error:error];
    if (!converted) {
        rmdir(mount.fileSystemRepresentation);
        return nil;
    }
    BOOL volumeOnly = leopard && modernImages;
    if (modernImages && [VIMInstallerInspection fileHasApplePartitionMap:working]) {
        // macOS27's image resize supports GPT or a naked filesystem, not APM.
        // Resizing APM can grow the container, then fail with the HFS volume
        // unchanged. Normalize only that format, not a particular OS/model.
        if (![self extractWorkingHFSVolume:working error:error]) {
            rmdir(mount.fileSystemRepresentation);
            return nil;
        }
        volumeOnly = YES;
    }
    BOOL partitionedInstaller = restoreDVD || volumeOnly;
    [self nextWorkTo:.60 seconds:8];
    // WRITES the job's working copy.
    if (![self perform:[VIMToolInvocation resizeWorkingImage:working.path capacity:plan.workingCapacity backend:backend]
                 error:error]) {
        rmdir(mount.fileSystemRepresentation);
        return nil;
    }
    [self nextWorkTo:.65 seconds:10];
    // WRITES: the only writable attach, and only of this job's working copy.
    BOOL attached = [self perform:[VIMToolInvocation attachWorkingImage:working.path
                                                             mountPoint:mount.path
                                                              rawVolume:volumeOnly]
                            error:error];
    BOOL copied = NO;
    NSDictionary *version = nil, *tigerPolicy = nil, *tigerControls = nil;
    if (attached) {
        version =
            [NSDictionary dictionaryWithContentsOfURL:
                              [mount URLByAppendingPathComponent:@"System/Library/CoreServices/SystemVersion.plist"]];
        if ([plan matchesProductVersion:version[@"ProductVersion"]] &&
            RegularFile([mount URLByAppendingPathComponent:@"System/Library/CoreServices/boot.efi"])) {
            if (classic) {
                // This generation boots the genuine CDIS installer against a
                // local Packages tree. A modern InstallAssistant app copy does
                // not supply that tree and cannot replace this native layout.
                NSURL *packages = [mount URLByAppendingPathComponent:@"System/Installation/Packages"];
                struct stat info;
                // ERASES the working copy's stub Packages. A restore disc keeps its own, and an original is never
                // attached writable.
                BOOL removed = restoreDVD || lstat(packages.fileSystemRepresentation, &info) != 0 ||
                               [fm removeItemAtURL:packages error:error];
                BOOL imageInstaller = plan.carriesInstallerImages;
                NSURL *sourceMount = restoreDVD || imageInstaller ? nil : MountDirectory(error);
                BOOL sourceAttached =
                    sourceMount && [self perform:[VIMToolInvocation attachReadOnlyImage:esd.path
                                                                             mountPoint:sourceMount.path]
                                           error:error];
                if (snow)
                    copied = [fm fileExistsAtPath:[packages URLByAppendingPathComponent:@"OSInstall.mpkg"].path] &&
                             [self removeRestoreModelRestrictionAtMount:mount error:error];
                if (leopard)
                    copied = LeopardRestoreProfile(mount, guest, error) &&
                             [self prepareLeopardRecoveryMemoryAtMount:mount error:error] &&
                             [self removeRestoreModelRestrictionAtMount:mount error:error];
                if (tiger && VIMTigerValidateRestoreDVD(mount, error)) {
                    NSURL *distribution =
                        [packages URLByAppendingPathComponent:@"OSInstall.mpkg/Contents/OSInstall.dist"];
                    NSData *prepared = VIMTigerPrepareDiscOneDistribution([NSData dataWithContentsOfURL:distribution],
                                                                          &tigerPolicy, error);
                    // WRITES the attached working copy, after the disc validated above.
                    copied = prepared && [prepared writeToURL:distribution options:NSDataWritingAtomic error:error];
                    if (copied)
                        copied = VIMTigerStageInstallerControls(mount, openGLSupport, &tigerControls, error);
                }
                if (removed && imageInstaller) {
                    // Native17's InstallInfo reader resolves the original
                    // payload/recovery images together. A flattened Packages
                    // tree loads the distribution but leaves image paths nil.
                    // Preserve the genuine metadata and images, not a donor
                    // app or an edited/synthetic Apple package distribution.
                    [self report:@"Adding macOS installation images…"];
                    [self nextWorkTo:.87 seconds:100];
                    copied =
                        [self perform:[VIMToolInvocation
                                             copy:[installer URLByAppendingPathComponent:@"Contents/SharedSupport"].path
                                               to:mount.path
                                          timeout:1800]
                                error:error];
                } else if (removed && sourceAttached) {
                    [self report:@"Adding OS X installation packages…"];
                    [self nextWorkTo:.87 seconds:100];
                    copied =
                        // WRITES the attached working copy. The installer's image stays attached read-only.
                        [self perform:[VIMToolInvocation copy:[sourceMount URLByAppendingPathComponent:@"Packages"].path
                                                           to:packages.path
                                                      timeout:1800]
                                error:error];
                    NSString *recoveryDirectory = plan.baseSystemDirectory;
                    for (NSString *file in @[ @"BaseSystem.dmg", @"BaseSystem.chunklist" ])
                        if (copied) {
                            // High Sierra's genuine three-package installer keeps
                            // recovery beside InstallESD in SharedSupport, not
                            // inside InstallESD as earlier releases do. Use those
                            // native siblings rather than omit the recovery image.
                            NSURL *recovery = [sourceMount URLByAppendingPathComponent:file];
                            if (!RegularFile(recovery))
                                recovery = [[installer URLByAppendingPathComponent:@"Contents/SharedSupport"]
                                    URLByAppendingPathComponent:file];
                            // WRITES the attached working copy.
                            if (RegularFile(recovery))
                                copied = [fm
                                    copyItemAtURL:recovery
                                            toURL:[mount URLByAppendingPathComponent:
                                                             [recoveryDirectory stringByAppendingPathComponent:file]]
                                            error:error];
                        }
                }
                if (copied && bootstrap)
                    for (VIMRecoveryEdit *edit in plan.recoveryEdits) {
                        copied = [self applyRecoveryEdit:edit
                                                 atMount:mount
                                                 support:openGLSupport
                                                   guest:guest
                                                   error:error];
                        if (!copied)
                            break;
                    }
                if (sourceMount) {
                    NSError *issue = nil;
                    BOOL clean = [self perform:[VIMToolInvocation detachMountPoint:sourceMount.path] error:&issue];
                    if (clean)
                        rmdir(sourceMount.fileSystemRepresentation);
                    if (sourceAttached && !clean) {
                        copied = NO;
                        if (error)
                            *error = issue;
                    }
                }
            } else {
                NSURL *stub = [mount URLByAppendingPathComponent:name];
                // ERASES the working copy's stub app, then WRITES the complete one over it.
                BOOL removed = ![fm fileExistsAtPath:stub.path] || [fm removeItemAtURL:stub error:error];
                [self report:@"Adding the complete OS installer…"];
                [self completedWork:.65];
                [self nextWorkTo:.87 seconds:100];
                if (removed)
                    copied = [self perform:[VIMToolInvocation copy:installer.path to:stub.path timeout:1800]
                                     error:error];
                if (copied && plan.usesSerialAgent)
                    copied = [self prepareSerialRecoveryAtMount:mount error:error];
            }
        } else
            AssemblyError(error, VIMAssemblyFailureRecoveryVersionMismatch);
    }
    NSError *detachError = nil;
    [self nextWorkTo:.90 seconds:12];
    BOOL detached = [self perform:[VIMToolInvocation detachMountPoint:mount.path] error:&detachError];
    if (detached)
        rmdir(mount.fileSystemRepresentation);
    if (!copied)
        return nil;
    if (!detached) {
        if (error)
            *error = detachError;
        return nil;
    }
    NSURL *image = [directory URLByAppendingPathComponent:@"Installer.iso"];
    NSURL *volumeImage = partitionedInstaller ? [directory URLByAppendingPathComponent:@"Installer-volume.raw"] : image;
    [self report:@"Creating the bootable installer image…"];
    [self completedWork:.9];
    [self nextWorkTo:partitionedInstaller ? .96 : .99 seconds:80];
    // Preserve BaseSystem's filesystem catalog, including root ownership,
    // hardlinks, ACLs and blessing. makehybrid on an ownership-disabled mount
    // stamps host UID 501 onto launchd jobs, which require system ownership.
    // The historical .iso name is a raw bootable disk image, not an ISO9660 FS.
    if (modernImages) {
        // diskutil created this working image with --format RAW already.
        // Resizing/mounting edited that same disk. QEMU can use it directly:
        // publish by a same-directory rename, not a second 16 GB conversion.
        // WRITES by a same-directory rename inside the job.
        if (![fm moveItemAtURL:working toURL:volumeImage error:error])
            return nil;
        [self completedWork:partitionedInstaller ? .96 : .99];
    } else {
        NSURL *converted = [directory URLByAppendingPathComponent:@"Installer-blocks.cdr"];
        // WRITES new files inside the job.
        if (![self perform:[VIMToolInvocation convertToBlocks:working.path output:converted.path] error:error] ||
            ![fm moveItemAtURL:converted toURL:volumeImage error:error])
            return nil;
    }
    if (partitionedInstaller) {
        // 10.6 AppleFileSystemDriver matches boot UUIDs only on media with an
        // HFS partition Content Hint. A naked HFS volume boots in EFI but the
        // kernel waits forever for boot-uuid-media. Add real GPT metadata;
        // preserve all volume bytes/UUID and use the existing disk boot path.
        [self report:@"Preparing the installation disk…"];
        // WRITES the final image (O_EXCL), preserving every byte of the volume.
        if (VIMWrapHFSInstallerDisk(volumeImage.fileSystemRepresentation, image.fileSystemRepresentation,
                                    HFSInstallerProgress, (__bridge void *)self)) {
            AssemblyError(error, errno == ECANCELED ? VIMAssemblyFailureCancelledWithDownloadSaved
                                                    : VIMAssemblyFailureInstallationDiskFailed);
            return nil;
        }
    }
    NSNumber *imageSize = FlushGeneratedImage(image, error);
    if (!imageSize)
        return nil;
    if (![VIMInstallerInspection fileIsRecognizableDisk:image]) {
        AssemblyError(error, VIMAssemblyFailureImageNotReadable);
        return nil;
    }
    // A successful conversion/expected length is not proof of usable media.
    // Re-open the final blocks before deleting our working copy. In particular,
    // fail closed if a host image-tool/filesystem combination emitted zeros.
    NSURL *readback = MountDirectory(error);
    if (!readback)
        return nil;
    BOOL readbackMounted = [self perform:[VIMToolInvocation attachReadOnlyImage:image.path mountPoint:readback.path]
                                   error:error];
    BOOL readbackValid = NO;
    if (readbackMounted) {
        NSDictionary *actual = [NSDictionary
            dictionaryWithContentsOfURL:
                [readback URLByAppendingPathComponent:@"System/Library/CoreServices/SystemVersion.plist"]];
        readbackValid = [actual isEqual:version] && [plan requirementsSatisfiedAtMount:readback];
        if (readbackValid && tiger) {
            NSData *distribution = [NSData
                dataWithContentsOfURL:[readback
                                          URLByAppendingPathComponent:
                                              @"System/Installation/Packages/OSInstall.mpkg/Contents/OSInstall.dist"]];
            readbackValid =
                [VIMTigerDistributionSHA256(distribution) isEqual:tigerPolicy[@"PreparedDistributionSHA256"]] &&
                VIMTigerVerifyInstallerControls(readback, openGLSupport, tigerControls, error);
        }
        NSError *issue = nil;
        BOOL clean = [self perform:[VIMToolInvocation detachMountPoint:readback.path] error:&issue];
        if (!clean) {
            if (error)
                *error = issue;
            return nil;
        }
    }
    rmdir(readback.fileSystemRepresentation);
    if (!readbackMounted)
        return nil;
    if (!readbackValid) {
        AssemblyError(error, VIMAssemblyFailureMediaUnverified);
        return nil;
    }
    // ERASES the job's own intermediates, only after the final image was reopened and verified above.
    if (partitionedInstaller && ![fm removeItemAtURL:volumeImage error:error])
        return nil;
    // Only a verified final image can retire the generated working copy.
    if (!modernImages)
        [fm removeItemAtURL:working error:nil];
    if ([base.URLByDeletingLastPathComponent isEqual:directory] &&
        [base.lastPathComponent isEqual:@"Original-BaseSystem.dmg"] && ![fm removeItemAtURL:base error:error])
        return nil;
    NSMutableDictionary *receipt = [[VIMPreparationRecords recoveryReceiptForGuest:guest
                                                                             media:image.lastPathComponent
                                                                              size:imageSize.longLongValue
                                                                    productVersion:version[@"ProductVersion"]
                                                                       partitioned:partitionedInstaller] mutableCopy];
    if (tiger && tigerPolicy)
        [receipt addEntriesFromDictionary:tigerPolicy];
    if (tiger && tigerControls)
        [receipt addEntriesFromDictionary:tigerControls];
    if (!WriteReceipt(receipt, [directory URLByAppendingPathComponent:@"Media.plist"], error))
        return nil;
    [self completedWork:1];
    return image;
}
- (NSURL *)createBigSurMediaFromInstaller:(NSURL *)installer jobDirectory:(NSURL *)directory error:(NSError **)error {
    if (NSThread.isMainThread) {
        AssemblyError(error, VIMAssemblyFailureMainThreadMedia);
        return nil;
    }
    if (![self.class validateInstallerApplication:installer guest:VIMHybridMedia.guest error:error])
        return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *support = [installer URLByAppendingPathComponent:@"Contents/SharedSupport/SharedSupport.dmg"];
    if (!directory.isFileURL || ![installer.pathExtension.lowercaseString isEqual:@"app"] || !RegularFile(support)) {
        AssemblyError(error, VIMAssemblyFailureUnsupportedHybridInputs);
        return nil;
    }
    NSDictionary *space = [fm attributesOfFileSystemForPath:directory.URLByDeletingLastPathComponent.path error:error];
    if (!space)
        return nil;
    if ([space[NSFileSystemFreeSize] unsignedLongLongValue] < VIMScratchRequirement.hybridMedia) {
        AssemblyError(error, VIMAssemblyFailureHybridMediaNeedsScratchSpace);
        return nil;
    }
    if ([fm fileExistsAtPath:directory.path]) {
        AssemblyError(error, VIMAssemblyFailureNeedsNewMediaJob);
        return nil;
    }
    // WRITES the new job directory, which is the ownership boundary: it must not already exist.
    if (![fm createDirectoryAtURL:directory
            withIntermediateDirectories:NO
                             attributes:@{NSFilePosixPermissions : @0700}
                                  error:error])
        return nil;
    self.job = directory;
    self.step = 0;
    self.progressGuest = VIMHybridMedia.guest;
    [self report:@"Checking Apple’s signed installation package…"];
    if (![self perform:[VIMToolInvocation checkSignatureOfPackage:support.path] error:error])
        return nil;
    if (![VIMRecoveryText isSignedAppleSoftware:[NSString stringWithContentsOfURL:self.lastLog
                                                                         encoding:NSUTF8StringEncoding
                                                                            error:error]]) {
        AssemblyError(error, VIMAssemblyFailureBigSurPackageNotSignedByApple);
        return nil;
    }
    NSURL *mount = MountDirectory(error);
    if (!mount)
        return nil;
    NSURL *extracted = [directory URLByAppendingPathComponent:@"BootAssets"];
    NSURL *stage = [directory URLByAppendingPathComponent:@"MediaRoot"];
    for (NSURL *URL in @[ extracted, stage ])
        // WRITES inside the job: BootAssets and MediaRoot, neither of which may exist.
        if (![fm createDirectoryAtURL:URL withIntermediateDirectories:NO attributes:nil error:error])
            return nil;
    [self report:@"Reading Big Sur installer boot files…"];
    [self completedWork:.45];
    [self nextWorkTo:.48 seconds:12];
    BOOL attached = [self perform:[VIMToolInvocation attachReadOnlyImage:support.path mountPoint:mount.path]
                            error:error];
    BOOL extractedOK = NO;
    VIMHybridAsset *asset = nil;
    if (attached) {
        NSURL *assetDirectory = [mount URLByAppendingPathComponent:VIMHybridMedia.assetDirectory];
        NSDictionary *metadata = [NSDictionary
            dictionaryWithContentsOfURL:[assetDirectory URLByAppendingPathComponent:VIMHybridMedia.assetMetadata]];
        asset = [VIMHybridAsset assetFromMetadata:metadata];
        NSMutableArray *archives = [NSMutableArray array];
        for (NSURL *URL in [fm contentsOfDirectoryAtURL:assetDirectory
                             includingPropertiesForKeys:nil
                                                options:0
                                                  error:nil])
            if ([URL.pathExtension isEqual:@"zip"] && RegularFile(URL))
                [archives addObject:URL];
        if (archives.count == 1 && asset) {
            [self nextWorkTo:.60 seconds:50];
            extractedOK = [self perform:[VIMToolInvocation unzip:[archives.firstObject path]
                                                         members:VIMHybridMedia.archiveMembers
                                                            into:extracted.path]
                                  error:error];
        } else
            AssemblyError(error, VIMAssemblyFailureBigSurMetadataAmbiguous);
    }
    NSError *detachError = nil;
    BOOL detached = [self perform:[VIMToolInvocation detachMountPoint:mount.path] error:&detachError];
    if (detached)
        rmdir(mount.fileSystemRepresentation);
    if (!extractedOK)
        return nil;
    if (!detached) {
        if (error)
            *error = detachError;
        return nil;
    }
    NSDictionary<NSString *, NSString *> *mapping = VIMHybridMedia.stagedFiles;
    for (NSString *sourcePath in mapping) {
        if (self.cancelled) {
            AssemblyError(error, VIMAssemblyFailureMediaCancelled);
            return nil;
        }
        NSURL *source = [extracted URLByAppendingPathComponent:sourcePath];
        NSURL *target = [stage URLByAppendingPathComponent:mapping[sourcePath]];
        if (!RegularFile(source)) {
            AssemblyError(error, VIMAssemblyFailureBigSurBootFileMissing);
            return nil;
        }
        if (![fm createDirectoryAtURL:target.URLByDeletingLastPathComponent
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:error] ||
            // WRITES inside the job, moving a file from BootAssets to MediaRoot.
            ![fm moveItemAtURL:source toURL:target error:error])
            return nil;
    }
    NSURL *manifests = [extracted URLByAppendingPathComponent:VIMHybridMedia.extractedManifests];
    // WRITES the job's MediaRoot, as do the plists and app copy below.
    if (![self perform:[VIMToolInvocation copy:manifests.path to:stage.path timeout:120] error:error])
        return nil;
    NSURL *bootPlist = [stage URLByAppendingPathComponent:VIMHybridMedia.bootPlistPath];
    if (![fm createDirectoryAtURL:bootPlist.URLByDeletingLastPathComponent
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:error])
        return nil;
    NSDictionary *cookie = [VIMHybridMedia installerCookieForApplication:installer.lastPathComponent
                                                          productVersion:asset.productVersion
                                                            productBuild:asset.build];
    for (NSArray *entry in @[
             @[ VIMHybridMedia.bootPlist, bootPlist ],
             @[ cookie, [stage URLByAppendingPathComponent:VIMHybridMedia.installerCookiePath] ]
         ]) {
        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:entry[0]
                                                                   format:NSPropertyListXMLFormat_v1_0
                                                                  options:0
                                                                    error:error];
        if (!plist || ![plist writeToURL:entry[1] options:NSDataWritingAtomic error:error])
            return nil;
    }
    [self report:@"Copying macOS installation files into the media…"];
    [self completedWork:.65];
    [self nextWorkTo:.90 seconds:120];
    if (![self perform:[VIMToolInvocation copy:installer.path
                                            to:[stage URLByAppendingPathComponent:installer.lastPathComponent].path
                                       timeout:1800]
                 error:error])
        return nil;
    // ERASES the job's own BootAssets. Their contents were staged above.
    if (![fm removeItemAtURL:extracted error:error])
        return nil;
    [self report:@"Creating the bootable installer image…"];
    [self completedWork:.9];
    NSURL *image = [directory URLByAppendingPathComponent:@"Installer.iso"];
    [self nextWorkTo:.99 seconds:120];
    // WRITES the final image inside the job, from the job's MediaRoot.
    if (![self perform:[VIMToolInvocation
                           makeHybridImageFromStage:stage.path
                                   blessedDirectory:[stage URLByAppendingPathComponent:VIMHybridMedia.blessedDirectory]
                                                        .path
                                         volumeName:VIMHybridMedia.volumeName
                                             output:image.path]
                 error:error])
        return nil;
    NSNumber *imageSize = FlushGeneratedImage(image, error);
    if (!imageSize)
        return nil;
    if (![VIMInstallerInspection fileIsRecognizableDisk:image]) {
        AssemblyError(error, VIMAssemblyFailureImageNotReadable);
        return nil;
    }
    // Staged files are now inside the image and are never reused.
    // ERASES the job's own MediaRoot, once its files are inside the checked image.
    if (![fm removeItemAtURL:stage error:error])
        return nil;
    if (!WriteReceipt([VIMPreparationRecords hybridReceiptForMedia:image.lastPathComponent
                                                              size:imageSize.longLongValue
                                                             asset:asset],
                      [directory URLByAppendingPathComponent:@"Media.plist"], error))
        return nil;
    [self completedWork:1];
    return image;
}
@end
