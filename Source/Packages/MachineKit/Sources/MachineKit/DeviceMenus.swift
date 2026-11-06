// What a guest window's device menus list, as data. The session builds menu items from these, and validates them when
// AppKit asks, so an entry's `action` is the name of the session's method.

import Foundation

@objc(VIMDeviceMenuItem)
@objcMembers
public final class DeviceMenuItem: NSObject {
    public let title: String
    /// A selector's name, or nil for a line of text.
    public let action: String?
    public let isSeparator: Bool
    public let isEnabled: Bool
    public let isOn: Bool
    public let tag: Int
    public let representedObject: Any?
    public let symbol: String?
    public let toolTip: String?

    init(
        _ title: String = "", action: String? = nil, isSeparator: Bool = false, isEnabled: Bool? = nil,
        isOn: Bool = false,
        tag: Int = 0, representedObject: Any? = nil, symbol: String? = nil, toolTip: String? = nil
    ) {
        self.title = title
        self.action = action
        self.isSeparator = isSeparator
        self.isEnabled = isEnabled ?? (action != nil)
        self.isOn = isOn
        self.tag = tag
        self.representedObject = representedObject
        self.symbol = symbol
        self.toolTip = toolTip
    }

    static var separator: DeviceMenuItem { DeviceMenuItem(isSeparator: true) }
}

@objc(VIMDeviceMenus)
public final class DeviceMenus: NSObject {
    /// `images` are the connected ones, each with its `Path` and `Slot`.
    @objc(imagesMenuWithImages:slotCount:)
    public class func images(_ images: [[String: Any]], slotCount: Int) -> [DeviceMenuItem] {
        var items: [DeviceMenuItem] = []
        if images.isEmpty { items.append(DeviceMenuItem("No Images Connected")) }
        for image in images {
            let name = ((image["Path"] as? String ?? "") as NSString).lastPathComponent
            if images.count == 1 {
                items.append(DeviceMenuItem(name))
                items.append(
                    DeviceMenuItem("Disconnect", action: "ejectOpticalMedia:", representedObject: image["Slot"]))
            } else {
                items.append(
                    DeviceMenuItem(
                        "Disconnect “\(name)”", action: "ejectOpticalMedia:", representedObject: image["Slot"],
                        symbol: "opticaldisc"))
            }
        }
        if images.count < slotCount {
            items.append(.separator)
            items.append(DeviceMenuItem("Connect Image…", action: "chooseOpticalMedia:"))
        }
        items.append(.separator)
        items.append(DeviceMenuItem("Configure…", action: "showOpticalSettings:"))
        return items
    }

    /// - Parameter screenSharing: Whether Screen Sharing is offered for this guest at all.
    @objc(networkMenuConnected:mode:running:addresses:screenSharing:screenSharingOn:)
    public class func network(
        connected: Bool, mode: String, running: Bool, addresses: [String]?, screenSharing: Bool, screenSharingOn: Bool
    ) -> [DeviceMenuItem] {
        var items = [
            DeviceMenuItem("Disconnect", action: "changeNetworkConnection:", isOn: !connected, tag: 0), .separator
        ]
        let modes = [
            ("shared", "Shared Network (Recommended)"), ("host", "Host-Only Network"), ("bridged", "Bridged Network")
        ]
        for (index, (name, title)) in modes.enumerated() {
            items.append(
                DeviceMenuItem(
                    title, action: "changeNetworkConnection:", isOn: connected && mode == name, tag: index + 1))
        }
        if running, connected, let addresses, !addresses.isEmpty {
            items.append(.separator)
            items.append(DeviceMenuItem("IP Addresses:"))
            for address in addresses {
                items.append(DeviceMenuItem(address, action: "copyGuestIPAddress:", representedObject: address))
            }
        }
        items.append(.separator)
        if screenSharing {
            items.append(DeviceMenuItem("Share Screen", action: "toggleScreenSharing:", isOn: screenSharingOn))
            items.append(DeviceMenuItem("Open Screen Sharing…", action: "openScreenSharing:"))
            items.append(.separator)
        }
        items.append(DeviceMenuItem("Configure…", action: "showNetworkSettings:"))
        return items
    }

    /// - Parameter devices: The host's, each with a `Name` and `UID`.
    @objc(soundMenuForInput:selected:devices:)
    public class func sound(input: Bool, selected: String, devices: [[String: Any]]?) -> [DeviceMenuItem] {
        func choice(_ name: String, _ identifier: String) -> DeviceMenuItem {
            DeviceMenuItem(
                name, action: "changeAudioChoice:", isOn: selected == identifier,
                representedObject: ["Input": input, "UID": identifier] as [String: Any])
        }
        var items = [choice("Default", "default")]
        for device in devices ?? [] {
            items.append(choice(device["Name"] as? String ?? "", device["UID"] as? String ?? ""))
        }
        items.append(.separator)
        items.append(choice("Disconnected", "disabled"))
        return items
    }

    /// Shortcuts that macOS on the host would otherwise take for itself.
    @objc public class var keyboardMenu: [DeviceMenuItem] {
        let shortcuts: [(String, [String])] = [
            ("Command–Option–Escape", ["meta_l", "alt", "esc"]), ("Command–Tab", ["meta_l", "tab"]),
            ("Command–Space", ["meta_l", "spc"]), ("Control–Command–Q", ["ctrl", "meta_l", "q"]),
            ("Control–Up Arrow", ["ctrl", "up"]), ("Control–Down Arrow", ["ctrl", "down"]),
            ("Control–Left Arrow", ["ctrl", "left"]), ("Control–Right Arrow", ["ctrl", "right"]),
            ("Shift–Command–3", ["shift", "meta_l", "3"]), ("Shift–Command–4", ["shift", "meta_l", "4"]),
            ("Shift–Command–5", ["shift", "meta_l", "5"])
        ]
        return shortcuts.map { DeviceMenuItem($0.0, action: "sendMenuShortcut:", representedObject: $0.1) }
    }

    /// The host's devices, checked if connected to the guest, then any connected device unplugged from the host, which can
    /// still be released.
    /// - Parameters:
    ///   - devices: The host's, each with an `Identifier`, `Name` and optional `Vendor`.
    ///   - attached: The name of each connected device, by identifier.
    ///   - pending: A connection is changing, so the host's devices wait.
    @objc(usbMenuWithDevices:attached:pending:)
    public class func usb(devices: [[String: Any]], attached: [String: String]?, pending: Bool) -> [DeviceMenuItem] {
        let attached = attached ?? [:]
        var items = devices.map { device in
            let identifier = device["Identifier"] as? String ?? ""
            let vendor = device["Vendor"] as? String
            return DeviceMenuItem(
                device["Name"] as? String ?? "", action: "toggleUSBDevice:", isEnabled: !pending,
                isOn: attached[identifier] != nil, representedObject: device,
                toolTip: vendor?.isEmpty == false ? vendor : nil)
        }
        let listed = Set(devices.compactMap { $0["Identifier"] as? String })
        for identifier in attached.keys.sorted() where !listed.contains(identifier) {
            let name = attached[identifier] ?? ""
            items.append(
                DeviceMenuItem(
                    name + " (unplugged)", action: "toggleUSBDevice:", isOn: true,
                    representedObject: ["Identifier": identifier, "Name": name]))
        }
        if items.isEmpty { items.append(DeviceMenuItem("No USB Devices Connected to This Mac")) }
        return items
    }
}
