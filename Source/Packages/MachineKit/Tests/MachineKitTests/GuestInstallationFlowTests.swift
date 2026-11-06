import Foundation
import Testing

@testable import MachineKit

@MainActor
private final class FakeRunner: GuestCommandRunning {
    struct Lost: Error, LocalizedError {
        var errorDescription: String? { "The agent went away." }
    }

    var replies: [(([String]) -> [String: Any]?)] = []
    var commands: [(path: String, arguments: [String])] = []
    var firstArguments: [String] { commands.compactMap(\.arguments.first) }

    func run(_ path: String, arguments: [String], timeout: TimeInterval) async throws -> GuestCommandResult {
        let index = commands.count
        commands.append((path, arguments))
        guard index < replies.count, let reply = replies[index](arguments) else { throw Lost() }
        let stdout = try JSONSerialization.data(withJSONObject: reply)
        return GuestCommandResult(foundationObject: ["exitcode": 0, "stdout": stdout] as [String: Any])
    }

    func answer(_ objects: [String: Any]...) {
        replies = objects.map { object in { _ in object } }
    }
}

private struct InstallationFixture {
    let root: URL
    var journal: URL { root.appendingPathComponent("State/GuestInstallation.plist") }
    var history: URL { root.appendingPathComponent("State/InstallationHistory") }
    let identity = UUID().uuidString
    let guestJournal = "/private/var/tmp/VirtualIntelMac.test/InstallTransaction.plist"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("State"), withIntermediateDirectories: true)
    }

    var record: [String: Any] {
        [
            "FormatVersion": 1, "TransactionID": identity, "GuestJournal": guestJournal,
            "Preparation": ["TransactionID": identity, "TransactionJournal": guestJournal]
        ]
    }

    var status: [String: Any] {
        [
            "TransactionID": identity, "Phase": "awaiting-reboot", "RebootRequired": true,
            "ProductBuildVersion": "19H15", "VolumeUUID": "volume", "BootSessionUUID": "before"
        ]
    }

    var terminal: [String: Any] { status.merging(["FilesPublished": true]) { $1 } }

    var verified: [String: Any] {
        [
            "TransactionID": identity, "VerifiedAfterReboot": true, "MetalCommandVerified": true,
            "ProductBuildVersion": "19H15", "VolumeUUID": "volume", "BootSessionUUID": "after", "Ready": false
        ]
    }

    var receipt: [String: PropertyListValue] {
        [
            "Prepared": true, "Planned": true, "Installed": false, "TransactionID": .string(identity),
            "TransactionJournal": .string(guestJournal)
        ]
    }

    func write(_ record: [String: Any]) throws {
        try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0).write(to: journal)
    }

    var saved: [String: PropertyListValue]? { GuestInstallationTransaction.record(at: journal) }
}

@MainActor
private final class FakeHost: GuestInstallationHost {
    let fixture: InstallationFixture
    let fake = FakeRunner()
    var isRunning = true
    let sessionState = GuestSessionStateBridge()
    var hasInstallerMedia = false
    var requiresInstallerDisplay = false
    var statusText = ""
    var windowSubtitle = ""
    var isPreparing = false
    var preparationRequested = false
    var installationRequested = false
    var repairArchivePending = false
    var canRepairUpdatedSystem = false
    var preparation: (receipt: [String: PropertyListValue]?, failure: (any Error)?) = (nil, nil)
    var events: [String] = []
    var logged: [String] = []
    var preparedHeadlessly: Bool?

    init(fixture: InstallationFixture) {
        self.fixture = fixture
        sessionState.state.running = true
    }

    var runner: any GuestCommandRunning { fake }
    var installationJournal: URL { fixture.journal }

