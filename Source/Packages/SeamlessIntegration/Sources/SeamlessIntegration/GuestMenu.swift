import AppKit

/// One item of a guest app's menu, as Accessibility reports it. This is the same tree `seamless-integration-guest menu`
/// prints.
public struct GuestMenuItem: Codable, Hashable, Sendable {
    public var title: String
    public var isEnabled = true
    /// `AXMenuItemMarkChar`: a check mark, a dash for mixed state, or nothing.
    public var mark: String?
    /// `AXMenuItemCmdChar`, or empty when the item has only `virtualKey` or `glyph`.
    public var key: String?
    public var virtualKey: Int?
    /// `AXMenuItemCmdModifiers`.
    public var modifiers: Int = 0
    public var children: [GuestMenuItem]?
    /// `AXMenuItemPrimaryUIElement` was set: it replaces the item before it while Option is held.
    public var isAlternate: Bool?

    public init(
        title: String, isEnabled: Bool = true, mark: String? = nil, key: String? = nil, virtualKey: Int? = nil,
        modifiers: Int = 0, children: [GuestMenuItem]? = nil, isAlternate: Bool? = nil
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.mark = mark
        self.key = key
        self.virtualKey = virtualKey
        self.modifiers = modifiers
        self.children = children
        self.isAlternate = isAlternate
    }

    /// An untitled leaf is how Accessibility reports a separator.
    public var isSeparator: Bool { title.isEmpty && children == nil && key == nil && virtualKey == nil }

    /// What the proxy's menu bar shows: everything but the Apple menu, which stays the host's own. The guest's would offer
    /// its own About This Mac and Shut Down, which belong in the guest's whole-desktop window, not beside host windows.
    public static func hostMenuBar(from items: [GuestMenuItem]) -> [GuestMenuItem] {
        items.first?.title == "Apple" ? Array(items.dropFirst()) : items
    }

    public var keyEquivalent: String {
        if let key, !key.isEmpty { return key.lowercased() == key ? key : key.lowercased() }
        return virtualKey.flatMap { Self.functionKeys[$0] } ?? ""
    }

    /// `AXMenuItemCmdModifiers`: 1 Shift, 2 Option, 4 Control, 8 no Command. An uppercase letter in a `CmdChar` doesn't
    /// imply Shift in Accessibility, unlike a key equivalent set in `NSMenuItem`, so `key` is folded above.
    public var keyModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & 1 != 0 { flags.insert(.shift) }
        if modifiers & 2 != 0 { flags.insert(.option) }
        if modifiers & 4 != 0 { flags.insert(.control) }
        if modifiers & 8 == 0 { flags.insert(.command) }
        return flags
    }

    public var state: NSControl.StateValue {
        switch mark {
        case nil, "": .off
        case "-": .mixed
        default: .on
        }
    }

    static let functionKeys: [Int: String] = [
        0x24: "\r", 0x30: "\t", 0x33: "\u{8}", 0x35: "\u{1b}", 0x75: "\u{7f}", 0x7A: f(NSF1FunctionKey),
        0x78: f(NSF2FunctionKey), 0x63: f(NSF3FunctionKey), 0x76: f(NSF4FunctionKey), 0x60: f(NSF5FunctionKey),
        0x61: f(NSF6FunctionKey), 0x62: f(NSF7FunctionKey), 0x64: f(NSF8FunctionKey), 0x65: f(NSF9FunctionKey),
        0x6D: f(NSF10FunctionKey), 0x67: f(NSF11FunctionKey), 0x6F: f(NSF12FunctionKey),
        0x7B: f(NSLeftArrowFunctionKey), 0x7C: f(NSRightArrowFunctionKey), 0x7D: f(NSDownArrowFunctionKey),
        0x7E: f(NSUpArrowFunctionKey)
    ]

    private static func f(_ key: Int) -> String { String(UnicodeScalar(UInt32(key)).map(Character.init) ?? " ") }
}

/// A menu that knows where it is in the guest's, so opening it can ask for just that subtree.
public final class GuestMenu: NSMenu {
    public var path: [String] = []
}

/// Applies guest menu trees to `NSMenu`s, reusing items so a menu the user has open updates in place.
@MainActor
public struct GuestMenuMirror {
    public let target: AnyObject
    public let action: Selector

    public init(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
    }

    /// Each item's `representedObject` is its path, as `[String]`, which is what the guest's `AXPress` walks.
    public func apply(_ items: [GuestMenuItem], to menu: NSMenu, path: [String] = []) {
        if let menu = menu as? GuestMenu { menu.path = path }
        // Mirrored state is the guest's, not AppKit's.
        menu.autoenablesItems = false
        while menu.items.count > items.count { menu.removeItem(at: menu.items.count - 1) }
        for (index, item) in items.enumerated() {
            if index < menu.items.count, menu.items[index].isSeparatorItem != item.isSeparator {
                menu.removeItem(at: index)
                menu.insertItem(makeItem(item), at: index)
            } else if index == menu.items.count {
                menu.addItem(makeItem(item))
            }
            update(menu.items[index], from: item, path: path + [item.title])
        }
    }

    private func makeItem(_ item: GuestMenuItem) -> NSMenuItem {
        item.isSeparator ? .separator() : NSMenuItem()
    }

    private func update(_ menuItem: NSMenuItem, from item: GuestMenuItem, path: [String]) {
        guard !item.isSeparator else { return }
        menuItem.title = item.title
        menuItem.isEnabled = item.isEnabled
        menuItem.state = item.state
        menuItem.keyEquivalent = item.keyEquivalent
        // An alternate may have only modifiers, like System Information under About This Mac.
        let usesModifiers = !item.keyEquivalent.isEmpty || item.isAlternate == true
        menuItem.keyEquivalentModifierMask = usesModifiers ? item.keyModifiers : []
        menuItem.representedObject = path
        menuItem.isAlternate = item.isAlternate == true
        if let children = item.children {
            let submenu = menuItem.submenu ?? GuestMenu(title: item.title)
            submenu.title = item.title
            submenu.delegate = target as? any NSMenuDelegate
            apply(children, to: submenu, path: path)
            menuItem.submenu = submenu
            menuItem.target = nil
            menuItem.action = nil
        } else {
            menuItem.submenu = nil
            menuItem.target = target
            menuItem.action = action
        }
    }
}
