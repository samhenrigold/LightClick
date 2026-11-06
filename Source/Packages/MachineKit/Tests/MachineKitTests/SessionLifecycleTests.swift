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

@Suite struct OpenGLSetupOutcomeTests {
    @Test(arguments: [
        ("credential-required", OpenGLSetupStep.askForPassword),
        ("unmanaged", .monitorDesktop),
        ("unsupported", .monitorDesktop),
        ("setup-unavailable", .monitorDesktop),
        ("recovery", .installerRunning),
        ("needs-restart", .restart),
        ("complete", .finish),
        ("booting", .waitAndAskAgain),
        ("audio-busy", .waitAndAskAgain),
        ("payload-media-wait", .waitAndAskAgain),
        ("anything new", .waitAndAskAgain)
    ])
    func stepForPhase(_ phase: String, _ step: OpenGLSetupStep) {
        #expect(OpenGLSetupOutcome(phase: phase).step == step)
    }

    @Test func noPhaseKeepsWaiting() {
        #expect(OpenGLSetupOutcome(phase: nil).step == .waitAndAskAgain)
        #expect(OpenGLSetupOutcome(phase: nil).waitingMessage(osName: "Snow") == "Starting Snow…")
    }

    @Test func onlySetupUnavailableIsLogged() {
        #expect(OpenGLSetupOutcome(phase: "setup-unavailable").leftSystemUnchanged)
        #expect(!OpenGLSetupOutcome(phase: "unmanaged").leftSystemUnchanged)
    }

    @Test(arguments: [
        ("recovery", "Installing Snow…"),
        ("payload-media-wait", "Waiting for the graphics update disc…"),
        ("root-volume-wait", "Waiting for this Mac’s startup disk…"),
        ("desktop-wait", "Waiting for this Mac’s desktop…"),
        ("desktop-services-wait", "Finishing File Sharing setup…"),
        ("file-sharing-busy", "Finishing File Sharing setup…"),
        ("update-restart-wait", "Restart this Mac when its system update finishes…"),
        ("account-busy", "Creating your Mac account…"),
        ("restarting", "Restarting to finish setup…"),
        ("booting", "Starting Snow…"),
        ("audio-busy", "Starting Snow…")
    ])
    func waitingMessage(_ phase: String, _ message: String) {
        #expect(OpenGLSetupOutcome(phase: phase).waitingMessage(osName: "Snow") == message)
    }

    @Test func aRestartAsksUnlessSomeoneCantAnswer() {
        let asked = OpenGLSetupOutcome(phase: "needs-restart")
        #expect(!asked.restartsWithoutAsking(creatingGuest: false))
        #expect(asked.restartsWithoutAsking(creatingGuest: true))
        #expect(OpenGLSetupOutcome(phase: "needs-restart", automatic: true).restartsWithoutAsking(creatingGuest: false))
    }

    @Test func anUpdateAndAFirstSetupDifferInWhatFollows() {
        let first = OpenGLSetupOutcome(phase: "needs-restart")
        let update = OpenGLSetupOutcome(phase: "needs-restart", existingGuestUpdate: true)
        #expect(first.showsRestartNotice && !first.monitorsDesktopIfDeclined)
        #expect(!update.showsRestartNotice && update.monitorsDesktopIfDeclined)
        #expect(first.restartPromptTitle == "Restart to finish graphics setup?")
        #expect(update.restartPromptTitle == "Restart to use updated graphics support?")
    }

    @Test func theBridgeReadsTheCoordinatorsDictionaryAndRefusesWrongTypes() {
        let bridged = OpenGLSetupOutcomeBridge(
            outcome: ["Phase": "needs-restart", "Automatic": true, "ExistingGuestUpdate": true] as NSDictionary)
        #expect(bridged.step == .restart)
        #expect(bridged.automatic)
        #expect(bridged.monitorsDesktopIfDeclined)
        #expect(OpenGLSetupOutcomeBridge(outcome: nil).step == .waitAndAskAgain)
        let wrong = OpenGLSetupOutcomeBridge(outcome: ["Phase": 1, "Automatic": "YES"] as NSDictionary)
        #expect(wrong.step == .waitAndAskAgain)
        #expect(!wrong.automatic)
    }
}

