import AppKit

// One proxy per guest app. It holds the Dock tile, the menu bar and document handling, and forwards everything to the
// session process. See probes/seamless-integration.md.
let application = NSApplication.shared
let delegate = ProxyApplication()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
