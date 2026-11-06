import AppKit
import SeamlessInputKit
import SeamlessIntegration
@preconcurrency import UserNotifications

@MainActor
final class ProxyApplication: NSObject, NSApplicationDelegate, NSMenuDelegate, ProxyEventSink {
    private var socket: LineSocket?
    private var pending: [ProxyEvent] = []
    private var didAskToBoot = false
    private var connectTries = 0
    private let dockMenu = NSMenu()
    private lazy var mirror = GuestMenuMirror(target: self, action: #selector(menuChosen(_:)))
    private var windows: [Int: NSWindow] = [:]
    private var dropViews: [Int: ProxyDropView] = [:]
    private var quitting = false
    private var guestMenuBar: NSWindow?

    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var socketPath: String { info[ProxyBundle.sessionSocketKey] as? String ?? "" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        armTestClicks()
        armTestMoves()
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
            // One generated for a Seamless press has nothing to start, if opened afterward by hand.
            connectTries += 1
            if (info[ProxyBundle.machinePathKey] as? String ?? "").isEmpty, connectTries > 10 { NSApp.terminate(nil) }
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
                        $0.key == "CFFIXED_USER_HOME" || $0.key.hasPrefix("LC_SEAMLESS_")
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
        /// Set for a window with a title bar in its pixels. Told when a drag of it on the host has ended.
        var movedByUser: (() -> Void)?
        private(set) var isBeingDragged = false
        /// Around the guest's window, for its shadow.
        var margin = 0.0
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override func sendEvent(_ event: NSEvent) {
            observer?.observe(event)
            guard event.type == .leftMouseDown, movedByUser != nil, isInTitleBar(event) else {
                super.sendEvent(event)
                return
            }
            // The guest gets a click whichever this turns out to be, which raises its window, and is all a double click or a
            // press on the title needs. If it becomes a drag, the host does it, so it isn't limited to the guest's display.
            super.sendEvent(event)
            let start = NSEvent.mouseLocation
            while let next = nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                if next.type == .leftMouseUp {
                    super.sendEvent(next)
                    return
                }
                let now = NSEvent.mouseLocation
                if hypot(now.x - start.x, now.y - start.y) >= 3 { break }
            }
            if let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                timestamp: event.timestamp, windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 0)
            {
                super.sendEvent(up)
            }
            isBeingDragged = true
            performDrag(with: event)
            isBeingDragged = false
            movedByUser?()
        }

        /// shortcut: the top 22 points past the traffic lights and the button at the far right. A tall title bar's lower part,
        /// or a toolbar's blank space, still drags in the guest, within its display, until there's a hit test for it from the guest.
        private func isInTitleBar(_ event: NSEvent) -> Bool {
            let place = event.locationInWindow
            let fromTop = frame.height - margin - place.y
            return fromTop >= 0 && fromTop <= 22 && place.x >= margin + 70 && place.x <= frame.width - margin - 28
        }
    }

    private struct Surface {
        var window: NSWindow
        var host: CALayer
        var input: NSView
        var order: Int
        var offset = NSPoint.zero
    }

    private var surfaces: [Int: Surface] = [:]
    private var clickSignal: DispatchSourceSignal?
    private var moveSignal: DispatchSourceSignal?

    private func showSurface(
        id: Int, contextID: UInt32, frame: NSRect, margin: Double, level: Int, alpha: Double, order: Int, title: String,
        offset: NSPoint
    ) {
        let isFirstSurface = surfaces.isEmpty
        let surface = surfaces[id] ?? makeSurface(id: id, frame: frame)
        surface.host.setValue(contextID, forKey: "contextId")
        let window = surface.window
        let dragging = (window as? SurfaceWindow)?.isBeingDragged ?? false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if window.frame != frame, !dragging { window.setFrame(frame, display: false) }
        surface.host.frame = CGRect(origin: .zero, size: frame.size)
        CATransaction.commit()
        window.level = NSWindow.Level(rawValue: level)
                window.alphaValue = alpha
        // Cropped from the guest's display there's no guest shadow to show, so the window gets the host's own.
        window.hasShadow = margin == 0
        window.title = title
        if !dragging { SeamlessInputViewSetGuestOffset(surface.input, offset) }
        setEventShape(of: window, margin: margin, size: frame.size)
        // A window with a title bar in its pixels moves on the host. What's in its layer doesn't care where it is.
        (window as? SurfaceWindow)?.margin = margin
        (window as? SurfaceWindow)?.movedByUser = level == 0 && !title.isEmpty ? { [weak self] in
            self?.surfaceMoved(id)
        } : nil
        var updated = surface
        updated.order = order
        if !dragging { updated.offset = offset }
        surfaces[id] = updated
        let frontToBack = surfaces.values.sorted { $0.order < $1.order }
        let quiet = ProcessInfo.processInfo.environment["LC_SEAMLESS_CLICK_LOG"] != nil
        for other in frontToBack.reversed() {
            // A measurement's windows stay behind what whoever's at the Mac is using, where their pointer can't reach them.
            if quiet { other.window.orderBack(nil) } else { other.window.orderFront(nil) }
        }
        if NSApp.keyWindow == nil, let first = frontToBack.first(where: { $0.window.level == .normal }) {
            first.window.makeKey()
            first.window.makeFirstResponder(first.input)
        }
                // A measurement mustn't take the Mac from whoever is using it.
        if isFirstSurface && ProcessInfo.processInfo.environment["LC_SEAMLESS_QUIET"] == nil { NSApp.activate() }
    }

    private func surfaceMoved(_ id: Int) {
        guard let surface = surfaces[id], let primary = NSScreen.screens.first?.frame.height else { return }
        let frame = surface.window.frame
        send(.surfaceMoved(windowID: id, x: frame.minX, y: primary - frame.maxY))
    }

    /// Each SIGUSR2 moves the front window by a screen's worth of the way as a host drag would, for a test with no pointer to drag.
    private func armTestMoves() {
        guard ProcessInfo.processInfo.environment["LC_SEAMLESS_CLICK_LOG"] != nil else { return }
        signal(SIGUSR2, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let front = self.surfaces.min(by: { $0.value.order < $1.value.order }) else { return }
                let screen = front.value.window.screen?.visibleFrame ?? .zero
                front.value.window.setFrameOrigin(NSPoint(x: screen.maxX - front.value.window.frame.width, y: screen.minY))
                self.surfaceMoved(front.key)
            }
        }
        source.resume()
        moveSignal = source
    }

    /// Each SIGUSR1 is one click, noted in LC_SEAMLESS_CLICK_LOG, for measuring input to the window changing.
    private func armTestClicks() {
        guard let path = ProcessInfo.processInfo.environment["LC_SEAMLESS_CLICK_LOG"] else { return }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let file = fopen(path, "a") else { return }
                fputs("\(Date().timeIntervalSince1970)\n", file)
                fclose(file)
                self.testClick()
            }
        }
        source.resume()
        clickSignal = source
    }

    /// Real NSEvents through the real input view, from the window's middle. It doesn't exercise WindowServer's delivery,
    /// but it needs no permission and doesn't touch the host's pointer.
    private func testClick() {
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
    }

    private func testInput() {
        guard let surface = surfaces.values.min(by: { $0.order < $1.order }) else { return }
        let window = surface.window
        testClick()
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
