// The Objective-C face of QMPConnection and GuestAgent. These classes take the names, selectors and dictionary shapes of
// VIMQMPConnection and VIMGuestAgent, to replace those two classes without changing their callers. They can't be linked
// alongside the originals. A class name can't be aliased instead, since callers' headers forward-declare it with @class.
//
// The methods take explicit completion handlers rather than being `@objc async`. The compiler's thunk for an async method
// starts it in a task that isn't enqueued in call order, so a burst of input events could reach the emulator reordered.
// Every method here enqueues its work before returning. Completions always run on the main thread.

import Foundation

/// Events go through here so the connection's observer can exist before the bridge does.
@MainActor private final class LifecycleEventRelay {
    var handler: (([String: Any]) -> Void)?

    nonisolated init() {}
}

@objc(VIMQMPConnection)
public final class QMPConnectionBridge: NSObject {
    private let connection: QMPConnection
    private let relay: LifecycleEventRelay

    /// Lifecycle events observed on the existing connection, delivered on main. Set before connecting. No second socket
    /// or additional polling is used.
    @MainActor @objc public var lifecycleEventHandler: (([String: Any]) -> Void)? {
        get { relay.handler }
        set { relay.handler = newValue }
    }

    private init(socketPath: String, mode: QMPConnection.Mode) {
        let relay = LifecycleEventRelay()
        self.relay = relay
        // The same main queue that completions use: an event precedes the result of the command that read it, and
        // every observed SHUTDOWN reason reaches the owner before its termination decision.
        connection = QMPConnection(socketPath: socketPath, mode: mode) { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { relay.handler?(event.fields.mapValues(\.foundationObject)) }
            }
        }
    }

    @objc(initWithSocketPath:)
    public convenience init(socketPath: String) {
        self.init(socketPath: socketPath, mode: .qmp)
    }

    /// QGA has no greeting and Apple's implementation may omit response IDs.
    @objc(initWithGuestAgentSocketPath:)
    public convenience init(guestAgentSocketPath: String) {
        self.init(socketPath: guestAgentSocketPath, mode: .guestAgent)
    }

    @objc(connectWithCompletion:)
    public func connect(completion: @escaping @Sendable (NSError?) -> Void) {
        connection.submit { connection in
            let result = Result { () throws(QMPError) in try connection.connect() }
            DispatchQueue.main.async {
                if case .failure(let error) = result { completion(error as NSError) } else { completion(nil) }
            }
        }
    }

    @objc(execute:arguments:completion:)
    public func execute(
        _ command: String,
        arguments: [String: Any],
        completion: @escaping @Sendable (Any?, NSError?) -> Void
    ) {
        let encoded = JSONValue(foundationObject: arguments)?.object
        connection.submit { connection in
            let result = Result { () throws(QMPError) in
                guard let encoded else { throw .invalidArguments }
                return try connection.execute(command, arguments: encoded)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let value): completion(value.foundationObject, nil)
                case .failure(let error): completion(nil, error as NSError)
                }
            }
        }
    }

    /// After the owned emulator has exited, consume already queued lifecycle events before teardown. No commands,
    /// reconnect, or second control client.
    @objc(drainLifecycleEventsAfterExitWithCompletion:)
    public func drainLifecycleEventsAfterExit(completion: @escaping @Sendable () -> Void) {
        connection.submit { connection in
            connection.drainLifecycleEventsAfterExit()
            DispatchQueue.main.async { completion() }
        }
    }

    @objc public func close() {
        connection.close()
    }
}

/// Main-thread owned, as VIMGuestAgent was. A `Task` isolated to the main actor and created on it is enqueued there in
/// creation order, and reaches the agent's serial queue in that order.
@MainActor @objc(VIMGuestAgent)
public final class GuestAgentBridge: NSObject {
    public typealias DictionaryCompletion = ([String: Any]?, NSError?) -> Void

    private let agent: GuestAgent

    @objc(initWithSocketPath:)
    public init(socketPath: String) {
        agent = GuestAgent(socketPath: socketPath)
    }

    /// Modern VirtIO defaults to 0.25 s. The legacy UART uses a slower cold-work cadence; this never creates an
    /// idle/background polling timer.
    @objc public var processPollInterval: TimeInterval {
        get { agent.processPollInterval }
        set { agent.processPollInterval = newValue }
    }

    @objc public var preMetalGuest: Bool {
        get { agent.isPreMetalGuest }
        set { agent.isPreMetalGuest = newValue }
    }

    @objc public var tigerGuest: Bool {
        get { agent.isTigerGuest }
        set { agent.isTigerGuest = newValue }
    }

    /// Mojave/Catalina Recovery lacks Apple's agent. Only connection handshakes may fall back to this private UART;
    /// commands are never replayed on error.
    @objc public var recoverySocketPath: String? {
        get { agent.recoverySocketPath }
        set { agent.recoverySocketPath = newValue }
    }

    /// Selected endpoint after a successful handshake, for diagnostic records.
    @objc public var transportName: String { agent.transportName }

    private func start(
        _ operation: @escaping @MainActor () async throws(GuestAgentError) -> Void,
        completion: @escaping (NSError?) -> Void
    ) {
        Task { @MainActor in
            do throws(GuestAgentError) {
                try await operation()
                completion(nil)
            } catch {
                completion(error.nsError)
            }
        }
    }

