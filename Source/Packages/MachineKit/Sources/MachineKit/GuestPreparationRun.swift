import Foundation

/// The window the guest's setup tool shows, once a run has opened it.
@MainActor
public protocol GuestSetupWindow {
    var setupReceipt: [String: PropertyListValue] { get }
    func update(mode: String, fraction: Double, message: String)
}

/// What a preparation run needs beyond the guest's own commands: the emulator's support drive and the app's files.
@MainActor
public protocol GuestPreparationEnvironment: GuestCommandRunning {
    func insertSupportDisc(at url: URL) async throws
    func ejectSupportDisc(force: Bool) async throws
    /// Stages the small tools the disc can't provide, and returns their directory in the guest.
    func stageBootstrapTools(guest: String) async throws -> String
    func openSetupWindow(staging directory: String) async throws -> any GuestSetupWindow
    func collectStatus() async throws -> GuestReport
}

/// One preparation of a guest's graphics files: the support disc, the guest's tools and a journal of each step. It never
/// installs anything into the system, and owns only the dedicated setup-support drive, never the user's or an OS
/// installer's disc.
@MainActor
public final class GuestPreparationRun {
    private let environment: any GuestPreparationEnvironment
    private let report: GuestReport
    private let checks: GuestPreparationChecks
    private let runtime: URL
    private let journal: URL
    private let headlessRepair: Bool
    private let progress: @MainActor (String) -> Void
    private var state: [String: PropertyListValue] = [:]
    private var setupWindow: (any GuestSetupWindow)?
    private var supportInserted = false
    private var supportUnmounted = false

    public init(
        environment: any GuestPreparationEnvironment, report: GuestReport, runtime: URL, journal: URL,
        headlessRepair: Bool, progress: @escaping @MainActor (String) -> Void
    ) {
        self.environment = environment
        self.report = report
        checks = GuestPreparationChecks(initialReport: report)
        self.runtime = runtime
        self.journal = journal
        self.headlessRepair = headlessRepair
        self.progress = progress
    }

    private static let windowFractions: [String: Double] = [
        "preparing-utilities": 0.12, "checking-environment": 0.14, "extracting": 0.18, "preparing": 0.25,
        "verifying-guest": 0.42, "planning-installation": 0.46
    ]

    /// The receipt an installation needs, or why there isn't one. A failure past the first step has a journal.
    public func run() async -> (receipt: [String: PropertyListValue]?, failure: (any Error)?) {
        do {
            try checks.verifyInitialReport(allowingHeadlessRepair: headlessRepair)
            try startJournal()
        } catch {
            return (nil, error)
        }
        do {
            return await finish(try await prepare(), nil)
        } catch {
            return await finish(nil, error)
        }
    }

    /// Each attempt starts a new journal, and the last one goes to history first.
    private func startJournal() throws {
        let files = FileManager.default
        let directory = journal.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        if files.fileExists(atPath: journal.path) {
            let history = directory.appendingPathComponent("GuestPreparationHistory")
            try files.createDirectory(at: history, withIntermediateDirectories: true)
            try files.copyItem(at: journal, to: history.appendingPathComponent(UUID().uuidString + ".plist"))
        }
        state = [
            "FormatVersion": 1,
            "Attempt": .string(UUID().uuidString),
            "HeadlessUpdateRepair": .number(headlessRepair as NSNumber),
            "InitialGuestReport": .dictionary(report.values),
            "Installed": false
        ]
    }

    private func save(phase: String) throws {
        state["Phase"] = .string(phase)
        state["UpdatedAt"] = .date(Date())
        let object = state.mapValues(\.foundationObject)
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        try data.write(to: journal, options: .atomic)
    }

    private func enter(phase: String, message: String) throws {
        try save(phase: phase)
        if let fraction = Self.windowFractions[phase] {
            setupWindow?.update(mode: "working", fraction: fraction, message: message)
        }
        progress(message)
    }

