import AppKit
import SeamlessIntegration

@MainActor
final class HostProbe {
    let proxyExecutable: URL
    let helper: URL
    let output: URL
    let guestRoots: [URL]
    let visual: Bool
    var failures = 0

    private var listener: LineSocketListener?
    private var client: LineSocket?
    private var events: [ProxyEvent] = []
    private let socketPath = NSTemporaryDirectory() + "lc-probe-\(getpid()).sock"
    private lazy var applications = FileManager.default.homeDirectoryForCurrentUser.appending(
        path: "Applications/Light Click Probe")
    private lazy var support = FileManager.default.homeDirectoryForCurrentUser.appending(
        path: "Library/Application Support/Light Click/Proxies Probe")
    private var bundles: [URL] = []
    private let start = Synthetic.location
    private var proxyPID: pid_t = 0
    var dragsOnly = false

    init(proxyExecutable: URL, helper: URL, output: URL, guestRoots: [URL], visual: Bool) {
        self.proxyExecutable = proxyExecutable
        self.helper = helper
        self.output = output
        self.guestRoots = guestRoots
        self.visual = visual
    }

    private func report(_ name: String, _ value: String) { print("\(name): \(value)") }

    private func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    private func sleep(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

    private func waitFor(_ timeout: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await sleep(50)
        }
        return condition()
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        report("ax_trusted", "\(AXIsProcessTrusted())")
        await icons()
        await bundleAndRegistration()
        await liveProxy()
        if !dragsOnly { await dragsFromHelper() }
        await cleanUp()
        CGWarpMouseCursorPosition(start)
        print(failures == 0 ? "RESULT all checks passed" : "RESULT \(failures) checks failed")
    }

    // MARK: Icons

    private func iconURL(root: URL, appPath: String) -> URL? {
        let app = root.appending(path: appPath)
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            var icon = info["CFBundleIconFile"] as? String
        else { return nil }
        if !icon.hasSuffix(".icns") { icon += ".icns" }
        return app.appending(path: "Contents/Resources/\(icon)")
    }

