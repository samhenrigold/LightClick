// A controlled local peer for the control channel: no QEMU, VM, disk, host input or extra monitor client.

import Darwin
import Foundation
import Synchronization

@testable import GuestControl

/// One accepted client. Blocking, because each script runs on its own thread.
final class FakePeer {
    private let descriptor: Int32
    private var buffer = Data()

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The next request. `hadSentinel` reports whether 0xFF came before it.
    func readRequest() -> (request: [String: JSONValue], hadSentinel: Bool)? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                var line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                let hadSentinel = line.first == 0xff
                if hadSentinel { line.removeFirst() }
                guard let parsed = try? JSONSerialization.jsonObject(with: line),
                    let object = JSONValue(foundationObject: parsed)?.object
                else { return nil }
                return (object, hadSentinel)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<count])
        }
    }

    func read() -> [String: JSONValue]? { readRequest()?.request }

    func send(_ object: JSONValue) {
        guard let json = try? JSONSerialization.data(withJSONObject: object.foundationObject) else { return }
        send(raw: json + [0x0a])
    }

    func send(raw: Data) {
        raw.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    /// Answers the QMP greeting and capabilities exchange.
    func acceptQMPHandshake() {
        send(["QMP": [:]])
        guard let capabilities = read(), let id = capabilities["id"] else { return }
        send(["return": [:], "id": id])
    }
}

/// Listens on a Unix socket in a private directory and runs a script for each accepted client.
final class FakeSocketServer: Sendable {
    let path: String
    private let directory: String
    private let listener: Int32
    private let isStopped = Mutex(false)
    private let finished = DispatchGroup()

    /// The socket path has to fit `sun_path`, which a long temporary directory wouldn't.
    static func makeDirectory() -> String {
        let base = NSTemporaryDirectory().utf8.count < 60 ? NSTemporaryDirectory() : "/tmp/"
        var template = Array((base + (base.hasSuffix("/") ? "" : "/") + "gc.XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { preconditionFailure("Private fixture directory") }
        return template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    init(script: @escaping @Sendable (FakePeer) -> Void) {
        directory = Self.makeDirectory()
        path = directory + "/s"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            _ = strlcpy(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), path, capacity)
        }
        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard didBind, listen(listener, 4) == 0 else { preconditionFailure("Local listener") }

        finished.enter()
        let listener = listener
        Thread.detachNewThread { [self] in
            defer { finished.leave() }
            while !isStopped.withLock({ $0 }) {
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 20) > 0 else { continue }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                finished.enter()
                Thread.detachNewThread { [finished] in
                    script(FakePeer(descriptor: client))
                    Darwin.close(client)
                    finished.leave()
                }
            }
        }
    }

    /// Waits for the scripts, which end when the client hangs up, then removes the socket.
    func stop() {
        isStopped.withLock { $0 = true }
        finished.wait()
        Darwin.close(listener)
        unlink(path)
        rmdir(directory)
    }
}

/// A thread-safe log shared between a script and its test.
final class Recorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    func append(_ value: Value) { values.withLock { $0.append(value) } }
    var all: [Value] { values.withLock { $0 } }
}
