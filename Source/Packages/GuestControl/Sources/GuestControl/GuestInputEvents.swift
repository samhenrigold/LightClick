import Foundation

/// QMP's names for each Mac virtual key code.
private let qcodes: [UInt16: String] = [
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 10: "less", 11: "b", 12: "q",
    13: "w",
    14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "equal", 25: "9",
    26: "7", 27: "minus", 28: "8", 29: "0", 30: "bracket_right", 31: "o", 32: "u", 33: "bracket_left", 34: "i", 35: "p",
    36: "ret", 37: "l", 38: "j", 39: "apostrophe", 40: "k", 41: "semicolon", 42: "backslash", 43: "comma", 44: "slash",
    45: "n", 46: "m", 47: "dot", 48: "tab", 49: "spc", 50: "grave_accent", 51: "backspace", 53: "esc", 54: "meta_r",
    55: "meta_l", 56: "shift", 58: "alt", 59: "ctrl", 60: "shift_r", 61: "alt_r", 62: "ctrl_r", 64: "f17",
    65: "kp_decimal", 67: "kp_multiply", 69: "kp_add", 71: "num_lock", 75: "kp_divide", 76: "kp_enter",
    78: "kp_subtract",
    79: "f18", 80: "f19", 81: "kp_equals", 82: "kp_0", 83: "kp_1", 84: "kp_2", 85: "kp_3", 86: "kp_4", 87: "kp_5",
    88: "kp_6", 89: "kp_7", 90: "f20", 91: "kp_8", 92: "kp_9", 93: "yen", 94: "ro", 95: "kp_comma", 96: "f5", 97: "f6",
    98: "f7", 99: "f3", 100: "f8", 101: "f9", 102: "lang2", 103: "f11", 104: "lang1", 105: "f13", 106: "f16",
    107: "f14",
    109: "f10", 111: "f12", 113: "f15", 114: "insert", 115: "home", 116: "pgup", 117: "delete", 118: "f4", 119: "end",
    120: "f2", 121: "pgdn", 122: "f1", 123: "left", 124: "right", 125: "down", 126: "up"
]

/// One modifier: AppKit's aggregate flag and, for each side, its QMP key, device flag and key code.
private struct Modifier {
    let flag: UInt
    let left: (key: String, mask: UInt, code: UInt16)
    let right: (key: String, mask: UInt, code: UInt16)
}

private let modifiers = [
    Modifier(flag: 1 << 20, left: ("meta_l", 0x8, 55), right: ("meta_r", 0x10, 54)),
    Modifier(flag: 1 << 17, left: ("shift", 0x2, 56), right: ("shift_r", 0x4, 60)),
    Modifier(flag: 1 << 18, left: ("ctrl", 0x1, 59), right: ("ctrl_r", 0x2000, 62)),
    Modifier(flag: 1 << 19, left: ("alt", 0x20, 58), right: ("alt_r", 0x40, 61))
]
private let commandFlag: UInt = 1 << 20
private let capsLockCode: UInt16 = 57

private func keyEvent(_ key: String, down: Bool) -> [String: Any] {
    ["type": "key", "data": ["down": down, "key": ["type": "qcode", "data": key]]]
}

private func buttonEvent(_ button: String, down: Bool) -> [String: Any] {
    ["type": "btn", "data": ["button": button, "down": down]]
}

/// Turns a window's keyboard, pointer and wheel events into QMP input events, and keeps what's held so that nothing stays
/// down in the guest after macOS swallows a key-up. `modifierFlags` are `NSEvent`'s, device bits included.
@MainActor @objc(VIMGuestInputEvents)
public final class GuestInputEvents: NSObject {
    private let emit: ([[String: Any]]) -> Void
    @objc public private(set) var pressedKeys: Set<String> = []
    private var wheelRemainder = (x: 0.0, y: 0.0)

    @objc(initWithEmit:)
    public init(emit: @escaping ([[String: Any]]) -> Void) {
        self.emit = emit
    }

    private func send(_ key: String, down: Bool) {
        guard pressedKeys.contains(key) != down else { return }
        emit([keyEvent(key, down: down)])
        if down {
            pressedKeys.insert(key)
        } else {
            pressedKeys.remove(key)
        }
    }

    /// A key equivalent or a focus change can arrive with no `flagsChanged`. This reconciles the aggregate flags without
    /// discarding a known right-hand modifier.
    @objc(synchronizeModifiers:)
    public func synchronizeModifiers(_ flags: UInt) {
        for modifier in modifiers {
            let down = flags & modifier.flag != 0
            if down && flags & (modifier.left.mask | modifier.right.mask) != 0 {
                send(modifier.left.key, down: flags & modifier.left.mask != 0)
                send(modifier.right.key, down: flags & modifier.right.mask != 0)
            } else if down {
                if !pressedKeys.contains(modifier.left.key) && !pressedKeys.contains(modifier.right.key) {
                    send(modifier.left.key, down: true)
                }
            } else {
                send(modifier.left.key, down: false)
                send(modifier.right.key, down: false)
            }
        }
    }

