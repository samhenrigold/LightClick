import Foundation
import InstallerKit

extension MachineConfiguration {
    /// The primary optical or disk slot and three USB images. Matches `VIMImageSlotCount`.
    public static let imageSlotCount = 4

    /// A MAC an emulator can be given safely: exact shape, so nothing can be injected into its arguments, unicast and
    /// not all zeros.
    public static func isValidMACAddress(_ address: String) -> Bool {
        let units = Array(address.utf16)
        guard units.count == 17 else { return false }
        var bytes: [UInt8] = []
        for start in stride(from: 0, to: 18, by: 3) {
            guard let high = hexDigit(units[start]), let low = hexDigit(units[start + 1]),
                start == 15 || units[start + 2] == UInt16(UInt8(ascii: ":"))
            else { return false }
            bytes.append(high << 4 | low)
        }
        return bytes[0] & 1 == 0 && bytes.contains { $0 != 0 }
    }

    private static func hexDigit(_ unit: UInt16) -> UInt8? {
        guard let ascii = UInt8(exactly: unit) else { return nil }
        return switch ascii {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): ascii - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): ascii - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): ascii - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Every rule a saved or edited setting must satisfy. Checks the stored values rather than the typed properties,
    /// since a value of the wrong type is what this must refuse.
    public var hasValidSettings: Bool {
        if let value = self[.networkMode], value.string.flatMap(NetworkMode.init(rawValue:)) == nil { return false }
        if let value = self[.bridgeInterface], !fits(value, within: 64) { return false }
        for key in [Key.cpuCount, .memoryMiB, .sshPort, .fileSharingPort, .screenSharingPort] {
            if let value = self[key] {
                guard let number = value.number, number.doubleValue == Double(number.intValue) else { return false }
            }
        }
        let cpu = self[.cpuCount]?.number?.intValue ?? 0
        let memory = self[.memoryMiB]?.number?.intValue ?? 0
        guard (1...64).contains(cpu), (1024...1_048_576).contains(memory) else { return false }
        for key in [
            Key.sshEnabled, .fileSharingEnabled, .screenSharingEnabled, .audioEnabled, .retinaEnabled,
            .networkConnected, .clipboardEnabled
        ] {
            if let value = self[key] {
                guard let number = value.number, [0, 1].contains(number.doubleValue) else { return false }
            }
        }
        for key in [Key.sshPort, .fileSharingPort, .screenSharingPort] {
            if let number = self[key]?.number, !(1024...65535).contains(number.intValue) { return false }
        }
        let ssh = self[.sshEnabled].boolValue
        let fileSharing = self[.fileSharingEnabled].boolValue
        let screenSharing = self[.screenSharingEnabled].boolValue
        if ssh && self[.sshPort] == nil { return false }
        if fileSharing && self[.fileSharingPort] == nil { return false }
        if screenSharing && self[.screenSharingPort] == nil { return false }
        if ssh && fileSharing && self[.sshPort].isEqual(self[.fileSharingPort]) { return false }
        if screenSharing && ssh && self[.screenSharingPort].isEqual(self[.sshPort]) { return false }
        if screenSharing && fileSharing && self[.screenSharingPort].isEqual(self[.fileSharingPort]) { return false }
        if let value = self[.description], !fits(value, within: 4096) { return false }
        if let value = self[.opticalMedia], !isEmptyOrAbsolutePath(value) { return false }
        if let value = self[.additionalMedia] {
            guard let paths = value.array, paths.count < Self.imageSlotCount, paths.allSatisfy(isEmptyOrAbsolutePath)
            else {
                return false
            }
        }
        if let value = self[.macAddress] {
            guard let address = value.string, address.isEmpty || Self.isValidMACAddress(address) else { return false }
        }
        if let value = self[.displayMode], value.string.flatMap(DisplayMode.init(rawValue:)) == nil { return false }
        if let value = self[.displayScalingFilter],
            value.string.flatMap(DisplayScalingFilter.init(rawValue:)) == nil
        {
            return false
        }
        if let value = self[.executionEngine], value.string.flatMap(ExecutionEngine.init(rawValue:)) == nil {
            return false
        }
        for key in [Key.audioOutputDevice, .audioInputDevice] {
            if let value = self[key], !fits(value, within: 1024) { return false }
        }
        return true
    }

    private func fits(_ value: PropertyListValue, within limit: Int) -> Bool {
        value.string.map { $0.utf16.count <= limit } ?? false
    }

    private func isEmptyOrAbsolutePath(_ value: PropertyListValue) -> Bool {
        value.string.map { $0.isEmpty || ($0 as NSString).isAbsolutePath } ?? false
    }

    /// The checks a package must pass before anything in it is trusted, in the order they report. `package` must
    /// already have its symlinks resolved. Reads the file system to confirm each referenced file is a regular file
    /// inside the package, or for a shared installer, a regular file at its absolute path.
    public func validate(package: URL) throws(MachineConfigurationError) {
        guard self[.formatVersion].isEqual(1),
            PackageNaming.isValid(package.deletingPathExtension().lastPathComponent),
            self[.name].map({ $0.string.map(PackageNaming.isValid) ?? false }) ?? true,
            guest != nil,
            let cpu = self[.cpuCount]?.number?.intValue, (1...64).contains(cpu),
            let memory = self[.memoryMiB]?.number?.intValue, memory >= 1024,
            identifier != nil
        else { throw .invalidConfiguration }

        var fileKeys = [Key.disk, .firmware, .nvram, .bootMedia]
        if firmwareSource == .application { fileKeys.removeAll { $0 == .firmware || $0 == .bootMedia } }
        if let kind = self[.bootMediaKind], kind.string.flatMap(BootMediaKind.init(rawValue:)) == nil {
            throw .unsupportedBootMedia
        }

        let shared = self[.installerMediaShared].isTrue
        if let media = self[.installerMedia] {
            if let kind = self[.installerMediaKind], kind.string.flatMap(InstallerMediaKind.init(rawValue:)) == nil {
                throw .unsupportedInstallerMediaKind
            }
            guard installState == .installing || installState == .patching,
                media.string == InstallerMediaLocation.ownedPath
                    || (shared && media.string.flatMap(AbsolutePath.init(rawValue:)) != nil)
            else { throw .installerMediaInInvalidState }
            fileKeys.append(.installerMedia)
        }

        for key in fileKeys {
            if key == .installerMedia && shared {
                guard let path = self[key]?.string.flatMap(AbsolutePath.init(rawValue:)) else {
                    throw .sharedInstallerNotAbsolute
                }
                guard Self.isRegularFile(URL(fileURLWithPath: path.rawValue)) else { throw .sharedInstallerMissing }
                continue
            }
            guard let path = self[key]?.string.flatMap(PackagePath.init(rawValue:)) else { throw .invalidFilePath }
            guard let file = path.resolved(in: package), Self.isRegularFile(file) else {
                throw .fileMissingOrOutsidePackage(key.rawValue)
            }
        }

        guard hasValidSettings else { throw .invalidHardwareSettings }
        // Doesn't follow a symlink: State holds the locks and evidence, so it must really be here.
        let state = package.appendingPathComponent("State").path
        guard (try? FileManager.default.attributesOfItem(atPath: state))?[.type] as? FileAttributeType == .typeDirectory
        else { throw .missingStateFolder }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}