    func keepCompletionReport() { events.append("keep report") }
    func clearCompletionReport() { events.append("clear report") }
    func prepareGuestFiles(
        allowHeadlessRepair: Bool, progress: @escaping @MainActor (String) -> Void
    ) async -> (receipt: [String: PropertyListValue]?, failure: (any Error)?) {
        preparedHeadlessly = allowHeadlessRepair
        progress("Copying…")
        return preparation
    }
    func connectGuestProgress(receipt: PropertyListValue?) { events.append("connect progress") }
    func updateGuestProgress(mode: String, fraction: Double, message: String) { events.append("progress \(mode)") }
    func ejectInstallerVolumes() { events.append("eject") }
    func log(_ message: String) { logged.append(message) }
    func present(_ error: any Error) { events.append("present") }
    func failCreatingGuest(_ message: String) { events.append("fail") }
    func showInstallationNotice() { events.append("notice") }
    func dismissSetupNotice() { events.append("dismiss") }
    func showHeadlessRepairProgress(_ message: String) { events.append("headless") }
    func refreshGuestStatus() { events.append("refresh") }
    func scheduleGuestStatusRetry() { events.append("retry") }
    func scheduleGuestStatusRefresh(after delay: TimeInterval) { events.append("refresh after \(Int(delay))") }
    func resumeDesktopServices(boot: String) { events.append("desktop \(boot)") }
    func handOffToGraphics() { events.append("hand off") }
    func offerGraphicsRestart() { events.append("offer restart") }
}

private func report(_ values: [String: PropertyListValue] = [:]) -> GuestReport {
    GuestReport(values: values)
}

private let updatedCatalina: [String: PropertyListValue] = [
    "Guest": "catalina", "InstalledSystemCandidate": true, "LiveRoot": true, "KernelMatchesSystem": true,
    "VolumeUUID": "volume", "ProductBuildVersion": "19H2036", "BootSessionUUID": "updated-boot"
]

@MainActor
@Suite struct GuestInstallationTransactionTests {
    private func transaction(_ fixture: InstallationFixture) -> (GuestInstallationTransaction, FakeRunner) {
        let runner = FakeRunner()
        return (GuestInstallationTransaction(runner: runner, journal: fixture.journal), runner)
    }

    @Test func aStatusCheckSendsOneCommandAndNeverReadies() async throws {
        let fixture = try InstallationFixture()
        try fixture.write(fixture.record)
        let (transaction, runner) = transaction(fixture)
        runner.answer(fixture.status)
        let outcome = await transaction.reconcile(verifyAfterReboot: false)
        #expect(outcome.failure == nil)
        #expect(runner.firstArguments == ["--status"])
        #expect(runner.commands[0].path == "/private/var/tmp/VirtualIntelMac.test/guest-install")
        #expect(fixture.saved?["Ready"] == false)
        #expect(fixture.saved?["Phase"] == "awaiting-reboot")
    }

    @Test func verificationAfterARestartRecordsItsEvidence() async throws {
        let fixture = try InstallationFixture()
        try fixture.write(fixture.record)
        let (transaction, runner) = transaction(fixture)
        runner.answer(fixture.status, fixture.verified)
        let outcome = await transaction.reconcile(verifyAfterReboot: true)
        #expect(outcome.failure == nil)
        #expect(runner.firstArguments == ["--status", "--verify-after-reboot"])
        #expect(fixture.saved?["Phase"] == "graphics-verified")
        #expect(fixture.saved?["Ready"] == false)
        #expect(fixture.saved?["PostBootVerification"]?.dictionary?["BootSessionUUID"] == "after")
    }

    @Test func theSameBootCantVerifyItself() async throws {
        let fixture = try InstallationFixture()
        try fixture.write(fixture.record)
        let (transaction, runner) = transaction(fixture)
        runner.answer(fixture.status, fixture.verified.merging(["BootSessionUUID": "before"]) { $1 })
        let outcome = await transaction.reconcile(verifyAfterReboot: true)
        #expect(outcome.failure as? GuestInstallationError == .verificationIncomplete(diagnostic: nil))
        #expect(fixture.saved?["PostBootVerification"] == nil)
    }

