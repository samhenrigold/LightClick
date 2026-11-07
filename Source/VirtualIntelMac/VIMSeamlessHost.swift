import AppKit
import GuestControl
import SeamlessIntegration

/// A guest's agent, through the machine's running session, one user at a time with the session's own setup.
@MainActor
private final class AgentGuest: SeamlessGuest {
    private let machinePath: String

    init(machinePath: String) {
        self.machinePath = machinePath
    }

    var isMachineRunning: Bool { VIMSession.running(forMachinePath: machinePath) != nil }

    /// Waits for the machine's session and for its agent to be free. Long waits are normal during a boot.
    private func agent() async -> (VIMSession, GuestAgentBridge)? {
        for _ in 0..<1800 {
            if let session = VIMSession.running(forMachinePath: machinePath),
                let agent = session.beginExclusiveGuestAgentUse() as? GuestAgentBridge
            {
                return (session, agent)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    func run(_ path: String, _ arguments: [String]) async -> SeamlessGuestRun {
        guard let (session, agent) = await agent() else {
            return SeamlessGuestRun(exitCode: nil, output: "", failure: "The machine isn't running.")
        }
        defer { session.endExclusiveGuestAgentUse() }
        return await withCheckedContinuation { continuation in
            agent.connect { error in
                if let error {
                    continuation.resume(
                        returning: SeamlessGuestRun(exitCode: nil, output: "", failure: error.localizedDescription))
                    return
                }
                // No deadline: a session's tool runs for as long as the app does.
                agent.runExecutable(path, arguments: arguments, timeout: 0) { result, failure in
                    let output = (result?["stdout"] as? Data).map { String(decoding: $0, as: UTF8.self) } ?? ""
                    continuation.resume(
                        returning: SeamlessGuestRun(
                            exitCode: (result?["exitcode"] as? NSNumber)?.intValue, output: output,
                            failure: failure?.localizedDescription))
                }
            }
        }
    }

    func stage(_ file: URL) async -> String? {
        guard let (session, agent) = await agent() else { return nil }
        defer { session.endExclusiveGuestAgentUse() }
        let name = "Transfer.bin"
        return await withCheckedContinuation { continuation in
            agent.connect { error in
                if error != nil {
                    continuation.resume(returning: nil)
                    return
                }
                agent.stageFiles([name: file], progress: nil) { receipt, _ in
                    let directory = receipt?["Directory"] as? String
                    continuation.resume(returning: directory.map { ($0 as NSString).appendingPathComponent(name) })
                }
            }
        }
    }
}

/// Each guest window's latest surface from QEMU, on Mojave with the hook loaded. Idle otherwise: nothing sends to it.
@MainActor
private final class WindowSurfaces: SeamlessPixelSource {
    private var surfaces: [UInt32: IOSurfaceRef] = [:]
    private var origins: [UInt32: (x: Int32, y: Int32)] = [:]
    let noDisplayFile: URL
    weak var desktop: SeamlessDesktop?
    private var receiver: GuestWindowSurfaceReceiver?

    init?(machineIdentifier: String, directory: URL) {
        noDisplayFile = directory.appending(path: "nodisplay")
        try? FileManager.default.removeItem(at: noDisplayFile)
        receiver = try? GuestWindowSurfaceReceiver(service: Self.service(machineIdentifier)) { [weak self] frame in
            // shortcut: a shape is for masking a host material, and nothing here puts one behind a window yet.
            guard !frame.isShape else { return }
            let surface = UnsafeTransfer(frame.surface)
            let window = frame.window
            let origin = frame.origin
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.arrived(window, surface.value, origin) }
            }
        }
        if receiver == nil { return nil }
    }

    static func service(_ identifier: String) -> String { "gold.samhenri.LightClick.seamless.\(identifier)" }

    private func arrived(_ window: UInt32, _ surface: IOSurfaceRef, _ origin: (x: Int32, y: Int32)) {
        guard let desktop else { return }
        if surfaces.isEmpty { FileManager.default.createFile(atPath: noDisplayFile.path, contents: nil) }
        if surfaces[window] == nil {
            desktop.note("# window \(window)'s own surface: \(IOSurfaceGetWidth(surface))x\(IOSurfaceGetHeight(surface))")
        }
        surfaces[window] = surface
        // Mavericks' say where they start, and Mojave's leave that to the tool.
        origins[window] = origin == (0, 0) ? nil : origin
        desktop.windowPixelsChanged(window)
    }

    var hasSurfaces: Bool { !surfaces.isEmpty }

    func surface(forWindow window: UInt32) -> IOSurfaceRef? { surfaces[window] }

    func surfaceOrigin(forWindow window: UInt32) -> (x: Int32, y: Int32)? { origins[window] }

    /// The display's frames are what show the window that's coming back.
    func stop() {
        surfaces = [:]
        origins = [:]
        desktop = nil
        try? FileManager.default.removeItem(at: noDisplayFile)
    }
}

private struct UnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The app's end of seamless guest apps: running one as a process with no window of its own, and making the proxy for one.
@MainActor @objc(VIMSeamlessHost)
final class SeamlessHost: NSObject {
    private static var session: SeamlessSession?
    private static var maker: SeamlessHost?

