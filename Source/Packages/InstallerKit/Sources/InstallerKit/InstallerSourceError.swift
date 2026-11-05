import Foundation

/// Why a source can't be used. Bridges to the `VirtualIntelMac.InstallerSource` errors.
public enum InstallerSourceError: Error, Sendable, LocalizedError, CustomNSError {
    case unsupportedLocation
    case recoveryUnavailable
    case invalidChallenge
    case unexpectedInstaller
    case noVerificationRecord
    case unreadableDownload
    case unverifiableDownload
    case digestMismatch

    public static var errorDomain: String { "VirtualIntelMac.InstallerSource" }

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocation: "This installer download location is not supported."
        case .recoveryUnavailable:
            "Apple’s recovery service could not authorize the Mavericks download. Your partial download is saved; "
                + "try again later."
        case .invalidChallenge: "Apple’s recovery service returned an invalid challenge."
        case .unexpectedInstaller: "Apple’s recovery service did not provide the expected Mavericks installer."
        case .noVerificationRecord:
            "The recovery download has no matching verification record in the installer catalog."
        case .unreadableDownload: "The downloaded installer could not be read."
        case .unverifiableDownload: "The downloaded installer could not be verified."
        case .digestMismatch:
            "The download did not match the expected Apple installer. It was not used. Remove the saved download and "
                + "try again."
        }
    }

    public var errorCode: Int { 1 }
}