    @Test func anUntrustedJournalPathSendsNothing() async throws {
        let fixture = try InstallationFixture()
        try fixture.write(fixture.record.merging(["GuestJournal": "/tmp/untrusted/InstallTransaction.plist"]) { $1 })
        let (transaction, runner) = transaction(fixture)
        let outcome = await transaction.reconcile(verifyAfterReboot: true)
        #expect(outcome.failure as? GuestInstallationError == .invalidRecord)
        #expect(runner.commands.isEmpty)
    }

    @Test func anotherTransactionsStatusIsUnconfirmed() async throws {
        let fixture = try InstallationFixture()
        try fixture.write(fixture.record)
        let (transaction, runner) = transaction(fixture)
        runner.answer(["TransactionID": "wrong"])
        let outcome = await transaction.reconcile(verifyAfterReboot: true)
        #expect(outcome.failure as? GuestInstallationError == .outcomeUnconfirmed)
        #expect(runner.commands.count == 1)
        #expect(fixture.saved?["Phase"] == "outcome-unknown")
        #expect(fixture.saved?["ReconciliationError"] != nil)
    }

    @Test func aLostAgentIsRecordedAsUnknown() async throws {
        let fixture = try InstallationFixture()
        try fixture.write(fixture.record)
        let (transaction, _) = transaction(fixture)
        let outcome = await transaction.reconcile(verifyAfterReboot: false)
        #expect(outcome.failure is FakeRunner.Lost)
        #expect(fixture.saved?["Phase"] == "outcome-unknown")
    }

    @Test func theDurableGuestDirectoryIsTrusted() async throws {
        let fixture = try InstallationFixture()
        let durable = "/private/var/db/VirtualIntelMac.test/InstallTransaction.plist"
        try fixture.write(
            fixture.record.merging([
                "GuestJournal": durable,
                "Preparation": ["TransactionID": fixture.identity, "TransactionJournal": durable]
            ]) { $1 })
        let (transaction, runner) = transaction(fixture)
        runner.answer(fixture.status, fixture.verified)
        #expect(await transaction.reconcile(verifyAfterReboot: true).failure == nil)
    }

    @Test func aRepairCheckKeepsTheJournalWhereItIs() async throws {
        let fixture = try InstallationFixture()
        try fixture.write(fixture.record)
        let (transaction, runner) = transaction(fixture)
        runner.answer(fixture.terminal)
        try await transaction.checkForRepair(updatedSystem: nil)
        #expect(FileManager.default.fileExists(atPath: fixture.journal.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.history.path))
    }

