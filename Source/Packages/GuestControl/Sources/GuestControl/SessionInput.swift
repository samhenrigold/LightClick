import Foundation

/// Where a session's keyboard and pointer events go: a click while the guest sleeps wakes it and is otherwise dropped,
/// and the rest are calibrated and sent, with pointer motion coalesced unless each send must get its own reply.
@MainActor @objc(VIMSessionInput)
public final class SessionInput: NSObject {
    public typealias Execute = (String, [String: Any], @escaping @Sendable (Any?, NSError?) -> Void) -> Void

    private let execute: Execute
    private var coalescer: InputMotionCoalescer?
    private var wakePending = false

    @objc public var isSuspended: () -> Bool = { false }
    @objc public var tabletTrim: () -> Int = { 0 }
    /// A diagnostic is timing every reply, so each batch goes out by itself.
    @objc public var sendsEachBatchAlone: () -> Bool = { false }
    @objc public var woke: () -> Void = {}
    @objc public var wakeFailed: (NSError) -> Void = { _ in }
    @objc public var sendFailed: (NSError) -> Void = { _ in }
    /// Called as a batch goes out. What it returns is called with the batch's answer.
    @objc public var willSend: () -> (NSError?) -> Void = { { _ in } }

    /// `coalesces` is off with VIM_INPUT_COALESCE=0, which sends every move as its own round trip again.
    @objc(initWithCoalescing:execute:)
    public init(coalesces: Bool, execute: @escaping Execute) {
        self.execute = execute
        super.init()
        if coalesces {
            coalescer = InputMotionCoalescer { [weak self] events, answered in
                self?.send(events, answered: answered)
            }
        }
    }

    @objc(submitEvents:)
    public func submit(_ events: [[String: Any]]) {
        if isSuspended() {
            wake()
            return
        }
        let calibrated = TabletCalibration.events(from: events, trim: tabletTrim())
        if let coalescer, !sendsEachBatchAlone() {
            coalescer.submit(calibrated)
        } else {
            send(calibrated, answered: nil)
        }
    }

    private func wake() {
        guard !wakePending else { return }
        wakePending = true
        execute("system_wakeup", [:]) { [weak self] _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wakePending = false
                if let error {
                    self.wakeFailed(error)
                } else {
                    self.woke()
                }
            }
        }
    }

    private func send(_ events: [[String: Any]], answered: (() -> Void)?) {
        let finished = willSend()
        let answer = MainThreadAnswer(finished: finished, answered: answered)
        execute("input-send-event", ["events": events]) { [weak self] _, error in
            MainActor.assumeIsolated {
                answer.finished(error)
                if let error { self?.sendFailed(error) }
                answer.answered?()
            }
        }
    }
}

/// Closures that only ever run on main, carried through a `@Sendable` completion that also runs there.
private struct MainThreadAnswer: @unchecked Sendable {
    let finished: (NSError?) -> Void
    let answered: (() -> Void)?
}
