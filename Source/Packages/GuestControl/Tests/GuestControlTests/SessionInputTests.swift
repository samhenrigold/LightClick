import Foundation
import Testing

@testable import GuestControl

private var key: [[String: Any]] { [["type": "key", "data": ["down": true]]] }
private var motion: [[String: Any]] { [["type": "abs", "data": ["axis": "x", "value": 32767]]] }

@MainActor
@Suite struct SessionInputTests {
    @MainActor private final class Channel {
        var sent: [(command: String, arguments: [String: Any])] = []
        var answers: [@Sendable (Any?, NSError?) -> Void] = []
        var log: [String] = []

        func input(coalesces: Bool = true) -> SessionInput {
            let input = SessionInput(coalesces: coalesces) { command, arguments, done in
                self.sent.append((command, arguments))
                self.answers.append(done)
            }
            input.woke = { self.log.append("woke") }
            input.wakeFailed = { _ in self.log.append("wake failed") }
            input.sendFailed = { _ in self.log.append("send failed") }
            input.willSend = {
                self.log.append("will send")
                return { error in self.log.append(error == nil ? "finished" : "finished with error") }
            }
            return input
        }

        func answerOldest(_ error: NSError? = nil) { answers.removeFirst()(nil, error) }
    }

    private let failure = NSError(domain: "test", code: 1)

    @Test func aSleepingGuestIsWokenOnceAndTheEventsAreDropped() {
        let channel = Channel()
        let input = channel.input()
        input.isSuspended = { true }
        input.submit(key)
        input.submit(key)
        #expect(channel.sent.map(\.command) == ["system_wakeup"])
        channel.answerOldest()
        #expect(channel.log == ["woke"])
        input.submit(key)
        #expect(channel.sent.map(\.command) == ["system_wakeup", "system_wakeup"], "Still suspended, so wake again.")
    }

    @Test func aFailedWakeIsReported() {
        let channel = Channel()
        let input = channel.input()
        input.isSuspended = { true }
        input.submit(key)
        channel.answerOldest(failure)
        #expect(channel.log == ["wake failed"])
    }

    @Test func eventsAreCalibratedBeforeTheyreSent() {
        let channel = Channel()
        let input = channel.input()
        input.tabletTrim = { 10 }
        input.submit(motion)
        let events = channel.sent[0].arguments["events"] as? [[String: Any]]
        let value = (events?[0]["data"] as? [String: Any])?["value"] as? Int64
        #expect(value != nil && value! < 32767)
    }

    @Test func motionWaitsBehindAnOutstandingBatch() {
        let channel = Channel()
        let input = channel.input()
        input.submit(key)
        input.submit(motion)
        #expect(channel.sent.count == 1)
        channel.answerOldest()
        #expect(channel.sent.count == 2)
    }

    @Test func withoutCoalescingEveryMoveGoesOut() {
        let channel = Channel()
        let input = channel.input(coalesces: false)
        input.submit(key)
        input.submit(motion)
        #expect(channel.sent.count == 2)
    }

    @Test func aTimedDiagnosticSendsEachBatchAlone() {
        let channel = Channel()
        let input = channel.input()
        input.sendsEachBatchAlone = { true }
        input.submit(key)
        input.submit(motion)
        #expect(channel.sent.count == 2)
    }

    @Test func aReplyFinishesBeforeItsFailureIsShown() {
        let channel = Channel()
        let input = channel.input()
        input.submit(key)
        channel.answerOldest(failure)
        #expect(channel.log == ["will send", "finished with error", "send failed"])
    }
}

@MainActor
struct BeginGuestTests {
    private func commands(
        linkDown: Bool, resume: Bool, refusing refused: String? = nil
    ) async -> (sent: [String], failed: Bool) {
        let received = Recorder<String>()
        let server = FakeSocketServer { peer in
            peer.acceptQMPHandshake()
            while let request = peer.read(), let id = request["id"] {
                let name = request["execute"]?.string ?? ""
                received.append(name)
                peer.send(name == refused ? ["error": ["desc": "no"], "id": id] : ["return": [:], "id": id])
            }
        }
        defer { server.stop() }
        let bridge = QMPConnectionBridge(socketPath: server.path)
        defer { bridge.close() }
        await withCheckedContinuation { continuation in
            bridge.connect { _ in continuation.resume() }
        }
        let failures = Recorder<String>()
        bridge.beginGuest(linkDown: linkDown, resume: resume) { failures.append($0.localizedDescription) }
        // Replies are in order, and `cont` goes out from `set_link`'s reply, so this waits long enough for both.
        try? await Task.sleep(for: .milliseconds(500))
        return (received.all, !failures.all.isEmpty)
    }

    @Test func aDisconnectedLinkGoesDownBeforeTheGuestRuns() async {
        let answer = await commands(linkDown: true, resume: false)
        #expect(answer.sent == ["set_link", "cont"])
        #expect(!answer.failed)
    }

    @Test func aPausedEmulatorIsResumed() async {
        #expect(await commands(linkDown: false, resume: true).sent == ["cont"])
    }

    @Test func aRunningOneIsLeftAlone() async {
        #expect(await commands(linkDown: false, resume: false).sent.isEmpty)
    }

    @Test func aRefusedLinkLeavesTheGuestPausedAndSaysSo() async {
        let answer = await commands(linkDown: true, resume: true, refusing: "set_link")
        #expect(answer.sent == ["set_link"])
        #expect(answer.failed)
    }
}
