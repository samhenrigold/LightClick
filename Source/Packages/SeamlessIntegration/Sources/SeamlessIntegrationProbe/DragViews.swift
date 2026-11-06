import AppKit

/// Starts a drag of a file on mouse down, standing in for Finder on the host.
@MainActor
final class FileDragSource: NSView, NSDraggingSource {
    var file: URL?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let file else { return }
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        let icon = NSWorkspace.shared.icon(forFile: file.path)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }
}

/// A drop target in another process from the drag source, standing in for a guest app. Records what a real target sees.
@MainActor
final class DropRecorder: NSView {
    var entered = 0
    var dropped: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        entered += 1
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls =
            sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        dropped = urls.map(\.path)
        return true
    }
}

func smallWindow(_ frame: NSRect, content: NSView, title: String) -> NSWindow {
    let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.contentView = content
    window.orderFrontRegardless()
    return window
}
