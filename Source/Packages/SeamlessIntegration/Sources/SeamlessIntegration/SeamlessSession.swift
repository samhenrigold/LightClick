import AppKit
import Darwin
import IOSurface
import QuartzCore

/// What a session needs of the machine it runs on: the guest agent the app already holds.
@MainActor
public protocol SeamlessGuest: AnyObject {
    func run(_ path: String, _ arguments: [String]) async -> SeamlessGuestRun
    /// Whether the machine got as far as running. A machine another app has open never does.
    var isMachineRunning: Bool { get }
    /// Puts a host file in the guest, and says where.
    func stage(_ file: URL) async -> String?
}

public struct SeamlessGuestRun: Sendable {
    public var exitCode: Int?
    public var output: String
    public var failure: String?

    public init(exitCode: Int?, output: String, failure: String?) {
        self.exitCode = exitCode
        self.output = output
        self.failure = failure
    }
}

/// Where a guest window's own pixels come from, when something has them. Without one, or when it answers nil, a window is
/// cropped from the display's frames, which is the fallback. A source calls `windowPixelsChanged` on the session or desktop
/// when a window's surface has something new, which is the only damage it needs to report.
@MainActor
public protocol SeamlessPixelSource: AnyObject {
    /// `window` is the guest's window number. The surface holds it with real alpha, from `surfaceOrigin` on the guest's display,
    /// and can be bigger than it.
    func surface(forWindow window: UInt32) -> IOSurfaceRef?
    /// Where it starts on the guest's display, if the surface itself says. Otherwise the guest's tool does.
    func surfaceOrigin(forWindow window: UInt32) -> (x: Int32, y: Int32)?
    /// Whether windows are coming this way now, which leaves the display's frames with nothing current in them.
    var hasSurfaces: Bool { get }
}

/// One guest app as a host app. Listens for its proxy and for the tool it starts in the guest, shows each of the guest's
/// windows as a layer the proxy hosts, and passes everything else across. The design is `probes/seamless-apps-design.md`.
@MainActor
public final class SeamlessSession {
    public struct Configuration: Sendable {
        public var socketPath: String
        public var guestApp: String
        /// Holds `seamless-guest` and `seamless-integration-guest`, the x86_64 programs for the guest.
        public var tools: URL
        public var log: URL

        public init(socketPath: String, guestApp: String, tools: URL, log: URL) {
            self.socketPath = socketPath
            self.guestApp = guestApp
            self.tools = tools
            self.log = log
        }
    }

    private final class Surface {
        var window: SessionWire.Window
        let context: NSObject
        let layer: CALayer
        var image: CGImage?
        var cropped = false
        /// Its shape is `image`'s alpha, rather than a rectangle with the host's corners.
        var overlay = false
        /// The parts of a covered window nothing's in front of, live, over `image`.
        var pieces: [CALayer] = []
        /// Where the user dragged it to, relative to the guest's window, once they have. The guest's window stays put.
        var hostOffset: NSPoint?
        /// Where its own surface starts on the guest's display, with its shadow, once the guest has said.
        var surfaceOrigin: (x: Int32, y: Int32)?
        var ownSurfaceLayer: CALayer?
        var guestCovers: [CGRect]?
        var materials: [GuestMaterial] = []
        init(window: SessionWire.Window, context: NSObject, layer: CALayer) {
            self.window = window
            self.context = context
            self.layer = layer
        }
    }

    private let configuration: Configuration
    private let guest: any SeamlessGuest
    private let finished: () -> Void
    private var surfaces: [UInt32: Surface] = [:]
    private var proxy: LineSocket?
    private var proxyPID: Int32 = 0
    private var guestDescriptor: Int32 = -1
    private var everConnected = false
    private var port: UInt16 = 0
    /// Added to a guest window's position to get its place on the host. If it's not set, the first window goes mid-screen.
    public var guestOffset: NSPoint?
    /// Whether this runs its own program in the guest, or something else starts one on `guestPort`.
    public var drivesGuest = true
    public var guestPort: UInt16 { port }
    public var windowCount: Int { surfaces.count }
    /// A menu item and Dock menu item with this title calls `onLeave`, rather than going to the guest, and so does asking the proxy to quit.
    public var leaveTitle: String?
    public var onLeave: (() -> Void)?
    public var onWindowsChanged: (() -> Void)?
    /// Whether the guest app had gone first.
    public var onProxyClosed: ((Bool) -> Void)?
    public var onGuestGone: (() -> Void)?
    private var appGone = false
    private var stopped = false
    private var activateWhenConnected = false
    private var lastMenu: [GuestMenuItem]?
    private var nextDocument: UInt32 = 0
    private var documentPaths: [UInt32: String] = [:]
    private var documentsComing: [UInt32: Data] = [:]
    private var documentsWaiting: [String] = []
    private var guestDragFiles: [String] = []
    private var logHandle: FileHandle?
    public var test: SeamlessSessionTest?
    public weak var pixelSource: (any SeamlessPixelSource)?
    /// Crop each window from the frames windowed mode shows, rather than capture it. Set before `start`.
    public var usesDisplayFrames = false
    /// For measuring: quit the guest app this long after its first window.
    public var stopAfter: Double?
    private var frame: (surface: IOSurfaceRef, width: Int, height: Int)?
    private var copies = FrameCopies()
    private var arrived = 0
    private var measuring: (started: CFAbsoluteTime, arrived: Int, distinct: Int)?
    public var distinctFrames: (() -> Int)?
    private var testStarted = false
    private let placeholderFrame: (surface: IOSurfaceRef, width: Int, height: Int)? = IOSurfaceCreate(
        [kIOSurfaceWidth: 1, kIOSurfaceHeight: 1, kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: 0x4247_5241] as CFDictionary
    ).map { ($0, 1, 1) }

