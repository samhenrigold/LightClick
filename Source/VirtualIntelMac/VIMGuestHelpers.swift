import AppKit
import GuestControl
import MachineKit

extension VIMClipboardBridge: GuestHelperTransport {}

/// A session's guest helpers: the serial bridges, the guest agent and the settings. MachineKit decides when they run.
@MainActor @objc(VIMGuestHelpers)
final class GuestHelpers: NSObject, GuestHelperHost {
    private unowned let session: VIMSession
    private lazy var links = GuestHelperLinks(host: self)

    @objc init(session: VIMSession) {
        self.session = session
    }

    @objc func update(boot: String?) { links.update(boot: boot) }
    @objc func updateDisplayPower(boot: String?) { links.update(.displayPower, boot: boot) }
    @objc func forgetClipboard() { links.forgetClipboard() }
    @objc func stop() { links.stop() }

    private var clipboardBridge: VIMClipboardBridge? { links.transport(.clipboard) as? VIMClipboardBridge }

    private var mayExchangeClipboard: Bool {
        session.task?.isRunning == true && NSApp.isActive && session.window?.isKeyWindow == true
            && session.displayView?.displaySleeping == false && links.clipboardSharingEnabled
    }

    @objc var displayPowerDiagnostics: [String: Any] {
        let bridge = links.transport(.displayPower) as? VIMClipboardBridge
        return ["Connected": bridge?.isConnected ?? false, "Transport": bridge?.diagnosticState() ?? [:]]
    }

    @objc var clipboardDiagnostics: [String: Any] {
        [
            "Enabled": isClipboardAllowedBySettings,
            "Connected": clipboardBridge?.isConnected ?? false,
            "ExchangeAllowed": clipboardBridge != nil && mayExchangeClipboard,
            "ApplicationActive": NSApp.isActive,
            "WindowKey": session.window?.isKeyWindow ?? false,
            "DisplaySleeping": session.displayView?.displaySleeping ?? false,
            "Provisioning": sessionState.clipboardPending,
            "Failure": links.clipboardFailure ?? "",
            "Transport": clipboardBridge?.diagnosticState() ?? [:]
        ]
    }

    // MARK: GuestHelperHost

    var isRunning: Bool { session.task?.isRunning == true }
    var sessionState: GuestSessionStateBridge { session.currentSessionState() as! GuestSessionStateBridge }
    var runtimeDirectory: String { session.runtimeDirectory ?? "" }
    var isPreMetalGuest: Bool { session.machine?.preMetalGuest == true }

    var isClipboardAllowedBySettings: Bool {
        let setting = session.machine?.editableConfiguration["ClipboardEnabled"]
        return setting == nil || setting as? NSNumber == true as NSNumber
    }

    var acceptsDisplayPowerRequests: Bool { session.displayView?.softwareCursor != true && !isPreMetalGuest }

    func makeTransport(
        _ kind: GuestHelperKind, connectionLost: @escaping @MainActor (any GuestHelperTransport) -> Void
    ) -> any GuestHelperTransport {
        let bridge = VIMClipboardBridge()
        let displayPower = kind == .displayPower
        bridge.displayPowerOnly = displayPower
        // Asked by the 200 ms pasteboard timer and on every receive. Settings changes call `update`, so this hot path
        // never reads PendingConfiguration.plist from a removable disk.
        bridge.exchangeAllowed = { [weak self] in
            MainActor.assumeIsolated { !displayPower && self?.mayExchangeClipboard == true }
        }
        bridge.displayPowerChanged = { [weak self] sleeping in
            MainActor.assumeIsolated {
                if displayPower { self?.session.requestGuestDisplaySleeping(sleeping) }
            }
        }
        bridge.connectionLost = { [weak bridge] in
            MainActor.assumeIsolated {
                if let bridge { connectionLost(bridge) }
            }
        }
        return bridge
    }

    func provision(
        _ kind: GuestHelperKind, configuration: Data, file: URL, stillWanted: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        guard let agent = session.guestAgentConnection as? GuestAgentBridge else { return completion("transfer") }
        if isPreMetalGuest {
            agent.provisionInstalledHelper(configuration: configuration, completion: completion)
            return
        }
        agent.provisionHelper(
            VIMGuestFileURL("GuestTools")!.appendingPathComponent("guest-clipboard"), configuration: file,
            named: file.lastPathComponent, stillWanted: stillWanted, completion: completion)
    }

    func displayObserverWentAway() { session.requestGuestDisplaySleeping(false) }
    func refreshGuestStatus() { session.refreshGuestStatus() }
    func restoreDisplaySelection(boot: String) { session.restoreDisplaySelection(forBoot: boot) }
    func log(_ message: String) { session.logMessage(message) }
}
