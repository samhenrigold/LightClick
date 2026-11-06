import Foundation

/// What the session does with one answer from the pre-Metal setup coordinator.
@objc(VIMOpenGLSetupStep)
public enum OpenGLSetupStep: Int, Sendable {
    case askForPassword
    /// Setup has nothing more to do on this boot, so watch the desktop as any guest would.
    case monitorDesktop
    /// Apple's installer owns the progress and the next boot gets a new coordinator, so nothing polls while it copies.
    case installerRunning
    case restart
    case finish
    case waitAndAskAgain
}

/// One coordinator answer. It's built in this process, so a wrong-typed value is a missing one rather than an error.
public struct OpenGLSetupOutcome: Sendable {
    public var phase: String?
    public var automatic: Bool
    public var existingGuestUpdate: Bool

    public init(phase: String?, automatic: Bool = false, existingGuestUpdate: Bool = false) {
        self.phase = phase
        self.automatic = automatic
        self.existingGuestUpdate = existingGuestUpdate
    }

    public var step: OpenGLSetupStep {
        switch phase {
        case "credential-required": .askForPassword
        case "unmanaged", "unsupported", "setup-unavailable": .monitorDesktop
        case "recovery": .installerRunning
        case "needs-restart": .restart
        case "complete": .finish
        default: .waitAndAskAgain
        }
    }

    /// Setup chose not to touch this system, unlike a guest it was never going to manage.
    public var leftSystemUnchanged: Bool { phase == "setup-unavailable" }

    /// What to say while waiting. A phase with nothing of its own, or none at all, is still starting.
    public func waitingMessage(osName: String) -> String {
        switch phase {
        case "recovery": "Installing \(osName)…"
        case "payload-media-wait": "Waiting for the graphics update disc…"
        case "root-volume-wait": "Waiting for this Mac’s startup disk…"
        case "desktop-wait": "Waiting for this Mac’s desktop…"
        case "desktop-services-wait", "file-sharing-busy": "Finishing File Sharing setup…"
        case "update-restart-wait": "Restart this Mac when its system update finishes…"
        case "account-busy": "Creating your Mac account…"
        case "restarting": "Restarting to finish setup…"
        default: "Starting \(osName)…"
        }
    }

    /// An automatic setup or an unattended run has nobody to ask.
    public func restartsWithoutAsking(creatingGuest: Bool) -> Bool { automatic || creatingGuest }

    /// An update restarts into a working desktop. A first setup restarts into a notice covering the rest of it.
    public var showsRestartNotice: Bool { !existingGuestUpdate }

    /// An installed update waits for a restart the user agrees to, so this boot keeps its usual services meanwhile.
    public var monitorsDesktopIfDeclined: Bool { existingGuestUpdate }

    public var restartPromptTitle: String {
        existingGuestUpdate ? "Restart to use updated graphics support?" : "Restart to finish graphics setup?"
    }

    public var restartPromptDetail: String {
        existingGuestUpdate
            ? "Graphics support has been updated. Save any open work, then restart this Mac to use it."
            : "Graphics support is installed. Restart this Mac to load it. Save any open work first."
    }
}

@objc(VIMOpenGLSetupOutcome)
@objcMembers
public final class OpenGLSetupOutcomeBridge: NSObject {
    private let outcome: OpenGLSetupOutcome

    public init(outcome: Any?) {
        let values = outcome as? [String: Any] ?? [:]
        self.outcome = OpenGLSetupOutcome(
            phase: values["Phase"] as? String,
            automatic: values["Automatic"] as? Bool ?? false,
            existingGuestUpdate: values["ExistingGuestUpdate"] as? Bool ?? false)
    }

    public var step: OpenGLSetupStep { outcome.step }
    public var leftSystemUnchanged: Bool { outcome.leftSystemUnchanged }
    public var automatic: Bool { outcome.automatic }
    public var showsRestartNotice: Bool { outcome.showsRestartNotice }
    public var monitorsDesktopIfDeclined: Bool { outcome.monitorsDesktopIfDeclined }
    public var restartPromptTitle: String { outcome.restartPromptTitle }
    public var restartPromptDetail: String { outcome.restartPromptDetail }

    @objc(waitingMessageForOSName:)
    public func waitingMessage(osName: String) -> String { outcome.waitingMessage(osName: osName) }

    @objc(restartsWithoutAskingWhenCreatingGuest:)
    public func restartsWithoutAsking(creatingGuest: Bool) -> Bool {
        outcome.restartsWithoutAsking(creatingGuest: creatingGuest)
    }
}
