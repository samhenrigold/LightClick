import Foundation

/// The Installers folder's attempt directories. Each preparation run gets a new one, and failed, paused or superseded
/// ones are never resumed.
public enum PreparationScratch {
    private static func resolved(_ path: String) -> String { (path as NSString).resolvingSymlinksInPath }

    /// Removes attempts nothing can use. Kept are completed products, which another app process may be about to publish,
    /// and anything the job or a machine's `InstallerMedia` points into. Anything uncertain keeps everything.
    public static func removeAbandoned(root: URL, library: URL, jobMedia: String?, jobInstaller: String?) {
        let manager = FileManager.default
        var referenced = Set([jobMedia, jobInstaller].compactMap { $0 }.filter { !$0.isEmpty }.map(resolved))
        guard
            let packages = try? manager.contentsOfDirectory(
                at: LibraryLayout.machines(forLibrary: library), includingPropertiesForKeys: nil)
        else { return }  // An offline library: never infer unused media.
        for package in packages where package.pathExtension == PackageNaming.pathExtension {
            guard let configuration = NSDictionary(contentsOf: package.appendingPathComponent("Machine.plist")) else {
                return  // Unreadable configuration: keep everything.
            }
            if let media = configuration["InstallerMedia"] as? String, (media as NSString).isAbsolutePath {
                referenced.insert(resolved(media))
            }
        }
        let attempts = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for attempt in attempts where UUID(uuidString: attempt.lastPathComponent) != nil {
            let completed = ["Media/Media.plist", "Assembly/Assembly.plist"].contains {
                manager.fileExists(atPath: attempt.appendingPathComponent($0).path)
            }
            let prefix = resolved(attempt.path) + "/"
            if !completed, !referenced.contains(where: { $0.hasPrefix(prefix) }) {
                try? manager.removeItem(at: attempt)
            }
        }
    }

    /// Deletes the assembled app at `preparedInstaller` now that media exists, if it's a real directory at
    /// `<root>/<UUID>/Assembly/<app>` and not, say, a restore DVD or something a user chose. True if it went.
    public static func retireAssembly(preparedInstaller: String, root: URL) -> Bool {
        let app = URL(fileURLWithPath: preparedInstaller)
        let assembly = app.deletingLastPathComponent()
        let attempt = assembly.deletingLastPathComponent()
        guard assembly.lastPathComponent == "Assembly", UUID(uuidString: attempt.lastPathComponent) != nil,
            resolved(attempt.deletingLastPathComponent().path) == resolved(root.path),
            [attempt, assembly, app].allSatisfy(isRealDirectory)
        else { return false }
        return (try? FileManager.default.removeItem(at: assembly)) != nil
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}

/// Only one preparation per library, across app processes. The lock file itself stays.
public struct PreparationLock {
    private var locks = FileLocks()

    public init?(root: URL) {
        guard locks.acquire(root.appendingPathComponent(".Preparation.lock")) else { return nil }
    }

    public mutating func release() {
        locks.release()
    }
}
