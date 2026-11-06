import Testing

@testable import GuestControl

@MainActor
struct InputMotionCoalescerTests {
    @MainActor private final class Channel {
        var sent: [String] = []
        var answers: [() -> Void] = []

        func coalescer() -> InputMotionCoalescer {
            InputMotionCoalescer { events, answered in
                self.sent.append(events.first?["name"] as? String ?? "")
                self.answers.append(answered)
            }
        }

        func answerOldest() { answers.removeFirst()() }
    }

    private func motion(_ name: String) -> [[String: Any]] { [["type": "abs", "name": name]] }
    private func button(_ name: String) -> [[String: Any]] { [["type": "btn", "name": name]] }

    @Test func onlyTheNewestMotionFollowsAnOutstandingBatch() {
        let channel = Channel()
        let coalescer = channel.coalescer()
        coalescer.submit(motion("a"))
        coalescer.submit(motion("b"))
        coalescer.submit(motion("c"))
        #expect(channel.sent == ["a"])
        channel.answerOldest()
        #expect(channel.sent == ["a", "c"])
        channel.answerOldest()
        #expect(channel.answers.isEmpty)
    }

    @Test func otherBatchesAreNeverHeldAndKeepTheirPlaceAfterMotion() {
        let channel = Channel()
        let coalescer = channel.coalescer()
        coalescer.submit(motion("a"))
        coalescer.submit(motion("b"))
        coalescer.submit(button("down"))
        coalescer.submit(motion("c"))
        coalescer.submit(button("up"))
        #expect(channel.sent == ["a", "b", "down", "c", "up"])
    }

    @Test func heldMotionWaitsForEveryOutstandingBatch() {
        let channel = Channel()
        let coalescer = channel.coalescer()
        coalescer.submit(button("down"))
        coalescer.submit(button("up"))
        coalescer.submit(motion("a"))
        channel.answerOldest()
        #expect(channel.sent == ["down", "up"])
        channel.answerOldest()
        #expect(channel.sent == ["down", "up", "a"])
    }

    @Test func aBatchMixingMotionWithAButtonIsNotMotion() {
        let channel = Channel()
        let coalescer = channel.coalescer()
        coalescer.submit(motion("a"))
        coalescer.submit([["type": "abs", "name": "mixed"], ["type": "btn"]])
        #expect(channel.sent == ["a", "mixed"])
    }
}