    private func start(
        _ operation: @escaping @MainActor () async throws(GuestAgentError) -> [String: Any],
        completion: @escaping DictionaryCompletion
    ) {
        Task { @MainActor in
            do throws(GuestAgentError) {
                completion(try await operation(), nil)
            } catch {
                completion(nil, error.nsError)
            }
        }
    }

    @objc(connectWithCompletion:)
    public func connect(completion: @escaping (NSError?) -> Void) {
        start({ [agent] () async throws(GuestAgentError) in try await agent.connect() }, completion: completion)
    }

    /// Result contains the QGA exit status plus decoded stdout/stderr NSData. A timeout has an uncertain outcome: callers
    /// must not blindly repeat a write. Pass zero for setup work that must wait for actual process completion.
    @objc(runExecutable:arguments:timeout:completion:)
    public func runExecutable(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval,
        completion: @escaping DictionaryCompletion
    ) {
        runExecutable(path, arguments: arguments, standardInput: nil, timeout: timeout, completion: completion)
    }

    /// Small private setup input goes through stdin, never argv or a saved command file. Intended for account
    /// provisioning; bulk payloads belong on support media.
    @objc(runExecutable:arguments:standardInput:timeout:completion:)
    public func runExecutable(
        _ path: String,
        arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval,
        completion: @escaping DictionaryCompletion
    ) {
        start(
            { [agent] () async throws(GuestAgentError) in
                let result = try await agent.runExecutable(
                    path,
                    arguments: arguments,
                    standardInput: standardInput,
                    timeout: timeout
                )
                return Self.dictionary(for: result)
            },
            completion: completion
        )
    }

    @objc(runConsoleExecutable:arguments:timeout:completion:)
    public func runConsoleExecutable(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval,
        completion: @escaping DictionaryCompletion
    ) {
        start(
            { [agent] () async throws(GuestAgentError) in
                Self.dictionary(for: try await agent.runConsoleExecutable(path, arguments: arguments, timeout: timeout))
            },
            completion: completion
        )
    }

    @objc(collectStatusWithTool:completion:)
    public func collectStatus(tool: Data, completion: @escaping DictionaryCompletion) {
        start(
            { [agent] () async throws(GuestAgentError) in
                try await agent.collectStatus(tool: tool).mapValues(\.foundationObject)
            },
            completion: completion
        )
    }

    @objc(collectInstalledOpenGLDesktopStatus:)
    public func collectInstalledOpenGLDesktopStatus(completion: @escaping DictionaryCompletion) {
        start(
            { [agent] () async throws(GuestAgentError) in
                try await agent.collectInstalledOpenGLDesktopStatus().mapValues(\.foundationObject)
            },
            completion: completion
        )
    }

    /// `id`, because a pane name comes from an external command and need not be a string; anything else is refused.
    @objc(openPreferencesPane:completion:)
    public func openPreferencesPane(_ pane: Any?, completion: @escaping (NSError?) -> Void) {
        let name = pane as? String ?? ""
        start(
            { [agent] () async throws(GuestAgentError) in try await agent.openPreferencesPane(name) },
            completion: completion
        )
    }

    @objc(openHostConnection:completion:)
    public func openHostConnection(_ url: URL, completion: @escaping (NSError?) -> Void) {
        start(
            { [agent] () async throws(GuestAgentError) in try await agent.openHostConnection(url) },
            completion: completion
        )
    }

    @objc(requestShutdownWithCompletion:)
    public func requestShutdown(completion: @escaping (NSError?) -> Void) {
        start({ [agent] () async throws(GuestAgentError) in try await agent.requestShutdown() }, completion: completion)
    }

    @objc(requestRestartWithCompletion:)
    public func requestRestart(completion: @escaping (NSError?) -> Void) {
        start({ [agent] () async throws(GuestAgentError) in try await agent.requestRestart() }, completion: completion)
    }

    @objc(stageFiles:progress:completion:)
    public func stageFiles(
        _ files: [String: URL],
        progress: (@Sendable (UInt64, UInt64) -> Void)?,
        completion: @escaping DictionaryCompletion
    ) {
        stage(files, persistent: false, progress: progress, completion: completion)
    }

    @objc(stageInstallationFiles:progress:completion:)
    public func stageInstallationFiles(
        _ files: [String: URL],
        progress: (@Sendable (UInt64, UInt64) -> Void)?,
        completion: @escaping DictionaryCompletion
    ) {
        stage(files, persistent: true, progress: progress, completion: completion)
    }

    private func stage(
        _ files: [String: URL],
        persistent: Bool,
        progress: (@Sendable (UInt64, UInt64) -> Void)?,
        completion: @escaping DictionaryCompletion
    ) {
        start(
            { [agent] () async throws(GuestAgentError) in
                let receipt = try await agent.stageFiles(files, persistent: persistent) { completed, total in
                    guard let progress else { return }
                    DispatchQueue.main.async { progress(completed, total) }
                }
                return [
                    "Directory": receipt.directory,
                    "Files": receipt.files.map { ["Name": $0.name, "Size": $0.size] as [String: Any] },
                    "FilesStaged": true
                ]
            },
            completion: completion
        )
    }

    @objc public nonisolated func close() {
        agent.close()
    }

    private static func dictionary(for result: GuestProcessResult) -> [String: Any] {
        var dictionary: [String: Any] = result.status.mapValues(\.foundationObject)
        dictionary["stdout"] = result.standardOutput
        dictionary["stderr"] = result.standardError
        return dictionary
    }
}
