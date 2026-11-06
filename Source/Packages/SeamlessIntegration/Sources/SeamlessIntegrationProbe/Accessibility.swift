import AppKit

/// Small readers over the Accessibility C API, for checking what the Dock and menu bar really show.
struct Element: @unchecked Sendable {
    let reference: AXUIElement

    static func application(pid: pid_t) -> Element { Element(reference: AXUIElementCreateApplication(pid)) }

    func value(_ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(reference, name as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ name: String) -> String? { value(name) as? String }

    var children: [Element] {
        (value("AXChildren") as? [AXUIElement] ?? []).map(Element.init)
    }

    var attributes: [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(reference, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    var frame: CGRect? {
        guard let position = value("AXPosition"), let size = value("AXSize") else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    func set(position: CGPoint) {
        var point = position
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(reference, "AXPosition" as CFString, value)
        }
    }

    @discardableResult
    func perform(_ action: String) -> AXError { AXUIElementPerformAction(reference, action as CFString) }
}

/// Synthetic pointer and keys. Top-left global coordinates, as CoreGraphics uses.
enum Synthetic {
    static func post(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func glide(from: CGPoint, to: CGPoint, steps: Int = 25) async {
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            post(
                .leftMouseDragged,
                CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction))
            try? await Task.sleep(for: .milliseconds(15))
        }
    }
}

extension NSScreen {
    /// A rect in AppKit's bottom-left space, in CoreGraphics' top-left space.
    static func topLeft(_ rect: NSRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}

func command(_ path: String, _ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