    @objc(keyDown:repeating:modifiers:)
    public func keyDown(_ code: UInt16, repeating: Bool, modifiers flags: UInt) {
        synchronizeModifiers(flags)
        if let key = qcodes[code], !repeating { send(key, down: true) }
    }

    @objc(keyUp:modifiers:)
    public func keyUp(_ code: UInt16, modifiers flags: UInt) {
        synchronizeModifiers(flags)
        if let key = qcodes[code] { send(key, down: false) }
    }

    /// AppKit doesn't reliably deliver a key-up for a command equivalent it consumed, so this is both.
    @objc(keyEquivalent:modifiers:)
    public func keyEquivalent(_ code: UInt16, modifiers flags: UInt) {
        synchronizeModifiers(flags)
        if let key = qcodes[code] {
            send(key, down: true)
            send(key, down: false)
        }
    }

    @objc(flagsChanged:modifiers:)
    public func flagsChanged(_ code: UInt16, modifiers flags: UInt) {
        let hadCommand = pressedKeys.contains("meta_l") || pressedKeys.contains("meta_r")
        if code == capsLockCode {
            send("caps_lock", down: true)
            send("caps_lock", down: false)
            return
        }
        // A synthetic or focus notification can have key code 0, which isn't an A key transition: only real modifier
        // key codes may be toggled here.
        if let modifier = modifiers.first(where: { $0.left.code == code || $0.right.code == code }),
            flags & (modifier.left.mask | modifier.right.mask) == 0,
            let key = qcodes[code]
        {
            // Hardware events carry per-side bits. Synthetic aggregate-only ones keep this fallback, but a cleared
            // aggregate is always an up, never a toggle that could make up a held modifier.
            send(key, down: flags & modifier.flag != 0 && !pressedKeys.contains(key))
        }
        synchronizeModifiers(flags)
        if hadCommand && flags & commandFlag == 0 {
            // macOS can consume a command shortcut's key-up, and its ordinary key mustn't stay held with Command gone.
            let held = modifiers.flatMap { [$0.left.key, $0.right.key] }
            for key in pressedKeys where !held.contains(key) { send(key, down: false) }
        }
    }

    /// One ordered request, not a round trip for every held key and button, when a menu opens or capture is released.
    @objc public func releaseAll() {
        var events = pressedKeys.map { keyEvent($0, down: false) }
        pressedKeys.removeAll()
        events += ["left", "right", "middle"].map { buttonEvent($0, down: false) }
        emit(events)
    }

    /// `x` and `y` are the pointer's position in the presented frame, from 0 to 1, with `y` already measured from the top.
    @objc(pointerAtX:y:)
    public func pointer(x: Double, y: Double) {
        func tablet(_ value: Double) -> Int { value.isNaN ? 0 : Int(max(0, min(1, value)) * 32767) }
        emit([
            ["type": "abs", "data": ["axis": "x", "value": tablet(x)]],
            ["type": "abs", "data": ["axis": "y", "value": tablet(y)]]
        ])
    }

    @objc(button:down:)
    public func button(_ button: String, down: Bool) {
        emit([buttonEvent(button, down: down)])
    }

    @objc public func resetWheel() {
        wheelRemainder = (0, 0)
    }

    /// `x` and `y` are in wheel detents, in the device's physical direction. The guest's macOS applies its own natural
    /// scrolling setting, so direction is sent once. Fractions are kept, since rounding every tiny Magic Mouse event up
    /// would amplify motion and jitter.
    @objc(scrollX:y:)
    public func scroll(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        var events: [[String: Any]] = []
        // Anomalous or accelerated input is bounded to one request of at most 64 events, with no backlog that would go on
        // scrolling after the gesture ends.
        func detents(_ value: Double, positive: String, negative: String) -> Double {
            let total = max(-16, min(16, value))
            let count = floor(abs(total) + 1e-9)
            let button = total > 0 ? positive : negative
            for _ in 0..<Int(count) {
                events.append(buttonEvent(button, down: true))
                events.append(buttonEvent(button, down: false))
            }
            let remainder = total - copysign(count, total)
            return abs(remainder) < 1e-9 ? 0 : remainder
        }
        wheelRemainder = (
            detents(wheelRemainder.x + x, positive: "wheel-left", negative: "wheel-right"),
            detents(wheelRemainder.y + y, positive: "wheel-up", negative: "wheel-down")
        )
        if !events.isEmpty { emit(events) }
    }
}
