import Foundation
import InstallerKit

public enum InstallState: String, Codable, Sendable {
    case installing
    case patching
    case installed
    case importedPrepared = "imported-prepared"
    case hostPopulated = "host-populated"
}

public enum NetworkMode: String, Codable, Sendable {
    case shared
    case host
    case bridged
}

public enum DisplayMode: String, Codable, Sendable {
    case retina
    case scaled
    case space
}

public enum DisplayScalingFilter: String, Codable, Sendable {
    case linear
    case nearest
}

public enum BootMediaKind: String, Codable, Sendable {
    case legacyOpenCoreISO = "legacy-opencore-iso"
    case efiDisk = "efi-disk"
}

public enum InstallerMediaKind: String, Codable, Sendable {
    case optical
    case disk
}

public enum FirmwareSource: String, Codable, Sendable {
    case application
    case package
}

public enum LegacyDisplayAdapter: String, Codable, Sendable {
    case vmware
}

/// A machine's Machine.plist.
///
/// The property list is the one source of truth and the typed properties read and write it. So a key this version
/// doesn't know, a value in an older form (`1` for a Boolean) and a value of the wrong type all survive a round trip
/// untouched, and validation sees exactly what's on disk. A typed getter returns nil for a missing or malformed value;
/// `hasValidSettings` and `validate(package:)` are what reject one.
public struct MachineConfiguration: Sendable, Equatable {
    public var values: [String: PropertyListValue]

    public init(values: [String: PropertyListValue] = [:]) {
        self.values = values
    }

    /// Nil unless the object is a dictionary with string keys.
    public init?(foundationObject: Any?) {
        guard let dictionary = foundationObject as? [String: Any] else { return nil }
        values = dictionary.mapValues(PropertyListValue.init(foundationObject:))
    }

    /// Reads a file's bytes with the property list reader VIMMachine used. Unlike Codable, this keeps a `<real>` a
    /// real.
    public init(propertyList data: Data) throws {
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let configuration = MachineConfiguration(foundationObject: object) else {
            throw MachineConfigurationError.invalidConfiguration
        }
        self = configuration
    }

