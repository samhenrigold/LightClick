import Foundation
import Testing

@testable import GuestControl

/// Calls the bridge through the Objective-C runtime, with the selectors the app's callers use, so these exercise the
/// compiler's completion-handler thunks rather than the Swift methods.
@MainActor
struct ObjectiveCBridgeTests {
    private typealias ExecuteCompletion = @convention(block) (AnyObject?, NSError?) -> Void
    private typealias Execute =
        @convention(c) (AnyObject, Selector, NSString, NSDictionary, @escaping ExecuteCompletion) -> Void
    private typealias Connect =
        @convention(c) (AnyObject, Selector, @escaping @convention(block) (NSError?) -> Void) -> Void
    private typealias Drain = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
    private typealias Run =
        @convention(c) (AnyObject, Selector, NSString, NSArray, TimeInterval, @escaping ExecuteCompletion) -> Void
    private typealias Stage =
        @convention(c) (
            AnyObject, Selector, NSDictionary, (@convention(block) (UInt64, UInt64) -> Void)?,
            @escaping ExecuteCompletion
        ) -> Void
    private typealias OpenPane =
        @convention(c) (AnyObject, Selector, AnyObject?, @escaping @convention(block) (NSError?) -> Void) -> Void

    private func connect(_ bridge: NSObject) async -> NSError? {
        let selector = NSSelectorFromString("connectWithCompletion:")
        let function = unsafeBitCast(bridge.method(for: selector), to: Connect.self)
        return await withCheckedContinuation { continuation in
            function(bridge, selector) { error in
                let isMain = Thread.isMainThread
                #expect(isMain, "Completions always run on the main thread")
                continuation.resume(returning: error)
            }
        }
    }

    /// Foundation objects a test receives from the one completion it waits for.
    private struct Reply: @unchecked Sendable {
        let result: AnyObject?
        let error: NSError?
    }

    private func execute(_ bridge: NSObject, _ command: String, arguments: NSDictionary = [:]) async -> Reply {
        let selector = NSSelectorFromString("execute:arguments:completion:")
        let function = unsafeBitCast(bridge.method(for: selector), to: Execute.self)
        return await withCheckedContinuation { continuation in
            function(bridge, selector, command as NSString, arguments) { result, error in
                continuation.resume(returning: Reply(result: result, error: error))
            }
        }
    }

    private func run(_ agent: NSObject, _ path: String) async -> Reply {
        let selector = NSSelectorFromString("runExecutable:arguments:timeout:completion:")
        let function = unsafeBitCast(agent.method(for: selector), to: Run.self)
        return await withCheckedContinuation { continuation in
            function(agent, selector, path as NSString, [] as NSArray, 5) { result, error in
                continuation.resume(returning: Reply(result: result, error: error))
            }
        }
    }

    @Test func consecutiveCallsReachTheSocketInCallOrderWithResultsOnMain() async throws {
        let received = Recorder<String>()
        let count = 300
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            while let request = peer.read(), let id = request["id"] {
                received.append(request["execute"]?.string ?? "")
                peer.send(["return": ["echo": request["execute"] ?? .null], "id": id])
            }
        }
        defer { server.stop() }
        let bridge = QMPConnectionBridge(socketPath: server.path)
        defer { bridge.close() }
        #expect(await connect(bridge) == nil)

