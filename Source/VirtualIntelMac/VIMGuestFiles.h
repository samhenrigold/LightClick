#pragma once
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

// Files copied into guests ship in Runtime/GuestFiles.tar.xz because notarization rejects their period
// Mach-O files, and re-signing them isn't safe for old guests. They are unpacked once per archive into
// Caches. Header-only: standalone test probes compile the callers with clang alone.
NS_INLINE NSURL *VIMGuestFilesUnpack(NSURL *archive) {
    NSData *bytes = [NSData dataWithContentsOfURL:archive options:NSDataReadingMappedIfSafe error:NULL];
    if (!bytes)
        return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, hash);
    NSMutableString *name = [NSMutableString stringWithString:@"GuestFiles-"];
    for (int index = 0; index < 8; index++)
        [name appendFormat:@"%02x", hash[index]];
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *caches = [[files URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
        URLByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier ?: @"gold.samhenri.LightClick"];
    NSURL *destination = [caches URLByAppendingPathComponent:name];
    if ([destination checkResourceIsReachableAndReturnError:nil])
        return destination;
    NSURL *partial = [caches URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![files createDirectoryAtURL:partial withIntermediateDirectories:YES attributes:nil error:NULL])
        return nil;
    NSTask *tar = [NSTask new];
    tar.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tar"];
    tar.arguments = @[ @"-xpf", archive.path, @"-C", partial.path ];
    BOOL unpacked = [tar launchAndReturnError:NULL];
    if (unpacked) {
        [tar waitUntilExit];
        unpacked = tar.terminationReason == NSTaskTerminationReasonExit && tar.terminationStatus == 0;
    }
    // Another copy of the app may have finished first; either result is the same archive.
    if (!unpacked || ![files moveItemAtURL:partial toURL:destination error:NULL])
        [files removeItemAtURL:partial error:NULL];
    return [destination checkResourceIsReachableAndReturnError:nil] ? destination : nil;
}

/// A path under OpenGLGuests/ or GuestTools/. Builds without an archive keep them in Runtime directly.
NS_INLINE NSURL *VIMGuestFileURL(NSString *path) {
    static NSURL *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSURL *runtime = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Runtime"];
      NSURL *archive = [runtime URLByAppendingPathComponent:@"GuestFiles.tar.xz"];
      root = ([archive checkResourceIsReachableAndReturnError:nil] ? VIMGuestFilesUnpack(archive) : nil) ?: runtime;
    });
    return [root URLByAppendingPathComponent:path];
}
