import AVFoundation
import AppKit
import MachineKit

/// The Objective-C face of the configuration windows: one per machine, kept for the app's lifetime.
@MainActor @objc(VIMMachineSettings)
final class MachineSettings: NSObject {
    private static var windows: [String: ConfigurationWindow] = [:]

    private static func window(for machine: VIMMachine) -> ConfigurationWindow? {
        NSApp.windows.lazy.compactMap { $0.windowController as? ConfigurationWindow }.first { $0.isShowing(machine) }
    }

    @objc(showForMachine:window:completion:)
    class func show(for machine: VIMMachine, window: NSWindow?, completion: (() -> Void)?) {
        let identifier = (machine.configuration["Identifier"] as? String).flatMap(UUID.init(uuidString:))
        let key = identifier?.uuidString ?? machine.url.resolvingSymlinksInPath().path
        let controller: ConfigurationWindow
        if let existing = windows[key] {
            controller = existing
            if existing.window?.isVisible != true {
                existing.machine = machine
                existing.invalidField = false
                existing.render()
            }
        } else {
            controller = ConfigurationWindow(machine: machine)
            windows[key] = controller
        }
        // Opened again from somewhere with nothing to refresh, the window still owes the library its refreshes.
        if let completion { controller.completion = completion }
        if controller.window?.isMiniaturized == true { controller.window?.deminiaturize(nil) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc(showForMachine:section:category:window:)
    class func show(for machine: VIMMachine, section: String, category: String, window: NSWindow?) {
        show(for: machine, window: window, completion: nil)
        guard let controller = Self.window(for: machine) else { return }
        if let section = SettingsSection(identifier: section) { controller.select(section) }
        if let category = SettingsCategory(identifier: category) { controller.select(category) }
    }

    @objc(requestMicrophoneAccessFromWindow:)
    class func requestMicrophoneAccess(from window: NSWindow?) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        Task {
            guard await !AVCaptureDevice.requestAccess(for: .audio) else { return }
            let alert = NSAlert()
            alert.messageText = "Microphone access is turned off"
            alert.informativeText = "You can allow Light Click to use this Mac’s microphone in Privacy settings."
            alert.addButton(withTitle: "OK")
            VIMPresentAlert(alert, window, nil)
        }
    }

    /// Development harness: renders only this app's own configuration content.
    @objc(captureForMachine:toURL:error:)
    class func capture(for machine: VIMMachine, to url: URL) throws {
        guard let view = window(for: machine)?.window?.contentView else {
            throw NSError(
                domain: "VirtualIntelMac.Configuration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Open this Mac’s configuration before capturing its preview."])
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    /// Development harness: 21 section switches, checking the outgoing table's layout and the sidebar's elasticity.
    @objc(checkPaneCyclingForMachine:completion:)
    class func checkPaneCycling(for machine: VIMMachine, completion: @escaping (Bool) -> Void) {
        show(for: machine, window: nil, completion: nil)
        guard let controller = window(for: machine) else {
            completion(false)
            return
        }
        Task {
            for cycle in 0..<21 {
                let outgoing = controller.sidebar
                let section: SettingsSection = cycle % 2 == 0 ? .hardware : .sharing
                controller.select(section)
                outgoing?.layoutSubtreeIfNeeded()
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                let scroll = controller.sidebar?.enclosingScrollView
                guard scroll?.verticalScrollElasticity == NSScrollView.Elasticity.none,
                    scroll?.horizontalScrollElasticity == NSScrollView.Elasticity.none,
                    scroll?.hasVerticalScroller == false, scroll?.hasHorizontalScroller == false,
                    controller.sidebar?.categories == section.categories
                else {
                    completion(false)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            completion(true)
        }
    }
}
