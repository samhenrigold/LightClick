import Foundation

/// The two helpers a session runs in its guest. Each has its own private serial channel and its own lifetime.
public enum GuestHelperKind: Sendable {
    /// Reports display sleep. It never touches a pasteboard.
    case displayPower
    case clipboard

    var socketName: String { self == .displayPower ? "displaypower" : "clipboard" }
    var configurationName: String { self == .displayPower ? "DisplayPower.json" : "Clipboard.json" }
    var failureName: String { self == .displayPower ? "display-power observer" : "clipboard" }
}

/// One helper's host end of its serial channel.
@MainActor
public protocol GuestHelperTransport: AnyObject {
    var token: String { get }
    var isConnected: Bool { get }
    func start(withSocketPath path: String) throws
    func awaitGuestHandshake()
    func stop()
}

/// What the links need from their session.
@MainActor
public protocol GuestHelperHost: AnyObject {
    var isRunning: Bool { get }
    /// Flags as they are right now.
    var sessionState: GuestSessionStateBridge { get }
    var runtimeDirectory: String { get }
    var isPreMetalGuest: Bool { get }
    var isClipboardAllowedBySettings: Bool { get }
    /// Installer VGA's legacy wire reader doesn't implement PVG power requests, so they aren't sent to it.
    var acceptsDisplayPowerRequests: Bool { get }
    /// `connectionLost` is for an unexpected loss: an explicit stop doesn't call it.
    func makeTransport(
        _ kind: GuestHelperKind, connectionLost: @escaping @MainActor (any GuestHelperTransport) -> Void
    ) -> any GuestHelperTransport
    /// Calls `completion` with the name of the step that failed, or nil.
    func provision(
        _ kind: GuestHelperKind, configuration: Data, file: URL, stillWanted: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (String?) -> Void)
    func displayObserverWentAway()
    func refreshGuestStatus()
    func restoreDisplaySelection(boot: String)
    func log(_ message: String)
}

/// When each guest helper is started, retried and given up on. A helper is provisioned once per boot, a failed start
/// waits a minute, and an old provisioning's answer is ignored once its transport has been replaced.
@MainActor
public final class GuestHelperLinks {
    private struct Link {
        var transport: (any GuestHelperTransport)?
        var configuredBoot: String?
        var retryAfter: Date?
    }

    private unowned let host: any GuestHelperHost
    private var displayPower = Link()
    private var clipboard = Link()
    private static let retryDelay: TimeInterval = 60

    /// The settings' answer as of the last update. It's read on every pasteboard check, so that never reads a file.
    public private(set) var clipboardSharingEnabled = false
    public private(set) var clipboardFailure: String?

    public init(host: any GuestHelperHost) {
        self.host = host
    }

    public func transport(_ kind: GuestHelperKind) -> (any GuestHelperTransport)? { link(kind).transport }

    private func link(_ kind: GuestHelperKind) -> Link { kind == .displayPower ? displayPower : clipboard }

    private func change(_ kind: GuestHelperKind, _ body: (inout Link) -> Void) {
        if kind == .displayPower {
            body(&displayPower)
        } else {
            body(&clipboard)
        }
    }

    /// The display observer first: the clipboard provisions after it, without racing it for the guest agent.
    public func update(boot: String?) {
        update(.displayPower, boot: boot)
        update(.clipboard, boot: boot)
    }

    public func update(_ kind: GuestHelperKind, boot: String?) {
        if kind == .displayPower && !host.acceptsDisplayPowerRequests { return }
        if kind == .clipboard {
            clipboardSharingEnabled = host.isClipboardAllowedBySettings
            if !clipboardSharingEnabled {
                forgetClipboard()
                return
            }
        }
        let state = host.sessionState
        guard let boot, !boot.isEmpty, kind == .displayPower || state.consoleUID != nil, state.mayProvisionHelpers
        else { return }
        let current = link(kind)
        if current.transport?.isConnected == true && current.configuredBoot == boot { return }
        if let retryAfter = current.retryAfter, retryAfter > Date() { return }
        let transport =
            current.transport
            ?? host.makeTransport(kind) { [weak self] lost in self?.connectionLost(kind, lost) }
        change(kind) { $0.transport = transport }
        let directory = host.runtimeDirectory as NSString
        do {
            try transport.start(withSocketPath: directory.appendingPathComponent(kind.socketName))
        } catch {
            transport.stop()
            change(kind) {
                $0.transport = nil
                $0.retryAfter = Date(timeIntervalSinceNow: Self.retryDelay)
            }
            return
        }
        let file = URL(fileURLWithPath: directory.appendingPathComponent(kind.configurationName))
        guard let configuration = configuration(kind, token: transport.token),
            (try? configuration.write(to: file, options: .atomic)) != nil
        else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        state.clipboardPending = true
        change(kind) { $0.retryAfter = Date(timeIntervalSinceNow: Self.retryDelay) }
        let token = transport.token
        host.provision(
            kind, configuration: configuration, file: file,
            stillWanted: { [weak self] in
                guard let self else { return false }
                return host.isRunning && link(kind).transport?.token == token
            },
            completion: { [weak self] failedStep in
                self?.finishProvisioning(kind, boot: boot, token: token, failedStep: failedStep)
            })
    }

    private func configuration(_ kind: GuestHelperKind, token: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "UID": host.sessionState.consoleUID ?? 0,
            "Transport": host.isPreMetalGuest ? "isa-serial" : "virtio-serial",
            "Token": token,
            "DisplayPowerOnly": kind == .displayPower
        ])
    }

    private func finishProvisioning(_ kind: GuestHelperKind, boot: String, token: String, failedStep: String?) {
        host.sessionState.clipboardPending = false
        guard let transport = link(kind).transport, transport.token == token else { return }
        if let failedStep {
            let message = "Guest \(kind.failureName) \(failedStep) did not finish."
            if clipboardFailure != message { host.log(message) }
            transport.stop()
            change(kind) { $0.transport = nil }
            if kind == .clipboard { clipboardFailure = message }
            return
        }
        change(kind) { $0.configuredBoot = boot }
        if kind == .clipboard { clipboardFailure = nil }
        transport.awaitGuestHandshake()
        switch kind {
        case .displayPower:
            // Display setup has released the guest agent, so the clipboard needn't wait another minute.
            update(.clipboard, boot: boot)
        case .clipboard:
            host.restoreDisplaySelection(boot: boot)
        }
    }

    private func connectionLost(_ kind: GuestHelperKind, _ lost: any GuestHelperTransport) {
        guard host.isRunning, link(kind).transport === lost else { return }
        lost.stop()
        change(kind) {
            $0.transport = nil
            $0.configuredBoot = nil
            $0.retryAfter = Date(timeIntervalSinceNow: Self.retryDelay)
        }
        if kind == .displayPower {
            host.displayObserverWentAway()
        } else {
            // After a logout, the old UID and token are no authority to restart a GUI helper. Look at the console again.
            host.sessionState.consoleUID = nil
            host.sessionState.usernameBoot = nil
        }
        host.refreshGuestStatus()
    }

    /// The clipboard's settings or its console user changed.
    public func forgetClipboard() {
        clipboard.transport?.stop()
        clipboard = Link()
    }

    /// The emulator has gone, and a retry time from its run says nothing about the next one's.
    public func stop() {
        forgetClipboard()
        host.sessionState.clipboardPending = false
        displayPower.transport?.stop()
        displayPower = Link()
    }
}