    @Test func anActiveTransactionCantBeRepairedOver() async throws {
        let fixture = try InstallationFixture()
        try fixture.write(fixture.record)
        let (transaction, runner) = transaction(fixture)
        runner.answer(fixture.terminal.merging(["Phase": "publishing"]) { $1 })
        await #expect(throws: GuestInstallationError.notAtStoppingPoint) {
            try await transaction.checkForRepair(updatedSystem: nil)
        }
    }

    @Test func archivingRejectsActiveOrMismatchedTransactions() async throws {
        let fixture = try InstallationFixture()
        for reply in [["Phase": "publishing"], ["TransactionID": "wrong"]] as [[String: Any]] {
            try fixture.write(fixture.record)
            let (transaction, runner) = transaction(fixture)
            runner.answer(fixture.terminal.merging(reply) { $1 })
            await #expect(throws: GuestInstallationError.self) {
                try await transaction.archiveForRepair(updatedSystem: nil)
            }
            #expect(runner.commands.count == 1)
            #expect(FileManager.default.fileExists(atPath: fixture.journal.path))
        }
    }

    @Test func archivingKeepsEveryRecord() async throws {
        let fixture = try InstallationFixture()
        for _ in 0..<2 {
            try fixture.write(fixture.record)
            let (transaction, runner) = transaction(fixture)
            runner.answer(fixture.terminal)
            try await transaction.archiveForRepair(updatedSystem: nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.history.path)
        #expect(names.count == 2)
        #expect(names.contains("\(fixture.identity).plist"))
        let retained = GuestInstallationTransaction.record(
            at: fixture.history.appendingPathComponent("\(fixture.identity).plist"))
        #expect(retained?["Preparation"]?.dictionary?["TransactionID"] == .string(fixture.identity))
    }

    @Test func aSupersededVerifiedInstallationIsArchivedWithoutACommand() async throws {
        let fixture = try InstallationFixture()
        var old = fixture.record
        old["GuestResult"] = fixture.terminal
        old["PreviousPostBootVerification"] = fixture.verified
        old["Preparation"] = [
            "TransactionID": fixture.identity, "TransactionJournal": fixture.guestJournal,
            "GuestReport": ["Guest": "catalina", "ProductBuildVersion": "19H15", "VolumeUUID": "volume"]
        ]
        old["Phase"] = "outcome-unknown"
        old["ReconciliationError"] = "Temporary verifier missing"
        try fixture.write(old)
        let (transaction, runner) = transaction(fixture)
        try await transaction.checkForRepair(updatedSystem: report(updatedCatalina))
        #expect(FileManager.default.fileExists(atPath: fixture.journal.path))
        try await transaction.archiveForRepair(updatedSystem: report(updatedCatalina))
        #expect(runner.commands.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func applyingDispatchesOnceAndTheGuestsStatusDecides() async throws {
        let fixture = try InstallationFixture()
        let (transaction, runner) = transaction(fixture)
        runner.answer([:], fixture.status)
        let outcome = await transaction.apply(preparation: fixture.receipt)
        #expect(outcome.failure == nil)
        #expect(runner.firstArguments == ["--apply", "--status"])
        #expect(fixture.saved?["Phase"] == "awaiting-reboot")

        let again = await transaction.apply(preparation: fixture.receipt)
        #expect(again.failure != nil)
        #expect(runner.commands.count == 2)
    }

    @Test func applyingPassesTheProgressDirectory() async throws {
        let fixture = try InstallationFixture()
        let (transaction, runner) = transaction(fixture)
        runner.answer([:], fixture.status)
        var receipt = fixture.receipt
        receipt["GuestProgress"] = ["Directory": "/private/var/tmp/VirtualIntelMacUI.abc123"]
        _ = await transaction.apply(preparation: receipt)
        #expect(
            runner.commands[0].arguments == [
                "--apply", fixture.guestJournal, "--progress", "/private/var/tmp/VirtualIntelMacUI.abc123"
            ])
    }

    @Test func aRefusedReceiptDispatchesNothing() async throws {
        let fixture = try InstallationFixture()
        let (transaction, runner) = transaction(fixture)
        for change in [["Installed": true], ["Planned": false], ["TransactionID": "nope"]]
            as [[String: PropertyListValue]]
        {
            let outcome = await transaction.apply(preparation: fixture.receipt.merging(change) { $1 })
            #expect(outcome.failure as? GuestInstallationError == .noPreparedTransaction)
        }
        #expect(runner.commands.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func aRollbackReportsItsOwnFailure() async throws {
        let fixture = try InstallationFixture()
        let (transaction, runner) = transaction(fixture)
        runner.answer([:], ["TransactionID": fixture.identity, "Phase": "rolled-back", "Failure": "No room."])
        let outcome = await transaction.apply(preparation: fixture.receipt)
        #expect(outcome.failure?.localizedDescription == "No room.")
        #expect(outcome.result?["Phase"] == "rolled-back")
    }

    @Test func aLostReplyKeepsTheJournalAndTheGuestStatusStillDecides() async throws {
        let fixture = try InstallationFixture()
        let (transaction, runner) = transaction(fixture)
        runner.replies = [{ _ in nil }, { _ in fixture.status }]
        let outcome = await transaction.apply(preparation: fixture.receipt)
        #expect(outcome.failure == nil)
        #expect(fixture.saved?["CommandError"] == "The agent went away.")
    }
}

