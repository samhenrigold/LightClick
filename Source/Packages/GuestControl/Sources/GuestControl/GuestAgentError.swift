import Foundation

/// A guest-agent failure. The messages, NSError domains and codes are the ones VIMGuestAgent reported.
public enum GuestAgentError: Error, Equatable {
    /// The raw value is the message people see.
    public enum Reason: String, Sendable {
        case closed = "The guest controller is closed."
        case cannotStart = "The guest command cannot be started."
        case noProcessIdentifier = "The guest did not return a process identifier."
        case interrupted = "The guest command was interrupted or timed out. It may still be running."
        case invalidProcessStatus = "The guest returned an invalid process status."
        case outputIncomplete = "The guest command output was incomplete."
        case outputInvalid = "The guest command output was invalid."
        case noExitStatus = "The guest command did not report its exit status."
        case notConnected = "The virtual Mac’s guest tools are not connected."
        case shutdownNotAcknowledged =
            "The virtual Mac did not acknowledge shutdown. It may already be shutting down; the request was not repeated."
        case stagingFileNotOpened = "The guest could not open the staging file."
        case transferInterrupted = "Guest transfer was interrupted or timed out. Partial staging was retained."
        case stagingFileIncomplete = "The guest staging file was not completely written."
        case statusProbeUnavailable = "The guest status probe is unavailable or already running."
        case busyOpeningConnection = "Wait for this virtual Mac’s current operation to finish, then try again."
        case unsupportedConnection = "Choose a supported connection to this Mac."
        case sshClientFailed =
            "Terminal couldn’t open the modern SSH client inside this virtual Mac. Make sure its guest support is up to date and sign in to its desktop, then try again."
        case guestInterfaceUnavailable =
            "Start the virtual Mac, sign in and wait for setup to finish, then try again. You can also open System Preferences inside the virtual Mac."
        case connectionNotOpened =
            "The connection could not open inside the virtual Mac. Sign in to its desktop and try again."
        case notSignedIn = "Sign in to the virtual Mac’s desktop before opening its settings."
        case invalidReport = "The guest returned an invalid installation report."
        case notPrivileged = "Automatic guest setup requires the built-in privileged guest agent."
        case probeDirectoryNotCreated = "The guest could not create a private staging directory."
        case probeNotPrepared = "Could not prepare the guest probe."
        case transferUnavailable = "Guest setup transfer is unavailable or another operation is active."
        case invalidInputName = "Invalid guest setup file name or source."
        case inputNotRegularFile = "Guest setup input is not a regular file."
        case transferLimitExceeded = "Guest setup files exceed the transfer limit."
        case transferCancelled = "Guest transfer was cancelled."
        case transferDirectoryNotCreated = "The guest could not create a private transfer directory."
        case stagingFileNotSecured = "Could not secure a guest staging file."
    }

    case guest(Reason)
    case control(QMPError)
    /// A failure reading a local input file or parsing a probe's report, passed through as it was.
    case foundation(NSError)
    /// A failed upload, naming the directory it retained for diagnosis.
    indirect case staging(GuestAgentError, directory: String)
}

extension GuestAgentError: LocalizedError {
    public var errorDescription: String? { nsError.localizedDescription }

    /// The NSError VIMGuestAgent reported. A wrapped error keeps its own domain and code, so this isn't `CustomNSError`,
    /// whose domain is per type.
    public var nsError: NSError {
        switch self {
        case .guest(let reason):
            NSError(
                domain: "VirtualIntelMac.GuestAgent",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason.rawValue]
            )
        case .control(let error): error as NSError
        case .foundation(let error): error
        case .staging(let error, let directory):
            NSError(
                domain: error.nsError.domain,
                code: error.nsError.code,
                userInfo: [
                    NSLocalizedDescriptionKey: error.nsError.localizedDescription,
                    "GuestStagingDirectory": directory
                ]
            )
        }
    }
}