    private func icons() async {
        for root in guestRoots {
            let apps = GuestApp.discover(root: root)
            var converted = 0
            var sizes: [Int: Int] = [:]
            let started = Date()
            for app in apps {
                guard let icon = iconURL(root: root, appPath: app.guestPath),
                    let size = IconConversion.largestSize(of: icon)
                else { continue }
                sizes[size, default: 0] += 1
                let target = output.appending(path: "icon-test.icns")
                if (try? IconConversion.convert(icon, to: target)) != nil { converted += 1 }
            }
            try? FileManager.default.removeItem(at: output.appending(path: "icon-test.icns"))
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000 / Double(max(apps.count, 1)))
            report(
                "guest_root_apps",
                "\(apps.count) apps, \(converted) icons converted, largest sizes \(sizes.sorted { $0.key < $1.key }), \(milliseconds) ms each"
            )
        }
    }

    // MARK: Bundles

    private func fixture() -> (GuestApp, URL?) {
        for root in guestRoots {
            let plist = root.appending(path: "Applications/TextEdit.app/Contents/Info.plist")
            if let data = try? Data(contentsOf: plist),
                let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                var app = GuestApp(infoPlist: info, guestPath: "/Applications/TextEdit.app")
            {
                app.documentTypes.append(.init(name: "Probe Document", extensions: ["lcprobedoc"]))
                return (app, iconURL(root: root, appPath: "/Applications/TextEdit.app"))
            }
        }
        // No guest disk: the host's TextEdit describes a plausible app, and the document icon is the host's own.
        var info: [String: Any] = ["CFBundleIdentifier": "com.apple.TextEdit", "CFBundleName": "TextEdit"]
        info["CFBundleDocumentTypes"] = [
            ["CFBundleTypeName": "RTF", "CFBundleTypeExtensions": ["rtf"], "CFBundleTypeRole": "Editor"],
            ["CFBundleTypeName": "Probe", "CFBundleTypeExtensions": ["lcprobedoc"], "CFBundleTypeRole": "Editor"]
        ]
        return (GuestApp(infoPlist: info, guestPath: "/Applications/TextEdit.app")!, nil)
    }

    private func machine(_ name: String) -> ProxyBundle.Machine {
        // An empty path means a proxy can't ask the app to boot anything, whatever this probe does.
        ProxyBundle.Machine(identifier: "probe-\(name.lowercased())", name: name, path: "")
    }

    private var openWithFile: URL { output.appending(path: "Probe Document.rtf") }
    private var privateTypeFile: URL { output.appending(path: "Probe Document.lcprobedoc") }
    private var alternate: URL { bundles[0] }

    private func bundleAndRegistration() async {
        let (app, icon) = fixture()
        try? Data("{\\rtf1 probe}".utf8).write(to: openWithFile)
        try? Data("probe".utf8).write(to: privateTypeFile)
        let workspace = NSWorkspace.shared
        let defaultBefore = workspace.urlForApplication(toOpen: openWithFile)
        do {
            let started = Date()
            let alternateBundle = try ProxyBundle(app: app, machine: machine("Mavericks"))
                .write(to: applications, proxyExecutable: proxyExecutable, sessionSocket: socketPath, guestIcon: icon)
            report("proxy_generate_ms", "\(Int(Date().timeIntervalSince(started) * 1000))")
            let noneBundle = try ProxyBundle(app: app, machine: machine("Hidden"), rank: .none)
                .write(to: applications, proxyExecutable: proxyExecutable, sessionSocket: socketPath, guestIcon: icon)
            let supportBundle = try ProxyBundle(app: app, machine: machine("Support"))
                .write(to: support, proxyExecutable: proxyExecutable, sessionSocket: socketPath, guestIcon: icon)
            bundles = [alternateBundle, noneBundle, supportBundle]
        } catch {
            check("generate proxies", false, "\(error)")
            return
        }
        await sleep(1500)
        let candidates = workspace.urlsForApplications(toOpen: openWithFile).map(\.path)
        check(
            "default handler for .rtf unchanged", workspace.urlForApplication(toOpen: openWithFile) == defaultBefore,
            workspace.urlForApplication(toOpen: openWithFile)?.lastPathComponent ?? "none")
        report("open_with_rank_alternate_listed", "\(candidates.contains(bundles[0].path))")
        report("open_with_rank_none_listed", "\(candidates.contains(bundles[1].path))")
        report(
            "default_for_private_type",
            workspace.urlForApplication(toOpen: privateTypeFile)?.lastPathComponent ?? "none")
        // Spotlight, which is what Launchpad's replacement and app search read.
        var found: [String: Bool] = [:]
        for (name, bundle) in [("applications", bundles[0]), ("application_support", bundles[2])] {
            let identifier = Bundle(url: bundle)?.bundleIdentifier ?? ""
            _ = command("/usr/bin/mdimport", [bundle.path])
            for _ in 0..<20 {
                let text = command("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(identifier)'"])
                found[name] = text.contains(bundle.lastPathComponent)
                if found[name] == true { break }
                await sleep(500)
            }
            report("spotlight_finds_proxy_in_\(name)", "\(found[name] ?? false)")
        }
    }

    // MARK: A running proxy

    private func dockItem(titled title: String) -> Element? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        for list in Element.application(pid: dock.processIdentifier).children {
            if let item = list.children.first(where: { $0.string("AXTitle") == title }) { return item }
        }
        return nil
    }

    private func screenshot(_ name: String, _ rect: CGRect? = nil) {
        guard visual else { return }
        var arguments = ["-x"]
        if let rect {
            arguments += ["-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"]
        }
        _ = command("/usr/sbin/screencapture", arguments + [output.appending(path: name).path])
        report("screenshot", name)
    }

    private func startListening() {
        listener?.stop()
        listener = LineSocketListener(path: socketPath)
        listener?.onAccept = { [weak self] socket in
            guard let self else { return }
            socket.onLine = { [weak self] line in
                if let event = try? JSONDecoder().decode(ProxyEvent.self, from: line) { self?.received(event) }
            }
            socket.start()
            self.client = socket
        }
        listener?.start()
    }

    private func received(_ event: ProxyEvent) {
        events.append(event)
        switch event {
        case .pointerLeftWithButtonDown:
            client?.send(SessionCommand.beginDragOut(names: ["Promised By Guest.txt"], imagePNG: nil))
        case .promiseRequested(let id, let destination):
            let error: String?
            do {
                try Data("from the guest\n".utf8).write(to: URL(fileURLWithPath: destination))
                error = nil
            } catch {
                self.client?.send(SessionCommand.promiseFulfilled(id: id, error: "\(error)"))
                return
            }
            client?.send(SessionCommand.promiseFulfilled(id: id, error: error))
        case .quit:
            client?.send(SessionCommand.terminate)
        default: break
        }
    }

    private func has(_ test: (ProxyEvent) -> Bool) -> Bool { events.contains(where: test) }

    private func liveProxy() async {
        guard bundles.count == 3 else { return }
        let bundle = alternate
        let displayName = bundle.deletingPathExtension().lastPathComponent

        // The VM isn't running: nothing listens yet. A document opened now must arrive once it does.
        let started = Date()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.open([openWithFile], withApplicationAt: bundle, configuration: configuration)
        await sleep(1500)
        guard
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: Bundle(url: bundle)?.bundleIdentifier ?? ""
            ).first
        else {
            check("proxy launches", false)
            return
        }
        check("proxy launches with no session running", !running.isTerminated)
        startListening()
        let opened = await waitFor(6) {
            has { if case .openDocuments(let paths) = $0 { paths.contains(openWithFile.path) } else { false } }
        }
        check("document opened before the session started is delivered when it does", opened)
        report("launch_to_delivered_ms", "\(Int(Date().timeIntervalSince(started) * 1000))")

        // Menu bar: what AppKit shows, read back through Accessibility as any user would see it.
        let tree = [
            GuestMenuItem(title: displayName, children: [GuestMenuItem(title: "About", isEnabled: true)]),
            GuestMenuItem(
                title: "File",
                children: [
                    GuestMenuItem(title: "Save", key: "S"),
                    GuestMenuItem(title: "Save As", key: "S", modifiers: 1),
                    GuestMenuItem(title: ""),
                    GuestMenuItem(title: "Revert", isEnabled: false),
                    GuestMenuItem(title: "Wrap", mark: "\u{2713}"),
                    GuestMenuItem(title: "Full Screen", key: "F", modifiers: 4)
                ])
        ]
        client?.send(SessionCommand.setMenuBar(tree))
        client?.send(
            SessionCommand.setDockMenu([GuestMenuItem(title: "New Window"), GuestMenuItem(title: "Recent One")]))
        client?.send(SessionCommand.setBadge("7"))
        await sleep(500)
        menuReadBack(pid: running.processIdentifier)
        await dockReadBack(displayName: displayName, pid: running.processIdentifier)

        client?.send(SessionCommand.notify(title: "From the guest", body: "Probe", identifier: "probe"))
        let posted = await waitFor(5) {
            has { if case .notificationPosted = $0 { true } else { false } }
        }
        let error = events.compactMap { event -> String?? in
            if case .notificationPosted(let error) = event { error } else { nil }
        }.first
        check("notification from an ad-hoc proxy", posted && error == .some(nil), "error \(String(describing: error))")

        proxyPID = running.processIdentifier
        running.activate()
        await sleep(500)
        await hostDrags(displayName: displayName)
        await liveMenu(pid: running.processIdentifier)
        await guestMenuBarMode(pid: running.processIdentifier)

        // Quitting asks the session first, so the guest app can ask to save.
        running.terminate()
        let asked = await waitFor(5) { has { if case .quit = $0 { true } else { false } } }
        let gone = await waitFor(5) { running.isTerminated }
        check("Cmd-Q goes to the session, then the proxy exits", asked && gone)
    }

    private func menuReadBack(pid: pid_t) {
        guard let bar = Element.application(pid: pid).value("AXMenuBar") else {
            check("host menu bar readable", false)
            return
        }
        let barElement = Element(reference: bar as! AXUIElement)
        guard let file = barElement.children.first(where: { $0.string("AXTitle") == "File" }),
            let menu = file.children.first
        else {
            check("mirrored File menu present", false)
            return
        }
        let items = menu.children
        func item(_ title: String) -> Element? { items.first { $0.string("AXTitle") == title } }
        check("mirrored Save has its key", item("Save")?.string("AXMenuItemCmdChar") == "S")
        check(
            "mirrored Save As has Shift",
            (item("Save As")?.value("AXMenuItemCmdModifiers") as? Int) == 1)
        check("mirrored Revert is disabled", (item("Revert")?.value("AXEnabled") as? Bool) == false)
        check("mirrored Wrap is checked", item("Wrap")?.string("AXMenuItemMarkChar")?.isEmpty == false)
        check(
            "mirrored Full Screen has Control",
            (item("Full Screen")?.value("AXMenuItemCmdModifiers") as? Int) == 4)
    }

    private func dockReadBack(displayName: String, pid: pid_t) async {
        guard let tile = dockItem(titled: displayName) else {
            check("Dock shows a tile titled \(displayName)", false)
            return
        }
        check("Dock shows a tile titled \(displayName)", true, tile.string("AXSubrole") ?? "")
        report("dock_tile_attributes", tile.attributes.joined(separator: " "))
        check("Dock tile badge", tile.string("AXStatusLabel") == "7", tile.string("AXStatusLabel") ?? "none")
        let label = command("/usr/bin/lsappinfo", ["info", "-only", "StatusLabel", "-app", "pid=\(pid)"])
        report("lsappinfo_status_label", label.trimmingCharacters(in: .whitespacesAndNewlines))
        if let frame = tile.frame {
            screenshot("dock-tile.png", frame.insetBy(dx: -24, dy: -24))
        }

        // Bounce: an inactive app asking for attention.
        client?.send(SessionCommand.requestAttention(critical: true))
        await sleep(600)
        report(
            "lsappinfo_attention",
            command("/usr/bin/lsappinfo", ["info", "-all", "-app", "pid=\(pid)"]).split(separator: "\n")
                .filter { $0.lowercased().contains("attention") }.joined(separator: " "))
        screenshot("dock-bounce.png", (tile.frame ?? .zero).insetBy(dx: -24, dy: -80))
        await sleep(300)

        // The Dock's own menu, opened as a right click would.
        let shown = tile.perform("AXShowMenu")
        await sleep(800)
        let menu = tile.value("AXShownMenuUIElement").map { Element(reference: $0 as! AXUIElement) }
        let titles = (menu?.children ?? tile.children.flatMap(\.children)).compactMap { $0.string("AXTitle") }
        report("dock_show_menu_error", "\(shown.rawValue)")
        check(
            "Dock menu shows the mirrored items", titles.contains("New Window") && titles.contains("Recent One"),
            titles.joined(separator: ", "))
        report("dock_menu_recent_listed", "\(titles.contains(openWithFile.lastPathComponent))")
        if let frame = tile.frame { screenshot("dock-menu.png", frame.insetBy(dx: -220, dy: -320)) }
        Synthetic.key(53, down: true)
        Synthetic.key(53, down: false)
        await sleep(300)

        // Cmd-Tab: the switcher is the Dock's. Escape before releasing Command so no app changes.
        if visual && !dragsOnly {
            Synthetic.key(55, down: true, flags: .maskCommand)
            Synthetic.key(48, down: true, flags: .maskCommand)
            Synthetic.key(48, down: false, flags: .maskCommand)
            await sleep(900)
            if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
                let root = Element.application(pid: dock.processIdentifier)
                let lists = root.children.filter { $0.string("AXRole") != "AXList" || $0.string("AXSubrole") != nil }
                report("switcher_roles", root.children.compactMap { $0.string("AXRole") }.joined(separator: " "))
                let names = lists.flatMap(\.children).compactMap { $0.string("AXTitle") }
                check("Cmd-Tab lists the proxy", names.contains(displayName), names.joined(separator: ", "))
            }
            screenshot("cmd-tab.png")
            Synthetic.key(53, down: true, flags: .maskCommand)
            Synthetic.key(53, down: false, flags: .maskCommand)
            Synthetic.key(55, down: false)
            await sleep(400)
        }

        // Mission Control groups windows by owning app. One placeholder window, seen by eye in the screenshot.
        client?.send(
            SessionCommand.showPlaceholderWindow(id: 1, title: "Document", x: 120, y: 200, width: 420, height: 300))
        await sleep(600)
        let onScreen =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        check(
            "placeholder window is owned by the proxy's process and name",
            onScreen.contains { ($0[kCGWindowOwnerName as String] as? String) == displayName })
        if visual && !dragsOnly {
            _ = command("/usr/bin/open", ["-a", "Mission Control"])
            await sleep(1800)
            screenshot("mission-control.png")
            Synthetic.key(53, down: true)
            Synthetic.key(53, down: false)
            await sleep(1500)
        }
    }

    // MARK: Menu pass-through

    private func count(_ items: [GuestMenuItem]) -> Int { items.reduce(0) { $0 + 1 + count($1.children ?? []) } }

    private func helperOutput(_ arguments: [String]) -> String { command(helper.path, arguments) }

    private func menu(of app: String) -> (items: [GuestMenuItem], text: String)? {
        let text = helperOutput(["menu", "--app", app])
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("[") }),
            let items = try? JSONDecoder().decode([GuestMenuItem].self, from: Data(line.utf8))
        else { return nil }
        return (items, text)
    }

    private func find(_ path: [String], in items: [GuestMenuItem]) -> GuestMenuItem? {
        guard let first = path.first, let item = items.first(where: { $0.title == first }) else { return nil }
        return path.count == 1 ? item : find(Array(path.dropFirst()), in: item.children ?? [])
    }

    private func liveMenu(pid: pid_t) async {
        NSRunningApplication(processIdentifier: pid)?.activate()
        await sleep(400)

        // A real, large menu, read by the guest tool and shown by the proxy.
        guard let finder = menu(of: "Finder") else {
            check("guest tool reads Finder's menu", false)
            return
        }
        report(
            "real_menu_read",
            finder.text.split(separator: "\n").filter { $0.hasPrefix("#") }.joined(separator: " "))
        let sent = Date()
        client?.send(SessionCommand.setMenuBar(finder.items))
        let bar = Element.application(pid: pid)
        func barItems() -> [Element] {
            (bar.value("AXMenuBar")).map { Element(reference: $0 as! AXUIElement) }?.children ?? []
        }
        let shown = await waitFor(4) { barItems().contains { $0.string("AXTitle") == "Go" } }
        report("real_menu_mirror_ms", "\(Int(Date().timeIntervalSince(sent) * 1000)) for \(count(finder.items)) items")
        let titles = barItems().compactMap { $0.string("AXTitle") }
        check("the proxy's bar has the real menu, with the host's Apple menu", shown, titles.joined(separator: " "))

        // Help search: AppKit's own field, only if the mirrored Help is the real help menu.
        if let help = barItems().last, let menu = help.children.first {
            let first = menu.children.first
            report("help_menu_first_role", first?.string("AXRole") ?? "none")
            report(
                "help_menu_first_item_children",
                first?.children.compactMap { $0.string("AXRole") }.joined(separator: " ") ?? "")
        }

        // Opening a menu, from a fresh tree: how long until it's open, and whether an update reaches it while it's open.
        let tree = [
            GuestMenuItem(
                title: "File",
                children: [
                    GuestMenuItem(title: "About", isEnabled: true),
                    GuestMenuItem(title: "About Extra", modifiers: 10, isAlternate: true),
                    GuestMenuItem(title: "Revert", isEnabled: false)
                ])
        ]
        client?.send(SessionCommand.setMenuBar(tree))
        _ = await waitFor(3) { barItems().contains { $0.string("AXTitle") == "File" } && barItems().count <= 3 }
        await sleep(300)
        guard let file = barItems().first(where: { $0.string("AXTitle") == "File" }), let open = file.frame else {
            check("mirrored File is present", false)
            return
        }
        events.removeAll()
        // A real click, not AXPress, since it's what a person does.
        let point = CGPoint(x: open.midX, y: open.midY)
        Synthetic.post(.mouseMoved, point)
        await sleep(150)
        let pressed = Date()
        Synthetic.post(.leftMouseDown, point)
        Synthetic.post(.leftMouseUp, point)
        let opened = await waitFor(2) {
            has { if case .menuWillOpen(let path) = $0 { path == ["File"] } else { false } }
        }
        report("menu_click_to_will_open_ms", "\(Int(Date().timeIntervalSince(pressed) * 1000))")
        check("opening a mirrored menu tells the session which", opened)
        await sleep(200)
        client?.send(
            SessionCommand.setMenuBar([
                GuestMenuItem(
                    title: "File",
                    children: [
                        GuestMenuItem(title: "About", isEnabled: true),
                        GuestMenuItem(title: "About Extra", modifiers: 10, isAlternate: true),
                        GuestMenuItem(title: "Revert", isEnabled: true),
                        GuestMenuItem(title: "Added While Open")
                    ])
            ]))
        await sleep(300)
        screenshot("menu-open.png", CGRect(x: open.minX - 20, y: 0, width: 420, height: 260))
        let live = file.children.first?.children ?? []
        func item(_ title: String) -> Element? { live.first { $0.string("AXTitle") == title } }
        check(
            "a menu updates while it's open",
            item("Added While Open") != nil && (item("Revert")?.value("AXEnabled") as? Bool) == true,
            live.compactMap { $0.string("AXTitle") }.joined(separator: ", "))
        // Accessibility still lists a hidden alternate, so this one is by eye: not drawn here, and drawn with Option held.
        Synthetic.key(58, down: true, flags: .maskAlternate)
        await sleep(300)
        screenshot("menu-open-option.png", CGRect(x: open.minX - 20, y: 0, width: 420, height: 260))
        Synthetic.key(58, down: false)
        await sleep(100)
        // Choosing: the path the guest will AXPress.
        events.removeAll()
        item("Added While Open")?.perform("AXPress")
        let chosen = await waitFor(2) {
            has { if case .menuChosen(let path, _) = $0 { path == ["File", "Added While Open"] } else { false } }
        }
        check("choosing a mirrored item sends its path", chosen)
        Synthetic.key(53, down: true)
        Synthetic.key(53, down: false)
        await sleep(300)
        await realAppRoundTrip()
    }

    /// A real app's check mark, end to end: read it, AXPress the item, read it again, and see which notifications say so.
    private func realAppRoundTrip() async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").isEmpty else {
            print("SKIP real app round trip: Calculator is already in use")
            return
        }
        _ = command("/usr/bin/open", ["-g", "-a", "Calculator"])
        await sleep(1500)
        let watch = try? runHelper(["menu-watch", "--app", "Calculator", "--seconds", "5"])
        await sleep(600)
        guard let before = menu(of: "Calculator") else {
            check("read Calculator", false)
            return
        }
        let view = before.items.first { $0.title == "View" }?.children ?? []
        let marked = view.first { $0.mark != nil }?.title
        let other = view.first { $0.mark == nil && ($0.title == "Scientific" || $0.title == "Basic") }?.title
        report("calculator_view", "marked \(marked ?? "none"), other \(other ?? "none")")
        if let marked, let other {
            let pressed = Date()
            let output = helperOutput(["press", "--app", "Calculator", "--path", "View/\(other)"])
            report("press", output.trimmingCharacters(in: .whitespacesAndNewlines))
            let changed = await waitFor(4) {
                menu(of: "Calculator").flatMap { find(["View", other], in: $0.items) }?.mark != nil
            }
            check(
                "AXPress on a real item changes its check mark", changed,
                "\(Int(Date().timeIntervalSince(pressed) * 1000)) ms including reads")
            _ = helperOutput(["press", "--app", "Calculator", "--path", "View/\(marked)"])
        }
        if let watch {
            let text = await finish(watch.0, watch.1, timeout: 6)
            report("calculator_notifications", text.replacingOccurrences(of: "\n", with: " | "))
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").first?.terminate()
    }

    // MARK: The guest's own menu bar

    private func menuBarWindows() -> [String] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { ($0[kCGWindowLayer as String] as? Int) == 24 }.map {
            let bounds = ($0[kCGWindowBounds as String] as? NSDictionary).flatMap {
                CGRect(dictionaryRepresentation: $0)
            }
            return "\($0[kCGWindowOwnerName as String] ?? "") \(bounds ?? .zero)"
        }
    }

    private func menuBarState() async -> String {
        events.removeAll { if case .menuBarState = $0 { true } else { false } }
        client?.send(SessionCommand.reportMenuBarState)
        _ = await waitFor(2) { has { if case .menuBarState = $0 { true } else { false } } }
        for case .menuBarState(let options, let visible, let top, let left, let right, let width) in events {
            return
                "options 0x\(String(options, radix: 16)) bar_visible \(visible) safe_top \(top) notch \(left)...\(right) of \(width)"
        }
        return "no reply"
    }

    private func guestMenuBarMode(pid: pid_t) async {
        NSRunningApplication(processIdentifier: pid)?.activate()
        await sleep(400)
        report("menu_bar_before", await menuBarState())
        for autoHide in [false, true] {
            let name = autoHide ? "auto_hide" : "hide"
            client?.send(SessionCommand.showGuestMenuBar(height: 37, autoHide: autoHide))
            await sleep(900)
            report("menu_bar_\(name)", await menuBarState())
            report("menu_bar_\(name)_windows", menuBarWindows().joined(separator: "; "))
            screenshot("menu-bar-\(name).png", CGRect(x: 0, y: 0, width: 1512, height: 80))
            // Clicks at the very top of the screen, where a menu lives.
            events.removeAll()
            Synthetic.post(.mouseMoved, CGPoint(x: 200, y: 1))
            await sleep(900)
            screenshot("menu-bar-\(name)-hover.png", CGRect(x: 0, y: 0, width: 1512, height: 80))
            Synthetic.post(.leftMouseDown, CGPoint(x: 200, y: 1))
            Synthetic.post(.leftMouseUp, CGPoint(x: 200, y: 1))
            let clicked = await waitFor(1.5) { has { if case .guestMenuBarClicked = $0 { true } else { false } } }
            check("mode B, \(name): a click at the top of the screen reaches the guest's bar", clicked)
            report("menu_bar_\(name)_after_hover", await menuBarState())
            Synthetic.key(53, down: true)
            Synthetic.key(53, down: false)
            Synthetic.post(.mouseMoved, CGPoint(x: 700, y: 400))
            await sleep(400)
        }
        // Another app coming forward must get the normal bar back with nothing done here.
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        await sleep(900)
        report("menu_bar_other_app_active", await menuBarState())
        screenshot("menu-bar-other-app.png", CGRect(x: 0, y: 0, width: 1512, height: 80))
        report("menu_bar_other_app_windows", menuBarWindows().joined(separator: "; "))
        client?.send(SessionCommand.hideGuestMenuBar)
        await sleep(300)
    }

    // MARK: Drags on the host side

    /// Whoever owns the frontmost ordinary window at a point. This is a shared desktop: another window may have come
    /// forward, and a drop on it would land the probe's file in someone's app.
    private func ownerOfTopWindow(at point: CGPoint) -> pid_t? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        // Normal and floating only: the drag's own image sits above them, at layer 20, under the pointer.
        for window in windows where (window[kCGWindowLayer as String] as? Int) ?? 0 <= 3 {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
                (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.02
            else { continue }
            return window[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }

    private func titleOfElement(at point: CGPoint) -> String? {
        var element: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
                == .success,
            let element
        else { return nil }
        return Element(reference: element).string("AXTitle")
    }

    /// Drops only if `safe`. Otherwise Escape cancels the drag, so nothing lands, and the check is reported as skipped.
    private func release(at point: CGPoint, safe: Bool, _ name: String) async -> Bool {
        if !safe {
            Synthetic.key(53, down: true)
            Synthetic.key(53, down: false)
            await sleep(200)
            print("SKIP \(name): target wasn't frontmost, drag cancelled")
        }
        Synthetic.post(.leftMouseUp, point)
        return safe
    }

    /// Moves there first, or the press can go to the window that was last under the pointer.
    private func pressAndHold(at point: CGPoint) async {
        Synthetic.post(.mouseMoved, point)
        await sleep(200)
        Synthetic.post(.leftMouseDown, point)
        await sleep(250)
    }

    private func hostDrags(displayName: String) async {
        guard visual else { return }
        let source = FileDragSource(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        source.file = openWithFile
        let sourceWindow = smallWindow(NSRect(x: 620, y: 200, width: 120, height: 80), content: source, title: "Source")
        await sleep(400)
        let sourcePoint = CGPoint(
            x: NSScreen.topLeft(sourceWindow.frame).midX, y: NSScreen.topLeft(sourceWindow.frame).maxY - 40)

        // Onto the guest window: entered, moved, then dropped, with the file's real path.
        let target = CGPoint(x: 330, y: NSScreen.topLeft(NSRect(x: 120, y: 200, width: 420, height: 300)).midY)
        await pressAndHold(at: sourcePoint)
        await Synthetic.glide(from: sourcePoint, to: target)
        await sleep(300)
        let safeOnWindow = await release(
            at: target, safe: ownerOfTopWindow(at: target) == proxyPID, "host drag onto a proxy window")
        let droppedOnWindow = await waitFor(safeOnWindow ? 4 : 0.2) {
            has { if case .dragDropped = $0 { true } else { false } }
        }
        let enteredWith = events.compactMap { event -> [String]? in
            if case .dragEntered(let paths, _, _, _) = event { paths } else { nil }
        }.first
        let moves = events.filter { if case .dragMoved = $0 { true } else { false } }.count
        if safeOnWindow {
            check(
                "host drag onto a proxy window reaches the session",
                droppedOnWindow && enteredWith == [openWithFile.path],
                "\(moves) moves")
        }

        // Onto the Dock tile.
        if let tile = dockItem(titled: displayName)?.frame {
            events.removeAll()
            let point = CGPoint(x: tile.midX, y: tile.midY)
            await pressAndHold(at: sourcePoint)
            await Synthetic.glide(from: sourcePoint, to: point, steps: 40)
            for offset in [1.0, -1.0, 1.0, 0.0] {
                await sleep(150)
                Synthetic.post(.leftMouseDragged, CGPoint(x: point.x + offset, y: point.y))
            }
            await sleep(300)
            screenshot("dock-drop-hover.png", tile.insetBy(dx: -60, dy: -60))
            let safe = await release(
                at: point, safe: titleOfElement(at: point) == displayName, "drop on the Dock tile")
            if safe {
                let opened = await waitFor(4) {
                    has { if case .openDocuments(let paths) = $0 { paths == [openWithFile.path] } else { false } }
                }
                check("file dropped on the Dock tile reaches application(_:openFiles:)", opened)
            }
        }
        sourceWindow.close()

        // Out of the guest window, into a real Finder window, as a promised file.
        let folder = output.appending(path: "Dropped Here")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
        await sleep(1500)
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
            let window = (Element.application(pid: finder.processIdentifier).value("AXWindows") as? [AXUIElement])?
                .map(Element.init).first(where: { $0.string("AXTitle") == "Dropped Here" })
        else {
            check("Finder window opened for the drag out", false)
            return
        }
        window.set(position: CGPoint(x: 640, y: 200))
        await sleep(400)
        let finderFrame = window.frame ?? CGRect(x: 640, y: 200, width: 400, height: 300)
        let from = CGPoint(x: 300, y: target.y)
        let to = CGPoint(x: finderFrame.midX, y: finderFrame.midY)
        events.removeAll()
        await pressAndHold(at: from)
        await Synthetic.glide(from: from, to: to, steps: 40)
        await sleep(500)
        if await release(at: to, safe: ownerOfTopWindow(at: to) == finder.processIdentifier, "drag out to Finder") {
            let arrived = await waitFor(6) {
                FileManager.default.fileExists(atPath: folder.appending(path: "Promised By Guest.txt").path)
            }
            check("guest drag leaving a window lands in Finder as a promised file", arrived)
            let accepted = await waitFor(3) {
                has { if case .dragOutEnded(let accepted) = $0 { accepted } else { false } }
            }
            check("the proxy learns the host drag was accepted", accepted)
        }
        if let close = window.value("AXCloseButton") { Element(reference: close as! AXUIElement).perform("AXPress") }
        await sleep(300)
    }

    // MARK: Drags from the guest tool, under Rosetta

    private func runHelper(_ arguments: [String]) throws -> (Process, Pipe) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = helper
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        return (process, pipe)
    }

    private func finish(_ process: Process, _ pipe: Pipe, timeout: Double) async -> String {
        _ = await waitFor(timeout) { !process.isRunning }
        if process.isRunning { process.terminate() }
        return String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
    }

    private func dragsFromHelper() async {
        guard visual else { return }
        for backend in ["ns", "coredrag"] {
            let recorder = DropRecorder(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            let window = smallWindow(
                NSRect(x: 200, y: 300, width: 300, height: 200), content: recorder, title: "Guest target stand-in")
            await sleep(300)
            let frame = NSScreen.topLeft(window.frame)
            let target = CGPoint(x: frame.midX, y: frame.midY)
            guard let watcher = try? runHelper(["drag-watch", "--seconds", "6"]),
                let dragger = try? runHelper([
                    "drag-in", "--backend", backend, "--file", openWithFile.path, "--drive",
                    "\(Int(target.x)),\(Int(target.y))"
                ])
            else {
                check("run helper", false)
                return
            }
            CGWarpMouseCursorPosition(CGPoint(x: 700, y: 300))
            let dropped = await waitFor(10) { !recorder.dropped.isEmpty }
            let text = await finish(dragger.0, dragger.1, timeout: 4)
            let watched = await finish(watcher.0, watcher.1, timeout: 8)
            check(
                "\(backend) drag from a helper is a real drop on another process's view",
                dropped && recorder.dropped == [openWithFile.path],
                "entered \(recorder.entered), \(recorder.dropped)")
            report("\(backend)_helper_output", text.replacingOccurrences(of: "\n", with: " | "))
            report("\(backend)_drag_pasteboard_seen", watched.replacingOccurrences(of: "\n", with: " | "))
            window.close()
            await sleep(500)
        }
        await dragToSink()
    }

    private func dragToSink() async {
        let source = FileDragSource(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        source.file = openWithFile
        let window = smallWindow(NSRect(x: 200, y: 200, width: 120, height: 80), content: source, title: "Guest source")
        await sleep(300)
        guard let sink = try? runHelper(["drag-sink", "--seconds", "10"]) else {
            check("run sink", false)
            return
        }
        await sleep(1500)
        let frame = NSScreen.topLeft(window.frame)
        let from = CGPoint(x: frame.midX, y: frame.maxY - 40)
        // The sink covers the screen, so its shield is under this window, which is at the floating level below it.
        window.level = .screenSaver
        await sleep(200)
        await pressAndHold(at: from)
        let to = CGPoint(x: from.x + 400, y: from.y - 100)
        await Synthetic.glide(from: from, to: to)
        await sleep(400)
        Synthetic.post(.leftMouseUp, to)
        let text = await finish(sink.0, sink.1, timeout: 4)
        check(
            "drag sink reads the drag's files and completes it as a copy",
            text.contains("sink_concluded") && text.contains(openWithFile.lastPathComponent),
            text.replacingOccurrences(of: "\n", with: " | "))
        window.close()
    }

    private func cleanUp() async {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier?.contains(".guest.probe-") == true
        {
            app.forceTerminate()
        }
        await sleep(500)
        for bundle in bundles { try? ProxyBundle.remove(bundle) }
        try? FileManager.default.removeItem(at: applications)
        try? FileManager.default.removeItem(at: support)
        listener?.stop()
        report(
            "cleanup_proxies_left",
            "\(command("/usr/bin/mdfind", ["-onlyin", applications.deletingLastPathComponent().path, "kMDItemFSName == 'TextEdit (Mavericks).app'"]).count)"
        )
    }
}
