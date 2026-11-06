import AppKit
import MachineKit

/// A flipped page, optionally with the window's own background.
final class ConfigurationDocument: NSView {
    var drawsWindowBackground = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard drawsWindowBackground else { return }
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// A native editor sheet. Retained by the window until it's dismissed; a failed save keeps it open, so nothing typed is
/// lost.
final class ConfigurationSheet: NSWindowController {
    /// Saves, and says whether the sheet can close.
    var save: ((NSWindow) -> Bool)?

    init(title: String, content: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180), styleMask: .titled, backing: .buffered,
            defer: false)
        super.init(window: window)
        window.title = title
        window.isReleasedWhenClosed = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "OK", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 12
        for button in [cancel, save] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        }
        guard let root = window.contentView else { return }
        for view in [content, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            buttons.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        window.setContentSize(
            NSSize(width: max(420, content.fittingSize.width + 48), height: content.fittingSize.height + 84))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func cancelTapped() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
    }

    @objc private func saveTapped() {
        guard let window, save?(window) ?? true else { return }
        window.sheetParent?.endSheet(window)
    }
}

/// Each table owns its immutable rows: AppKit can finish laying out an outgoing table during a section switch.
final class ConfigurationSidebar: NSTableView {
    var categories: [SettingsCategory] = []
}

/// All the categories fit, so this isn't scrollable content.
final class FixedSidebarClip: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin = .zero
        return bounds
    }
}

final class FixedSidebarScroll: NSScrollView {
    override func scrollWheel(with event: NSEvent) {}
}

@MainActor func settingsText(_ text: String, heading: Bool = false) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.isSelectable = false
    label.font = .systemFont(ofSize: 13, weight: heading ? .semibold : .regular)
    label.textColor = heading ? .labelColor : .secondaryLabelColor
    return label
}

@MainActor func settingsColumn(_ views: [NSView], spacing: CGFloat = 16) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    return stack
}

@MainActor func settingsGrid(
    _ rows: [[NSView]], columnSpacing: CGFloat = 12, rowSpacing: CGFloat? = nil
) -> NSGridView {
    let grid = NSGridView(views: rows)
    grid.columnSpacing = columnSpacing
    if let rowSpacing { grid.rowSpacing = rowSpacing }
    grid.column(at: 0).xPlacement = .trailing
    return grid
}

/// A pane on a Sharing tab. Its padding is in the document, so the last line and its margin can scroll fully into view.
@MainActor func sharingScrollPane(_ pane: NSView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.verticalScrollElasticity = .none
    scroll.horizontalScrollElasticity = .none
    let document = ConfigurationDocument()
    document.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = document
    pane.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(pane)
    let fit = document.heightAnchor.constraint(equalTo: pane.heightAnchor, constant: 40)
    fit.priority = .defaultHigh
    NSLayoutConstraint.activate([
        document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor), fit,
        pane.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
        pane.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
        pane.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
        pane.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -20)
    ])
    for case let label as NSTextField in pane.subviews where !label.isEditable {
        label.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
    }
    return scroll
}

/// Lines captions up with the text of the controls beside them, in every form inside `view`.
@MainActor func alignFormBaselines(in view: NSView) {
    if let grid = view as? NSGridView {
        grid.rowAlignment = .firstBaseline
        for row in 0..<grid.numberOfRows {
            let value = grid.cell(atColumnIndex: 1, rowIndex: row).contentView
            if value is NSStackView || value is NSScrollView { grid.row(at: row).yPlacement = .top }
        }
    }
    for child in view.subviews { alignFormBaselines(in: child) }
}
