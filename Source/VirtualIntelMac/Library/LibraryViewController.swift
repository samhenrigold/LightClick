import AppKit
import MachineKit
import UniformTypeIdentifiers

private let dragType = NSPasteboard.PasteboardType("gold.samhenri.LightClick.library-row")
private let registeredPackagesKey = "VIMRegisteredPackages"

/// One background scan's answer.
private struct LibraryScan: Sendable {
    var machines: [VIMMachine]
    var catalog: [String: LibraryRecord]
    var libraryUnavailable: Bool
    var unavailableCount: Int
}

/// A strip under the toolbar for news about the library. As a titlebar accessory, it leaves the rows' sizing alone.
@MainActor
private final class LibraryNoticeBar: NSTitlebarAccessoryViewController {
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 28))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        view = bar
        layoutAttribute = .bottom
    }

    func show(_ text: String?) {
        loadViewIfNeeded()
        label.stringValue = text ?? ""
        label.toolTip = text
        isHidden = text == nil
    }
}

/// The library window: its table of Macs, and the catalog and order kept for each library in preferences.
@MainActor @objc(VIMLibraryViewController)
final class LibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate,
    NSMenuDelegate, NSWindowDelegate, NSMenuItemValidation
{
    @objc private(set) var compact = false
    private var machines: [VIMMachine] = []
    private var visibleMachines: [VIMMachine] = []
    private let table = LibraryTable()
    private let scroll = NSScrollView()
    private var scanGeneration = 0
    private var libraryLoaded = false
    private var presentedEmptyCreation = false
    private var wantsLibraryWindow = false
    private var libraryRequestedExplicitly = false
    private var automaticContentSize = NSSize.zero
    private let noticeBar = LibraryNoticeBar()
    private var libraryUnavailable = false

    private var defaults: UserDefaults { .standard }
    private var libraryPath: String { LibraryLocationBridge.currentURL.path }
    private var arrangeKey: String { "VIMLibraryArrange-" + libraryPath }
    private var catalogKey: String { "VIMLibraryKnown-" + libraryPath }
    private var orderKey: String { "VIMLibraryOrder-" + libraryPath }
    private var rowHeight: CGFloat { LibraryWindowLayout.rowHeight(compact: compact) }

    private var selected: VIMMachine? {
        let row = table.selectedRow
        return row >= 0 && row < visibleMachines.count ? visibleMachines[row] : nil
    }

    @objc var selectedMachine: VIMMachine? { selected }
    @objc var arrangement: String { defaults.string(forKey: arrangeKey) ?? "None" }

    // MARK: Views

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 378))
        wantsLibraryWindow = true
        noticeBar.show(nil)
        compact = defaults.bool(forKey: "VIMCompactLibrary")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.automaticallyAdjustsContentInsets = false
        table.headerView = nil
        table.style = .plain
        table.setAccessibilityLabel("Virtual Macs")
        table.registerForDraggedTypes([dragType, .fileURL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .windowBackgroundColor
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("machine"))
        column.width = 540
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openMachineWindow(_:))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let names = [
            Notification.Name("VIMLibraryChanged"), Notification.Name("VIMMachineRelocated"),
            NSApplication.didBecomeActiveNotification
        ]
        for name in names {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh(_:)), name: name, object: nil)
        }
        reloadLibrary()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        window.delegate = self
        window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])
        window.collectionBehavior.insert(.fullScreenNone)
        guard window.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "VIMLibraryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.title = "Light Click Library"
        window.titleVisibility = .visible
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.addTitlebarAccessoryViewController(noticeBar)
        sizeLibraryWindow()
        updateLibraryVisibility()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, NSToolbarItem.Identifier("density"), NSToolbarItem.Identifier("new")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier.rawValue == "new" {
            item.label = "New Mac"
            item.toolTip = "New Mac"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Mac")
            item.target = self
            item.action = #selector(newMac(_:))
        } else {
            let density = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "rectangle.grid.1x2", accessibilityDescription: "Large thumbnails")!,
                    NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Compact list")!
                ], trackingMode: .selectOne, target: self, action: #selector(changeDensity(_:)))
            density.selectedSegment = compact ? 1 : 0
            density.setToolTip("Large thumbnails", forSegment: 0)
            density.setToolTip("Compact list", forSegment: 1)
            item.label = "View"
            item.view = density
        }
        return item
    }

    @objc private func changeDensity(_ sender: NSSegmentedControl) {
        setCompact(sender.selectedSegment == 1)
    }

    private func setCompact(_ value: Bool) {
        compact = value
        defaults.set(compact, forKey: "VIMCompactLibrary")
        automaticContentSize = .zero
        table.rowHeight = rowHeight
        table.reloadData()
        sizeLibraryWindow()
        for item in view.window?.toolbar?.items ?? [] where item.itemIdentifier.rawValue == "density" {
            (item.view as? NSSegmentedControl)?.selectedSegment = compact ? 1 : 0
        }
    }

    @objc func setDensityFromMenu(_ sender: NSMenuItem) { setCompact(sender.tag == 1) }

    @objc func arrangeFromMenu(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject, forKey: arrangeKey)
        applyFilter()
    }

    /// Refreshes must not snap a manually resized window back to its default.
    private func sizeLibraryWindow() {
        guard let window else { return }
        let rows = LibraryWindowLayout.rowsHeight(count: visibleMachines.count, compact: compact)
        window.contentMinSize = NSSize(width: 440, height: min(rows, 126))
        window.contentMaxSize = NSSize(width: 10000, height: rows)
        var current = window.contentView?.bounds.size ?? .zero
        if current.height > rows {
            window.setContentSize(NSSize(width: current.width, height: rows))
            current = window.contentView?.bounds.size ?? .zero
        }
        if automaticContentSize != .zero,
            abs(current.width - automaticContentSize.width) > 1 || abs(current.height - automaticContentSize.height) > 1
        {
            return
        }
        let chrome = window.frame.height - current.height
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let height = LibraryWindowLayout.automaticHeight(
            rowsHeight: rows, availableHeight: visible.height - chrome - 48)
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: max(440, current.width), height: height))
        var frame = window.frame
        frame.origin.y = top - frame.height
        automaticContentSize = window.contentView?.bounds.size ?? .zero
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        window.setFrame(frame, display: true)
    }

    private var window: NSWindow? { viewIfLoaded?.window }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let font = NSFont.systemFont(ofSize: 22, weight: .light)
        let titleWidth =
            visibleMachines.map { ($0.name as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let width = LibraryWindowLayout.standardWidth(
            titleWidth: titleWidth, compact: compact, visibleWidth: visible.width)
        let chrome = window.frame.height - (window.contentView?.bounds.height ?? 0)
        let height = min(visible.height - 40, CGFloat(max(1, visibleMachines.count)) * table.rowHeight + chrome)
        return NSRect(
            x: max(visible.minX, min(window.frame.minX, visible.maxX - width)),
            y: max(visible.minY, window.frame.maxY - height), width: width, height: height)
    }

    @objc func newMac(_ sender: Any?) { NewMachineWindow.show(installer: nil, guest: nil) }
    @objc private func refresh(_ sender: Any?) { reloadLibrary() }

    @objc func showLibrary() {
        wantsLibraryWindow = true
        libraryRequestedExplicitly = true
        reloadLibrary()
    }

    // MARK: Adding packages

    @objc func registerPackageURL(_ url: URL) {
        guard url.isFileURL, LibraryCatalog.isPackage(url) else { return }
        var paths = defaults.array(forKey: registeredPackagesKey) as? [String] ?? []
        let path = url.resolvingSymlinksInPath().path
        if !paths.contains(path) { paths.append(path) }
        defaults.set(paths, forKey: registeredPackagesKey)
        reloadLibrary()
    }

    private func packagePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        if let package = UTType(filenameExtension: "vintelmac") { panel.allowedContentTypes = [package] }
        return panel
    }

    @objc func openExistingMac(_ sender: Any?) {
        guard let window else { return }
        let panel = packagePanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        panel.message = "Choose existing Mac packages. Their disks stay in their current locations."
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK else { return }
            for url in panel.urls { registerPackageURL(url) }
        }
    }

    // MARK: Dragging

    private func droppedPackages(_ info: any NSDraggingInfo) -> [URL] {
        let urls =
            info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).filter(LibraryCatalog.isPackage)
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        if info.draggingSource as? NSTableView === tableView, info.draggingPasteboard.string(forType: dragType) != nil {
            tableView.setDropRow(max(0, min(row, visibleMachines.count)), dropOperation: .above)
            return .move
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return droppedPackages(info).isEmpty ? [] : .link
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        if info.draggingSource as? NSTableView === tableView {
            return moveMachine(atPath: info.draggingPasteboard.string(forType: dragType), beforeVisibleRow: row)
        }
        let packages = droppedPackages(info)
        for url in packages { registerPackageURL(url) }
        return !packages.isEmpty
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row >= 0, row < visibleMachines.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(visibleMachines[row].url.path, forType: dragType)
        return item
    }

    private func moveMachine(atPath path: String?, beforeVisibleRow row: Int) -> Bool {
        guard let path, row >= 0, row <= visibleMachines.count,
            let moving = machines.first(where: { $0.url.path == path })
        else { return false }
        let before = row < visibleMachines.count ? visibleMachines[row] : nil
        if before === moving { return true }
        machines = LibraryOrder.moved(machines, moving: moving, before: before)
        defaults.set("None", forKey: arrangeKey)
        // Scans that began before the user changed the order are out of date.
        scanGeneration += 1
        defaults.set(machines.map(\.url.path), forKey: orderKey)
        applyFilter()
        if let selection = visibleMachines.firstIndex(of: moving) {
            table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        }
        return true
    }

    // MARK: Scanning

    private var knownRecords: [String: LibraryRecord] {
        (defaults.dictionary(forKey: catalogKey) ?? [:]).mapValues(LibraryRecord.init(foundationObject:))
    }

    @objc func reloadLibrary() {
        guard isViewLoaded else { return }
        scanGeneration += 1
        let generation = scanGeneration
        let library = LibraryLocationBridge.machinesURL
        let key = catalogKey
        let known = knownRecords
        let registered = defaults.array(forKey: registeredPackagesKey) as? [String] ?? []
        let savedOrder = defaults.array(forKey: orderKey) as? [String] ?? []
        Task {
            let scan = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        returning: Self.scan(
                            library: library, known: known, registered: registered, savedOrder: savedOrder))
                }
            }
            guard generation == scanGeneration else { return }
            // Known rows stay while an external library is disconnected.
            libraryLoaded = true
            machines = scan.machines
            libraryUnavailable = scan.libraryUnavailable
            noticeBar.show(
                LibraryNotice.text(
                    libraryUnavailable: scan.libraryUnavailable, unavailableCount: scan.unavailableCount))
            defaults.set(scan.catalog.mapValues(\.foundationObject), forKey: key)
            applyFilter()
        }
    }

    private nonisolated static func scan(
        library: URL, known: [String: LibraryRecord], registered: [String], savedOrder: [String]
    ) -> LibraryScan {
        let files = FileManager.default
        var found: [URL] = []
        var libraryUnavailable = false
        do {
            found = try files.contentsOfDirectory(
                at: library, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        } catch {
            let libraryRoot = library.deletingLastPathComponent()
            libraryUnavailable = LibraryNotice.libraryIsUnavailable(
                readFailed: true, machinesFolderMissing: (error as NSError).code == NSFileReadNoSuchFileError,
                rootExists: files.fileExists(atPath: libraryRoot.path),
                isStandardLibrary: libraryRoot.standardizedFileURL
                    == LibraryLocationBridge.defaultURL.standardizedFileURL)
        }
        let inFolder = found.filter(LibraryCatalog.isPackage).map { $0.resolvingSymlinksInPath().path }
        var loaded: [VIMMachine] = []
        var packages: [LibraryPackage] = []
        var missing: [String] = []
        for path in LibraryCatalog.candidatePaths(known: known, registered: registered, inFolder: inFolder) {
            guard let machine = try? VIMMachine.load(URL(fileURLWithPath: path)) else {
                missing.append(path)
                continue
            }
            // A normal scan is read-only, since taking every stopped machine's session lock would race a reboot's next
            // launch. Only queued edits or the old UUID name migration need maintenance.
            let oldName =
                machine.configuration["Name"] != nil
                && UUID(uuidString: machine.url.deletingPathExtension().lastPathComponent) != nil
            let pending = machine.url.appendingPathComponent("State/PendingConfiguration.plist")
            if oldName || files.fileExists(atPath: pending.path) { try? machine.applyPendingChanges() }
            loaded.append(machine)
            packages.append(
                LibraryPackage(
                    path: machine.url.path,
                    record: LibraryRecord(
                        name: machine.name, guest: machine.guest,
                        identifier: machine.configuration["Identifier"] as? String ?? path)))
        }
        let result = LibraryCatalog.reconcile(loaded: packages, missing: missing, known: known)
        let rows = result.unavailable.map {
            UnavailableMac(url: URL(fileURLWithPath: $0.path), name: $0.name, guest: $0.guest) as VIMMachine
        }
        let machines = LibraryOrder.sorted(loaded + rows, savedOrder: savedOrder, path: \.url.path, name: \.name)
        return LibraryScan(
            machines: machines, catalog: result.catalog, libraryUnavailable: libraryUnavailable,
            unavailableCount: rows.count)
    }

    private func arrangementValue(of machine: VIMMachine, _ chosen: LibraryArrangement) -> LibraryArrangement.Value {
        switch chosen {
        case .none, .name: return .text(machine.name)
        case .type: return .text(machine.guest)
        case .dateLastOpened:
            let opened = defaults.dictionary(forKey: "VIMLastOpened")
            let key = machine.configuration["Identifier"] as? String ?? machine.url.path
            return .date(opened?[key] as? Date ?? .distantPast)
        case .dateCreated:
            return .date((try? machine.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast)
        case .size:
            guard let disk = machine.configuration["Disk"] as? String, !disk.isEmpty else { return .size(0) }
            let values = try? machine.url.appendingPathComponent(disk).resourceValues(forKeys: [
                .totalFileAllocatedSizeKey
            ])
            return .size(Int64(values?.totalFileAllocatedSize ?? 0))
        case .tags:
            let tags = (try? machine.url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            let sorted = tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return .text(sorted.joined(separator: ", "))
        }
    }

    private func applyFilter() {
        let previousTop = scroll.contentView.bounds.minY
        let selection = selected?.url
        let chosen = LibraryArrangement(savedName: arrangement)
        visibleMachines = chosen.sorted(machines, value: { arrangementValue(of: $0, chosen) }, name: \.name)
        table.reloadData()
        if let index = visibleMachines.firstIndex(where: { $0.url == selection }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        sizeLibraryWindow()
        view.layoutSubtreeIfNeeded()
        let maxTop = max(0, CGFloat(visibleMachines.count) * table.rowHeight - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(previousTop, maxTop))))
        scroll.reflectScrolledClipView(scroll.contentView)
        updateLibraryVisibility()
    }

    private func updateLibraryVisibility() {
        guard libraryLoaded, let window else { return }
        // With no library to create a Mac in, the window stays to say why.
        guard !machines.isEmpty || libraryUnavailable else {
            window.orderOut(nil)
            if !presentedEmptyCreation {
                presentedEmptyCreation = true
                NewMachineWindow.show(installer: nil, guest: nil)
            }
            return
        }
        presentedEmptyCreation = false
        guard wantsLibraryWindow else { return }
        // A background scan mustn't cover a creation or progress window opened by a launch argument. An explicit Library
        // action still brings it forward.
        let anotherWindow = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.level == .normal }
        if libraryRequestedExplicitly || !anotherWindow { window.makeKeyAndOrderFront(nil) }
        wantsLibraryWindow = false
        libraryRequestedExplicitly = false
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { visibleMachines.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = LibraryRow()
        view.thumbnailWidth = LibraryWindowLayout.thumbnailWidth(compact: compact)
        return view
    }

    private func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 20, weight: .regular)) ?? image
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let machine = visibleMachines[row]
        let unavailable = machine is UnavailableMac
        let running = !unavailable && VIMSession.isRunning(machine)
        let cell = LibraryCell()
        cell.compact = compact
        cell.thumbnailWidth = LibraryWindowLayout.thumbnailWidth(compact: compact)
        cell.table = tableView
        addThumbnail(for: machine, to: cell)

        let title = LibraryLabel(labelWithString: machine.name)
        title.font = .systemFont(ofSize: compact ? 17 : 22, weight: .light)
        title.lineBreakMode = .byTruncatingTail
        let configuration = machine.configuration
        let resources =
            unavailable
            ? "Mac Unavailable"
            : LibraryRowText.resources(
                cpuCount: configuration["CPUCount"],
                memoryMiB: (configuration["MemoryMiB"] as? NSNumber)?.doubleValue ?? 0,
                diskBytes: machine.diskCapacityBytes)
        let specifications = LibraryLabel(labelWithString: resources)
        specifications.font = .systemFont(ofSize: compact ? 11 : 12)
        specifications.textColor = .secondaryLabelColor
        specifications.lineBreakMode = .byTruncatingTail
        specifications.toolTip = resources
        cell.specifications = specifications

        let continuing =
            !unavailable
            && LibraryRowText.continuesSetup(
                preMetalGuest: machine.preMetalGuest, installState: configuration["InstallState"],
                requiresInstallerDisplay: !machine.preMetalGuest && machine.requiresInstallerDisplay)
        let action = LibraryRowText.action(unavailable: unavailable, running: running, continuingSetup: continuing)
        let label = "\(action) \(machine.name)"
        let start = VIMPlayButton()
        start.target = self
        start.action = #selector(rowStart(_:))
        start.controlDiameter = compact ? 40 : 58
        start.glyphScale = 1.35
        start.tag = row
        start.contentTintColor = .labelColor
        start.setAccessibilityLabel(label)
        start.toolTip = label
        cell.primary = start

        let configure = NSButton(image: symbol("gearshape"), target: self, action: #selector(rowConfigure(_:)))
        configure.isBordered = false
        configure.contentTintColor = .secondaryLabelColor
        configure.toolTip = "Configure \(machine.name)"
        configure.tag = row
        configure.isEnabled = !unavailable
        configure.setAccessibilityLabel(configure.toolTip)
        cell.configure = configure

        for view in [title, specifications, start, configure] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(
                equalTo: cell.leadingAnchor, constant: cell.thumbnailWidth + (compact ? 22 : 32)),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: compact ? -58 : -24),
            specifications.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            specifications.trailingAnchor.constraint(
                lessThanOrEqualTo: cell.trailingAnchor, constant: compact ? -58 : -24),
            specifications.topAnchor.constraint(equalTo: title.bottomAnchor, constant: compact ? 3 : 4),
            start.centerXAnchor.constraint(equalTo: cell.leadingAnchor, constant: cell.thumbnailWidth / 2),
            start.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            start.widthAnchor.constraint(equalToConstant: cell.thumbnailWidth),
            start.heightAnchor.constraint(equalTo: cell.heightAnchor)
        ])
        if compact {
            NSLayoutConstraint.activate([
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 10),
                configure.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -18),
                configure.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        } else {
            addPowerButton(
                to: cell, title: title, configure: configure, label: label, row: row,
                symbolName: running ? "arrow.up.forward.square" : unavailable ? "folder.badge.questionmark" : "power")
        }
        cell.hovered = false
        let status = unavailable ? "Unavailable. Locate this Mac’s package." : VIMSession.status(for: machine)
        cell.toolTip = "\(machine.name)\n\(resources)\n\(status)"
        cell.textField = title
        return cell
    }

    /// A standard image view, centered and aspect-filled inside a clipped pane. AppKit has aspect-fit but no aspect-fill,
    /// so the image view is sized to cover the pane and the pane crops it, with no custom drawing.
    private func addThumbnail(for machine: VIMMachine, to cell: LibraryCell) {
        let thumbnail = NSView()
        thumbnail.wantsLayer = true
        thumbnail.layer?.masksToBounds = true
        let wallpaper = NSImage(
            named: LibraryRowText.wallpaperName(guest: machine.guest) { NSImage(named: $0) != nil })
        let image = NSImageView()
        image.image = wallpaper
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityElement(false)
        image.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.addSubview(image)
        cell.addSubview(thumbnail)
        cell.imageView = image
        let size = wallpaper?.size ?? .zero
        let aspect = size.height > 0 ? size.width / size.height : 1.6
        let fit = image.widthAnchor.constraint(equalTo: thumbnail.widthAnchor)
        fit.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            thumbnail.topAnchor.constraint(equalTo: cell.topAnchor),
            thumbnail.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: cell.thumbnailWidth),
            image.centerXAnchor.constraint(equalTo: thumbnail.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: thumbnail.centerYAnchor),
            image.widthAnchor.constraint(greaterThanOrEqualTo: thumbnail.widthAnchor),
            image.heightAnchor.constraint(greaterThanOrEqualTo: thumbnail.heightAnchor),
            image.widthAnchor.constraint(equalTo: image.heightAnchor, multiplier: aspect), fit
        ])
    }

    private func addPowerButton(
        to cell: LibraryCell, title: NSTextField, configure: NSButton, label: String, row: Int, symbolName: String
    ) {
        let power = NSButton(image: symbol(symbolName), target: self, action: #selector(rowStart(_:)))
        power.isBordered = false
        power.contentTintColor = .secondaryLabelColor
        power.tag = row
        power.setAccessibilityLabel(label)
        power.toolTip = label
        power.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(power)
        cell.addSubview(separator)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 25),
            power.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: cell.thumbnailWidth + 30),
            power.centerYAnchor.constraint(equalTo: cell.topAnchor, constant: table.rowHeight * (101.0 / 126)),
            power.widthAnchor.constraint(equalToConstant: 22),
            power.heightAnchor.constraint(equalToConstant: 24),
            separator.leadingAnchor.constraint(equalTo: power.trailingAnchor, constant: 14),
            separator.centerYAnchor.constraint(equalTo: power.centerYAnchor),
            separator.heightAnchor.constraint(equalToConstant: 15),
            separator.widthAnchor.constraint(equalToConstant: 1),
            configure.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 16),
            configure.centerYAnchor.constraint(equalTo: power.centerYAnchor)
        ])
    }

    @objc private func rowStart(_ sender: NSButton) {
        table.selectRowIndexes(IndexSet(integer: sender.tag), byExtendingSelection: false)
        startMachine(nil)
    }

    @objc private func rowConfigure(_ sender: NSButton) {
        table.selectRowIndexes(IndexSet(integer: sender.tag), byExtendingSelection: false)
        machineSettings(nil)
    }

    // MARK: Menu and actions

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        if row >= 0 { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        guard let selected else { return }
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        if selected is UnavailableMac {
            add("Locate Mac…", #selector(startMachine(_:)))
            add("Show in Finder", #selector(revealMachine(_:)))
            menu.addItem(.separator())
            add("Remove from Library…", #selector(removeSelectedMachine(_:)))
            return
        }
        add(VIMSession.isRunning(selected) ? "Show" : "Start", #selector(startMachine(_:)))
        add("Open Window", #selector(openMachineWindow(_:)))
        add("Configure…", #selector(machineSettings(_:)))
        menu.addItem(.separator())
        add("Rename…", #selector(renameMachine(_:)))
        add("Show in Finder", #selector(revealMachine(_:)))
        menu.addItem(.separator())
        add("Delete…", #selector(removeSelectedMachine(_:)))
    }

    @objc private func revealMachine(_ sender: Any?) {
        if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected.url]) }
    }

    @objc private func openMachineWindow(_ sender: Any?) {
        guard let selected else { return }
        if let unavailable = selected as? UnavailableMac {
            locate(unavailable)
        } else {
            VIMSession.showMachineWindow(selected)
        }
    }

    @objc private func startMachine(_ sender: Any?) {
        guard let selected else { return }
        if let unavailable = selected as? UnavailableMac {
            locate(unavailable)
            return
        }
        do {
            try VIMSession.open(selected)
        } catch {
            VIMPresentError(error, window)
        }
        table.reloadData()
    }

    @objc private func machineSettings(_ sender: Any?) {
        guard let selected, !(selected is UnavailableMac), let window else { return }
        MachineSettings.show(for: selected, window: window) { [self] in reloadLibrary() }
    }

    private func locate(_ machine: UnavailableMac) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Locate \(machine.name)"
        alert.informativeText =
            "Mac Unavailable\n\n\(machine.url.path)\n\nReconnect its drive, or choose its current package location. No disks will be copied."
        VIMSetAppAlertIcon(alert)
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [self] response in
            if response == .alertSecondButtonReturn {
                reloadLibrary()
            } else if response == .alertFirstButtonReturn {
                chooseLocation(of: machine, window: window)
            }
        }
    }

    private func chooseLocation(of machine: UnavailableMac, window: NSWindow) {
        let panel = packagePanel()
        panel.beginSheetModal(for: window) { [self] choice in
            guard choice == .OK, let url = panel.url else { return }
            do {
                _ = try VIMMachine.load(url)
            } catch {
                VIMPresentError(error, window)
                return
            }
            var known = defaults.dictionary(forKey: catalogKey) ?? [:]
            known[machine.url.path] = nil
            defaults.set(known, forKey: catalogKey)
            var registered = defaults.array(forKey: registeredPackagesKey) as? [String] ?? []
            registered.removeAll { $0 == machine.url.path }
            defaults.set(registered, forKey: registeredPackagesKey)
            registerPackageURL(url)
        }
    }

    @objc private func renameMachine(_ sender: Any?) {
        guard let machine = selected, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Mac"
        VIMSetAppAlertIcon(alert)
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        name.stringValue = machine.name
        alert.accessoryView = name
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try machine.rename(name.stringValue)
            } catch {
                VIMPresentError(error, window)
            }
            reloadLibrary()
        }
    }

    @objc func removeSelectedMachine(_ sender: Any?) {
        guard let machine = selected, !VIMSession.isRunning(machine) else { return }
        let missing = machine is UnavailableMac
        let alert = NSAlert()
        alert.messageText = missing ? "Remove “\(machine.name)” from the library?" : "Move “\(machine.name)” to Trash?"
        alert.informativeText =
            missing
            ? "The missing Mac will be removed from this library. No files will be deleted."
            : "This virtual Mac and its disk will be moved to Trash. You can restore the package from Trash later."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: missing ? "Remove" : "Move to Trash")
        VIMPresentAlert(alert, window) { [self] response in
            guard response == .alertSecondButtonReturn else { return }
            if missing {
                forget(machine)
            } else {
                moveToTrash(machine)
            }
        }
    }

    private func forget(_ machine: VIMMachine) {
        var known = defaults.dictionary(forKey: catalogKey) ?? [:]
        known[machine.url.path] = nil
        defaults.set(known, forKey: catalogKey)
        for key in [registeredPackagesKey, orderKey] {
            guard var paths = defaults.array(forKey: key) as? [String] else { continue }
            paths.removeAll { $0 == machine.url.path }
            defaults.set(paths, forKey: key)
        }
        reloadLibrary()
    }

    /// Checks again after the confirmation sheet: another window or process could have started or renamed the machine
    /// while the decision was pending.
    private func moveToTrash(_ machine: VIMMachine) {
        let lockPath = machine.url.appendingPathComponent("State/Session.lock").path
        let lock = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var info = stat()
        guard lock >= 0, fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
            flock(lock, LOCK_EX | LOCK_NB) == 0
        else {
            if lock >= 0 { close(lock) }
            let busy = NSAlert()
            busy.messageText = "This Mac can’t be deleted right now"
            busy.informativeText =
                "Shut down the virtual Mac and close any other Light Click session using it, then try again."
            busy.addButton(withTitle: "OK")
            VIMPresentAlert(busy, window, nil)
            return
        }
        let current = try? VIMMachine.load(machine.url)
        guard let identifier = current?.configuration["Identifier"] as? NSObject,
            identifier.isEqual(machine.configuration["Identifier"])
        else {
            close(lock)
            reloadLibrary()
            return
        }
        NSWorkspace.shared.recycle([machine.url]) { @Sendable [self] _, error in
            close(lock)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        VIMPresentError(error, self.window)
                    } else {
                        self.forget(machine)
                    }
                }
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(removeSelectedMachine(_:)) else { return true }
        guard let selected else { return false }
        return !VIMSession.isRunning(selected)
    }
}
