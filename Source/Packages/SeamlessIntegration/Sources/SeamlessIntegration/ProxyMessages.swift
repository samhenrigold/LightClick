import Foundation

/// What a proxy tells the session process.
public enum ProxyEvent: Codable, Hashable, Sendable {
    case hello(guestIdentifier: String, guestPath: String, pid: Int32)
    case openDocuments(paths: [String])
    case reopen
    case quit
    case activated
    case menuChosen(path: [String], viaKey: Bool)
    case menuWillOpen(path: [String])
    /// The host's drag, in window points with a top-left origin, for the guest's helper to mirror.
    case dragEntered(paths: [String], windowID: Int, x: Double, y: Double)
    case dragMoved(windowID: Int, x: Double, y: Double)
    case dragExited
    case dragDropped(windowID: Int, x: Double, y: Double)
    case pointerLeftWithButtonDown(windowID: Int)
    case promiseRequested(id: Int, destination: String)
    case dragOutEnded(accepted: Bool)
    case notificationPosted(error: String?)
}

/// What the session process tells a proxy. All of it derives from the guest, so it stays data: a proxy shows it and never
/// runs it or treats a name as a path.
public enum SessionCommand: Codable, Hashable, Sendable {
    case setMenuBar([GuestMenuItem])
    case setDockMenu([GuestMenuItem])
    case setBadge(String?)
    case requestAttention(critical: Bool)
    case notify(title: String, body: String, identifier: String)
    case noteRecentDocument(path: String)
    case activate
    case terminate
    /// A guest drag has reached the edge of a window: start the host's drag, with these names promised.
    case beginDragOut(names: [String], imagePNG: Data?)
    case promiseFulfilled(id: Int, error: String?)
    /// Until the surfaces land, a plain window that takes drops. `seamless-apps` replaces its content with hosted layers.
    case showPlaceholderWindow(id: Int, title: String, x: Double, y: Double, width: Double, height: Double)
}

/// Newline-separated JSON, capped so a misbehaving peer can't grow the buffer forever.
public struct LineFramer: Sendable {
    public static let maximumLine = 16 * 1024 * 1024
    private var buffer = Data()

    public init() {}

    public enum Failure: Error { case lineTooLong }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<newline]))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > Self.maximumLine { throw Failure.lineTooLong }
        return lines
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }
}
