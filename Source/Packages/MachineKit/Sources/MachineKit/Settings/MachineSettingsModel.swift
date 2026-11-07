import Foundation
import InstallerKit

/// The configuration window's toolbar. Raw values are the toolbar identifiers and what callers ask for.
public enum SettingsSection: String, CaseIterable, Sendable {
    case general = "General"
    case hardware = "Hardware"
    case sharing = "Sharing"

    /// "Options" is the old name for Sharing, which the session window still asks for.
    public init?(identifier: String) {
        self.init(rawValue: identifier == "Options" ? "Sharing" : identifier)
    }

    public var categories: [SettingsCategory] {
        switch self {
        case .general: []
        case .hardware: [.cpuAndMemory, .graphics, .mouseAndKeyboard, .network, .sound, .hardDisk, .opticalDrive]
        case .sharing: [.fileSharing, .remoteLogin, .clipboard]
        }
    }

    /// The content height before a page adjusts it.
    public var contentHeight: Double {
        switch self {
        case .general: 380
        case .hardware: 390
        case .sharing: 490
        }
    }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .hardware: "cpu"
        case .sharing: "folder"
        }
    }
}

/// A row in the configuration window's sidebar. Raw values are its titles, which callers also pass to open one.
public enum SettingsCategory: String, Sendable {
    case cpuAndMemory = "CPU & Memory"
    case graphics = "Graphics"
    case mouseAndKeyboard = "Mouse & Keyboard"
    case network = "Network"
    case sound = "Sound"
    case hardDisk = "Hard Disk"
    case opticalDrive = "CD/DVD"
    case fileSharing = "File Sharing"
    case remoteLogin = "Remote Login"
    case clipboard = "Clipboard"

    /// An older name for the first Sharing row.
    public init?(identifier: String) {
        self.init(rawValue: identifier == "Sharing" ? "File Sharing" : identifier)
    }

    public var symbol: String {
        switch self {
        case .cpuAndMemory: "cpu"
        case .graphics: "display"
        case .sound: "speaker.wave.2"
        case .network: "network"
        case .hardDisk: "internaldrive"
        case .mouseAndKeyboard: "keyboard"
        case .fileSharing: "folder"
        case .remoteLogin: "terminal"
        case .opticalDrive: "opticaldisc"
        case .clipboard: "doc.on.clipboard"
        }
    }

    public var hasRestoreDefaults: Bool { [.cpuAndMemory, .graphics, .network, .sound].contains(self) }
}

/// What the Restore Defaults button writes. Network also restarts its connection, which is the caller's to do.
public enum SettingsDefaults {
    public static func restored(
        _ category: SettingsCategory, supportsRetina: Bool, processorCount: Int
    ) -> [String: Any]? {
        switch category {
        case .cpuAndMemory:
            [
                "CPUCount": min(4, processorCount), "MemoryMiB": 4096, "ExecutionEngine": "off",
                "MeltdownProtection": "off"
            ]
        case .graphics:
            [
                "DisplayMode": supportsRetina ? "retina" : "scaled", "RetinaEnabled": supportsRetina,
                "DisplayScalingFilter": supportsRetina ? "linear" : "nearest"
            ]
        case .network: ["MACAddress": "", "BridgeInterface": ""]
        case .sound: ["AudioEnabled": true, "AudioInputDevice": "default", "AudioOutputDevice": "default"]
        default: nil
        }
    }
}

/// The numbers on the CPU & Memory page, for this host.
public struct SettingsHardwareLimits: Equatable, Sendable {
    public let processorCount: Int
    public let maximumMemoryMiB: Int
    public let physicalMemoryGiB: Int

    public init(physicalMemoryBytes: UInt64, processorCount: Int) {
        self.processorCount = processorCount
        maximumMemoryMiB =
            HostCapacity(physicalMemoryBytes: physicalMemoryBytes, processorCount: processorCount).maximumMemoryGiB
            * 1024
        physicalMemoryGiB = Int(physicalMemoryBytes >> 30)
    }

    public var memorySliderMaximumGiB: Int { maximumMemoryMiB / 1024 }
    public var memorySliderMiddleGiB: Int { Int((Double(memorySliderMaximumGiB + 1) / 2).rounded()) }

    /// "4 (Recommended)" for the core count a new machine would get, otherwise the number.
    public var processorTitles: [String] {
        guard processorCount > 0 else { return [] }
        return (1...processorCount).map { "\($0)\($0 == min(4, processorCount) ? " (Recommended)" : "")" }
    }

