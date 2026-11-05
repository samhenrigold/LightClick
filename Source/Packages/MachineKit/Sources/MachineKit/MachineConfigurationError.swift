import Foundation

/// Why a configuration was refused. The messages, NSError domain and code are the ones VIMMachine reported.
public enum MachineConfigurationError: Error, Equatable, Sendable, LocalizedError, CustomNSError {
    case invalidConfiguration
    case unsupportedBootMedia
    case unsupportedInstallerMediaKind
    case installerMediaInInvalidState
    case sharedInstallerNotAbsolute
    case sharedInstallerMissing
    case invalidFilePath
    case fileMissingOrOutsidePackage(String)
    case invalidHardwareSettings
    case missingStateFolder
    case invalidRename
    case unsupportedSetting
    case queuedUnsupportedSetting
    case invalidSettings
    case installerStillAttached

    public static var errorDomain: String { "VirtualIntelMac.Machine" }
    public var errorCode: Int { 1 }

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "This Mac’s configuration is invalid or not supported by this version."
        case .unsupportedBootMedia: "This Mac uses an unsupported boot media format."
        case .unsupportedInstallerMediaKind: "Unsupported installer media device type."
        case .installerMediaInInvalidState: "Installer media is attached in an invalid installation state."
        case .sharedInstallerNotAbsolute: "Shared installer path must be absolute."
        case .sharedInstallerMissing: "The shared installer is missing. Restore it to its original location."
        case .invalidFilePath: "The package contains an invalid file path."
        case .fileMissingOrOutsidePackage(let key): "The \(key) file is missing or outside this package."
        case .invalidHardwareSettings: "This Mac has invalid memory, processor or network settings."
        case .missingStateFolder: "This Mac’s State folder is missing or is not a regular folder."
        case .invalidRename: "Enter a name of 1–128 characters without slashes, colons, or a leading dot."
        case .unsupportedSetting: "Unsupported setting."
        case .queuedUnsupportedSetting: "The queued configuration contains an unsupported setting."
        case .invalidSettings: "Use 1–64 processors, 1–1024 GB of memory and distinct ports from 1024–65535."
        case .installerStillAttached: "Restart this Mac without its installer before completing setup."
        }
    }

    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}
