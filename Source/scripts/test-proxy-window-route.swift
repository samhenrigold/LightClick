// Compile with the production ProxyWindowRoute.swift only. No AppKit, NSApplication, NSWindow or host input.
@main
private enum ProxyWindowRouteChecks {
    @MainActor static func main() {
        var sent: [String] = []
        func callback(_ event: String, target: ProxyWindowRoute) -> @MainActor () -> Void {
            {
                guard let id = target.windowID else { return }
                sent.append("\(event):\(id)")
            }
        }
        let original = ProxyWindowRoute(windowID: 43)
        // These closures are installed once, before the guest changes CGWindowID.
        let callbacks = ["fullscreen-exit", "minimize", "drag-enter", "drag-move", "drag-drop", "pointer-left"].map {
            callback($0, target: original)
        }
        original.rename(to: 77)
        callbacks.forEach { $0() }
        precondition(sent == ["fullscreen-exit:77", "minimize:77", "drag-enter:77", "drag-move:77", "drag-drop:77", "pointer-left:77"])
        sent.removeAll()
        original.rename(to: 43) // Returning from fullscreen can restore the earlier guest ID.
        callbacks.forEach { $0() }
        precondition(sent.allSatisfy { $0.hasSuffix(":43") } && sent.count == callbacks.count)
        sent.removeAll()
        original.invalidate() // Close/removal happens before any delayed host notification.
        let reused = ProxyWindowRoute(windowID: 43)
        let currentCallback = callback("new-window", target: reused)
        callbacks.forEach { $0() }
        original.rename(to: 999) // A retired target cannot be resurrected by late work.
        callbacks.forEach { $0() }
        precondition(sent.isEmpty)
        currentCallback()
        precondition(sent == ["new-window:43"])
        sent.removeAll()
        let displaced = ProxyWindowRoute(windowID: 88)
        let displacedCallback = callback("displaced-window", target: displaced)
        displaced.invalidate() // Rename replaces a destination surface; its callbacks must also retire.
        reused.rename(to: 88)
        displacedCallback()
        currentCallback()
        precondition(sent == ["new-window:88"])
        reused.invalidate()
        reused.invalidate()
        currentCallback()
        precondition(sent == ["new-window:88"])
        print("PASS queued callbacks follow rename/return; removal, ID reuse and displaced targets cannot misroute")
    }
}