    /// What the processor popup offers and which entry it shows. A saved count past this host, from a machine moved here,
    /// gets its own entry: it's what the machine would start with, and picking a lower one is the edit that changes it.
    public func processorChoices(saved: Int) -> (counts: [Int], titles: [String], selectedIndex: Int) {
        var counts = processorCount > 0 ? Array(1...processorCount) : []
        var titles = processorTitles
        if saved > processorCount {
            counts.append(saved)
            titles.append("\(saved) (more than this Mac has)")
        }
        return (counts, titles, saved > processorCount ? counts.count - 1 : max(0, saved - 1))
    }

    public var summary: String {
        "This Mac has \(processorCount) logical processors and \(physicalMemoryGiB) GB of memory. Leave resources "
            + "available for other apps."
    }

    /// The megabytes typed into the memory field, or what to say about them. A saved value past the limit stays valid
    /// until it's edited: leaving the field without changing it isn't an edit.
    public func memoryMiB(from text: String, saved: Int? = nil) -> Result<Int, SettingsFieldIssue> {
        if let saved, NewMachineForm.wholeNumber(text, in: saved...saved) != nil { return .success(saved) }
        guard let value = NewMachineForm.wholeNumber(text, in: 1024...max(1024, maximumMemoryMiB)) else {
            return .failure(
                SettingsFieldIssue(
                    message: "Use up to \(processorCount) processors or \(maximumMemoryMiB) MB of memory."))
        }
        return .success(value)
    }

    /// A slider position, in megabytes, which can't exceed the limit.
    public func memoryMiB(fromSliderGiB value: Double) -> Int {
        min(maximumMemoryMiB, 1024 * Int(value.rounded()))
    }
}

/// Who the CPU & Memory page offers the Hypervisor engine to.
public enum EngineAvailability {
    /// hvdbt_want_engine stops QEMU past this many vCPUs, so a launch uses software instead.
    public static let maximumProcessors = 8

    /// The engine takes over at a 64-bit kernel's entry. Tiger's and Leopard's kernels are 32-bit, so it would never run.
    public static func isOffered(for guest: Guest?) -> Bool {
        guard let guest else { return false }
        return guest != .tiger && guest != .leopard
    }

    /// Whether the packaged runtime's QEMU for Apple silicon was configured with the engine, from Packaging.plist.
    public static func runtimeHasEngine(packaging: Data?) -> Bool {
        guard let packaging,
            let receipt = try? PropertyListSerialization.propertyList(from: packaging, format: nil) as? [String: Any],
            let build = receipt["RuntimeBuild"] as? [String: Any],
            let configure = build["ConfigureArguments"] as? [String: [String]]
        else { return false }
        return configure["arm64"]?.contains { $0.hasPrefix("-Dhvdbt_engine=") } == true
    }

    /// Why the engine can't be chosen, or nil if it can.
    public static func unavailableReason(runtimeHasEngine: Bool, processors: Int) -> String? {
        if !runtimeHasEngine { return "This copy of Light Click was built without the Hypervisor engine." }
        if processors > maximumProcessors {
            return "Hypervisor runs up to \(maximumProcessors) processors, so this Mac uses Software."
        }
        return nil
    }
}

public struct SettingsFieldIssue: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum SettingsValidation {
    /// The field only names an account the guest already has, and it goes into commands, so it's limited to what a
    /// short name can hold.
    public static func guestUsernameIssue(_ name: String) -> SettingsFieldIssue? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard name.rangeOfCharacter(from: allowed.inverted) != nil else { return nil }
        return SettingsFieldIssue(
            message: "Use the guest account’s short name (letters, numbers, dots, hyphens or underscores).")
    }

    /// The Advanced sheet's local port.
    public static func localPort(_ text: String) -> Result<Int, SettingsFieldIssue> {
        guard let value = NewMachineForm.wholeNumber(text, in: 1024...65535) else {
            return .failure(SettingsFieldIssue(message: "Enter a local port from 1024 to 65535."))
        }
        return .success(value)
    }

    public static let invalidMACAddressMessage =
        "Enter a valid MAC address, such as 52:54:00:12:34:56. Use a unicast address unique to this network."

    /// A locally administered unicast address.
    public static func randomMACAddress(using generator: inout some RandomNumberGenerator) -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        bytes[0] = (bytes[0] | 2) & 0xfe
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// The Graphics page's three resolution choices.
public enum DisplayResolutionChoice: Int, CaseIterable, Sendable {
    case moreSpace, bestForRetina, scaled

    public var mode: String {
        switch self {
        case .moreSpace: "space"
        case .bestForRetina: "retina"
        case .scaled: "scaled"
        }
    }

    public var title: String {
        switch self {
        case .moreSpace: "More Space"
        case .bestForRetina: "Best for Retina display"
        case .scaled: "Scaled"
        }
    }

