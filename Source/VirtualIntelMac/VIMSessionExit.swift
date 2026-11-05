import Foundation

/// A session's flags and its emulator's exit, already read. Acting on the plan stays with the caller.
@objcMembers
public final class SessionExitInput: NSObject {
    public var relaunchForGuestReboot = false
    public var relaunchForGraphics = false
    public var forceResetRequested = false
    public var shutdownRequested = false
    public var closeAfterShutdown = false
    /// The emulator exited by itself; otherwise `terminationStatus` holds the signal that killed it.
    public var exited = false
    public var terminationStatus: Int32 = 0
    public var recentGuestReboots: [Date] = []
    public var now = Date()
}

/// What to do when the emulator has exited: relaunch it, or stay stopped and say why.
@objcMembers
public final class SessionExitPlan: NSObject {
    public let statusText: String
    public let stateText: String
    /// Still a reboot after loop detection, even if a failed exit prevents the relaunch.
    public let guestReboot: Bool
    public let rebootLoop: Bool
    public let relaunch: Bool
    public let showStoppedScreen: Bool
    public let closeWindow: Bool
    public let recentGuestReboots: [Date]

    public init(input: SessionExitInput) {
        let clean = input.exited && input.terminationStatus == 0
        let stopping = input.shutdownRequested || input.closeAfterShutdown
        var recent = input.recentGuestReboots.filter { input.now.timeIntervalSince($0) < 60 }
        var guestReboot = (input.relaunchForGuestReboot || input.forceResetRequested) && !stopping
        let rebootLoop = guestReboot && !input.forceResetRequested && recent.count >= 6
        if rebootLoop { guestReboot = false }
        if guestReboot { recent.append(input.now) }
        let graphicsRestart = input.relaunchForGraphics && !stopping
        let relaunch = (graphicsRestart || guestReboot) && (input.forceResetRequested || clean)

        statusText = "Stopped (exit \(input.terminationStatus))"
        stateText =
            input.terminationStatus == 0
            ? "This Mac is shut down."
            : "This Mac stopped unexpectedly. You can start it again or inspect Session Details."
        self.guestReboot = guestReboot
        self.rebootLoop = rebootLoop
        self.relaunch = relaunch
        showStoppedScreen = !relaunch && clean
        closeWindow = input.closeAfterShutdown && clean
        recentGuestReboots = recent
    }
}
