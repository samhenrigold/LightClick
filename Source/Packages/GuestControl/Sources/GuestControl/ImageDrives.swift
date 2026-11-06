// A running guest's image drives: what's in each, which extra drives exist, and the emulator commands that change them.
//
// Slot 0 is the drive the guest boots with. Slots above it are USB Bulk-Only devices, created the first time they're used
// and removed when emptied. A drive's contents here are what the emulator has, which can differ from the saved settings.

import Foundation

/// Issues control commands in order, answering each on the main thread. `VIMQMPConnection` is the real one.
@MainActor public protocol ControlCommands: AnyObject {
    func run(_ command: String, arguments: [String: Any], completion: @escaping @MainActor (Any?, NSError?) -> Void)
}

extension QMPConnectionBridge: ControlCommands {
    public func run(
        _ command: String, arguments: [String: Any], completion: @escaping @MainActor (Any?, NSError?) -> Void
    ) {
        execute(command, arguments: arguments) { result, error in
            nonisolated(unsafe) let result = result
            MainActor.assumeIsolated { completion(result, error) }
        }
    }
}

extension ControlCommands {
    @discardableResult
    func run(_ command: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            run(command, arguments: arguments) { result, error in
                nonisolated(unsafe) let result = result
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}

/// An error whose message is the user's to read, in the session's domain.
func sessionError(_ message: String) -> NSError {
    NSError(domain: "VirtualIntelMac.Session", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

@MainActor @objc(VIMImageDrives)
public final class ImageDrives: NSObject {
    private struct Media: Equatable {
        let path: String
        let format: String
    }

    private let control: any ControlCommands
    private let bus: String
    private let basePort: Int
    private let slotCount: Int
    private var media: [Int: Media] = [:]
    /// Extra drives the emulator has now, which outlive their media until disconnected.
    private var devices: Set<Int> = []

    /// A change is under way. Tray events it causes aren't the guest ejecting anything.
    @objc public private(set) var changePending = false
    /// Words a failed change for the user, given the image it was for. Not used for a change refused before it began.
    @objc public var describeFailure: ((String, NSError) -> NSError)?

    /// - Parameter basePort: The USB port slot 0 would have. Extra drives claim ports above it, up to the last slot's.
    public init(control: any ControlCommands, bus: String, basePort: Int, slotCount: Int) {
        self.control = control
        self.bus = bus
        self.basePort = basePort
        self.slotCount = slotCount
    }

    @objc(initWithControl:bus:basePort:slotCount:)
    public convenience init(bridge: QMPConnectionBridge, bus: String, basePort: Int, slotCount: Int) {
        self.init(control: bridge, bus: bus, basePort: basePort, slotCount: slotCount)
    }

    /// The name of the device that holds `format` in `slot`. Slot 0 has a separate device for each kind of image.
    public static func deviceName(slot: Int, format: String?) -> String {
        if slot == 0 { return format == "dmg" ? "image-device" : "cdrom-device" }
        return "image-disk-\(slot)"
    }

    private static func transportName(slot: Int) -> String { "image-usb-\(slot)" }

    /// Records what the emulator is starting with. An extra drive is on its command line, so its device exists.
    @objc(startWithImage:format:slot:)
    public func start(with path: String, format: String, slot: Int) {
        media[slot] = Media(path: path, format: format)
        if slot > 0 { devices.insert(slot) }
    }

    /// `Path` and `Format` of what's in the drive now.
    @objc(mediaInSlot:)
    public func media(inSlot slot: Int) -> [String: String]? {
        media[slot].map { ["Path": $0.path, "Format": $0.format] }
    }

    /// The guest opened a tray. Empties the drive it belongs to, and returns what was removed by slot, for the settings to
    /// forget. Nothing during a change of ours, whose own ejects report here too.
    @objc(trayOpenedOnDevice:)
    public func trayOpened(onDevice device: String?) -> [NSNumber: String] {
        guard !changePending, let device else { return [:] }
        var removed: [NSNumber: String] = [:]
        for slot in 0..<slotCount where device == Self.deviceName(slot: slot, format: media[slot]?.format) {
            if let path = media.removeValue(forKey: slot)?.path { removed[slot as NSNumber] = path }
        }
        return removed
    }

    /// The guest or emulator finished removing a device.
    @objc(deviceDeleted:)
    public func deviceDeleted(_ device: String?) {
        for slot in 1..<max(1, slotCount) where device == Self.transportName(slot: slot) { devices.remove(slot) }
    }

    /// Connects an image, or with an empty path, disconnects what's there. The completion runs on main.
    @objc(changeImage:format:slot:completion:)
    public func change(path: String, format: String?, slot: Int, completion: @escaping (NSError?) -> Void) {
        guard !changePending else {
            completion(sessionError("Wait for the current disc change to finish, then try again."))
            return
        }
        changePending = true
        Task {
            var failure: NSError?
            do {
                try await apply(path: path, format: format ?? "raw", slot: slot)
            } catch {
                failure = Self.explained(error as NSError)
            }
            changePending = false
            if let describeFailure, let error = failure, !path.isEmpty { failure = describeFailure(path, error) }
            completion(failure)
        }
    }

    private func apply(path: String, format: String, slot: Int) async throws {
        let previous = media[slot]
        if path.isEmpty {
            if let previous {
                try await control.run("eject", ["id": Self.deviceName(slot: slot, format: previous.format)])
            }
            if slot > 0 && devices.contains(slot) {
                try await control.run("device_del", ["id": Self.transportName(slot: slot)])
                devices.remove(slot)
            }
            media[slot] = nil
            return
        }
        if let previous {
            if previous.path == path { return }
            throw sessionError("Disconnect this drive’s current image before choosing another.")
        }
        try await createDeviceIfNeeded(slot: slot)
        try await control.run(
            "blockdev-change-medium",
            [
                "id": Self.deviceName(slot: slot, format: format), "filename": path, "format": format,
                "read-only-mode": "read-only"
            ])
        media[slot] = Media(path: path, format: format)
    }

    private func createDeviceIfNeeded(slot: Int) async throws {
        guard slot > 0, !devices.contains(slot) else { return }
        let transport = Self.transportName(slot: slot)
        let backend = "image-backend-\(slot)"
        // QMP blockdev-add creates a media node, not an empty BlockBackend. QEMU's fixed native drive_add command creates
        // that removable backend; no shell, user-supplied monitor text or filename is passed through HMP.
        let reply = try await control.run(
            "human-monitor-command",
            ["command-line": "drive_add 0 id=\(backend),if=none,media=disk,readonly=on"])
        guard (reply as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
            throw sessionError("The virtual image drive could not be created.")
        }
        var transportCreated = false
        do {
            try await claimPort(transport: transport)
            transportCreated = true
            try await control.run(
                "device_add",
                [
                    "driver": "scsi-hd", "id": Self.deviceName(slot: slot, format: "raw"), "bus": transport + ".0",
                    "drive": backend, "removable": true, "logical_block_size": 512, "physical_block_size": 512
                ])
            // Hot-plugged usb-bot stays detached until its child is ready.
            try await control.run(
                "qom-set", ["path": "/machine/peripheral/" + transport, "property": "attached", "value": true])
            devices.insert(slot)
        } catch {
            if transportCreated { _ = try? await control.run("device_del", ["id": transport]) }
            _ = try? await control.run("human-monitor-command", ["command-line": "drive_del " + backend])
            throw error
        }
    }

    /// Explicit root ports avoid QEMU silently adding its USB1 hub on the last free port. Only an occupied port is retried.
    private func claimPort(transport: String) async throws {
        var port = basePort + 1
        while true {
            do {
                try await control.run(
                    "device_add", ["driver": "usb-bot", "id": transport, "bus": bus, "port": String(port)])
                return
            } catch let error as NSError {
                guard port < basePort + slotCount - 1, error.localizedDescription.contains("not found (in use?)") else {
                    throw error
                }
                port += 1
            }
        }
    }

    private static func explained(_ error: NSError) -> NSError {
        guard error.localizedDescription.localizedLowercase.contains("locked") else { return error }
        return NSError(
            domain: "VirtualIntelMac.Media", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "This disc is in use",
                NSLocalizedRecoverySuggestionErrorKey:
                    "In the virtual Mac, eject the disc in Finder, then try again. Close any apps using it first. Your "
                    + "image hasn’t been changed.",
                NSUnderlyingErrorKey: error
            ])
    }
}
