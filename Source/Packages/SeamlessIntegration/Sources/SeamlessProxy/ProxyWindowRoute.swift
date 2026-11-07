/// Shared by callbacks belonging to one host window. Renaming changes its guest target; removal retires it permanently.
/// A new surface reusing a guest ID gets a new route, so queued callbacks from the old surface cannot reach it.
@MainActor
final class ProxyWindowRoute {
    private(set) var windowID: Int?

    init(windowID: Int) { self.windowID = windowID }

    func rename(to windowID: Int) {
        guard self.windowID != nil else { return }
        self.windowID = windowID
    }

    func invalidate() { windowID = nil }
}
