import AppKit
import InstallerKit
import MachineKit

// The creation assistant's own views. They draw and report; `VIMNewMachineWindow` decides.

/// The assistant's fixed content size.
let assistantSize = NSSize(width: 872, height: 584)

class AssistantPage: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.blended(withFraction: 0.8, of: .controlBackgroundColor)?.setFill()
        dirtyRect.fill()
    }

    /// The bottom bar: a separator, an optional leading control, and trailing buttons of equal width.
    func addFooter(leading: NSButton?, trailing buttons: [NSButton]) {
        let line = NSBox()
        line.boxType = .separator
        addAssistantSubview(line)
        let trailing = NSStackView(views: buttons)
        trailing.spacing = 12
        addAssistantSubview(trailing)
        for button in buttons {
            button.bezelStyle = .push
            button.controlSize = .large
            button.font = .systemFont(ofSize: NSFont.systemFontSize)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }
        if let first = buttons.first, let last = buttons.last, first !== last {
            first.widthAnchor.constraint(equalTo: last.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -80),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            trailing.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -40)
        ])
        guard let leading else { return }
        leading.controlSize = .large
        leading.font = .systemFont(ofSize: NSFont.systemFontSize)
        addAssistantSubview(leading)
        NSLayoutConstraint.activate([
            leading.heightAnchor.constraint(equalToConstant: 40),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            leading.centerYAnchor.constraint(equalTo: trailing.centerYAnchor)
        ])
    }

    /// The picture of a window running off the page's left edge.
    func addArtwork(_ artwork: InstallerArtwork) {
        addAssistantSubview(artwork)
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -28),
            artwork.widthAnchor.constraint(equalToConstant: 416),
            artwork.heightAnchor.constraint(equalToConstant: 328),
            artwork.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10)
        ])
    }
}

extension NSView {
    func addAssistantSubview(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
    }
}

@MainActor func assistantText(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = .labelColor
    field.isSelectable = false
    return field
}

/// An icon beside a title. Artwork may be missing during development, which must never stop the page appearing, so this
/// doesn't use `NSImageView(image:)`.
@MainActor func assistantHeading(title: NSTextField, guest: Guest) -> (
    heading: NSStackView, icon: NSImageView, height: NSLayoutConstraint
) {
    let icon = NSImageView()
    icon.image = NSImage(named: guest.rawValue + "Icon")
    icon.widthAnchor.constraint(equalToConstant: 52).isActive = true
    let height = icon.heightAnchor.constraint(equalToConstant: 64)
    height.isActive = true
    let heading = NSStackView(views: [icon, title])
    heading.spacing = 8
    heading.alignment = .centerY
    title.widthAnchor.constraint(equalTo: heading.widthAnchor, constant: -60).isActive = true
    return (heading, icon, height)
}

/// Reserves field-editor room for the inline reveal button.
final class PasswordCell: NSTextFieldCell {
    override func drawingRect(forBounds bounds: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: bounds)
        rect.size.width = max(0, rect.size.width - 26)
        return rect
    }
}

final class SecurePasswordCell: NSSecureTextFieldCell {
    override func drawingRect(forBounds bounds: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: bounds)
        rect.size.width = max(0, rect.size.width - 26)
        return rect
    }
}

/// A single native paragraph with inline attachments and links, not button rows. The prose isn't selectable, but its
/// links still work.
final class RecommendationParagraph: NSTextView {
    override func mouseDown(with event: NSEvent) {
        guard let layoutManager, let textContainer, let textStorage else { return }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < textStorage.length else { return }
        var range = NSRange()
        guard let link = textStorage.attribute(.link, at: index, effectiveRange: &range) as? URL else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).contains(point) else { return }
        NSWorkspace.shared.open(link)
    }
}

/// A row in the version chooser. The whole row is one accessible button, not nested labels that swallow clicks.
final class SystemOption: NSButton {
    var roundel: NSImage?
    /// Return activates it, as it does nothing else on this page.
    var isRecommendation = false
    var onDoubleClick: (() -> Void)?
    var onMove: ((GuestGrid.Move) -> Void)?

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        sendAction(action, to: target)
    }

    override func mouseDown(with event: NSEvent) {
        // NSRadioButtonCell tracks only its own image and title, not this custom full-width row. Selection is immediate
        // everywhere.
        performClick(nil)
        if event.clickCount == 2, isEnabled { onDoubleClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            ring.fill()
            NSColor.controlAccentColor.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
        roundel?.draw(
            in: NSRect(x: 10, y: (bounds.height - 36) / 2, width: 36, height: 36), from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: true, hints: nil)
        (title as NSString).draw(
            in: NSRect(x: 56, y: (bounds.height - 20) / 2, width: bounds.width - 68, height: 20),
            withAttributes: [.font: Self.titleFont, .foregroundColor: NSColor.labelColor])
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onMove?(.left)
        case 124: onMove?(.right)
        case 125: onMove?(.down)
        case 126: onMove?(.up)
        case 36 where isRecommendation, 76 where isRecommendation: performClick(nil)
        default: super.keyDown(with: event)
        }
    }

    static let titleFont = NSFont.systemFont(ofSize: 15)
}

/// The guest's wallpaper in a little window with a real title bar.
final class InstallerArtwork: NSView {
    var wallpaper: NSImage? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSRect(x: 0, y: 24, width: bounds.width - 28, height: bounds.height - 48)
        let outline = NSBezierPath(roundedRect: card, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -7)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        var picture = card
        picture.size.height -= 22
        if let wallpaper, wallpaper.size.width > 0, wallpaper.size.height > 0 {
            let size = wallpaper.size
            let scale = max(picture.width / size.width, picture.height / size.height)
            let crop = NSRect(
                x: (size.width - picture.width / scale) / 2, y: (size.height - picture.height / scale) / 2,
                width: picture.width / scale, height: picture.height / scale)
            wallpaper.draw(in: picture, from: crop, operation: .sourceOver, fraction: 1)
        }
        // A real title bar must stay visible against the assistant's dark page. System colors keep the light variant
        // native, without a black-on-black cap.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark
            ? NSColor.windowBackgroundColor.blended(withFraction: 0.16, of: .white) : NSColor.windowBackgroundColor)?
            .setFill()
        NSRect(x: card.minX, y: card.maxY - 22, width: card.width, height: 22).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
