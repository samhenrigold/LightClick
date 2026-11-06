import Foundation
import InstallerKit

/// What a status pass should do, given only what the session is already doing.
@objc(VIMGuestRefreshStep)
public enum GuestRefreshStep: Int, Sendable {
    /// Start nothing: a pass or setup is under way, or the guest has stopped or is stopping.
    case busy
    /// A guest command holds the agent. Look again later so the readiness loop survives it.
    case retryAfterCommand
    /// Native Tiger installs before its separate graphics payload is qualified, so nothing is checked or completed.
    case nativeTigerInstallation
    case setupPaused
    case openGLSetup
    case statusToolMissing
    case collectStatus
}

/// A running session's flags, as read when a decision is needed. Earlier steps of a status pass change these, so each
/// decision takes a fresh copy.
public struct GuestSessionState: Sendable {
    public var guest: Guest?
    public var running = false
    public var lifecycle = SessionLifecycle()
    public var developmentSetupDeferred = false

    public var preparing = false
    public var preparationRequested = false
    public var installationRequested = false
    /// What QEMU last said its state was.
    public var runState: String?
    public var repairRequested = false
    public var explicitRepair = false
    public var verifiedUpdateRepair = false
    /// A repair check or archive failed and told the user no repair was started. An explicit repair still may.
    public var updateRepairHeld = false
    /// The modern setup failures already shown to the user since the guest last started.
    public var presentedSetupFailures: Set<String> = []

    /// QEMU has answered on its control connection since it started.
    public var controlConnected = false

    public var guestPending = false
    public var diagnosticPending = false
    public var clipboardPending = false
    public var bootPolicyPending = false
    public var displayModePending = false

    public var hasStatusTool = false
    public var hasModernSetup = false
    public var modernSetupReportActive = false
    public var openGLDesktopMonitoring = false
    public var passthroughOpenGLEnabled = false
    public var legacyTabletGuest = false
    public var legacyTabletObserved = false

    public var networkLinkConnected = false
    public var hasGuestAddresses = false
    public var consoleUID: NSNumber?

    public var displayPolicyRestartRequired = false
    public var displaySelectionRetryAfter: Date?

    // The boot each once-per-boot step last ran for.
    public var bootPolicyCheckedBoot: String?
    public var displaySizedBoot: String?
    public var displaySelectedBoot: String?
    public var usernameBoot: String?
    public var reconciledBoot: String?
    public var reconciliationAttempts = 0

    public init() {}

    public var shutdownRequested: Bool { lifecycle.shutdownRequested }
    public var relaunchForGraphics: Bool { lifecycle.handingOff }

    public var mayHandOff: Bool { running && lifecycle.acceptsHandoff }
    public var mayRequestShutdown: Bool { running && !shutdownRequested && !preparing }
    /// The app is quitting, and a session that's mid-setup or mid-handoff gets to finish.
    public var mayShutDownForQuit: Bool { running && !preparing && !relaunchForGraphics }
    public var mayForceReset: Bool { running && !lifecycle.resetRequested }
    public var mayStartGraphicsAction: Bool { running && !preparing && !preparationRequested && !relaunchForGraphics }
    public var graphicsActionsEnabled: Bool { mayStartGraphicsAction && !guestPending }

    /// How long a new emulator gets to answer before the window says so. A cold start under load can take a while, so this
    /// only says what's known, and nothing stops the emulator.
    public static let controlStallSeconds: TimeInterval = 60
    public static let controlStallNotice =
        "This Mac’s emulator has started but isn’t responding yet. It may still finish starting, and this message will "
        + "go away if it does. If it stays here, use Controls → Force Stop, then start it again."

    /// The emulator is running, and has yet to answer.
    public var controlStalled: Bool { running && !controlConnected }

    /// A one-off user action in the guest, such as turning on Remote Login, may start. The guest may still be asleep.
    public var mayRunGuestAction: Bool {
        running && !preparing && !preparationRequested && !guestPending && !diagnosticPending
    }

