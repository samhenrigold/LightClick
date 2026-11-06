import Foundation
import InstallerKit

/// Why a package couldn't be made, in the domain VIMMachine has always reported.
public struct MachinePackageIssue: Error, Equatable, LocalizedError, CustomNSError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public static var errorDomain: String { "VirtualIntelMac.Machine" }
    public var errorCode: Int { 1 }
    public var errorDescription: String? { message }
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }
}

/// Runs a disk tool to completion, with its output in `log`. Throws if it didn't exit cleanly.
public protocol PackageToolRunning: Sendable {
    func run(_ executable: URL, _ arguments: [String], log: URL) throws
}

public struct ProcessToolRunner: PackageToolRunning {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String], log: URL) throws {
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw MachinePackageIssue("Cannot create import log.")
        }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MachinePackageIssue(
                "The disk tool could not complete the operation. See \(log.path). Source disks were not modified.")
        }
    }
}

/// What `hdiutil attach -plist` said about a new image.
struct AttachedImage: Equatable {
    var device: String?
    /// The HFS+ slice, when there's exactly one.
    var volumeSlice: String?

    /// A newer host appends a deprecation warning to the merged log, so the property list is cut out of it.
    init(log: String) {
        guard let start = log.range(of: "<?xml"), let end = log.range(of: "</plist>"),
            end.lowerBound >= start.lowerBound,
            let object = try? PropertyListSerialization.propertyList(
                from: Data(log[start.lowerBound..<end.upperBound].utf8), format: nil),
            let entities = (object as? [String: Any])?["system-entities"] as? [[String: Any]]
        else { return }
        for entity in entities where entity["content-hint"] as? String == "GUID_partition_scheme" {
            device = entity["dev-entry"] as? String
        }
        let slices = entities.filter { $0["content-hint"] as? String == "Apple_HFS" }
        if slices.count == 1 { volumeSlice = slices[0]["dev-entry"] as? String }
    }

    var validDevice: String? {
        device.flatMap { $0.matchesWholly("^/dev/disk[0-9]+$") ? $0 : nil }
    }

    /// The slice, if it belongs to `device`.
    func validSlice(of device: String) -> String? {
        guard let volumeSlice, volumeSlice.hasPrefix(device + "s"),
            volumeSlice.matchesWholly("^/dev/disk[0-9]+s[0-9]+$")
        else { return nil }
        return volumeSlice
    }
}

/// Makes new machine packages. Everything happens in a hidden staging folder in the library, and a package appears under
/// its real name only when complete. A failure leaves the staging folder and its logs to look at.
public struct MachinePackageBuilder: Sendable {
    /// Fills in a configuration's network settings, or nil if no local ports are left.
    public typealias NetworkDefaults = @Sendable ([String: Any], URL, URL) -> [String: Any]?

    let tools: any PackageToolRunning
    let networkDefaults: NetworkDefaults
    let researchEnabled: Bool
    let freeBytes: @Sendable (URL) throws -> UInt64

    public init(
        tools: any PackageToolRunning = ProcessToolRunner(), researchEnabled: Bool,
        networkDefaults: @escaping NetworkDefaults,
        freeBytes: @escaping @Sendable (URL) throws -> UInt64 = MachinePackageBuilder.volumeFreeBytes
    ) {
        self.tools = tools
        self.researchEnabled = researchEnabled
        self.networkDefaults = networkDefaults
        self.freeBytes = freeBytes
    }

