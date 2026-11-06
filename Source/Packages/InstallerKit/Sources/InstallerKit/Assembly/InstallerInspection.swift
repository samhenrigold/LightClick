// What a given input is. Nothing here writes: these read Apple's bundles, plists and the first blocks of an image.
//
// Selection never trusts a filename or the selected row. A file is what its contents say it is.
import Foundation

extension Guest {
    /// Identifies the OS being installed, unlike CFBundleShortVersionString, which is the InstallAssistant app's version.
    /// Big Sur includes "macOS" in its ID.
    public var installerBundleIdentifier: String? {
        switch self {
        case .tiger, .leopard, .snowLeopard: nil
        case .lion: "com.apple.InstallAssistant.Lion"
        case .mountainLion: "com.apple.InstallAssistant.MountainLion"
        case .mavericks: "com.apple.InstallAssistant.Mavericks"
        case .yosemite: "com.apple.InstallAssistant.Yosemite"
        case .elCapitan: "com.apple.InstallAssistant.ElCapitan"
        case .sierra: "com.apple.InstallAssistant.Sierra"
        case .highSierra: "com.apple.InstallAssistant.HighSierra"
        case .mojave: "com.apple.InstallAssistant.Mojave"
        case .catalina: "com.apple.InstallAssistant.Catalina"
        case .bigSur: "com.apple.InstallAssistant.macOSBigSur"
        }
    }

    public init?(installerBundleIdentifier identifier: Any?) {
        guard let identifier = identifier as? String,
            let guest = Guest.allCases.first(where: { $0.installerBundleIdentifier == identifier })
        else { return nil }
        self = guest
    }

    /// Whether an untrusted version names a release of this guest: all-digit components, and this family or a member of it.
    /// Big Sur also reports itself as 10.16.
    public func matchesProductVersion(_ version: Any?) -> Bool {
        guard let version = version as? String else { return false }
        let components = (version as NSString).components(separatedBy: ".")
        guard
            components.allSatisfy({ component in
                !component.isEmpty && component.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
            })
        else { return false }
        if self == .bigSur, version == "10.16" || version.hasPrefix("10.16.") { return true }
        return version == self.version || version.hasPrefix(self.version + ".")
    }

    /// The restore disc a product version belongs to.
    public static func restoreDisc(productVersion: Any?) -> Guest? {
        [Guest.tiger, .leopard, .snowLeopard].first { $0.matchesProductVersion(productVersion) }
    }
}

/// What the leading bytes of an image say it is.
public enum DiskHeader {
    /// Reads exactly `count` bytes at `offset`, or nil when it can't.
    public typealias Reader = (_ offset: Int64, _ count: Int) -> [UInt8]?

    /// Old BaseSystem images use a driver-descriptor block followed by APM. Its block size can be 2048, not the 512-byte
    /// sectors used by GPT.
    public static func hasApplePartitionMap(_ read: Reader) -> Bool {
        guard let header = read(0, 4), header[0] == UInt8(ascii: "E"), header[1] == UInt8(ascii: "R") else {
            return false
        }
        let block = Int(header[2]) << 8 | Int(header[3])
        guard block >= 512, block <= 65536, block & (block - 1) == 0, let partition = read(Int64(block), 2) else {
            return false
        }
        return partition == [UInt8(ascii: "P"), UInt8(ascii: "M")]
    }

    /// Only recognizes the disk containers we publish. A matching receipt or length cannot detect a damaged primary header
    /// (observed on generated Catalina media). This reads a few boot sectors, not a whole-image hash or a seal on a
    /// replacement user installer; those still follow normal installer detection.
    public static func isRecognizableDisk(_ read: Reader) -> Bool {
        if let blocks = read(0, 1536) {
            if blocks[512..<520].elementsEqual("EFI PART".utf8) { return true }
            if blocks[0..<2].elementsEqual("ER".utf8), hasApplePartitionMap(read) { return true }
            if ["H+", "HX", "BD"].contains(where: { blocks[1024..<1026].elementsEqual($0.utf8) }) { return true }
        }
        guard let descriptor = read(32768, 6) else { return false }
        return ["CD001", "BEA01"].contains { descriptor[1..<6].elementsEqual($0.utf8) }
    }

    public static func isInstallerPackage(_ read: Reader) -> Bool {
        read(0, 4) == Array("xar!".utf8)
    }

    /// Opens without following a symlink, or `flags` otherwise, and answers from its bytes. Nil when it can't be opened.
    static func inspect<Answer>(_ url: URL, flags: Int32 = O_NOFOLLOW, _ body: (Int32, Reader) -> Answer) -> Answer? {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_CLOEXEC | flags) } ?? -1
        }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return body(fd) { offset, count in
            var bytes = [UInt8](repeating: 0, count: count)
            var done: Int
            repeat {
                done = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            } while done < 0 && errno == EINTR
            return done == count ? bytes : nil
        }
    }

    public static func fileHasApplePartitionMap(_ url: URL) -> Bool {
        inspect(url) { _, read in hasApplePartitionMap(read) } ?? false
    }

    public static func fileIsRecognizableDisk(_ url: URL) -> Bool {
        inspect(url) { _, read in isRecognizableDisk(read) } ?? false
    }

    /// Follows a symlink, as a package may be reached through one on a mounted disc.
    public static func fileIsInstallerPackage(_ url: URL) -> Bool {
        inspect(url, flags: O_NONBLOCK) { _, read in isInstallerPackage(read) } ?? false
    }
}

