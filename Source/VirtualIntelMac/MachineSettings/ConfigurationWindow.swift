import AppKit
import InstallerKit
import MachineKit

/// A machine's configuration window: a toolbar of sections, a sidebar of categories, and a page rebuilt whenever anything
/// about them changes. Pages are in the extensions in this folder.
final class ConfigurationWindow: NSWindowController, NSToolbarDelegate, NSTableViewDelegate, NSTableViewDataSource,
    NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate, NSTabViewDelegate
{
    static let contentWidth: CGFloat = 660

    var machine: VIMMachine
    var completion: (() -> Void)?
    var invalidField = false
    private(set) var section = SettingsSection.hardware
    private(set) var categoryIndex = 0
    var showsHostDirections = true
    var editorSheet: ConfigurationSheet?
    var guestUsername = ""
    var storage: PackageStorage?
    var feedback = NSTextField()
    var memoryField: NSTextField?
    var memorySlider: NSSlider?
    var memoryStepper: NSStepper?
    var descriptionEditor: NSTextView?
    private var descriptionTimer: Timer?
    private(set) var sidebar: ConfigurationSidebar?

    var category: SettingsCategory? {
        categoryIndex < section.categories.count ? section.categories[categoryIndex] : nil
    }

    var editable: [AnyHashable: Any] { machine.editableConfiguration }
    private var identifier: String? { machine.configuration["Identifier"] as? String }

    init(machine: VIMMachine) {
        self.machine = machine
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.windowController = self
        window.backgroundColor = .windowBackgroundColor
        window.autorecalculatesKeyViewLoop = true
        window.collectionBehavior = .fullScreenNone
        guestUsername = savedGuestUsername
        let center = NotificationCenter.default
        for name in ["VIMLibraryChanged", "VIMNetworkChanged"] {
            center.addObserver(
                self, selector: #selector(sessionStateChanged), name: Notification.Name(name), object: nil)
        }
        center.addObserver(
            self, selector: #selector(packageRelocated), name: Notification.Name("VIMMachineRelocated"), object: nil)
        window.title = Self.title(for: machine)
        let toolbar = NSToolbar(identifier: "VIMConfigurationToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        window.tabbingMode = .disallowed
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(section.rawValue)
        render()
        window.center()
        readStorageSizes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func title(for machine: VIMMachine) -> String { "“\(machine.name)” Configuration" }

    private var savedGuestUsername: String {
        UserDefaults.standard.string(forKey: "VIMGuestUsername-" + machine.url.path) ?? ""
    }

    func isShowing(_ machine: VIMMachine) -> Bool {
        identifier != nil && identifier == machine.configuration["Identifier"] as? String
    }

    // MARK: - Notifications

    @objc private func sessionStateChanged() {
        if let fresh = try? VIMMachine.load(machine.url) { machine = fresh }
        if !(window?.firstResponder is NSTextView) {
            guestUsername = savedGuestUsername
            render()
        }
    }

    @objc private func packageRelocated(_ note: Notification) {
        guard note.userInfo?["Identifier"] as? String == identifier else { return }
        if let url = note.userInfo?["URL"] as? URL, let fresh = try? VIMMachine.load(url) { machine = fresh }
        window?.title = Self.title(for: machine)
        render()
    }

    private func readStorageSizes() {
        let package = machine.url
        let disk = machine.configuration["Disk"] as? String
        Task {
            let measured = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: PackageStorage.measure(package: package, disk: disk))
                }
            }
            storage = measured
            // Only General shows these. Replacing Hardware as this scan finishes would needlessly recreate its controls
            // just after opening.
            if window?.isVisible == true, section == .general, !(window?.firstResponder is NSTextView) { render() }
        }
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsSection.allCases.map { NSToolbarItem.Identifier($0.rawValue) } + [.flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsSection.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = identifier.rawValue
        if let section = SettingsSection(rawValue: identifier.rawValue) {
            item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: identifier.rawValue)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .regular))
        }
        item.target = self
        item.action = #selector(toolbarItemSelected)
        return item
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        if let section = SettingsSection(identifier: sender.itemIdentifier.rawValue) { select(section) }
    }

    /// Moves to `section`, unless a field there can't be left yet.
    func select(_ section: SettingsSection) {
        saveDescription()
        window?.makeFirstResponder(nil)
        if invalidField {
            window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(self.section.rawValue)
            return
        }
        self.section = section
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(section.rawValue)
        categoryIndex = 0
        render()
    }

    func select(_ category: SettingsCategory) {
        guard let index = section.categories.firstIndex(of: category) else { return }
        categoryIndex = index
        render()
    }

    // MARK: - Page

    /// Rebuilds the whole page.
    func render() {
        guard let window else { return }
        // AppKit can finish laying out an outgoing table during a section switch. Retire its callbacks first.
        sidebar?.delegate = nil
        sidebar?.dataSource = nil
        sidebar = nil
        var top = window.frame.maxY
        window.setContentSize(NSSize(width: Self.contentWidth, height: section.contentHeight))
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
        descriptionEditor = nil
        let content = ConfigurationDocument()
        content.drawsWindowBackground = true
        window.contentView = content
        feedback = settingsText("")
        feedback.textColor = .systemRed
        feedback.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(feedback)
        var left: CGFloat = 24
        if section != .general {
            addSidebar(to: content)
            left = 213
            if section == .sharing {
                feedback.isHidden = true
                let tabs = makeSharingPage()
                tabs.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(tabs)
                NSLayoutConstraint.activate([
                    tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: left),
                    tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                    tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                    tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
                ])
                content.layoutSubtreeIfNeeded()
                return
            }
            let box = NSBox()
            box.boxType = .custom
            box.borderWidth = 0.5
            box.borderColor = .separatorColor
            box.cornerRadius = 4
            box.fillColor = .controlBackgroundColor
            box.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(box, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: left),
                box.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                box.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                box.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
            ])
            left += 20
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = section != .general
        scroll.autohidesScrollers = true
        scroll.identifier = NSUserInterfaceItemIdentifier("ConfigurationDetail")
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        let document = ConfigurationDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let pane = section == .general ? makeGeneralPage() : makeHardwarePage()
        alignFormBaselines(in: pane)
        pane.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(pane)
        let hasRestore = section == .hardware && category?.hasRestoreDefaults == true
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: left),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            scroll.bottomAnchor.constraint(equalTo: feedback.topAnchor, constant: hasRestore ? -46 : -12),
            feedback.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            feedback.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            feedback.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            pane.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            pane.topAnchor.constraint(equalTo: document.topAnchor),
            pane.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        if hasRestore {
            let restore = button("Restore Defaults", #selector(restoreDefaults))
            restore.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(restore)
            NSLayoutConstraint.activate([
                restore.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
                restore.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -30)
            ])
        }
        if section == .general {
            content.layoutSubtreeIfNeeded()
            let fitting = ceil(pane.fittingSize.height) + 24 + 12 + ceil(feedback.fittingSize.height) + 16
            top = window.frame.maxY
            window.setContentSize(NSSize(width: Self.contentWidth, height: fitting))
            frame = window.frame
            frame.origin.y = top - frame.height
            window.setFrame(frame, display: true)
        }
        // Resolve the scroll view, grid and fixed-width controls before this pane can be presented. Otherwise the
        // processor popup is first drawn at its intrinsic menu width and shrinks on the next layout pass.
        content.layoutSubtreeIfNeeded()
    }

    private func addSidebar(to content: NSView) {
        let scroll = FixedSidebarScroll()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = FixedSidebarClip()
        scroll.borderType = .lineBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        let table = ConfigurationSidebar()
        table.categories = section.categories
        sidebar = table
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 40
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .textBackgroundColor
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        column.width = 187
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(section == .hardware ? "Hardware categories" : "Sharing categories")
        table.dataSource = self
        scroll.documentView = table
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalToConstant: 189)
        ])
        // With empty selection disallowed, AppKit may select row zero while attaching the data source. Establish the
        // intended category before observing changes, rather than reentering render during setup.
        table.selectRowIndexes(IndexSet(integer: categoryIndex), byExtendingSelection: false)
        table.delegate = self
        // Rebuilding the pane must not leave first responder on the discarded table, which makes the newly selected row
        // immediately turn inactive.
        window?.makeFirstResponder(table)
    }

    // MARK: - Sidebar

    func numberOfRows(in tableView: NSTableView) -> Int {
        (tableView as? ConfigurationSidebar)?.categories.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let categories = (tableView as? ConfigurationSidebar)?.categories, categories.indices.contains(row)
        else { return nil }
        let category = categories[row]
        let cell = NSTableCellView()
        let icon = VIMSettingsIcon(
            symbol: category.symbol, color: Self.color(for: category), glyphSize: category == .clipboard ? 16 : 20)
        let label = NSTextField(labelWithString: category.rawValue)
        label.font = .systemFont(ofSize: 13)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
        ])
        cell.textField = label
        return cell
    }

    private static func color(for category: SettingsCategory) -> NSColor {
        switch category {
        case .cpuAndMemory, .network, .fileSharing: .systemBlue
        case .graphics: .systemIndigo
        case .sound: .systemPink
        case .hardDisk: .systemGray
        case .mouseAndKeyboard, .remoteLogin: .darkGray
        case .clipboard: .systemOrange
        case .opticalDrive: .systemTeal
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table === sidebar, table.selectedRow >= 0,
            table.selectedRow != categoryIndex
        else { return }
        window?.makeFirstResponder(nil)
        if invalidField {
            table.selectRowIndexes(IndexSet(integer: categoryIndex), byExtendingSelection: false)
            return
        }
        categoryIndex = table.selectedRow
        render()
    }

    // MARK: - Saving

    func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    /// Saves, tells the library, and presents any failure. False if it failed.
    @discardableResult func commit(_ settings: [String: Any]) -> Bool {
        do {
            try machine.saveSettings(settings)
        } catch {
            VIMPresentError(error, window)
            return false
        }
        completion?()
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        invalidField = false
        switch field.identifier?.rawValue {
        case "GuestUsername": guestUsernameEdited(field.stringValue)
        case "Name": nameEdited(field.stringValue)
        case "MemoryMiB": memoryEdited(field.stringValue)
        default: break
        }
    }

    private func guestUsernameEdited(_ value: String) {
        if let issue = SettingsValidation.guestUsernameIssue(value) {
            feedback.stringValue = issue.message
            invalidField = true
            return
        }
        guard value != guestUsername else {
            feedback.stringValue = ""
            return
        }
        guestUsername = value
        UserDefaults.standard.set(value, forKey: "VIMGuestUsername-" + machine.url.path)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.render() } }
    }

    private func nameEdited(_ value: String) {
        guard value != (machine.pendingName ?? machine.name) else {
            feedback.stringValue = ""
            return
        }
        do {
            try machine.rename(value)
            feedback.stringValue = ""
            window?.title = Self.title(for: machine)
            completion?()
        } catch {
            feedback.stringValue = error.localizedDescription
            invalidField = true
        }
    }

    private func memoryEdited(_ text: String) {
        switch hardwareLimits.memoryMiB(from: text, saved: (editable["MemoryMiB"] as? NSNumber)?.intValue) {
        case .failure(let issue):
            feedback.stringValue = issue.message
            invalidField = true
        case .success(let value):
            guard (editable["MemoryMiB"] as? NSNumber)?.intValue != value else {
                feedback.stringValue = ""
                return
            }
            do {
                try machine.saveSettings(["MemoryMiB": value])
                feedback.stringValue = ""
                memorySlider?.doubleValue = Double(value) / 1024
                memoryStepper?.integerValue = value
                completion?()
            } catch {
                feedback.stringValue = error.localizedDescription
                invalidField = true
            }
        }
    }

    var hardwareLimits: SettingsHardwareLimits {
        SettingsHardwareLimits(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            processorCount: ProcessInfo.processInfo.processorCount)
    }

    // MARK: - Description

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === descriptionEditor else { return }
        descriptionTimer?.invalidate()
        descriptionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveDescription() }
        }
    }

    func saveDescription() {
        descriptionTimer?.invalidate()
        descriptionTimer = nil
        if let text = descriptionEditor?.string, text != (editable["Description"] as? String ?? "") {
            commit(["Description": text])
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        saveDescription()
        return !invalidField
    }

    // MARK: - Editor sheets

    func present(_ sheet: ConfigurationSheet) {
        guard let window, window.attachedSheet == nil, let sheetWindow = sheet.window else { return }
        editorSheet = sheet
        window.beginSheet(sheetWindow) { [weak self] _ in self?.editorSheet = nil }
    }
}
