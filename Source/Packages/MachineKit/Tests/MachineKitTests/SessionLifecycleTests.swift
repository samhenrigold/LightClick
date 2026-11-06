import Foundation
import Testing

@testable import MachineKit

private func lifecycle(_ events: SessionEvent...) -> SessionLifecycle {
    events.reduce(SessionLifecycle()) { $0.applying($1) }
}

private let booted: [SessionEvent] = [.launchStarted, .emulatorStarted]

private func after(_ events: SessionEvent...) -> SessionLifecycle {
    (booted + events).reduce(SessionLifecycle()) { $0.applying($1) }
}

@Suite struct SessionLifecycleTests {
    @Test func aLaunchReachesTheDesktop() {
        #expect(lifecycle(.launchStarted).phase == .launching)
        #expect(after().phase == .booting)
        #expect(after(.desktopReached).phase == .running)
    }

    @Test func aDesktopNeedsAStartedEmulator() {
        #expect(lifecycle(.desktopReached).phase == .stopped)
        #expect(lifecycle(.launchStarted, .desktopReached).phase == .launching)
    }

    @Test func aHandoffBeginsFromBootOrDesktop() {
        #expect(after(.handoffRequested).phase == .handoff)
        #expect(after(.desktopReached, .handoffRequested).phase == .handoff)
        #expect(after(.handoffRequested, .handoffRequested).phase == .handoff)
    }

    @Test(arguments: [
        SessionEvent.shutdownRequested, .forceStopRequested, .resetRequested, .closeRequested, .emulatorStopped
    ])
    func aHandoffCannotOverride(_ event: SessionEvent) {
        let state = after(event)
        #expect(!state.acceptsHandoff)
        #expect(state.applying(.handoffRequested) == state)
    }

    @Test func aHandoffCannotStartBeforeTheEmulator() {
        #expect(lifecycle(.launchStarted, .handoffRequested).phase == .launching)
    }

    @Test func aCancelledHandoffWaitsForTheNextReport() {
        #expect(after(.desktopReached, .handoffRequested, .handoffCancelled).phase == .booting)
        #expect(after(.desktopReached, .handoffRequested, .handoffCancelled, .desktopReached).phase == .running)
    }

    @Test func aStaleHandoffTimeoutChangesNothing() {
        #expect(after(.desktopReached, .handoffCancelled).phase == .running)
        #expect(after(.shutdownRequested, .handoffCancelled).phase == .shuttingDown(.requested))
    }

    @Test func aShutdownEndsAHandoffAndAReset() {
        #expect(after(.handoffRequested, .shutdownRequested).phase == .shuttingDown(.requested))
        #expect(after(.resetRequested, .shutdownRequested).phase == .shuttingDown(.requested))
    }

    @Test func aForceStopIsNotDowngradedByAShutdownRequest() {
        #expect(after(.forceStopRequested, .shutdownRequested).phase == .shuttingDown(.forced))
    }

    @Test func aFailedShutdownRequestResumes() {
        #expect(after(.desktopReached, .shutdownRequested, .shutdownFailed).phase == .booting)
    }

    @Test func aFailedShutdownRequestDoesNotUndoAStop() {
        #expect(after(.forceStopRequested, .shutdownFailed).phase == .shuttingDown(.forced))
        #expect(after(.resetRequested, .shutdownFailed).phase == .shuttingDown(.reset))
    }

    @Test func aFailedShutdownKeepsAClose() {
        #expect(after(.closeRequested, .shutdownRequested, .shutdownFailed).closesWindowWhenStopped)
    }

    @Test func aResetDropsAClose() {
        #expect(!after(.closeRequested, .resetRequested).closesWindowWhenStopped)
    }

    @Test func aForceStopDropsAPendingReboot() {
        #expect(!after(.guestRebootExpected, .forceStopRequested).guestRebootPending)
    }

    @Test func aRebootPendingSurvivesACancelledHandoff() {
        #expect(after(.guestRebootExpected, .handoffRequested, .handoffCancelled).guestRebootPending)
    }

    @Test(arguments: [SessionEvent.shutdownRequested, .forceStopRequested, .closeRequested])
    func aRebootIsNotExpectedWhileStopping(_ event: SessionEvent) {
        #expect(!after(event, .guestRebootExpected).guestRebootPending)
    }

    @Test func aRebootIsExpectedDuringAReset() {
        #expect(after(.resetRequested, .guestRebootExpected).guestRebootPending)
    }