    public static func volumeFreeBytes(_ url: URL) throws -> UInt64 {
        let space = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (space[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
    }

    private static let noPorts = MachinePackageIssue(
        "No local connection ports are available. Close unused virtual Macs or network services, then try again.")
    private static let safetyMargin: UInt64 = 2 << 30

    private func save(_ value: [String: Any], _ url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(
            to: url, options: .atomic)
    }

    /// Whether the file is a GPT disk, going by the header's signature, and not a symbolic link to one.
    static func isEFIDisk(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var signature = [UInt8](repeating: 0, count: 8)
        return pread(descriptor, &signature, 8, 512) == 8 && signature == Array("EFI PART".utf8)
    }

    private func makeFolders(_ names: [String], in stage: URL) throws {
        for name in names {
            try FileManager.default.createDirectory(
                at: stage.appendingPathComponent(name), withIntermediateDirectories: false)
        }
    }

    private func copy(_ source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: destination)
    }

    private func bootFiles(efiDisk: Bool) -> (firmware: String, nvram: String, bootMedia: String, kind: String) {
        (
            "Firmware/CODE.fd", "Firmware/NVRAM.fd", efiDisk ? "Firmware/EFI.img" : "Firmware/OpenCore.iso",
            efiDisk ? "efi-disk" : "legacy-opencore-iso"
        )
    }

    // MARK: Creating

    /// An independent formatted disk that references shared installer media. Returns the new package.
    public func createGuest(
        _ guestName: String, name: String, diskGiB: Int, library: URL, firmware: URL, nvram: URL, bootMedia: URL,
        installer: URL, qemuImage: URL
    ) throws -> URL {
        guard let guest = Guest(rawValue: guestName), PackageNaming.isValid(name), (40...2048).contains(diskGiB),
            library.isFileURL
        else {
            throw MachinePackageIssue("Choose a supported macOS version, a name, and a disk size from 40 to 2048 GB.")
        }
        let files = FileManager.default
        let library = LibraryLayout.machines(forLibrary: library)
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        for input in [firmware, nvram, bootMedia, installer, qemuImage] {
            // Bundled per-OS firmware paths alias the shared image, so this asks about the actual file, as copying and
            // the runtime lookup do. A file URL's own key would report a symbolic link.
            let regular =
                input.isFileURL
                ? try? input.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile
                : false
            guard regular == true else {
                throw MachinePackageIssue("A required firmware, installer, or disk tool file is missing.")
            }
        }
        let imageSize = (try files.attributesOfItem(atPath: installer.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let free = try freeBytes(library)
        // Installer media is shared in place, not copied into every machine, and the disk is sparse: this needs room for
        // an installed system, not the disk's full capacity.
        let diskSize = UInt64(min(diskGiB, 24)) << 30
        guard imageSize != 0, free >= diskSize + Self.safetyMargin else {
            throw MachinePackageIssue("The library needs enough free space for the requested disk.")
        }
        let identifier = UUID().uuidString
        let stage = library.appendingPathComponent(".\(identifier).creating")
        let destination = PackageNaming.newPackageURL(for: name, in: library)
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        try makeFolders(["Disks", "Firmware", "State", "Logs", "Installation"], in: stage)
        let install = stage.appendingPathComponent("State/Install.plist")
        try save(["Phase": "creating", "Identifier": identifier], install)
        // Native unattended installation needs the new disk's identity too, whichever graphics stack a guest uses.
        try createFormattedDisk(in: stage, qemuImage: qemuImage, diskGiB: diskGiB)
        let tigerResearch = guest == .tiger && researchEnabled
        let boot = bootFiles(efiDisk: Self.isEFIDisk(bootMedia))
        if tigerResearch { try copy(firmware, to: stage.appendingPathComponent(boot.firmware)) }
        try copy(nvram, to: stage.appendingPathComponent(boot.nvram))
        if tigerResearch { try copy(bootMedia, to: stage.appendingPathComponent(boot.bootMedia)) }
        let media = installer.resolvingSymlinksInPath().path
        // Ownership identity is distinct from BootMedia. Later cleanup must verify it and the guest's own completion: a
        // desktop frame is not completion.
        try save(
            ["FormatVersion": 1, "MachineIdentifier": identifier, "Media": media, "Size": imageSize],
            stage.appendingPathComponent("Installation/Ownership.plist"))
        let base: [String: Any] = [
            "FormatVersion": 1,
            "Identifier": identifier,
            "Guest": guestName,
            "CPUCount": 4,
            "MemoryMiB": 4096,
            "Disk": "Disks/System.qcow2",
            "DiskGiB": diskGiB,
            "Firmware": boot.firmware,
            "NVRAM": boot.nvram,
            "BootMedia": boot.bootMedia,
            "BootMediaKind": boot.kind,
            "FirmwareSource": "application",
            "InstallerMediaShared": true,
            "InstallerMedia": media,
            "InstallerMediaKind": Self.isEFIDisk(installer) ? "disk" : "optical",
            "InstallState": "installing"
        ]
        guard var configuration = networkDefaults(base, library, destination) else { throw Self.noPorts }
        if tigerResearch { configuration["FirmwareSource"] = "package" }
        if guest == .tiger {
            configuration["LegacyDisplayAdapter"] = "vmware"
            configuration["DisplayMode"] = "scaled"
            configuration["PassthroughOpenGLEnabled"] = false
        }
        if guest.traits.contains(.openGLDesktop) {
            configuration["LegacyDisplayAdapter"] = "vmware"
            configuration["PassthroughOpenGLEnabled"] = true
        }
        try save(configuration, stage.appendingPathComponent("Machine.plist"))
        try save(["Phase": "awaiting-os-install", "Identifier": identifier], install)
        try files.moveItem(at: stage, to: destination)
        return destination
    }

    /// Only ever inside a freshly created, unpublished package, so it can't format an existing guest's disk. Sparse
    /// staging keeps large logical disks cheap on exFAT.
    private func createFormattedDisk(in stage: URL, qemuImage: URL, diskGiB: Int) throws {
        let seed = stage.appendingPathComponent("Disks/Formatting.sparsebundle")
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        func log(_ name: String) -> URL { stage.appendingPathComponent("Logs/" + name) }
        try tools.run(
            hdiutil,
            [
                "create", "-size", "\(diskGiB)g", "-type", "SPARSEBUNDLE", "-layout", "GPTSPUD", "-fs",
                "Journaled HFS+",
                "-volname", "Macintosh HD", seed.path
            ], log: log("FormatDisk.log"))
        let attachLog = log("AttachFormattingDisk.log")
        try tools.run(hdiutil, ["attach", "-nomount", "-readonly", "-plist", seed.path], log: attachLog)
        let attached = AttachedImage(log: (try? String(contentsOf: attachLog, encoding: .utf8)) ?? "")
        let detachLog = log("DetachFormattingDisk.log")
        guard let device = attached.validDevice else {
            // Detached by the exact image path, since the property list wasn't understood.
            try? tools.run(hdiutil, ["detach", seed.path], log: detachLog)
            throw MachinePackageIssue("Cannot identify the newly formatted virtual disk. See AttachFormattingDisk.log.")
        }
        do {
            try recordInstallationTarget(attached, device: device, in: stage, log: log)
        } catch {
            try? tools.run(hdiutil, ["detach", device], log: detachLog)
            throw MachinePackageIssue("The new Macintosh HD could not be identified safely for automatic installation.")
        }
        let raw = device.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        let disk = stage.appendingPathComponent("Disks/System.qcow2")
        var conversionFailure: (any Error)?
        do {
            try tools.run(
                qemuImage, ["convert", "-f", "raw", "-O", "qcow2", raw, disk.path], log: log("CreateDisk.log"))
        } catch {
            conversionFailure = error
        }
        var detachFailure: (any Error)?
        do {
            try tools.run(hdiutil, ["detach", device], log: detachLog)
        } catch {
            detachFailure = error
        }
        if let failure = conversionFailure ?? detachFailure { throw failure }
        // Only the generated seed goes, after conversion and a clean detach.
        try FileManager.default.removeItem(at: seed)
    }

    private func recordInstallationTarget(
        _ attached: AttachedImage, device: String, in stage: URL, log: (String) -> URL
    ) throws {
        guard let slice = attached.validSlice(of: device) else { throw MachinePackageIssue("") }
        let metadata = log("FormattedVolume.plist")
        try tools.run(URL(fileURLWithPath: "/usr/sbin/diskutil"), ["info", "-plist", slice], log: metadata)
        let volume = GuestInstallationTransaction.record(at: metadata)
        guard let identifier = volume?["VolumeUUID"]?.string, UUID(uuidString: identifier) != nil else {
            throw MachinePackageIssue("")
        }
        try save(
            ["FormatVersion": 1, "VolumeUUID": identifier, "Filesystem": "HFS+"],
            stage.appendingPathComponent("State/InstallationTarget.plist"))
    }

    // MARK: Importing

    /// A snapshot copy of a QCOW2 disk. `qemu-img` reads and locks the whole source chain, and this never uses `-U`, rebases
    /// an original or copies a live writable disk. Returns the new package.
    public func importDisk(
        _ disk: URL, guest guestName: String, name: String, library: URL, firmware: URL, nvram: URL, bootMedia: URL,
        qemuImage: URL
    ) throws -> URL {
        guard Guest(rawValue: guestName) != nil, PackageNaming.isValid(name) else {
            throw MachinePackageIssue("Unsupported guest or invalid name.")
        }
        let files = FileManager.default
        let library = LibraryLayout.machines(forLibrary: library)
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        for input in [disk, firmware, nvram, bootMedia, qemuImage] {
            guard input.isFileURL, try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw MachinePackageIssue("A required firmware, installer, or disk tool file is missing.")
            }
        }
        let identifier = UUID().uuidString
        let stage = library.appendingPathComponent(".\(identifier).importing")
        let destination = PackageNaming.newPackageURL(for: name, in: library)
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        let sourceInfo = stage.appendingPathComponent("SourceDisk.json")
        try tools.run(qemuImage, ["info", "--output=json", disk.path], log: sourceInfo)
        let source = try? JSONSerialization.jsonObject(with: Data(contentsOf: sourceInfo)) as? [String: Any]
        guard let source, source["format"] as? String == "qcow2", let size = source["virtual-size"] as? NSNumber else {
            throw MachinePackageIssue("Import requires a valid QCOW2 disk.")
        }
        // A conservative worst case. Sparse output usually uses much less.
        let free = try freeBytes(library)
        guard size.uint64Value != 0, free >= size.uint64Value, free - size.uint64Value >= Self.safetyMargin else {
            throw MachinePackageIssue("The selected library needs more free space for a safe import.")
        }
        try makeFolders(["Disks", "Firmware", "Logs", "State"], in: stage)
        let journal = stage.appendingPathComponent("State/Import.plist")
        try save(["Phase": "importing", "Source": disk.path, "Identifier": identifier], journal)
        let target = stage.appendingPathComponent("Disks/System.qcow2")
        try tools.run(
            qemuImage, ["convert", "-p", "-f", "qcow2", "-O", "qcow2", disk.path, target.path],
            log: stage.appendingPathComponent("Logs/Import.log"))
        let targetInfo = stage.appendingPathComponent("Disk.json")
        try tools.run(qemuImage, ["info", "--output=json", target.path], log: targetInfo)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: targetInfo)) as? [String: Any]
        guard let result, result["backing-filename"] == nil, result["virtual-size"] as? NSNumber == size else {
            throw MachinePackageIssue("The imported disk did not pass the independence check.")
        }
        let efiDisk = Self.isEFIDisk(bootMedia)
        let boot = bootFiles(efiDisk: efiDisk)
        try copy(nvram, to: stage.appendingPathComponent(boot.nvram))
        let base: [String: Any] = [
            "FormatVersion": 1,
            "Identifier": identifier,
            "Guest": guestName,
            "Disk": "Disks/System.qcow2",
            "Firmware": boot.firmware,
            "NVRAM": boot.nvram,
            "BootMedia": boot.bootMedia,
            "BootMediaKind": boot.kind,
            "CPUCount": 4,
            "MemoryMiB": 4096,
            "FirmwareSource": "application",
            "InstallState": "imported-prepared",
            "ImportedFrom": disk.path
        ]
        guard let configuration = networkDefaults(base, library, destination) else { throw Self.noPorts }
        try save(configuration, stage.appendingPathComponent("Machine.plist"))
        try save(["Phase": "complete", "Source": disk.path], journal)
        try files.moveItem(at: stage, to: destination)
        return destination
    }
}

