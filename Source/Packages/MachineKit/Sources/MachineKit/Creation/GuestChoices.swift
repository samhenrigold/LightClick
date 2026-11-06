import Foundation
import InstallerKit

/// The version chooser's two columns of seven rows: the guests, then the row recommending newer systems.
public enum GuestGrid {
    public enum Move: Sendable {
        case up, down, left, right
    }

    public static let rowsPerColumn = 7

    /// The row an arrow key lands on. Rows run down the first column, then down the second.
    public static func index(moving move: Move, from index: Int, count: Int) -> Int {
        switch move {
        case .down: index + 1 < count ? index + 1 : index
        case .up: index > 0 ? index - 1 : index
        case .left: index >= rowsPerColumn ? index - rowsPerColumn : index
        case .right: index < rowsPerColumn && index + rowsPerColumn < count ? index + rowsPerColumn : index
        }
    }
}

/// Where to send someone who wants a release this app doesn't run.
public struct NewerSystemsRecommendation: Sendable {
    public struct App: Equatable, Sendable {
        public let name: String
        public let imageName: String
        public let url: URL
    }

    public let opening = "You can virtualize macOS Monterey 12 and later using "
    public let apps: [App]
    public let closing: String

    public init(appleSilicon: Bool) {
        if appleSilicon {
            apps = [
                App(
                    name: "VirtualBuddy", imageName: "RecommendedVirtualBuddy",
                    url: URL(string: "https://github.com/insidegui/VirtualBuddy")!),
                App(name: "UTM", imageName: "RecommendedUTM", url: URL(string: "https://getutm.app")!),
                App(
                    name: "Virtual Mac on iPad", imageName: "RecommendedVirtualMac",
                    url: URL(string: "https://github.com/nfzerox/VirtualMacOniPad")!)
            ]
            closing = ", then run Intel-based apps using Rosetta."
        } else {
            apps = [
                App(
                    name: "Parallels Desktop 26", imageName: "RecommendedParallels",
                    url: URL(string: "https://www.parallels.com/products/desktop/")!)
            ]
            closing = "."
        }
    }

    /// The words between the previous app and `apps[index]`.
    public func separator(before index: Int) -> String {
        index == 0 ? "" : index == apps.count - 1 ? ", or " : ", "
    }
}

/// `--create-guest guest --name name [--cpu n] [--memory-gb n] [--disk-gb n] [--account-name name] --account-password p`.
/// `main` has already checked the flags; this is only their meaning.
public struct CreateGuestArguments: Equatable, Sendable {
    public let guestName: String?
    public let name: String
    public let cores: String?
    public let memory: String?
    public let disk: String?
    public let accountName: String?
    public let accountPassword: String?

    /// `arguments[0]` is the executable. Pairs follow, and an unpaired last argument is ignored.
    public init(arguments: [String]) {
        var options: [String: String] = [:]
        for index in stride(from: 1, to: arguments.count - 1, by: 2) {
            options[arguments[index]] = arguments[index + 1]
        }
        guestName = options["--create-guest"]
        name = options["--name"] ?? ""
        cores = options["--cpu"]
        memory = options["--memory-gb"]
        disk = options["--disk-gb"]
        accountName = options["--account-name"]
        accountPassword = options["--account-password"]
    }

    public var guest: Guest? { guestName.flatMap(Guest.init(rawValue:)) }

    public static var unknownGuestMessage: String {
        "Unknown guest. Use one of: \(Guest.allCases.map(\.rawValue).joined(separator: ", "))."
    }
}
