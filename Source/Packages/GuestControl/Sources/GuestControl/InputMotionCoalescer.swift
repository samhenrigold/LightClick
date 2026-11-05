import Foundation

/// Keeps pointer motion from queueing behind a slow control channel.
///
/// Each input batch is one QMP round trip, and the channel runs them one at a time. When the emulator's main loop waits
/// for the big lock, moves pile up on that queue, and a later click or key waits behind every stale position. The tablet
/// reports absolute positions, so only the newest unsent one matters: motion waits while a batch is outstanding, and the
/// newest goes out when the channel clears or just before the next other batch, so a click still lands where it was made.
@MainActor @objc(VIMInputMotionCoalescer)
public final class InputMotionCoalescer: NSObject {
    private let send: ([[String: Any]], @escaping () -> Void) -> Void
    private var outstandingBatches = 0
    private var heldMotion: [[String: Any]]?

    /// - Parameter send: Sends one batch, and calls its second argument on the main thread once the batch is answered.
    @objc(initWithSend:)
    public init(send: @escaping ([[String: Any]], @escaping () -> Void) -> Void) {
        self.send = send
    }

    @objc(submitEvents:)
    public func submit(_ events: [[String: Any]]) {
        if outstandingBatches > 0, events.allSatisfy({ $0["type"] as? String == "abs" }) {
            heldMotion = events
            return
        }
        sendHeldMotion()
        dispatch(events)
    }

    private func sendHeldMotion() {
        guard let motion = heldMotion else { return }
        heldMotion = nil
        dispatch(motion)
    }

    private func dispatch(_ events: [[String: Any]]) {
        outstandingBatches += 1
        send(events) { [weak self] in
            guard let self else { return }
            outstandingBatches -= 1
            if outstandingBatches == 0 { sendHeldMotion() }
        }
    }
}
