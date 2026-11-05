import Foundation

/// A path relative to a `.vintelmac` package, as Machine.plist stores `Disk`, `Firmware`, `NVRAM` and `BootMedia`.
public struct PackagePath: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty, !(rawValue as NSString).isAbsolutePath else { return nil }
        self.rawValue = rawValue
    }

    /// The file this names, with symlinks resolved, or nil if that lands outside `package`. `package` must already be
    /// resolved. A `..` or a symlink that climbs out of the package is what this exists to refuse.
    public func resolved(in package: URL) -> URL? {
        let file = package.appendingPathComponent(rawValue).resolvingSymlinksInPath()
        guard (file.path as NSString).hasPrefix(package.path + "/") else { return nil }
        return file
    }
}

/// An absolute path outside the package: a shared installer or an inserted image. `~` counts as absolute, as it does
/// for `-[NSString isAbsolutePath]`.
public struct AbsolutePath: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard (rawValue as NSString).isAbsolutePath else { return nil }
        self.rawValue = rawValue
    }
}

/// Where a machine's installer lives. Owned media is inside the package and may be deleted once installation is
/// verified; shared media belongs to the library's cache and is only ever detached.
public enum InstallerMediaLocation: Hashable, Sendable {
    case owned
    case shared(AbsolutePath)

    public static let ownedPath = "Installation/Installer.iso"
}

/// A library's fixed children.
public enum LibraryLayout {
    /// Machines is a reserved child: old preferences and resumable jobs stored it instead of the chosen root.
    public static func root(forLibrary library: URL) -> URL {
        let url = library.standardizedFileURL
        return url.lastPathComponent == "Machines" ? url.deletingLastPathComponent() : url
    }

    public static func machines(forLibrary library: URL) -> URL {
        root(forLibrary: library).appendingPathComponent("Machines", isDirectory: true)
    }

    public static func downloads(forLibrary library: URL) -> URL {
        root(forLibrary: library).appendingPathComponent("Downloads", isDirectory: true)
    }

    public static func installers(forLibrary library: URL) -> URL {
        root(forLibrary: library).appendingPathComponent("Installers", isDirectory: true)
    }

    /// The attempt folder that may be deleted with this media, or nil if the media isn't app-prepared. Prepared media
    /// is `<Installers or Downloads/Preparation>/<UUID>/Media/<file>`, and an `Installers` attempt must belong to the
    /// owner's own library. `media` must already have its symlinks resolved.
    public static func preparedMediaAttempt(media: URL, owner: URL) -> URL? {
        let attempt = media.deletingLastPathComponent().deletingLastPathComponent()
        let container = attempt.deletingLastPathComponent()
        let machines = owner.deletingLastPathComponent()
        let legacy =
            container.lastPathComponent == "Preparation"
            && container.deletingLastPathComponent().lastPathComponent == "Downloads"
        let organized =
            container.lastPathComponent == "Installers" && machines.lastPathComponent == "Machines"
            && container.deletingLastPathComponent().path == machines.deletingLastPathComponent().path
        guard media.deletingLastPathComponent().lastPathComponent == "Media", legacy || organized,
            UUID(uuidString: attempt.lastPathComponent) != nil
        else { return nil }
        return attempt
    }
}

/// How a machine's name maps to its package, which is what holds the name once migrated.
public enum PackageNaming {
    public static let pathExtension = "vintelmac"

    private static let separators = CharacterSet(charactersIn: "/:\n\r")

    /// 1 to 128 UTF-16 units with something other than whitespace.
    public static func isValid(_ name: String) -> Bool {
        (1...128).contains(name.utf16.count) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A rename must also stay one visible path component.
    public static func isValidRename(_ name: String) -> Bool {
        isValid(name) && !(name as NSString).hasPrefix(".") && name.rangeOfCharacter(from: separators) == nil
    }

    /// The package name for a display name that may contain anything.
    public static func baseName(for name: String) -> String {
        let base = name.components(separatedBy: separators).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty || (base as NSString).hasPrefix(".") ? "Mac " + base : base
    }

    /// The first unused package URL: "Name", "Name 2", "Name 3".
    public static func newPackageURL(
        for name: String, in library: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        let base = baseName(for: name)
        var index = 1
        while true {
            let candidate = index == 1 ? base : "\(base) \(index)"
            let url = library.appendingPathComponent(candidate + "." + pathExtension)
            if !exists(url.path) { return url }
            index += 1
        }
    }
}
