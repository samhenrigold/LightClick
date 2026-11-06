import AppKit
import InstallerKit
import MachineKit

/// "Create Virtual Mac": the version chooser.
final class ChoicesPage: AssistantPage {
    var onSelect: ((Guest) -> Void)?
    var onContinue: (() -> Void)?

    private var rows: [SystemOption] = []
    private let newerSystemsPopover = NSPopover()

    /// `chooseButton` is the assistant's, as it stays disabled across pages while an installer is being inspected.
    init(selection: Guest, chooseButton: NSButton) {
        super.init(frame: NSRect(origin: .zero, size: assistantSize))
        let title = assistantText("Create Virtual Mac", size: 27, weight: .semibold)
        let appIcon = NSImageView()
        appIcon.image = NSApp.applicationIconImage
        appIcon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let heading = NSStackView(views: [appIcon, title])
        heading.spacing = 12
        addAssistantSubview(heading)
        let intro = assistantText("", size: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 5
        intro.attributedStringValue = NSAttributedString(
            string: "Choose a version to run the Intel or PowerPC apps you love and revisit classic Mac designs. Every "
                + "version supports graphics acceleration.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13), .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor
            ])
        addAssistantSubview(intro)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 25),
            heading.centerXAnchor.constraint(equalTo: centerXAnchor),
            intro.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 5),
            intro.centerXAnchor.constraint(equalTo: centerXAnchor),
            intro.widthAnchor.constraint(equalToConstant: 450)
        ])

        rows = Guest.allCases.enumerated().map { index, guest in
            let row = makeRow(title: guest.systemName, imageName: guest.rawValue + "Icon", tag: index)
            row.action = #selector(rowSelected)
            row.setButtonType(.radio)
            row.state = guest == selection ? .on : .off
            row.onDoubleClick = { [weak self] in self?.onContinue?() }
            return row
        }
        let newer = makeRow(title: "macOS Monterey 12 or later", imageName: "montereyIcon", tag: rows.count)
        newer.action = #selector(toggleNewerSystems)
        newer.isRecommendation = true
        rows.append(newer)

        // The drawing's icon and title inset, with a little trailing room. Equal columns fit the longest actual label
        // rather than spreading short names across nearly the whole window.
        let width =
            rows.map {
                ceil(($0.title as NSString).size(withAttributes: [.font: SystemOption.titleFont]).width) + 84
            }.max() ?? 0
        for row in rows { row.widthAnchor.constraint(equalToConstant: width).isActive = true }
        let lines = (0..<GuestGrid.rowsPerColumn).map { index in
            let line = NSStackView(views: [rows[index], rows[index + GuestGrid.rowsPerColumn]])
            line.spacing = 16
            line.alignment = .centerY
            return line
        }
        let stack = NSStackView(views: lines)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        addAssistantSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 20)
        ])
        let next = NSButton(title: "Continue", target: self, action: #selector(continueTapped))
        next.keyEquivalent = "\r"
        addFooter(leading: chooseButton, trailing: [next])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusSelection(_ guest: Guest) {
        window?.makeFirstResponder(rows[Guest.allCases.firstIndex(of: guest) ?? 0])
    }

    func select(_ guest: Guest) {
        newerSystemsPopover.close()
        for (row, candidate) in zip(rows, Guest.allCases) { row.state = candidate == guest ? .on : .off }
    }

    private func makeRow(title: String, imageName: String, tag: Int) -> SystemOption {
        let row = SystemOption()
        row.title = title
        row.target = self
        row.tag = tag
        row.roundel = NSImage(named: imageName)
        row.isBordered = false
        row.focusRingType = .none
        row.setAccessibilityLabel(title)
        row.heightAnchor.constraint(equalToConstant: 46).isActive = true
        row.onMove = { [weak self] move in self?.move(move, from: tag) }
        return row
    }

    private func move(_ move: GuestGrid.Move, from index: Int) {
        let target = GuestGrid.index(moving: move, from: index, count: rows.count)
        if target != index { rows[target].performClick(nil) }
        window?.makeFirstResponder(rows[target])
    }

    @objc private func rowSelected(_ sender: SystemOption) {
        onSelect?(Guest.allCases[sender.tag])
    }

    @objc private func continueTapped() {
        onContinue?()
    }

    @objc private func toggleNewerSystems(_ sender: NSButton) {
        if newerSystemsPopover.isShown {
            newerSystemsPopover.close()
            return
        }
        let width: CGFloat = 350
        let body = RecommendationParagraph(frame: NSRect(x: 18, y: 16, width: width, height: 200))
        body.isEditable = false
        body.isSelectable = false
        body.drawsBackground = false
        body.textContainerInset = .zero
        body.textContainer?.lineFragmentPadding = 0
        body.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        body.textStorage?.setAttributedString(Self.recommendationText())
        var height: CGFloat = 0
        if let layoutManager = body.layoutManager, let container = body.textContainer {
            layoutManager.ensureLayout(for: container)
            height = ceil(layoutManager.usedRect(for: container).height)
        }
        body.frame = NSRect(x: 18, y: 16, width: width, height: height)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: width + 36, height: height + 32))
        controller.view.addSubview(body)
        controller.preferredContentSize = controller.view.frame.size
        newerSystemsPopover.behavior = .transient
        newerSystemsPopover.contentViewController = controller
        newerSystemsPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private static func recommendationText() -> NSAttributedString {
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0)
        let recommendation = NewerSystemsRecommendation(appleSilicon: arm != 0)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]
        let text = NSMutableAttributedString(string: recommendation.opening, attributes: attributes)
        func append(_ string: String) { text.append(NSAttributedString(string: string, attributes: attributes)) }
        for (index, app) in recommendation.apps.enumerated() {
            append(recommendation.separator(before: index))
            let icon = NSTextAttachment()
            icon.image = NSImage(named: app.imageName)
            icon.bounds = NSRect(x: 0, y: -3, width: 18, height: 18)
            text.append(NSAttributedString(attachment: icon))
            // Attachments otherwise create an independent Unicode line-break opportunity: keep the icon with the app's
            // first word.
            append("\u{2060}\u{00a0}\u{2060}")
            let start = text.length
            append(app.name)
            append("\u{2060}")
            // The symbol is an inline part of the same underlined link: no button padding or gap before the arrow.
            let arrow = NSTextAttachment()
            arrow.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Opens website")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(hierarchicalColor: .linkColor))
            arrow.bounds = NSRect(x: 1, y: 0, width: 10, height: 10)
            text.append(NSAttributedString(attachment: arrow))
            text.addAttributes(
                [
                    .link: app.url, .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: NSRange(location: start, length: text.length - start))
        }
        append(recommendation.closing)
        return text
    }
}