@Suite struct SessionRunStateTests {
    @Test func labels() {
        #expect(SessionRunState.label(for: "running") == "Running")
        #expect(SessionRunState.label(for: "watchdog") == "Paused: guest watchdog expired")
        #expect(SessionRunState.label(for: "colo") == "Guest state: colo")
    }

    @Test(arguments: ["paused", "suspended", "shutdown", "io-error", "guest-panicked", "internal-error", "watchdog"])
    func halted(_ state: String) {
        #expect(SessionRunState.isHalted(state))
    }

    @Test func aRunningOrUnknownGuestIsNotHalted() {
        #expect(!SessionRunState.isHalted("running"))
        #expect(!SessionRunState.isHalted("prelaunch"))
        #expect(!SessionRunState.isHalted(nil))
        #expect(!SessionRunState.isFailure("paused"))
    }

    @Test func aSleepingOrStoppedGuestDarkensTheDisplay() {
        #expect(SessionRunState.isDisplayAsleep("suspended"))
        #expect(SessionRunState.isDisplayAsleep("shutdown"))
        #expect(!SessionRunState.isDisplayAsleep("paused"))
    }
}

@Suite struct InstallationFollowUpTests {
    private func followUp(
        desktop: Bool = true, verifiedRepair: Bool = false, running: Bool = true, phase: String? = "awaiting-reboot",
        rebootRequired: Bool = true, installerDisplay: Bool = false
    ) -> InstallationFollowUp {
        var session = GuestSessionState()
        session.running = running
        session.verifiedUpdateRepair = verifiedRepair
        let report = GuestReport(values: ["DesktopRunning": .init(foundationObject: desktop)])
        return GuestStatusPolicy(report: report, failed: false, session: session).followUpAfterInstallation(
            outcomePhase: phase, rebootRequired: rebootRequired, requiresInstallerDisplay: installerDisplay)
    }

    @Test func aCompletedInstallationOffersARestart() {
        #expect(followUp() == .offerRestart)
        #expect(followUp(desktop: false) == .offerRestart)
        #expect(followUp(verifiedRepair: true) == .offerRestart)
    }

    @Test func aHeadlessVerifiedRepairRestartsAlone() {
        #expect(followUp(desktop: false, verifiedRepair: true) == .handOff)
    }

    @Test func anythingElseKeepsPolling() {
        #expect(followUp(running: false) == .keepPolling)
        #expect(followUp(phase: nil) == .keepPolling)
        #expect(followUp(phase: "rolled-back") == .keepPolling)
        #expect(followUp(rebootRequired: false) == .keepPolling)
        #expect(followUp(installerDisplay: true) == .keepPolling)
    }
}

@Suite struct SessionAdmissionTests {
    private var idle: GuestSessionState {
        var state = GuestSessionState()
        state.running = true
        return state
    }

    private func with(_ change: (inout GuestSessionState) -> Void) -> GuestSessionState {
        var state = idle
        change(&state)
        return state
    }

    @Test func anIdleRunningGuestIsFree() {
        #expect(idle.guestAgentFree)
        #expect(idle.mayRunGuestAction)
        #expect(idle.mayProvisionHelpers)
        #expect(!GuestSessionState().mayRunGuestAction)
    }

    @Test func setupAndCommandsHoldEveryKindOfAction() {
        let holds: [(inout GuestSessionState) -> Void] = [
            { $0.preparing = true }, { $0.preparationRequested = true }, { $0.guestPending = true },
            { $0.diagnosticPending = true }
        ]
        for hold in holds {
            let state = with(hold)
            #expect(!state.mayRunGuestAction && !state.guestAgentFree && !state.mayProvisionHelpers)
        }
    }

