// A session from launch to exit, as a value. `applying` is the only way it changes, and a transition from the wrong
// phase leaves it as it was, since late callbacks are normal here: guest commands answer long after the user moved on.
//
//   launching -> booting <-> running
//                   |  \       |
//                   |   handoff (guest shuts down so a new emulator can change display hardware)
//                   v      |
//             shuttingDown -> stopped

import Foundation

/// How a session's emulator is being stopped.
public enum SessionShutdown: Sendable, Equatable {
    /// macOS was asked to shut down, and might not.
    case requested
    /// The emulator was told to terminate, and stays stopped.
    case forced
    /// The emulator was told to terminate so that a new one starts in its place.
    case reset
}

public enum SessionPhase: Sendable, Equatable, CustomStringConvertible {
    case stopped
    case launching
    case booting
    case running
    case handoff
    case shuttingDown(SessionShutdown)

    public var description: String {
        switch self {
        case .stopped: "stopped"
        case .launching: "launching"
        case .booting: "booting"
        case .running: "running"
        case .handoff: "handoff"
        case .shuttingDown(let how): "shutting down (\(how))"
        }
    }
}

@objc(VIMSessionEvent)
public enum SessionEvent: Int, Sendable {
    case launchStarted
    case emulatorStarted
    case desktopReached
    case handoffRequested
    /// The guest refused to shut down, or didn't in time.
    case handoffCancelled
    case shutdownRequested
    /// The guest couldn't be asked. It may still be shutting down, but nothing here says so.
    case shutdownFailed
    case forceStopRequested
    case resetRequested
    case closeRequested
    /// The guest is restarting, which takes a new emulator.
    case guestRebootExpected
    case emulatorStopped
}

public struct SessionLifecycle: Sendable, Equatable {
    public var phase = SessionPhase.stopped
    /// Separate from `phase` because it outlives a cancelled handoff or a failed shutdown request.
    public var guestRebootPending = false
    /// Separate from `phase` because it's asked for even while `shutdown:` refuses, and outlives a failed request.
    public var closesWindowWhenStopped = false

    public init() {}

    /// Stopped for good, as far as this emulator goes: a relaunch can't override these.
    private var isStopping: Bool {
        switch phase {
        case .shuttingDown(.requested), .shuttingDown(.forced): true
        default: closesWindowWhenStopped
        }
    }

    public var shutdownRequested: Bool {
        switch phase {
        case .shuttingDown(.requested), .shuttingDown(.forced): true
        default: false
        }
    }

    public var resetRequested: Bool { phase == .shuttingDown(.reset) }
    public var handingOff: Bool { phase == .handoff }

    /// A late installation or status callback must not override a shutdown, a close or a reset, or revive a stopped
    /// emulator. Handing off again while one is under way is allowed.
    public var acceptsHandoff: Bool {
        guard !closesWindowWhenStopped else { return false }
        return switch phase {
        case .booting, .running, .handoff: true
        default: false
        }
    }

    public func applying(_ event: SessionEvent) -> SessionLifecycle {
        var next = self
        switch event {
        case .launchStarted:
            next = SessionLifecycle()
            next.phase = .launching
        case .emulatorStarted:
            if phase == .launching { next.phase = .booting }
        case .desktopReached:
            if phase == .booting { next.phase = .running }
        case .handoffRequested:
            if acceptsHandoff { next.phase = .handoff }
        case .handoffCancelled:
            // The next status report says whether the desktop is still there.
            if phase == .handoff { next.phase = .booting }
        case .shutdownRequested:
            if phase != .stopped && !shutdownRequested { next.phase = .shuttingDown(.requested) }
        case .shutdownFailed:
            if phase == .shuttingDown(.requested) { next.phase = .booting }
        case .forceStopRequested:
            if phase != .stopped {
                next.phase = .shuttingDown(.forced)
                next.guestRebootPending = false
            }
        case .resetRequested:
            if phase != .stopped {
                next.phase = .shuttingDown(.reset)
                next.closesWindowWhenStopped = false
            }
        case .closeRequested:
            if phase != .stopped { next.closesWindowWhenStopped = true }
        case .guestRebootExpected:
            if phase != .stopped && !isStopping { next.guestRebootPending = true }
        case .emulatorStopped:
            next = SessionLifecycle()
        }
        return next
    }