    public init(configuration: Configuration, guest: any SeamlessGuest, finished: @escaping () -> Void) {
        self.configuration = configuration
        self.guest = guest
        self.finished = finished
    }

    public func start() {
        signal(SIGPIPE, SIG_IGN)
        // A desktop's session for an app can start many times, and each keeps what the one before said.
        if !drivesGuest, FileManager.default.fileExists(atPath: configuration.log.path) {
        } else {
            FileManager.default.createFile(
                atPath: configuration.log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        logHandle = try? FileHandle(forWritingTo: configuration.log)
        _ = try? logHandle?.seekToEnd()
        guard listenForGuest(), listenForProxy() else {
            note("ERROR couldn't listen")
            finished()
            return
        }
        if drivesGuest { Task { await self.drive() } }
    }

    /// shortcut: the threads waiting on the listeners stay, blocked, with no session to deliver to: two per app per Seamless press,
    /// until something needs them gone.
    public func stop() {
        stopped = true
        proxy?.send(SessionCommand.terminate)
        if guestDescriptor >= 0 { shutdown(guestDescriptor, SHUT_RDWR) }
        surfaces = [:]
    }

    public func activateProxy() {
        if let proxy {
            proxy.send(SessionCommand.activate)
        } else {
            activateWhenConnected = true
        }
    }

    public func note(_ text: String) {
        logHandle?.write(Data((text + "\n").utf8))
    }

    // MARK: The guest's side

    private func drive() async {
        // A guest can restart itself early in a boot, which ends the agent's connection under whatever was running. Nothing
        // has reached the user yet, so that only means starting over.
        for attempt in 1...3 {
            guard let ran = await runInGuest() else { return }
            note(
                "# the guest's side ended, exit \(ran.exitCode.map(String.init) ?? "none")\n\(ran.output)\n\(ran.failure ?? "")"
            )
            if ran.exitCode != nil || everConnected || attempt == 3 { break }
            note("# trying again")
        }
        proxy?.send(SessionCommand.terminate)
        finished()
    }

    private func runInGuest() async -> SeamlessGuestRun? {
        let started = CFAbsoluteTimeGetCurrent()
        // Starting is asynchronous, so give it a moment before believing it didn't.
        while !guest.isMachineRunning {
            if CFAbsoluteTimeGetCurrent() - started > 30 {
                proxy?.send(
                    SessionCommand.showError(
                        "This app’s Mac couldn’t start. If it’s open in Light Click, shut it down there, then try again."
                    ))
                fail("the machine isn't running")
                return nil
            }
            try? await Task.sleep(for: .seconds(1))
        }
        // The agent isn't there until well into the boot, and answers with an error until it is.
        while await guest.run("/usr/bin/uname", ["-r"]).exitCode != 0 {
            if CFAbsoluteTimeGetCurrent() - started > 900 {
                fail("no answer from the guest")
                return nil
            }
            try? await Task.sleep(for: .seconds(5))
        }
        guard let tool = await guest.stage(configuration.tools.appending(path: "seamless-guest")),
            let menuTool = await guest.stage(configuration.tools.appending(path: "seamless-integration-guest"))
        else {
            fail("couldn't put the programs in the guest")
            return nil
        }
        let setup = await guest.run("/bin/sh", ["-c", Self.setupScript, "sh", tool, menuTool])
        note("# set up: exit \(setup.exitCode.map(String.init) ?? "none"), \(setup.output)\(setup.failure ?? "")")
        note("# running \(configuration.guestApp) in the guest")
        var arguments = [
            "SEAMLESS_RUN_IN_PLACE=1", "/tmp/sg/g", "tree", "--app", configuration.guestApp, "--open", "--session",
            "--hook",
            "--menu-tool", "/tmp/sg/ig", "--port", String(port), "--seconds", "0"
        ]
        if test != nil { arguments.append("--test-badge") }
        if usesDisplayFrames { arguments.append("--no-pixels") }
        return await guest.run("/usr/bin/env", arguments)
    }

    private func fail(_ why: String) {
        note("# ERROR the session stopped: \(why)")
        proxy?.send(SessionCommand.terminate)
        finished()
    }

    /// Copies the tools somewhere stable, and grants Accessibility for reading and pressing the app's menu. 10.9 asks TCC
    /// about the responsible process, and from a daemon that's the agent.
    static var setupScript: String {
        let clients = [
            "/private/tmp/sg/ig", "/tmp/sg/ig", "/private/tmp/sg/g", "/usr/bin/sudo", "/usr/bin/env", "/bin/launchctl",
            "/Library/Application Support/Virtual Intel Mac/GuestTools/opengl-install-bootstrap"
        ]
        let rows = clients.map {
            "INSERT OR REPLACE INTO access (service,client,client_type,allowed,prompt_count) VALUES "
                + "('kTCCServiceAccessibility','\($0)',1,1,1);"
        }
        // The agent is in a different place on other guests, and it's this script's parent.
        let agentRow =
            "INSERT OR REPLACE INTO access (service,client,client_type,allowed,prompt_count) VALUES "
            + "('kTCCServiceAccessibility','$(/bin/ps -o comm= -p $PPID)',1,1,1);"
        return
            "mkdir -p /tmp/sg; chmod 755 /tmp/sg; cp \"$1\" /tmp/sg/g; cp \"$2\" /tmp/sg/ig; chmod 755 /tmp/sg/g /tmp/sg/ig; "
            + "/usr/bin/sqlite3 \"/Library/Application Support/com.apple.TCC/TCC.db\" \"\(rows.joined())\(agentRow)\" 2>&1; "
            + "/bin/ps -o comm= -p $PPID; /usr/bin/killall tccd; sleep 2"
    }

    private func listenForGuest() -> Bool {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, size) == 0 && getsockname(listener, $0, &size) == 0
            }
        }
        guard bound, listen(listener, 1) == 0 else { return false }
        port = UInt16(bigEndian: address.sin_port)
        note("Listening on 127.0.0.1:\(port), which a guest reaches as 10.0.2.2:\(port)")
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { continue }
                var on: Int32 = 1
                setsockopt(client, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self?.guestConnected(client) }
                }
                Self.serve(client) { messages in
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated { messages.apply(to: self) }
                    }
                }
                close(client)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.guestDisconnected() }
                }
            }
        }
        return true
    }

    private func guestConnected(_ descriptor: Int32) {
        guestDescriptor = descriptor
        everConnected = true
        let waiting = documentsWaiting
        documentsWaiting = []
        for path in waiting { sendDocument(path, flags: 0) }
    }

    private func guestDisconnected() {
        guestDescriptor = -1
        for id in surfaces.keys { proxy?.send(SessionCommand.removeSurface(id: Int(id))) }
        surfaces = [:]
        if !stopped {
            onWindowsChanged?()
            onGuestGone?()
        }
    }

    /// One message off the wire, with the pixels already made into an image so the main thread doesn't copy them.
    private struct Delivery: @unchecked Sendable {
        var message: SessionWire.Message
        var image: CGImage?

        @MainActor func apply(to session: SeamlessSession?) { session?.apply(message, image: image) }
    }

    /// Runs on the reading thread, so a slow main thread throttles the guest. Each window's pixels live here.
    private nonisolated static func serve(_ client: Int32, deliver: (Delivery) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var have = 0
        var pixels: [UInt32: (width: UInt32, height: UInt32, data: UnsafeMutablePointer<UInt8>)] = [:]
        defer { for entry in pixels.values { entry.data.deallocate() } }
        let space = CGColorSpaceCreateDeviceRGB()
        while true {
            let received = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress! + have, $0.count - have, 0) }
            if received <= 0 { return }
            have += received
            var offset = 0
            parsing: while true {
                let (parsed, image): (SessionWire.Parsed, CGImage?) = buffer.withUnsafeBytes { all in
                    let bytes = UnsafeRawBufferPointer(rebasing: all[offset..<have])
                    let parsed = SessionWire.parse(bytes)
                    guard case .message(.frame(let frame), _) = parsed else { return (parsed, nil) }
                    var entry = pixels[frame.window]
                    if entry?.width != frame.fullWidth || entry?.height != frame.fullHeight {
                        entry?.data.deallocate()
                        let size = Int(frame.fullWidth) * Int(frame.fullHeight) * 4
                        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                        data.initialize(repeating: 0, count: size)
                        entry = (frame.fullWidth, frame.fullHeight, data)
                        pixels[frame.window] = entry
                    }
                    let stride = Int(frame.fullWidth) * 4
                    let row = Int(frame.width) * 4
                    for y in 0..<Int(frame.height) {
                        memcpy(
                            entry!.data + (Int(frame.y) + y) * stride + Int(frame.x) * 4,
                            bytes.baseAddress! + frame.pixelOffset + y * row, row)
                    }
                    let context = CGContext(
                        data: entry!.data, width: Int(frame.fullWidth), height: Int(frame.fullHeight),
                        bitsPerComponent: 8,
                        bytesPerRow: stride, space: space,
                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                            | CGImageAlphaInfo.premultipliedFirst.rawValue)
                    return (parsed, context?.makeImage())
                }
                switch parsed {
                case .bad:
                    return
                case .needMore(let size):
                    if let size, size > buffer.count {
                        buffer.append(contentsOf: repeatElement(0, count: size - buffer.count))
                    }
                    break parsing
                case .message(let message, let used):
                    deliver(Delivery(message: message, image: image))
                    offset += used
                }
            }
            buffer.withUnsafeMutableBytes { memmove($0.baseAddress!, $0.baseAddress! + offset, have - offset) }
            have -= offset
        }
    }

    private func apply(_ message: SessionWire.Message, image: CGImage?) {
        switch message {
        case .hello(let version): if version != 2 { note("# guest protocol \(version), not 2") }
        case .window(let window): show(window)
        case .frame(let frame):
            guard let surface = surfaces[frame.window], let image else { return }
            surface.image = image
            if surface.cropped, self.frame != nil {
                showCrops(of: [surface])
                return
            }
            surface.cropped = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.layer.contents = image
            surface.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            surface.layer.cornerRadius = 0
            CATransaction.commit()
            CATransaction.flush()
        case .crop(let id), .overlay(let id):
            guard let surface = surfaces[id] else { return }
            surface.cropped = true
            if case .overlay = message { surface.overlay = true } else { surface.overlay = false }
            showCrops(of: [surface])
        case .covers(let id, let rects):
            surfaces[id]?.guestCovers = rects
            if let surface = surfaces[id] { showCrops(of: [surface]) }
        case .materials(let id, let rows):
            surfaces[id]?.materials = rows
            proxy?.send(SessionCommand.setMaterials(id: Int(id), rows))
        case .minimized(let id, let minimized):
            note("# window \(id) \(minimized ? "minimized" : "back")")
            proxy?.send(SessionCommand.minimizeSurface(id: Int(id), minimized: minimized))
        case .surfaceOrigin(let id, let x, let y):
            surfaces[id]?.surfaceOrigin = (x, y)
            if let surface = surfaces[id] { showCrops(of: [surface]) }
        case .gone(let id):
            note("# window \(id) gone")
            surfaces[id] = nil
            proxy?.send(SessionCommand.removeSurface(id: Int(id)))
            onWindowsChanged?()
        case .menu(let json):
            guard var items = try? JSONDecoder().decode([GuestMenuItem].self, from: json) else { return }
            // In the app's own menu, above Quit.
            if let leaveTitle, !items.isEmpty, var children = items[0].children {
                children.insert(GuestMenuItem(title: leaveTitle), at: max(0, children.count - 1))
                items[0].children = children
            }
            lastMenu = items
            proxy?.send(SessionCommand.setMenuBar(items))
            startTestOnce()
        case .document(let piece): receive(piece)
        case .dragState(let json): beginDragOut(json)
        case .appState(let json): applyAppState(json)
        case .appGone:
            note("# the guest app has exited")
            appGone = true
            proxy?.send(SessionCommand.terminate)
        }
    }

    private func sendToGuest(_ data: Data) {
        guard guestDescriptor >= 0 else { return }
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let wrote = send(guestDescriptor, bytes.baseAddress! + sent, bytes.count - sent, 0)
                if wrote <= 0 { return }
                sent += wrote
            }
        }
    }

    // MARK: Windows

    private func show(_ window: SessionWire.Window) {
        let surface: Surface
        if let existing = surfaces[window.id] {
            surface = existing
        } else {
            guard let made = makeSurface(window) else { return }
            surface = made
            surfaces[window.id] = made
        }
        surface.window = window
        tellProxy(surface)
        onWindowsChanged?()
        if let stopAfter, measuring == nil {
            measuring = (CFAbsoluteTimeGetCurrent(), arrived, distinctFrames?() ?? 0)
            note("# first window")
            // Past the window's opening, then over the same time windowed mode was measured for.
            DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter - 22) {
                MainActor.assumeIsolated {
                    self.measuring = (CFAbsoluteTimeGetCurrent(), self.arrived, self.distinctFrames?() ?? 0)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter) {
                MainActor.assumeIsolated {
                    if let measuring = self.measuring {
                        let seconds = CFAbsoluteTimeGetCurrent() - measuring.started
                        let distinct = Double((self.distinctFrames?() ?? 0) - measuring.distinct)
                        self.note(
                            String(
                                format: "# frames: %.1f/s, %.1f distinct, over %.0f s",
                                Double(self.arrived - measuring.arrived) / seconds,
                                distinct / seconds, seconds))
                    }
                    self.handle(.quit)
                }
            }
        }
        // A guest whose menu can't be read still gets its test.
        if test != nil, !testStarted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                MainActor.assumeIsolated { self.startTestOnce() }
            }
        }
    }

    /// A layer in a context of this process, which the proxy's `CALayerHost` shows by its ID. Both are private classes, and
    /// work across processes with SIP on, per the design document.
    private func makeSurface(_ window: SessionWire.Window) -> Surface? {
        typealias Make = @convention(c) (AnyObject, Selector, Int32, NSDictionary) -> NSObject
        typealias Connection = @convention(c) () -> Int32
        guard let contextClass = NSClassFromString("CAContext") as? NSObject.Type,
            let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let connection = dlsym(sky, "SLSMainConnectionID")
        else { return nil }
        let selector = NSSelectorFromString("contextWithCGSConnection:options:")
        let make = unsafeBitCast(contextClass.method(for: selector), to: Make.self)
        let context = make(
            contextClass, selector, unsafeBitCast(connection, to: Connection.self)(),
            ["kCAContextCIFilterBehavior": "ignore"])
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.contentsGravity = .resize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        context.setValue(layer, forKey: "layer")
        CATransaction.commit()
        return Surface(window: window, context: context, layer: layer)
    }

    private func tellProxy(_ surface: Surface) {
        let window = surface.window
        let primary = NSScreen.screens.first?.frame.height ?? 0
        if guestOffset == nil {
            // Keeps this first window's guest position on the host's screen, near the middle.
            let screen = NSScreen.main?.visibleFrame ?? .zero
            guestOffset = NSPoint(
                x: screen.midX - (Double(window.x) + Double(window.width) / 2),
                y: primary - screen.midY - (Double(window.y) + Double(window.height) / 2))
        }
        // What pops up from a window goes where that window has been dragged.
        let parent = surfaces.values.filter { $0.hostOffset != nil && $0.window.group == window.group }
            .min { $0.window.order < $1.window.order }
        let front = surfaces.values.filter { $0.hostOffset != nil && !$0.overlay && !$0.window.title.isEmpty }
            .min { $0.window.order < $1.window.order }
        let offset = surface.hostOffset ?? parent?.hostOffset ?? (surface.overlay ? front?.hostOffset : nil) ?? guestOffset ?? .zero
        let side = Double(window.margin)
        let width = Double(window.width) + 2 * side
        let height = Double(window.height) + 2 * side
        let x = Double(window.x) - side + offset.x
        let y = primary - (Double(window.y) - side + offset.y) - height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        CATransaction.commit()
        // Its place may have covered or uncovered others.
        showCrops(of: Array(surfaces.values))
        proxy?.send(
            SessionCommand.showSurface(
                id: Int(window.id),
                contextID: (surface.context.value(forKey: "contextId") as? NSNumber)?.uint32Value ?? 0,
                x: x, y: y, width: width, height: height, margin: side, level: Int(window.level),
                alpha: Double(window.alpha) / 65536, order: Int(window.order), title: window.title, offsetX: offset.x,
                offsetY: offset.y))
    }

    //     // MARK: Windowed mode's frames

    /// One frame of the guest's display, as windowed mode gets it. Everything shows the same surface, each through its own crop.
    public func frameArrived(surface: IOSurfaceRef?, bytes: UnsafeRawPointer?, width: Int, height: Int, stride: Int) {
        arrived += 1
        guard usesDisplayFrames, let current = surface ?? copies.copy(bytes, width: width, height: height, stride: stride)
        else { return }
        frame = (current, width, height)
        guard !surfaces.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for surface in surfaces.values where surface.cropped { crop(surface, from: (current, width, height)) }
        CATransaction.commit()
        CATransaction.flush()
    }

    public func windowPixelsChanged(_ id: UInt32) {
        guard let surface = surfaces[id] else { return }
        surface.cropped = true
        showCrops(of: [surface])
    }

    private func showCrops(of list: [Surface]) {
        // With every window's own surface coming, there may never be a display frame.
        guard let frame = frame ?? pixelSource.flatMap({ _ in placeholderFrame }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for surface in list where surface.cropped { crop(surface, from: frame) }
        CATransaction.commit()
        CATransaction.flush()
    }

    private func crop(_ surface: Surface, from frame: (surface: IOSurfaceRef, width: Int, height: Int)) {
        let window = surface.window
        let side = Double(window.margin)
        let whole = CGRect(x: 0, y: 0, width: Double(window.width) + 2 * side, height: Double(window.height) + 2 * side)
        let scale = whole.width > 0 ? Double(window.pixelWidth) / whole.width : 1
        let fullWidth = Double(frame.width)
        let fullHeight = Double(frame.height)
        // contentsRect counts up from the bottom of the surface, and guest windows down from the top of the display.
        func place(_ part: CGRect) -> CGRect {
            CGRect(
                x: (Double(window.x) - side + part.minX) * scale / fullWidth,
                y: (fullHeight - (Double(window.y) - side + part.maxY) * scale) / fullHeight,
                width: part.width * scale / fullWidth, height: part.height * scale / fullHeight)
        }
        let layer = surface.layer
        if let own = pixelSource?.surface(forWindow: window.id) {
            // Until the guest says, at its window's place, which is right but for any shadow: with the display off, this is all there is.
            let origin = pixelSource?.surfaceOrigin(forWindow: window.id) ?? surface.surfaceOrigin ?? (window.x, window.y)
            setPieces(of: surface, to: [], from: own, place: place, height: whole.height)
            layer.mask = nil
            layer.contents = nil
            layer.cornerRadius = 0
            layer.masksToBounds = true
            // Placed whole, where it is on the guest's display, rather than cropped: past the window there's only its shadow,
            // then transparency. A layer behind this one is where a host material would go.
            let sublayer = surface.ownSurfaceLayer ?? CALayer()
            if surface.ownSurfaceLayer == nil {
                sublayer.edgeAntialiasingMask = []
                layer.addSublayer(sublayer)
                surface.ownSurfaceLayer = sublayer
            }
            let size = CGSize(width: Double(IOSurfaceGetWidth(own)) / scale, height: Double(IOSurfaceGetHeight(own)) / scale)
            let top = Double(origin.y) - (Double(window.y) - side)
            sublayer.frame = CGRect(
                x: Double(origin.x) - (Double(window.x) - side), y: whole.height - top - size.height,
                width: size.width, height: size.height)
            sublayer.contents = own
            sublayer.perform(NSSelectorFromString("setContentsChanged"))
            return
        }
        surface.ownSurfaceLayer?.removeFromSuperlayer()
        surface.ownSurfaceLayer = nil
        // Until its first one comes, this window has nothing of its own. What's in the frame could be anyone's.
        if pixelSource?.hasSurfaces ?? false {
            setPieces(of: surface, to: [], from: frame.surface, place: place, height: whole.height)
            layer.contents = nil
            layer.mask = nil
            return
        }
        // One guest pixel to one host pixel takes none of its neighbours' at the edges.
        let filter: CALayerContentsFilter = scale == (NSScreen.main?.backingScaleFactor ?? 0) ? .nearest : .linear
        layer.magnificationFilter = filter
        layer.minificationFilter = filter
        // In this window's terms. When the guest says, it's every app's; otherwise a session only knows its own app's windows.
        let covers = (surface.guestCovers ?? surfaces.values.filter {
            $0.window.order < window.order && $0.window.level == 0 && !$0.window.title.isEmpty && $0.window.group != window.group
        }.map {
            CGRect(x: Double($0.window.x), y: Double($0.window.y), width: Double($0.window.width), height: Double($0.window.height))
        }).map { $0.offsetBy(dx: side - Double(window.x), dy: side - Double(window.y)) }
        let visible = surface.overlay ? [whole] : SeamlessSession.uncovered(whole, by: covers)
        if visible == [whole] {
            layer.contents = frame.surface
            layer.contentsRect = place(whole)
            setPieces(of: surface, to: [], from: frame.surface, place: place, height: whole.height)
        } else {
            layer.contents = surface.image ?? (frame.surface as Any)
            layer.contentsRect = surface.image == nil ? place(whole) : CGRect(x: 0, y: 0, width: 1, height: 1)
            setPieces(of: surface, to: visible, from: frame.surface, place: place, height: whole.height)
        }
        if surface.overlay {
            let mask = layer.mask ?? CALayer()
            mask.frame = whole
            mask.contents = surface.image
            layer.mask = mask
            layer.cornerRadius = 0
            layer.masksToBounds = false
        } else {
            layer.mask = nil
            // shortcut: the same corners all round, where a window's own differ a little, until they're read from its shape.
            layer.cornerRadius = 5
            layer.masksToBounds = true
        }
        // A surface a producer has drawn into again is the same object, which on its own wouldn't refresh.
        layer.perform(NSSelectorFromString("setContentsChanged"))
    }

    private func setPieces(
        of surface: Surface, to parts: [CGRect], from frame: IOSurfaceRef, place: (CGRect) -> CGRect, height: Double
    ) {
        while surface.pieces.count > parts.count { surface.pieces.removeLast().removeFromSuperlayer() }
        while surface.pieces.count < parts.count {
            let piece = CALayer()
            piece.edgeAntialiasingMask = []
            piece.magnificationFilter = surface.layer.magnificationFilter
            piece.minificationFilter = surface.layer.minificationFilter
            surface.layer.addSublayer(piece)
            surface.pieces.append(piece)
        }
        for (piece, part) in zip(surface.pieces, parts) {
            piece.frame = CGRect(x: part.minX, y: height - part.maxY, width: part.width, height: part.height)
            piece.contents = frame
            piece.contentsRect = place(part)
            piece.perform(NSSelectorFromString("setContentsChanged"))
        }
    }

    /// What's left of `rect` with `covers` taken out, as rectangles that don't overlap.
    nonisolated static func uncovered(_ rect: CGRect, by covers: [CGRect]) -> [CGRect] {
        covers.reduce([rect]) { parts, cover in
            parts.flatMap { part -> [CGRect] in
                let cut = part.intersection(cover)
                guard !cut.isEmpty else { return [part] }
                return [
                    CGRect(x: part.minX, y: part.minY, width: part.width, height: cut.minY - part.minY),
                    CGRect(x: part.minX, y: cut.maxY, width: part.width, height: part.maxY - cut.maxY),
                    CGRect(x: part.minX, y: cut.minY, width: cut.minX - part.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: part.maxX - cut.maxX, height: cut.height)
                ].filter { !$0.isEmpty }
            }
        }
    }


    // MARK: The proxy's side

    private func listenForProxy() -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(configuration.socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        // Whatever's left at this path in our private folder is no use now. The proxy only starts us if nothing answers there.
        try? FileManager.default.removeItem(atPath: configuration.socketPath)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, chmod(configuration.socketPath, 0o600) == 0, listen(listener, 4) == 0 else { return false }
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { continue }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.proxyConnected(client) }
                }
            }
        }
        return true
    }

    private func proxyConnected(_ descriptor: Int32) {
        let socket = LineSocket(descriptor: descriptor)
        socket.onLine = { [weak self] line in
            guard let event = try? JSONDecoder().decode(ProxyEvent.self, from: line) else { return }
            self?.handle(event)
        }
        socket.onClose = { [weak self] in
            self?.proxy = nil
            if let self, !self.stopped { self.onProxyClosed?(self.appGone) }
        }
        socket.start()
        proxy = socket
        for surface in surfaces.values {
            tellProxy(surface)
            if !surface.materials.isEmpty {
                socket.send(SessionCommand.setMaterials(id: Int(surface.window.id), surface.materials))
            }
        }
        if let lastMenu { socket.send(SessionCommand.setMenuBar(lastMenu)) }
        if let leaveTitle { socket.send(SessionCommand.setDockMenu([GuestMenuItem(title: leaveTitle)])) }
        if activateWhenConnected {
            activateWhenConnected = false
            socket.send(SessionCommand.activate)
        }
    }

    private func handle(_ event: ProxyEvent) {
        switch event {
        case .hello(_, _, let pid):
            proxyPID = pid
            note("# proxy said hello, pid \(pid)")
        case .input(let bytes): sendToGuest(bytes)
        case .tileBadge(let label): note("# the proxy's tile says \"\(label ?? "")\"")
        case .activated:
            if let id = surfaces.values.min(by: { $0.window.order < $1.window.order })?.window.id {
                sendToGuest(SessionWire.value(.focus, id))
            }
        case .surfaceMinimized(let id, let minimized):
            sendToGuest(SessionWire.setMinimized(window: UInt32(clamping: id), minimized))
        case .surfaceMoved(let id, let x, let y):
            guard let surface = surfaces[UInt32(clamping: id)] else { return }
            let side = Double(surface.window.margin)
            surface.hostOffset = NSPoint(x: x + side - Double(surface.window.x), y: y + side - Double(surface.window.y))
            tellProxy(surface)
        case .menuChosen(let path, _) where path.last == leaveTitle && leaveTitle != nil: onLeave?()
        case .menuChosen(let path, _): sendToGuest(SessionWire.text(.menuPress, path.joined(separator: "/")))
        case .openDocuments(let paths): for path in paths { sendDocument(path, flags: 0) }
        case .quit where onLeave != nil: onLeave?()
        case .quit:
            if guestDescriptor >= 0 {
                sendToGuest(SessionWire.value(.quitApp))
                note("# the proxy asked to quit, so the guest app was asked")
            } else {
                // shortcut: quitting before the guest is up leaves the app to shut the machine down, which waits for its agent.
                proxy?.send(SessionCommand.terminate)
                finished()
            }
        case .dragEntered(let paths, let windowID, let x, let y):
            sendPointer(0, windowID: windowID, x: x, y: y)
            for (index, path) in paths.enumerated() {
                let last = index == paths.count - 1
                sendDocument(path, flags: SessionWire.dragFlag | (last ? SessionWire.dragStartFlag : 0))
            }
        case .dragMoved(let windowID, let x, let y): sendPointer(3, windowID: windowID, x: x, y: y)
        case .dragDropped(let windowID, let x, let y):
            sendPointer(3, windowID: windowID, x: x, y: y)
            sendPointer(2, windowID: windowID, x: x, y: y)
        case .dragExited: sendToGuest(SessionWire.value(.dragCancel))
        case .pointerLeftWithButtonDown: sendToGuest(SessionWire.value(.dragQuery))
        case .promiseRequested(let id, let destination): sendFileForPromise(id: id, destination: destination)
        default: break
        }
    }

    /// A host drag's point is in the proxy window's points from its top left, shadow included.
    private func sendPointer(_ kind: UInt8, windowID: Int, x: Double, y: Double) {
        guard let window = surfaces[UInt32(clamping: windowID)]?.window else { return }
        let margin = Double(window.margin)
        sendToGuest(SessionWire.pointer(kind: kind, x: Double(window.x) + x - margin, y: Double(window.y) + y - margin))
    }

    // MARK: Documents

    /// A file of the host's goes into the guest. It waits if the guest isn't here yet.
    private func sendDocument(_ path: String, flags: UInt8) {
        guard guestDescriptor >= 0 else {
            documentsWaiting.append(path)
            return
        }
        let name = (path as NSString).lastPathComponent
        guard let contents = FileManager.default.contents(atPath: path), name.utf8.count <= 255 else {
            note("# can't send \(path): only plain files go to the guest")
            return
        }
        nextDocument += 1
        documentPaths[nextDocument] = path
        for piece in SessionWire.documentPieces(id: nextDocument, name: name, flags: flags, contents: contents) {
            sendToGuest(piece)
        }
        note("# sent \(path) to the guest, \(contents.count) bytes")
    }

    private static let promiseBit: UInt32 = 0x8000_0000

    /// The guest is untrusted: it only ever names a document this session sent it, and the file goes where that came from.
    private func receive(_ piece: SessionWire.DocumentPiece) {
        guard let path = documentPaths[piece.id] else { return }
        var coming = documentsComing[piece.id] ?? Data()
        coming.append(piece.payload)
        if coming.count > 1 << 32 {
            documentsComing[piece.id] = nil
            return
        }
        guard piece.isLast else {
            documentsComing[piece.id] = coming
            return
        }
        documentsComing[piece.id] = nil
        var failure: String?
        do {
            try coming.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            failure = error.localizedDescription
        }
        note("# the guest saved \(path), \(coming.count) bytes: \(failure ?? "written")")
        if piece.id & Self.promiseBit != 0 {
            documentPaths[piece.id] = nil
            proxy?.send(SessionCommand.promiseFulfilled(id: Int(piece.id & ~Self.promiseBit), error: failure))
        }
    }

    private func beginDragOut(_ json: Data) {
        let state = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        guestDragFiles = state?["files"] as? [String] ?? []
        note("# the guest is dragging \(guestDragFiles.count) files")
        if !guestDragFiles.isEmpty {
            proxy?.send(
                SessionCommand.beginDragOut(
                    names: guestDragFiles.map { ($0 as NSString).lastPathComponent }, imagePNG: nil))
        }
    }

    /// It's only ever a file the guest's drag pasteboard named, matched by its name or else by its place.
    private func sendFileForPromise(id: Int, destination: String) {
        let name = (destination as NSString).lastPathComponent
        let found =
            guestDragFiles.first { hostFileName(for: ($0 as NSString).lastPathComponent) == name }
            ?? (guestDragFiles.indices.contains(id - 1) ? guestDragFiles[id - 1] : nil)
        guard let found else {
            proxy?.send(SessionCommand.promiseFulfilled(id: id, error: "The guest has no such file."))
            return
        }
        let identifier = Self.promiseBit | UInt32(clamping: id)
        documentPaths[identifier] = destination
        sendToGuest(SessionWire.dragSend(id: identifier, path: found))
        note("# asked the guest for \(found), to \(destination)")
    }

    private func applyAppState(_ json: Data) {
        guard let state = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return }
        let badge = state["badge"] as? String ?? ""
        let attention = state["attention"] as? Bool ?? false
        note("# app state: badge \"\(badge)\", attention \(attention)")
        proxy?.send(SessionCommand.setBadge(badge.isEmpty ? nil : badge))
        if attention { proxy?.send(SessionCommand.requestAttention(critical: true)) }
    }

    // MARK: A test with nobody at the host

    private func startTestOnce() {
        guard let test, !testStarted else { return }
        testStarted = true
        runTest(test)
    }

    private func runTest(_ test: SeamlessSessionTest) {
        func after(_ seconds: Double, _ step: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated { step() }
            }
        }
        func frontPlace() -> (id: Int, x: Double, y: Double) {
            let front = surfaces.values.filter { $0.window.level == 0 && !$0.window.title.isEmpty }.min {
                $0.window.order < $1.window.order
            }
            let window = front?.window
            let margin = Double(window?.margin ?? 0)
            return (
                Int(window?.id ?? 0), Double(window?.width ?? 0) / 2 + margin,
                Double(window?.height ?? 0) / 2 + margin * 1.5
            )
        }
        after(10) { [self] in
            note("# test: typing in the document")
            proxy?.send(SessionCommand.testInput)
        }
        after(20) { [self] in sendToGuest(SessionWire.text(.menuPress, "File/New")) }
        after(32) { [self] in
            note("# test: typing in the new document")
            proxy?.send(SessionCommand.testInput)
        }
        // The file drag, driven as the proxy would report it: a real drop in the guest, then a drag that leaves the window.
        after(40) { [self] in
            let place = frontPlace()
            handle(.dragEntered(paths: [test.dragPath], windowID: place.id, x: place.x, y: place.y))
        }
        after(52) { [self] in
            let place = frontPlace()
            handle(.dragDropped(windowID: place.id, x: place.x, y: place.y))
        }
        // A file made for this, so a pasteboard left from anything before can't look like it.
        after(60) { [self] in
            let place = frontPlace()
            handle(.dragEntered(paths: [test.markerPath], windowID: place.id, x: place.x, y: place.y))
        }
        after(72) { [self] in
            let place = frontPlace()
            handle(.dragMoved(windowID: place.id, x: place.x, y: place.y))
            handle(.pointerLeftWithButtonDown(windowID: place.id))
        }
        after(82) { [self] in
            let name = (test.markerPath as NSString).lastPathComponent
            handle(.promiseRequested(id: 1, destination: (test.dragOutFolder as NSString).appendingPathComponent(name)))
        }
        after(92) { [self] in
            note("# test: asking the proxy, pid \(proxyPID), to quit")
            NSRunningApplication(processIdentifier: proxyPID)?.terminate()
        }
        after(108) { [self] in
            let titles = surfaces.values.map {
                "\($0.window.id) \($0.window.title) \($0.window.width)x\($0.window.height)"
            }
            note("# test: at the prompt, windows are: \(titles.joined(separator: "; "))")
            compose(to: test.screenshot)
            guard test.cancelFirst else {
                answer(code: 36)  // Return: the default button, Save.
                return
            }
            answer(code: 53)  // Escape: Cancel.
            note("# test: cancelled the prompt")
        }
        if test.cancelFirst {
            after(123) { [self] in
                let proxyAlive = NSRunningApplication(processIdentifier: proxyPID) != nil
                note(
                    "# test: after Cancel, the proxy \(proxyAlive ? "is running" : "has gone"), \(surfaces.count) windows"
                )
                NSRunningApplication(processIdentifier: proxyPID)?.terminate()
            }
            // The first launch has saved under the name this offers, and a clone keeps that, so this one types its own.
            after(139) { [self] in answer(code: 6) }
            after(141) { [self] in answer(code: 36) }
        }
        after(200) { [self] in
            note("# ERROR test: the guest app didn't exit after the answer")
            // Ends the guest's side normally, which brings its log back with it.
            shutdown(guestDescriptor, SHUT_RDWR)
        }
    }

    private func answer(code: UInt16) {
        sendToGuest(SessionWire.key(code: code, down: true))
        sendToGuest(SessionWire.key(code: code, down: false))
    }

    /// Every window's exact pixels at its position and order, over gray, so it works with the Mac's display asleep. It isn't
    /// read from the screen.
    private func compose(to path: String) {
        let shown = surfaces.values.filter { $0.image != nil }.sorted { $0.window.order > $1.window.order }
        guard let first = shown.first, let firstImage = first.image else { return }
        let scale = CGFloat(firstImage.width) / (CGFloat(first.window.width) + 2 * CGFloat(first.window.margin))
        var bounds = CGRect.null
        func frame(_ surface: Surface) -> CGRect {
            let margin = CGFloat(surface.window.margin)
            return CGRect(
                x: CGFloat(surface.window.x) - margin, y: CGFloat(surface.window.y) - margin,
                width: CGFloat(surface.window.width) + 2 * margin, height: CGFloat(surface.window.height) + 2 * margin)
        }
        for surface in shown { bounds = bounds.union(frame(surface)) }
        guard
            let context = CGContext(
                data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        context.setFillColor(gray: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        for surface in shown {
            guard let image = surface.image else { continue }
            let place = frame(surface)
            context.draw(
                image,
                in: CGRect(
                    x: (place.minX - bounds.minX) * scale, y: (bounds.maxY - place.maxY) * scale,
                    width: place.width * scale, height: place.height * scale))
        }
        if let image = context.makeImage(),
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// What a test wants of a session, from the environment.
public struct SeamlessSessionTest: Sendable {
    public var dragPath, markerPath, dragOutFolder, screenshot: String
    public var cancelFirst: Bool

    /// `LC_SEAMLESS_TEST`: four paths on lines of their own, then whether to cancel the first prompt.
    public init?(environment value: String?) {
        let parts = value?.components(separatedBy: "\n") ?? []
        guard parts.count == 5 else { return nil }
        dragPath = parts[0]
        markerPath = parts[1]
        dragOutFolder = parts[2]
        screenshot = parts[3]
        cancelFirst = parts[4] == "cancel"
    }
}

/// The display path that hands over shared memory rather than a surface: two surfaces, so one is never being read as it's written.
struct FrameCopies {
    private var copies: [IOSurfaceRef] = []
    private var copyIndex = 0

    mutating func copy(_ bytes: UnsafeRawPointer?, width: Int, height: Int, stride: Int) -> IOSurfaceRef? {
        guard let bytes else { return nil }
        if copies.first.map({ IOSurfaceGetWidth($0) != width || IOSurfaceGetHeight($0) != height }) ?? true {
            let properties: [CFString: Any] = [
                kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
                kIOSurfacePixelFormat: 0x4247_5241
            ]
            copies = (0..<2).compactMap { _ in IOSurfaceCreate(properties as CFDictionary) }
        }
        guard copies.count == 2 else { return nil }
        copyIndex = 1 - copyIndex
        let target = copies[copyIndex]
        IOSurfaceLock(target, [], nil)
        let row = IOSurfaceGetBytesPerRow(target)
        let base = IOSurfaceGetBaseAddress(target)
        for y in 0..<height { memcpy(base + y * row, bytes + y * stride, min(row, stride)) }
        IOSurfaceUnlock(target, [], nil)
        return target
    }
}