    private func finish(
        _ receipt: [String: PropertyListValue]?, _ failure: (any Error)?
    ) async -> (receipt: [String: PropertyListValue]?, failure: (any Error)?) {
        var writeFailure: (any Error)?
        if let failure {
            state["Failure"] = .string(failure.localizedDescription)
            setupWindow?.update(
                mode: "failed", fraction: 0,
                message: "Setup couldn’t finish. Check Session Details in the Light Click app before trying again.")
        }
        if let receipt { state["Receipt"] = .dictionary(receipt) }
        do {
            try save(phase: failure == nil ? "prepared" : "failed")
        } catch {
            writeFailure = error
        }
        var ejectFailure: (any Error)?
        do {
            try await releaseSupportDisc()
        } catch {
            ejectFailure = error
        }
        return (receipt, failure ?? writeFailure ?? ejectFailure)
    }

    /// macOS can hold a removal lock even after unmounting, so the tray is forced, once the verified volume is gone.
    private func releaseSupportDisc() async throws {
        guard supportInserted else { return }
        try await environment.ejectSupportDisc(force: supportUnmounted)
        supportInserted = false
    }

    /// Runs a guest command. Whatever it printed is judged by the caller, after a transport error has been dealt with.
    private func run(
        _ path: String, _ arguments: [String], timeout: TimeInterval
    ) async -> (GuestCommandResult, (any Error)?) {
        do {
            return (try await environment.run(path, arguments: arguments, timeout: timeout), nil)
        } catch {
            return (GuestCommandResult(values: [:]), error)
        }
    }

    private func prepare() async throws -> [String: PropertyListValue] {
        let guest = report["Guest"]?.string ?? ""
        try enter(phase: "transferring", message: "Making guest setup files available…")
        let started = ProcessInfo.processInfo.systemUptime
        let media = runtime.appendingPathComponent("GuestPayloads").appendingPathComponent(guest + ".iso")
        guard FileManager.default.fileExists(atPath: media.path) else {
            throw GuestPreparationError.supportDiscIncomplete
        }
        try await environment.insertSupportDisc(at: media)
        supportInserted = true
        let bootstrap = try await environment.stageBootstrapTools(guest: guest)
        state["GuestStagingDirectory"] = .string(bootstrap)
        // An update can replace framebuffer support before WindowServer starts, and a guest AppKit window would deadlock
        // on it. A verified update repair reports its progress in the host app instead.
        if headlessRepair {
            try await mountSupportDisc()
        } else {
            let window = try await environment.openSetupWindow(staging: bootstrap)
            setupWindow = window
            state["GuestProgress"] = .dictionary(window.setupReceipt)
        }
        progress("Copying and verifying guest setup files…")
        setupWindow?.update(mode: "working", fraction: 0.05, message: "Copying and verifying guest support files…")
        let transfer = try await stageMedia(guest: guest, directory: bootstrap, started: started)
        let directory = transfer["Directory"]?.string ?? bootstrap
        // Guest Disk Arbitration is told first. A forced host-only tray removal can leave the now-invalid mounted volume
        // visible in Finder.
        let (unmounted, unmountFailure) = await run(
            "/usr/sbin/diskutil", ["unmount", transfer["MediaDevice"]?.string ?? ""], timeout: 60)
        state["SupportUnmountResult"] = .dictionary(GuestPreparationChecks.unmountEvidence(unmounted))
        if let unmountFailure { throw unmountFailure }
        try GuestPreparationChecks.verifyUnmount(unmounted)
        supportUnmounted = true
        try await releaseSupportDisc()
        return try await prepareFiles(in: directory, archive: transfer["Archive"]?.string ?? "")
    }

