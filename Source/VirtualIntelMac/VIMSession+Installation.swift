import AppKit
import GuestControl
import MachineKit

extension GuestAgentBridge: @retroactive GuestCommandRunning {
    public func run(_ path: String, arguments: [String], timeout: TimeInterval) async throws -> GuestCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            runExecutable(path, arguments: arguments, timeout: timeout) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: GuestCommandResult(foundationObject: result))
                }
            }
        }
    }
}

/// A session and the report a graphics installation step started from.
@MainActor
private final class SessionInstallationHost: GuestInstallationHost {
    let session: VIMSession
    let report: [String: Any]

    init(session: VIMSession, report: [String: Any]) {
        self.session = session
        self.report = report
    }

    private var machineURL: URL { session.machine!.url }
    private var agent: GuestAgentBridge? { session.guestAgentConnection as? GuestAgentBridge }

    var isRunning: Bool { session.task?.isRunning == true }
    var sessionState: GuestSessionStateBridge { session.currentSessionState() as! GuestSessionStateBridge }
    var runner: any GuestCommandRunning { agent! }  // A status report just came through it.
    var installationJournal: URL { machineURL.appendingPathComponent("State/GuestInstallation.plist") }
    var hasInstallerMedia: Bool { session.machine?.configuration["InstallerMedia"] != nil }
    var requiresInstallerDisplay: Bool { session.machine?.requiresInstallerDisplay == true }

    var statusText: String {
        get { session.guestStatus.stringValue }
        set { session.guestStatus.stringValue = newValue }
    }
    var windowSubtitle: String {
        get { session.window?.subtitle ?? "" }
        set { session.window?.subtitle = newValue }
    }
    var isPreparing: Bool {
        get { session.preparing }
        set { session.preparing = newValue }
    }
    var preparationRequested: Bool {
        get { session.preparationRequested }
        set { session.preparationRequested = newValue }
    }
    var installationRequested: Bool {
        get { session.installationRequested }
        set { session.installationRequested = newValue }
    }
    var repairArchivePending: Bool {
        get { session.repairArchivePending }
        set { session.repairArchivePending = newValue }
    }

    var canRepairUpdatedSystem: Bool {
        (try? session.machine?.canRepairUpdatedSystem(withGuestReport: report)) != nil
    }
    func keepCompletionReport() { session.completionGuestReport = report }
    func clearCompletionReport() { session.completionGuestReport = nil }

    func prepareGuestFiles(
        allowHeadlessRepair: Bool, progress: @escaping @MainActor (String) -> Void
    ) async -> (receipt: [String: PropertyListValue]?, failure: (any Error)?) {
        await withCheckedContinuation { continuation in
            VIMGuestPreparation.prepare(
                withAgent: agent as Any, report: report,
                runtime: Bundle.main.resourceURL!.appendingPathComponent("Runtime"),
                journal: machineURL.appendingPathComponent("State/GuestPreparation.plist"),
                control: session.controlConnection as Any, allowHeadlessRepair: allowHeadlessRepair,
                progress: { message in MainActor.assumeIsolated { progress(message) } },
                completion: { receipt, failure in
                    continuation.resume(
                        returning: (
                            (receipt as? [String: Any])?.mapValues(PropertyListValue.init(foundationObject:)), failure
                        ))
                })
        }
    }

    func connectGuestProgress(receipt: PropertyListValue?) {
        session.guestProgress = agent.flatMap { GuestProgress.progress(agent: $0, receipt: receipt?.foundationObject) }
    }

    func updateGuestProgress(mode: String, fraction: Double, message: String) {
        (session.guestProgress as? GuestProgress)?.update(
            mode: mode, fraction: fraction, message: message, completion: nil)
    }

    func ejectInstallerVolumes() {
        let session = session
        agent?.ejectEmulatedVolumes(
            [
                "/Volumes/macOS Base System", "/Volumes/Install macOS Mojave", "/Volumes/Install macOS Catalina",
                "/Volumes/Install macOS Big Sur"
            ],
            while: { [weak session] in session?.task?.isRunning == true && session?.completionGuestReport != nil })
    }

    func log(_ message: String) { session.logMessage(message) }
    func present(_ error: any Error) { VIMPresentError(error, session.window) }
    func failCreatingGuest(_ message: String) { VIMFailCreateGuest(message) }
    func showInstallationNotice() { session.showSetupNoticeAutomatic(false, automaticLogin: false, restarting: false) }
    func dismissSetupNotice() { session.dismissSetupNotice() }
    func showHeadlessRepairProgress(_ message: String) { session.showHeadlessRepairProgress(message) }
    func refreshGuestStatus() { session.refreshGuestStatus() }
    func scheduleGuestStatusRetry() { session.scheduleGuestStatusRetry() }
    func scheduleGuestStatusRefresh(after delay: TimeInterval) { session.scheduleGuestStatusRefresh(after: delay) }
    func resumeDesktopServices(boot: String) {
        session.updateClipboard(forBoot: boot)
        session.restoreDisplaySelection(forBoot: boot)
    }
    func handOffToGraphics() { session.handoffToGraphics() }
    func offerGraphicsRestart() { session.offerGraphicsRestart() }
}

extension VIMSession {
    private func installationFlow(_ report: [String: Any]) -> GuestInstallationFlow {
        GuestInstallationFlow(
            host: SessionInstallationHost(session: self, report: report),
            report: GuestReport(foundationObject: report) ?? GuestReport(values: [:]))
    }

    @objc func beginRepair(report: [String: Any]) { installationFlow(report).beginRepair() }
    @objc func beginReconciliation(report: [String: Any]) { installationFlow(report).beginReconciliation() }
    @objc func beginPreparation(report: [String: Any]) { installationFlow(report).beginPreparation() }
}
