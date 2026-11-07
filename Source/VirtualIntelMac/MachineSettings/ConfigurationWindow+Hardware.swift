import AppKit
import InstallerKit
import MachineKit

extension ConfigurationWindow {
    func makeHardwarePage() -> NSView {
        switch category {
        case .graphics: makeGraphicsPage()
        case .mouseAndKeyboard: makeInputPage()
        case .network: makeNetworkPage()
        case .sound: makeSoundPage()
        case .hardDisk: makeHardDiskPage()
        case .opticalDrive: makeOpticalPage()
        default: makeProcessorPage()
        }
    }

    // MARK: - CPU & Memory

    private func makeProcessorPage() -> NSView {
        let limits = hardwareLimits
        let cpu = NSPopUpButton()
        cpu.identifier = NSUserInterfaceItemIdentifier("CPUCount")
        cpu.target = self
        cpu.action = #selector(processorsChanged)
        let choices = limits.processorChoices(saved: (editable["CPUCount"] as? NSNumber)?.intValue ?? 0)
        cpu.addItems(withTitles: choices.titles)
        for (item, count) in zip(cpu.itemArray, choices.counts) { item.tag = count }
        cpu.selectItem(at: choices.selectedIndex)
        cpu.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let memory = NSTextField(string: (editable["MemoryMiB"] as? NSNumber)?.stringValue ?? "")
        memory.identifier = NSUserInterfaceItemIdentifier("MemoryMiB")
        memory.delegate = self
        memory.widthAnchor.constraint(equalToConstant: 90).isActive = true
        memoryField = memory
        let stepper = NSStepper()
        stepper.minValue = 1024
        stepper.maxValue = Double(limits.maximumMemoryMiB)
        stepper.increment = 1024
        stepper.valueWraps = false
        stepper.doubleValue = memory.doubleValue
        stepper.target = self
        stepper.action = #selector(memoryStepped)
        memoryStepper = stepper
        let memoryRow = NSStackView(views: [memory, NSTextField(labelWithString: "MB"), stepper])
        memoryRow.spacing = 4

        let maximum = limits.memorySliderMaximumGiB
        let slider = NSSlider(
            value: memory.doubleValue / 1024, minValue: 1, maxValue: Double(maximum), target: self,
            action: #selector(memorySlid))
        slider.isContinuous = false
        slider.numberOfTickMarks = maximum
        slider.allowsTickMarkValuesOnly = true
        slider.setAccessibilityLabel("Memory allocation in gigabytes")
        slider.widthAnchor.constraint(equalToConstant: 280).isActive = true
        memorySlider = slider
        let low = settingsText("1 GB")
        let middle = settingsText("\(limits.memorySliderMiddleGiB) GB")
        let high = settingsText("\(maximum) GB")
        middle.alignment = .center
        high.alignment = .right
        let ticks = NSStackView(views: [low, middle, high])
        ticks.distribution = .fillEqually
        ticks.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let memoryColumn = settingsColumn([memoryRow, slider, ticks], spacing: 10)
        let grid = settingsGrid(
            [
                [NSTextField(labelWithString: "Processors:"), cpu],
                [NSTextField(labelWithString: "Memory:"), memoryColumn]
            ] + engineRows(), rowSpacing: 22)
        grid.column(at: 1).xPlacement = .leading
        grid.row(at: 1).yPlacement = .top
        return settingsColumn([
            grid, settingsText(limits.summary),
            settingsText("Changes take effect the next time this virtual Mac starts.")
        ])
    }

    @objc private func processorsChanged(_ sender: NSPopUpButton) {
        guard commit(["CPUCount": sender.selectedTag()]) else { return }
        // The engine's rows depend on the count. Finish any memory being typed first, as a render would discard it.
        window?.makeFirstResponder(nil)
        if !invalidField { render() }
    }

    private static let runtimeHasEngine = EngineAvailability.runtimeHasEngine(
        packaging: (Bundle.main.resourceURL?.appendingPathComponent("Runtime/Packaging.plist")).flatMap {
            try? Data(contentsOf: $0)
        })

    /// Nothing on Intel, where the engine doesn't exist, or for a guest it would never run.
    private func engineRows() -> [[NSView]] {
        #if arch(arm64)
            guard EngineAvailability.isOffered(for: (editable["Guest"] as? String).flatMap(Guest.init(rawValue:)))
            else { return [] }
            let reason = EngineAvailability.unavailableReason(
                runtimeHasEngine: Self.runtimeHasEngine,
                processors: (editable["CPUCount"] as? NSNumber)?.intValue ?? 0)
            let hypervisor = reason == nil && editable["ExecutionEngine"] as? String == "on"
            let engine = NSPopUpButton()
            engine.addItems(withTitles: ["Software (TCG)", "Hypervisor"])
            engine.selectItem(at: hypervisor ? 1 : 0)
            engine.isEnabled = reason == nil
            engine.target = self
            engine.action = #selector(engineChanged)
            engine.toolTip =
                "Hypervisor runs the virtual Mac’s 64-bit code in a translator inside a virtual machine, which is faster. "
                + "Software (TCG) emulates every instruction."
            engine.widthAnchor.constraint(equalToConstant: 170).isActive = true
            let meltdown = NSButton(
                checkboxWithTitle: "Protect against Meltdown", target: self,
                action: #selector(meltdownProtectionChanged))
            meltdown.state = editable["MeltdownProtection"] as? String == "on" ? .on : .off
            meltdown.isEnabled = hypervisor
            meltdown.toolTip =
                "On keeps the page table switch macOS makes at every system call. Off skips it in the Hypervisor engine: "
                + "system calls are faster, and the virtual Mac loses its Meltdown protection. Versions of macOS without "
                + "this protection aren’t affected."
            var rows: [[NSView]] = [
                [NSTextField(labelWithString: "Engine:"), engine], [NSGridCell.emptyContentView, meltdown]
            ]
            if let reason {
                let note = settingsText(reason)
                note.widthAnchor.constraint(equalToConstant: 280).isActive = true
                rows.append([NSGridCell.emptyContentView, note])
            }
            return rows
        #else
            return []
        #endif
    }

    @objc private func engineChanged(_ sender: NSPopUpButton) {
        guard commit(["ExecutionEngine": sender.indexOfSelectedItem == 1 ? "on" : "off"]) else { return }
        window?.makeFirstResponder(nil)
        if !invalidField { render() }
    }

    @objc private func meltdownProtectionChanged(_ sender: NSButton) {
        commit(["MeltdownProtection": sender.state == .on ? "on" : "off"])
    }

    @objc private func memoryStepped(_ sender: NSStepper) {
        memoryField?.integerValue = sender.integerValue
        memorySlider?.doubleValue = sender.doubleValue / 1024
        commit(["MemoryMiB": sender.integerValue])
    }

    @objc private func memorySlid(_ sender: NSSlider) {
        let value = hardwareLimits.memoryMiB(fromSliderGiB: sender.doubleValue)
        memoryField?.integerValue = value
        memoryStepper?.integerValue = value
        commit(["MemoryMiB": value])
    }

    // MARK: - Graphics

    private func makeGraphicsPage() -> NSView {
        let supportsRetina = VIMGuestSupportsRetinaDisplay(editable)
        let current = VIMDisplayMode(editable)
        var firstOption: NSButton?
        let views: [NSView] = DisplayResolutionChoice.available(supportsRetina: supportsRetina).map { choice in
            let option = NSButton(
                radioButtonWithTitle: choice.title, target: self, action: #selector(resolutionChanged))
            option.tag = choice.rawValue
            if firstOption == nil { firstOption = option }
            option.state = choice.mode == current ? .on : .off
            guard let detail = choice.detail(supportsRetina: supportsRetina) else { return option }
            let description = settingsText(detail)
            let pair = NSView()
            for view in [option, description] {
                view.translatesAutoresizingMaskIntoConstraints = false
                pair.addSubview(view)
            }
            NSLayoutConstraint.activate([
                option.topAnchor.constraint(equalTo: pair.topAnchor),
                option.leadingAnchor.constraint(equalTo: pair.leadingAnchor),
                description.leadingAnchor.constraint(equalTo: pair.leadingAnchor, constant: 20),
                description.topAnchor.constraint(equalTo: option.bottomAnchor, constant: 4),
                description.widthAnchor.constraint(equalToConstant: 285),
                description.trailingAnchor.constraint(equalTo: pair.trailingAnchor),
                description.bottomAnchor.constraint(equalTo: pair.bottomAnchor)
            ])
            return pair
        }
        let options = settingsColumn(views, spacing: 18)
        let form = NSView()
        let label = NSTextField(labelWithString: "Resolution:")
        for view in [label, options] {
            view.translatesAutoresizingMaskIntoConstraints = false
            form.addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            options.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            options.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            options.topAnchor.constraint(equalTo: form.topAnchor),
            options.bottomAnchor.constraint(equalTo: form.bottomAnchor)
        ])
        if let firstOption {
            label.firstBaselineAnchor.constraint(equalTo: firstOption.firstBaselineAnchor).isActive = true
        }
        let filter = NSPopUpButton()
        filter.addItems(withTitles: ["Nearest Neighbor", "Linear"])
        filter.selectItem(at: VIMDisplayScalingFilter(editable) == "nearest" ? 0 : 1)
        filter.target = self
        filter.action = #selector(scalingFilterChanged)
        let sampling = settingsGrid([[NSTextField(labelWithString: "Scaling Filter:"), filter]])
        return settingsColumn([
            form, sampling,
            settingsText(
                "Resolution changes take effect the next time this Mac starts. The scaling filter applies immediately.")
        ])
    }

    @objc private func resolutionChanged(_ sender: NSButton) {
        guard let choice = DisplayResolutionChoice(rawValue: sender.tag), commit(choice.settings) else { return }
        render()
    }

    @objc private func scalingFilterChanged(_ sender: NSPopUpButton) {
        if commit(["DisplayScalingFilter": sender.indexOfSelectedItem == 0 ? "nearest" : "linear"]) {
            VIMSession.displayScalingPreferencesChanged(for: machine)
        }
    }

    // MARK: - Mouse & Keyboard

    private func makeInputPage() -> NSView {
        let mode = NSPopUpButton()
        mode.addItem(withTitle: "Automatic")
        mode.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Mouse & Keyboard:"), mode]])
        grid.columnSpacing = 12
        return settingsColumn([
            grid,
            settingsText(
                "Click inside this Mac to use its mouse and Mac keyboard. Press Control–Option to release them.")
        ])
    }

    // MARK: - Network

    private func makeNetworkPage() -> NSView {
        let mode = VIMNetworkMode(editable)
        let source = NSPopUpButton()
        source.target = self
        source.action = #selector(networkChanged)
        source.addItems(withTitles: NetworkSource.titles)
        let connected = (editable["NetworkConnected"] as? NSNumber)?.boolValue
        source.selectItem(at: NetworkSource.selectedIndex(mode: mode, isDisconnected: connected == false))
        source.widthAnchor.constraint(equalToConstant: 270).isActive = true
        var rows: [[NSView]] = [[NSTextField(labelWithString: "Source:"), source]]
        if mode == "bridged" {
            let bridge = NSPopUpButton()
            bridge.target = self
            bridge.action = #selector(bridgeChanged)
            bridge.addItem(withTitle: "Automatic")
            bridge.lastItem?.representedObject = ""
            for interface in VIMNetworkBridgeInterfaces() {
                bridge.addItem(withTitle: interface["Name"] ?? "")
                bridge.lastItem?.representedObject = interface["Identifier"]
            }
            let selected = editable["BridgeInterface"] as? String ?? ""
            if let item = bridge.itemArray.last(where: { $0.representedObject as? String == selected }) {
                bridge.select(item)
            }
            rows.append([NSTextField(labelWithString: "Interface:"), bridge])
        }
        rows.append([NSGridCell.emptyContentView, button("Advanced…", #selector(showNetworkAdvanced))])
        let grid = settingsGrid(rows, rowSpacing: 20)
        grid.column(at: 1).xPlacement = .leading
        return settingsColumn([grid, settingsText(NetworkSource.explanation(mode: mode))])
    }

    @objc private func networkChanged(_ sender: NSPopUpButton) {
        let (mode, connected) = NetworkSource.mode(
            forIndex: sender.indexOfSelectedItem, current: VIMNetworkMode(editable))
        VIMSession.changeNetworkMode(mode, connected: connected, machine: machine, window: window ?? NSWindow()) {
            [self] error in
            if let error { VIMPresentError(error, window) }
            render()
        }
    }

    @objc private func bridgeChanged(_ sender: NSPopUpButton) {
        guard commit(["BridgeInterface": sender.selectedItem?.representedObject as? String ?? ""]) else { return }
        if VIMSession.isRunning(machine) {
            let alert = NSAlert()
            alert.messageText = "Restart to change the bridge interface"
            alert.informativeText = "Your selection is saved for the next start."
            alert.addButton(withTitle: "OK")
            VIMPresentAlert(alert, window, nil)
        }
        render()
    }

    @objc private func showNetworkAdvanced() {
        let mac = NSTextField(string: VIMNetworkMACAddress(editable))
        mac.widthAnchor.constraint(equalToConstant: 175).isActive = true
        let generate = button("Generate", #selector(generateMAC))
        generate.cell?.representedObject = mac
        let macRow = NSStackView(views: [mac, generate])
        macRow.spacing = 12
        macRow.alignment = .firstBaseline
        let type = NSPopUpButton()
        type.addItem(withTitle: "Intel 82545EM Gigabit Ethernet")
        type.toolTip = "QEMU e1000-82545em · PCI 8086:100F"
        let grid = settingsGrid(
            [[NSTextField(labelWithString: "MAC:"), macRow], [NSTextField(labelWithString: "Type:"), type]],
            rowSpacing: 16)
        // A stack's bounds and a popup's bezel aren't text baselines. Align the captions with the actual text.
        for (row, control) in [mac as NSView, type].enumerated() {
            let caption = grid.cell(atColumnIndex: 0, rowIndex: row)
            caption.yPlacement = .none
            if let content = caption.contentView {
                caption.customPlacementConstraints = [
                    content.firstBaselineAnchor.constraint(equalTo: control.firstBaselineAnchor)
                ]
            }
        }
        let sheet = ConfigurationSheet(
            title: "Network — Advanced",
            content: settingsColumn([grid, settingsText("Changes take effect the next time this Mac starts.")]))
        sheet.save = { [weak self] window in
            guard let self else { return true }
            do {
                guard VIMNetworkMACAddressIsValid(mac.stringValue) else {
                    throw NSError(
                        domain: "VirtualIntelMac.Settings", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: SettingsValidation.invalidMACAddressMessage])
                }
                try machine.saveSettings(["MACAddress": mac.stringValue.uppercased()])
            } catch {
                VIMPresentError(error, window)
                return false
            }
            completion?()
            render()
            return true
        }
        present(sheet)
    }

    @objc private func generateMAC(_ sender: NSButton) {
        var generator = SystemRandomNumberGenerator()
        (sender.cell?.representedObject as? NSTextField)?.stringValue = SettingsValidation.randomMACAddress(
            using: &generator)
    }

    // MARK: - Sound

    private func makeSoundPage() -> NSView {
        let grid = settingsGrid(
            [
                [NSTextField(labelWithString: "Sound Output:"), audioPopup(input: false)],
                [NSTextField(labelWithString: "Microphone:"), audioPopup(input: true)]
            ], rowSpacing: 20)
        let hostAccess = button("This Mac’s Access…", #selector(microphoneAccess))
        hostAccess.toolTip = "Allow Light Click to use this Mac’s microphone."
        let access = NSStackView(views: [hostAccess, guestSettingsButton("Virtual Mac’s Access…", pane: "microphone")])
        access.spacing = 8
        return settingsColumn([
            grid, access,
            settingsText(
                "Inside the virtual Mac, also allow access in System Preferences → Security & Privacy → Privacy → "
                    + "Microphone."),
            settingsText("Changes take effect the next time the virtual Mac starts.")
        ])
    }

    private func audioPopup(input: Bool) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier(input ? "AudioInputDevice" : "AudioOutputDevice")
        popup.target = self
        popup.action = #selector(audioChanged)
        popup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        popup.addItem(withTitle: "Default")
        popup.lastItem?.representedObject = "default"
        let selected = VIMAudioSelection(editable, input)
        for device in VIMHostAudioDevices(input) {
            popup.addItem(withTitle: device["Name"] ?? "")
            popup.lastItem?.representedObject = device["UID"]
        }
        var choice = popup.itemArray.last { $0.representedObject as? String == selected }
        if choice == nil, selected != "disabled" {
            popup.addItem(withTitle: "Selected Device (Disconnected)")
            popup.lastItem?.representedObject = selected
            choice = popup.lastItem
        }
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: "Disconnected")
        popup.lastItem?.representedObject = "disabled"
        if selected == "disabled" { choice = popup.lastItem }
        popup.select(choice)
        return popup
    }

    @objc private func audioChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue,
            let value = sender.selectedItem?.representedObject as? String,
            commit(["AudioEnabled": true, key: value])
        else { return }
        render()
    }

    @objc private func microphoneAccess() {
        MachineSettings.requestMicrophoneAccess(from: window)
    }

    // MARK: - Hard Disk

    private func makeHardDiskPage() -> NSView {
        let disk = machine.configuration["Disk"] as? String
        let source = NSPopUpButton()
        source.addItem(withTitle: disk.map { ($0 as NSString).lastPathComponent } ?? "System.qcow2")
        source.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Source:"), source]])
        grid.columnSpacing = 12
        var allocated: Int64?
        if let disk, !disk.isEmpty {
            allocated =
                (try? machine.url.appendingPathComponent(disk).resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey]
                ).totalFileAllocatedSize).flatMap { $0 }.map(Int64.init)
        }
        return settingsColumn([
            grid,
            settingsText(PackageStorage.summary(capacityBytes: machine.diskCapacityBytes, allocatedBytes: allocated)),
            button("Show in Finder", #selector(reveal)),
            settingsText("Disk capacity is set when the Mac is created. The disk grows on demand up to that capacity.")
        ])
    }

    // MARK: - CD/DVD

    private func makeOpticalPage() -> NSView {
        let images = VIMSession.connectedImages(for: machine)
        var rows: [[NSView]] = images.enumerated().map { index, image in
            let source = NSPopUpButton()
            source.target = self
            source.action = #selector(opticalChanged)
            source.tag = (image["Slot"] as? NSNumber)?.intValue ?? 0
            source.addItem(withTitle: ((image["Path"] as? String ?? "") as NSString).lastPathComponent)
            source.selectedItem?.tag = 0
            source.selectedItem?.image = NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: nil)
            source.menu?.addItem(.separator())
            source.addItem(withTitle: "Disconnect")
            source.lastItem?.tag = 2
            source.widthAnchor.constraint(equalToConstant: 280).isActive = true
            return [NSTextField(labelWithString: "Drive \(index + 1):"), source]
        }
        if images.isEmpty {
            let source = NSPopUpButton()
            source.target = self
            source.action = #selector(opticalChanged)
            source.tag = 0
            source.addItem(withTitle: "No Disc")
            source.menu?.addItem(.separator())
            source.addItem(withTitle: "Choose Image…")
            source.lastItem?.tag = 1
            source.widthAnchor.constraint(equalToConstant: 280).isActive = true
            rows.append([NSTextField(labelWithString: "Source:"), source])
        } else if images.count < VIMImageSlotCount {
            rows.append([NSGridCell.emptyContentView, button("Connect Image…", #selector(chooseDisc))])
        }
        return settingsColumn([
            settingsGrid(rows, rowSpacing: 14),
            settingsText(
                "Connect ISO, CDR or supported unencrypted DMG images. Disconnect a drive’s current image before "
                    + "replacing it.")
        ])
    }

    @objc private func opticalChanged(_ sender: NSPopUpButton) {
        let action = sender.selectedItem?.tag ?? 0
        sender.selectItem(at: 0)
        guard let window else { return }
        if action == 1 {
            VIMSession.chooseImage(for: machine, slot: UInt(sender.tag), window: window)
        } else if action == 2 {
            VIMSession.ejectImage(for: machine, slot: UInt(sender.tag), window: window)
        }
    }

    @objc private func chooseDisc() {
        guard let window else { return }
        VIMSession.chooseOpticalMedia(for: machine, window: window)
    }

    // MARK: - Restore Defaults

    @objc func restoreDefaults() {
        guard let category,
            let settings = SettingsDefaults.restored(
                category, supportsRetina: VIMGuestSupportsRetinaDisplay(editable),
                processorCount: ProcessInfo.processInfo.processorCount),
            commit(settings)
        else { return }
        if category == .network {
            VIMSession.changeNetworkMode("shared", connected: true, machine: machine, window: window ?? NSWindow()) {
                [self] error in
                if let error { VIMPresentError(error, window) }
                render()
            }
            return
        }
        if category == .graphics { VIMSession.displayScalingPreferencesChanged(for: machine) }
        render()
    }
}
