import Foundation

/// Why guest preparation stopped. They're shown to the user. The ones that carry text show a guest tool's own diagnostic.
public enum GuestPreparationError: Error, Equatable, Sendable, LocalizedError, CustomNSError {
    case unsuitableSystem
    case supportDiscIncomplete
    case supportDiscNotLocated
    case diskListNotRecognized
    case supportDiscMissingOrAmbiguous
    case supportDiscNotReadOnly
    case supportDiscMountFailed
    case stagingNotVerified(diagnostic: String?)
    case stagedCopyIncomplete
    case supportDiscDeviceUnknown
    case supportDiscHeldByLoginWindow
    case supportDiscInUse
    case utilitiesNotPrepared
    case environmentNotEligible(diagnostic: String?)
    case extractionFailed
    case filePreparationFailed
    case guestChanged
    case planningFailed
    case planHasNoTransaction

    public static var errorDomain: String { "VirtualIntelMac.GuestPreparation" }
    public var errorCode: Int { 1 }

    public var errorDescription: String? {
        switch self {
        case .unsuitableSystem:
            "Preparation requires a matching installed Mojave, Catalina or Big Sur system with verified volume identity. Initial setup also requires a usable desktop."
        case .supportDiscIncomplete: "This app’s guest support disc is incomplete. Reinstall the app and try again."
        case .supportDiscNotLocated: "The support disc couldn’t be located before login. Nothing was installed."
        case .diskListNotRecognized: "The guest disk list was not recognized."
        case .supportDiscMissingOrAmbiguous: "The guest support disc is missing or ambiguous. Nothing was installed."
        case .supportDiscNotReadOnly: "The support disc isn’t verified as read-only. Nothing was installed."
        case .supportDiscMountFailed:
            "The read-only support disc couldn’t be mounted before login. Nothing was installed."
        case .stagingNotVerified(let diagnostic):
            diagnostic ?? "Could not verify the private guest support copy. Nothing was installed."
        case .stagedCopyIncomplete: "The guest support copy is incomplete. Nothing was installed."
        case .supportDiscDeviceUnknown:
            "Could not identify the verified support disc for removal. Nothing was installed."
        case .supportDiscHeldByLoginWindow:
            "macOS kept the support disc in use. Unlock your virtual Mac, then try setup again. No system files were installed."
        case .supportDiscInUse:
            "macOS couldn’t release the setup disc. Close any windows using it, then try setup again. No system files were installed."
        case .utilitiesNotPrepared: "Could not prepare guest utilities."
        case .environmentNotEligible(let diagnostic):
            diagnostic
                ?? "The guest does not meet setup requirements or changed since it was checked. Nothing was installed."
        case .extractionFailed: "Guest payload extraction failed. Diagnostic staging was retained."
        case .filePreparationFailed:
            "Guest file preparation failed. Nothing was installed; diagnostic staging was retained."
        case .guestChanged: "The guest changed while setup files were being prepared."
        case .planningFailed: "Installation planning failed. Nothing was installed; diagnostics were retained."
        case .planHasNoTransaction: "Installation plan has no valid transaction identity."
        }
    }

    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}