    private static func option(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static var tools: URL { Bundle.main.resourceURL!.appending(path: "Seamless") }

    /// Before the Dock has seen this app, if a proxy started it.
    @objc static func prepareIfRequested() {
        guard option("--seamless-session") != nil else { return }
        NSApp.setActivationPolicy(.accessory)
        // The machine's and library's windows are what say a VM is there. A sheet on one goes with it; an alert is a panel of
        // its own, and still shows. No notification does this: an inactive app with no events doesn't update its windows.
        // Clear as well as ordered out, since with the Mac's display asleep WindowServer's list still calls them on screen,
        // whatever AppKit says, and nothing here can tell whether that would show.
        // shortcut: they exist, on a timer, so one can flash on screen for a moment, until a session can run without a window.
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
                    window.alphaValue = 0
                    window.ignoresMouseEvents = true
                    window.orderOut(nil)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// `finished` runs when the session ends, which is when the machine should shut down.
    @objc static func startIfRequested(_ finished: @escaping () -> Void) {
        if let name = option("--seamless-make-proxy"), let machine = option("--open-vm") {
            Task {
                let made = await make(appNamed: name, machinePath: machine)
                print(made ?? "Failed to make the proxy")
                finished()
            }
            return
        }
        guard let socket = option("--seamless-session"), let app = option("--seamless-app"),
            let machine = option("--open-vm")
        else { return }
        let session = SeamlessSession(
            configuration: .init(
                socketPath: socket, guestApp: app, tools: tools, log: URL(fileURLWithPath: socket + ".log")),
            guest: AgentGuest(machinePath: machine), finished: finished)
        let environment = ProcessInfo.processInfo.environment
        session.test = SeamlessSessionTest(environment: environment["LC_SEAMLESS_TEST"])
        session.usesDisplayFrames = environment["LC_SEAMLESS_CAPTURE"] == nil
        session.stopAfter = environment["LC_SEAMLESS_STOP_AFTER"].flatMap(Double.init)
        session.distinctFrames = { Int(VIMSession.running(forMachinePath: machine)?.distinctFrames ?? 0) }
        observeFrames(machine: machine, session: session)
        self.session = session
        session.start()
    }

    //     /// The display view exists once the machine's session has started.
    private static func observeFrames(machine: String, session: SeamlessSession) {
        Task {
            while true {
                if let running = VIMSession.running(forMachinePath: machine) {
                    running.setFrameObserver { [weak session] surface, bytes, width, height, stride in
                        MainActor.assumeIsolated {
                            session?.frameArrived(
                                surface: surface, bytes: bytes, width: Int(width), height: Int(height),
                                stride: Int(stride))
                        }
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: Seamless, from a running machine's window

    private static var desktops: [String: SeamlessDesktop] = [:]
    private static var windowHidden: Set<String> = []
    private static var windowSurfaces: [String: WindowSurfaces] = [:]

    private static func surfaceDirectory(_ identifier: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "lc-surfaces-\(identifier.prefix(8))")
    }

    /// For QEMU, before it starts: where to send each window's surface, once a guest has been asked for them. Nothing goes
    /// there until then.
    @objc static func qemuEnvironment(for session: VIMSession) -> [String: String] {
        guard let machine = try? VIMMachine.load(URL(fileURLWithPath: session.machinePath)),
            let identifier = machine.configuration["Identifier"] as? String
        else { return [:] }
        let directory = surfaceDirectory(identifier)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard windowSurfaces[session.machinePath] != nil
            || WindowSurfaces(machineIdentifier: identifier, directory: directory).map({
                windowSurfaces[session.machinePath] = $0
                return true
            }) ?? false
        else { return [:] }
        return GuestWindowSurfaceReceiver.environment(service: WindowSurfaces.service(identifier), directory: directory.path)
    }

    @objc static func isActive(for session: VIMSession) -> Bool { desktops[session.machinePath] != nil }
    @objc static func isPrepared(for session: VIMSession) -> Bool { SeamlessDesktop.isPrepared(machine: session.machinePath) }
    @objc static func hasOwnSurfaces(for session: VIMSession) -> Bool { windowSurfaces[session.machinePath]?.hasSurfaces ?? false }

    /// So the button's quick from the first press. Once the guest's agent answers, and not while something's measuring it or
    /// the app's only there to run one guest app.
    @objc static func prepare(for session: VIMSession) {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("--guest-diagnostics-root") || ProcessInfo.processInfo.environment["LC_SEAMLESS_CLICK_LOG"] != nil,
            !arguments.contains("--seamless-session"),
            !arguments.contains("--seamless-make-proxy")
        else { return }
        let path = session.machinePath
        Task {
            let guest = AgentGuest(machinePath: path)
            try? await Task.sleep(for: .seconds(20))
            for _ in 0..<60 {
                guard VIMSession.running(forMachinePath: path) != nil else { return }
                if await guest.run("/usr/bin/uname", ["-r"]).exitCode == 0 {
                    _ = await SeamlessDesktop.prepare(guest: guest, tools: tools, machine: path)
                    return
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Takes the machine's window away, leaving its guest apps' windows in its place, or puts it back.
    @objc static func toggle(for session: VIMSession) {
        let path = session.machinePath
        if let desktop = desktops[path] {
            desktop.finish(why: "the button")
            return
        }
        guard let machine = try? VIMMachine.load(URL(fileURLWithPath: path)),
            let identifier = machine.configuration["Identifier"] as? String
        else { return }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let home = FileManager.default.homeDirectoryForCurrentUser
        let origin = session.seamlessGuestOffset
        let desktop = SeamlessDesktop(
            configuration: .init(
                tools: tools, proxyExecutable: tools.appending(path: "SeamlessProxy"),
                bundles: home.appending(path: "Library/Caches/Light Click/Seamless Apps/\(identifier)"),
                savedBundles: home.appending(path: "Applications/Light Click"),
                machine: .init(identifier: identifier, name: name, path: path),
                log: FileManager.default.temporaryDirectory.appending(path: "lc-seamless-\(identifier.prefix(8)).log"),
                guestOffset: NSPoint(x: origin.x.rounded(), y: origin.y.rounded())),
            guest: AgentGuest(machinePath: path))
        desktops[path] = desktop
        session.noteSeamlessChanged()
        let surfaces = windowSurfaces[path]
        surfaces?.desktop = desktop
        desktop.pixelSource = surfaces
        desktop.hasOwnSurfaces = { surfaces?.hasSurfaces ?? false }
        // The window only goes once something's there in its place, and comes back if nothing is.
        desktop.windowsChanged = { count in
            if count > 0, !windowHidden.contains(path) {
                windowHidden.insert(path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    MainActor.assumeIsolated {
                        if windowHidden.contains(path) { session.setSeamlessWindowHidden(true) }
                    }
                }
            } else if count == 0, windowHidden.contains(path) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated {
                        if desktops[path] === desktop, desktop.windowCount == 0 { desktop.finish(why: "no windows left") }
                    }
                }
            }
        }
        desktop.ended = { failure in
            surfaces?.stop()
            desktops[path] = nil
            windowHidden.remove(path)
            session.setFrameObserver(nil)
            session.setSeamlessWindowHidden(false)
            session.noteSeamlessChanged()
            // On its window, since an app-modal one stops everything else in this app, every other machine's window included.
            if let failure, let window = session.window {
                let alert = NSAlert()
                alert.messageText = failure
                alert.beginSheetModal(for: window)
            }
        }
        session.setFrameObserver { [weak desktop] surface, bytes, width, height, stride in
            MainActor.assumeIsolated {
                desktop?.frameArrived(
                    surface: surface, bytes: bytes, width: Int(width), height: Int(height), stride: Int(stride))
            }
        }
        desktop.start()
        // If the machine goes away, or there turn out to be no windows to show.
        Task { [weak desktop] in
            let started = CFAbsoluteTimeGetCurrent()
            while let desktop, desktops[path] === desktop {
                if VIMSession.running(forMachinePath: path) == nil {
                    desktop.finish(why: "the machine stopped")
                } else if !windowHidden.contains(path), CFAbsoluteTimeGetCurrent() - started > 150 {
                    desktop.finish("There are no windows in this Mac to show. Log in and open an app, then try again.")
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Whatever else happens to the app, a hidden machine comes back. Says whether there was one.
    @discardableResult @objc static func leaveAll() -> Bool {
        let any = !desktops.isEmpty
        for desktop in desktops.values { desktop.finish(why: "Light Click's tile or quitting") }
        return any
    }

    // MARK: Making a proxy

    /// Machine > Make Dock App…: asks the running guest what it has, and lets the user pick.
    @objc static func makeProxy(for session: VIMSession) {
        let path = session.machinePath
        Task {
            let guest = AgentGuest(machinePath: path)
            guard let apps = await installedApps(guest), !apps.isEmpty else {
                failed("Couldn't ask this Mac which apps it has. Wait for it to finish starting, then try again.")
                return
            }
            let alert = NSAlert()
            alert.messageText = "Make a Dock App"
            alert.informativeText =
                "Choose an app in this Mac. It gets its own icon, which starts this Mac with no window when you open it, and "
                + "shuts it down when you quit."
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
            popup.addItems(withTitles: apps.map(\.name))
            alert.accessoryView = popup
            alert.addButton(withTitle: "Make App")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let chosen = apps[popup.indexOfSelectedItem]
            if let bundle = await make(chosen, guest: guest, machinePath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundle)])
            } else {
                failed("Couldn't make the app.")
            }
        }
    }

    private static func failed(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    private static func make(appNamed name: String, machinePath: String) async -> String? {
        let guest = AgentGuest(machinePath: machinePath)
        // From the command line the machine has only just started, and its agent answers with an error until it's up.
        let started = CFAbsoluteTimeGetCurrent()
        while await guest.run("/usr/bin/uname", ["-r"]).exitCode != 0, CFAbsoluteTimeGetCurrent() - started < 900 {
            try? await Task.sleep(for: .seconds(5))
        }
        guard let app = await installedApps(guest)?.first(where: { $0.name == name }) else { return nil }
        return await make(app, guest: guest, machinePath: machinePath)
    }

    private static func toolInGuest(_ guest: AgentGuest) async -> Bool {
        guard let staged = await guest.stage(tools.appending(path: "seamless-integration-guest")) else {
            NSLog("Couldn't stage the integration tool")
            return false
        }
        let copy = "mkdir -p /tmp/sg; chmod 755 /tmp/sg; cp \"$1\" /tmp/sg/ig; chmod 755 /tmp/sg/ig"
        return await guest.run("/bin/sh", ["-c", copy, "sh", staged]).exitCode == 0
    }

    private static func installedApps(_ guest: AgentGuest) async -> [GuestApp]? {
        guard await toolInGuest(guest) else { return nil }
        let run = await guest.run("/tmp/sg/ig", ["apps"])
        let listing = run.output
        if run.exitCode != 0 { NSLog("The guest's app listing failed: %@", run.failure ?? String(listing.prefix(500))) }
        guard let line = listing.split(separator: "\n").first(where: { $0.hasPrefix("[") }) else { return nil }
        return (try? JSONDecoder().decode([GuestApp].self, from: Data(line.utf8)))?.sorted { $0.name < $1.name }
    }

    private static func make(_ app: GuestApp, guest: AgentGuest, machinePath: String) async -> String? {
        guard let machine = try? VIMMachine.load(URL(fileURLWithPath: machinePath)),
            let identifier = machine.configuration["Identifier"] as? String
        else { return nil }
        // The Dock tile's icon. A proxy still works without it.
        let icon = await guest.run("/tmp/sg/ig", ["icon", "--path", app.guestPath]).output
        var iconFile: URL?
        if let data = Data(base64Encoded: icon.trimmingCharacters(in: .whitespacesAndNewlines)), !data.isEmpty {
            let file = FileManager.default.temporaryDirectory.appending(path: "lc-icon-\(identifier).icns")
            if (try? data.write(to: file)) != nil { iconFile = file }
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Light Click")
        // The per-user temporary folder, since anyone can make a socket in /tmp. A socket's path has a short limit.
        let socket = FileManager.default.temporaryDirectory.appending(path: "lc-\(identifier.prefix(8).lowercased())")
            .path
        let name = (machinePath as NSString).lastPathComponent
        let proxy = ProxyBundle(
            app: app,
            machine: .init(identifier: identifier, name: (name as NSString).deletingPathExtension, path: machinePath),
            rank: .alternate)
        let written = try? proxy.write(
            to: folder, proxyExecutable: tools.appending(path: "SeamlessProxy"), sessionSocket: socket,
            guestIcon: iconFile,
            hostApp: Bundle.main.bundlePath)
        return written?.path
    }
}