    /// What to do now that the emulator has exited. `exited` is false when `terminationStatus` holds the signal that
    /// killed it.
    public func exitPlan(
        exited: Bool, terminationStatus: Int32, recentGuestReboots: [Date], now: Date = Date()
    ) -> SessionExitPlan {
        let clean = exited && terminationStatus == 0
        var recent = recentGuestReboots.filter { now.timeIntervalSince($0) < 60 }
        var guestReboot = (guestRebootPending || resetRequested) && !isStopping
        let rebootLoop = guestReboot && !resetRequested && recent.count >= 6
        if rebootLoop { guestReboot = false }
        if guestReboot { recent.append(now) }
        let relaunch = ((handingOff && !isStopping) || guestReboot) && (resetRequested || clean)
        return SessionExitPlan(
            statusText: "Stopped (exit \(terminationStatus))",
            stateText: terminationStatus == 0
                ? "This Mac is shut down."
                : "This Mac stopped unexpectedly. You can start it again or inspect Session Details.",
            guestReboot: guestReboot,
            rebootLoop: rebootLoop,
            relaunch: relaunch,
            showStoppedScreen: !relaunch && clean,
            closeWindow: closesWindowWhenStopped && clean,
            recentGuestReboots: recent
        )
    }
}

/// What to do when the emulator has exited: relaunch it, or stay stopped and say why.
@objcMembers
public final class SessionExitPlan: NSObject, Sendable {
    public let statusText: String
    public let stateText: String
    /// Still a reboot after loop detection, even if a failed exit prevents the relaunch.
    public let guestReboot: Bool
    public let rebootLoop: Bool
    public let relaunch: Bool
    public let showStoppedScreen: Bool
    public let closeWindow: Bool
    public let recentGuestReboots: [Date]

    init(
        statusText: String, stateText: String, guestReboot: Bool, rebootLoop: Bool, relaunch: Bool,
        showStoppedScreen: Bool, closeWindow: Bool, recentGuestReboots: [Date]
    ) {
        self.statusText = statusText
        self.stateText = stateText
        self.guestReboot = guestReboot
        self.rebootLoop = rebootLoop
        self.relaunch = relaunch
        self.showStoppedScreen = showStoppedScreen
        self.closeWindow = closeWindow
        self.recentGuestReboots = recentGuestReboots
    }
}

/// What QEMU's `query-status` answer means for the window. An unknown state is shown by name and counts as nothing else.
@objc(VIMSessionRunState)
public final class SessionRunState: NSObject {
    @objc(labelFor:)
    public class func label(for state: String) -> String {
        switch state {
        case "running": "Running"
        case "paused": "Paused"
        case "io-error": "Paused: a disk operation failed"
        case "guest-panicked": "The guest reported a kernel panic"
        case "internal-error": "Stopped: an internal emulator error"
        case "shutdown": "Guest shut down"
        case "suspended": "Sleeping"
        case "prelaunch": "Starting…"
        case "watchdog": "Paused: guest watchdog expired"
        default: "Guest state: \(state)"
        }
    }

    /// The guest can't go on, and the window says so.
    @objc(isFailure:)
    public class func isFailure(_ state: String?) -> Bool {
        ["io-error", "guest-panicked", "internal-error", "watchdog"].contains(state)
    }

    @objc(isDisplayAsleep:)
    public class func isDisplayAsleep(_ state: String?) -> Bool {
        ["suspended", "shutdown"].contains(state)
    }

    /// The guest isn't running, so nothing in it needs the host kept awake.
    @objc(isHalted:)
    public class func isHalted(_ state: String?) -> Bool {
        isFailure(state) || isDisplayAsleep(state) || state == "paused"
    }
}