/// The Objective-C face of the builder. VIMMachine loads what it makes.
@objc(VIMMachinePackages)
public final class MachinePackagesBridge: NSObject {
    @objc(createGuest:name:diskGiB:library:firmware:nvram:bootMedia:installer:qemuImage:research:networkDefaults:error:)
    public class func createGuest(
        _ guest: String, name: String, diskGiB: Int, library: URL, firmware: URL, nvram: URL, bootMedia: URL,
        installer: URL, qemuImage: URL, research: Bool,
        networkDefaults: @escaping @Sendable ([String: Any], URL, URL) -> [String: Any]?
    ) throws -> URL {
        try MachinePackageBuilder(researchEnabled: research, networkDefaults: networkDefaults).createGuest(
            guest, name: name, diskGiB: diskGiB, library: library, firmware: firmware, nvram: nvram,
            bootMedia: bootMedia, installer: installer, qemuImage: qemuImage)
    }

    @objc(importDisk:guest:name:library:firmware:nvram:bootMedia:qemuImage:networkDefaults:error:)
    public class func importDisk(
        _ disk: URL, guest: String, name: String, library: URL, firmware: URL, nvram: URL, bootMedia: URL,
        qemuImage: URL, networkDefaults: @escaping @Sendable ([String: Any], URL, URL) -> [String: Any]?
    ) throws -> URL {
        try MachinePackageBuilder(researchEnabled: false, networkDefaults: networkDefaults).importDisk(
            disk, guest: guest, name: name, library: library, firmware: firmware, nvram: nvram, bootMedia: bootMedia,
            qemuImage: qemuImage)
    }
}