    /// Nil if the title says it all.
    public func detail(supportsRetina: Bool) -> String? {
        switch self {
        case .moreSpace:
            supportsRetina
                ? "Graphics at full Retina resolution. Text and interface are small."
                : "Graphics at full display resolution. Text and interface are small."
        case .bestForRetina: nil
        case .scaled: "Graphics scaled to full size."
        }
    }

    public static func available(supportsRetina: Bool) -> [DisplayResolutionChoice] {
        supportsRetina ? allCases : [.moreSpace, .scaled]
    }

    /// Machine.plist has always held `RetinaEnabled` as an integer when it comes from here.
    public var settings: [String: Any] {
        ["DisplayMode": mode, "RetinaEnabled": self != .scaled ? 1 : 0]
    }
}

/// The Network page's Source menu, whose first item is Disconnected.
public enum NetworkSource {
    public static let modes = ["shared", "host", "bridged"]
    public static let titles = [
        "Disconnected", "Shared Network (Recommended)", "Host-Only Network", "Bridged Network"
    ]

    public static func selectedIndex(mode: String, isDisconnected: Bool) -> Int {
        isDisconnected ? 0 : 1 + (modes.firstIndex(of: mode) ?? 0)
    }

    /// The mode a menu item means. Disconnected keeps the current one.
    public static func mode(forIndex index: Int, current: String) -> (mode: String, connected: Bool) {
        index == 0 ? (current, false) : (modes[index - 1], true)
    }

    public static func explanation(mode: String) -> String {
        switch mode {
        case "host": "Connects to this Mac and other host-only virtual Macs, without access to the internet."
        case "bridged":
            "Connects directly to your local network. Other devices can reach services you enable inside the virtual Mac."
        default: "The virtual Mac shares this Mac’s internet connection."
        }
    }
}

/// What a machine's package takes up.
public struct PackageStorage: Equatable, Sendable {
    public var diskBytes: UInt64 = 0
    public var otherBytes: UInt64 = 0

    public init(diskBytes: UInt64 = 0, otherBytes: UInt64 = 0) {
        self.diskBytes = diskBytes
        self.otherBytes = otherBytes
    }

    /// The disk's width on the bar, never hiding either part.
    public var diskShare: Double {
        let total = diskBytes + otherBytes
        return total == 0 ? 0.98 : max(0.01, min(0.99, Double(diskBytes) / Double(total)))
    }

    /// Walks `package`, counting the file at relative path `disk` apart from the rest, however it's linked. Symbolic
    /// links and hidden files aren't counted.
    public static func measure(package: URL, disk: String?) -> PackageStorage {
        var storage = PackageStorage()
        var diskInfo = stat()
        let hasDisk = disk?.isEmpty == false
        if hasDisk, let disk { stat(package.appendingPathComponent(disk).path, &diskInfo) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey]
        let files = FileManager.default.enumerator(
            at: package, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        while let file = files?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            // The enumerator doesn't follow links. Calling skipDescendants here would skip the next real folder.
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let allocated = values.fileAllocatedSize ?? 0
            let size = UInt64(allocated != 0 ? allocated : values.fileSize ?? 0)
            var info = stat()
            let isDisk =
                hasDisk && stat(file.path, &info) == 0 && info.st_dev == diskInfo.st_dev
                && info.st_ino == diskInfo.st_ino
            if isDisk { storage.diskBytes += size } else { storage.otherBytes += size }
        }
        return storage
    }

    /// The Hard Disk page's two lines.
    public static func summary(capacityBytes: UInt64, allocatedBytes: Int64?) -> String {
        let capacity =
            capacityBytes != 0 ? String(format: "%g GB", Double(capacityBytes) / Double(1 << 30)) : "Not recorded"
        let size =
            allocatedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable"
        return "Disk capacity: \(capacity)\nDisk file space on this Mac: \(size)"
    }
}

/// The confirmation after Set Up Remote Login. A saved opt-out or a changed port only takes effect at the next start.
public enum RemoteLoginMessage {
    public static func enabled(needsRestart: Bool) -> String {
        needsRestart
            ? "Remote Login is enabled in the virtual Mac. You previously turned off or changed its local connection "
                + "port; restart the virtual Mac to apply that change, then use the command shown here."
            : "Remote Login is enabled. Use the command shown here with your virtual Mac’s account and password—there’s "
                + "no need to restart."
    }
}

/// Terminal's profile document for a connection, which opens it without AppleEvents permission or edits to the global
/// ssh_config. It holds no credential or shell script.
public enum TerminalConnectionProfile {
    public static let directory = "com.mac.virtualintelmac/Connections"

    public static func settings(name: String, command: String) -> [String: Any] {
        [
            "type": "Window Settings", "name": name, "CommandString": command, "RunCommandAsShell": false,
            "ProfileCurrentVersion": 2.08
        ]
    }
}
