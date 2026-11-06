// Every command installer preparation runs, as data. No shell, package scripts or privileged tools, and no command here
// can erase or partition a disk: nothing names `asr`, `diskutil erase*` or `partition*`, and a device is only ever read.
//
// `writes` names what a command creates or changes. Those commands are the disk-writing paths: each targets a file in the
// caller's fresh job directory or a working image attached from one, never an original installer or a user's volume.
import Foundation

/// One run of a system tool: pinned executable, exact arguments, and how long it may take.
public struct ToolInvocation: Equatable, Sendable {
    /// Only these system binaries can run, by absolute path.
    public enum Tool: String, Sendable {
        case hdiutil = "/usr/bin/hdiutil"
        case diskutil = "/usr/sbin/diskutil"
        case pkgutil = "/usr/sbin/pkgutil"
        case ditto = "/usr/bin/ditto"
        case xar = "/usr/bin/xar"
        case codesign = "/usr/bin/codesign"
        case unzip = "/usr/bin/unzip"
    }

    public let tool: Tool
    public let arguments: [String]
    public let timeout: TimeInterval
    /// xar's `-C` applies only to extraction, so creation needs a real working directory.
    public var workingDirectory: String?
    /// Cleanup still runs after cancellation.
    public var isCleanup = false
    /// The path this command creates or changes. Nil for a command that only reads or detaches.
    public var writes: String?

    /// `hdiutil convert` reports percentages when asked. makehybrid rejects `-puppetstrings`, so its progress is estimated.
    public var reportsPercent: Bool { tool == .hdiutil && arguments.first == "convert" }

    /// What to launch. `arguments` stays the identity used for learned durations.
    public var launchArguments: [String] { reportsPercent ? arguments + ["-puppetstrings"] : arguments }

    // MARK: - Disk images

    /// Attaches an image read-only, so nothing can change an original through this mount. `ignoringOwners` is for reading
    /// its partition's device.
    public static func attachReadOnly(image: String, mountPoint: String, ignoringOwners: Bool = false)
        -> ToolInvocation
    {
        let owners = ignoringOwners ? ["-owners", "off"] : []
        return ToolInvocation(
            tool: .hdiutil,
            arguments: ["attach", "-readonly"] + owners + [
                "-nobrowse", "-noautoopen", "-mountpoint", mountPoint, image
            ],
            timeout: 180)
    }

    /// WRITES `image`: the one writable attach. It must be the job's own working copy, never an original. A source-device
    /// volume copy is plain HFS, not UDIF, so `rawVolume` supplies its known class rather than guess it from a suffix.
    public static func attachWorkingImage(_ image: String, mountPoint: String, rawVolume: Bool) -> ToolInvocation {
        ToolInvocation(
            tool: .hdiutil,
            arguments: ["attach", "-owners", "off", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint]
                + (rawVolume ? ["-imagekey", "diskimage-class=CRawDiskImage"] : []) + [image],
            timeout: 180, writes: image)
    }

    public static func detach(mountPoint: String) -> ToolInvocation {
        ToolInvocation(tool: .hdiutil, arguments: ["detach", mountPoint], timeout: 60, isCleanup: true)
    }

    public static func deviceInfo(mountPoint: String) -> ToolInvocation {
        ToolInvocation(tool: .diskutil, arguments: ["info", "-plist", mountPoint], timeout: 60)
    }

    public static func imageInfo(image: String) -> ToolInvocation {
        ToolInvocation(tool: .hdiutil, arguments: ["imageinfo", "-plist", image], timeout: 60)
    }

    /// WRITES `working`: copies an installer's image into the job.
    public static func createWorkingImage(from base: String, at working: String, backend: WorkingImageBackend)
        -> ToolInvocation
    {
        switch backend {
        case .diskutil:
            ToolInvocation(
                tool: .diskutil, arguments: ["image", "create", "from", "--format", "RAW", base, working], timeout: 600,
                writes: working)
        case .hdiutil:
            ToolInvocation(
                tool: .hdiutil, arguments: ["convert", "-format", "UDSB", "-o", working, base], timeout: 600,
                writes: working)
        }
    }

    /// WRITES `working`. The device, a partition of an image the caller attached read-only, is only the source.
    public static func createWorkingImage(fromDevice device: ImagePartitionDevice, at working: String) -> ToolInvocation
    {
        ToolInvocation(
            tool: .hdiutil, arguments: ["create", "-srcdevice", device.blockPath, "-format", "UDSB", "-o", working],
            timeout: 600, writes: working)
    }

