import AppKit
import SeamlessIntegration
import UniformTypeIdentifiers

@MainActor
protocol ProxyEventSink: AnyObject {
    func send(_ event: ProxyEvent)
}

/// A guest window's view on the host: takes the host's drags in, and starts the host's drag when a guest drag leaves.
/// The hosted layer from `seamless-apps` draws over this view; these methods don't depend on it.
@MainActor
final class ProxyDropView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    private let windowID: Int
    private weak var sink: (any ProxyEventSink)?
    private var lastMouseEvent: NSEvent?
    private var leftWithButtonDown = false
    private var nextPromise = 0
    private var promises: [Int: (any Error)?] = [:]
    private var promiseCompletions: [Int: @Sendable ((any Error)?) -> Void] = [:]

    init(windowID: Int, sink: any ProxyEventSink) {
        self.windowID = windowID
        self.sink = sink
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Into the guest

    private func point(_ info: any NSDraggingInfo) -> NSPoint { convert(info.draggingLocation, from: nil) }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let urls =
            sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return [] }
        let location = point(sender)
        sink?.send(
            .dragEntered(paths: urls.map(\.path), windowID: windowID, x: location.x, y: location.y))
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let location = point(sender)
        sink?.send(.dragMoved(windowID: windowID, x: location.x, y: location.y))
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { sink?.send(.dragExited) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let location = point(sender)
        sink?.send(.dragDropped(windowID: windowID, x: location.x, y: location.y))
        return true
    }

    // MARK: Out of the guest

    override func mouseDown(with event: NSEvent) {
        lastMouseEvent = event
        leftWithButtonDown = false
    }

    override func mouseDragged(with event: NSEvent) {
        lastMouseEvent = event
        // Only this edge matters here: `seamless-input` owns forwarding the drag itself.
        if !bounds.contains(convert(event.locationInWindow, from: nil)), !leftWithButtonDown {
            leftWithButtonDown = true
            sink?.send(.pointerLeftWithButtonDown(windowID: windowID))
        }
    }

    func beginDragOut(names: [String], imagePNG: Data?) {
        guard let event = lastMouseEvent ?? NSApp.currentEvent, !names.isEmpty else { return }
        let image = imagePNG.flatMap(NSImage.init(data:))
        let items = names.map { name -> NSDraggingItem in
            let provider = NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: self)
            provider.userInfo = hostFileName(for: name)
            let item = NSDraggingItem(pasteboardWriter: provider)
            let tile = image ?? NSWorkspace.shared.icon(for: .data)
            let origin = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(
                NSRect(
                    x: origin.x - tile.size.width / 2, y: origin.y - tile.size.height / 2, width: tile.size.width,
                    height: tile.size.height),
                contents: tile)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        MainActor.assumeIsolated { sink?.send(.dragOutEnded(accepted: operation != [])) }
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String
    {
        provider.userInfo as? String ?? "Untitled"
    }

    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.nextPromise += 1
                self.promiseCompletions[self.nextPromise] = completionHandler
                self.sink?.send(.promiseRequested(id: self.nextPromise, destination: url.path))
            }
        }
    }

    func promiseFulfilled(id: Int, error: String?) {
        promiseCompletions.removeValue(forKey: id)?(
            error.map { NSError(domain: "LightClick.Seamless", code: 1, userInfo: [NSLocalizedDescriptionKey: $0]) })
    }
}

/// Where the crop of the guest's menu bar goes in mode B. The surface comes from `seamless-apps`; this reports where clicks
/// land, in points from the top left of the screen.
@MainActor
final class GuestMenuBarView: NSView {
    private weak var sink: (any ProxyEventSink)?

    init(sink: any ProxyEventSink) {
        self.sink = sink
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        sink?.send(.guestMenuBarClicked(x: point.x, y: point.y))
    }
}
