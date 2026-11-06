import Foundation

/// What a session lends a graphics installation: its flags, its window and the guest. All of it is the session's, and
/// `sessionState` is its flags as they are right now.
@MainActor
public protocol GuestInstallationHost: AnyObject {
    var isRunning: Bool { get }
    var sessionState: GuestSessionStateBridge { get }
    var runner: any GuestCommandRunning { get }
    var installationJournal: URL { get }
    var hasInstallerMedia: Bool { get }
    var requiresInstallerDisplay: Bool { get }

    var statusText: String { get set }
    var windowSubtitle: String { get set }
    var isPreparing: Bool { get set }
    var preparationRequested: Bool { get set }
    var installationRequested: Bool { get set }
    var repairArchivePending: Bool { get set }

    var canRepairUpdatedSystem: Bool { get }
    func keepCompletionReport()
    func clearCompletionReport()
    func prepareGuestFiles(
        allowHeadlessRepair: Bool, progress: @escaping @MainActor (String) -> Void
    ) async -> (receipt: [String: PropertyListValue]?, failure: (any Error)?)
    func connectGuestProgress(receipt: PropertyListValue?)
    func updateGuestProgress(mode: String, fraction: Double, message: String)
    func ejectInstallerVolumes()

    func log(_ message: String)
    func present(_ error: any Error)
    func failCreatingGuest(_ message: String)
    func showInstallationNotice()
    func dismissSetupNotice()
    func showHeadlessRepairProgress(_ message: String)
    func refreshGuestStatus()
    func scheduleGuestStatusRetry()
    func scheduleGuestStatusRefresh(after delay: TimeInterval)
    func resumeDesktopServices(boot: String)
    func handOffToGraphics()
    func offerGraphicsRestart()
}

/// The graphics installation steps `finishGuestStatus` starts, once its policy says one may run: check for a repair,
/// reconcile an earlier transaction, or prepare the guest's files and install them. Each `begin` sets the session's
/// flags before it returns, so a status report arriving next finds the work under way.
@MainActor
public struct GuestInstallationFlow {
    private let host: any GuestInstallationHost
    private let report: GuestReport
    private let transaction: GuestInstallationTransaction

    public init(host: any GuestInstallationHost, report: GuestReport) {
        self.host = host
        self.report = report
        transaction = GuestInstallationTransaction(runner: host.runner, journal: host.installationJournal)
    }

    private var updatedSystem: GuestReport? { host.canRepairUpdatedSystem ? report : nil }

    // MARK: Repair

    /// A development machine imported before transactional installation has no journal. That isn't a malformed journal,
    /// so it goes straight to a new, fully backed-up transaction. One that exists must pass a check first.
    @discardableResult
    public func beginRepair() -> Task<Void, Never> {
        host.sessionState.repairRequested = false
        host.isPreparing = true
        host.clearCompletionReport()
        let journalExists = FileManager.default.fileExists(atPath: host.installationJournal.path)
        if journalExists { host.repairArchivePending = true }
        let updated = journalExists ? updatedSystem : nil
        return Task {
            do {
                if journalExists { try await transaction.checkForRepair(updatedSystem: updated) }
                host.isPreparing = false
                guard host.isRunning else { return }
                host.sessionState.reconciledBoot = nil
                host.preparationRequested = true
                host.installationRequested = true
                host.refreshGuestStatus()
            } catch {
                host.isPreparing = false
                host.repairArchivePending = false
                host.sessionState.updateRepairHeld = true
                host.statusText = error.localizedDescription
                host.present(error)
                host.scheduleGuestStatusRetry()
            }
        }
    }

    // MARK: Reconciliation

    /// A read-only look at the saved transaction. Installation is never repeated and no hash is relaxed.
    @discardableResult
    public func beginReconciliation() -> Task<Void, Never> {
        let boot = report.bootSessionUUID
        host.sessionState.reconciliationAttempts =
            GuestStatusPolicy(report: report, failed: false, session: host.sessionState.state).nextReconciliationAttempt
        host.isPreparing = true
        host.sessionState.reconciledBoot = boot
        host.clearCompletionReport()
        let verifies = report.reconciliationVerifiesAfterReboot(
            journal: GuestInstallationTransaction.record(at: host.installationJournal))
        return Task {
            let outcome = await transaction.reconcile(verifyAfterReboot: verifies)
            host.isPreparing = false
            guard host.isRunning else { return }
            let verified = outcome.failure == nil && report.isVerifiedByReconciliation(result: outcome.result)
            if verified { host.sessionState.reconciliationAttempts = 3 }
            if verified && host.hasInstallerMedia {
                host.keepCompletionReport()
                // The owned backend stays open until shutdown, but its installer volumes needn't stay on the desktop.
                host.ejectInstallerVolumes()
            }
            let message =
                outcome.failure?.localizedDescription
                ?? GuestReport.reconciliationMessage(result: outcome.result, verified: verified)
            host.statusText = message
            host.log("Reconciliation: \(message)")
            // This boot checks no more, so the run could only wait forever.
            if !verified && host.sessionState.reconciliationAttempts >= 3 { host.failCreatingGuest(message) }
            // Console discovery may have finished while this check held the session busy, so clipboard setup resumes
            // now and not at the next status report. A stale check mustn't configure another boot's GUI session.
            if let boot, host.sessionState.reconciledBoot == boot { host.resumeDesktopServices(boot: boot) }
            host.scheduleGuestStatusRefresh(after: 60)
        }
    }

