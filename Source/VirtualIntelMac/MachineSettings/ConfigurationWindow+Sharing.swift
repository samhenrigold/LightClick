import AppKit
import InstallerKit
import MachineKit

extension ConfigurationWindow {
    private var serviceKeys: (enabled: String, port: String) {
        category == .fileSharing ? ("FileSharingEnabled", "FileSharingPort") : ("SSHEnabled", "SSHPort")
    }

    private var suggestedPorts: [String: NSNumber] {
        VIMSuggestedForwardPorts(machine.url.deletingLastPathComponent(), machine.url)
    }

    func makeSharingPage() -> NSView {
        let tabs = NSTabView()
        tabs.tabViewType = .topTabsBezelBorder
        if category == .clipboard {
            let pane = NSView()
            let enabled = NSButton(
                checkboxWithTitle: "Share copied text and images with this Mac", target: self,
                action: #selector(clipboardToggled))
            enabled.identifier = NSUserInterfaceItemIdentifier("ClipboardEnabled")
            enabled.state = isEnabled("ClipboardEnabled") ? .on : .off
            enabled.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(enabled)
            NSLayoutConstraint.activate([
                enabled.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 24),
                enabled.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
                enabled.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -20)
            ])
            let item = NSTabViewItem(identifier: "guest")
            item.label = "Virtual Mac"
            item.view = pane
            tabs.addTabViewItem(item)
            return tabs
        }
        tabs.identifier = NSUserInterfaceItemIdentifier("SharingDirections")
        tabs.setAccessibilityLabel("Which Mac to connect to")
        for host in [true, false] {
            let item = NSTabViewItem(identifier: host ? "host" : "guest")
            item.label = host ? "This Mac" : "Virtual Mac"
            let pane = host ? makeHostDirections() : makeGuestDirections()
            alignFormBaselines(in: pane)
            item.view = sharingScrollPane(pane)
            tabs.addTabViewItem(item)
        }
        tabs.selectTabViewItem(at: showsHostDirections ? 0 : 1)
        tabs.delegate = self
        return tabs
    }

    func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool {
        window?.makeFirstResponder(nil)
        return !invalidField
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        showsHostDirections = tabViewItem?.identifier as? String == "host"
    }

    /// Absent means on: these features default to enabled.
    private func isEnabled(_ key: String) -> Bool {
        (editable[key] as? NSNumber)?.boolValue ?? true
    }

    private func actions(_ directions: SharingDirections, open action: Selector) -> (NSStackView, open: NSButton) {
        let copy = button(directions.copyTitle, #selector(copyConnection))
        copy.identifier = NSUserInterfaceItemIdentifier(directions.address)
        copy.isEnabled = directions.canCopy
        let open = button(directions.openTitle, action)
        open.identifier = NSUserInterfaceItemIdentifier(directions.openTarget)
        open.isEnabled = directions.canOpen
        let actions = NSStackView(views: [open, copy])
        actions.spacing = 12
        return (actions, open)
    }

    private func makeHostDirections() -> NSView {
        let network = VIMSession.networkDetails(for: machine)
        let service: SharingDirections.Service = category == .fileSharing ? .fileSharing : .remoteLogin
        let directions = SharingDirections.toHost(
            service: service, hostAddress: network["HostAddress"] as? String, hostUser: NSUserName(),
            isPreMetalGuest: machine.preMetalGuest,
            usesWindowsFileSharing: Guest(rawValue: machine.guest)?.traits.contains(.windowsFileSharing) == true,
            isConnected: (network["Connected"] as? NSNumber)?.boolValue == true)
        let (actions, _) = actions(directions, open: #selector(openGuestConnection))
        return settingsColumn([
            settingsText(directions.heading, heading: true), settingsText(directions.firstStep),
            button("Open Sharing Settings", #selector(openSharingSettings)), settingsText(directions.secondStep),
            settingsText(directions.addressLine), actions,
            settingsText("Use this Mac’s account and password, not the virtual Mac’s.")
        ])
    }

    private func makeGuestDirections() -> NSView {
        let network = VIMSession.networkDetails(for: machine)
        let isShared = network["Mode"] as? String == "shared"
        let service: SharingDirections.Service = category == .fileSharing ? .fileSharing : .remoteLogin
        let keys = serviceKeys
        let enabled = isEnabled(keys.enabled)
        let directions = SharingDirections.toGuest(
            service: service, isShared: isShared, port: (editable[keys.port] as? NSNumber) ?? suggestedPorts[keys.port],
            guestAddress: (network["GuestAddresses"] as? [String])?.first, guestUsername: guestUsername,
            smbForwardURL: VIMSMBService.url(for: machine).absoluteString, isPreMetalGuest: machine.preMetalGuest,
            identifier: machine.configuration["Identifier"] as? String ?? "",
            isConnected: (network["Connected"] as? NSNumber)?.boolValue == true, isEnabled: enabled)
        let (actions, _) = actions(directions, open: #selector(openConnection))
        var views: [NSView] = [settingsText(directions.heading, heading: true), settingsText(directions.firstStep)]
        if service == .fileSharing {
            views.append(guestSettingsButton("Open Sharing in Virtual Mac…", pane: "sharing"))
        } else {
            let setUp = button("Set Up Remote Login…", #selector(enableGuestRemoteLogin))
            setUp.isEnabled = VIMSession.isRunning(machine)
            setUp.toolTip = "Uses the built-in guest tools. Start the virtual Mac first."
            views.append(setUp)
            let username = NSTextField(string: guestUsername)
            username.identifier = NSUserInterfaceItemIdentifier("GuestUsername")
            username.delegate = self
            username.widthAnchor.constraint(equalToConstant: 240).isActive = true
            username.placeholderString = "Guest account short name"
            username.setAccessibilityLabel("Guest account short name")
            views.append(username)
        }
        if isShared { actions.addArrangedSubview(button("Advanced…", #selector(showSharingAdvanced))) }
        views += [settingsText(directions.secondStep), settingsText(directions.addressLine), actions]
        if isShared, !enabled {
            views.append(
                settingsText("Local connections are turned off. Enable them in Advanced, then restart this Mac."))
        }
        if !isShared {
            views.append(
                settingsText(
                    "Connect directly using the address above. Service access is controlled by Sharing and Firewall "
                        + "settings inside the virtual Mac; local port forwarding is not used."))
        }
        return settingsColumn(views)
    }

    func guestSettingsButton(_ title: String, pane: String) -> NSButton {
        let settings = button(title, #selector(openGuestSettings))
        settings.identifier = NSUserInterfaceItemIdentifier(pane)
        settings.isEnabled = VIMSession.isRunning(machine)
        settings.toolTip = "Uses the built-in guest tools. Start the virtual Mac and sign in first."
        return settings
    }

    // MARK: - Actions

    @objc private func clipboardToggled(_ sender: NSButton) {
        let prior = isEnabled("ClipboardEnabled")
        // Machine.plist has always held this one as an integer.
        var settings: [String: Any] = ["ClipboardEnabled": sender.state == .on ? 1 : 0]
        let ports = suggestedPorts
        // Saving any of this pins the suggested ports, so they can't shift under a running service.
        for key in ["SSHPort", "FileSharingPort"] where editable[key] == nil { settings[key] = ports[key] }
        do {
            try machine.saveSettings(settings)
        } catch {
            sender.state = prior ? .on : .off
            feedback.stringValue = error.localizedDescription
            return
        }
        VIMSession.clipboardPreferencesChanged(for: machine)
        completion?()
        render()
    }

    @objc private func showSharingAdvanced() {
        window?.makeFirstResponder(nil)
        guard !invalidField else { return }
        let files = category == .fileSharing
        let keys = serviceKeys
        let allowed = NSButton(
            checkboxWithTitle: files ? "Allow connections to shared files" : "Allow SSH connections", target: nil,
            action: nil)
        allowed.state = isEnabled(keys.enabled) ? .on : .off
        let port = (editable[keys.port] as? NSNumber) ?? suggestedPorts[keys.port]
        let field = NSTextField(string: port?.stringValue ?? "")
        field.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let grid = settingsGrid([[NSTextField(labelWithString: "Local port:"), field]])
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).width = 80
        grid.column(at: 1).xPlacement = .leading
        grid.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let explanation = settingsText("Accessible only from this Mac. Changes take effect at the next start.")
        explanation.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let sheet = ConfigurationSheet(
            title: files ? "File Sharing — Advanced" : "Remote Login — Advanced",
            content: settingsColumn([allowed, grid, explanation]))
        sheet.save = { [weak self] window in
            guard let self else { return true }
            do {
                let value = try SettingsValidation.localPort(field.stringValue).get()
                // Machine.plist has always held these as integers here.
                try machine.saveSettings([keys.enabled: allowed.state == .on ? 1 : 0, keys.port: value])
            } catch let issue as SettingsFieldIssue {
                VIMPresentError(
                    NSError(
                        domain: "VirtualIntelMac.Settings", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: issue.message]), window)
                return false
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

    @objc private func copyConnection(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.identifier?.rawValue ?? "", forType: .string)
    }

    @objc private func openConnection(_ sender: NSButton) {
        let target = sender.identifier?.rawValue ?? ""
        if category == .remoteLogin, machine.preMetalGuest {
            openInTerminal(command: target)
            return
        }
        // Finder connects over the machine's network, not the guest-control socket. Let Finder report SMB errors even
        // if guest tools are busy or unavailable.
        if let url = URL(string: target) { NSWorkspace.shared.open(url) }
    }

    private func openInTerminal(command: String) {
        var failure: (any Error)?
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(TerminalConnectionProfile.directory, isDirectory: true)
            let identifier = machine.configuration["Identifier"] as? String ?? ""
            let profile = directory.appendingPathComponent(identifier).appendingPathExtension("terminal")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try (TerminalConnectionProfile.settings(name: machine.name, command: command) as NSDictionary).write(
                to: profile)
            if NSWorkspace.shared.open(profile) { return }
        } catch {
            failure = error
        }
        VIMPresentError(
            failure
                ?? NSError(
                    domain: "VirtualIntelMac.RemoteLogin", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Terminal couldn’t open this connection. Use Copy Command and paste it into Terminal."
                    ]), window)
    }

    @objc private func openGuestConnection(_ sender: NSButton) {
        guard let url = URL(string: sender.identifier?.rawValue ?? "") else { return }
        let title = sender.title
        sender.isEnabled = false
        sender.title = "Opening…"
        VIMSession.openHostConnection(url, in: machine) { [self] error in
            sender.title = title
            sender.isEnabled = true
            if let error { VIMPresentError(error, window) }
        }
    }

    @objc private func openSharingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.sharing") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openGuestSettings(_ sender: NSButton) {
        sender.isEnabled = false
        VIMSession.openGuestPreferences(sender.identifier?.rawValue ?? "", machine: machine) { [self] error in
            sender.isEnabled = VIMSession.isRunning(machine)
            if let error {
                VIMPresentError(error, window)
                return
            }
            VIMSession.showMachineWindow(machine)
        }
    }

    @objc private func enableGuestRemoteLogin(_ sender: NSButton) {
        sender.isEnabled = false
        VIMSession.enableGuestRemoteLogin(machine) { [self] error in
            sender.isEnabled = true
            if let error {
                VIMPresentError(error, window)
                return
            }
            do {
                try machine.saveSettings(["SSHEnabled": true])
            } catch {
                VIMPresentError(error, window)
                return
            }
            render()
            let running = machine.configuration
            let needsRestart =
                (running["SSHEnabled"] as? NSNumber)?.boolValue != true
                || !((running["SSHPort"] as? NSObject)?.isEqual(editable["SSHPort"]) ?? false)
            let alert = NSAlert()
            alert.messageText = "Remote Login is on"
            alert.informativeText = RemoteLoginMessage.enabled(needsRestart: needsRestart)
            alert.addButton(withTitle: "OK")
            VIMPresentAlert(alert, window, nil)
        }
    }
}
