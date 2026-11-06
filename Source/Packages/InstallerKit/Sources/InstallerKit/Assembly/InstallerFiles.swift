import Foundation

/// File operations on what installer assembly generates or owns. Every write stays inside a job's own output, and every
/// deletion is of an owned download that's been checked.
public enum InstallerFiles {
    private static func isUnlinkedDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func record(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Commits newly generated output before its working files go, and returns a fresh size for the completion receipt:
    /// a tool's clean exit and a mounted readback can both see cached data. Opened read-write only to flush, it writes no
    /// bytes, and it refuses a symbolic link, a hard link or a file replaced meanwhile. Never for an original.
    public static func flushGeneratedImage(_ url: URL) throws -> UInt64 {
        let failure = AssemblyFailure.imageNotSavedReliably.error
        let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure }
        var before = stat()
        var after = stat()
        var path = stat()
        var valid =
            fstat(descriptor, &before) == 0 && before.st_mode & S_IFMT == S_IFREG && before.st_nlink == 1
            && before.st_size > 0
        var result: Int32 = -1
        if valid {
            repeat { result = fsync(descriptor) } while result < 0 && errno == EINTR
        }
        if valid && result == 0 {
            repeat { result = fcntl(descriptor, F_FULLFSYNC) } while result < 0 && errno == EINTR
            // Some external filesystems don't implement the stronger drive-cache operation. Their fsync still had to pass.
            if result < 0 && (errno == EINVAL || errno == ENOTSUP) { result = 0 }
        }
        valid =
            valid && result == 0 && fstat(descriptor, &after) == 0 && after.st_size == before.st_size
            && lstat(url.path, &path) == 0 && path.st_mode & S_IFMT == S_IFREG && path.st_dev == after.st_dev
            && path.st_ino == after.st_ino && path.st_size == after.st_size
        if close(descriptor) != 0 { valid = false }
        guard valid else { throw failure }
        return UInt64(after.st_size)
    }

    /// Writes a file on the generated working copy, never a source installer. It keeps its inode and catalog owner, and
    /// gains write permission only while saving.
    public static func rewriteGeneratedFile(_ file: URL, bytes: Data?) throws {
        let files = FileManager.default
        guard let mode = try files.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        var failure: (any Error)?
        do {
            try files.setAttributes([.posixPermissions: mode.uint16Value | 0o200], ofItemAtPath: file.path)
            guard let bytes else { throw CocoaError(.fileWriteUnknown) }
            try bytes.write(to: file)
        } catch {
            failure = error
        }
        try files.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        if let failure { throw failure }
    }

    /// Removes completed downloads the app owns: only an owned payload path, holding its lock, a plain single-link file of
    /// the recorded length, from an approved source. Anything else is left, and so are active downloads and whatever the
    /// user selected.
    public static func retireCompletedDownloads(_ files: [URL]) {
        for file in files {
            let directory = file.deletingLastPathComponent()
            guard DownloadRetirement.isOwnedPayload(file), isUnlinkedDirectory(directory) else { continue }
            let lock = open(directory.appendingPathComponent("Download.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard lock >= 0 else { continue }
            defer { close(lock) }
            var info = stat()
            guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                flock(lock, LOCK_EX | LOCK_NB) == 0
            else { continue }
            let completion = directory.appendingPathComponent("Download.plist")
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                DownloadRetirement.recordAllowsRemoval(record(completion), payloadSize: info.st_size)
            else { continue }
            // Payload first, then the completion record. An interruption leaves a stale record, which a new transfer
            // can safely restart.
            if (try? FileManager.default.removeItem(at: file)) != nil {
                try? FileManager.default.removeItem(at: completion)
            }
        }
    }

    /// Outputs a receipt vouches for, newest attempt first. Never partially prepared media. Keys are `Media` and
    /// `SourceInstaller`.
    public static func retainedInstaller(in root: URL, guest: String) -> [String: URL] {
        let attempts =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        var found: [String: URL] = [:]
        for attempt in attempts.sorted(by: { modified($0) > modified($1) }) {
            guard UUID(uuidString: attempt.lastPathComponent) != nil, isUnlinkedDirectory(attempt) else { continue }
            let mediaDirectory = attempt.appendingPathComponent("Media")
            let media = record(mediaDirectory.appendingPathComponent("Media.plist"))
            if found["Media"] == nil, let name = MediaReceipt.retainedImageName(media, guest: guest) {
                let url = mediaDirectory.appendingPathComponent(name)
                var info = stat()
                if isUnlinkedDirectory(mediaDirectory), lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                    info.st_size > 0, Int64(info.st_size) == (media?["Size"] as? NSNumber)?.int64Value
                {
                    found["Media"] = url
                }
            }
            let assembly = attempt.appendingPathComponent("Assembly")
            let receipt = record(assembly.appendingPathComponent("Assembly.plist"))
            if found["SourceInstaller"] == nil, let name = AssemblyReceipt.installerName(receipt, guest: guest) {
                let url = assembly.appendingPathComponent(name)
                if isUnlinkedDirectory(assembly), isUnlinkedDirectory(url),
                    (try? InstallerInspectionBridge.validateInstaller(url, guest: guest)) != nil
                {
                    found["SourceInstaller"] = url
                }
            }
            if found.count == 2 { break }
        }
        return found
    }
}

@objc(VIMInstallerFiles)
public final class InstallerFilesBridge: NSObject {
    /// As a number, since zero is never a valid size.
    @objc(flushGeneratedImage:error:)
    public class func flushGeneratedImage(_ url: URL) throws -> NSNumber {
        NSNumber(value: try InstallerFiles.flushGeneratedImage(url))
    }

    @objc(rewriteGeneratedFile:bytes:error:)
    public class func rewriteGeneratedFile(_ file: URL, bytes: Data?) throws {
        try InstallerFiles.rewriteGeneratedFile(file, bytes: bytes)
    }

    @objc(retireCompletedDownloads:)
    public class func retireCompletedDownloads(_ files: [URL]) {
        InstallerFiles.retireCompletedDownloads(files)
    }

    @objc(retainedInstallerIn:guest:)
    public class func retainedInstaller(in root: URL, guest: String) -> [String: URL] {
        InstallerFiles.retainedInstaller(in: root, guest: guest)
    }
}
