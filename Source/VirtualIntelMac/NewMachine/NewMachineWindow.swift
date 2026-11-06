import AppKit
import InstallerKit
import MachineKit
import UniformTypeIdentifiers

/// The creation assistant: choose a version, configure, then download, prepare and create. One lives for the app's
/// lifetime. Decisions are MachineKit's; this owns the pages and the order things happen in.
@objc(VIMNewMachineWindow)
final class NewMachineWindow: NSWindowController, NSWindowDelegate {
    private static var shared: NewMachineWindow?
    /// Volatile launch defaults exercise the real recovery sheet without downloading.
    private static let simulatedArchiveFailureKey = "VIMSimulateArchiveDownloadFailure"

    private let store = CreationJobStore()
    private let host: HostCapacity
    private let configuration: ConfigurationPage
    /// The guest the configuration page was last filled in for, if what's on it should survive going Back.
    private var configuredGuest: Guest?
    private let chooseButton = NSButton(title: "Use an Existing Installer…", target: nil, action: nil)
    private var choices: ChoicesPage?
    private var progressPage: ProgressPage?

    private var guest = Guest.mavericks
    private var installer: URL?
    private var job: CreationJob?
    private var downloadOnly = false
    private var progress = SetupProgress()

    private var isCreating = false
    private var transfer: InstallerDownloadBridge?
    private var tally: InstallerDownloadTally?
    private var inputs: [String: URL] = [:]
    private var lengthProbes: [Task<Void, Never>] = []
    private var assembly: VIMInstallerAssembly?
    private var preparationLock: PreparationLock?
    private var sleepActivity: VIMInstallationActivity?

    private var isCancelling = false
    private var closesAfterCancellation = false
    private var terminationCompletion: (() -> Void)?
    private var resumesAfterTermination = false

    private var pendingFailure: CreationIssue?
    private var pendingArchiveFailure: URL?
    /// The next installer failure offers the way back to choosing, as a blocked download left nothing else to do.
    private var isRecoveringWithInstaller = false
    private var pendingFailureOffersRecovery = false

    private var isBusy: Bool { isCreating || transfer != nil || assembly != nil }
    private var isShowingProgress: Bool { progressPage != nil }
    private var slot: CreationJobStore.Slot { downloadOnly ? .installerDownload : .creation }

    // MARK: - Objective-C interface

    @objc class var isCreating: Bool { shared?.isCreating ?? false }

    /// Stops a transfer or preparation for quitting. False if there's nothing to wait for.
    @objc(stopForTermination:) class func stopForTermination(_ completion: @escaping () -> Void) -> Bool {
        guard let controller = shared, controller.transfer != nil || controller.assembly != nil else { return false }
        controller.resumesAfterTermination = controller.job?.phase != .stopping
        controller.terminationCompletion = completion
        controller.pause()
        return true
    }

    @objc(showWithInstaller:guest:) class func show(installer: URL?, guest: String?) {
        let controller = shared ?? NewMachineWindow(host: .current)
        shared = controller
        if let installer, !controller.isBusy {
            controller.installer = installer
            if let guest = guest.flatMap(Guest.init(rawValue:)) {
                controller.guest = guest
                controller.resetConfigurationUnlessResuming()
                controller.configuration.show(guest)
            }
            controller.updateCreateButton()
            controller.window?.contentView = controller.configuration
        }
        if installer == nil, !controller.isBusy, controller.window?.isVisible == false {
            controller.installer = nil
            controller.progressPage = nil
            controller.configuredGuest = nil
            controller.showChoices()
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if installer != nil, controller.window?.contentView === controller.configuration {
            controller.configuration.focusEditor()
        }
    }

    /// Goes straight to the configuration page. Development only.
    @objc(showConfigurationForGuest:) class func showConfiguration(forGuest name: String) {
        guard let guest = Guest(rawValue: name) else { return }
        show(installer: nil, guest: nil)
        guard let controller = shared, !controller.isBusy else { return }
        controller.guest = guest
        controller.continueToConfiguration()
        if UserDefaults.standard.bool(forKey: simulatedArchiveFailureKey), guest.traits.contains(.restoreDVD) {
            let source = (InstallerCatalogBridge.file(guest: name, role: "diskimage")?["URL"] as? String)
                .flatMap(URL.init(string:))
            controller.presentDownloadFailure(URLError(.notConnectedToInternet), source: source)
        }
    }

