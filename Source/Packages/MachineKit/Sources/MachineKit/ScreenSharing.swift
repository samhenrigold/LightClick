import Foundation
import InstallerKit

/// What "Share Screen" does to a guest and where it connects. The guest's stock `screensharingd` does the work and asks
/// for one of its own accounts, so nothing here holds a credential.
public enum ScreenSharing {
    public struct GuestCommand: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
    }

    private static let launchctl = "/bin/launchctl"
    private static let label = "com.apple.screensharing"
    private static let job = "/System/Library/LaunchDaemons/com.apple.screensharing.plist"

    /// What to run, in order, as root in the guest. Nil for Tiger, which has no `screensharingd`.
    ///
    /// Always the launchd job, never `kickstart`: that turns on Remote Management for a named user rather than Screen
    /// Sharing, may not grant control from Mojave on (guest-capabilities.md, question 5), and its way of avoiding the
    /// account prompt is a VNC password someone has to keep. From Mojave on, this is the route account setup already
    /// takes for sshd.
    ///
    /// Their exit statuses don't decide anything, since each refuses a job already in the state it asks for. Run
    /// `verification` after them.
    public static func commands(enabling: Bool, on guest: Guest) -> [GuestCommand]? {
        switch guest {
        case .tiger:
            return nil
        case .leopard, .snowLeopard, .lion, .mountainLion, .mavericks, .yosemite, .elCapitan, .sierra, .highSierra:
            return [GuestCommand(executable: launchctl, arguments: [enabling ? "load" : "unload", "-w", job])]
        case .mojave, .catalina, .bigSur:
            let service = "system/\(label)"
            return enabling
                ? [
                    GuestCommand(executable: launchctl, arguments: ["enable", service]),
                    GuestCommand(executable: launchctl, arguments: ["bootstrap", "system", job])
                ]
                : [
                    GuestCommand(executable: launchctl, arguments: ["bootout", service]),
                    GuestCommand(executable: launchctl, arguments: ["disable", service])
                ]
        }
    }

    /// Exits zero exactly when the job is loaded.
    public static let verification = GuestCommand(executable: launchctl, arguments: ["list", label])

    /// Whether this machine can offer it at all. The forward only exists on the shared network, the one with a host side.
    public static func isAvailable(on configuration: MachineConfiguration) -> Bool {
        guard let guest = configuration.guest else { return false }
        return commands(enabling: true, on: guest) != nil && configuration.networkMode == .shared
    }

    /// Where the host connects, given the configuration QEMU was started with. Nil unless that started the forward.
    /// There's no user in it, so the host's client asks.
    public static func connectionURL(for configuration: MachineConfiguration) -> URL? {
        guard isAvailable(on: configuration), configuration.screenSharingEnabled == true,
            let port = configuration.screenSharingPort, (1024...65535).contains(port)
        else { return nil }
        return URL(string: "vnc://127.0.0.1:\(port)")
    }
}
