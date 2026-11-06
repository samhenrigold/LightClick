import Darwin
import Foundation

/// A Unix-domain stream carrying `LineFramer` lines, delivered on the main queue.
@MainActor
public final class LineSocket {
    private var descriptor: Int32
    private var source: (any DispatchSourceRead)?
    private var framer = LineFramer()
    public var onLine: ((Data) -> Void)?
    public var onClose: (() -> Void)?

    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// nil when nothing is listening at `path`.
    public static func connect(path: String) -> LineSocket? {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0, var address = unixAddress(path) else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(socket)
            return nil
        }
        return LineSocket(descriptor: socket)
    }

    public func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        source.resume()
        self.source = source
    }

    public func send(_ value: some Encodable) {
        guard descriptor >= 0, let data = try? LineFramer.encode(value) else { return }
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let wrote = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if wrote <= 0 { return }
                offset += wrote
            }
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = read(descriptor, &bytes, bytes.count)
        guard count > 0, let lines = try? framer.append(Data(bytes[0..<count])) else {
            stop()
            onClose?()
            return
        }
        for line in lines { onLine?(line) }
    }
}

/// The listening side, which is the session process in the app and the fake session in the probe.
@MainActor
public final class LineSocketListener {
    private let descriptor: Int32
    private var source: (any DispatchSourceRead)?
    private let path: String
    public var onAccept: ((LineSocket) -> Void)?

    public init?(path: String) {
        self.path = path
        unlink(path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0, var address = unixAddress(path) else { return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Only this user's proxies may connect: other local accounts mustn't drive a guest.
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else { return nil }
    }

    public func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let client = accept(self.descriptor, nil, nil)
                if client >= 0 { self.onAccept?(LineSocket(descriptor: client)) }
            }
        }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        close(descriptor)
        unlink(path)
    }
}

private func unixAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}