    // MARK: Preparation and installation

    private var repairsHeadlessly: Bool { host.sessionState.verifiedUpdateRepair && !report.isDesktopRunning }

    @discardableResult
    public func beginPreparation() -> Task<Void, Never> {
        host.preparationRequested = false
        host.isPreparing = true
        host.windowSubtitle = "Finishing setup…"
        return Task {
            let (receipt, failure) = await host.prepareGuestFiles(allowHeadlessRepair: repairsHeadlessly) { progress in
                host.statusText = progress
                if repairsHeadlessly { host.showHeadlessRepairProgress(progress) }
            }
            host.isPreparing = false
            host.windowSubtitle = ""
            guard host.isRunning else { return }
            host.connectGuestProgress(receipt: receipt?["GuestProgress"])
            let install = host.installationRequested
            host.installationRequested = false
            if install && failure == nil {
                await self.install(receipt: receipt ?? [:])
                return
            }
            let message = failure?.localizedDescription ?? "Guest files prepared — installation pending"
            host.statusText = message
            if failure == nil {
                host.updateGuestProgress(
                    mode: "complete", fraction: 1,
                    message: "Support files are prepared. No system files were installed.")
            }
            host.log("Preparation: \(message)")
            if failure != nil { host.failCreatingGuest(message) }
            // An explicit request runs once. An uncertain write is never retried by itself.
            host.scheduleGuestStatusRefresh(after: 60)
        }
    }

    private func install(receipt: [String: PropertyListValue]) async {
        host.isPreparing = true
        host.statusText = "Installing graphics support — do not shut down this Mac…"
        host.windowSubtitle = "Installing Graphics Drivers…"
        if !host.sessionState.verifiedUpdateRepair { host.showInstallationNotice() }
        // The earlier record stays until preparation succeeds. Otherwise a failure that only affected staging would
        // turn the next boot back into an unaccelerated installer.
        if host.repairArchivePending {
            host.repairArchivePending = false
            do {
                try await transaction.archiveForRepair(updatedSystem: updatedSystem)
            } catch {
                host.dismissSetupNotice()
                host.isPreparing = false
                host.windowSubtitle = ""
                host.statusText = error.localizedDescription
                host.updateGuestProgress(
                    mode: "failed", fraction: 0,
                    message: "The previous installation record could not be preserved. Nothing was installed.")
                host.sessionState.updateRepairHeld = true
                host.present(error)
                host.scheduleGuestStatusRetry()
                return
            }
        }
        let outcome = await transaction.apply(preparation: receipt)
        host.isPreparing = false
        host.windowSubtitle = ""
        host.dismissSetupNotice()
        let result =
            outcome.failure?.localizedDescription ?? "Graphics files installed — restart required for verification"
        host.statusText = result
        if outcome.failure != nil {
            if outcome.result?["Phase"].isEqual("rolled-back") == true {
                host.updateGuestProgress(
                    mode: "failed", fraction: 0,
                    message: "Setup couldn’t finish. The original system files were restored.")
            } else {
                host.updateGuestProgress(
                    mode: "working", fraction: -1,
                    message:
                        "Setup status couldn’t be confirmed. Keep this Mac running and check Session Details in the Light Click app."
                )
            }
        }
        host.log("Installation: \(result)")
        if outcome.failure != nil { host.failCreatingGuest(result) }
        host.sessionState.reconciledBoot = nil
        let policy = GuestStatusPolicy(report: report, failed: false, session: host.sessionState.state)
        let answer = outcome.failure == nil ? outcome.result : nil
        // Nothing restarts by itself: an uncertain outcome or a rollback must never be mistaken for success.
        switch policy.followUpAfterInstallation(
            outcomePhase: answer?["Phase"]?.string, rebootRequired: answer?["RebootRequired"].isTrue ?? false,
            requiresInstallerDisplay: host.requiresInstallerDisplay)
        {
        case .handOff: host.handOffToGraphics()
        case .offerRestart: host.offerGraphicsRestart()
        case .keepPolling: host.scheduleGuestStatusRefresh(after: 60)
        }
    }
}
