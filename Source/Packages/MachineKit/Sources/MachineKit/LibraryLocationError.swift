import Foundation

/// Why a library couldn't be selected or organized. The messages, domain and codes are the ones VIMLibraryLocation
/// reported. The app ignores `EBUSY` at launch and tries again next time, so the busy cases must keep that code.
public enum LibraryLocationError: Error, Equatable, Sendable, LocalizedError, CustomNSError {
    case notAFolder
    case anotherCopyOrganizing
    case creationInProgress
    case machineRunning
    case machineSettingsSaving
    case unreadableLayoutRecord
    case invalidLayoutRecord
    case unexpectedLocationInRecord
    case duplicateItem
    case missingItem

    public static var errorDomain: String { "VirtualIntelMac.Library" }

    public var errorCode: Int {
        switch self {
        case .anotherCopyOrganizing, .creationInProgress, .machineRunning, .machineSettingsSaving: Int(EBUSY)
        default: 1
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notAFolder: "Choose an existing folder for your Macs."
        case .anotherCopyOrganizing:
            "Another copy of Light Click is organizing this library. Try again after it finishes."
        case .creationInProgress: "The library will be organized after the current Mac finishes being created."
        case .machineRunning: "The library will be organized after all its virtual Macs have shut down."
        case .machineSettingsSaving: "Wait for this Mac’s settings to finish saving, then try again."
        case .unreadableLayoutRecord: "The library’s layout record is unreadable. Its files have not been removed."
        case .invalidLayoutRecord: "The library’s layout record is invalid."
        case .unexpectedLocationInRecord: "The library’s layout record contains an unexpected location."
        case .duplicateItem:
            "Two library items have the same name. Nothing will be overwritten. Rename the duplicate and try again."
        case .missingItem: "A library item is missing. Reconnect its drive before trying again."
        }
    }

    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}