    /// The visible production transfer flow, without creating or booting a guest. Useful for maintaining installer
    /// assets and resuming acquisition from the command line.
    @objc(downloadInstallerForGuest:) class func downloadInstaller(forGuest name: String) {
        guard let guest = Guest(rawValue: name) else { return }
        show(installer: nil, guest: nil)
        guard let controller = shared, !controller.isBusy else { return }
        controller.downloadOnly = true
        controller.job = nil
        controller.installer = nil
        controller.progress = SetupProgress()
        controller.guest = guest
        controller.resetConfigurationUnlessResuming()
        controller.configuration.show(guest)
        controller.beginSetup()
    }

    /// Fills the configuration page from arguments `main` has checked and presses Create. Numbers stay text, for the
    /// same validation as what's typed in the window. Development only.
    @objc(createGuestFromArguments:) class func createGuest(arguments: [String]) {
        let request = CreateGuestArguments(arguments: arguments)
        guard let guest = request.guest else {
            VIMFailCreateGuest(CreateGuestArguments.unknownGuestMessage)
            return
        }
        show(installer: nil, guest: nil)
        guard let controller = shared else { return }
        controller.guest = guest
        controller.resetConfigurationUnlessResuming()
        controller.configuration.show(guest)
        var values = controller.configuration.values
        values.name = request.name
        values.cores = request.cores ?? values.cores
        values.memory = request.memory ?? values.memory
        values.disk = request.disk ?? values.disk
        controller.configuration.values = values
        controller.configuration.setAccount(name: request.accountName, password: request.accountPassword ?? "")
        controller.beginSetup()
    }

    // MARK: - Lifecycle

    private init(host: HostCapacity) {
        self.host = host
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: assistantSize),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        configuration = ConfigurationPage(host: host)
        super.init(window: window)
        window.title = "Create Virtual Mac"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.autorecalculatesKeyViewLoop = true
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = .fullScreenNone
        window.contentMinSize = assistantSize
        window.contentMaxSize = assistantSize
        window.contentView = configuration

        chooseButton.target = self
        chooseButton.action = #selector(chooseInstaller)
        chooseButton.bezelStyle = .push
        configuration.onBack = { [weak self] in self?.showChoices() }
        configuration.onCreate = { [weak self] in self?.beginSetup() }
        configuration.reset(to: defaults(for: guest))
        if let saved = store.load(.creation) {
            job = saved
            guest = saved.guest
            let password = saved.automaticSetup?.credentialIdentifier.flatMap {
                try? VIMAutomaticSetup.password(forIdentifier: $0)
            }
            configuration.restore(saved, password: password)
            configuration.show(guest)
            configuration.syncSliders()
            updateCreateButton()
            progress = SetupProgress(fraction: saved.progress ?? 0)
        } else {
            showChoices()
        }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isCreating {
            present(
                CreationIssue(
                    detail: "Your virtual Mac is being created. Wait for this step to finish before closing the window."
                ))
            return false
        }
        guard isShowingProgress, job != nil else { return true }
        confirmCancellation(closing: true)
        return false
    }