@MainActor
@Suite struct GuestInstallationFlowTests {
    private func make(_ values: [String: PropertyListValue] = [:]) throws -> (
        GuestInstallationFlow, FakeHost, InstallationFixture
    ) {
        let fixture = try InstallationFixture()
        let host = FakeHost(fixture: fixture)
        return (GuestInstallationFlow(host: host, report: report(values)), host, fixture)
    }

    @Test func aRepairWithNoJournalGoesStraightToPreparation() async throws {
        let (flow, host, _) = try make()
        host.sessionState.repairRequested = true
        let task = flow.beginRepair()
        #expect(host.isPreparing)
        #expect(!host.sessionState.repairRequested)
        await task.value
        #expect(!host.isPreparing)
        #expect(host.preparationRequested && host.installationRequested)
        #expect(!host.repairArchivePending)
        #expect(host.events == ["clear report", "refresh"])
    }

    @Test func aRepairOverAnActiveTransactionIsHeld() async throws {
        let (flow, host, fixture) = try make()
        try fixture.write(fixture.record)
        host.fake.answer(fixture.terminal.merging(["Phase": "publishing"]) { $1 })
        await flow.beginRepair().value
        #expect(host.sessionState.updateRepairHeld)
        #expect(!host.repairArchivePending && !host.isPreparing && !host.preparationRequested)
        #expect(host.events == ["clear report", "present", "retry"])
        #expect(host.statusText == GuestInstallationError.notAtStoppingPoint.localizedDescription)
    }

    @Test func aRepairThatPassesItsCheckLeavesTheArchivePending() async throws {
        let (flow, host, fixture) = try make()
        try fixture.write(fixture.record)
        host.fake.answer(fixture.terminal)
        await flow.beginRepair().value
        #expect(host.repairArchivePending && host.preparationRequested)
    }

    @Test func aMachineThatStoppedDuringARepairCheckDoesNothingMore() async throws {
        let (flow, host, _) = try make()
        host.isRunning = false
        await flow.beginRepair().value
        #expect(!host.preparationRequested && !host.isPreparing)
        #expect(host.events == ["clear report"])
    }

    @Test func aVerifiedReconciliationFinishesAndEjectsTheInstaller() async throws {
        let (flow, host, fixture) = try make(["BootSessionUUID": "after", "Guest": "catalina"])
        try fixture.write(fixture.record)
        host.hasInstallerMedia = true
        host.fake.answer(fixture.status, fixture.verified)
        await flow.beginReconciliation().value
        #expect(host.sessionState.reconciliationAttempts >= 1)
        #expect(!host.isPreparing)
        #expect(host.logged.first?.hasPrefix("Reconciliation: ") == true)
        #expect(host.events.last == "refresh after 60")
        #expect(host.events.contains("desktop after"))
        #expect(host.sessionState.reconciledBoot == "after")
    }

    @Test func aThirdFailedCheckEndsACreationRun() async throws {
        let (flow, host, fixture) = try make(["BootSessionUUID": "boot"])
        try fixture.write(fixture.record)
        host.sessionState.reconciledBoot = "boot"
        host.sessionState.reconciliationAttempts = 2
        await flow.beginReconciliation().value
        #expect(host.sessionState.reconciliationAttempts == 3)
        #expect(host.events.contains("fail"))
        #expect(host.events.last == "refresh after 60")
    }

    @Test func aStaleCheckLeavesAnotherBootsDesktopAlone() async throws {
        let (flow, host, fixture) = try make(["BootSessionUUID": "boot"])
        try fixture.write(fixture.record)
        let task = flow.beginReconciliation()
        host.sessionState.reconciledBoot = "newer"
        await task.value
        #expect(!host.events.contains { $0.hasPrefix("desktop") })
    }

