import AppKit
import MachineKit

private final class SettingsPage: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Pages have different heights, and this keeps the toolbar and top edge still instead of leaving the shorter page in a
/// large box.
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.fitSelectedPage() } }
    }

    private func fitSelectedPage() {
        guard let window = view.window, selectedTabViewItemIndex >= 0,
            let size = tabViewItems[selectedTabViewItemIndex].viewController?.preferredContentSize, size.width > 0,
            size.height > 0
        else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
    }
}

/// The Settings window.
@MainActor
final class SettingsWindow: NSObject {
    private let libraryChanged: (URL) -> Void
    private let checkForUpdates: (_ manually: Bool) -> Void
    private var window: NSWindow?
    private let libraryPopup = NSPopUpButton()
    private var updatesCheckbox: NSButton?

    private enum PopupTag: Int {
        case current = 0
        case other, standard
    }

    init(libraryChanged: @escaping (URL) -> Void, checkForUpdates: @escaping (_ manually: Bool) -> Void) {
        self.libraryChanged = libraryChanged
        self.checkForUpdates = checkForUpdates
    }

    var contentView: NSView? { window?.contentView }

    func show() {
        let window = window ?? makeWindow()
        refreshLibraryPopup()
        window.makeKeyAndOrderFront(nil)
    }

