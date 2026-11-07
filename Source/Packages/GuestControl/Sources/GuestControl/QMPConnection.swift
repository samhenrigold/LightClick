import Darwin
import Foundation
import Synchronization

/// A serialized QEMU control channel over a Unix socket, for QMP or for the QGA-compatible guest agent.
///
/// The actor runs on its own serial queue, and socket I/O blocks that queue rather than the cooperative pool. Every
/// method therefore runs to completion in the order callers reach the actor: commands can't interleave, and a command
/// reaches the socket before any later one. A running command doesn't respond to task cancellation, because its
/// outcome would be uncertain; `close()` is the interrupt.
///
/// Events are read only while a command or drain is in flight. No second socket or additional polling is used.
public actor QMPConnection {
    public enum Mode: Sendable {
        case qmp
        /// QGA has no greeting and Apple's implementation may omit response IDs.
        case guestAgent
    }

    /// Lifecycle events observed on this connection, buffered without limit so none is lost. Ends after `close()`.
    public nonisolated let events: AsyncStream<QMPEvent>

    private nonisolated let eventContinuation: AsyncStream<QMPEvent>.Continuation
    private nonisolated let eventObserver: (@Sendable (QMPEvent) -> Void)?
    private nonisolated let path: String
    private nonisolated let mode: Mode
    private nonisolated let queue = DispatchSerialQueue(label: "gold.samhenri.LightClick.control")
    private let socketState = Mutex(SocketState())

    private var buffer = Data()
    private var isReady = false
    private var sequence: UInt64 = 0
    private var isAwaitingSentinel = false
    private var responseDeadline: TimeInterval = 0

    private struct SocketState {
        var descriptor: Int32 = -1
        var isStopped = false
    }

    private static let lifecycleEvents: Set<String> = [
        "RESET", "SHUTDOWN", "SUSPEND", "WAKEUP", "GUEST_PANICKED", "WATCHDOG", "DEVICE_TRAY_MOVED", "PVG_HELPER_LOST"
    ]
    private static let responseSizeLimit = 1024 * 1024

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// - Parameter eventObserver: Called on the connection's queue as each event is read, before the command or drain
    ///   that read it returns. Use it, rather than `events`, when an event must be seen before that command's result.
    public init(socketPath: String, mode: Mode = .qmp, eventObserver: (@Sendable (QMPEvent) -> Void)? = nil) {
        path = socketPath
        self.mode = mode
        self.eventObserver = eventObserver
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    deinit {
        socketState.withLock { state in
            if state.descriptor >= 0 { Darwin.close(state.descriptor) }
        }
        eventContinuation.finish()
    }

    // MARK: - Connecting

    public func connect() throws(QMPError) {
        guard !isReady else { return }
        do throws(QMPError) {
            // After a timeout the socket is still this agent's, and synchronizing again on it is what makes it usable.
            if socketState.withLock({ $0.descriptor }) < 0 { try openSocket() }
            switch mode {
            case .guestAgent:
                let token = JSONValue.number(NSNumber(value: UInt64.random(in: .min ... .max) & UInt64(Int64.max)))
                isAwaitingSentinel = true
                guard try request("guest-sync-delimited", arguments: ["id": token]) == token else {
                    throw QMPError.synchronizationFailed
                }
            case .qmp:
                responseDeadline = ProcessInfo.processInfo.systemUptime + 5
                let greeting = try readObject()
                guard greeting["QMP"]?.object != nil else { throw QMPError.invalidGreeting }
                _ = try request("qmp_capabilities", arguments: [:])
            }
            isReady = true
        } catch {
            Self.trace("connecting to \(path): \(error)")
            if !keepsSocket(after: error) { discardDescriptor() }
            throw error
        }
    }

    /// A guest agent that's slow to answer keeps its socket. QEMU serves one client at a time, and learns that a closed
    /// one has gone only when its main loop gets round to it; until then a new client's requests sit unread. So a close
    /// on a timeout turned a busy guest into one that seemed gone, sometimes for minutes.
    private func keepsSocket(after error: QMPError) -> Bool {
        mode == .guestAgent && error == .timedOut && !socketState.withLock { $0.isStopped }
    }

    private static let tracing = ProcessInfo.processInfo.environment["LC_SEAMLESS_CLICK_LOG"] != nil

    private static func trace(_ what: String) {
        guard tracing else { return }
        FileHandle.standardError.write(Data("[\(Date())] agent connection, \(what)\n".utf8))
    }

    private func openSocket() throws(QMPError) {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        // fileSystemRepresentation raises on an empty string, which can't name a socket anyway.
        guard !path.isEmpty else { throw .unavailable }
        let representation = (path as NSString).fileSystemRepresentation
        guard strlen(representation) < capacity else { throw .pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            _ = strlcpy(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), representation, capacity)
        }

        // QEMU creates this socket shortly after process launch. Bounded retry, off the UI thread; close cancels the
        // retry without starting another VM.
        for _ in 0..<100 {
            guard !socketState.withLock({ $0.isStopped }) else { break }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { break }
            let didConnect = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            if didConnect {
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else {
                    Darwin.close(descriptor)
                    break
                }
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
                Self.setTimeout(5, option: SO_RCVTIMEO, descriptor: descriptor)
                Self.setTimeout(5, option: SO_SNDTIMEO, descriptor: descriptor)
                var one: Int32 = 1
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                socketState.withLock { state in
                    if state.isStopped {
                        Darwin.close(descriptor)
                    } else {
                        state.descriptor = descriptor
                    }
                }
                break
            }
            Darwin.close(descriptor)
            usleep(100_000)
        }
        guard socketState.withLock({ $0.descriptor }) >= 0 else { throw .unavailable }
    }

    private static func setTimeout(_ seconds: TimeInterval, option: Int32, descriptor: Int32) {
        let whole = time_t(seconds)
        var timeout = timeval(tv_sec: whole, tv_usec: suseconds_t((seconds - TimeInterval(whole)) * 1_000_000))
        if timeout.tv_sec == 0 && timeout.tv_usec == 0 { timeout.tv_usec = 1 }
        setsockopt(descriptor, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - Commands

    public func execute(_ command: QMPCommand) throws(QMPError) -> JSONValue {
        try execute(command.name, arguments: command.arguments)
    }

    public func execute(_ command: String, arguments: [String: JSONValue] = [:]) throws(QMPError) -> JSONValue {
        guard isReady else { throw .notReady }
        // The emulator rejects a full keyboard batch before dispatching any of it. Keep ordering on this serial queue
        // and never block AppKit.
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while true {
            do throws(QMPError) {
                return try request(command, arguments: arguments)
            } catch {
                let canRetry =
                    command == "input-send-event" && error == .inputQueueFull
                    && !socketState.withLock { $0.isStopped } && ProcessInfo.processInfo.systemUptime < deadline
                if canRetry {
                    usleep(10_000)
                    continue
                }
                Self.trace("\(command): \(error)")
                // A QGA stream must synchronize again before reuse: on the same socket after a timeout, as the next
                // `connect()` does, and on a new one after anything else.
                if mode == .guestAgent {
                    if keepsSocket(after: error) { isReady = false } else { discardDescriptor() }
                }
                throw error
            }
        }
    }

    private func request(_ command: String, arguments: [String: JSONValue]) throws(QMPError) -> JSONValue {
        let isGuestAgent = mode == .guestAgent
        let isSync = isGuestAgent && command == "guest-sync-delimited"
        // Large staging writes execute inside a potentially busy emulated guest. Other control operations retain their
        // short responsiveness deadline.
        responseDeadline =
            ProcessInfo.processInfo.systemUptime + (isGuestAgent && command == "guest-file-write" ? 30 : 5)
        sequence += 1
        let identifier = JSONValue.number(NSNumber(value: sequence))

        let message = JSONValue.object([
            "execute": .string(command), "arguments": .object(arguments), "id": identifier
        ]).foundationObject
        guard JSONSerialization.isValidJSONObject(message),
            let json = try? JSONSerialization.data(withJSONObject: message)
        else { throw .invalidArguments }
        var wire = Data()
        if isSync { wire.append(0xff) }
        wire.append(json)
        wire.append(0x0a)
        try write(wire)

        for _ in 0..<1024 {
            let response = try readObject()
            if let event = response["event"] {
                if !isGuestAgent, let name = event.string, Self.lifecycleEvents.contains(name) {
                    deliver(QMPEvent(name: name, fields: response))
                }
                continue
            }
            // A stopped/busy emulator can answer after the caller's deadline. That command has an uncertain outcome
            // and must not be replayed, but its obsolete reply must not poison every subsequent request either.
            // QMP echoes our monotonically increasing IDs. Discard only older positive integral IDs; future/missing/
            // malformed IDs still fail below. QGA's legacy no-ID transport retains its separate resynchronization
            // rules.
            if !isGuestAgent, let id = response["id"], Self.isObsolete(id, before: identifier) { continue }
            if isSync && response["return"] != arguments["id"] { continue }
            guard response["id"] == identifier || (isGuestAgent && response["id"] == nil) else {
                throw .unexpectedResponse
            }
            if let failure = response["error"] {
                let detail = failure["desc"]
                if detail == "VIMInputQueueFull" { throw .inputQueueFull }
                throw .rejected(detail?.string ?? "The virtual machine rejected this command.")
            }
            guard let result = response["return"] else { throw .incompleteResponse }
            return result
        }
        throw .tooManyEvents
    }

    private static func isObsolete(_ id: JSONValue, before identifier: JSONValue) -> Bool {
        guard !id.isBoolean, let id = id.number, let current = identifier.number else { return false }
        let unsigned = id.uint64Value
        return unsigned > 0 && id.isEqual(NSNumber(value: unsigned)) && id.compare(current) == .orderedAscending
    }

    private func write(_ wire: Data) throws(QMPError) {
        let descriptor = socketState.withLock { $0.descriptor }
        let didWrite = wire.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard didWrite else { throw .sendFailed }
    }

    private func readObject() throws(QMPError) -> [String: JSONValue] {
        while true {
            if isAwaitingSentinel, let sentinel = buffer.firstIndex(of: 0xff) {
                buffer.removeSubrange(buffer.startIndex...sentinel)
                isAwaitingSentinel = false
                continue
            }
            if !isAwaitingSentinel, let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[buffer.startIndex...newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let parsed = try? JSONSerialization.jsonObject(with: line),
                    let object = JSONValue(foundationObject: parsed)?.object
                else { throw .invalidResponse }
                return object
            }
            guard buffer.count < Self.responseSizeLimit else { throw .responseTooLarge }
            let remaining = responseDeadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw .timedOut }
            let descriptor = socketState.withLock { $0.descriptor }
            Self.setTimeout(remaining, option: SO_RCVTIMEO, descriptor: descriptor)
            var chunk = [UInt8](repeating: 0, count: 4096)
            var count: Int
            repeat {
                count = read(descriptor, &chunk, chunk.count)
            } while count < 0 && errno == EINTR
            // A guest that's slow to answer, as when the host's busy, is a different story from one that's gone.
            if count < 0 && errno == EAGAIN { throw .timedOut }
            guard count > 0 else { throw .connectionEnded }
            buffer.append(contentsOf: chunk[..<count])
        }
    }

    private func deliver(_ event: QMPEvent) {
        eventObserver?(event)
        eventContinuation.yield(event)
    }

    // MARK: - Teardown

    /// After the owned emulator has exited, consumes already queued lifecycle events before teardown. Sends no commands,
    /// and doesn't reconnect or open a second control client.
    ///
    /// Every observed SHUTDOWN reason reaches `eventObserver` before this returns, so the owner sees it before its
    /// termination decision. Unlike a command, a drain passes on every named event, not only the lifecycle ones.
    public func drainLifecycleEventsAfterExit() {
        guard mode == .qmp, socketState.withLock({ $0.descriptor }) >= 0 else { return }
        responseDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        for _ in 0..<4096 {
            guard let object = try? readObject() else { break }
            if let name = object["event"]?.string {
                deliver(QMPEvent(name: name, fields: object))
            }
        }
    }

    /// Stops any connection retry and wakes a blocked read at once. Callable from anywhere.
    public nonisolated func close() {
        socketState.withLock { state in
            state.isStopped = true
            if state.descriptor >= 0 { shutdown(state.descriptor, SHUT_RDWR) }
        }
        // Commands and drains already queued finish first, so the descriptor is never closed under a read, and events
        // they read still reach `events` before it ends.
        submit { connection in
            connection.discardDescriptor()
            connection.eventContinuation.finish()
        }
    }

    /// Enqueues `work` before returning, so it runs in submission order. `await` from separate unstructured tasks, or
    /// from `@objc async` thunks, doesn't promise that.
    nonisolated func submit(_ work: @escaping @Sendable (isolated QMPConnection) -> Void) {
        queue.async { [self] in assumeIsolated { work($0) } }
    }

    private func discardDescriptor() {
        socketState.withLock { state in
            if state.descriptor >= 0 {
                Darwin.close(state.descriptor)
                state.descriptor = -1
            }
        }
        isReady = false
        buffer.removeAll()
    }
}
