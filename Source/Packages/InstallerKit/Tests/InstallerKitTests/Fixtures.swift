// Shared fixtures: the app's real catalog from the source tree, private directories, and a URLProtocol stub. Nothing here
// reaches the network. Everything using the stub lives under StubbedNetwork, which serializes it.
import CryptoKit
import Foundation
import Testing

@testable import InstallerKit

/// The tests that share StubURLProtocol's one handler.
@Suite(.serialized) enum StubbedNetwork {}

enum Fixture {
    /// Source/, from Source/Packages/InstallerKit/Tests/InstallerKitTests/Fixtures.swift.
    static let sourceRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let catalogData: Data = {
        // A missing catalog fails every test that needs it, on the line that says why.
        (try? Data(contentsOf: sourceRoot.appending(path: "VirtualIntelMac/InstallerCatalog.plist"))) ?? Data()
    }()

    /// The real catalog after `change` edits its mutable property list.
    static func catalog(_ change: (NSMutableDictionary) -> Void = { _ in }) throws -> Data {
        let plist = try #require(
            PropertyListSerialization.propertyList(
                from: catalogData, options: .mutableContainersAndLeaves, format: nil) as? NSMutableDictionary)
        change(plist)
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func catalog(revision: Any) throws -> Data {
        try catalog { $0["Revision"] = revision }
    }

    static func entry(_ plist: NSMutableDictionary, _ guest: Guest) -> NSMutableDictionary {
        (plist["Installers"] as? NSArray)?.compactMap { $0 as? NSMutableDictionary }
            .first { $0["Guest"] as? String == guest.rawValue } ?? [:]
    }

    static func files(_ plist: NSMutableDictionary, _ guest: Guest) -> NSMutableArray {
        entry(plist, guest)["Files"] as? NSMutableArray ?? []
    }

    static func file(_ plist: NSMutableDictionary, _ guest: Guest) -> NSMutableDictionary {
        files(plist, guest)[0] as? NSMutableDictionary ?? [:]
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `count` bytes that make a shifted or repeated range visible.
    static func payload(count: Int) -> Data {
        var data = Data(capacity: count)
        var block = 0
        while data.count < count {
            data.append(contentsOf: "\(block)|".utf8)
            block += 1
        }
        return Data(data.prefix(count))
    }
}

/// A private directory, removed when the test lets go of it.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(component: "InstallerKitTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What the stub answers one request with.
struct StubResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    /// Keeps the connection open after the chunks, until the client cancels.
    var stalls = false
    var error: URLError.Code?

    static func body(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(status: status, headers: headers, chunks: [Data(text.utf8)])
    }
}

/// Answers every request from a handler, and records them with their bodies.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> StubResponse

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler = { _ in StubResponse(status: 500) }
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    private let stopped = NSCondition()
    private var isStopped = false

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    static var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    @Sendable static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        if let stream = request.httpBodyStream {
            request.httpBody = Self.drain(stream)
        }
        let response = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.handler(request)
        }
        let finished = HTTPURLResponse(
            url: request.url ?? Fixture.sourceRoot, statusCode: response.status, httpVersion: "HTTP/1.1",
            headerFields: response.headers)
        DispatchQueue.global().async { [self] in
            if let code = response.error {
                client?.urlProtocol(self, didFailWithError: URLError(code))
                return
            }
            guard let finished else { return }
            client?.urlProtocol(self, didReceive: finished, cacheStoragePolicy: .notAllowed)
            for chunk in response.chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            if response.stalls {
                stopped.lock()
                while !isStopped {
                    stopped.wait()
                }
                stopped.unlock()
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        stopped.withLock {
            isStopped = true
            stopped.broadcast()
        }
    }

    private static func drain(_ stream: InputStream) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        stream.open()
        defer { stream.close() }
        while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
            data.append(buffer, count: count)
        }
        return data
    }
}