    func selectAdvancedTab() {
        (window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = 1
    }

    /// What a library folder panel attaches to, when this window is open.
    private func chooseLibraryFolder(from parent: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = LibraryLocationBridge.rootURL
        panel.prompt = "Use This Folder"
        panel.message =
            "This folder will contain Machines, Downloads and Installers. An external drive can save space on this Mac. Macs in other libraries stay where they are."
        let finished: (NSApplication.ModalResponse) -> Void = { [self] response in
            if response == .OK, let url = panel.url {
                do {
                    try LibraryLocationBridge.setURL(url)
                    libraryChanged(LibraryLocationBridge.currentURL)
                } catch {
                    VIMPresentError(error, parent)
                }
            }
            refreshLibraryPopup()
        }
        if let parent {
            panel.beginSheetModal(for: parent, completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }

    private func refreshLibraryPopup() {
        libraryPopup.removeAllItems()
        libraryPopup.addItem(withTitle: "Folders:")
        libraryPopup.lastItem?.isEnabled = false
        let root = LibraryLocationBridge.rootURL
        func addItem(_ title: String, _ tag: PopupTag, iconOf path: String? = nil) {
            libraryPopup.addItem(withTitle: title)
            libraryPopup.lastItem?.tag = tag.rawValue
            if let path, let icon = NSWorkspace.shared.icon(forFile: path).copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                libraryPopup.lastItem?.image = icon
            }
        }
        addItem(root.path, .current, iconOf: root.path)
        libraryPopup.menu?.addItem(.separator())
        let standard = LibraryLocationBridge.defaultURL
        if root.resolvingSymlinksInPath().path != standard.resolvingSymlinksInPath().path {
            addItem("Default", .standard, iconOf: standard.path)
        }
        addItem("Other…", .other)
        libraryPopup.selectItem(at: 1)
    }

    @objc private func libraryLocationChanged(_ sender: NSPopUpButton) {
        let tag = PopupTag(rawValue: sender.selectedItem?.tag ?? 0)
        if tag == .standard {
            let url = LibraryLocationBridge.defaultURL
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try LibraryLocationBridge.setURL(url)
                libraryChanged(url)
            } catch {
                VIMPresentError(error, window)
            }
            refreshLibraryPopup()
            return
        }
        sender.selectItem(at: 1)
        if tag == .other { chooseLibraryFolder(from: window) }
    }

    @objc private func toggleAutomaticUpdates(_ sender: NSButton) {
        let defaults = UserDefaults.standard
        let enabled = !defaults.bool(forKey: "VIMAutomaticUpdateChecks")
        defaults.set(enabled, forKey: "VIMAutomaticUpdateChecks")
        sender.state = enabled ? .on : .off
        if enabled { checkForUpdates(false) }
    }

    @objc private func checkNow(_ sender: Any?) { checkForUpdates(true) }
    @objc private func exportDiagnostics(_ sender: Any?) { VIMDiagnostics.export(from: window) }
    @objc private func revealLibrary(_ sender: Any?) { NSWorkspace.shared.open(LibraryLocationBridge.rootURL) }

    @objc private func revealDownloads(_ sender: Any?) {
        let url = LibraryLocationBridge.downloadsURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "No downloads yet"
            alert.informativeText = "Downloads will appear here when you create a Mac."
            VIMPresentAlert(alert, window, nil)
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func changeInstallerRetention(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "VIMKeepInstallers")
    }

    // MARK: Building

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 330), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Settings"
        window.collectionBehavior = .fullScreenNone
        self.window = window
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        let general = makeGeneralPage()
        let generalItem = NSTabViewItem(viewController: general)
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        tabs.addTabViewItem(generalItem)
        let (advanced, options) = makeAdvancedPage()
        let advancedItem = NSTabViewItem(viewController: advanced)
        advancedItem.label = "Advanced"
        advancedItem.image = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: "Advanced")
        tabs.addTabViewItem(advancedItem)
        window.contentViewController = tabs
        general.view.layoutSubtreeIfNeeded()
        let fitting = NSSize(width: 640, height: ceil(general.view.fittingSize.height))
        general.preferredContentSize = fitting
        tabs.preferredContentSize = fitting
        advanced.preferredContentSize = NSSize(width: 640, height: ceil(options.fittingSize.height) + 52)
        window.setContentSize(fitting)
        window.center()
        return window
    }

    private func makeGeneralPage() -> NSViewController {
        let page = NSViewController()
        page.view = SettingsPage(frame: NSRect(x: 0, y: 0, width: 640, height: 330))
        libraryPopup.target = self
        libraryPopup.action = #selector(libraryLocationChanged(_:))
        libraryPopup.autoenablesItems = false
        libraryPopup.setAccessibilityLabel("Virtual Macs folder")
        libraryPopup.widthAnchor.constraint(equalToConstant: 400).isActive = true
        libraryPopup.cell?.lineBreakMode = .byTruncatingMiddle
        refreshLibraryPopup()
        let updates = NSButton(
            checkboxWithTitle: "Automatically check for updates", target: self,
            action: #selector(toggleAutomaticUpdates(_:)))
        updatesCheckbox = updates
        updates.state = UserDefaults.standard.bool(forKey: "VIMAutomaticUpdateChecks") ? .on : .off
        let libraryActions = NSStackView(views: [
            NSButton(title: "Show in Finder", target: self, action: #selector(revealLibrary(_:))),
            NSButton(title: "Show Downloads in Finder", target: self, action: #selector(revealDownloads(_:)))
        ])
        libraryActions.spacing = 12
        let library = stack(
            [
                libraryPopup, libraryActions,
                secondaryLabel(
                    "Changing libraries does not move existing Macs. Setups already in progress keep their original location."
                )
            ], spacing: 8)
        let updateGroup = stack(
            [updates, NSButton(title: "Check Now", target: self, action: #selector(checkNow(_:)))], spacing: 10)
        let diagnostics = NSButton(title: "Export Diagnostics…", target: self, action: #selector(exportDiagnostics(_:)))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Virtual Macs folder:"), library],
            [NSTextField(labelWithString: "Updates:"), updateGroup],
            [NSTextField(labelWithString: "Support:"), diagnostics]
        ])
        grid.columnSpacing = 14
        grid.rowSpacing = 24
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 150
        grid.column(at: 1).xPlacement = .leading
        for row in 0..<3 { grid.row(at: row).yPlacement = .top }
        grid.row(at: 2).yPlacement = .center
        grid.translatesAutoresizingMaskIntoConstraints = false
        page.view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: page.view.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: page.view.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: page.view.topAnchor, constant: 28),
            grid.bottomAnchor.constraint(equalTo: page.view.bottomAnchor, constant: -22),
            page.view.widthAnchor.constraint(equalToConstant: 640),
            library.widthAnchor.constraint(equalToConstant: 400)
        ])
        return page
    }

    private func makeAdvancedPage() -> (NSViewController, NSView) {
        let page = NSViewController()
        page.view = SettingsPage(frame: NSRect(x: 0, y: 0, width: 640, height: 330))
        let keep = NSButton(
            checkboxWithTitle: "Keep downloaded files and installers", target: self,
            action: #selector(changeInstallerRetention(_:)))
        keep.state = UserDefaults.standard.bool(forKey: "VIMKeepInstallers") ? .on : .off
        let options = stack(
            [
                keep,
                secondaryLabel(
                    "Keep the finished installer app and disk image for another virtual Mac. Temporary preparation files are always removed. Otherwise, the installer image is removed after the operating system is installed and graphics support is verified."
                )
            ], spacing: 8)
        options.translatesAutoresizingMaskIntoConstraints = false
        page.view.addSubview(options)
        NSLayoutConstraint.activate([
            options.leadingAnchor.constraint(equalTo: page.view.leadingAnchor, constant: 32),
            options.trailingAnchor.constraint(equalTo: page.view.trailingAnchor, constant: -32),
            options.topAnchor.constraint(equalTo: page.view.topAnchor, constant: 28),
            options.bottomAnchor.constraint(equalTo: page.view.bottomAnchor, constant: -24),
            page.view.widthAnchor.constraint(equalToConstant: 640)
        ])
        return (page, options)
    }
}