    @Test func preparingWithoutInstallingStopsThere() async throws {
        let (flow, host, _) = try make()
        host.preparation = (["Prepared": true], nil)
        let task = flow.beginPreparation()
        #expect(host.windowSubtitle == "Finishing setup…")
        await task.value
        #expect(host.statusText == "Guest files prepared — installation pending")
        #expect(host.windowSubtitle == "" && !host.isPreparing)
        #expect(host.events == ["connect progress", "progress complete", "refresh after 60"])
        #expect(host.fake.commands.isEmpty)
    }

    @Test func aFailedPreparationInstallsNothing() async throws {
        let (flow, host, _) = try make()
        host.installationRequested = true
        host.preparation = (nil, FakeRunner.Lost())
        await flow.beginPreparation().value
        #expect(host.statusText == "The agent went away.")
        #expect(host.events == ["connect progress", "fail", "refresh after 60"])
        #expect(!host.installationRequested)
        #expect(host.fake.commands.isEmpty)
    }

    @Test func aHeadlessRepairShowsItsProgress() async throws {
        let (flow, host, _) = try make()
        host.sessionState.verifiedUpdateRepair = true
        host.preparation = (["Prepared": true], nil)
        await flow.beginPreparation().value
        #expect(host.preparedHeadlessly == true)
        #expect(host.events.first == "headless")

        let (desktopFlow, desktopHost, _) = try make(["DesktopRunning": true])
        desktopHost.sessionState.verifiedUpdateRepair = true
        desktopHost.preparation = (["Prepared": true], nil)
        await desktopFlow.beginPreparation().value
        #expect(desktopHost.preparedHeadlessly == false)
        #expect(!desktopHost.events.contains("headless"))
    }

    private func installing(_ values: [String: PropertyListValue] = [:]) throws -> (
        GuestInstallationFlow, FakeHost, InstallationFixture
    ) {
        let (flow, host, fixture) = try make(values)
        host.installationRequested = true
        host.preparation = (fixture.receipt, nil)
        return (flow, host, fixture)
    }

    @Test func aFinishedInstallOffersARestart() async throws {
        let (flow, host, fixture) = try installing()
        host.fake.answer([:], fixture.status)
        await flow.beginPreparation().value
        #expect(host.events == ["connect progress", "notice", "dismiss", "offer restart"])
        #expect(host.statusText == "Graphics files installed — restart required for verification")
        #expect(host.logged == ["Installation: Graphics files installed — restart required for verification"])
        #expect(!host.isPreparing && host.windowSubtitle == "")
    }

    @Test func aHeadlessRepairRestartsByItselfWithNoNotice() async throws {
        let (flow, host, fixture) = try installing()
        host.sessionState.verifiedUpdateRepair = true
        host.fake.answer([:], fixture.status)
        await flow.beginPreparation().value
        #expect(host.events.suffix(2) == ["dismiss", "hand off"])
        #expect(!host.events.contains("notice"))
    }

    @Test func aMachineStillOnTheInstallerDisplayKeepsPolling() async throws {
        let (flow, host, fixture) = try installing()
        host.requiresInstallerDisplay = true
        host.fake.answer([:], fixture.status)
        await flow.beginPreparation().value
        #expect(host.events.last == "refresh after 60")
    }

    @Test func aRollbackSaysSoAndKeepsPolling() async throws {
        let (flow, host, fixture) = try installing()
        host.fake.answer([:], ["TransactionID": fixture.identity, "Phase": "rolled-back"])
        await flow.beginPreparation().value
        #expect(host.events == ["connect progress", "notice", "dismiss", "progress failed", "fail", "refresh after 60"])
    }

    @Test func anUncertainInstallKeepsWorkingStatus() async throws {
        let (flow, host, fixture) = try installing()
        host.fake.answer([:], ["TransactionID": "other"])
        await flow.beginPreparation().value
        #expect(host.events.contains("progress working"))
        #expect(!host.events.contains("offer restart"))
        #expect(host.sessionState.reconciledBoot == nil)
        #expect(fixture.saved?["Phase"] == "outcome-unknown")
    }

