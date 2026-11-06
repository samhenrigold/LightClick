import Foundation

/// A rectangle of a guest window that a material shows through, in points from the window's top left. `material` is WindowServer's.
public struct GuestMaterial: Codable, Hashable, Sendable {
    public var material: Int
    public var active: Bool
    public var x, y, width, height: Double

    public init(material: Int, active: Bool, x: Double, y: Double, width: Double, height: Double) {
        self.material = material
        self.active = active
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// What a proxy tells the session process.
public enum ProxyEvent: Codable, Hashable, Sendable {
    case hello(guestIdentifier: String, guestPath: String, pid: Int32)
    case openDocuments(paths: [String])
    case reopen
    case quit
    case activated
    /// What the Dock tile's label says after a `setBadge`, as AppKit has it.
    case tileBadge(String?)
    case menuChosen(path: [String], viaKey: Bool)
    case menuWillOpen(path: [String])
    /// The host's drag, in window points with a top-left origin, for the guest's helper to mirror.
    case dragEntered(paths: [String], windowID: Int, x: Double, y: Double)
    case dragMoved(windowID: Int, x: Double, y: Double)
    case dragExited
    /// The user moved this window on the host, which the guest's doesn't follow. Its new place, down from the top of the primary screen.
    case surfaceMoved(windowID: Int, x: Double, y: Double)
    /// The host's Dock or the user took this window there or brought it back, not the guest.
    case surfaceMinimized(windowID: Int, minimized: Bool)
    case dragDropped(windowID: Int, x: Double, y: Double)
    case pointerLeftWithButtonDown(windowID: Int)
    case promiseRequested(id: Int, destination: String)
    case dragOutEnded(accepted: Bool)
    case notificationPosted(error: String?)
    case guestMenuBarClicked(x: Double, y: Double)
    /// Pointer, trackpad and keys, already in the seamless wire format, for the session to pass on.
    case input(bytes: Data)
    /// Facts only the proxy's process can read, for the probe.
    case menuBarState(
        presentationOptions: UInt, menuBarVisible: Bool, safeTop: Double, notchLeft: Double, notchRight: Double,
        screenWidth: Double)
}

/// What the session process tells a proxy. All of it derives from the guest, so it stays data: a proxy shows it and never
/// runs it or treats a name as a path.
public enum SessionCommand: Codable, Hashable, Sendable {
    case setMenuBar([GuestMenuItem])
    case minimizeSurface(id: Int, minimized: Bool)
    case setMaterials(id: Int, [GuestMaterial])
    case setDockMenu([GuestMenuItem])
    case setBadge(String?)
    case requestAttention(critical: Bool)
    case notify(title: String, body: String, identifier: String)
    case noteRecentDocument(path: String)
    case activate
    case terminate
    /// The app can't run, and why. The proxy is what the user is looking at, as nothing else of the session shows.
    case showError(String)
    /// A guest drag has reached the edge of a window: start the host's drag, with these names promised.
    case beginDragOut(names: [String], imagePNG: Data?)
    case promiseFulfilled(id: Int, error: String?)
    /// Until the surfaces land, a plain window that takes drops. `seamless-apps` replaces its content with hosted layers.
    /// Mode B: the guest's own menu bar in a window over the host's, with the host's hidden while this app is active.
    case showGuestMenuBar(height: Double, autoHide: Bool)
    case hideGuestMenuBar
    case reportMenuBarState
    case showPlaceholderWindow(id: Int, title: String, x: Double, y: Double, width: Double, height: Double)
    /// One guest window: a window on the host's screen that shows the layer `contextID` names, hosted from the session.
    /// `margin` is how far the content sits inside it, the rest being its shadow. `offset` turns host screen points into
    /// guest ones.
    case showSurface(
        id: Int, contextID: UInt32, x: Double, y: Double, width: Double, height: Double, margin: Double, level: Int,
        alpha: Double, order: Int, title: String, offsetX: Double, offsetY: Double)
    case removeSurface(id: Int)
    /// For a test with nobody at the host: the proxy clicks and types into its own front window's input view.
    case testInput
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