    /// The bytes VIMMachine writes: XML, sorted keys.
    public func propertyList() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: foundationObject, format: .xml, options: 0)
    }

    public var foundationObject: NSDictionary {
        values.mapValues(\.foundationObject) as NSDictionary
    }

    /// The Machine.plist keys. Anything else in a file is kept and otherwise ignored.
    public enum Key: String, CaseIterable, Sendable {
        case formatVersion = "FormatVersion"
        case identifier = "Identifier"
        case name = "Name"
        case guest = "Guest"
        case cpuCount = "CPUCount"
        case memoryMiB = "MemoryMiB"
        case disk = "Disk"
        case diskGiB = "DiskGiB"
        case firmware = "Firmware"
        case nvram = "NVRAM"
        case bootMedia = "BootMedia"
        case bootMediaKind = "BootMediaKind"
        case firmwareSource = "FirmwareSource"
        case installerMedia = "InstallerMedia"
        case installerMediaKind = "InstallerMediaKind"
        case installerMediaShared = "InstallerMediaShared"
        case installState = "InstallState"
        case importedFrom = "ImportedFrom"
        case networkMode = "NetworkMode"
        case bridgeInterface = "BridgeInterface"
        case networkConnected = "NetworkConnected"
        case macAddress = "MACAddress"
        case sshEnabled = "SSHEnabled"
        case sshPort = "SSHPort"
        case fileSharingEnabled = "FileSharingEnabled"
        case fileSharingPort = "FileSharingPort"
        case audioEnabled = "AudioEnabled"
        case audioOutputDevice = "AudioOutputDevice"
        case audioInputDevice = "AudioInputDevice"
        case clipboardEnabled = "ClipboardEnabled"
        case description = "Description"
        case retinaEnabled = "RetinaEnabled"
        case displayMode = "DisplayMode"
        case displayScalingFilter = "DisplayScalingFilter"
        case opticalMedia = "OpticalMedia"
        case additionalMedia = "AdditionalMedia"
        case legacyDisplayAdapter = "LegacyDisplayAdapter"
        case passthroughOpenGLEnabled = "PassthroughOpenGLEnabled"
        case legacyDirectGLBridge = "LegacyDirectGLBridge"
        case legacyGDBPort = "LegacyGDBPort"
    }

    public subscript(key: Key) -> PropertyListValue? {
        get { values[key.rawValue] }
        set { values[key.rawValue] = newValue }
    }

    private func typed<Value: RawRepresentable>(_ key: Key) -> Value? where Value.RawValue == String {
        self[key]?.string.flatMap(Value.init(rawValue:))
    }

    private mutating func setTyped<Value: RawRepresentable>(_ key: Key, _ value: Value?)
    where Value.RawValue == String {
        self[key] = value.map { .string($0.rawValue) }
    }

    private mutating func setNumber(_ key: Key, _ value: NSNumber?) {
        self[key] = value.map { .number($0) }
    }

    private mutating func setString(_ key: Key, _ value: String?) {
        self[key] = value.map { .string($0) }
    }

    public var formatVersion: Int? {
        get { self[.formatVersion]?.number?.intValue }
        set { setNumber(.formatVersion, newValue as NSNumber?) }
    }

    public var identifier: UUID? {
        get { self[.identifier]?.string.flatMap(UUID.init(uuidString:)) }
        set { setString(.identifier, newValue?.uuidString) }
    }

    /// Only legacy packages named by UUID have one. Applying pending changes moves it to the package's filename.
    public var name: String? {
        get { self[.name]?.string }
        set { setString(.name, newValue) }
    }

    public var guest: Guest? {
        get { typed(.guest) }
        set { setTyped(.guest, newValue) }
    }

    public var cpuCount: Int? {
        get { self[.cpuCount]?.number?.intValue }
        set { setNumber(.cpuCount, newValue as NSNumber?) }
    }

    public var memoryMiB: Int? {
        get { self[.memoryMiB]?.number?.intValue }
        set { setNumber(.memoryMiB, newValue as NSNumber?) }
    }

    public var diskGiB: Double? {
        get { self[.diskGiB]?.number?.doubleValue }
        set { setNumber(.diskGiB, newValue as NSNumber?) }
    }

    public var disk: PackagePath? {
        get { typed(.disk) }
        set { setTyped(.disk, newValue) }
    }

    public var firmware: PackagePath? {
        get { typed(.firmware) }
        set { setTyped(.firmware, newValue) }
    }

    public var nvram: PackagePath? {
        get { typed(.nvram) }
        set { setTyped(.nvram, newValue) }
    }

    public var bootMedia: PackagePath? {
        get { typed(.bootMedia) }
        set { setTyped(.bootMedia, newValue) }
    }

    public var bootMediaKind: BootMediaKind? {
        get { typed(.bootMediaKind) }
        set { setTyped(.bootMediaKind, newValue) }
    }

    public var firmwareSource: FirmwareSource? {
        get { typed(.firmwareSource) }
        set { setTyped(.firmwareSource, newValue) }
    }

    /// Nil when absent or when the stored path breaks the rules for its kind.
    public var installerMedia: InstallerMediaLocation? {
        get {
            guard let path = self[.installerMedia]?.string else { return nil }
            if self[.installerMediaShared].isTrue {
                return AbsolutePath(rawValue: path).map(InstallerMediaLocation.shared)
            }
            return path == InstallerMediaLocation.ownedPath ? .owned : nil
        }
        set {
            switch newValue {
            case .owned:
                setString(.installerMedia, InstallerMediaLocation.ownedPath)
                self[.installerMediaShared] = nil
            case .shared(let path):
                setString(.installerMedia, path.rawValue)
                self[.installerMediaShared] = true
            case nil:
                self[.installerMedia] = nil
                self[.installerMediaShared] = nil
            }
        }
    }

    public var installerMediaKind: InstallerMediaKind? {
        get { typed(.installerMediaKind) }
        set { setTyped(.installerMediaKind, newValue) }
    }

    public var installState: InstallState? {
        get { typed(.installState) }
        set { setTyped(.installState, newValue) }
    }

    public var importedFrom: String? {
        get { self[.importedFrom]?.string }
        set { setString(.importedFrom, newValue) }
    }

    /// `shared` unless set to something else valid.
    public var networkMode: NetworkMode {
        get { typed(.networkMode) ?? .shared }
        set { setTyped(.networkMode, newValue) }
    }

    public var bridgeInterface: String? {
        get { self[.bridgeInterface]?.string }
        set { setString(.bridgeInterface, newValue) }
    }

    public var networkConnected: Bool? {
        get { self[.networkConnected]?.number?.boolValue }
        set { setNumber(.networkConnected, newValue as NSNumber?) }
    }

    public var macAddress: String? {
        get { self[.macAddress]?.string }
        set { setString(.macAddress, newValue) }
    }

    public var sshEnabled: Bool? {
        get { self[.sshEnabled]?.number?.boolValue }
        set { setNumber(.sshEnabled, newValue as NSNumber?) }
    }

    public var sshPort: Int? {
        get { self[.sshPort]?.number?.intValue }
        set { setNumber(.sshPort, newValue as NSNumber?) }
    }

    public var fileSharingEnabled: Bool? {
        get { self[.fileSharingEnabled]?.number?.boolValue }
        set { setNumber(.fileSharingEnabled, newValue as NSNumber?) }
    }

    public var fileSharingPort: Int? {
        get { self[.fileSharingPort]?.number?.intValue }
        set { setNumber(.fileSharingPort, newValue as NSNumber?) }
    }

    public var audioEnabled: Bool? {
        get { self[.audioEnabled]?.number?.boolValue }
        set { setNumber(.audioEnabled, newValue as NSNumber?) }
    }

    public var audioOutputDevice: String? {
        get { self[.audioOutputDevice]?.string }
        set { setString(.audioOutputDevice, newValue) }
    }

    public var audioInputDevice: String? {
        get { self[.audioInputDevice]?.string }
        set { setString(.audioInputDevice, newValue) }
    }

    public var clipboardEnabled: Bool? {
        get { self[.clipboardEnabled]?.number?.boolValue }
        set { setNumber(.clipboardEnabled, newValue as NSNumber?) }
    }

    public var machineDescription: String? {
        get { self[.description]?.string }
        set { setString(.description, newValue) }
    }

    public var retinaEnabled: Bool? {
        get { self[.retinaEnabled]?.number?.boolValue }
        set { setNumber(.retinaEnabled, newValue as NSNumber?) }
    }

    public var displayMode: DisplayMode? {
        get { typed(.displayMode) }
        set { setTyped(.displayMode, newValue) }
    }

    public var displayScalingFilter: DisplayScalingFilter? {
        get { typed(.displayScalingFilter) }
        set { setTyped(.displayScalingFilter, newValue) }
    }

    /// Nil when no image is selected: the file stores "" for an empty slot.
    public var opticalMedia: AbsolutePath? {
        get { typed(.opticalMedia) }
        set { setString(.opticalMedia, newValue?.rawValue ?? "") }
    }

    /// The slots after `opticalMedia`, with nil for an empty one.
    public var additionalMedia: [AbsolutePath?] {
        get { (self[.additionalMedia]?.array ?? []).map { $0.string.flatMap(AbsolutePath.init(rawValue:)) } }
        set { self[.additionalMedia] = .array(newValue.map { .string($0?.rawValue ?? "") }) }
    }

    public var legacyDisplayAdapter: LegacyDisplayAdapter? {
        get { typed(.legacyDisplayAdapter) }
        set { setTyped(.legacyDisplayAdapter, newValue) }
    }

    public var legacyGDBPort: Int? {
        get { self[.legacyGDBPort]?.number?.intValue }
        set { setNumber(.legacyGDBPort, newValue as NSNumber?) }
    }

    /// `LegacyDirectGLBridge` is the old name. It's read as a fallback and left in the file.
    public var passthroughOpenGLEnabled: Bool {
        get { (self[.passthroughOpenGLEnabled] ?? self[.legacyDirectGLBridge]).boolValue }
        set { self[.passthroughOpenGLEnabled] = .number(newValue as NSNumber) }
    }

    /// The display mode a launch uses. `RetinaEnabled` is the old setting, read when no `DisplayMode` was ever saved.
    /// Guests with no backing scale can't be asked for 2x, whatever an imported preference says.
    public var effectiveDisplayMode: DisplayMode {
        if guest?.traits.contains(.noBackingScale) == true {
            return displayMode == .space ? .space : .scaled
        }
        if let displayMode { return displayMode }
        return self[.retinaEnabled] != nil && !self[.retinaEnabled].boolValue ? .scaled : .retina
    }

    /// The user's validated override in uppercase, or the default derived from the identifier, which a rename can't
    /// change.
    public var effectiveMACAddress: String {
        if let macAddress, MachineConfiguration.isValidMACAddress(macAddress) { return macAddress.uppercased() }
        let identity = (self[.identifier]?.string ?? "").replacingOccurrences(of: "-", with: "")
        guard identity.utf16.count >= 8 else { return "52:54:00:00:00:01" }
        let bytes = stride(from: 0, to: 8, by: 2).map { offset in
            (identity as NSString).substring(with: NSRange(location: offset, length: 2))
        }
        return (["52", "54"] + bytes).joined(separator: ":").uppercased()
    }
}

extension MachineConfiguration: Codable {
    public init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: PropertyListValue].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}