    @Test func helperProvisioningOnlyHoldsTheAgentForOtherActions() {
        for hold in [with { $0.clipboardPending = true }, with { $0.bootPolicyPending = true }] {
            #expect(hold.mayRunGuestAction)
            #expect(!hold.guestAgentFree)
            #expect(!hold.mayProvisionHelpers)
        }
    }

    @Test func aPendingInstallationOnlyHoldsHelpers() {
        let state = with { $0.installationRequested = true }
        #expect(state.guestAgentFree)
        #expect(!state.mayProvisionHelpers)
    }

    @Test func anAsleepGuestHoldsOnlyWhatNeedsItAwake() {
        for run in ["paused", "suspended"] {
            let state = with { $0.runState = run }
            #expect(!state.guestAgentFree)
            #expect(state.mayRunGuestAction)
            #expect(state.mayProvisionHelpers)
        }
    }

    private func awake(_ state: GuestSessionState, media: Bool = false, install: String? = nil, report: Bool = false)
        -> Bool
    {
        state.keepsHostAwake(hasInstallerMedia: media, installState: install, hasCompletionReport: report)
    }

    @Test func setupKeepsTheHostAwakeUntilReported() {
        #expect(!awake(idle))
        #expect(awake(idle, media: true))
        #expect(awake(idle, install: "patching"))
        #expect(awake(idle, install: "host-populated"))
        #expect(!awake(idle, install: "installed"))
        #expect(!awake(idle, media: true, report: true))
        #expect(awake(with { $0.preparing = true }, report: true))
        #expect(awake(with { $0.preparationRequested = true }))
        #expect(awake(with { $0.installationRequested = true }))
    }

    @Test func aHaltedOrStoppedGuestDoesNot() {
        #expect(!awake(GuestSessionState(), media: true))
        for run in ["paused", "suspended", "shutdown", "io-error", "guest-panicked"] {
            #expect(
                !awake(
                    with {
                        $0.preparing = true
                        $0.runState = run
                    }, media: true))
        }
    }

    @Test func menuActionsFollowTheSession() {
        let stopped = GuestSessionState()
        #expect(stopped.enablesMenuAction("startAgain:", controlReady: false) == true)
        #expect(idle.enablesMenuAction("startAgain:", controlReady: true) == false)
        for action in ["paste:", "forceStop:", "resetMachine:", "sendMenuShortcut:", "takeScreenshot:"] {
            #expect(stopped.enablesMenuAction(action, controlReady: true) == false)
            #expect(idle.enablesMenuAction(action, controlReady: false) == true)
        }
        let preparing = with { $0.preparing = true }
        #expect(preparing.enablesMenuAction("paste:", controlReady: true) == true)
        #expect(preparing.enablesMenuAction("sendForceQuitKey:", controlReady: true) == false)
        #expect(preparing.enablesMenuAction("shutdown:", controlReady: true) == false)
        #expect(with { $0.runState = "paused" }.enablesMenuAction("toggleScreenSharing:", controlReady: true) == false)
    }

    @Test func someActionsWaitForTheControlConnection() {
        #expect(idle.enablesMenuAction("shutdown:", controlReady: true) == true)
        #expect(idle.enablesMenuAction("shutdown:", controlReady: false) == false)
        #expect(idle.enablesMenuAction("toggleUSBDevice:", controlReady: false) == false)
    }

    @Test func otherActionsAreNotTheSessionsToSay() {
        #expect(idle.enablesMenuAction("ejectOpticalMedia:", controlReady: true) == nil)
        #expect(idle.enablesMenuAction("about:", controlReady: true) == nil)
    }

    @Test func aMachinesStatusReadsItsState() {
        let status = SessionRunState.status
        #expect(status(false, nil, false) == "Shut down")
        #expect(status(false, "running", true) == "Installation in progress")
        #expect(status(true, "suspended", true) == "Sleeping")
        #expect(status(true, "paused", false) == "Paused")
        #expect(status(true, nil, true) == "Installing macOS")
        #expect(status(true, "running", false) == "Running")
    }
}