    /// Disk Arbitration doesn't automount optical volumes before a GUI session, so only the uniquely named disc is
    /// mounted, read-only. Insertion is acknowledged before the guest's probe publishes its label, so discovery alone
    /// is retried, never a mount with an uncertain outcome.
    private func mountSupportDisc() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        var identifier: String?
        while identifier == nil {
            let list = try await environment.run("/usr/sbin/diskutil", arguments: ["list", "-plist"], timeout: 20)
            switch try SupportDisc.lookup(inDiskList: list, mayRetry: ProcessInfo.processInfo.systemUptime < deadline) {
            case .found(let found): identifier = found
            case .notPublishedYet: try await Task.sleep(for: .seconds(1))
            }
        }
        guard let identifier else { return }
        try SupportDisc.verify(
            info: try await environment.run(
                "/usr/sbin/diskutil", arguments: ["info", "-plist", identifier], timeout: 15))
        try SupportDisc.verify(
            mount: try await environment.run(
                "/usr/sbin/diskutil", arguments: ["mount", "readOnly", identifier], timeout: 30))
    }

    private func stageMedia(
        guest: String, directory: String, started: TimeInterval
    ) async throws -> [String: PropertyListValue] {
        let tool = (directory as NSString).appendingPathComponent("guest-macho")
        let copied: GuestCommandResult
        do {
            copied = try await environment.run(tool, arguments: ["stage-media", guest, directory], timeout: 0)
        } catch {
            if let staging = (error as NSError).userInfo["GuestStagingDirectory"] {
                state["GuestStagingDirectory"] = PropertyListValue(foundationObject: staging)
            }
            throw error
        }
        try GuestPreparationChecks.verifyStaging(copied, directory: directory)
        let transfer = copied.json ?? [:]
        state["Transfer"] = .dictionary(transfer)
        state["GuestStagingDirectory"] = transfer["Directory"]
        state["TransferSeconds"] = .number((ProcessInfo.processInfo.systemUptime - started) as NSNumber)
        try GuestPreparationChecks.verifyStagedCopy(transfer)
        return transfer
    }

    private func prepareFiles(in directory: String, archive: String) async throws -> [String: PropertyListValue] {
        func path(_ name: String) -> String { (directory as NSString).appendingPathComponent(name) }
        let prepare = path("guest-prepare")
        let install = path("guest-install")

        try enter(phase: "preparing-utilities", message: "Preparing guest setup utilities…")
        let (mode, modeFailure) = await run(
            "/bin/chmod", ["0700", prepare, path("guest-image-patch"), install, path("codesign_allocate")], timeout: 15)
        if let modeFailure { throw modeFailure }
        try GuestPreparationChecks.verifyUtilities(mode)

        try enter(phase: "checking-environment", message: "Checking guest setup requirements…")
        let (checked, checkFailure) = await run(install, ["--check-environment"], timeout: 30)
        if let log = checked.log(nonText: nil) { state["AdmissionLog"] = .string(log) }
        if let checkFailure { throw checkFailure }
        try checks.verifyEnvironment(checked)
        state["Admission"] = checked.json.map(PropertyListValue.dictionary)

        try enter(phase: "extracting", message: "Unpacking guest setup files…")
        let extracted = path("Extracted")
        let payload = (extracted as NSString).appendingPathComponent("payload")
        let (unpacked, unpackFailure) = await run(prepare, ["--extract", path(archive), extracted], timeout: 0)
        if let log = unpacked.log(nonText: "Non-text extraction output") { state["ExtractionLog"] = .string(log) }
        if let receipt = unpacked.json { state["Extraction"] = .dictionary(receipt) }
        if let unpackFailure { throw unpackFailure }
        try GuestPreparationChecks.verifyExtraction(unpacked, payload: payload)

        try enter(phase: "preparing", message: "Preparing this macOS build’s graphics files…")
        let (prepared, prepareFailure) = await run(prepare, ["/", payload, directory], timeout: 0)
        if let log = prepared.log(nonText: "Non-text preparation output") { state["PreparationLog"] = .string(log) }
        if let prepareFailure { throw prepareFailure }
        try checks.verifyPreparedFiles(prepared)
        state["Preparation"] = prepared.json.map(PropertyListValue.dictionary)

        try enter(phase: "verifying-guest", message: "Verifying the prepared guest…")
        let later = try await environment.collectStatus()
        try checks.verifyUnchanged(later)

        try enter(
            phase: "planning-installation", message: "Checking installation targets and recording recovery information…"
        )
        let transaction = path("InstallTransaction.plist")
        let (planned, planFailure) = await run(install, ["--plan", "/", payload, transaction], timeout: 0)
        if let log = planned.log(nonText: "Non-text planning output") { state["PlanningLog"] = .string(log) }
        if let planFailure { throw planFailure }
        try checks.verifyPlan(planned)
        let plan = planned.json ?? [:]
        state["InstallationPlan"] = .dictionary(plan)
        try GuestPreparationChecks.verifyTransaction(plan)
        return [
            "Prepared": true,
            "Planned": true,
            "Installed": false,
            "GuestReport": .dictionary(later.values),
            "PayloadDirectory": .string(payload),
            "TransactionJournal": .string(transaction),
            "TransactionID": plan["TransactionID"] ?? .null,
            "GuestProgress": .dictionary(setupWindow?.setupReceipt ?? [:])
        ]
    }
}
