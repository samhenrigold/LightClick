import AppKit
import MachineKit

private let releasesURL = URL(string: "https://github.com/samhenrigold/LightClick/releases")!
private let projectURL = URL(string: "https://github.com/samhenrigold/LightClick")!
private let issuesURL = URL(string: "https://github.com/samhenrigold/LightClick/issues?q=is%3Aissue")!

private func argumentError(_ message: String) -> NSError {
    NSError(domain: "VirtualIntelMac.Arguments", code: 64, userInfo: [NSLocalizedDescriptionKey: message])
}

/// The app's lifecycle, its menus' app-wide items and its command line.
@MainActor @objc(AppDelegate)
final class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet var window: NSWindow?
    private let updateChecker = VIMUpdateChecker()
    private var updateTimer: Timer?
    private var libraryController: LibraryViewController?
    private var quitTimer: Timer?
    private var activatedAt: TimeInterval = 0
    private var quitConfirmationPending = false
    private var quitApproved = false
    private var menuController: VIMMenuController?
    private let launch = AppLaunchArguments(ProcessInfo.processInfo.arguments)

    private lazy var settings = SettingsWindow(
        libraryChanged: { [unowned self] url in
            window?.representedURL = url
            libraryController?.reloadLibrary()
        },
        checkForUpdates: { [unowned self] manually in updateChecker.checkManually(manually) })

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillFinishLaunching(_ notification: Notification) {
        SeamlessHost.prepareIfRequested()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startHarnessRequests()
        if let notice = VIMHostUpdateNotice(ProcessInfo.processInfo.operatingSystemVersion) {
            presentHostUpdateNotice(notice)
            return
        }
        UserDefaults.standard.register(defaults: ["VIMAutomaticUpdateChecks": true])
        prepareLibraryLayout()
        let library = setUpLibraryWindow()
        setUpMenus()
        menuController = VIMMenuController(library: library)
        startRequestedAssistants()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateChecker.checkManually(false) }
        }
        updateChecker.checkManually(false)
        showRequestedSettings()
        if launch.contains("--about") { showAbout(nil) }
        for command in launch.machineCommands { run(command) }
        SeamlessHost.startIfRequested { [weak self] in self?.waitForShutdown() }
        checkTranslation()
        VIMCheckRosetta { missing, error in
            MainActor.assumeIsolated {
                if let error {
                    VIMPresentError(error, NSApp.mainWindow)
                } else if missing {
                    VIMPresentRosettaRequiredAlert(NSApp.mainWindow)
                }
            }
        }
    }

    // MARK: Launching

    /// A development harness uses the real signed app and XPC authorization, with no VM and no second emulator connection.
    private func startHarnessRequests() {
        if let probe = launch.usbProbe {
            nonisolated(unsafe) let client = VIMUSBClient()
            let identity = ["LocationID": probe.locationID, "VendorID": probe.vendorID, "ProductID": probe.productID]
            client.checkStorageInterface(identity, inUserSession: probe.inUserSession) { result, error in
                // Keeps the XPC owner until the one bounded request completes.
                _ = client
                let response: Any = error.map { ["Error": $0.localizedDescription] } ?? result ?? [:]
                let data = try? JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
                try? data?.write(to: URL(fileURLWithPath: probe.output), options: .atomic)
            }
        }
        if launch.contains("--usb-helper-authorize-stdin") {
            VIMUSBClient.authorizeUsingTerminal { error in
                NSLog("USB helper authorization: %@", error?.localizedDescription ?? "ready")
            }
        }
        if launch.contains("--network-helper-authorize-stdin") {
            VIMNetworkClient.authorizeUsingTerminal { error in
                NSLog("Network helper authorization: %@", error?.localizedDescription ?? "ready")
            }
        }
    }

    private func presentHostUpdateNotice(_ notice: String) {
        let alert = NSAlert()
        alert.messageText = notice
        alert.informativeText = "Check the Light Click releases page for a version compatible with this Mac."
        alert.addButton(withTitle: "Check for Updates")
        alert.addButton(withTitle: "Quit")
        VIMPresentAlert(alert, nil) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(releasesURL) }
            NSApp.terminate(nil)
        }
    }

    private func prepareLibraryLayout() {
        do {
            try LibraryLocationBridge.prepareLayout()
        } catch {
            guard (error as NSError).code != EBUSY else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { VIMPresentError(error, self.window) }
            }
        }
    }

    private func setUpLibraryWindow() -> LibraryViewController {
        let window =
            self.window
            ?? NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        self.window = window
        window.isReleasedWhenClosed = false
        let library = LibraryViewController()
        libraryController = library
        window.title = "Light Click Library"
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])
        window.collectionBehavior.insert(.fullScreenNone)
        window.contentViewController = library
        window.setContentSize(NSSize(width: 540, height: 378))
        window.center()
        return library
    }

    private func setUpMenus() {
        guard let main = NSApp.mainMenu else { return }
        if let format = main.item(withTitle: "Format") { main.removeItem(format) }
        if let appMenu = main.items.first?.submenu {
            for item in appMenu.items where item.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) {
                item.target = self
                item.action = #selector(showAbout(_:))
            }
            for item in appMenu.items where item.keyEquivalent == "," { appMenu.removeItem(item) }
            let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
            settings.target = self
            appMenu.insertItem(settings, at: min(2, appMenu.numberOfItems))
            let check = NSMenuItem(
                title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
            check.target = self
            appMenu.insertItem(check, at: min(2, appMenu.numberOfItems))
        }
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Light Click Project", action: #selector(visitProject(_:)), keyEquivalent: "").target =
            self
        help.addItem(withTitle: "Get Help from Community", action: #selector(reportIssue(_:)), keyEquivalent: "")
            .target = self
        help.addItem(withTitle: "Report an Issue…", action: #selector(reportIssue(_:)), keyEquivalent: "").target = self
        var helpItem = main.items.last { $0.submenu === NSApp.helpMenu && $0.submenu != nil }
        if helpItem == nil {
            helpItem = NSMenuItem()
            main.addItem(helpItem!)
        }
        helpItem?.submenu = help
        NSApp.helpMenu = help
    }

    /// Relaunching opens the library, never an unsolicited assistant, and saved downloads stay resumable when the user
    /// opens setup.
    private func startRequestedAssistants() {
        if launch.contains("--new-mac") { NewMachineWindow.show(installer: nil, guest: nil) }
        if let guest = launch.value(after: "--configure-new-guest") {
            NewMachineWindow.showConfiguration(forGuest: guest)
        }
        if let guest = launch.value(after: "--download-installer") {
            NewMachineWindow.downloadInstaller(forGuest: guest)
        }
        if VIMCreatingGuestFromArguments() {
            // A failed run mustn't leave its QEMU behind.
            atexit_b { MainActor.assumeIsolated { VIMSession.stopAll() } }
            NewMachineWindow.createGuest(arguments: launch.arguments)
        }
    }

    private func showRequestedSettings() {
        guard launch.contains("--show-settings") else { return }
        settings.show()
        if launch.value(after: "--settings-tab") == "Advanced" { settings.selectAdvancedTab() }
        guard let path = launch.absolutePath(after: "--settings-capture") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                guard let view = self.settings.contentView else { return }
                view.layoutSubtreeIfNeeded()
                guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: image)
                try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private func run(_ command: AppLaunchArguments.MachineCommand) {
        guard let path = command.path else {
            VIMPresentError(
                argumentError(
                    "--configure-vm/--show-vm/--open-vm/--prepare-vm/--install-vm requires a Mac package path."),
                nil)
            return
        }
        do {
            let machine = try VIMMachine.load(URL(fileURLWithPath: path))
            // The same persistent settings path as Configure, and not a second emulator or network implementation.
            switch launch.networkOverride {
            case nil: break
            case .invalid:
                VIMPresentError(argumentError("--network-mode requires shared, host, or bridged."), nil)
                return
            case .settings(let mode, let bridge):
                var settings: [String: Any] = ["NetworkMode": mode, "NetworkConnected": true]
                settings["BridgeInterface"] = bridge
                try machine.saveSettings(settings)
            }
            switch command.action {
            case .configure: configure(machine)
            case .show: VIMSession.showMachineWindow(machine)
            case .repair: try start { try VIMSession.repair(machine) }
            case .install: try start { try VIMSession.installMachine(machine) }
            case .prepare: try start { try VIMSession.prepare(machine) }
            case .open: try start { try VIMSession.open(machine) }
            }
        } catch {
            VIMPresentError(error, nil)
        }
    }

    /// A seamless session reports a failure through its proxy, which is what the user can see.
    private func start(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch  where launch.contains("--seamless-session") {
            return
        }
    }

    private func configure(_ machine: VIMMachine) {
        MachineSettings.show(for: machine, window: nil, completion: nil)
        if let pane = launch.value(after: "--configuration-pane") {
            MachineSettings.show(
                for: machine, section: AppLaunchArguments.configurationSection(forPane: pane), category: pane,
                window: nil)
        }
        if launch.contains("--configuration-cycle-check") {
            MachineSettings.checkPaneCycling(for: machine) { passed in
                NSLog(
                    "Configuration pane cycling: %@ (21 transitions, outgoing table layout and sidebar elasticity)",
                    passed ? "PASS" : "FAIL")
            }
        }
        if let path = launch.absolutePath(after: "--configuration-capture") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    do {
                        try MachineSettings.capture(for: machine, to: URL(fileURLWithPath: path))
                    } catch {
                        VIMPresentError(error, NSApp.mainWindow)
                    }
                }
            }
        }
    }

    private func checkTranslation() {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated != 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Turn off Rosetta for Light Click"
        alert.informativeText =
            "Light Click needs to run natively on this Apple silicon Mac. Quit the app, select it in Finder, and choose File → Get Info. Turn off “Open using Rosetta”, then open the app again."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Not Now")
        VIMPresentAlert(alert, NSApp.mainWindow) { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
        }
    }

    // MARK: Quitting

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SeamlessHost.leaveAll()
        switch QuitDecision(
            confirmationPending: quitConfirmationPending, creatingMachine: NewMachineWindow.isCreating,
            runningMachines: VIMSession.hasRunningMachines(), approved: quitApproved)
        {
        case .alreadyAsking:
            return .terminateCancel
        case .waitForCreation:
            quitApproved = false
            let alert = NSAlert()
            alert.messageText = "A Mac is being created"
            alert.informativeText =
                "Wait for the new disk to finish being created before quitting. Your existing Macs are unchanged."
            alert.addButton(withTitle: "OK")
            VIMPresentAlert(alert, nil, nil)
            return .terminateCancel
        case .confirmShutdown:
            confirmShutdown()
            return .terminateCancel
        case .proceed:
            break
        }
        quitApproved = false
        quitTimer?.invalidate()
        quitTimer = nil
        let waiting = NewMachineWindow.stopForTermination {
            MainActor.assumeIsolated {
                VIMSession.stopAll()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        if waiting { return .terminateLater }
        VIMSession.stopAll()
        return .terminateNow
    }

    private func confirmShutdown() {
        let alert = NSAlert()
        alert.messageText = "Shut down your Macs and quit?"
        let names = VIMSession.runningMachineNames().joined(separator: ", ")
        alert.informativeText =
            "Running: \(names)\n\nSave your work in each virtual Mac before shutting down. Force Stop stops immediately without letting macOS finish."
        alert.addButton(withTitle: "Shut Down and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Force Stop and Quit")
        quitConfirmationPending = true
        VIMPresentAlert(alert, nil) { [self] response in
            quitConfirmationPending = false
            switch response {
            case .alertFirstButtonReturn:
                waitForShutdown()
            case .alertThirdButtonReturn:
                quitApproved = true
                NSApp.terminate(nil)
            default:
                quitTimer?.invalidate()
                quitTimer = nil
            }
        }
    }

    private func waitForShutdown() {
        quitTimer?.invalidate()
        VIMSession.requestShutdownAll()
        let deadline = Date(timeIntervalSinceNow: 60)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] fired in
            nonisolated(unsafe) let timer = fired
            MainActor.assumeIsolated {
                if !VIMSession.hasRunningMachines() {
                    timer.invalidate()
                    self?.quitTimer = nil
                    NSApp.terminate(nil)
                } else if deadline.timeIntervalSinceNow <= 0 {
                    timer.invalidate()
                    self?.quitTimer = nil
                    self?.shutdownTimedOut()
                }
            }
        }
        quitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func shutdownTimedOut() {
        // Nobody can see this app in a session, so it mustn't stay to ask.
        if launch.contains("--seamless-session") || launch.contains("--seamless-make-proxy") {
            quitApproved = true
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Your virtual Mac is still shutting down"
        alert.informativeText =
            "The app will stay open so you can check the virtual Mac’s window. If guest tools are unavailable, choose Shut Down from its Apple menu. Use Force Stop only if it is unresponsive."
        alert.addButton(withTitle: "Keep App Open")
        VIMPresentAlert(alert, nil, nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        quitTimer?.invalidate()
    }

    // MARK: Actions

    @objc private func checkForUpdates(_ sender: Any?) { updateChecker.checkManually(true) }
    @IBAction func newMac(_ sender: Any?) { NewMachineWindow.show(installer: nil, guest: nil) }
    @objc func showInstallers(_ sender: Any?) { NewMachineWindow.show(installer: nil, guest: nil) }
    @IBAction func showLibrary(_ sender: Any?) { libraryController?.showLibrary() }
    @objc private func showSettings(_ sender: Any?) { settings.show() }
    @objc private func visitProject(_ sender: Any?) { NSWorkspace.shared.open(projectURL) }
    @objc private func reportIssue(_ sender: Any?) { NSWorkspace.shared.open(issuesURL) }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.isFileURL, LibraryCatalog.isPackage(url) else {
                VIMPresentError(
                    NSError(
                        domain: "VirtualIntelMac.Documents", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Choose a virtual Mac package (.vintelmac)."]), nil)
                continue
            }
            libraryController?.registerPackageURL(url)
            do {
                VIMSession.showMachineWindow(try VIMMachine.load(url))
            } catch {
                VIMPresentError(error, nil)
            }
        }
        libraryController?.reloadLibrary()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        activatedAt = ProcessInfo.processInfo.systemUptime
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows visible: Bool) -> Bool {
        // Light Click's own tile is one way back from Seamless, since its window with the button is what's gone.
        if SeamlessHost.leaveAll() { return false }
        // A Dock click that only brings the app forward keeps the user's windows, and a click while already frontmost or
        // with no window opens the library. The reopen event can arrive just before or just after activation, and either
        // way the app was in the background when clicked.
        let background = !NSApp.isActive || ProcessInfo.processInfo.systemUptime - activatedAt < 0.5
        if !visible || !background { libraryController?.showLibrary() }
        return false
    }

    @IBAction func showAbout(_ sender: Any?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 5
        let text = "Based on Virtual Intel Mac by nfzerox\nProject on GitHub"
        let credits = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ])
        let name = (text as NSString).range(of: "nfzerox")
        credits.addAttribute(.link, value: URL(string: "https://github.com/nfzerox")!, range: name)
        credits.addAttribute(.link, value: projectURL, range: (text as NSString).range(of: "Project on GitHub"))
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Light Click", .credits: credits])
    }
}
