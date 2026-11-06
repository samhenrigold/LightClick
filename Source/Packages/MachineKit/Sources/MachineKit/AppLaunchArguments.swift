import Foundation

/// What the app's command line asks for, for the options the app delegate handles. Machine commands and development
/// harness options all come through here.
public struct AppLaunchArguments: Sendable {
    public let arguments: [String]

    public init(_ arguments: [String]) {
        self.arguments = arguments
    }

    public func contains(_ option: String) -> Bool { arguments.contains(option) }

    /// The argument after the first `option`.
    public func value(after option: String) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// The same, for a path that must be absolute.
    public func absolutePath(after option: String) -> String? {
        value(after: option).flatMap { ($0 as NSString).isAbsolutePath ? $0 : nil }
    }

    // MARK: Machine commands

    public enum MachineAction: String, Sendable {
        case open = "--open-vm"
        case show = "--show-vm"
        case configure = "--configure-vm"
        case prepare = "--prepare-vm"
        case install = "--install-vm"
        case repair = "--repair-vm"
    }

    public struct MachineCommand: Equatable, Sendable {
        public var action: MachineAction
        /// Nil when the command line ended before one.
        public var path: String?
    }

    /// Each command takes the argument after it as its package, whatever that is.
    public var machineCommands: [MachineCommand] {
        var commands: [MachineCommand] = []
        var index = 1
        while index < arguments.count {
            defer { index += 1 }
            guard let action = MachineAction(rawValue: arguments[index]) else { continue }
            commands.append(
                MachineCommand(action: action, path: index + 1 < arguments.count ? arguments[index + 1] : nil))
            index += 1
        }
        return commands
    }

    /// Settings to save before a machine command runs, through the same path as Configure.
    public enum NetworkOverride: Equatable, Sendable {
        case invalid
        case settings(mode: String, bridgeInterface: String?)
    }

    public var networkOverride: NetworkOverride? {
        guard contains("--network-mode") else { return nil }
        guard let mode = value(after: "--network-mode"), ["shared", "host", "bridged"].contains(mode) else {
            return .invalid
        }
        return .settings(mode: mode, bridgeInterface: value(after: "--bridge-interface"))
    }

    /// Which part of the configuration window a `--configuration-pane` is in.
    public static func configurationSection(forPane pane: String) -> String {
        if ["File Sharing", "Remote Login", "Clipboard"].contains(pane) { return "Sharing" }
        return pane == "General" ? "General" : "Hardware"
    }

    // MARK: USB harness

    public struct USBProbe: Equatable, Sendable {
        public var locationID: UInt64
        public var vendorID: UInt64
        public var productID: UInt64
        public var output: String
        public var inUserSession: Bool
    }

    /// `--usb-interface-policy <location> <vendor> <product> <output>`, with decimal, hex or octal numbers. Nil unless all
    /// of it is valid and in range, and none of the numbers may be zero.
    public var usbProbe: USBProbe? {
        guard let index = arguments.firstIndex(of: "--usb-interface-policy"), index + 4 < arguments.count,
            let location = Self.number(arguments[index + 1], maximum: UInt64(UInt32.max)),
            let vendor = Self.number(arguments[index + 2], maximum: UInt64(UInt16.max)),
            let product = Self.number(arguments[index + 3], maximum: UInt64(UInt16.max)),
            (arguments[index + 4] as NSString).isAbsolutePath
        else { return nil }
        return USBProbe(
            locationID: location, vendorID: vendor, productID: product, output: arguments[index + 4],
            inUserSession: !contains("--usb-system-context"))
    }

    private static func number(_ text: String, maximum: UInt64) -> UInt64? {
        guard !text.isEmpty, !text.hasPrefix("-") else { return nil }
        return text.withCString { start -> UInt64? in
            var end: UnsafeMutablePointer<CChar>?
            errno = 0
            let value = strtoull(start, &end, 0)
            guard errno == 0, let end, end.pointee == 0, value != 0, value <= maximum else { return nil }
            return UInt64(value)
        }
    }
}

/// What asking to quit does, going by what's running. Doing it stays with the app delegate.
public enum QuitDecision: Equatable, Sendable {
    /// A confirmation is already on screen.
    case alreadyAsking
    /// A new disk is being made, which can't be interrupted.
    case waitForCreation
    case confirmShutdown
    case proceed

    public init(confirmationPending: Bool, creatingMachine: Bool, runningMachines: Bool, approved: Bool) {
        if confirmationPending {
            self = .alreadyAsking
        } else if creatingMachine {
            self = .waitForCreation
        } else if runningMachines && !approved {
            self = .confirmShutdown
        } else {
            self = .proceed
        }
    }
}