/// Whether a chosen input is complete enough to use. Every check is a refusal: nil means nothing was refused.
public enum InstallerValidation {
    /// Resume gate for an installer or restore disc image. For a disc this only checks it's a substantial regular file:
    /// media creation mounts the original read-only and checks the OS, boot files and packages. A retail DVD may be raw
    /// ISO/CDR rather than a UDIF DMG, so a filename, disc model or container trailer doesn't decide acceptance.
    public static func refusal(forInstaller url: URL, guest: Guest?) -> AssemblyFailure? {
        guard let guest else { return .incompleteInstallerApplication }
        if case .restoreDisc = guest.mediaLayout {
            let valid = DiskHeader.inspect(url) { fd, _ -> Bool in
                var info = stat()
                return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size > 512
            }
            return valid == true ? nil : .incompleteRestoreDiscImage
        }
        let support = url.appending(path: "Contents/SharedSupport")
        let installInfo = support.appending(path: "InstallInfo.plist")
        let hybrid = guest.mediaLayout == .hybridImage
        let flat = guest.mediaLayout == .flatPackages
        let payload = support.appending(path: hybrid ? "SharedSupport.dmg" : "InstallESD.dmg")
        let complete =
            (flat || url.appending(path: "Contents/Resources/createinstallmedia").isNonemptyFile)
            && payload.isNonemptyFile
            && (hybrid || flat || support.appending(path: "BaseSystem.dmg").isNonemptyFile)
        // Big Sur ships only SharedSupport.dmg, with OSVersion inside its asset manifest, which media preparation checks
        // before using boot files. Apple's complete app isn't rejected merely because InstallInfo is absent.
        let system = NSDictionary(contentsOf: installInfo)?["System Image Info"] as? NSDictionary
        let versionMatches =
            ((hybrid || flat) && !FileManager.default.fileExists(atPath: installInfo.path))
            || guest.matchesProductVersion(system?["version"])
        let identifier = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist"))?["CFBundleIdentifier"]
        guard url.isFileURL, url.pathExtension.lowercased() == "app", identifier as? String != nil,
            identifier as? String == guest.installerBundleIdentifier, versionMatches, complete
        else { return .incompleteInstallerApplication }
        return hybrid && !DiskHeader.fileIsInstallerPackage(payload) ? .bigSurPackageMissing : nil
    }

    /// Whether a disc attached read-only at `mount` is a complete restore disc for `guest`: its version, boot.efi and an
    /// installation package, flat or bundled.
    public static func restoreDiscIsComplete(at mount: URL, guest: Guest) -> Bool {
        let package = mount.appending(path: "System/Installation/Packages/OSInstall.mpkg")
        let version = NSDictionary(contentsOf: mount.appending(path: "System/Library/CoreServices/SystemVersion.plist"))
        return guest.matchesProductVersion(version?["ProductVersion"])
            && mount.appending(path: "System/Library/CoreServices/boot.efi").isRegularFile
            && (DiskHeader.fileIsInstallerPackage(package)
                || package.appending(path: "Contents/Info.plist").isRegularFile)
    }

    /// The app's bundled guest support: the bootstrap's required tools, and only regular files of at most 64 MiB inside its
    /// directory, as these are copied onto every OS X guest's media.
    public static func refusal(forGuestSupport directory: URL) -> AssemblyFailure? {
        let required = [
            "opengl-guest-agent", "opengl-install-bootstrap", "opengl-create-account", "guest-ssh",
            "guest-host-connection"
        ]
        guard required.allSatisfy({ directory.appending(path: $0).isNonemptyFile }) else { return .guestSupportMissing }
        let root = directory.resolvingSymlinksInPath().path + "/"
        for name in FileManager.default.subpaths(atPath: directory.path) ?? [] {
            let file = directory.appending(path: name)
            var info = stat()
            if lstat(file, &info), info.st_mode & S_IFMT == S_IFDIR { continue }
            guard file.resolvingSymlinksInPath().path.hasPrefix(root), lstat(file, &info),
                info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 64 * 1024 * 1024
            else { return .guestSupportInvalid }
        }
        return nil
    }

    /// Cheap launch-time check of an image against its size receipt. An ordinary image with no receipt beside it is fine:
    /// it isn't our prepared output.
    public static func refusal(forPreparedMedia url: URL, guest: String?) -> AssemblyFailure? {
        var image = stat()
        guard url.isFileURL, lstat(url, &image), image.st_mode & S_IFMT == S_IFREG, image.st_size > 0 else {
            return .preparedMediaUnavailable
        }
        let receipt = url.deletingLastPathComponent().appending(path: "Media.plist")
        var record = stat()
        guard lstat(receipt, &record) else {
            return errno == ENOENT ? nil : .preparationRecordUnreadable
        }
        let info =
            record.st_mode & S_IFMT == S_IFREG && record.st_size > 0 && record.st_size <= 65536
            ? NSDictionary(contentsOf: receipt) : nil
        guard
            MediaReceipt.matchesImage(
                info as? [String: Any], guest: guest, mediaName: url.lastPathComponent, size: Int64(image.st_size))
        else { return .preparedMediaChanged }
        return DiskHeader.fileIsRecognizableDisk(url) ? nil : .preparedMediaHeaderUnreadable
    }

    private static func lstat(_ url: URL, _ info: inout stat) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &info) == 0 } ?? false
        }
    }
}

/// The one asset a Big Sur installer's manifest must describe. Its metadata is untrusted.
public struct HybridAsset: Equatable, Sendable {
    public let productVersion: String
    public let build: String

    public init?(metadata: Any?) {
        guard let assets = (metadata as? NSDictionary)?["Assets"] as? [Any], assets.count == 1,
            let asset = assets.first as? NSDictionary, Guest.bigSur.matchesProductVersion(asset["OSVersion"]),
            let version = asset["OSVersion"] as? String, let build = asset["Build"] as? String
        else { return nil }
        productVersion = version
        self.build = build
    }
}
