import Foundation

// Expected values were derived by reading the terminationHandler in VIMSession.m
// as it was before its decision moved to VIMSessionExit.swift, not by running it.
struct Case {
    let name: String
    var reboot = false
    var graphics = false
    var forced = false
    var shutdown = false
    var close = false
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
}

let six: [Double] = [1, 10, 20, 30, 40, 50]
let cases = [
    Case(name: "clean shutdown", stopped: true),
    Case(name: "crash", status: 1),
    Case(name: "killed by signal", exited: false, status: 9),
    Case(name: "not exited, status 0", exited: false),
    Case(name: "stale reboots are forgotten", ages: [60, 61, 59.5], stopped: true, recent: [59.5]),
    Case(name: "future reboot date is kept", ages: [-5], stopped: true, recent: [-5]),

    Case(name: "guest reboot", reboot: true, guestReboot: true, relaunch: true, recent: [0]),
    Case(name: "guest reboot, failed exit still counts", reboot: true, status: 1, guestReboot: true, recent: [0]),
    Case(name: "guest reboot, killed", reboot: true, exited: false, status: 9, guestReboot: true, recent: [0]),
    Case(name: "guest reboot, shutdown wins", reboot: true, shutdown: true, stopped: true),
    Case(name: "guest reboot, close wins", reboot: true, close: true, stopped: true, closes: true),

    Case(name: "graphics restart", graphics: true, relaunch: true),
    Case(name: "graphics restart, failed exit", graphics: true, status: 1),
    Case(name: "graphics restart, shutdown wins", graphics: true, shutdown: true, stopped: true),
    Case(name: "graphics restart, close wins", graphics: true, close: true, stopped: true, closes: true),

    Case(name: "close after clean shutdown", shutdown: true, close: true, stopped: true, closes: true),
    Case(name: "close after failed exit", close: true, status: 1),
    Case(name: "close after kill", close: true, exited: false, status: 9),

    Case(name: "forced reset", forced: true, guestReboot: true, relaunch: true, recent: [0]),
    Case(
        name: "forced reset, killed", forced: true, exited: false, status: 9, guestReboot: true, relaunch: true,
        recent: [0]),
    Case(name: "forced reset, failed exit", forced: true, status: 1, guestReboot: true, relaunch: true, recent: [0]),
    Case(name: "forced reset, shutdown wins", forced: true, shutdown: true, exited: false, status: 9),
    Case(name: "forced reset, close wins", forced: true, close: true, stopped: true, closes: true),
    Case(
        name: "forced reset ignores the loop limit", forced: true, ages: six, guestReboot: true, relaunch: true,
        recent: six + [0]),

    Case(
        name: "5 recent reboots still relaunch", reboot: true, ages: [10, 20, 30, 40, 50], guestReboot: true,
        relaunch: true, recent: [10, 20, 30, 40, 50, 0]),
    Case(name: "6 recent reboots are a loop", reboot: true, ages: six, loop: true, stopped: true, recent: six),
    Case(name: "loop after failed exit", reboot: true, status: 1, ages: six, loop: true, recent: six),
    Case(
        name: "loop and graphics restart both apply", reboot: true, graphics: true, ages: six, loop: true,
        relaunch: true, recent: six),
    Case(
        name: "a reboot exactly 60s old leaves the window", reboot: true, ages: [10, 20, 30, 40, 50, 60],
        guestReboot: true, relaunch: true, recent: [10, 20, 30, 40, 50, 0]),
    Case(name: "6 recent reboots, shutdown wins", reboot: true, shutdown: true, ages: six, stopped: true, recent: six)
]

let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
var failures = 0
for c in cases {
    let input = SessionExitInput()
    input.relaunchForGuestReboot = c.reboot
    input.relaunchForGraphics = c.graphics
    input.forceResetRequested = c.forced
    input.shutdownRequested = c.shutdown
    input.closeAfterShutdown = c.close
    input.exited = c.exited
    input.terminationStatus = c.status
    input.recentGuestReboots = c.ages.map { now.addingTimeInterval(-$0) }
    input.now = now
    let plan = SessionExitPlan(input: input)
    let got = """
        guestReboot=\(plan.guestReboot) loop=\(plan.rebootLoop) relaunch=\(plan.relaunch) \
        stopped=\(plan.showStoppedScreen) closes=\(plan.closeWindow) \
        recent=\(plan.recentGuestReboots.map { now.timeIntervalSince($0) }) \
        status=\(plan.statusText) state=\(plan.stateText)
        """
    let state =
        c.status == 0
        ? "This Mac is shut down."
        : "This Mac stopped unexpectedly. You can start it again or inspect Session Details."
    let want = """
        guestReboot=\(c.guestReboot) loop=\(c.loop) relaunch=\(c.relaunch) \
        stopped=\(c.stopped) closes=\(c.closes) \
        recent=\(c.recent) \
        status=Stopped (exit \(c.status)) state=\(state)
        """
    if got != want {
        print("FAIL \(c.name)\n  got  \(got)\n  want \(want)")
        failures += 1
    }
}
if failures > 0 {
    print("FAIL \(failures) of \(cases.count) cases")
    exit(1)
}
print("PASS \(cases.count) cases")
