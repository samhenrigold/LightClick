import Foundation
import InstallerKit
import Testing

@testable import MachineKit

@Suite struct ScreenSharingTests {
    private var sharing: MachineConfiguration {
        Fixture.configuration.setting(.screenSharingEnabled, true).setting(.screenSharingPort, 5901)
            .setting(.guest, "mavericks")
    }

    @Test func itIsOffByDefault() {
        #expect(ScreenSharing.connectionURL(for: Fixture.configuration.setting(.guest, "mavericks")) == nil)
        // Filling a legacy machine's forwarding defaults doesn't turn this one on.
        let legacy = Fixture.configuration.withNetworkDefaults { (2222, 1445) }
        #expect(legacy?.screenSharingEnabled == nil)
        #expect(legacy?.screenSharingPort == nil)
    }

    @Test func itConnectsOverLoopbackWithoutAUser() throws {
        let url = try #require(ScreenSharing.connectionURL(for: sharing))
        #expect(url.absoluteString == "vnc://127.0.0.1:5901")
        #expect(url.user == nil && url.password == nil)
    }

    @Test func thereIsNoConnectionWithoutTheForward() {
        #expect(ScreenSharing.connectionURL(for: sharing.setting(.screenSharingEnabled, false)) == nil)
        #expect(ScreenSharing.connectionURL(for: sharing.setting(.screenSharingPort, nil)) == nil)
        #expect(ScreenSharing.connectionURL(for: sharing.setting(.screenSharingPort, 80)) == nil)
        for mode: PropertyListValue in ["host", "bridged"] {
            #expect(ScreenSharing.connectionURL(for: sharing.setting(.networkMode, mode)) == nil)
            #expect(!ScreenSharing.isAvailable(on: sharing.setting(.networkMode, mode)))
        }
    }

    @Test func tigerHasNothingToEnable() {
        #expect(ScreenSharing.commands(enabling: true, on: .tiger) == nil)
        #expect(ScreenSharing.commands(enabling: false, on: .tiger) == nil)
        #expect(!ScreenSharing.isAvailable(on: sharing.setting(.guest, "tiger")))
        #expect(ScreenSharing.connectionURL(for: sharing.setting(.guest, "tiger")) == nil)
    }

    @Test(arguments: Guest.allCases.filter { $0 != .tiger })
    func everyOtherGuestCanBeTurnedOnAndOff(guest: Guest) throws {
        let on = try #require(ScreenSharing.commands(enabling: true, on: guest))
        let off = try #require(ScreenSharing.commands(enabling: false, on: guest))
        #expect(on != off)
        #expect(ScreenSharing.isAvailable(on: sharing.setting(.guest, .string(guest.rawValue))))
        // launchd's job only: no kickstart, so nothing that could carry a password or set one.
        for command in on + off + [ScreenSharing.verification] {
            #expect(command.executable == "/bin/launchctl")
            #expect(!command.arguments.contains { $0.localizedCaseInsensitiveContains("pw") })
        }
    }

    @Test func mojaveOnUsesTheServiceVerbs() throws {
        for guest in [Guest.mojave, .catalina, .bigSur] {
            #expect(try #require(ScreenSharing.commands(enabling: true, on: guest)).first?.arguments.first == "enable")
        }
        for guest in [Guest.leopard, .mavericks, .highSierra] {
            #expect(try #require(ScreenSharing.commands(enabling: true, on: guest)).first?.arguments.first == "load")
            #expect(try #require(ScreenSharing.commands(enabling: false, on: guest)).first?.arguments.first == "unload")
        }
    }

    @Test func itsSettingsAreChecked() {
        #expect(sharing.hasValidSettings)
        #expect(!sharing.setting(.screenSharingPort, nil).hasValidSettings)  // on, with no port
        #expect(!sharing.setting(.screenSharingPort, 1023).hasValidSettings)
        #expect(!sharing.setting(.screenSharingPort, 65536).hasValidSettings)
        #expect(!sharing.setting(.screenSharingPort, "5901").hasValidSettings)
        #expect(!sharing.setting(.screenSharingEnabled, 2).hasValidSettings)
        // QEMU can't bind one port twice, and off a stale port doesn't matter.
        #expect(!sharing.setting(.sshEnabled, true).setting(.sshPort, 5901).hasValidSettings)
        #expect(!sharing.setting(.fileSharingEnabled, true).setting(.fileSharingPort, 5901).hasValidSettings)
        #expect(sharing.setting(.sshEnabled, false).setting(.sshPort, 5901).hasValidSettings)
        #expect(
            sharing.setting(.screenSharingEnabled, false).setting(.sshEnabled, true).setting(.sshPort, 5901)
                .hasValidSettings)
    }

    @Test func itCanBeQueuedWhileRunning() throws {
        let queued = PendingChanges(values: ["Settings": ["ScreenSharingEnabled": true, "ScreenSharingPort": 5901]])
        let applied = try queued.applied(to: Fixture.configuration)
        #expect(applied.screenSharingEnabled == true)
        #expect(applied.screenSharingPort == 5901)
    }

    @Test func theBridgeEndsWithTheVerification() throws {
        let commands = try #require(MachineModelBridge.screenSharingCommands(guest: "mojave", enabling: true))
        #expect(
            commands == [
                ["/bin/launchctl", "enable", "system/com.apple.screensharing"],
                [
                    "/bin/launchctl", "bootstrap", "system",
                    "/System/Library/LaunchDaemons/com.apple.screensharing.plist"
                ],
                ["/bin/launchctl", "list", "com.apple.screensharing"]
            ])
        #expect(MachineModelBridge.screenSharingCommands(guest: "tiger", enabling: true) == nil)
        #expect(MachineModelBridge.screenSharingCommands(guest: 3, enabling: true) == nil)
    }
}
