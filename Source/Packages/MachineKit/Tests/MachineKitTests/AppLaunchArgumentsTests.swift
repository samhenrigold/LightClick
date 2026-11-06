import Testing

@testable import MachineKit

@Suite struct AppLaunchArgumentsTests {
    private func arguments(_ list: String...) -> AppLaunchArguments { AppLaunchArguments(["app"] + list) }

    @Test func aValueIsTheArgumentAfterTheFirstOption() {
        #expect(arguments("--x", "1", "--x", "2").value(after: "--x") == "1")
        #expect(arguments("--x").value(after: "--x") == nil)
        #expect(arguments("--y").value(after: "--x") == nil)
        #expect(arguments("--x", "/a").absolutePath(after: "--x") == "/a")
        #expect(arguments("--x", "a").absolutePath(after: "--x") == nil)
    }

    @Test func machineCommandsTakeTheirPackage() {
        let commands = arguments("--open-vm", "/a", "--other", "--show-vm", "/b", "--repair-vm").machineCommands
        #expect(
            commands == [
                .init(action: .open, path: "/a"), .init(action: .show, path: "/b"), .init(action: .repair, path: nil)
            ])
    }

    @Test func aPackagePathThatLooksLikeACommandIsStillThePath() {
        #expect(arguments("--open-vm", "--show-vm").machineCommands == [.init(action: .open, path: "--show-vm")])
    }

    @Test func theFirstArgumentIsTheProgram() {
        #expect(AppLaunchArguments(["--open-vm", "/a"]).machineCommands.isEmpty)
    }

    @Test func networkOverrides() {
        #expect(arguments().networkOverride == nil)
        #expect(arguments("--network-mode").networkOverride == .invalid)
        #expect(arguments("--network-mode", "wifi").networkOverride == .invalid)
        #expect(arguments("--network-mode", "host").networkOverride == .settings(mode: "host", bridgeInterface: nil))
        #expect(
            arguments("--network-mode", "bridged", "--bridge-interface", "en0").networkOverride
                == .settings(mode: "bridged", bridgeInterface: "en0"))
    }

    @Test func configurationPanesAreInTheirSections() {
        #expect(AppLaunchArguments.configurationSection(forPane: "Clipboard") == "Sharing")
        #expect(AppLaunchArguments.configurationSection(forPane: "General") == "General")
        #expect(AppLaunchArguments.configurationSection(forPane: "Sound") == "Hardware")
    }

    @Test func aUSBProbeReadsAnyBase() {
        let probe = arguments("--usb-interface-policy", "0x14100000", "1452", "010", "/out").usbProbe
        #expect(probe?.locationID == 0x1410_0000)
        #expect(probe?.vendorID == 1452)
        #expect(probe?.productID == 8)
        #expect(probe?.output == "/out")
        #expect(probe?.inUserSession == true)
        #expect(
            arguments("--usb-interface-policy", "1", "2", "3", "/o", "--usb-system-context").usbProbe?.inUserSession
                == false)
    }

    @Test(arguments: [
        ["0", "2", "3", "/o"], ["1", "0", "3", "/o"], ["1", "2", "0", "/o"], ["-1", "2", "3", "/o"],
        ["", "2", "3", "/o"],
        ["1x", "2", "3", "/o"], ["4294967296", "2", "3", "/o"], ["1", "65536", "3", "/o"], ["1", "2", "65536", "/o"],
        ["99999999999999999999999", "2", "3", "/o"], ["1", "2", "3", "relative"], ["1", "2", "3"]
    ])
    func aBadUSBProbeIsIgnored(values: [String]) {
        #expect(AppLaunchArguments(["app", "--usb-interface-policy"] + values).usbProbe == nil)
    }

    @Test func quitting() {
        func decide(pending: Bool = false, creating: Bool = false, running: Bool = false, approved: Bool = false)
            -> QuitDecision
        {
            QuitDecision(
                confirmationPending: pending, creatingMachine: creating, runningMachines: running, approved: approved)
        }
        #expect(decide() == .proceed)
        #expect(decide(running: true) == .confirmShutdown)
        #expect(decide(running: true, approved: true) == .proceed)
        #expect(decide(creating: true, running: true, approved: true) == .waitForCreation)
        #expect(decide(pending: true, creating: true) == .alreadyAsking)
    }
}
