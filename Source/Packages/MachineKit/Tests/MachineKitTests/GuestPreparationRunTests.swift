import Foundation
import Testing

@testable import MachineKit

private struct Lost: Error, LocalizedError {
    var errorDescription: String? { "The agent went away." }
}

private let staging = "/private/var/tmp/VirtualIntelMac.test"
private let payload = staging + "/Extracted/payload"
private let identity = UUID().uuidString

private let initialReport = GuestReport(values: [
    "Guest": "mojave", "InstalledSystemCandidate": true, "DesktopRunning": true, "LiveRoot": true,
    "KernelMatchesSystem": true, "ProductBuildVersion": "18G103", "VolumeUUID": "volume"
])

private func json(_ text: String) -> GuestCommandResult {
    GuestCommandResult(values: ["exitcode": 0, "stdout": .data(Data(text.utf8))])
}

private func plist(_ object: [String: Any]) -> GuestCommandResult {
    let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    return GuestCommandResult(values: ["exitcode": 0, "stdout": .data(data ?? Data())])
}

@MainActor
private final class FakeWindow: GuestSetupWindow {
    var setupReceipt: [String: PropertyListValue] = ["Directory": "/private/var/tmp/VirtualIntelMacUI.abc123"]
    var updates: [String] = []
    func update(mode: String, fraction: Double, message: String) { updates.append("\(mode) \(fraction)") }
}