    /// WRITES `working`: grows it and its volume in place.
    public static func resizeWorkingImage(_ working: String, capacity: String, backend: WorkingImageBackend)
        -> ToolInvocation
    {
        switch backend {
        case .diskutil:
            ToolInvocation(
                tool: .diskutil, arguments: ["image", "resize", "--size", capacity, working], timeout: 180,
                writes: working)
        case .hdiutil:
            ToolInvocation(
                tool: .hdiutil, arguments: ["resize", "-size", capacity, working], timeout: 180, writes: working)
        }
    }

    /// WRITES `output`.
    public static func convertToBlocks(_ working: String, output: String) -> ToolInvocation {
        ToolInvocation(
            tool: .hdiutil, arguments: ["convert", working, "-format", "UDTO", "-o", output], timeout: 1800,
            writes: output)
    }

    /// WRITES `output`.
    public static func makeHybridImage(stage: String, blessedDirectory: String, volumeName: String, output: String)
        -> ToolInvocation
    {
        ToolInvocation(
            tool: .hdiutil,
            arguments: [
                "makehybrid", "-hfs", "-udf", "-hfs-volume-name", volumeName, "-hfs-blessed-directory",
                blessedDirectory,
                "-o", output, stage
            ],
            timeout: 1800, writes: output)
    }

    // MARK: - Packages and files

    public static func checkSignature(package: String) -> ToolInvocation {
        ToolInvocation(tool: .pkgutil, arguments: ["--check-signature", package], timeout: 300)
    }

    /// WRITES `destination`.
    public static func expandPackage(_ package: String, into destination: String) -> ToolInvocation {
        ToolInvocation(
            tool: .pkgutil, arguments: ["--expand-full", package, destination], timeout: 1800, writes: destination)
    }

    /// WRITES `destination`.
    public static func copy(_ source: String, to destination: String, timeout: TimeInterval) -> ToolInvocation {
        ToolInvocation(
            tool: .ditto, arguments: ["--norsrc", "--noextattr", "--noacl", source, destination], timeout: timeout,
            writes: destination)
    }

    /// WRITES `destination`.
    public static func extractArchive(_ archive: String, into destination: String) -> ToolInvocation {
        ToolInvocation(tool: .xar, arguments: ["-xf", archive, "-C", destination], timeout: 180, writes: destination)
    }

    /// WRITES `output`. Members are named relative to `directory`, in sorted order.
    public static func createArchive(_ output: String, members: [String], directory: String) -> ToolInvocation {
        let sorted = members.sorted { ($0 as NSString).compare($1) == .orderedAscending }
        return ToolInvocation(
            tool: .xar, arguments: ["-cf", output] + sorted, timeout: 180, workingDirectory: directory, writes: output)
    }

    /// WRITES `application`: signs the generated automatic copy in place. The original stays untouched.
    public static func signAdHoc(application: String, entitlements: String) -> ToolInvocation {
        ToolInvocation(
            tool: .codesign,
            arguments: [
                "--force", "--sign", "-", "--digest-algorithm=sha1,sha256", "--entitlements", entitlements, application
            ],
            timeout: 60, writes: application)
    }

    public static func verifySignature(application: String) -> ToolInvocation {
        ToolInvocation(tool: .codesign, arguments: ["--verify", "--strict", application], timeout: 60)
    }

    /// WRITES `destination`.
    public static func unzip(_ archive: String, members: [String], into destination: String) -> ToolInvocation {
        ToolInvocation(
            tool: .unzip, arguments: ["-q", archive] + members + ["-d", destination], timeout: 600, writes: destination)
    }
}

/// Which tool edits the working image, chosen by the host's macOS.
public enum WorkingImageBackend: Sendable {
    /// Banded UDSB, because UDRW conversion fails with ftruncate(EINVAL) on exFAT.
    case hdiutil
    /// A RAW image, which QEMU can use directly.
    case diskutil

    public init(macOSMajorVersion: Int) {
        self = macOSMajorVersion >= 27 ? .diskutil : .hdiutil
    }

    public var workingImageName: String {
        switch self {
        case .hdiutil: "Recovery-working.sparsebundle"
        case .diskutil: "Recovery-working.img"
        }
    }
}

/// A partition of an image we attached. Only this exact device shape can reach a copy, and a copy only reads it.
public struct ImagePartitionDevice: Equatable, Sendable {
    public let blockPath: String

    /// The block node belongs to the mounted filesystem, so a read-only copy uses the same partition's raw node.
    public var rawPath: String { "/dev/r" + blockPath.dropFirst("/dev/".count) }

    /// `diskutil info -plist` output is untrusted. A whole disk, a raw node or anything else is refused.
    public init?(deviceNode: Any?) {
        guard let node = deviceNode as? String, node.wholeMatch(of: /\/dev\/disk[0-9]+s[0-9]+/) != nil else {
            return nil
        }
        blockPath = node
    }
}
