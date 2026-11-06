import AppKit
import ObjectiveC.runtime

/// Seamless as a fourth stoplight, after close, minimize and zoom.
///
/// macOS 27's stoplights aren't glass views. Each is an `_NSThemeWidget` hosting SwiftUI's `DesignLibrary.WindowControl`, which
/// lays three things over each other: a bitmap body from DesignLibrary's asset catalog, translucent and with its rim baked in,
/// a template glyph composited with plus-darker, and a colour-dodge wash while pressed. None of that takes a colour, and its
/// only glyphs are the system's own, so this draws the same three layers itself, from the same assets. The zoom button says
/// what state to draw, so the four can't disagree.
///
/// The theme frame hard-codes the three in its hover group and its layout, so `StoplightHooks` adds the fourth there. If any of
/// that isn't what's expected there's no button, and the menu item remains.
@MainActor @objc(VIMSeamlessWindowButton)
final class SeamlessWindowButton: NSButton {
    /// What the button's made from. Change `tint` to change its colour.
    struct Tint {
        var source: String
        var hueTurn, saturation, gamma: Double
        /// The glyph's colour in light and dark. The system's are a dark shade of the body at 0.7 alpha.
        var glyphLight, glyphDark: (red: CGFloat, green: CGFloat, blue: CGFloat)

        static let purple = Tint(
            source: "Close", hueTurn: -1.48, saturation: 1, gamma: 1, glyphLight: (0.42, 0, 0.639),
            glyphDark: (0.4, 0, 0.52))
        static let blue = Tint(
            source: "Expand", hueTurn: 1.92, saturation: 1.1, gamma: 1.35, glyphLight: (0, 0.27, 0.639),
            glyphDark: (0, 0.23, 0.55))
    }
    static var tint = Tint.purple

    private weak var hostWindow: NSWindow?
    private let bodyLayer = CALayer()
    private let glyphLayer = CALayer()
    private let washLayer = CALayer()
    private let art: StoplightArt
    private var drawnKey: String?
    private var active = false

    @objc(installOnWindow:target:action:)
    static func install(on window: NSWindow, target: AnyObject, action: Selector) -> SeamlessWindowButton? {
        if let existing = StoplightHooks.button(on: window) { return existing }
        guard let zoom = window.standardWindowButton(.zoomButton), zoom.superview != nil, BezelState(zoom: zoom) != nil,
            let art = StoplightArt(tint: tint)
        else { return nil }
        let button = SeamlessWindowButton(window: window, art: art)
        guard StoplightHooks.attach(button, to: window) else { return nil }
        button.target = target
        button.action = action
        button.place()
        return button
    }

    /// `reason`, when it can't be used, says why, for the tooltip.
    @objc(updateActive:disabledReason:)
    func update(active: Bool, disabledReason reason: String?) {
        self.active = active
        let enabled = reason == nil
        if isEnabled != enabled {
            isEnabled = enabled
            hostWindow.map { StoplightHooks.groupChanged(on: $0) }
        }
        let label = active ? "Leave Seamless" : "Seamless"
        toolTip = reason ?? label
        // Its cell is what accessibility finds in the window.
        cell?.setAccessibilityLabel(label)
        cell?.setAccessibilityHelp(reason)
        needsDisplay = true
    }

