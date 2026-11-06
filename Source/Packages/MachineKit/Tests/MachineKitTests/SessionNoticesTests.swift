import Foundation
import Testing

@testable import MachineKit

@Suite struct QMPEventTests {
    private func event(_ name: String, _ data: [String: Any] = [:]) -> QMPEvent {
        QMPEvent(event: ["event": name, "data": data])
    }

    @Test func kinds() {
        #expect(event("RESET").kind == .reset)
        #expect(event("SUSPEND").kind == .suspend)
        #expect(event("WAKEUP").kind == .wakeup)
        #expect(event("POWERDOWN").kind == .other)
        #expect(QMPEvent(event: [:]).kind == .other)
    }

    @Test(arguments: [("guest-reset", true), ("host-qmp-system-reset", true), ("guest-shutdown", false)])
    func onlyAResetShutdownIsAReboot(reason: String, reboot: Bool) {
        let shutdown = event("SHUTDOWN", ["reason": reason])
        #expect(shutdown.kind == .shutdown)
        #expect(shutdown.expectsGuestReboot == reboot)
    }

    @Test func aReasonOnAnotherEventIsNoReboot() {
        #expect(!event("RESET", ["reason": "guest-reset"]).expectsGuestReboot)
        #expect(!event("SHUTDOWN").expectsGuestReboot)
    }

    @Test func aTrayOnlyCountsWhenOpening() {
        #expect(event("DEVICE_TRAY_MOVED", ["tray-open": true]).kind == .trayOpened)
        #expect(event("DEVICE_TRAY_MOVED", ["tray-open": false]).kind == .other)
        #expect(event("DEVICE_TRAY_MOVED").kind == .other)
    }

    @Test func aTrayNamesItsDeviceByIDFirst() {
        #expect(event("DEVICE_TRAY_MOVED", ["tray-open": true, "id": "a", "device": "b"]).device == "a")
        #expect(event("DEVICE_TRAY_MOVED", ["tray-open": true, "device": "b"]).device == "b")
        #expect(event("DEVICE_DELETED", ["device": "usb-1", "path": "/x"]).device == "usb-1")
    }
}

@Suite struct SetupNoticeCopyTests {
    @Test func driversSayWhetherARestartIsComing() {
        let later = SetupNoticeCopy(automatic: false, automaticLogin: true, restarting: false, preMetalGuest: true)
        #expect(later.title == "Installing Graphics Drivers…")
        #expect(later.detail.hasSuffix("you’ll be asked first."))
        let now = SetupNoticeCopy(automatic: false, automaticLogin: false, restarting: true, preMetalGuest: false)
        #expect(now.detail.hasPrefix("Your virtual Mac will restart to finish"))
    }

    @Test func automaticSetupDependsOnTheGuestAndLogin() {
        let old = SetupNoticeCopy(automatic: true, automaticLogin: false, restarting: false, preMetalGuest: true)
        #expect(old.title == "Automatic Setup in Progress…")
        #expect(old.detail.contains("language selection screen"))
        #expect(old.detail.contains("sign in automatically this first time"))
        let new = SetupNoticeCopy(automatic: true, automaticLogin: false, restarting: false, preMetalGuest: false)
        #expect(new.detail.contains("first setup screen"))
        #expect(new.detail.contains("sign in with the account you chose"))
        let login = SetupNoticeCopy(automatic: true, automaticLogin: true, restarting: false, preMetalGuest: false)
        #expect(login.detail.contains("sign in automatically when it’s ready"))
        #expect(login.detail.hasSuffix(" Setup may take up to 30 minutes."))
    }
}
