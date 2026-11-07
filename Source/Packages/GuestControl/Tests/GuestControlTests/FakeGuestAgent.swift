import Foundation
import Synchronization

@testable import GuestControl

/// A QGA-compatible peer that never echoes IDs, like Apple's agent, and runs no real processes.
final class FakeGuestAgent: Sendable {
    struct Process: Sendable, Equatable {
        let path: String
        let arguments: [String]
        let captureOutput: Bool
        let input: String?
    }

    enum Outcome: Sendable {
        case finished(exitCode: Int, output: String = "")
        /// The reply to `guest-exec-status`, verbatim.
        case status(JSONValue)
        /// Never exits while the test runs.
        case running
        /// Refuses `guest-exec`, which also makes the client discard its stream.
        case refused
    }

    struct State: Sendable {
        var processes: [Process] = []
        var polls = 0
        var files: [String: Data] = [:]
        var chunkSizes: [Int] = []
        var closedHandles = 0
        var directories = 0
        var pending: [Int: Outcome] = [:]
        var pollsBeforeExit = 0
        var failWriteAtChunk: Int?
        var shortWrites = false
        var syncs = 0
        /// Status polls answered only after the client's five-second deadline, as from a guest that's slow to answer.
        var latePolls = 0
    }

    let state = Mutex(State())
    private let outcomes: @Sendable (Process) -> Outcome
    private let refusesHandshake: Bool
    private var server: FakeSocketServer { serverBox.withLock { $0! } }
    private let serverBox = Mutex<FakeSocketServer?>(nil)

    var path: String { server.path }

    init(
        refusesHandshake: Bool = false,
        outcomes: @escaping @Sendable (Process) -> Outcome = { _ in .finished(exitCode: 0) }
    ) {
        self.outcomes = outcomes
        self.refusesHandshake = refusesHandshake
        let server = FakeSocketServer { [weak self] peer in self?.run(peer) }
        serverBox.withLock { $0 = server }
    }

    func stop() { server.stop() }

    private func run(_ peer: FakePeer) {
        if refusesHandshake { return }
        var openHandles: [Int: String] = [:]
        while let request = peer.read(), let name = request["execute"]?.string {
            let arguments = request["arguments"] ?? [:]
            switch name {
            case "guest-sync-delimited":
                state.withLock { $0.syncs += 1 }
                peer.send(raw: Data([0xff]))
                peer.send(["return": arguments["id"] ?? .null])
            case "guest-exec":
                let process = Process(
                    path: arguments["path"]?.string ?? "",
                    arguments: arguments["arg"]?.foundationObject as? [String] ?? [],
                    captureOutput: arguments["capture-output"] == true,
                    input: arguments["input-data"]?.string
                )
                let outcome = outcomes(process)
                let pid = state.withLock { state in
                    state.processes.append(process)
                    let pid = state.processes.count + 41
                    state.pending[pid] = outcome
                    return pid
                }
                if case .refused = outcome {
                    peer.send(["error": ["desc": "refused"]])
                } else {
                    peer.send(["return": ["pid": .number(pid as NSNumber)]])
                }
            case "guest-exec-status":
                let late = state.withLock { state in
                    defer { state.latePolls = max(0, state.latePolls - 1) }
                    return state.latePolls > 0
                }
                if late { usleep(6_000_000) }
                peer.send(["return": status(pid: arguments["pid"]?.number?.intValue ?? 0)])
            case "guest-file-open":
                let handle = state.withLock { state in
                    state.files[arguments["path"]?.string ?? ""] = Data()
                    return openHandles.count + 1000
                }
                openHandles[handle] = arguments["path"]?.string
                peer.send(["return": .number(handle as NSNumber)])
            case "guest-file-write":
                let data = Data(base64Encoded: arguments["buf-b64"]?.string ?? "") ?? Data()
                let path = openHandles[arguments["handle"]?.number?.intValue ?? 0] ?? ""
                let reply: JSONValue = state.withLock { state in
                    if state.failWriteAtChunk == state.chunkSizes.count { return ["error": ["desc": "disk full"]] }
                    state.chunkSizes.append(data.count)
                    state.files[path, default: Data()].append(data)
                    let count = state.shortWrites ? data.count - 1 : data.count
                    return ["return": ["count": .number(count as NSNumber)]]
                }
                peer.send(reply)
            case "guest-file-close":
                state.withLock { $0.closedHandles += 1 }
                peer.send(["return": [:]])
            default:
                peer.send(["error": ["desc": .string("unexpected \(name)")]])
            }
        }
    }

    private func status(pid: Int) -> JSONValue {
        state.withLock { state in
            state.polls += 1
            switch state.pending[pid] {
            case .finished(let exitCode, let output):
                if state.pollsBeforeExit > 0 {
                    state.pollsBeforeExit -= 1
                    return ["exited": false]
                }
                return [
                    "exited": true, "exitcode": .number(exitCode as NSNumber),
                    "out-data": .string(Data(output.utf8).base64EncodedString())
                ]
            case .status(let reply): return reply
            default: return ["exited": false]
            }
        }
    }
}