    private init(window: NSWindow, art: StoplightArt) {
        hostWindow = window
        self.art = art
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = false
        for sublayer in [bodyLayer, glyphLayer, washLayer] {
            sublayer.actions = ["contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(sublayer)
        }
        glyphLayer.compositingFilter = "plusD"
        washLayer.compositingFilter = "colorDodgeBlendMode"
        washLayer.backgroundColor = CGColor(srgbRed: 64 / 255, green: 64 / 255, blue: 64 / 255, alpha: 1)
        setAccessibilityRole(.button)
        update(active: false, disabledReason: nil)
        // The real three redraw for these from inside AppKit, where a plain button doesn't hear it.
        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification
        ] {
            center.addObserver(self, selector: #selector(stateChanged), name: name, object: window)
        }
        center.addObserver(
            self, selector: #selector(stateChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(stateChanged), name: NSApplication.didResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(stateChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    @objc private func stateChanged() {
        drawnKey = nil
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("Not from a nib") }

    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// One along from zoom, by the distance between minimize and zoom. Follows zoom into any titlebar it moves to.
    func place() {
        guard let hostWindow, let zoom = hostWindow.standardWindowButton(.zoomButton), let parent = zoom.superview
        else { return }
        if superview !== parent { parent.addSubview(self, positioned: .above, relativeTo: zoom) }
        let step =
            hostWindow.standardWindowButton(.miniaturizeButton).map { zoom.frame.minX - $0.frame.minX }
            ?? (zoom.frame.width + 9)
        let placed = NSRect(origin: NSPoint(x: zoom.frame.minX + step, y: zoom.frame.minY), size: zoom.frame.size)
        let moved = frame != placed
        frame = placed
        isHidden = zoom.isHidden
        alphaValue = zoom.alphaValue
        layer?.opacity = Float(zoom.cell?.value(forKey: "buttonRevealAmount") as? Double ?? 1)
        needsDisplay = true
        if moved { StoplightHooks.groupChanged(on: hostWindow) }
        // A title beside the stoplights starts just past zoom, by a metric of its own.
        if let field = StoplightHooks.titleField(on: hostWindow), field.superview === parent,
            field.frame.minX < placed.maxX
        {
            field.setFrameOrigin(NSPoint(x: placed.maxX + field.frame.minX - zoom.frame.maxX, y: field.frame.minY))
        }
    }

    /// How far this adds to the stoplights' width.
    var extraWidth: CGFloat {
        guard !isHidden, let zoom = hostWindow?.standardWindowButton(.zoomButton) else { return 0 }
        return abs(frame.minX - zoom.frame.minX)
    }

    /// From the zoom button's own frame in some coordinates, this one's in the same.
    func frame(fromZoomFrame zoomFrame: CGRect) -> CGRect {
        guard let zoom = hostWindow?.standardWindowButton(.zoomButton) else { return zoomFrame }
        return zoomFrame.offsetBy(dx: frame.minX - zoom.frame.minX, dy: 0)
    }

    override func updateLayer() {
        guard let hostWindow, let zoom = hostWindow.standardWindowButton(.zoomButton),
            let state = BezelState(zoom: zoom)
        else {
            return
        }
        let look = StoplightArt.Look(state: state, enabled: isEnabled)
        let appearance = effectiveAppearance
        let scale = hostWindow.backingScaleFactor
        let key = "\(appearance.name.rawValue) \(scale) \(look.body) \(active)"
        if key != drawnKey {
            drawnKey = key
            appearance.performAsCurrentDrawingAppearance {
                bodyLayer.contents = art.body(look.body, scale: scale)
                glyphLayer.contents = art.glyph(
                    active: active, dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, scale: scale)
            }
        }
        bodyLayer.frame = bounds.insetBy(dx: -4, dy: -4)
        glyphLayer.frame = bounds
        glyphLayer.isHidden = !look.showsGlyph
        washLayer.frame = bounds
        washLayer.cornerRadius = bounds.width / 2
        washLayer.isHidden = !(isHighlighted && isEnabled)
    }
}

/// What the zoom button's about to draw: `NSButtonBezelConfiguration`, which `_NSThemeWidgetCell` makes afresh each time.
private struct BezelState {
    static let selector = NSSelectorFromString("bezelConfigurationInView:")
    /// In the group, or down on any of them. It's 1 when disabled.
    let hovered: Bool
    /// A window that isn't key is 2.
    let keyLooking: Bool

    @MainActor init?(zoom: NSButton) {
        guard let cell = zoom.cell, cell.responds(to: Self.selector),
            let configuration = cell.perform(Self.selector, with: zoom)?.takeUnretainedValue() as? NSObject,
            configuration.responds(to: NSSelectorFromString("interactionState")),
            configuration.responds(to: NSSelectorFromString("presentationState")),
            let interaction = configuration.value(forKey: "interactionState") as? Int,
            let presentation = configuration.value(forKey: "presentationState") as? Int
        else { return nil }
        hovered = interaction >= 2
        keyLooking = presentation == 0
    }
}

/// DesignLibrary's bodies for the system's states, the tinted one made from one of them, and the glyph.
@MainActor
private final class StoplightArt {
    struct Look {
        enum Body: String {
            case tinted
            case inactive = "Inactive"
            case graphite = "GraphiteActive"
            case graphiteInactive = "GraphiteInactive"
        }
        let body: Body
        let showsGlyph: Bool

        /// As the system's: lit when key or hovered, and grey with no glyph when disabled however it's hovered.
        init(state: BezelState, enabled: Bool) {
            let graphite = NSColor.currentControlTint == .graphiteControlTint
            let lit = enabled && (state.hovered || state.keyLooking)
            body = graphite ? (lit ? .graphite : .graphiteInactive) : (lit ? .tinted : .inactive)
            showsGlyph = enabled && state.hovered
        }
    }

    private let tint: SeamlessWindowButton.Tint
    private let bundle: Bundle
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    init?(tint: SeamlessWindowButton.Tint) {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/DesignLibrary.framework") else { return nil }
        self.bundle = bundle
        self.tint = tint
        for name in [
            tint.source, Look.Body.inactive.rawValue, Look.Body.graphite.rawValue, Look.Body.graphiteInactive.rawValue
        ]
        where bundle.image(forResource: "WindowControlBodies/" + name) == nil {
            return nil
        }
    }

    /// In the current drawing appearance, which is what picks among the catalog's light, dark and high contrast versions.
    func body(_ body: Look.Body, scale: CGFloat) -> CGImage? {
        guard
            let image = bundle.image(
                forResource: "WindowControlBodies/" + (body == .tinted ? tint.source : body.rawValue))
        else { return nil }
        var rect = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        guard body == .tinted else { return source }
        var output = CIImage(cgImage: source).applyingFilter(
            "CIHueAdjust", parameters: [kCIInputAngleKey: tint.hueTurn])
        output = output.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: tint.saturation])
        if tint.gamma != 1 { output = output.applyingFilter("CIGammaAdjust", parameters: ["inputPower": tint.gamma]) }
        return context.createCGImage(
            output, from: output.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
            ?? source
    }

    /// Solid and rounded like the system's, at about their weight: a window in front of the one behind it. Leaving, the front one's open.
    func glyph(active: Bool, dark: Bool, scale: CGFloat) -> CGImage? {
        let shade = dark ? tint.glyphDark : tint.glyphLight
        let color = NSColor(srgbRed: shade.red, green: shade.green, blue: shade.blue, alpha: 0.7)
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            color.set()
            let back = NSBezierPath(
                roundedRect: NSRect(x: 5.75, y: 5.75, width: 5.25, height: 5.25), xRadius: 1.25, yRadius: 1.25)
            back.lineWidth = 1.5
            back.stroke()
            let front = NSRect(x: 2.75, y: 2.75, width: 5.75, height: 5.75)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: front.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            color.set()
            if active {
                let path = NSBezierPath(roundedRect: front.insetBy(dx: 0.75, dy: 0.75), xRadius: 1, yRadius: 1)
                path.lineWidth = 1.5
                path.stroke()
            } else {
                NSBezierPath(roundedRect: front, xRadius: 1.25, yRadius: 1.25).fill()
            }
            return true
        }
        var rect = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

/// `NSThemeFrame` and `NSWindow`, knowing about a fourth stoplight. Replaced once, for every window, and only different for one
/// with a button. Not by swapping the instances' classes as KVO does: AppKit observes both, and that would lose its observers.
private enum StoplightHooks {
    private nonisolated(unsafe) static var buttonKey: UInt8 = 0
    private static let frameMethods = [
        "_updateButtonPositions": "v16@0:8", "_setMouseEnteredGroup:entered:": "v24@0:8B16B20",
        "_minXTitlebarButtonsWidth": "d16@0:8",
        "setButtonRevealAmount:": "v24@0:8d16", "_updateMouseTracking": "v16@0:8", "_titleTextField": "@16@0:8"
    ]
    private static let groupFrame = "_groupFrameForStandardWindowButtonTypes:inView:includeObscured:"
    private static let installed = install()

    @MainActor static func button(on window: NSWindow) -> SeamlessWindowButton? {
        objc_getAssociatedObject(window, &buttonKey) as? SeamlessWindowButton
    }

    @MainActor static func attach(_ button: SeamlessWindowButton, to window: NSWindow) -> Bool {
        guard let frameClass = NSClassFromString("NSThemeFrame"),
            window.contentView?.superview?.isKind(of: frameClass) == true, installed
        else { return false }
        objc_setAssociatedObject(window, &buttonKey, button, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return true
    }

    /// The tracking area that shows the glyphs is built from the group's frame, which this now reaches past.
    @MainActor static func groupChanged(on window: NSWindow) {
        guard button(on: window) != nil else { return }
        window.contentView?.superview?.perform(NSSelectorFromString("_updateMouseTracking"))
    }

    /// The title field where AppKit keeps it, if it's using one: a title in a toolbar isn't.
    @MainActor static func titleField(on window: NSWindow) -> NSView? {
        window.contentView?.superview?.perform(NSSelectorFromString("_titleTextField"))?.takeUnretainedValue()
            as? NSView
    }

    /// Anything can ask, from any thread and for any window, so this is what keeps the rest of them as they were.
    private static func with<T: Sendable>(
        _ window: @autoclosure @MainActor () -> NSWindow?, otherwise: T, _ body: @MainActor (SeamlessWindowButton) -> T
    ) -> T {
        guard Thread.isMainThread else { return otherwise }
        return MainActor.assumeIsolated { window().flatMap { button(on: $0) }.map(body) ?? otherwise }
    }

    private static func matches(_ cls: AnyClass, _ selector: String, _ encoding: String) -> Bool {
        guard let method = class_getInstanceMethod(cls, NSSelectorFromString(selector)),
            let types = method_getTypeEncoding(method)
        else { return false }
        return String(cString: types) == encoding
    }

    private static func replace<Original>(
        _ cls: AnyClass, _ selector: Selector, _ type: Original.Type, _ block: (Original) -> Any
    ) {
        let method = class_getInstanceMethod(cls, selector)!
        let original = unsafeBitCast(method_getImplementation(method), to: type)
        class_replaceMethod(cls, selector, imp_implementationWithBlock(block(original)), method_getTypeEncoding(method))
    }

    /// Everything's checked to be there, each with the types it's called with, before anything's changed.
    private static func install() -> Bool {
        let rect = "{CGRect={CGPoint=dd}{CGSize=dd}}"
        guard let frameClass = NSClassFromString("NSThemeFrame"),
            frameMethods.allSatisfy({ matches(frameClass, $0.key, $0.value) }),
            matches(NSWindow.self, groupFrame, rect + "36@0:8@16@24B32")
        else { return false }
        let positions = NSSelectorFromString("_updateButtonPositions")
        let enteredGroup = NSSelectorFromString("_setMouseEnteredGroup:entered:")
        let width = NSSelectorFromString("_minXTitlebarButtonsWidth")
        let reveal = NSSelectorFromString("setButtonRevealAmount:")
        let group = NSSelectorFromString(groupFrame)
        typealias Plain = @convention(c) (NSView, Selector) -> Void
        typealias Entered = @convention(c) (NSView, Selector, Bool, Bool) -> Void
        typealias Width = @convention(c) (NSView, Selector) -> CGFloat
        typealias Reveal = @convention(c) (NSView, Selector, Double) -> Void
        typealias Group = @convention(c) (NSWindow, Selector, NSArray, NSView?, Bool) -> CGRect

        // Where AppKit positions the real three, so the fourth moves with them and needs no polling.
        replace(frameClass, positions, Plain.self) { original in
            { frame in
                original(frame, positions)
                with(frame.window, otherwise: ()) { $0.place() }
            } as @convention(block) (NSView) -> Void
        }
        replace(frameClass, enteredGroup, Entered.self) { original in
            { frame, left, entered in
                original(frame, enteredGroup, left, entered)
                with(frame.window, otherwise: ()) { $0.needsDisplay = true }
            } as @convention(block) (NSView, Bool, Bool) -> Void
        }
        // What a toolbar and its inline title start after.
        replace(frameClass, width, Width.self) { original in
            { frame in
                original(frame, width) + with(frame.window, otherwise: 0) { $0.extraWidth }
            } as @convention(block) (NSView) -> CGFloat
        }
        replace(frameClass, reveal, Reveal.self) { original in
            { frame, amount in
                original(frame, reveal, amount)
                with(frame.window, otherwise: ()) { $0.place() }
            } as @convention(block) (NSView, Double) -> Void
        }
        // Every measure of the group comes through here. A disabled stoplight isn't in it, here as with the system's.
        let zoomType = NSNumber(value: NSWindow.ButtonType.zoomButton.rawValue)
        replace(NSWindow.self, group, Group.self) { original in
            { window, types, view, obscured in
                let rect = original(window, group, types, view, obscured)
                guard types.contains(zoomType) else { return rect }
                let zoom = original(window, group, [zoomType] as NSArray, view, obscured)
                return with(window, otherwise: rect) { button in
                    !zoom.isEmpty && button.isEnabled ? rect.union(button.frame(fromZoomFrame: zoom)) : rect
                }
            } as @convention(block) (NSWindow, NSArray, NSView?, Bool) -> CGRect
        }
        return true
    }
}