    @Test func aStoppedSessionIgnoresEverythingButALaunch() {
        let events: [SessionEvent] = [
            .emulatorStarted, .desktopReached, .handoffRequested, .handoffCancelled, .shutdownRequested,
            .shutdownFailed, .forceStopRequested, .resetRequested, .closeRequested, .guestRebootExpected,
            .emulatorStopped
        ]
        for event in events { #expect(SessionLifecycle().applying(event) == SessionLifecycle()) }
    }

    @Test func stoppingForgetsEverything() {
        #expect(after(.guestRebootExpected, .closeRequested, .emulatorStopped) == SessionLifecycle())
    }

    @Test func aLaunchStartsClean() {
        let state = after(.guestRebootExpected, .closeRequested, .shutdownRequested, .launchStarted)
        #expect(state == lifecycle(.launchStarted))
    }
}

@Suite struct SessionDecisionTests {
    private func state(_ change: (inout GuestSessionState) -> Void = { _ in }) -> GuestSessionState {
        var state = GuestSessionState()
        state.running = true
        state.lifecycle = after(.desktopReached)
        change(&state)
        return state
    }

    @Test func nothingIsAllowedOnceStopped() {
        let stopped = state { $0.running = false }
        #expect(!stopped.mayHandOff)
        #expect(!stopped.mayRequestShutdown)
        #expect(!stopped.mayShutDownForQuit)
        #expect(!stopped.mayForceReset)
        #expect(!stopped.mayStartGraphicsAction)
        #expect(!stopped.graphicsActionsEnabled)
    }

    @Test func aRunningSessionAllowsEverything() {
        let running = state()
        #expect(running.mayHandOff)
        #expect(running.mayRequestShutdown)
        #expect(running.mayShutDownForQuit)
        #expect(running.mayForceReset)
        #expect(running.mayStartGraphicsAction)
        #expect(running.graphicsActionsEnabled)
    }

    @Test func preparingHoldsShutdownButNotAHandoff() {
        let preparing = state { $0.preparing = true }
        #expect(!preparing.mayRequestShutdown)
        #expect(!preparing.mayShutDownForQuit)
        #expect(preparing.mayHandOff)
        #expect(preparing.mayForceReset)
    }

    @Test func aHandoffHoldsQuitButNotAnExplicitShutdown() {
        let handingOff = state { $0.lifecycle = after(.handoffRequested) }
        #expect(!handingOff.mayShutDownForQuit)
        #expect(!handingOff.mayStartGraphicsAction)
        #expect(handingOff.mayRequestShutdown)
    }

    @Test func aRequestedShutdownIsNotRepeated() {
        #expect(!state { $0.lifecycle = after(.shutdownRequested) }.mayRequestShutdown)
        #expect(!state { $0.lifecycle = after(.forceStopRequested) }.mayRequestShutdown)
        #expect(state { $0.lifecycle = after(.resetRequested) }.mayRequestShutdown)
    }

    @Test func aResetIsNotRepeated() {
        #expect(!state { $0.lifecycle = after(.resetRequested) }.mayForceReset)
        #expect(state { $0.lifecycle = after(.shutdownRequested) }.mayForceReset)
    }

    @Test func aPendingGuestCommandOnlyDisablesTheMenu() {
        let pending = state { $0.guestPending = true }
        #expect(pending.mayStartGraphicsAction)
        #expect(!pending.graphicsActionsEnabled)
    }

    @Test func aPendingPreparationHoldsGraphicsActions() {
        #expect(!state { $0.preparationRequested = true }.mayStartGraphicsAction)
    }
}

/// Expected values were derived by reading the terminationHandler in VIMSession.m as it was before its decision moved
/// out of it, not by running it.
struct ExitCase: CustomTestStringConvertible, Sendable {
    let name: String
    var events: [SessionEvent] = []
    var exited = true
    var status: Int32 = 0
    /// Seconds before now.
    var ages: [Double] = []

    var guestReboot = false
    var loop = false
    var relaunch = false
    var stopped = false
    var closes = false
    var recent: [Double] = []

