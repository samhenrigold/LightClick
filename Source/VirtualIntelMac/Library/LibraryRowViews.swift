import AppKit

/// A recovery row, deliberately not a partly valid machine.
final class UnavailableMac: VIMMachine, @unchecked Sendable {
    private let missingURL: URL
    private let savedName: String
    private let savedGuest: String

    init(url: URL, name: String, guest: String) {
        missingURL = url
        savedName = name
        savedGuest = guest
        super.init()
    }

    override var url: URL { missingURL }
    override var name: String { savedName }
    override var guest: String { savedGuest }
    override var configuration: [AnyHashable: Any] { [:] }
    override var editableConfiguration: [AnyHashable: Any] { [:] }
}

final class LibraryTable: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            NSApp.sendAction(doubleAction!, to: target, from: self)
            return
        }
        super.keyDown(with: event)
    }
}

/// A label that lets clicks through to its row.
final class LibraryLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Explicit sRGB: calibrated RGB brightens the reference's encoded grays.
private func referenceColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

final class LibraryRow: NSTableRowView {
    var thumbnailWidth: CGFloat = 0

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    override func drawBackground(in dirtyRect: NSRect) {
        let top = isDark ? referenceColor(0.19, 0.19, 0.20) : referenceColor(0.973, 0.973, 0.973)
        let bottom = isDark ? referenceColor(0.185, 0.185, 0.195) : referenceColor(0.963, 0.963, 0.963)
        NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: 90)
        referenceColor(0.165, 0.165, 0.165).setFill()
        NSRect(x: 0, y: 0, width: thumbnailWidth, height: bounds.height).fill()
        (isDark ? referenceColor(0.30, 0.30, 0.31) : referenceColor(0.89, 0.89, 0.89)).setFill()
        NSRect(x: thumbnailWidth, y: 0, width: bounds.width - thumbnailWidth, height: 0.5).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        (isDark ? referenceColor(0.23, 0.30, 0.41) : referenceColor(0.88, 0.92, 0.98)).setFill()
        NSRect(x: thumbnailWidth, y: 0, width: bounds.width - thumbnailWidth, height: bounds.height).fill()
    }
}

final class LibraryCell: NSTableCellView {
    var thumbnailWidth: CGFloat = 0
    var compact = false
    weak var table: NSTableView?
    var primary: VIMPlayButton?
    var configure: NSButton?
    var specifications: NSTextField?
    private var hoverTracking: NSTrackingArea?

    var hovered = false {
        didSet {
            primary?.showsPlayControl = hovered
            configure?.isHidden = compact && !hovered
        }
    }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override var draggingImageComponents: [NSDraggingImageComponent] {
        let components = super.draggingImageComponents
        for component in components where component.key == .icon {
            guard let viewport = imageView?.superview, let source = imageView?.image else { continue }
            let size = viewport.bounds.size
            guard size.width > 0, size.height > 0 else { continue }
            let original = source.size
            let scale = max(size.width / original.width, size.height / original.height)
            let crop = NSRect(
                x: (original.width - size.width / scale) / 2, y: (original.height - size.height / scale) / 2,
                width: size.width / scale, height: size.height / scale)
            component.contents = NSImage(size: size, flipped: false) { rect in
                source.draw(in: rect, from: crop, operation: .sourceOver, fraction: 1)
                return true
            }
            // The aspect-fill image view extends beyond its clipped viewport, and only the visible thumbnail is dragged.
            component.frame = convert(viewport.bounds, from: viewport)
        }
        return components
    }

    /// AppKit swaps selected labels to white, and this selection is the reference's pale tint.
    override var backgroundStyle: NSView.BackgroundStyle {
        get { super.backgroundStyle }
        set {
            super.backgroundStyle = .normal
            textField?.textColor = .labelColor
            textField?.font = .systemFont(ofSize: compact ? 17 : 22, weight: .light)
            specifications?.textColor = .secondaryLabelColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let table else { return }
        let row = table.row(for: self)
        guard row >= 0 else { return }
        if event.clickCount >= 2 {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            NSApp.sendAction(table.doubleAction!, to: table.target, from: table)
        } else {
            table.mouseDown(with: event)
        }
    }

    @objc private func refreshHover(_ notification: Notification?) {
        guard let window else {
            hovered = false
            return
        }
        hovered =
            window.isKeyWindow
            && visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        hoverTracking = tracking
        addTrackingArea(tracking)
        // Removing a tracking area while scrolling doesn't promise mouseExited, so this goes by the current clipped
        // geometry and not the reused row's state.
        refreshHover(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        for name in [
            NSView.boundsDidChangeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification
        ] {
            center.removeObserver(self, name: name, object: nil)
        }
        if let window {
            let clip = enclosingScrollView?.contentView
            clip?.postsBoundsChangedNotifications = true
            if let clip {
                center.addObserver(
                    self, selector: #selector(refreshHover(_:)), name: NSView.boundsDidChangeNotification, object: clip)
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                center.addObserver(self, selector: #selector(refreshHover(_:)), name: name, object: window)
            }
        }
        refreshHover(nil)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}
