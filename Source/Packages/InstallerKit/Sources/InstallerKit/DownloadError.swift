import Foundation

/// Why a download stopped. Bridges to the `VirtualIntelMac.Download` errors.
public enum DownloadError: Error, Sendable, LocalizedError, CustomNSError {
    case invalidLocation
    case alreadyRunning
    case lockedByAnotherProcess
    case foreignDirectory
    case invalidState
    case incompleteCache
    case cannotOpenPartial
    case cannotRestartPartial
    case invalidResponse(status: Int)
    case cannotPositionPartial
    case exceededExpectedLength
    case cannotSave
    case incompleteTransfer
    case cannotFlush
    case source(InstallerSourceError)
    case system(NSError)

    static let invalidResponseCode = 2

    public static var errorDomain: String { "VirtualIntelMac.Download" }

    public var errorDescription: String? {
        switch self {
        case .invalidLocation: "Invalid installer download location."
        case .alreadyRunning: "This download is already running."
        case .lockedByAnotherProcess: "Another process is using this download."
        case .foreignDirectory: "This download folder belongs to another file."
        case .invalidState: "Invalid download state."
        case .incompleteCache:
            "The cached installer is incomplete. Remove this download through the app before retrying."
        case .cannotOpenPartial: "Cannot open this download, or another process is using it."
        case .cannotRestartPartial: "Could not restart the partial download."
        case .invalidResponse(let status): "The server returned an invalid download response (HTTP \(status))."
        case .cannotPositionPartial: "Could not position the partial download."
        case .exceededExpectedLength: "The download exceeded its expected length."
        case .cannotSave: "Could not save the download. Check available disk space."
        case .incompleteTransfer: "The installer download did not finish completely."
        case .cannotFlush: "Could not flush the completed download to disk."
        case .source(let error): error.errorDescription
        case .system(let error): error.localizedDescription
        }
    }

    public var errorCode: Int {
        if case .invalidResponse = self { Self.invalidResponseCode } else { 1 }
    }

    /// The error as Objective-C knew it: a wrapped error keeps its own domain and code, which `as NSError` can't do.
    public var bridged: NSError {
        switch self {
        case .source(let error): error as NSError
        case .system(let error): error
        default: self as NSError
        }
    }
}
