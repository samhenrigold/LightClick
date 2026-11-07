import Foundation

/// The events on QEMU's control connection that a session reacts to. Anything else is only logged.
@objc(VIMQMPEventKind)
public enum QMPEventKind: Int, Sendable {
    case other
    case reset
    case suspend
    case shutdown
    case wakeup
    /// The guest opened a drive's tray, which ejects what's in it.
    case trayOpened
    case deviceDeleted
    /// The process doing the paravirtual GPU's work has gone. The guest runs on with no display updates.
    case graphicsLost
}

@objc(VIMQMPEvent)
@objcMembers
public final class QMPEvent: NSObject {
    public let kind: QMPEventKind
    /// The device this is about, by its ID if it has one.
    public let device: String?
    /// The guest is restarting, which takes a new emulator. Anything else that shuts it down is it stopping.
    public let expectsGuestReboot: Bool

    @objc(initWithEvent:)
    public init(event: [String: Any]) {
        let data = event["data"] as? [String: Any]
        let name = event["event"] as? String
        let reason = data?["reason"] as? String
        expectsGuestReboot = name == "SHUTDOWN" && (reason == "guest-reset" || reason == "host-qmp-system-reset")
        switch name {
        case "RESET": kind = .reset
        case "SUSPEND": kind = .suspend
        case "SHUTDOWN": kind = .shutdown
        case "WAKEUP": kind = .wakeup
        case "DEVICE_DELETED": kind = .deviceDeleted
        case "PVG_HELPER_LOST": kind = .graphicsLost
        case "DEVICE_TRAY_MOVED": kind = data?["tray-open"] as? NSNumber == true as NSNumber ? .trayOpened : .other
        default: kind = .other
        }
        device =
            kind == .deviceDeleted
            ? data?["device"] as? String : (data?["id"] as? String) ?? (data?["device"] as? String)
    }
}

/// The notice shown over a guest while setup runs.
@objc(VIMSetupNoticeCopy)
@objcMembers
public final class SetupNoticeCopy: NSObject {
    public let title: String
    public let detail: String

    @objc(initWithAutomatic:automaticLogin:restarting:preMetalGuest:)
    public init(automatic: Bool, automaticLogin: Bool, restarting: Bool, preMetalGuest: Bool) {
        guard automatic else {
            title = "Installing Graphics Drivers…"
            detail =
                restarting
                ? "Your virtual Mac will restart to finish installing the graphics drivers. Sign in when it starts again. "
                    + "This may take up to 30 minutes."
                : "Keep your virtual Mac running while the graphics drivers install. This may take up to 30 minutes. If a "
                    + "restart is needed, you’ll be asked first."
            return
        }
        title = "Automatic Setup in Progress…"
        let waiting =
            preMetalGuest
            ? "The language selection screen is expected to stay visible during Automatic Setup."
            : "The first setup screen may stay visible during Automatic Setup."
        let restart =
            automaticLogin
            ? "Your virtual Mac will restart and sign in automatically when it’s ready."
            : preMetalGuest
                ? "Your virtual Mac will restart and sign in automatically this first time."
                : "Your virtual Mac will restart automatically when it’s ready. If you see the login screen, sign in with "
                    + "the account you chose."
        detail =
            "Please do not interact with Setup Assistant. \(waiting)\n\n\(restart) Setup may take up to 30 minutes."
    }
}
