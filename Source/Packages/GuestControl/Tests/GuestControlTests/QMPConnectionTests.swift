import Foundation
import Testing

@testable import GuestControl

/// Ports probes/app-qmp-late-response.m, app-qmp-exit-events.m and app-qmp-control.m (minus QEMU itself).
struct QMPConnectionTests {
    private func failure(of operation: () async throws(QMPError) -> Void) async -> QMPError? {
        do throws(QMPError) {
            try await operation()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Late responses

    /// Runs against the real five-second deadline, so it takes six seconds.
    @Test func aLateReplyNeverPoisonsLaterCommandsOrCausesARetry() async throws {
        let commands = Recorder<String>()
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            guard let write = peer.read(), let writeID = write["id"] else { return }
            commands.append(write["execute"]?.string ?? "")
            // Deliberately exceed the real controller's five-second deadline. The peer executed it, but the owner
            // cannot know that at timeout.
            usleep(6_000_000)
            peer.send(["return": ["Accepted": true], "id": writeID])
            guard let query = peer.read(), let queryID = query["id"] else { return }
            commands.append(query["execute"]?.string ?? "")
            peer.send(["error": ["desc": "An obsolete error, not this query"], "id": writeID])
            peer.send(["event": "RESUME"])
            peer.send(["return": ["status": "running"], "id": queryID])
            guard let future = peer.read(), let futureID = future["id"]?.number?.uint64Value else { return }
            commands.append(future["execute"]?.string ?? "")
            peer.send(["return": [:], "id": .number(NSNumber(value: futureID + 1))])
        }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path)
        defer { control.close() }
        try await control.connect()

        let timeout = await failure { () async throws(QMPError) in
            _ = try await control.execute("fixture-write-once")
        }
        #expect(timeout == .connectionEnded || timeout == .timedOut, "An uncertain write reports a timeout")

        let status = try await control.execute(.queryStatus)
        #expect(status["status"] == "running", "Ignore expired IDs, consume events, match the fresh query")

        let future = await failure { () async throws(QMPError) in
            _ = try await control.execute("fixture-future-id")
        }
        #expect(future == .unexpectedResponse, "Unexpected future IDs remain errors")
        #expect(commands.all == ["fixture-write-once", "query-status", "fixture-future-id"], "No write is repeated")
    }

