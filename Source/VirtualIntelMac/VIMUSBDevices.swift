import AppKit
import InstallerKit
import MachineKit

/// Waits for an Objective-C completion's answer.
@MainActor
private func answer(_ work: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        work { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}

/// A session's USB menu and automation: the helper client, the alerts, and the attachments MachineKit keeps.
@MainActor @objc(VIMUSBDevices)
final class USBDevices: NSObject, USBConnectionPrompts {
    private unowned let session: VIMSession
    private let attachments = USBAttachments()
    private var client: VIMUSBClient?

    @objc init(session: VIMSession) {
        self.session = session
    }

    @objc var attached: [String: String]? { attachments.attached }
    @objc var operationPending: Bool { attachments.isPending }

    private var ensuredClient: VIMUSBClient {
        if let client { return client }
        let client = VIMUSBClient()
        client.useUSB2Storage =
            session.machine.flatMap { Guest(rawValue: $0.guest) }?.traits.contains(.usb2StoragePassthrough) == true
        self.client = client
        return client
    }

    @objc func stop() {
        client?.stop()
        client = nil
        attachments.reset()
    }

    @objc func deviceWasDeleted(_ identifier: String?) {
        client?.deviceWasDeleted(identifier ?? "", control: session.controlConnection as Any)
    }

    @objc func toggle(_ device: [String: Any]) {
        Task {
            await attachments.toggle(
                identifier: device["Identifier"] as? String ?? "", name: device["Name"] as? String ?? "",
                host: host(for: device),
                prompts: self)
        }
    }

    private func host(for device: [String: Any]) -> DeviceHost {
        DeviceHost(device: device, session: session) { [unowned self] in ensuredClient }
    }

    // MARK: Prompts

    private func ask(_ message: String, _ detail: String, buttons: [String]) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        for button in buttons { alert.addButton(withTitle: button) }
        return await withCheckedContinuation { continuation in
            VIMPresentAlert(alert, session.window) { continuation.resume(returning: $0) }
        }
    }

    func confirmUnmount(of name: String) async -> USBUnmountChoice {
        let response = await ask(
            "Connect “\(name)” to this virtual Mac?",
            "Its disks must first be unmounted from this Mac. Save your work on this device before continuing. They’ll "
                + "be available to the virtual Mac instead.",
            buttons: ["Unmount and Connect", "Cancel", "Force Unmount…"])
        switch response {
        case .alertFirstButtonReturn: return .unmount
        case .alertSecondButtonReturn: return .cancel
        default: return .forceUnmount
        }
    }

    func confirmForceUnmount(of name: String) async -> Bool {
        await ask(
            "Force unmount “\(name)”?",
            "Unsaved changes on this device may be lost. Close apps using it first if possible.",
            buttons: ["Force Unmount and Connect", "Cancel"]) == .alertFirstButtonReturn
    }

    func offerForceUnmountAfterFailure(of name: String) async -> Bool {
        await ask(
            "“\(name)” couldn’t be unmounted",
            "Close apps using this device and try again, or force unmount it to connect it to the virtual Mac. Forcing "
                + "an unmount can lose unsaved changes on the device.",
            buttons: ["Cancel", "Force Unmount and Connect"]) == .alertSecondButtonReturn
    }

    func present(_ error: any Error) {
        VIMPresentError(error, session.window)
    }

    // MARK: Automation

    /// Answers one of the diagnostics channel's USB actions, or returns false if `command` is another kind.
    @objc func handleDiagnostic(_ command: [String: Any], finish: @escaping @Sendable ([String: Any]) -> Void) -> Bool {
        let action = command["Action"] as? String
        switch action {
        case "usb-devices":
            finish(["Devices": VIMHostUSBDevices() ?? [], "Attached": attached ?? [:]])
        case "usb-storage-access":
            withDevice(command, finish) { device in
                VIMHostRequestUSBStorageAccess(device, DeviceHost.protectedLocations) { error in
                    finish(
                        error.map { ["Error": $0.localizedDescription] }
                            ?? ["PreflightCompleted": true, "CaptureVerified": false])
                }
            }
        case "usb-interface-policy":
            withDevice(command, finish) { device in
                ensuredClient.checkStorageInterface(device, inUserSession: command["UserSession"] as? Bool == true) {
                    result, error in
                    finish(error.map { ["Error": $0.localizedDescription] } ?? result as? [String: Any] ?? [:])
                }
            }
        case "usb-connect", "usb-disconnect":
            guard session.task?.isRunning == true, !operationPending else {
                finish(["Error": "USB is not ready for another operation."])
                break
            }
            withDevice(command, finish) { device in
                let identifier = device["Identifier"] as? String ?? ""
                let host = host(for: device)
                Task {
                    do {
                        if action == "usb-disconnect" {
                            try await attachments.disconnect(identifier: identifier, host: host)
                        } else {
                            try await attachments.connect(
                                identifier: identifier, name: device["Name"] as? String ?? "",
                                confirmedUnmount: command["Unmount"] as? Bool == true, host: host)
                        }
                        finish(["Attached": attached ?? [:]])
                    } catch {
                        finish(["Error": error.localizedDescription])
                    }
                }
            }
        default:
            return false
        }
        return true
    }

    private func withDevice(
        _ command: [String: Any], _ finish: ([String: Any]) -> Void, _ work: ([String: Any]) -> Void
    ) {
        let location = command["LocationID"] as? NSNumber
        guard let location,
            let device = (VIMHostUSBDevices() as? [[String: Any]])?.last(where: {
                $0["LocationID"] as? NSNumber == location
            })
        else {
            finish(["Error": "The requested physical USB device is not connected."])
            return
        }
        work(device)
    }
}

/// One device, through the host's disk arbitration, the USB helper and the session's emulator.
@MainActor
private struct DeviceHost: USBDeviceHost {
    let device: [String: Any]
    let session: VIMSession
    let client: () -> VIMUSBClient

    static var protectedLocations: [URL] {
        [Bundle.main.bundleURL, LibraryLocationBridge.rootURL] + VIMSession.machineURLs
    }

    var isRunning: Bool { session.task?.isRunning == true }

    func storage() throws -> USBStorage {
        var failure: NSError?
        guard let info = VIMHostUSBStorageInfo(device, Self.protectedLocations, &failure) else {
            throw failure ?? USBConnectionError.isProtected
        }
        return USBStorage(
            isProtected: (info["Protected"] as? NSNumber)?.boolValue ?? false,
            hasMountedVolumes: (info["MountedVolumes"] as? [Any])?.isEmpty == false)
    }

    func requestStorageAccess() async throws {
        try await answer { VIMHostRequestUSBStorageAccess(device, Self.protectedLocations, $0) }
    }

    func releaseDisks(force: Bool) async throws {
        try await answer { VIMHostReleaseUSBDisks(device, Self.protectedLocations, force, $0) }
    }

    func prepareCapture() async throws {
        try await answer { client().prepare(completion: $0) }
    }

    func capture() async throws {
        try await answer { done in
            client().connectDevice(
                device, processID: session.task?.processIdentifier ?? 0, directory: session.runtimeDirectory ?? "",
                control: session.controlConnection as Any, completion: done)
        }
    }

    func disconnect() async throws {
        try await answer { done in
            client().disconnectDevice(
                device["Identifier"] as? String ?? "", control: session.controlConnection as Any, completion: done)
        }
    }
}