    @Test func aRepairArchivesTheOldRecordBeforeApplying() async throws {
        let (flow, host, fixture) = try installing()
        try fixture.write(fixture.record)
        host.repairArchivePending = true
        host.fake.answer(fixture.terminal, [:], fixture.status)
        await flow.beginPreparation().value
        #expect(host.fake.firstArguments == ["--status", "--apply", "--status"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.history.path).count == 1)
        #expect(!host.repairArchivePending)
    }

    @Test func aFailedArchiveInstallsNothingAndHoldsTheRepair() async throws {
        let (flow, host, fixture) = try installing()
        try fixture.write(fixture.record)
        host.repairArchivePending = true
        host.fake.answer(fixture.terminal.merging(["Phase": "publishing"]) { $1 })
        await flow.beginPreparation().value
        #expect(host.fake.commands.count == 1)
        #expect(host.sessionState.updateRepairHeld)
        #expect(host.events.suffix(4) == ["dismiss", "progress failed", "present", "retry"])
    }

    @Test func aMachineThatStoppedDuringPreparationDoesNothingMore() async throws {
        let (flow, host, fixture) = try installing()
        host.isRunning = false
        await flow.beginPreparation().value
        #expect(host.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }
}

@Suite struct GuestBootPolicyRecordTests {
    private let directory = "/private/var/db/VirtualIntelMac.0123456789abcdef"

    private func root(state: [String: Any], observed: [String: Any]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("BootPolicy.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["Report": observed], format: .xml, options: 0)
            .write(to: root.appendingPathComponent("GuestStatus.plist"))
        return root.appendingPathComponent("BootPolicy.plist")
    }

    private var ready: [String: Any] {
        [
            "FormatVersion": 1, "MachineIdentifier": "m", "Guest": "catalina", "Phase": "ready",
            "DispatchAttempted": true, "GuestDirectory": directory, "VolumeUUID": "v",
            "Result": [
                "PreferenceVerified": true, "TaskForPIDRestrictionDisabled": true, "VolumeUUID": "v",
                "Guest": "catalina", "ProtocolVersion": 1
            ]
        ]
    }

    @Test func aFinishedMigrationNamesItsVerifier() throws {
        let journal = try root(state: ready, observed: ["Guest": "catalina", "VolumeUUID": "v"])
        #expect(GuestBootPolicyRecord.isReady(at: journal, guest: "catalina", identifier: "m"))
        #expect(
            GuestBootPolicyRecord.verifier(at: journal, guest: "catalina", identifier: "m", volume: "v")
                == directory + "/guest-install")
        #expect(GuestBootPolicyRecord.verifier(at: journal, guest: "catalina", identifier: "m", volume: "w") == nil)
    }

    @Test func anythingUnfinishedIsNotReady() throws {
        let changes: [[String: Any]] = [
            ["Phase": "dispatching"], ["DispatchAttempted": false], ["MachineIdentifier": "other"],
            ["GuestDirectory": "/private/var/db/VirtualIntelMac."],
            ["GuestDirectory": "/tmp/VirtualIntelMac.0123456789abcdef"], ["FormatVersion": 2], ["VolumeUUID": ""]
        ]
        for change in changes {
            let journal = try root(
                state: ready.merging(change) { $1 }, observed: ["Guest": "catalina", "VolumeUUID": "v"])
            #expect(!GuestBootPolicyRecord.isReady(at: journal, guest: "catalina", identifier: "m"))
        }
    }

    @Test func aReportFromAnotherVolumeIsNotReady() throws {
        let journal = try root(state: ready, observed: ["Guest": "catalina", "VolumeUUID": "w"])
        #expect(!GuestBootPolicyRecord.isReady(at: journal, guest: "catalina", identifier: "m"))
    }
}
