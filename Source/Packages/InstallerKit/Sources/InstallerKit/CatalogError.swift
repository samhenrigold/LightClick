import Foundation

/// Why a catalog could not be read or updated. Bridges to the `VirtualIntelMac.Installers` errors.
public enum CatalogError: Error, Sendable, LocalizedError, CustomNSError {
    case emptyOrTooLarge
    case invalid
    case unavailable
    case updateFailed
    case system(NSError)

    public static var errorDomain: String { "VirtualIntelMac.Installers" }

    public var errorDescription: String? {
        switch self {
        case .emptyOrTooLarge: "The installer catalog is empty or too large."
        case .invalid: "The installer catalog is invalid or incompatible."
        case .unavailable: "No valid installer catalog is available."
        case .updateFailed: "The installer catalog could not be updated. The bundled catalog is still available."
        case .system(let error): error.localizedDescription
        }
    }

    public var errorCode: Int { 1 }
}
