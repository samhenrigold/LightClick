import AppKit
import SeamlessIntegration
@preconcurrency import UserNotifications

@MainActor
final class ProxyApplication: NSObject, NSApplicationDelegate, ProxyEventSink {
    private var socket: LineSocket?
    private var pending: [ProxyEvent] = []
    private var didAskToBoot = false
    private let dockMenu = NSMenu()
    private lazy var mirror = GuestMenuMirror(target: self, action: #selector(menuChosen(_:)))
    private var windows: [Int: NSWindow] = [:]
    private var dropViews: [Int: ProxyDropView] = [:]
    private var quitting = false

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
        connected.onClose = { [weak self] in
            self?.socket = nil
            self?.connectToSession()
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

    /// The session process isn't up, so nobody is running this machine. Ask the app once; the tile stays bouncing as an
    /// ordinary launching app until a window appears. `--open-vm` is the app's existing way in, and shows the machine's
    /// window until a headless mode exists.
    private func bootMachineOnce() {
        guard !didAskToBoot, let machine = info[ProxyBundle.machinePathKey] as? String, !machine.isEmpty,
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "gold.samhenri.LightClick")
        else { return }
        didAskToBoot = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--open-vm", machine]
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in }
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
        case .setBadge(let label): NSApp.dockTile.badgeLabel = label
        case .requestAttention(let critical):
            _ = NSApp.requestUserAttention(critical ? .criticalRequest : .informationalRequest)
        case .notify(let title, let body, let identifier): post(title: title, body: body, identifier: identifier)
        case .noteRecentDocument(let path):
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
        case .activate: NSApp.activate()
        case .terminate:
            quitting = true
            NSApp.reply(toApplicationShouldTerminate: true)
            NSApp.terminate(nil)
        case .beginDragOut(let names, let image):
            NSApp.keyWindow.flatMap { window in dropViews.first { $0.value.window === window }?.value }?
                .beginDragOut(names: names, imagePNG: image)
        case .promiseFulfilled(let id, let error):
            dropViews.values.forEach { $0.promiseFulfilled(id: id, error: error) }
        case .showPlaceholderWindow(let id, let title, let x, let y, let width, let height):
            showWindow(id: id, title: title, frame: NSRect(x: x, y: y, width: width, height: height))
        }
    }

    private func setMenuBar(_ items: [GuestMenuItem]) {
        let bar = NSApp.mainMenu ?? NSMenu()
        mirror.apply(items, to: bar)
        NSApp.mainMenu = bar
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

    func applicationDidBecomeActive(_ notification: Notification) { send(.activated) }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { dockMenu }

    /// Quitting belongs to the guest app, which may ask to save. The session answers with `.terminate`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting || socket == nil { return .terminateNow }
        send(.quit)
        return .terminateLater
    }

    @objc private func menuChosen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? [String] else { return }
        // A key equivalent goes to the guest as the key itself, so the guest's responder chain decides what it means.
        send(.menuChosen(path: path, viaKey: NSApp.currentEvent?.type == .keyDown))
    }
}
