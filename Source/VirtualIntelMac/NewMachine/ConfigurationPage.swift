import AppKit
import InstallerKit
import MachineKit

/// "Configure Your Mac": the form, plus the Advanced sheet with the account's on/off switches. The assistant keeps one of
/// these for its lifetime: its fields are what's being set up.
final class ConfigurationPage: AssistantPage {
    let createButton = NSButton(title: "Create", target: nil, action: nil)
    var onBack: (() -> Void)?
    var onCreate: (() -> Void)?

    private let host: HostCapacity
    private let nameField = NSTextField(string: "")
    private let diskField = NSTextField(string: "")
    private let coresField = NSTextField(string: "")
    private let memoryField = NSTextField(string: "")
    private let coresSlider: NSSlider
    private let memorySlider: NSSlider
    private let automaticSwitch = NSSwitch()
    private let sharingSwitch = NSSwitch()
    private let remoteLoginSwitch = NSSwitch()
    private let automaticLoginSwitch = NSSwitch()
    private let usernameField = NSTextField(string: VIMAutomaticSetup.defaultUsername())
    private let passwordField = NSSecureTextField()
    private let visiblePasswordField = NSTextField()
    private let passwordVisibility = NSButton(
        image: NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Show password") ?? NSImage(),
        target: nil, action: nil)
    private let icon: NSImageView
    private let artwork = InstallerArtwork()
    private let form: NSGridView
    private lazy var automaticSection = makeAutomaticSection()
    private var advancedSheet: NSWindow?
    private var isEditingAdvancedOptions = false

    private var allSwitches: [NSSwitch] { [automaticSwitch, sharingSwitch, remoteLoginSwitch, automaticLoginSwitch] }
    private var activePasswordField: NSTextField {
        visiblePasswordField.isHidden ? passwordField : visiblePasswordField
    }