@MainActor
private final class FakeEnvironment: GuestPreparationEnvironment {
    var answers: [String: GuestCommandResult] = [
        "stage-media": json(
            """
            {"Directory":"\(staging)","Archive":"payload.tar.xz","Files":[{"Name":"payload.tar.xz","Size":5}],\
            "FilesStaged":true,"MediaDevice":"/dev/disk2s1"}
            """),
        "unmount": GuestCommandResult(values: ["exitcode": 0]),
        "0700": GuestCommandResult(values: ["exitcode": 0]),
        "--check-environment": json(#"{"Eligible":true,"VolumeUUID":"volume","ProductBuildVersion":"18G103"}"#),
        "--extract": json(#"{"Extracted":true,"Installed":false,"PayloadDirectory":"\#(payload)"}"#),
        "/": json(#"{"Prepared":true,"Installed":false,"Guest":"mojave","ProductBuildVersion":"18G103"}"#),
        "--plan": json(
            #"{"Planned":true,"Installed":false,"Ready":false,"Guest":"mojave","TransactionID":"\#(identity)"}"#)
    ]
    var failing: Set<String> = []
    var events: [String] = []
    var ejects: [Bool] = []
    let window = FakeWindow()
    var status = initialReport
    var listsBeforeDisc = 0

    func run(_ path: String, arguments: [String], timeout: TimeInterval) async throws -> GuestCommandResult {
        // diskutil's own subcommands, and each guest tool's first argument, name the step.
        let step = arguments.first ?? path
        events.append(step)
        if failing.contains(step) { throw Lost() }
        if step == "list" {
            if listsBeforeDisc > 0 {
                listsBeforeDisc -= 1
                return plist(["AllDisksAndPartitions": [] as [Any]])
            }
            let disc: [String: Any] = ["VolumeName": "Virtual Intel Mac Support", "DeviceIdentifier": "disk2s1"]
            return plist(["AllDisksAndPartitions": [disc]])
        }
        if step == "info" { return plist(["VolumeName": "Virtual Intel Mac Support", "WritableMedia": false]) }
        if step == "mount" { return GuestCommandResult(values: ["exitcode": 0]) }
        return answers[step] ?? GuestCommandResult(values: ["exitcode": 1])
    }

    func insertSupportDisc(at url: URL) async throws {
        events.append("insert")
        if failing.contains("insert") { throw Lost() }
    }
    func ejectSupportDisc(force: Bool) async throws {
        events.append("eject")
        ejects.append(force)
        if failing.contains("eject") { throw Lost() }
    }
    func stageBootstrapTools(guest: String) async throws -> String {
        events.append("bootstrap")
        return staging
    }
    func openSetupWindow(staging directory: String) async throws -> any GuestSetupWindow {
        events.append("window")
        if failing.contains("window") { throw Lost() }
        return window
    }
    func collectStatus() async throws -> GuestReport {
        events.append("status")
        return status
    }
}

@MainActor
@Suite struct GuestPreparationRunTests {
    private struct Files {
        let runtime: URL
        var journal: URL { runtime.appendingPathComponent("State/GuestPreparation.plist") }
        var saved: [String: PropertyListValue]? { GuestInstallationTransaction.record(at: journal) }

        init(disc: Bool = true) throws {
            runtime = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let payloads = runtime.appendingPathComponent("GuestPayloads")
            try FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: true)
            if disc { try Data().write(to: payloads.appendingPathComponent("mojave.iso")) }
        }
    }

    private func run(
        _ environment: FakeEnvironment, _ files: Files, report: GuestReport = initialReport, headless: Bool = false
    ) async -> (receipt: [String: PropertyListValue]?, failure: (any Error)?, messages: [String]) {
        var messages: [String] = []
        let answer = await GuestPreparationRun(
            environment: environment, report: report, runtime: files.runtime, journal: files.journal,
            headlessRepair: headless, progress: { messages.append($0) }
        ).run()
        return (answer.receipt, answer.failure, messages)
    }

    private let fullRun = [
        "insert", "bootstrap", "window", "stage-media", "unmount", "eject", "0700", "--check-environment", "--extract",
        "/", "status", "--plan"
    ]

    @Test func aFullRunPlansAndInstallsNothing() async throws {
        let environment = FakeEnvironment()
        let files = try Files()
        let (receipt, failure, messages) = await run(environment, files)
        #expect(failure == nil)
        #expect(environment.events == fullRun)
        #expect(environment.ejects == [true], "The verified volume is gone, so the tray can be forced.")
        #expect(receipt?["Prepared"] == true && receipt?["Installed"] == false)
        #expect(receipt?["TransactionID"] == .string(identity))
        #expect(receipt?["PayloadDirectory"] == .string(payload))
        #expect(receipt?["TransactionJournal"] == .string(staging + "/InstallTransaction.plist"))
        #expect(receipt?["GuestProgress"]?.dictionary?["Directory"] != nil)
        #expect(files.saved?["Phase"] == "prepared")
        #expect(files.saved?["Installed"] == false)
        #expect(files.saved?["InstallationPlan"] != nil && files.saved?["Receipt"] != nil)
        #expect(messages.first == "Making guest setup files available…")
        #expect(environment.window.updates.first == "working 0.05")
        #expect(environment.window.updates.last == "working 0.46")
    }

    @Test func anUnsuitableReportTouchesNothing() async throws {
        let environment = FakeEnvironment()
        let files = try Files()
        let (_, failure, _) = await run(environment, files, report: GuestReport(values: ["Guest": "mojave"]))
        #expect(failure as? GuestPreparationError == .unsuitableSystem)
        #expect(environment.events.isEmpty)
        #expect(files.saved == nil)
    }

    @Test func aHeadlessRepairNeedsNoDesktopAndOpensNoWindow() async throws {
        let environment = FakeEnvironment()
        let files = try Files()
        var report = initialReport.values
        report["DesktopRunning"] = false
        let (receipt, failure, _) = await run(environment, files, report: GuestReport(values: report), headless: true)
        #expect(failure == nil)
        #expect(environment.events.prefix(5) == ["insert", "bootstrap", "list", "info", "mount"])
        #expect(!environment.events.contains("window"))
        #expect(receipt?["GuestProgress"]?.dictionary?.isEmpty == true)
        #expect(files.saved?["HeadlessUpdateRepair"] == true)
    }

    @Test func aDiscStillBeingProbedIsLookedForAgain() async throws {
        let environment = FakeEnvironment()
        environment.listsBeforeDisc = 1
        let (_, failure, _) = await run(environment, try Files(), headless: true)
        #expect(failure == nil)
        #expect(environment.events.prefix(4) == ["insert", "bootstrap", "list", "list"])
    }

    @Test func aMissingDiscIsReportedBeforeAnythingIsInserted() async throws {
        let environment = FakeEnvironment()
        let files = try Files(disc: false)
        let (_, failure, _) = await run(environment, files)
        #expect(failure as? GuestPreparationError == .supportDiscIncomplete)
        #expect(environment.events.isEmpty)
        #expect(files.saved?["Phase"] == "failed")
    }

    @Test func aFailedStepSavesWhyEjectsAndKeepsTheWindowInformed() async throws {
        let environment = FakeEnvironment()
        environment.failing = ["--extract"]
        let files = try Files()
        let (receipt, failure, _) = await run(environment, files)
        #expect(failure is Lost)
        #expect(receipt == nil)
        #expect(files.saved?["Phase"] == "failed")
        #expect(files.saved?["Failure"] == "The agent went away.")
        #expect(environment.window.updates.last == "failed 0.0")
        #expect(environment.ejects == [true])
    }

    @Test func aHeldDiscIsLeftForTheNextRunUnforced() async throws {
        let environment = FakeEnvironment()
        environment.answers["unmount"] = GuestCommandResult(values: [
            "exitcode": 1, "stderr": .data(Data("held by loginwindow".utf8))
        ])
        let files = try Files()
        let (_, failure, _) = await run(environment, files)
        #expect(failure as? GuestPreparationError == .supportDiscHeldByLoginWindow)
        #expect(environment.ejects == [false])
        #expect(files.saved?["SupportUnmountResult"]?.dictionary?["stderr"] == "held by loginwindow")
    }

    @Test func aLostUnmountStillRecordsItsEvidence() async throws {
        let environment = FakeEnvironment()
        environment.failing = ["unmount"]
        let files = try Files()
        let (_, failure, _) = await run(environment, files)
        #expect(failure is Lost)
        #expect(files.saved?["SupportUnmountResult"]?.dictionary == [:])
    }

    @Test func aFailedEjectEndsTheRun() async throws {
        let environment = FakeEnvironment()
        environment.failing = ["eject"]
        let (_, failure, _) = await run(environment, try Files())
        #expect(failure is Lost)
        #expect(environment.ejects == [true, true], "Failing mid-run tries once more on the way out.")
        #expect(!environment.events.contains("0700"))
    }

    @Test func aGuestThatChangedStopsBeforePlanning() async throws {
        let environment = FakeEnvironment()
        environment.status = GuestReport(values: initialReport.values.merging(["VolumeUUID": "other"]) { $1 })
        let (_, failure, _) = await run(environment, try Files())
        #expect(failure as? GuestPreparationError == .guestChanged)
        #expect(!environment.events.contains("--plan"))
    }

    @Test func aPlanWithoutAnIdentityIsRefusedButSaved() async throws {
        let environment = FakeEnvironment()
        environment.answers["--plan"] = json(#"{"Planned":true,"Installed":false,"Ready":false,"Guest":"mojave"}"#)
        let files = try Files()
        let (_, failure, _) = await run(environment, files)
        #expect(failure as? GuestPreparationError == .planHasNoTransaction)
        #expect(files.saved?["InstallationPlan"] != nil)
    }

    @Test func toolDiagnosticsReachTheJournal() async throws {
        let environment = FakeEnvironment()
        environment.answers["--extract"] = GuestCommandResult(values: [
            "exitcode": 1, "stderr": .data(Data([0xFF]))
        ])
        let files = try Files()
        _ = await run(environment, files)
        #expect(files.saved?["ExtractionLog"] == "Non-text extraction output")
    }

    @Test func eachAttemptKeepsTheLastJournal() async throws {
        let files = try Files()
        _ = await run(FakeEnvironment(), files)
        _ = await run(FakeEnvironment(), files)
        let history = files.journal.deletingLastPathComponent().appendingPathComponent("GuestPreparationHistory")
        #expect(try FileManager.default.contentsOfDirectory(atPath: history.path).count == 1)
    }
}