    func windowDidEndSheet(_ notification: Notification) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.presentPendingFailure() } }
    }

    private func defaults(for guest: Guest) -> NewMachineDefaults {
        let space = try? FileManager.default.attributesOfFileSystem(forPath: LibraryLocationBridge.currentURL.path)
        return NewMachineDefaults(
            guest: guest, host: host, volumeBytes: (space?[.systemSize] as? NSNumber)?.uint64Value,
            freeBytes: (space?[.systemFreeSize] as? NSNumber)?.uint64Value)
    }

    // MARK: - Pages

    private func sizeWindowForPage() {
        window?.contentMinSize = .zero
        window?.contentMaxSize = assistantSize
        window?.contentMinSize = assistantSize
        window?.setContentSize(assistantSize)
    }

    private func showChoices() {
        guard !isBusy else { return }
        isRecoveringWithInstaller = false
        progressPage = nil
        sizeWindowForPage()
        let page = ChoicesPage(selection: guest, chooseButton: chooseButton)
        page.onSelect = { [weak self] in self?.select($0) }
        page.onContinue = { [weak self] in self?.continueToConfiguration() }
        choices = page
        window?.contentView = page
        page.focusSelection(guest)
    }

    private func select(_ guest: Guest) {
        self.guest = guest
        choices?.select(guest)
        configuration.show(guest)
        installer = nil
    }

    private func continueToConfiguration() {
        progressPage = nil
        resetConfigurationUnlessResuming()
        configuration.show(guest)
        updateCreateButton()
        sizeWindowForPage()
        window?.contentView = configuration
        configuration.focusEditor()
    }

    private func updateCreateButton() {
        configuration.createButton.title = job?.guest == guest ? "Resume Setup" : "Create"
    }

    private func resetConfigurationUnlessResuming() {
        if NewMachineDefaults.pageStartsOver(pageGuest: configuredGuest, jobGuest: job?.guest, guest: guest) {
            configuration.reset(to: defaults(for: guest))
        }
        configuredGuest = guest
    }

    @objc private func chooseInstaller() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.title = "Choose an OS Installer"
        panel.allowedContentTypes = [.applicationBundle, .diskImage]
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Use Installer"
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else {
                if isRecoveringWithInstaller {
                    presentInstallerChoiceFailure(
                        "Choose a downloaded installer, or choose a different OS version to continue.")
                }
                return
            }
            chooseButton.isEnabled = false
            Task {
                let inspected = await onWorkerQueue(qos: .utility) {
                    try VIMInstallerAssembly.guest(forInstallerApplication: url)
                }
                chooseButton.isEnabled = true
                switch inspected {
                case .failure(let error):
                    presentInstallerChoiceFailure(message(for: error))
                case .success(let name):
                    guard let guest = Guest(rawValue: name) else {
                        presentInstallerChoiceFailure(
                            "Choose a Tiger, Leopard or Snow Leopard restore DVD, or a Lion through Big Sur installer app."
                        )
                        return
                    }
                    isRecoveringWithInstaller = false
                    select(guest)
                    installer = url
                    continueToConfiguration()
                }
            }
        }
    }

    // MARK: - Failures

    private func present(_ issue: CreationIssue) {
        pendingFailure = issue
        presentPendingFailure()
    }

    private func message(for error: any Error, fallback: String = "Setup could not finish. Please try again.") -> String
    {
        // What Swift makes of an Objective-C failure that left no error.
        (error as NSError).domain == "Foundation._GenericObjCError" ? fallback : error.localizedDescription
    }

    private func presentInstallerChoiceFailure(_ detail: String) {
        pendingFailureOffersRecovery = isRecoveringWithInstaller
        present(CreationIssue(title: "Choose a supported OS installer", detail: detail))
    }

    private func presentDownloadFailure(_ failure: any Error, source: URL?) {
        let simulated = UserDefaults.standard.bool(forKey: Self.simulatedArchiveFailureKey)
        let region = simulated ? "CN" : (Locale.current as NSLocale).object(forKey: .countryCode) as? String
        if let source,
            InstallerSource.shouldExplainArchiveFailure(
                failure, source: source, guest: guest, region: region, timeZone: TimeZone.current.identifier)
        {
            pendingArchiveFailure = source
            presentPendingFailure()
        } else {
            present(CreationIssue(detail: message(for: failure)))
        }
    }

    private func presentPendingFailure() {
        guard let window, window.attachedSheet == nil else { return }
        if let source = pendingArchiveFailure {
            pendingArchiveFailure = nil
            isRecoveringWithInstaller = true
            let alert = NSAlert()
            VIMSetInstallerAlertIcon(alert, guest.rawValue)
            alert.messageText = SetupCopy.archiveFailureTitle(guest)
            alert.informativeText = SetupCopy.archiveFailureDetail(guest, filename: source.lastPathComponent)
            presentRecoveryAlert(alert, linking: source)
            return
        }
        guard let issue = pendingFailure else { return }
        pendingFailure = nil
        let alert = NSAlert()
        VIMSetInstallerAlertIcon(alert, guest.rawValue)
        alert.messageText = issue.title
        alert.informativeText = issue.detail
        if pendingFailureOffersRecovery {
            pendingFailureOffersRecovery = false
            presentRecoveryAlert(alert)
        } else {
            alert.addButton(withTitle: "OK")
            VIMPresentAlert(alert, window, nil)
        }
    }

    private func presentRecoveryAlert(_ alert: NSAlert, linking source: URL? = nil) {
        alert.addButton(withTitle: "Use Existing Installer")
        alert.addButton(withTitle: "Choose Different Version")
        if let source { linkFilename(of: source, in: alert) }
        VIMPresentAlert(alert, window) { [self] response in
            if response == .alertFirstButtonReturn { chooseInstaller() } else { showChoices() }
        }
    }

    /// Keeps the linked prose in AppKit's informative-text column, not a separately positioned accessory whose inset can
    /// differ between presentations.
    private func linkFilename(of source: URL, in alert: NSAlert) {
        alert.layout()
        let copy = alert.informativeText
        let paragraph = Self.textField(in: alert.window.contentView, showing: copy)
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        let text = NSMutableAttributedString(
            string: copy,
            attributes: [
                .font: paragraph?.font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ])
        text.addAttributes(
            [.link: source, .underlineStyle: NSUnderlineStyle.single.rawValue],
            range: (copy as NSString).range(of: source.lastPathComponent))
        paragraph?.isEditable = false
        paragraph?.isSelectable = true
        paragraph?.allowsEditingTextAttributes = true
        paragraph?.attributedStringValue = text
        paragraph?.alignment = .left
    }

    private static func textField(in view: NSView?, showing copy: String) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.stringValue == copy { return field }
        return view.subviews.lazy.compactMap { textField(in: $0, showing: copy) }.first
    }

    // MARK: - Setting up

    private func beginSetup() {
        guard !isBusy else { return }
        let specification: NewMachineSpecification
        do {
            specification = try configuration.values.validated(for: host)
        } catch {
            present(error)
            return
        }
        configuration.name = specification.name
        let automatic = !downloadOnly && configuration.isAutomaticSetupOn
        let password = configuration.password
        if automatic {
            do {
                try VIMAutomaticSetup.validateUsername(configuration.username)
                try VIMAutomaticSetup.validatePassword(password)
            } catch {
                present(CreationIssue(title: "Check your virtual Mac’s account", detail: message(for: error)))
                return
            }
            if password.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Enter a password for your virtual Mac"
                alert.informativeText =
                    "Automatic Setup needs a password to create your account. To set up the account yourself, turn off "
                    + "Automatic Setup in \"Advanced...\"."
                VIMSetInstallerAlertIcon(alert, guest.rawValue)
                alert.addButton(withTitle: "OK")
                VIMPresentAlert(alert, window) { [configuration] _ in configuration.focusPassword() }
                return
            }
        }
        guard updateJob(specification, automatic: automatic, password: password) else { return }
        continueJob()
    }

    /// Brings the job up to date with the page and saves it. False after presenting what stopped it.
    private func updateJob(_ specification: NewMachineSpecification, automatic: Bool, password: String) -> Bool {
        if let job, job.guest != guest {
            forgetPassword(of: job)
            self.job = nil
        }
        if job == nil {
            job = CreationJob(library: LibraryLocationBridge.currentURL.path, guest: guest)
            progress = SetupProgress()
        }
        guard var job else { return false }
        defer { self.job = job }
        if !downloadOnly, installer == nil, job.sourceInstaller == nil, job.media == nil {
            let retained = VIMInstallerAssembly.retainedInstaller(forGuest: guest.rawValue, library: job.libraryURL)
            if let media = retained["Media"] {
                job.media = media.path
            } else if let source = retained["SourceInstaller"] {
                job.sourceInstaller = source.path
            }
        }
        let space: [FileAttributeKey: Any]
        do {
            try FileManager.default.createDirectory(atPath: job.library, withIntermediateDirectories: true)
            space = try FileManager.default.attributesOfFileSystem(forPath: job.library)
        } catch {
            present(
                CreationIssue(detail: message(for: error, fallback: "Connect your library drive before continuing.")))
            return false
        }
        if let issue = job.spaceIssue(freeBytes: (space[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0) {
            present(issue)
            return false
        }
        // After the checks above, as nothing would ever remove a password whose new job isn't saved.
        if automatic {
            do {
                try VIMAutomaticSetup.savePassword(password, identifier: job.identifier)
            } catch {
                present(CreationIssue(detail: message(for: error)))
                return false
            }
            job.automaticSetup = configuration.automaticSetupProfile(identifier: job.identifier)
        } else {
            forgetPassword(of: job)
            job.automaticSetup = nil
        }
        job.apply(specification)
        if let installer { job.useInstaller(installer) }
        self.job = job
        saveJob()
        return true
    }

    private func forgetPassword(of job: CreationJob) {
        if job.automaticSetup != nil, job.machine == nil {
            try? VIMAutomaticSetup.removePassword(forIdentifier: job.identifier)
        }
    }

    private func continueJob() {
        guard let job else { return }
        switch job.nextStep() {
        case .openMachine(let url):
            do {
                let machine = try VIMMachine.load(url)
                try applySettings(to: machine)
                try VIMSession.open(machine)
                finishJob()
                close()
            } catch {
                present(CreationIssue(detail: message(for: error)))
            }
        case .createMachine(let media):
            installer = media
            createMachine()
        case .prepareMedia(let source):
            do {
                try VIMInstallerAssembly.validateInstallerApplication(source, guest: job.guest.rawValue)
            } catch {
                present(
                    CreationIssue(
                        title: "Choose a matching \(job.guest.family.rawValue) installer", detail: message(for: error)))
                return
            }
            showProgress()
            prepareMedia()
        case .download:
            let files: [InstallerFile]
            do {
                files = try InstallerCatalogBridge.files(for: job.guest)
            } catch {
                present(
                    CreationIssue(
                        detail: message(for: error, fallback: "The installer list is unavailable. Try again later.")))
                return
            }
            guard !files.isEmpty else {
                present(CreationIssue(detail: "The installer list is unavailable. Try again later."))
                return
            }
            inputs = [:]
            tally = InstallerDownloadTally(files: files)
            showProgress()
            loadDownloadLengths()
            downloadNextFile()
        }
    }

    private func applySettings(to machine: VIMMachine) throws {
        guard let job else { return }
        if let profile = job.automaticSetup { try machine.saveAutomaticSetup(profile.propertyList) }
        try machine.saveSettings(job.machineSettings)
    }

    private func saveJob() {
        guard let job else { return }
        store.save(job, to: slot)
        NotificationCenter.default.post(name: Notification.Name("VIMLibraryChanged"), object: nil)
    }

    private func setPhase(_ phase: CreationPhase) {
        reportCreationProgress(phase.rawValue)
        if job != nil {
            job?.phase = phase
            saveJob()
        }
        if !phase.isBusy {
            sleepActivity = nil
        } else if sleepActivity == nil {
            sleepActivity = VIMInstallationActivity.begin(withReason: "Preparing a virtual Mac installer")
        }
        progressPage?.show(phase)
    }

    /// The window is the only other place a `--create-guest` run's progress shows up. Never given the password.
    private func reportCreationProgress(_ message: String) {
        guard VIMCreatingGuestFromArguments() else { return }
        FileHandle.standardOutput.write(Data("create-guest: \(message)\n".utf8))
    }

    private func showProgress() {
        guard let job else { return }
        sizeWindowForPage()
        let page = ProgressPage(job: job, fraction: progress.fraction)
        page.pauseButton.target = self
        page.pauseButton.action = #selector(togglePause)
        page.cancelButton.target = self
        page.cancelButton.action = #selector(cancelSetup)
        progressPage = page
        window?.contentView = page
        setPhase(job.phase ?? .downloading)
    }

    /// Moves the bar, and persists it only when it's moved visibly. Phase changes refresh the library; bytes shouldn't.
    private func updateProgress() {
        progressPage?.bar.isIndeterminate = false
        progressPage?.bar.doubleValue = progress.fraction
        if job?.phase == .preparing { progressPage?.detail.stringValue = "Download complete. Preparing the installer." }
        if var job, progress.needsSaving(over: job.progress) {
            job.progress = progress.fraction
            self.job = job
            store.save(job, to: slot)
        }
    }

    @objc private func togglePause() {
        if transfer != nil || assembly != nil { pause() } else { beginSetup() }
    }

    private func pause() {
        stopLengthProbes()
        setPhase(.stopping)
        if let assembly {
            assembly.cancelled = true
            progressPage?.status.stringValue = "Stopping preparation safely…"
        } else {
            transfer?.pause()
        }
    }

    // MARK: - Downloading

    private func stopLengthProbes() {
        lengthProbes.forEach { $0.cancel() }
        lengthProbes = []
    }

    /// Fetches sizes up front for an honest estimate. Headers only: nothing downloads twice.
    private func loadDownloadLengths() {
        stopLengthProbes()
        guard let job, let files = tally?.files else { return }
        for file in files {
            let directory = LibraryLayout.downloadDirectory(for: file.url, library: job.libraryURL)
            if let length = InstallerLength.recorded(inDirectory: directory, source: file.url) {
                tally?.setLength(length, of: file.url)
                continue
            }
            var request = URLRequest(
                url: InstallerSource.downloadURL(for: file.url), cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 15)
            request.httpMethod = "HEAD"
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            lengthProbes.append(
                Task { [weak self] in
                    guard let (_, response) = try? await URLSession.shared.data(for: request), !Task.isCancelled,
                        let response = response as? HTTPURLResponse,
                        let length = InstallerLength.probed(
                            statusCode: response.statusCode, expectedContentLength: response.expectedContentLength),
                        let self
                    else { return }
                    tally?.setLength(length, of: file.url)
                    if let detail = tally?.detail { progressPage?.detail.stringValue = detail }
                })
        }
    }

    private func downloadNextFile() {
        guard let job else { return }
        guard let file = tally?.currentFile else {
            if downloadOnly {
                stopLengthProbes()
                setPhase(.downloaded)
                progressPage?.status.stringValue = "Download complete"
                progressPage?.detail.stringValue = "The installer download is saved in your library’s Downloads folder."
                progress.advance(to: 1)
                updateProgress()
                progressPage?.pauseButton.isEnabled = false
            } else {
                prepareMedia()
            }
            return
        }
        let source = file.url
        if UserDefaults.standard.bool(forKey: Self.simulatedArchiveFailureKey), job.guest.traits.contains(.restoreDVD) {
            stopLengthProbes()
            setPhase(.failed)
            presentDownloadFailure(URLError(.notConnectedToInternet), source: source)
            return
        }
        let transfer: InstallerDownloadBridge
        do {
            transfer = try InstallerDownloadBridge(
                sourceURL: source, directory: LibraryLayout.downloadDirectory(for: source, library: job.libraryURL))
        } catch {
            setPhase(.failed)
            present(CreationIssue(detail: message(for: error)))
            return
        }
        self.transfer = transfer
        tally?.restartRate()
        setPhase(.downloading)
        let status = SetupCopy.downloading(job.guest)
        progressPage?.status.stringValue = status
        transfer.progress = { [weak self] received, total in
            guard let self else { return }
            tally?.record(
                received: received, total: total, of: source, at: ProcessInfo.processInfo.systemUptime)
            let fraction = total > 0 ? Double(received) / Double(total) : 0
            progress.advance(to: tally?.overallFraction(ofCurrentFile: fraction) ?? 0)
            updateProgress()
            progressPage?.status.stringValue = status
            if let detail = tally?.detail { progressPage?.detail.stringValue = detail }
        }
        transfer.start { [weak self] file, failure, paused in
            guard let self else { return }
            self.transfer = nil
            if finishCancellation() || completeTermination() { return }
            if paused || failure != nil {
                stopLengthProbes()
                setPhase(failure != nil ? .failed : .paused)
                if let failure {
                    presentDownloadFailure(failure, source: source)
                } else {
                    progressPage?.status.stringValue = "Download paused"
                }
                progressPage?.bar.stopAnimation(nil)
                return
            }
            let size = file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }
            if let role = tally?.currentFile?.role.rawValue { inputs[role] = file }
            progress.advance(to: tally?.overallFraction(ofCurrentFile: 1) ?? 0)
            updateProgress()
            tally?.finishCurrentFile(size: size?.int64Value)
            downloadNextFile()
        }
    }

    // MARK: - Preparing

    private func prepareMedia() {
        guard let job else { return }
        stopLengthProbes()
        setPhase(.preparing)
        progressPage?.status.stringValue = "Checking download and preparing your Mac…"
        progress.advance(to: SetupProgress.downloadShare)
        updateProgress()
        let root = LibraryLayout.installers(forLibrary: job.libraryURL)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            setPhase(.failed)
            present(CreationIssue(detail: message(for: error)))
            return
        }
        guard let lock = PreparationLock(root: root) else {
            setPhase(.failed)
            present(
                CreationIssue(
                    detail: "Another Mac is preparing an installer in this library. Try again when it finishes."))
            return
        }
        preparationLock = lock
        PreparationScratch.removeAbandoned(
            root: root, library: job.libraryURL, jobMedia: job.media, jobInstaller: job.sourceInstaller)
        let worker = VIMInstallerAssembly()
        assembly = worker
        worker.progress = { [weak self] stage in
            self?.reportCreationProgress(stage)
            self?.progressPage?.status.stringValue = stage
        }
        worker.workProgress = { [weak self] fraction in
            self?.progress.advance(toPreparation: fraction)
            self?.updateProgress()
        }
        worker.timeRemaining = { [weak self] seconds in
            self?.progressPage?.detail.stringValue = SetupCopy.preparationRemaining(seconds: seconds)
        }
        let request = PreparationRequest(
            guest: job.guest, inputs: inputs, existingInstaller: job.sourceInstaller,
            preparedInstaller: job.preparedInstaller, root: root,
            attempt: root.appendingPathComponent(UUID().uuidString))
        Task {
            let outcome = await onWorkerQueue(qos: .userInitiated) {
                try self.runPreparation(request, worker: worker)
            }
            finishPreparation(worker: worker, outcome: outcome)
        }
    }

    private struct PreparationRequest: Sendable {
        let guest: Guest
        let inputs: [String: URL]
        let existingInstaller: String?
        let preparedInstaller: String?
        let root: URL
        let attempt: URL
    }

    /// The blocking part. Each step publishes its product to the job before retiring what it replaces, so an interrupted
    /// run resumes from the newest complete thing. Deletion stays off the main thread: it can be gigabytes on exFAT.
    private nonisolated func runPreparation(
        _ request: PreparationRequest, worker: VIMInstallerAssembly
    ) throws -> Bool {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: request.attempt, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let installer: URL
        if let existing = request.existingInstaller {
            installer = URL(fileURLWithPath: existing)
        } else {
            installer = try worker.assembleGuest(
                request.guest.rawValue, files: request.inputs,
                jobDirectory: request.attempt.appendingPathComponent("Assembly"))
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    job?.sourceInstaller = installer.path
                    job?.preparedInstaller = installer.path
                    saveJob()
                }
            }
            // A restore-DVD guest uses the download itself as its installer; only an assembled app supersedes them.
            if installer.pathExtension.lowercased() == "app" {
                VIMInstallerAssembly.retireCompletedDownloads(request.inputs)
            }
        }
        guard !worker.cancelled else { return false }
        let mediaDirectory = request.attempt.appendingPathComponent("Media")
        let media =
            request.guest == .bigSur
            ? try worker.createBigSurMedia(fromInstaller: installer, jobDirectory: mediaDirectory)
            : try worker.createRecoveryMedia(
                fromInstaller: installer, guest: request.guest.rawValue, jobDirectory: mediaDirectory)
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.installer = media
                job?.media = media.path
                saveJob()
            }
        }
        let prepared = request.existingInstaller != nil ? request.preparedInstaller : installer.path
        if !UserDefaults.standard.bool(forKey: "VIMKeepInstallers"), let prepared,
            PreparationScratch.retireAssembly(preparedInstaller: prepared, root: request.root)
        {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    job?.sourceInstaller = nil
                    job?.preparedInstaller = nil
                    saveJob()
                }
            }
        }
        return true
    }

    private func finishPreparation(worker: VIMInstallerAssembly, outcome: Result<Bool, any Error>) {
        worker.progress = nil
        worker.workProgress = nil
        worker.timeRemaining = nil
        assembly = nil
        progressPage?.bar.stopAnimation(nil)
        preparationLock?.release()
        preparationLock = nil
        if finishCancellation() || completeTermination() { return }
        switch outcome {
        case .success(true):
            progress.advance(to: 1)
            updateProgress()
            progressPage?.detail.stringValue = "Installer ready. Creating your virtual Mac."
            createMachine()
        case .success(false):
            stoppedOrFailedPreparation(nil, cancelled: true)
        case .failure(let error):
            stoppedOrFailedPreparation(error, cancelled: worker.cancelled)
        }
    }

    private func stoppedOrFailedPreparation(_ error: (any Error)?, cancelled: Bool) {
        setPhase(cancelled ? .paused : .failed)
        if cancelled {
            progressPage?.status.stringValue = "Preparation paused"
            return
        }
        let error = error.map { $0 as NSError }
        let described = error?.domain == "Foundation._GenericObjCError" ? nil : error
        present(
            SetupCopy.preparationFailure(
                description: described?.localizedDescription,
                recoverySuggestion: described?.localizedRecoverySuggestion))
    }

    // MARK: - Cancelling

    @objc private func cancelSetup() {
        confirmCancellation(closing: false)
    }

    private func confirmCancellation(closing: Bool) {
        guard !isCreating, let window, window.attachedSheet == nil else { return }
        closesAfterCancellation = closing
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to cancel creating this Mac?"
        VIMSetInstallerAlertIcon(alert, guest.rawValue)
        alert.informativeText = "Downloaded files and any Mac already created will be kept."
        // AppKit lays out the first button on the right. Keep No on the left and make it the safe Return-key default.
        alert.addButton(withTitle: "Yes").keyEquivalent = ""
        alert.addButton(withTitle: "No").keyEquivalent = "\r"
        VIMPresentAlert(alert, window) { [self] response in
            guard response == .alertFirstButtonReturn, !isCreating else {
                closesAfterCancellation = false
                return
            }
            isCancelling = true
            if transfer != nil || assembly != nil { pause() } else { finishCancellation() }
        }
    }

    @discardableResult private func finishCancellation() -> Bool {
        guard isCancelling else { return false }
        let closes = closesAfterCancellation
        closesAfterCancellation = false
        isCancelling = false
        finishJob()
        progressPage?.bar.stopAnimation(nil)
        showChoices()
        if closes { window?.close() }
        completeTermination()
        return true
    }

    @discardableResult private func completeTermination() -> Bool {
        guard let completion = terminationCompletion else { return false }
        // Keep active intent for the next launch, except an explicit user pause.
        if job != nil {
            job?.phase = resumesAfterTermination ? .downloading : .paused
            saveJob()
        }
        terminationCompletion = nil
        Task { completion() }
        return true
    }

    private func finishJob() {
        stopLengthProbes()
        pendingFailure = nil
        progressPage = nil
        sleepActivity = nil
        if let job { forgetPassword(of: job) }
        store.remove(slot)
        job = nil
        configuredGuest = nil
        installer = nil
        progress = SetupProgress()
        downloadOnly = false
        NotificationCenter.default.post(name: Notification.Name("VIMLibraryChanged"), object: nil)
    }

    // MARK: - Creating

    private func createMachine() {
        guard !isCreating else { return }
        let name = job?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let job, let installer, !name.isEmpty, let disk = job.diskGiB, NewMachineForm.diskRangeGiB.contains(disk)
        else {
            setPhase(.failed)
            present(CreationIssue(detail: "Choose an installer, enter a name, and use a disk size from 40 to 2048 GB."))
            return
        }
        let resources =
            if let root = VIMDevelopmentSourceRoot(), !root.isEmpty {
                CreationResources(
                    developmentSourceRoot: URL(fileURLWithPath: root, isDirectory: true), guest: job.guest)
            } else {
                CreationResources(
                    runtime: (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Runtime"),
                    guest: job.guest)
            }
        if let missing = resources.missingFile() {
            setPhase(.failed)
            present(CreationIssue(detail: "This build is missing a creation resource: \(missing)"))
            return
        }
        isCreating = true
        setControlsEnabled(false)
        setPhase(.creating)
        progressPage?.status.stringValue = "Creating Macintosh HD."
        progressPage?.bar.startAnimation(nil)
        let (guest, library) = (job.guest, job.libraryURL)
        Task {
            let created = await onWorkerQueue(qos: .userInitiated) {
                try VIMMachine.createGuest(
                    guest.rawValue, name: name, diskGiB: UInt(disk), library: library, firmware: resources.firmware,
                    nvram: resources.nvram, bootMedia: resources.bootMedia, installer: installer,
                    qemuImage: resources.qemuImage)
            }
            finishCreating(created, guest: guest)
        }
    }

    private func setControlsEnabled(_ enabled: Bool) {
        configuration.setEditable(enabled)
        chooseButton.isEnabled = enabled
    }

    private func finishCreating(_ created: Result<VIMMachine, any Error>, guest: Guest) {
        isCreating = false
        setControlsEnabled(true)
        progressPage?.bar.stopAnimation(nil)
        let machine: VIMMachine
        switch created {
        case .success(let value): machine = value
        case .failure(let error):
            setPhase(.failed)
            present(CreationIssue(detail: message(for: error, fallback: "Could not create this Mac.")))
            return
        }
        job?.machine = machine.url.path
        saveJob()
        reportCreationProgress(machine.url.path)
        do {
            try applySettings(to: machine)
        } catch {
            setPhase(.failed)
            present(CreationIssue(detail: message(for: error)))
            return
        }
        NotificationCenter.default.post(name: Notification.Name("VIMLibraryChanged"), object: nil)
        progressPage?.status.stringValue = "Your Mac is ready to install \(guest.family.rawValue)."
        do {
            try VIMSession.open(machine)
            finishJob()
            close()
        } catch {
            setPhase(.failed)
            present(
                CreationIssue(
                    detail: "Your Mac was saved in the library, but could not start: \(error.localizedDescription)"))
        }
    }
}

/// Runs blocking work on a GCD queue, which minutes-long tool runs would starve the cooperative pool of, and comes back.
@MainActor private func onWorkerQueue<Value: Sendable>(
    qos: DispatchQoS.QoSClass, _ work: @escaping @Sendable () throws -> Value
) async -> Result<Value, any Error> {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: qos).async { continuation.resume(returning: Result<Value, any Error> { try work() }) }
    }
}