    init(host: HostCapacity) {
        self.host = host
        coresSlider = NSSlider(value: 1, minValue: 1, maxValue: Double(host.maximumCores), target: nil, action: nil)
        memorySlider = NSSlider(
            value: 1, minValue: 1, maxValue: Double(host.maximumMemoryGiB), target: nil, action: nil)
        let passwordContainer = NSView()
        form = NSGridView(views: [
            [Self.label("Name", symbol: "desktopcomputer"), nameField],
            [Self.label("Username", symbol: "person"), usernameField],
            [Self.label("Password", symbol: "key"), passwordContainer],
            [Self.label("Processors", symbol: "cpu"), Self.row([coresSlider, coresField, "cores"])],
            [Self.label("Memory", symbol: "memorychip"), Self.row([memorySlider, memoryField, "GB"])],
            [Self.label("Storage", symbol: "internaldrive"), Self.row([diskField, "GB"])]
        ])
        let title = assistantText("Configure Your Mac", size: 27, weight: .semibold)
        let (heading, icon, iconHeight) = assistantHeading(title: title, guest: .mojave)
        // Every guest has the account rows, which leaves less room for the icon.
        iconHeight.constant = 40
        self.icon = icon
        super.init(frame: NSRect(origin: .zero, size: assistantSize))

        form.rowSpacing = 10
        form.columnSpacing = 14
        form.column(at: 0).xPlacement = .leading
        configureFields()
        configurePasswordFields(in: passwordContainer)
        let intro = assistantText(
            "Start with the recommended settings, or make room for the apps you want to run.", size: 14)
        let storage = assistantText(
            "Storage size can’t be changed later. If you need additional storage in the future, set a larger size now.",
            size: 12)
        storage.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, intro, form, storage])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        addAssistantSubview(stack)
        for view in [heading, intro, storage] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 432),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -35),
            nameField.widthAnchor.constraint(equalToConstant: 240)
        ])
        addArtwork(artwork)
        let backButton = NSButton(title: "Go Back", target: self, action: #selector(back))
        let advanced = NSButton(title: "Advanced…", target: self, action: #selector(showAdvancedOptions))
        createButton.target = self
        createButton.action = #selector(create)
        createButton.keyEquivalent = "\r"
        addFooter(leading: advanced, trailing: [backButton, createButton])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Reading and filling

    var values: NewMachineForm {
        get {
            NewMachineForm(
                name: nameField.stringValue, cores: coresField.stringValue, memory: memoryField.stringValue,
                disk: diskField.stringValue)
        }
        set {
            nameField.stringValue = newValue.name
            coresField.stringValue = newValue.cores
            memoryField.stringValue = newValue.memory
            diskField.stringValue = newValue.disk
        }
    }

    var name: String {
        get { nameField.stringValue }
        set { nameField.stringValue = newValue }
    }

    var isAutomaticSetupOn: Bool { automaticSwitch.state == .on }
    var username: String { usernameField.stringValue }
    var password: String { activePasswordField.stringValue }

    func setAccount(name: String?, password: String) {
        if let name { usernameField.stringValue = name }
        passwordField.stringValue = password
    }

    func automaticSetupProfile(identifier: String) -> AutomaticSetupProfile {
        AutomaticSetupProfile(
            username: username, fileSharing: sharingSwitch.state == .on, remoteLogin: remoteLoginSwitch.state == .on,
            automaticLogin: automaticLoginSwitch.state == .on, credentialIdentifier: identifier)
    }

    /// Shows `guest`'s pictures, and its name unless the user typed one.
    func show(_ guest: Guest) {
        automaticSetupChanged()
        artwork.wallpaper = NSImage(named: guest.rawValue + "Wallpaper")
        icon.image = NSImage(named: guest.rawValue + "Icon")
        name = NewMachineDefaults.name(name, afterSwitchingTo: guest)
    }

    func reset(to defaults: NewMachineDefaults) {
        values = NewMachineForm(
            name: defaults.name, cores: String(defaults.cores), memory: String(defaults.memoryGiB),
            disk: String(defaults.diskGiB))
        syncSliders()
        for control in allSwitches { control.state = .on }
        usernameField.stringValue = VIMAutomaticSetup.defaultUsername()
        passwordField.stringValue = ""
        visiblePasswordField.stringValue = ""
        if !visiblePasswordField.isHidden { togglePassword() }
    }

    /// Fills the page from a saved job. Its password comes separately, from wherever `VIMAutomaticSetup` keeps it.
    func restore(_ job: CreationJob, password: String?) {
        values = NewMachineForm(
            name: job.name ?? "Mac", cores: job.cores.map(String.init) ?? "4",
            memory: job.memoryGiB.map(String.init) ?? "4", disk: job.diskGiB.map(String.init) ?? "64")
        if let profile = job.automaticSetup {
            automaticSwitch.state = profile.isEnabled ? .on : .off
            usernameField.stringValue = profile.username ?? VIMAutomaticSetup.defaultUsername()
            sharingSwitch.state = profile.fileSharing ? .on : .off
            remoteLoginSwitch.state = profile.remoteLogin ? .on : .off
            automaticLoginSwitch.state = profile.automaticLogin == true ? .on : .off
            passwordField.stringValue = password ?? ""
        } else {
            // A job only loses its profile when someone turned Automatic Setup off.
            automaticSwitch.state = .off
        }
        automaticSetupChanged()
    }

    func syncSliders() {
        memorySlider.doubleValue = memoryField.doubleValue
        coresSlider.doubleValue = coresField.doubleValue
    }

    /// While a disk is being made.
    func setEditable(_ editable: Bool) {
        createButton.isEnabled = editable
        nameField.isEnabled = editable
        diskField.isEnabled = editable
    }

    // MARK: - Focus

    func focusEditor() {
        layoutSubtreeIfNeeded()
        window?.recalculateKeyViewLoop()
        let password = activePasswordField
        window?.makeFirstResponder(form.row(at: 2).isHidden || !password.isEnabled ? nameField : password)
    }

    func focusPassword() {
        window?.makeFirstResponder(activePasswordField)
    }

    // MARK: - Actions

    @objc private func back() { onBack?() }
    @objc private func create() { onCreate?() }

    @objc private func memorySliderChanged(_ sender: NSSlider) {
        memoryField.integerValue = Int(sender.doubleValue.rounded())
        sender.doubleValue = Double(memoryField.integerValue)
    }

    @objc private func coresSliderChanged(_ sender: NSSlider) {
        coresField.integerValue = Int(sender.doubleValue.rounded())
        sender.doubleValue = Double(coresField.integerValue)
    }

    @objc private func memoryFieldChanged() { memorySlider.doubleValue = memoryField.doubleValue }
    @objc private func coresFieldChanged() { coresSlider.doubleValue = coresField.doubleValue }

    @objc private func automaticSetupChanged() {
        let enabled = isAutomaticSetupOn
        let controls: [NSControl] = [
            usernameField, passwordField, visiblePasswordField, passwordVisibility, sharingSwitch, remoteLoginSwitch,
            automaticLoginSwitch
        ]
        for control in controls { control.isEnabled = enabled }
        guard !isEditingAdvancedOptions else { return }
        // Collapse the rows and keep their labels and editors in step with them.
        for row in 1...2 {
            form.row(at: row).isHidden = !enabled
            for column in 0..<2 { form.cell(atColumnIndex: column, rowIndex: row).contentView?.isHidden = !enabled }
        }
    }

    @objc private func togglePassword() {
        let show = visiblePasswordField.isHidden
        if show {
            visiblePasswordField.stringValue = passwordField.stringValue
        } else {
            passwordField.stringValue = visiblePasswordField.stringValue
        }
        visiblePasswordField.isHidden = !show
        passwordField.isHidden = show
        let description = show ? "Hide password" : "Show password"
        passwordVisibility.image = NSImage(
            systemSymbolName: show ? "eye" : "eye.slash", accessibilityDescription: description)
        passwordVisibility.setAccessibilityLabel(description)
        passwordVisibility.toolTip = description
        window?.recalculateKeyViewLoop()
        window?.makeFirstResponder(activePasswordField)
    }

    @objc private func showAdvancedOptions() {
        guard let window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(nil)
        let saved = allSwitches.map(\.state)
        let sheet = advancedSheet ?? makeAdvancedSheet()
        advancedSheet = sheet
        isEditingAdvancedOptions = true
        window.beginSheet(sheet) { [weak self] response in
            guard let self else { return }
            if response != .OK {
                for (control, state) in zip(allSwitches, saved) { control.state = state }
            }
            isEditingAdvancedOptions = false
            automaticSetupChanged()
            focusEditor()
        }
    }

    @objc private func finishAdvancedOptions(_ sender: NSButton) {
        guard let advancedSheet else { return }
        window?.endSheet(advancedSheet, returnCode: sender.tag == 1 ? .OK : .cancel)
    }

    // MARK: - Building

    private func configureFields() {
        for field in [coresField, memoryField, diskField] {
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
            field.alignment = .right
        }
        memorySlider.target = self
        memorySlider.action = #selector(memorySliderChanged)
        memorySlider.numberOfTickMarks = Int(memorySlider.maxValue)
        memorySlider.allowsTickMarkValuesOnly = true
        memorySlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        memorySlider.setAccessibilityLabel("Memory in gigabytes")
        memoryField.target = self
        memoryField.action = #selector(memoryFieldChanged)
        coresSlider.target = self
        coresSlider.action = #selector(coresSliderChanged)
        coresSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        coresSlider.setAccessibilityLabel("Number of processors")
        coresField.target = self
        coresField.action = #selector(coresFieldChanged)
        for control in allSwitches { control.state = .on }
        automaticSwitch.controlSize = .regular
        automaticSwitch.target = self
        automaticSwitch.action = #selector(automaticSetupChanged)
        automaticSwitch.setAccessibilityLabel("Automatic Setup")
        sharingSwitch.controlSize = .small
        sharingSwitch.setAccessibilityLabel("Enable File Sharing")
        remoteLoginSwitch.controlSize = .small
        remoteLoginSwitch.setAccessibilityLabel("Enable Remote Login")
        automaticLoginSwitch.controlSize = .small
        automaticLoginSwitch.setAccessibilityLabel("Automatic Login")
        automaticLoginSwitch.toolTip =
            "Sign in to this virtual Mac automatically after it starts. Its password is stored by the guest’s standard "
            + "automatic-login service."
        usernameField.setAccessibilityLabel("Guest account name")
        usernameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        usernameField.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func configurePasswordFields(in container: NSView) {
        passwordField.cell = SecurePasswordCell(textCell: "")
        passwordField.setAccessibilityLabel("Guest password")
        visiblePasswordField.cell = PasswordCell(textCell: "")
        visiblePasswordField.setAccessibilityLabel("Guest password, visible")
        visiblePasswordField.isHidden = true
        container.widthAnchor.constraint(equalToConstant: 240).isActive = true
        container.heightAnchor.constraint(equalToConstant: 22).isActive = true
        for field in [passwordField, visiblePasswordField] {
            field.isBordered = true
            field.isBezeled = true
            field.isEditable = true
            // This creates a guest account, not a login to a host app or website. Keep native secure entry without
            // offering the host's saved passwords.
            if field.responds(to: #selector(NSTextField._setPasswordAutofillEnabled(_:))) {
                field._setPasswordAutofillEnabled(false)
            }
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.focusRingType = .exterior
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.textColor = .textColor
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            field.cell?.usesSingleLineMode = true
            container.addAssistantSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                field.topAnchor.constraint(equalTo: container.topAnchor),
                field.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        passwordVisibility.target = self
        passwordVisibility.action = #selector(togglePassword)
        passwordVisibility.isBordered = false
        passwordVisibility.controlSize = .small
        passwordVisibility.contentTintColor = .secondaryLabelColor
        passwordVisibility.toolTip = "Show password"
        passwordVisibility.setAccessibilityLabel("Show password")
        container.addAssistantSubview(passwordVisibility)
        NSLayoutConstraint.activate([
            passwordVisibility.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            passwordVisibility.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            passwordVisibility.widthAnchor.constraint(equalToConstant: 20),
            passwordVisibility.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    private func makeAutomaticSection() -> NSStackView {
        let headingTitle = Self.label("Automatic Setup", symbol: "wand.and.stars")
        (headingTitle.arrangedSubviews.last as? NSTextField)?.font = .systemFont(ofSize: 17, weight: .semibold)
        let heading = Self.spacedRow(headingTitle, automaticSwitch)
        let explanation = assistantText(
            "Install the operating system and create your account automatically. Turn this off to complete "
                + "installation and account setup yourself.", size: 13)
        explanation.textColor = .secondaryLabelColor
        let divider = NSBox()
        divider.boxType = .separator
        let rows = [
            Self.spacedRow(Self.label("File Sharing", symbol: "folder"), sharingSwitch),
            Self.spacedRow(Self.label("Remote Login", symbol: "terminal"), remoteLoginSwitch),
            Self.spacedRow(Self.label("Automatic Login", symbol: "person.crop.circle"), automaticLoginSwitch)
        ]
        let options = NSStackView(views: rows)
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 18
        for row in rows { row.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true }
        let section = NSStackView(views: [heading, explanation, divider, options])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 14
        for row in [heading, explanation, divider, options] {
            row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return section
    }

    private func makeAdvancedSheet() -> NSWindow {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320), styleMask: .titled, backing: .buffered,
            defer: false)
        sheet.title = "Advanced Setup"
        sheet.isReleasedWhenClosed = false
        guard let page = sheet.contentView else { return sheet }
        let section = automaticSection
        page.addAssistantSubview(section)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(finishAdvancedOptions))
        cancel.tag = 0
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: "OK", target: self, action: #selector(finishAdvancedOptions))
        done.tag = 1
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, done])
        buttons.spacing = 12
        page.addAssistantSubview(buttons)
        for button in [cancel, done] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        }
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 24),
            section.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -24),
            section.topAnchor.constraint(equalTo: page.topAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -20)
        ])
        return sheet
    }

    private static func label(_ title: String, symbol: String) -> NSStackView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let label = NSStackView(views: [icon, NSTextField(labelWithString: title)])
        label.spacing = 8
        return label
    }

    /// Controls, with a string standing for its unit label.
    private static func row(_ items: [Any]) -> NSStackView {
        let row = NSStackView(views: items.map { ($0 as? NSView) ?? NSTextField(labelWithString: $0 as? String ?? "") })
        row.spacing = 8
        return row
    }

    private static func spacedRow(_ leading: NSView, _ trailing: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [leading, spacer, trailing])
        row.spacing = 12
        row.alignment = .centerY
        return row
    }
}
