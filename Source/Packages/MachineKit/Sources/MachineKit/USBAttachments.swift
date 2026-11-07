import Foundation

/// A device's disks as the host sees them right now.
public struct USBStorage: Sendable, Equatable {
    /// The device holds the app, the library or a running machine, so it may never be unmounted.
    public var isProtected: Bool
    public var hasMountedVolumes: Bool

    public init(isProtected: Bool, hasMountedVolumes: Bool) {
        self.isProtected = isProtected
        self.hasMountedVolumes = hasMountedVolumes
    }
}

public enum USBConnectionError: LocalizedError, Equatable {
    case stopped
    case isProtected
    case unmountNotConfirmed
    /// Someone said no to an unmount. Nothing to show.
    case declined

    public var errorDescription: String? {
        switch self {
        case .stopped: "This virtual Mac has stopped."
        case .isProtected:
            "This device contains Light Click, a virtual Mac, or its library and cannot be unmounted. Move those files "
                + "to another drive first."
        case .unmountNotConfirmed: "Explicit normal-unmount confirmation is required."
        case .declined: nil
        }
    }
}

/// One device, as the host, the USB helper and the running emulator see it.
@MainActor
public protocol USBDeviceHost {
    var isRunning: Bool { get }
    func storage() throws -> USBStorage
    func requestStorageAccess() async throws
    func releaseDisks(force: Bool) async throws
    func prepareCapture() async throws
    func capture() async throws
    func disconnect() async throws
}

public enum USBUnmountChoice: Sendable {
    case unmount, cancel, forceUnmount
}

/// The questions connecting a mounted device asks whoever is at the Mac.
@MainActor
public protocol USBConnectionPrompts {
    func confirmUnmount(of name: String) async -> USBUnmountChoice
    func confirmForceUnmount(of name: String) async -> Bool
    func offerForceUnmountAfterFailure(of name: String) async -> Bool
    func present(_ error: any Error)
}

/// A session's USB devices: which are attached, whether an operation is under way, and the order an attachment goes in.
/// Nothing is pending while a prompt waits for a person.
@MainActor
public final class USBAttachments {
    /// Name by identifier. Nil until something is attached and after `reset()`, which keeps an operation that outlives
    /// its emulator from recording anything.
    public private(set) var attached: [String: String]?
    public private(set) var isPending = false

    public init() {}

    public func reset() {
        isPending = false
        attached = nil
    }

    /// What choosing a device in the menu does.
    public func toggle(identifier: String, name: String, host: any USBDeviceHost, prompts: any USBConnectionPrompts)
        async
    {
        guard !isPending, host.isRunning else { return }
        if attached == nil { attached = [:] }
        do {
            if attached?[identifier] != nil {
                try await disconnect(identifier: identifier, host: host)
                return
            }
            var force: Bool?
            if try unprotectedStorage(host).hasMountedVolumes {
                switch await prompts.confirmUnmount(of: name) {
                case .cancel: return
                case .unmount: force = false
                case .forceUnmount:
                    guard await prompts.confirmForceUnmount(of: name) else { return }
                    force = true
                }
            }
            try await attach(identifier: identifier, name: name, releasing: force, host: host, prompts: prompts)
        } catch USBConnectionError.stopped, USBConnectionError.declined {
            // The machine went away or the answer was no. Neither is a failure to report.
        } catch {
            prompts.present(error)
        }
    }

    /// An automated connect, which can confirm a normal unmount in advance and never a forced one.
    public func connect(identifier: String, name: String, confirmedUnmount: Bool, host: any USBDeviceHost) async throws
    {
        let mounted = try unprotectedStorage(host).hasMountedVolumes
        if mounted && !confirmedUnmount { throw USBConnectionError.unmountNotConfirmed }
        if attached == nil { attached = [:] }
        try await attach(identifier: identifier, name: name, releasing: mounted ? false : nil, host: host, prompts: nil)
    }

    public func disconnect(identifier: String, host: any USBDeviceHost) async throws {
        isPending = true
        defer { isPending = false }
        try await host.disconnect()
        attached?[identifier] = nil
    }

    private func unprotectedStorage(_ host: any USBDeviceHost) throws -> USBStorage {
        let storage = try host.storage()
        if storage.isProtected { throw USBConnectionError.isProtected }
        return storage
    }

    /// Consent comes before any unmount, and the disks go before capture. `force` is nil for a device with nothing
    /// mounted. Without `prompts` a failed unmount is final.
    private func attach(
        identifier: String, name: String, releasing force: Bool?, host: any USBDeviceHost,
        prompts: (any USBConnectionPrompts)?
    ) async throws {
        isPending = true
        defer { isPending = false }
        try await host.requestStorageAccess()
        try ensureRunning(host)
        if let force { try await release(name: name, force: force, host: host, prompts: prompts) }
        try ensureRunning(host)
        try await host.prepareCapture()
        try ensureRunning(host)
        try await host.capture()
        attached?[identifier] = name
    }

    private func release(name: String, force: Bool, host: any USBDeviceHost, prompts: (any USBConnectionPrompts)?)
        async throws
    {
        do {
            try await host.releaseDisks(force: force)
        } catch {
            guard !force, let prompts else { throw error }
            isPending = false
            guard await prompts.offerForceUnmountAfterFailure(of: name) else { throw USBConnectionError.declined }
            try ensureRunning(host)
            isPending = true
            try await host.releaseDisks(force: true)
        }
    }

    private func ensureRunning(_ host: any USBDeviceHost) throws {
        guard host.isRunning else { throw USBConnectionError.stopped }
    }
}