    var testDescription: String { name }
}

private let six: [Double] = [1, 10, 20, 30, 40, 50]

private let exitCases = [
    ExitCase(name: "clean shutdown", stopped: true),
    ExitCase(name: "crash", status: 1),
    ExitCase(name: "killed by signal", exited: false, status: 9),
    ExitCase(name: "not exited, status 0", exited: false),
    ExitCase(name: "stale reboots are forgotten", ages: [60, 61, 59.5], stopped: true, recent: [59.5]),
    ExitCase(name: "future reboot date is kept", ages: [-5], stopped: true, recent: [-5]),

    ExitCase(name: "guest reboot", events: [.guestRebootExpected], guestReboot: true, relaunch: true, recent: [0]),
    ExitCase(
        name: "guest reboot, failed exit still counts", events: [.guestRebootExpected], status: 1, guestReboot: true,
        recent: [0]),
    ExitCase(
        name: "guest reboot, killed", events: [.guestRebootExpected], exited: false, status: 9, guestReboot: true,
        recent: [0]),
    ExitCase(name: "guest reboot, shutdown wins", events: [.guestRebootExpected, .shutdownRequested], stopped: true),
    ExitCase(
        name: "guest reboot, close wins", events: [.guestRebootExpected, .closeRequested], stopped: true, closes: true),

    ExitCase(name: "graphics restart", events: [.handoffRequested], relaunch: true),
    ExitCase(name: "graphics restart, failed exit", events: [.handoffRequested], status: 1),
    ExitCase(name: "graphics restart, shutdown wins", events: [.handoffRequested, .shutdownRequested], stopped: true),
    ExitCase(
        name: "graphics restart, close wins", events: [.handoffRequested, .closeRequested], stopped: true, closes: true),
    ExitCase(name: "cancelled graphics restart", events: [.handoffRequested, .handoffCancelled], stopped: true),

    ExitCase(
        name: "close after clean shutdown", events: [.closeRequested, .shutdownRequested], stopped: true, closes: true),
    ExitCase(name: "close after failed exit", events: [.closeRequested], status: 1),
    ExitCase(name: "close after kill", events: [.closeRequested], exited: false, status: 9),

    ExitCase(name: "forced reset", events: [.resetRequested], guestReboot: true, relaunch: true, recent: [0]),
    ExitCase(
        name: "forced reset, killed", events: [.resetRequested], exited: false, status: 9, guestReboot: true,
        relaunch: true, recent: [0]),
    ExitCase(
        name: "forced reset, failed exit", events: [.resetRequested], status: 1, guestReboot: true, relaunch: true,
        recent: [0]),
    ExitCase(
        name: "forced reset, shutdown wins", events: [.resetRequested, .shutdownRequested], exited: false, status: 9),
    ExitCase(name: "forced reset, close wins", events: [.resetRequested, .closeRequested], stopped: true, closes: true),
    ExitCase(
        name: "forced reset ignores the loop limit", events: [.resetRequested], ages: six, guestReboot: true,
        relaunch: true, recent: six + [0]),
    ExitCase(name: "force stop", events: [.forceStopRequested], exited: false, status: 15),
    ExitCase(
        name: "force stop over a reset", events: [.resetRequested, .forceStopRequested], exited: false, status: 15),

    ExitCase(
        name: "5 recent reboots still relaunch", events: [.guestRebootExpected], ages: [10, 20, 30, 40, 50],
        guestReboot: true, relaunch: true, recent: [10, 20, 30, 40, 50, 0]),
    ExitCase(
        name: "6 recent reboots are a loop", events: [.guestRebootExpected], ages: six, loop: true, stopped: true,
        recent: six),
    ExitCase(
        name: "loop after failed exit", events: [.guestRebootExpected], status: 1, ages: six, loop: true, recent: six),
    ExitCase(
        name: "loop and graphics restart both apply", events: [.guestRebootExpected, .handoffRequested], ages: six,
        loop: true, relaunch: true, recent: six),
    ExitCase(
        name: "a reboot exactly 60s old leaves the window", events: [.guestRebootExpected],
        ages: [10, 20, 30, 40, 50, 60], guestReboot: true, relaunch: true, recent: [10, 20, 30, 40, 50, 0]),
    ExitCase(
        name: "6 recent reboots, shutdown wins", events: [.guestRebootExpected, .shutdownRequested], ages: six,
        stopped: true, recent: six)
]

@Suite struct SessionExitPlanTests {
    @Test(arguments: exitCases)
    func plan(_ c: ExitCase) {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let plan = (booted + c.events).reduce(SessionLifecycle()) { $0.applying($1) }.exitPlan(
            exited: c.exited, terminationStatus: c.status,
            recentGuestReboots: c.ages.map { now.addingTimeInterval(-$0) },
            now: now)
        #expect(plan.guestReboot == c.guestReboot)
        #expect(plan.rebootLoop == c.loop)
        #expect(plan.relaunch == c.relaunch)
        #expect(plan.showStoppedScreen == c.stopped)
        #expect(plan.closeWindow == c.closes)
        #expect(plan.recentGuestReboots.map { now.timeIntervalSince($0) } == c.recent)
        #expect(plan.statusText == "Stopped (exit \(c.status))")
        #expect(
            plan.stateText
                == (c.status == 0
                    ? "This Mac is shut down."
                    : "This Mac stopped unexpectedly. You can start it again or inspect Session Details."))
    }
}
