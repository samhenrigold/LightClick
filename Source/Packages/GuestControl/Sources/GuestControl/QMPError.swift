import Foundation

/// A control-channel failure. The messages, NSError domain and codes are the ones VIMQMPConnection reported.
public enum QMPError: Error, Equatable {
    case pathTooLong
    case unavailable
    case synchronizationFailed
    case invalidGreeting
    case invalidResponse
    case responseTooLarge
    case timedOut
    case connectionEnded
    case sendFailed
    case unexpectedResponse
    case rejected(String)
    case inputQueueFull
    case incompleteResponse
    case tooManyEvents
    case notReady
    case invalidArguments

    public var message: String {
        switch self {
        case .pathTooLong: "The control connection path is too long."
        case .unavailable: "The virtual machine’s control connection did not become available."
        case .synchronizationFailed: "Guest-agent synchronization failed."
        case .invalidGreeting: "The virtual machine sent an invalid control greeting."
        case .invalidResponse: "Invalid control response."
        case .responseTooLarge: "The control response exceeded its size limit."
        case .timedOut: "The control response timed out."
        case .connectionEnded: "The control connection ended or timed out."
        case .sendFailed: "Could not send a virtual machine command."
        case .unexpectedResponse: "An unexpected control response was received."
        case .rejected(let detail): detail
        case .inputQueueFull: "The guest keyboard is busy."
        case .incompleteResponse: "The control response was incomplete."
        case .tooManyEvents: "Too many unsolicited control events."
        case .notReady: "The virtual machine is not ready for commands."
        case .invalidArguments: "The command arguments aren’t valid JSON."
        }
    }
}

extension QMPError: CustomNSError, LocalizedError {
    public static var errorDomain: String { "VirtualIntelMac.Control" }
    public var errorCode: Int { self == .inputQueueFull ? 2 : 1 }
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }
    public var errorDescription: String? { message }
}