        let selector = NSSelectorFromString("execute:arguments:completion:")
        let function = unsafeBitCast(bridge.method(for: selector), to: Execute.self)
        let completions = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            nonisolated(unsafe) var names: [String] = []
            // All in one main-thread turn, as a burst of input events is.
            for index in 0..<count {
                function(bridge, selector, "c\(index)" as NSString, [:] as NSDictionary) { result, error in
                    #expect(error == nil)
                    #expect(Thread.isMainThread)
                    names.append((result as? NSDictionary)?["echo"] as? String ?? "")
                    if names.count == count { continuation.resume(returning: names) }
                }
            }
        }
        let expected = (0..<count).map { "c\($0)" }
        #expect(received.all == expected)
        #expect(completions == expected)
    }

    @Test func consecutiveGuestCommandsStartInCallOrder() async throws {
        let count = 100
        let fake = FakeGuestAgent()
        defer { fake.stop() }
        let agent = GuestAgentBridge(socketPath: fake.path)
        defer { agent.close() }
        #expect(await connect(agent) == nil)
        let selector = NSSelectorFromString("runExecutable:arguments:timeout:completion:")
        let function = unsafeBitCast(agent.method(for: selector), to: Run.self)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            nonisolated(unsafe) var remaining = count
            for index in 0..<count {
                function(agent, selector, "/c\(index)" as NSString, [] as NSArray, 5) { _, _ in
                    remaining -= 1
                    if remaining == 0 { continuation.resume() }
                }
            }
        }
        #expect(fake.state.withLock { $0.processes.map(\.path) } == (0..<count).map { "/c\($0)" })
    }

    @Test func errorsKeepTheirDomainCodeAndDescription() async throws {
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            guard let first = peer.read(), let firstID = first["id"] else { return }
            peer.send(["error": ["desc": "No such command"], "id": firstID])
            guard let second = peer.read(), let secondID = second["id"] else { return }
            peer.send(["error": ["desc": "VIMInputQueueFull"], "id": secondID])
        }
        defer { server.stop() }
        let bridge = QMPConnectionBridge(socketPath: server.path)
        defer { bridge.close() }
        #expect(await connect(bridge) == nil)
        let rejected = await execute(bridge, "first").error
        #expect(rejected?.domain == "VirtualIntelMac.Control")
        #expect(rejected?.code == 1)
        #expect(rejected?.localizedDescription == "No such command")
        let busy = await execute(bridge, "second").error
        #expect(busy?.code == 2)
        #expect(busy?.localizedDescription == "The guest keyboard is busy.")
    }

    @Test func argumentsAndRepliesKeepTheirNumberTypesAndNulls() async throws {
        let received = Recorder<JSONValue>()
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            guard let request = peer.read(), let id = request["id"] else { return }
            received.append(request["arguments"] ?? .null)
            peer.send(["return": .null, "id": id])
        }
        defer { server.stop() }
        let bridge = QMPConnectionBridge(socketPath: server.path)
        defer { bridge.close() }
        #expect(await connect(bridge) == nil)
        let reply = await execute(bridge, "set_link", arguments: ["up": kCFBooleanFalse as Any, "port": "1"])
        #expect(reply.error == nil)
        #expect(reply.result is NSNull, "A null return is a result, as it was")
        #expect(received.all.first?["up"]?.isBoolean == true)
    }

    @Test func aLifecycleEventPrecedesTheResultOfTheCommandThatReadIt() async throws {
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            guard let request = peer.read(), let id = request["id"] else { return }
            peer.send(["event": "RESET"])
            peer.send(["return": [:], "id": id])
        }
        defer { server.stop() }
        let bridge = QMPConnectionBridge(socketPath: server.path)
        defer { bridge.close() }
        nonisolated(unsafe) var events: [String] = []
        bridge.lifecycleEventHandler = { event in
            let isMain = Thread.isMainThread
            #expect(isMain)
            events.append(event["event"] as? String ?? "")
        }
        #expect(await connect(bridge) == nil)
        _ = await execute(bridge, "system_reset")
        #expect(events == ["RESET"])
    }

    @Test func aDrainDeliversQueuedExitEventsBeforeItsCompletion() async throws {
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            peer.send(["event": "SHUTDOWN", "data": ["guest": true, "reason": "guest-reset"]])
        }
        defer { server.stop() }
        let bridge = QMPConnectionBridge(socketPath: server.path)
        defer { bridge.close() }
        nonisolated(unsafe) var reasons: [String] = []
        bridge.lifecycleEventHandler = { event in
            reasons.append((event["data"] as? NSDictionary)?["reason"] as? String ?? "")
        }
        #expect(await connect(bridge) == nil)
        let selector = NSSelectorFromString("drainLifecycleEventsAfterExitWithCompletion:")
        let function = unsafeBitCast(bridge.method(for: selector), to: Drain.self)
        let seen = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            function(bridge, selector) { continuation.resume(returning: reasons) }
        }
        #expect(seen == ["guest-reset"])
    }

    @Test func aProcessResultHasTheOriginalDictionaryShape() async throws {
        let fake = FakeGuestAgent { _ in .finished(exitCode: 3, output: "text") }
        defer { fake.stop() }
        let agent = GuestAgentBridge(socketPath: fake.path)
        defer { agent.close() }
        #expect(await connect(agent) == nil)
        let reply = await run(agent, "/fixture")
        #expect(reply.error == nil)
        let result = reply.result as? NSDictionary
        #expect(result?["exitcode"] as? NSNumber == 3)
        #expect(result?["stdout"] as? Data == Data("text".utf8))
        #expect(result?["stderr"] as? Data == Data())
    }

    @Test func guestFailuresUseTheGuestAgentDomain() async throws {
        let agent = GuestAgentBridge(socketPath: "/nonexistent/agent")
        agent.close()
        let error = await connect(agent)
        #expect(error?.domain == "VirtualIntelMac.GuestAgent")
        #expect(error?.code == 1)
        #expect(error?.localizedDescription == "The guest controller is closed.")
    }

    @Test func aPaneThatIsNotAStringIsRefused() async throws {
        let agent = GuestAgentBridge(socketPath: "/nonexistent/agent")
        defer { agent.close() }
        let selector = NSSelectorFromString("openPreferencesPane:completion:")
        let function = unsafeBitCast(agent.method(for: selector), to: OpenPane.self)
        let error = await withCheckedContinuation { (continuation: CheckedContinuation<NSError?, Never>) in
            function(agent, selector, NSNull()) { continuation.resume(returning: $0) }
        }
        #expect(error?.localizedDescription.hasPrefix("Start the virtual Mac") == true)
    }

    @Test func aStagingFailureCarriesItsDirectoryAndProgressArrivesOnMain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("payload")
        try Data(count: 500_000).write(to: input)
        let fake = FakeGuestAgent { process in
            switch process.path {
            case "/bin/sh": .finished(exitCode: 0, output: "0\n")
            case "/usr/bin/mktemp": .finished(exitCode: 0, output: "/private/var/db/VirtualIntelMac.abc123\n")
            default: .finished(exitCode: 0)
            }
        }
        defer { fake.stop() }
        fake.state.withLock { $0.failWriteAtChunk = 1 }
        let agent = GuestAgentBridge(socketPath: fake.path)
        defer { agent.close() }
        #expect(await connect(agent) == nil)

        nonisolated(unsafe) var progress: [UInt64] = []
        let selector = NSSelectorFromString("stageInstallationFiles:progress:completion:")
        let function = unsafeBitCast(agent.method(for: selector), to: Stage.self)
        let error = await withCheckedContinuation { (continuation: CheckedContinuation<NSError?, Never>) in
            function(
                agent,
                selector,
                ["payload": input] as NSDictionary,
                { completed, _ in
                    let isMain = Thread.isMainThread
                    #expect(isMain)
                    progress.append(completed)
                },
                { _, error in continuation.resume(returning: error) }
            )
        }
        #expect(error?.userInfo["GuestStagingDirectory"] as? String == "/private/var/db/VirtualIntelMac.abc123")
        #expect(error?.localizedDescription == "disk full")
        #expect(progress == [0, 384 * 1024], "Progress precedes the completion")
    }

    @Test func settingsAreSynchronousProperties() {
        let agent = GuestAgentBridge(socketPath: "/nonexistent/agent")
        defer { agent.close() }
        #expect(agent.processPollInterval == 0.25)
        agent.setValue(5.0, forKey: "processPollInterval")
        #expect(agent.processPollInterval == 5)
        agent.setValue(true, forKey: "preMetalGuest")
        #expect(agent.value(forKey: "transportName") as? String == "Apple16X50Serial")
    }
}
