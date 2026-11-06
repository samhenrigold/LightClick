import AppKit
import SeamlessInputKit
import SeamlessIntegration
@preconcurrency import UserNotifications

@MainActor
final class ProxyApplication: NSObject, NSApplicationDelegate, NSMenuDelegate, ProxyEventSink {
    private var socket: LineSocket?
    private var pending: [ProxyEvent] = []
    private var didAskToBoot = false
    private let dockMenu = NSMenu()
    private lazy var mirror = GuestMenuMirror(target: self, action: #selector(menuChosen(_:)))
    private var windows: [Int: NSWindow] = [:]
    private var dropViews: [Int: ProxyDropView] = [:]
    private var quitting = false
    private var guestMenuBar: NSWindow?

    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var socketPath: String { info[ProxyBundle.sessionSocketKey] as? String ?? "" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = NSMenu()
        // The Dock draws an icon from a bundle inside a system tile on current macOS. Set at run time it doesn't.
        if let icon = Bundle.main.url(forResource: "GuestApp", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
        {
            NSApp.applicationIconImage = icon
        }
        connectToSession()
    }

    // MARK: Session

    private func connectToSession() {
        guard let connected = LineSocket.connect(path: socketPath) else {
            bootMachineOnce()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connectToSession() }
            return
        }
        connected.onLine = { [weak self] line in
            guard let command = try? JSONDecoder().decode(SessionCommand.self, from: line) else { return }
            self?.handle(command)
        }
        // shortcut: the session is gone, and with it every window, so this quits, until a session can come back to a proxy.
        connected.onClose = { [weak self] in
            self?.socket = nil
            self?.quitting = true
            NSApp.terminate(nil)
        }
        connected.start()
        socket = connected
        connected.send(
            ProxyEvent.hello(
                guestIdentifier: info[ProxyBundle.guestIdentifierKey] as? String ?? "",
                guestPath: info[ProxyBundle.guestPathKey] as? String ?? "",
                pid: ProcessInfo.processInfo.processIdentifier))
        for event in pending { connected.send(event) }
        pending = []
    }

    /// The session process isn't up, so nobody is running this machine. Ask the app once, as its own instance so the user's
    /// open library is left alone, to run the machine with no window and start the session on this socket. The tile stays
    /// bouncing as an ordinary launching app until a window appears.
    private func bootMachineOnce() {
        guard !didAskToBoot, let machine = info[ProxyBundle.machinePathKey] as? String, !machine.isEmpty,
            let guestPath = info[ProxyBundle.guestPathKey] as? String,
            let app = (info[ProxyBundle.hostAppKey] as? String).map({ URL(fileURLWithPath: $0) })
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "gold.samhenri.LightClick")
        else { return }
        didAskToBoot = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [
            "--open-vm", machine, "--seamless-session", socketPath, "--seamless-app",
            URL(fileURLWithPath: guestPath).deletingPathExtension().lastPathComponent
        ]
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        // Sessions run on the engine, if this app's QEMU has it, and a test's private home has to reach the app.
        configuration.environment = ProcessInfo.processInfo.environment.filter {
            ["CFFIXED_USER_HOME", "LC_SEAMLESS_TEST"].contains($0.key)
        }.merging(["LC_HVDBT": "1"]) { current, _ in current }
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                let alert = NSAlert(error: error)
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    func send(_ event: ProxyEvent) {
        if let socket {
            socket.send(event)
        } else {
            pending.append(event)
        }
    }

    private func handle(_ command: SessionCommand) {
        switch command {
        case .setMenuBar(let items): setMenuBar(items)
        case .setDockMenu(let items): mirror.apply(items, to: dockMenu)
        case .setBadge(let label):
            NSApp.dockTile.badgeLabel = label
            send(.tileBadge(NSApp.dockTile.badgeLabel))
        case .requestAttention(let critical):
            _ = NSApp.requestUserAttention(critical ? .criticalRequest : .informationalRequest)
        case .notify(let title, let body, let identifier): post(title: title, body: body, identifier: identifier)
        case .noteRecentDocument(let path):
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
        case .activate: NSApp.activate()
        case .showError(let message):
            // A test has nobody to answer it.
            guard ProcessInfo.processInfo.environment["LC_SEAMLESS_TEST"] == nil else { break }
            let alert = NSAlert()
            alert.messageText = message
            alert.runModal()
        case .terminate:
            quitting = true
            // Once, on Mojave after a cancelled quit, this didn't end the process, and a proxy that stays blocks its next launch.
            // shortcut: exit regardless after a while, until the sample `seamless-session-try` keeps says why.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(0) }
            NSApp.terminate(nil)
        case .beginDragOut(let names, let image):
            NSApp.keyWindow.flatMap { window in dropViews.first { $0.value.window === window }?.value }?
                .beginDragOut(names: names, imagePNG: image)
        case .promiseFulfilled(let id, let error):
            dropViews.values.forEach { $0.promiseFulfilled(id: id, error: error) }
        case .showGuestMenuBar(let height, let autoHide): showGuestMenuBar(height: height, autoHide: autoHide)
        case .hideGuestMenuBar:
            guestMenuBar?.close()
            guestMenuBar = nil
            NSApp.presentationOptions = []
        case .reportMenuBarState: reportMenuBarState()
        case .showPlaceholderWindow(let id, let title, let x, let y, let width, let height):
            showWindow(id: id, title: title, frame: NSRect(x: x, y: y, width: width, height: height))
        case .showSurface(
            let id, let contextID, let x, let y, let width, let height, let margin, let level, let alpha, let order,
            let title, let offsetX, let offsetY):
            showSurface(
                id: id, contextID: contextID, frame: NSRect(x: x, y: y, width: width, height: height), margin: margin,
                level: level, alpha: alpha, order: order, title: title, offset: NSPoint(x: offsetX, y: offsetY))
        case .removeSurface(let id):
            surfaces.removeValue(forKey: id)?.window.close()
            dropViews.removeValue(forKey: id)
        case .testInput: testInput()
        }
    }

    private func setMenuBar(_ items: [GuestMenuItem]) {
        let bar = NSApp.mainMenu ?? NSMenu()
        mirror.apply(GuestMenuItem.hostMenuBar(from: items), to: bar)
        if NSApp.mainMenu !== bar { NSApp.mainMenu = bar }
        // AppKit adds its search field to whatever it's told is the Help menu, and that search covers this whole bar.
        NSApp.helpMenu = bar.items.last?.submenu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let menu = menu as? GuestMenu { send(.menuWillOpen(path: menu.path)) }
    }

    private func showGuestMenuBar(height: Double, autoHide: Bool) {
        // AppKit refuses a hidden menu bar without the Dock hidden too, and an auto-hiding one without the Dock at least
        // auto-hiding, by raising an exception.
        NSApp.presentationOptions = autoHide ? [.autoHideDock, .autoHideMenuBar] : [.hideDock, .hideMenuBar]
        guard let screen = NSScreen.screens.first else { return }
        let frame = NSRect(
            x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
        let window =
            guestMenuBar ?? NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: true)
        window.level = .mainMenu + 1
        window.backgroundColor = .systemTeal
        window.isReleasedWhenClosed = false
        // shortcut: first screen only and fixed height, until the surface crop arrives and multiple displays are tested.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = GuestMenuBarView(sink: self)
        window.orderFrontRegardless()
        guestMenuBar = window
    }

    private func reportMenuBarState() {
        guard let screen = NSScreen.screens.first else { return }
        send(
            .menuBarState(
                presentationOptions: NSApp.currentSystemPresentationOptions.rawValue,
                menuBarVisible: NSMenu.menuBarVisible(), safeTop: Double(screen.safeAreaInsets.top),
                notchLeft: Double(screen.auxiliaryTopLeftArea?.maxX ?? 0),
                notchRight: Double(screen.auxiliaryTopRightArea?.minX ?? 0), screenWidth: Double(screen.frame.width)))
    }

    // MARK: Surfaces

    /// A borderless window can't normally take keys, and a guest window's frame is in its pixels.
    private final class SurfaceWindow: NSWindow {
        var observer: ProxyDropView?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override func sendEvent(_ event: NSEvent) {
            observer?.observe(event)
            super.sendEvent(event)
        }
    }

    private struct Surface {
        var window: NSWindow
        var host: CALayer
        var input: NSView
        var order: Int
    }

    private var surfaces: [Int: Surface] = [:]

    private func showSurface(
        id: Int, contextID: UInt32, frame: NSRect, margin: Double, level: Int, alpha: Double, order: Int, title: String,
        offset: NSPoint
    ) {
        let isFirstSurface = surfaces.isEmpty
        let surface = surfaces[id] ?? makeSurface(id: id, frame: frame)
        surface.host.setValue(contextID, forKey: "contextId")
        let window = surface.window
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if window.frame != frame { window.setFrame(frame, display: false) }
        surface.host.frame = CGRect(origin: .zero, size: frame.size)
        CATransaction.commit()
        window.level = NSWindow.Level(rawValue: level)
        window.alphaValue = alpha
        window.title = title
        SeamlessInputViewSetGuestOffset(surface.input, offset)
        setEventShape(of: window, margin: margin, size: frame.size)
        var updated = surface
        updated.order = order
        surfaces[id] = updated
        let frontToBack = surfaces.values.sorted { $0.order < $1.order }
        for other in frontToBack.reversed() { other.window.orderFront(nil) }
        if NSApp.keyWindow == nil, let first = frontToBack.first(where: { $0.window.level == .normal }) {
            first.window.makeKey()
            first.window.makeFirstResponder(first.input)
        }
        if isFirstSurface { NSApp.activate() }
    }

    /// Real NSEvents through the real input view, from the window's middle. It doesn't exercise WindowServer's delivery,
    /// but it needs no permission and doesn't touch the host's pointer.
    private func testInput() {
        guard let surface = surfaces.values.min(by: { $0.order < $1.order }) else { return }
        let window = surface.window
        let place = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: place, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            if type == .leftMouseDown {
                surface.input.mouseDown(with: event)
            } else {
                surface.input.mouseUp(with: event)
            }
        }
        // A real scroll event through the trackpad's path. The other gestures can't be made without a trackpad.
        if let scroll = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0),
            let event = NSEvent(cgEvent: scroll)
        {
            surface.input.scrollWheel(with: event)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard
                    let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                        context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)
                else { continue }
                if type == .keyDown { surface.input.keyDown(with: event) } else { surface.input.keyUp(with: event) }
            }
        }
    }

    private func makeSurface(id: Int, frame: NSRect) -> Surface {
        let window = SurfaceWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        let input = SeamlessMakeInputView(NSRect(origin: .zero, size: frame.size)) { [weak self] bytes in
            MainActor.assumeIsolated { self?.send(.input(bytes: bytes)) }
        }
        input.autoresizingMask = [.width, .height]
        input.wantsLayer = true
        window.contentView = input
        let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type ?? CALayer.self
        let host = hostClass.init()
        host.anchorPoint = .zero
        input.layer?.addSublayer(host)
        let drop = ProxyDropView(windowID: id, sink: self)
        drop.frame = input.bounds
        drop.autoresizingMask = [.width, .height]
        input.addSubview(drop)
        window.observer = drop
        dropViews[id] = drop
        return Surface(window: window, host: host, input: input, order: 0)
    }

    /// The window's pixels include its shadow, which mustn't take clicks. Only the guest window itself does.
    private func setEventShape(of window: NSWindow, margin: Double, size: NSSize) {
        typealias NewRegion =
            @convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
        typealias SetShape = @convention(c) (Int32, UInt32, UnsafeMutableRawPointer?) -> Int32
        typealias Connection = @convention(c) () -> Int32
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let newRegion = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSNewRegionWithRect"),
            let setShape = dlsym(sky, "SLSSetWindowEventShape"), let connection = dlsym(sky, "SLSMainConnectionID")
        else { return }
        var content = CGRect(x: margin, y: margin, width: size.width - 2 * margin, height: size.height - 2 * margin)
        var region: UnsafeMutableRawPointer?
        guard unsafeBitCast(newRegion, to: NewRegion.self)(&content, &region) == 0 else { return }
        _ = unsafeBitCast(setShape, to: SetShape.self)(
            unsafeBitCast(connection, to: Connection.self)(), UInt32(window.windowNumber), region)
    }

    private func showWindow(id: Int, title: String, frame: NSRect) {
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let view = ProxyDropView(windowID: id, sink: self)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        windows[id] = window
        dropViews[id] = view
    }

    private func post(title: String, body: String, identifier: String) {
        let center = UNUserNotificationCenter.current()
        // Provisional delivery asks nothing of the user: it lands quietly until they promote it in System Settings.
        center.requestAuthorization(options: [.alert, .badge, .sound, .provisional]) { _, _ in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                let description = error?.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.send(.notificationPosted(error: description)) }
                }
            }
        }
    }

    // MARK: AppKit

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for path in filenames { NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path)) }
        send(.openDocuments(paths: filenames))
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        send(.reopen)
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guestMenuBar?.orderFrontRegardless()
        send(.activated)
    }

    /// AppKit restores the host's bar by itself when another app comes forward, but this window would still cover it.
    func applicationDidResignActive(_ notification: Notification) { guestMenuBar?.orderOut(nil) }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { dockMenu }

    /// Quitting belongs to the guest app, which may ask to save, and may be told Cancel. The session answers with
    /// `.terminate`. Not `.terminateLater`, which would hold this app in a modal run loop while that sheet needs its input.
    /// shortcut: a logout or restart of the host sees a cancelled quit, until there's a reply it can wait for.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting || socket == nil { return .terminateNow }
        send(.quit)
        return .terminateCancel
    }

    @objc private func menuChosen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? [String] else { return }
        // A key equivalent goes to the guest as the key itself, so the guest's responder chain decides what it means.
        if let event = NSApp.currentEvent, event.type == .keyDown,
            let input = surfaces.values.first(where: { $0.window === NSApp.keyWindow })?.input
        {
            SeamlessInputViewForwardKeyEquivalent(input, event)
            return
        }
        send(.menuChosen(path: path, viaKey: NSApp.currentEvent?.type == .keyDown))
    }
}