    /// The only IDs a QMP reply may be discarded for are older, positive and integral. Everything else is refused.
    @Test(arguments: [
        JSONValue.null, "1", true, false, 0, -1, .number(NSNumber(value: 1.5)), .number(NSNumber(value: 99)), [1], [:]
    ])
    func aMalformedQMPIDIsRefusedRatherThanSkipped(id: JSONValue) async throws {
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            guard peer.read() != nil else { return }
            peer.send(["return": [:], "id": id])
        }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path)
        defer { control.close() }
        try await control.connect()
        let error = await failure { () async throws(QMPError) in _ = try await control.execute(.queryStatus) }
        #expect(error == .unexpectedResponse)
    }

    @Test func aQMPReplyWithoutAnIDIsRefused() async throws {
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            guard peer.read() != nil else { return }
            peer.send(["return": [:]])
        }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path)
        defer { control.close() }
        try await control.connect()
        let error = await failure { () async throws(QMPError) in _ = try await control.execute(.queryStatus) }
        #expect(error == .unexpectedResponse)
    }

    // MARK: - Exit events

    /// No later request will read this event. It must survive process-exit teardown, including when the event and EOF
    /// arrive together.
    @Test func aQueuedExitEventIsDeliveredBeforeTheDrainReturns() async throws {
        let observed = Recorder<QMPEvent>()
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            peer.send(["event": "SHUTDOWN", "data": ["guest": true, "reason": "guest-reset"]])
        }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path, eventObserver: { observed.append($0) })
        try await control.connect()
        await control.drainLifecycleEventsAfterExit()
        #expect(observed.all.map(\.name) == ["SHUTDOWN"], "Delivered before the drain returned")
        #expect(observed.all.first?.data?["reason"] == "guest-reset")

        control.close()
        var streamed: [String] = []
        for await event in control.events { streamed.append(event.name) }
        #expect(streamed == ["SHUTDOWN"], "The sequence sees the event too, then ends after close")
    }

    @Test func aDrainPassesOnEveryNamedEventAndSkipsReplies() async throws {
        let observed = Recorder<String>()
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            peer.send(["event": "DEVICE_DELETED", "data": ["device": "image-usb-1"]])
            peer.send(["return": [:], "id": 1])
            peer.send(["event": 7])
            peer.send(["event": "STOP"])
        }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path, eventObserver: { observed.append($0.name) })
        defer { control.close() }
        try await control.connect()
        await control.drainLifecycleEventsAfterExit()
        #expect(observed.all == ["DEVICE_DELETED", "STOP"])
    }

    @Test func aDrainWithNothingQueuedEndsWithinItsDeadline() async throws {
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            _ = peer.read()
        }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path)
        defer { control.close() }
        try await control.connect()
        let start = ContinuousClock.now
        await control.drainLifecycleEventsAfterExit()
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    // MARK: - Control sequence

    @Test func theControlSequenceHandlesErrorsAndReportsLifecycleEventsBeforeTheNextResult() async throws {
        let observed = Recorder<String>()
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            guard let status = peer.read(), let statusID = status["id"] else { return }
            peer.send(["return": ["status": "prelaunch"], "id": statusID])
            guard let bad = peer.read(), let badID = bad["id"] else { return }
            peer.send(["error": ["class": "CommandNotFound", "desc": "The command was not found"], "id": badID])
            guard let name = peer.read(), let nameID = name["id"] else { return }
            peer.send(["return": [:], "id": nameID])
            guard let reset = peer.read(), let resetID = reset["id"] else { return }
            peer.send(["event": "RESET", "data": ["guest": false]])
            // Not a lifecycle event: a command read discards it.
            peer.send(["event": "DEVICE_DELETED", "data": ["device": "image-usb-1"]])
            peer.send(["return": [:], "id": resetID])
        }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path, eventObserver: { observed.append($0.name) })
        defer { control.close() }
        try await control.connect()
        #expect(try await control.execute(.queryStatus)["status"] == "prelaunch")
        let error = await failure { () async throws(QMPError) in
            _ = try await control.execute("vim-nonexistent-test-command")
        }
        #expect(error == .rejected("The command was not found"))
        #expect(try await control.execute("query-name").object != nil, "An error doesn't end the session")
        _ = try await control.execute("system_reset")
        #expect(observed.all == ["RESET"])
    }

    @Test func aFullKeyboardQueueIsRetriedOnlyForInput() async throws {
        let received = Recorder<String>()
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            for attempt in 0..<4 {
                guard let request = peer.read(), let id = request["id"] else { return }
                received.append(request["execute"]?.string ?? "")
                if attempt == 2 {
                    peer.send(["return": [:], "id": id])
                } else {
                    peer.send(["error": ["desc": "VIMInputQueueFull"], "id": id])
                }
            }
        }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path)
        defer { control.close() }
        try await control.connect()
        _ = try await control.execute(.inputSendEvent(events: []))
        #expect(received.all == ["input-send-event", "input-send-event", "input-send-event"])
        let error = await failure { () async throws(QMPError) in
            _ = try await control.execute(.sendKey(keys: [], holdTime: 50))
        }
        #expect(error == .inputQueueFull, "Other commands report it at once")
        #expect((error as? NSError)?.code == 2)
    }

    @Test func tooManyUnsolicitedEventsFailTheCommand() async throws {
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            guard peer.read() != nil else { return }
            for _ in 0..<1024 { peer.send(["event": "STOP"]) }
        }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path)
        defer { control.close() }
        try await control.connect()
        let error = await failure { () async throws(QMPError) in _ = try await control.execute(.queryStatus) }
        #expect(error == .tooManyEvents)
    }

    @Test func anOversizedResponseFails() async throws {
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            guard peer.read() != nil else { return }
            peer.send(raw: Data(repeating: 0x20, count: 1024 * 1024 + 4096))
        }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path)
        defer { control.close() }
        try await control.connect()
        let error = await failure { () async throws(QMPError) in _ = try await control.execute(.queryStatus) }
        #expect(error == .responseTooLarge)
    }

    @Test(arguments: [
        ("[1]\n", QMPError.invalidResponse), ("not json\n", .invalidResponse), ("{\"return\":{}}\n", .invalidGreeting),
        ("{\"QMP\":1}\n", .invalidGreeting)
    ])
    func aBadGreetingFailsTheConnection(greeting: String, expected: QMPError) async {
        let server = FakeSocketServer { peer in peer.send(raw: Data(greeting.utf8)) }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path)
        defer { control.close() }
        #expect(await failure { () async throws(QMPError) in try await control.connect() } == expected)
    }

    @Test func aCommandBeforeConnectingIsNotSent() async {
        let control = QMPConnection(socketPath: "/nonexistent/control")
        defer { control.close() }
        let error = await failure { () async throws(QMPError) in _ = try await control.execute(.queryStatus) }
        #expect(error == .notReady)
    }

    @Test func aPathLongerThanTheSocketAddressIsRefused() async {
        let control = QMPConnection(socketPath: "/" + String(repeating: "a", count: 200))
        defer { control.close() }
        #expect(await failure { () async throws(QMPError) in try await control.connect() } == .pathTooLong)
    }

    // MARK: - Close

    @Test func closeCancelsTheConnectionRetry() async {
        let control = QMPConnection(socketPath: "/nonexistent/control")
        let start = ContinuousClock.now
        async let error = failure { () async throws(QMPError) in try await control.connect() }
        try? await Task.sleep(for: .milliseconds(150))
        control.close()
        #expect(await error == .unavailable)
        #expect(ContinuousClock.now - start < .seconds(5), "The full retry takes ten seconds")
    }

    @Test func closeInterruptsACommandWaitingForItsReply() async throws {
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            _ = peer.read()
            _ = peer.read()
        }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path)
        try await control.connect()
        let start = ContinuousClock.now
        async let error = failure { () async throws(QMPError) in _ = try await control.execute(.queryStatus) }
        try await Task.sleep(for: .milliseconds(100))
        control.close()
        #expect(await error == .connectionEnded)
        #expect(ContinuousClock.now - start < .seconds(4), "The deadline is five seconds")
        let after = await failure { () async throws(QMPError) in try await control.connect() }
        #expect(after == .unavailable, "A closed connection stays closed")
    }

    // MARK: - Guest-agent mode

    /// QGA has no greeting. The sync request leads with 0xFF, whose echo discards anything stale before it, and any
    /// reply that doesn't return the token is skipped whatever its ID or error.
    @Test func guestAgentSynchronizationSkipsStaleBytesAndReplies() async throws {
        let sentinels = Recorder<Bool>()
        let server = FakeSocketServer { peer in
            guard let sync = peer.readRequest(), let token = sync.request["arguments"]?["id"] else { return }
            sentinels.append(sync.hadSentinel)
            peer.send(raw: Data("{\"stale\":".utf8) + [0xff])
            peer.send(["return": 1, "id": 999])
            peer.send(["error": ["desc": "stale"]])
            peer.send(["return": token])
            guard let ping = peer.readRequest() else { return }
            sentinels.append(ping.hadSentinel)
            peer.send(["return": ["ok": true]])
        }
        defer { server.stop() }
        let agent = QMPConnection(socketPath: server.path, mode: .guestAgent)
        defer { agent.close() }
        try await agent.connect()
        #expect(try await agent.execute("guest-ping")["ok"] == true, "Apple's agent may omit the response ID")
        #expect(sentinels.all == [true, false], "Only synchronization sends the sentinel")
    }

    @Test func aGuestAgentReplyWithTheWrongOrNullIDIsRefused() async throws {
        for id: JSONValue in [99, .null] {
            let server = FakeSocketServer { peer in
                guard let sync = peer.read(), let token = sync["arguments"]?["id"] else { return }
                peer.send(raw: Data([0xff]))
                peer.send(["return": token])
                guard peer.read() != nil else { return }
                peer.send(["return": [:], "id": id])
            }
            defer { server.stop() }
            let agent = QMPConnection(socketPath: server.path, mode: .guestAgent)
            defer { agent.close() }
            try await agent.connect()
            let error = await failure { () async throws(QMPError) in _ = try await agent.execute("guest-ping") }
            #expect(error == .unexpectedResponse)
        }
    }

    /// A guest agent that times out keeps its socket and synchronizes again on it, skipping the late reply. QEMU takes one
    /// client at a time, so a new one could sit unread until it noticed the old one had gone. Runs against the real
    /// five-second deadline, so it takes six seconds.
    @Test func aTimedOutGuestAgentSynchronizesAgainOnTheSameSocket() async throws {
        let connections = Recorder<Bool>()
        let server = FakeSocketServer { peer in
            guard let sync = peer.readRequest(), let token = sync.request["arguments"]?["id"] else { return }
            connections.append(sync.hadSentinel)
            peer.send(raw: Data([0xff]))
            peer.send(["return": token])
            guard peer.read() != nil else { return }
            usleep(6_000_000)
            peer.send(["return": ["late": true]])
            guard let again = peer.readRequest(), let next = again.request["arguments"]?["id"] else { return }
            connections.append(again.hadSentinel)
            peer.send(raw: Data([0xff]))
            peer.send(["return": next])
            guard peer.read() != nil else { return }
            peer.send(["return": ["ok": true]])
        }
        defer { server.stop() }
        let agent = QMPConnection(socketPath: server.path, mode: .guestAgent)
        defer { agent.close() }
        try await agent.connect()
        let slow = await failure { () async throws(QMPError) in _ = try await agent.execute("guest-ping") }
        #expect(slow == .timedOut)
        let notReady = await failure { () async throws(QMPError) in _ = try await agent.execute("guest-ping") }
        #expect(notReady == .notReady, "Nothing's sent until it has synchronized again")
        try await agent.connect()
        #expect(try await agent.execute("guest-ping")["ok"] == true, "The late reply was skipped")
        #expect(connections.all == [true, true], "Both synchronizations were on the one connection, with the sentinel")
    }

    /// Any other QGA error, even a clean rejection, drops the connection, and the fresh one re-sends the sentinel.
    @Test func anyGuestAgentErrorRequiresSynchronizingAgain() async throws {
        let connections = Recorder<Bool>()
        let server = FakeSocketServer { peer in
            guard let sync = peer.readRequest(), let token = sync.request["arguments"]?["id"] else { return }
            connections.append(sync.hadSentinel)
            peer.send(raw: Data([0xff]))
            peer.send(["return": token])
            guard peer.read() != nil else { return }
            peer.send(["error": ["desc": "No such command"]])
            _ = peer.read()
        }
        defer { server.stop() }
        let agent = QMPConnection(socketPath: server.path, mode: .guestAgent)
        defer { agent.close() }
        try await agent.connect()
        let rejected = await failure { () async throws(QMPError) in _ = try await agent.execute("guest-ping") }
        #expect(rejected == .rejected("No such command"))
        let notReady = await failure { () async throws(QMPError) in _ = try await agent.execute("guest-ping") }
        #expect(notReady == .notReady)
        try await agent.connect()
        #expect(connections.all == [true, true])
    }

    /// Runs against the real deadlines, so it takes six seconds.
    @Test func onlyGuestFileWriteGetsTheLongDeadline() async throws {
        let server = FakeSocketServer { peer in
            guard let sync = peer.read(), let token = sync["arguments"]?["id"] else { return }
            peer.send(raw: Data([0xff]))
            peer.send(["return": token])
            guard peer.read() != nil else { return }
            usleep(6_000_000)
            peer.send(["return": ["count": 1]])
        }
        defer { server.stop() }
        let agent = QMPConnection(socketPath: server.path, mode: .guestAgent)
        defer { agent.close() }
        try await agent.connect()
        #expect(try await agent.execute("guest-file-write")["count"] == 1)
    }

    @Test func guestAgentEventsAreDiscardedAndADrainIsANoOp() async throws {
        let observed = Recorder<String>()
        let server = FakeSocketServer { peer in
            guard let sync = peer.read(), let token = sync["arguments"]?["id"] else { return }
            peer.send(raw: Data([0xff]))
            peer.send(["return": token])
            guard peer.read() != nil else { return }
            peer.send(["event": "SHUTDOWN"])
            peer.send(["return": [:]])
            peer.send(["event": "SHUTDOWN"])
        }
        defer { server.stop() }
        let agent = QMPConnection(
            socketPath: server.path, mode: .guestAgent, eventObserver: { observed.append($0.name) })
        defer { agent.close() }
        try await agent.connect()
        _ = try await agent.execute("guest-ping")
        await agent.drainLifecycleEventsAfterExit()
        #expect(observed.all.isEmpty)
    }

    // MARK: - Typed commands

    @Test func typedCommandsPutTheArgumentNamesOnTheWire() async throws {
        let received = Recorder<JSONValue>()
        let commands: [QMPCommand] = [
            .eject(id: "setup-support-device", force: false),
            .eject(id: "opengl-setup-device"),
            .blockdevChangeMedium(id: "setup-support-device", filename: "/fixture", format: "raw"),
            .setLink(name: "ethernet", up: false),
            .qomSet(path: "/machine/peripheral/x", property: "attached", value: true),
            .chardevAddUnixClient(id: "c", path: "/p"),
            .deviceAdd(driver: "usb-redir", id: "u", properties: ["bus": "b", "bulk-only": true]),
            .sendKey(keys: [], holdTime: 50),
            .traceEventSetState(name: "e", enable: true),
            .humanMonitorCommand("log none")
        ]
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            while let request = peer.read(), let id = request["id"] {
                received.append(["execute": request["execute"] ?? .null, "arguments": request["arguments"] ?? .null])
                peer.send(["return": [:], "id": id])
            }
        }
        defer { server.stop() }
        let control = QMPConnection(socketPath: server.path)
        try await control.connect()
        for command in commands { _ = try await control.execute(command) }
        control.close()

        let expected: [JSONValue] = [
            ["execute": "eject", "arguments": ["id": "setup-support-device", "force": false]],
            ["execute": "eject", "arguments": ["id": "opengl-setup-device"]],
            [
                "execute": "blockdev-change-medium",
                "arguments": [
                    "id": "setup-support-device", "filename": "/fixture", "format": "raw", "read-only-mode": "read-only"
                ]
            ],
            ["execute": "set_link", "arguments": ["name": "ethernet", "up": false]],
            [
                "execute": "qom-set",
                "arguments": ["path": "/machine/peripheral/x", "property": "attached", "value": true]
            ],
            [
                "execute": "chardev-add",
                "arguments": [
                    "id": "c",
                    "backend": [
                        "type": "socket",
                        "data": ["addr": ["type": "unix", "data": ["path": "/p"]], "server": false]
                    ]
                ]
            ],
            ["execute": "device_add", "arguments": ["driver": "usb-redir", "id": "u", "bus": "b", "bulk-only": true]],
            ["execute": "send-key", "arguments": ["keys": [], "hold-time": 50]],
            ["execute": "trace-event-set-state", "arguments": ["name": "e", "enable": true]],
            ["execute": "human-monitor-command", "arguments": ["command-line": "log none"]]
        ]
        #expect(received.all == expected)
    }
}