    /// Nothing else has the agent or needs it, and the guest can answer it.
    public var guestAgentFree: Bool {
        mayRunGuestAction && !clipboardPending && !bootPolicyPending && runState != "paused"
            && runState != "suspended"
    }

    /// The clipboard and display-power helpers may be set up in the guest. They wait for setup and for the agent, but not
    /// for a guest that's merely asleep.
    public var mayProvisionHelpers: Bool {
        mayRunGuestAction && !installationRequested && !clipboardPending && !bootPolicyPending
    }

    /// Whether a menu action is available, going by the session alone, or nil if it depends on the item or anything else.
    /// `controlReady` means the control connection has answered.
    public func enablesMenuAction(_ action: String, controlReady: Bool) -> Bool? {
        switch action {
        case "startAgain:": !running
        case "resetMachine:": mayForceReset
        case "sendForceQuitKey:", "takeScreenshot:", "sendMenuShortcut:": running && !preparing
        case "undo:", "cut:", "copy:", "paste:", "selectAll:", "forceStop:": running
        case "shutdown:": mayRequestShutdown && controlReady
        case "toggleUSBDevice:": running && controlReady
        case "toggleScreenSharing:": guestAgentFree
        default: nil
        }
    }

    /// Whether the host should stay awake for this session: it's installing something and isn't halted.
    public func keepsHostAwake(hasInstallerMedia: Bool, installState: String?, hasCompletionReport: Bool) -> Bool {
        let settingUp = hasInstallerMedia || installState == "patching" || installState == "host-populated"
        return running && !SessionRunState.isHalted(runState)
            && (preparing || preparationRequested || installationRequested || (settingUp && !hasCompletionReport))
    }

    public var nextRefreshStep: GuestRefreshStep {
        if guestPending || preparing || shutdownRequested || !running { return .busy }
        if diagnosticPending || clipboardPending || bootPolicyPending { return .retryAfterCommand }
        if guest?.traits.contains(.openGLDesktop) == true && !openGLDesktopMonitoring {
            if guest == .tiger && !passthroughOpenGLEnabled { return .nativeTigerInstallation }
            return developmentSetupDeferred ? .setupPaused : .openGLSetup
        }
        return hasStatusTool ? .collectStatus : .statusToolMissing
    }

    /// `pmset` arguments that keep the guest from sleeping, or nil when none are needed. Tiger lacks `disablesleep`, and
    /// its agent normally cancels idle sleep itself, so it only needs a fallback when that guard isn't registered.
    public func sleepPolicyArguments(nativeIdleGuard: Bool) -> [String]? {
        guard guest == .tiger else { return ["-a", "sleep", "0", "disablesleep", "1"] }
        return nativeIdleGuard ? nil : ["-a", "sleep", "0"]
    }

    /// Whether the saved display mode may be reasserted for this boot, which happens once after login. Published guest
    /// graphics are required too, and that part is the caller's, on disk.
    public func allowsDisplaySelection(boot: String?, now: Date) -> Bool {
        guard let boot, !boot.isEmpty, !GuestSessionState.isSame(boot, displaySelectedBoot) else { return false }
        if let displaySelectionRetryAfter, displaySelectionRetryAfter > now { return false }
        return !displayPolicyRestartRequired && consoleUID != nil && !preparing && !preparationRequested
            && !repairRequested && !guestPending && !clipboardPending && !bootPolicyPending && !displayModePending
            && !shutdownRequested
    }

    /// Whether a modern setup failure needs its alert. Setup retries on a timer, so only a failure not yet shown does.
    public func presentsSetupFailure(_ message: String) -> Bool {
        !presentedSetupFailures.contains(message)
    }

    /// `isEqual:`, not `==`: boots compare literally, and a missing boot matches nothing.
    static func isSame(_ boot: String, _ other: String?) -> Bool {
        other.map { (boot as NSString).isEqual(to: $0) } ?? false
    }
}
