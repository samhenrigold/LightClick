import Foundation
import Testing

@testable import MachineKit

@Suite struct DeviceMenusTests {
    private func titles(_ items: [DeviceMenuItem]) -> [String] { items.map { $0.isSeparator ? "-" : $0.title } }

    @Test func noImagesOffersOneToConnect() {
        let items = DeviceMenus.images([], slotCount: 4)
        #expect(titles(items) == ["No Images Connected", "-", "Connect Image…", "-", "Configure…"])
        #expect(!items[0].isEnabled)
    }

    @Test func oneImageShowsItsNameAndADisconnect() {
        let items = DeviceMenus.images([["Path": "/x/a.iso", "Slot": 2]], slotCount: 4)
        #expect(titles(items) == ["a.iso", "Disconnect", "-", "Connect Image…", "-", "Configure…"])
        #expect(!items[0].isEnabled)
        #expect(items[1].action == "ejectOpticalMedia:")
        #expect(items[1].representedObject as? Int == 2)
    }

    @Test func fullDrivesOfferNoMore() {
        let images = (0..<4).map { ["Path": "/\($0).iso", "Slot": $0] as [String: Any] }
        let items = DeviceMenus.images(images, slotCount: 4)
        #expect(!titles(items).contains("Connect Image…"))
        #expect(items[1].title == "Disconnect “1.iso”")
        #expect(items[1].symbol == "opticaldisc")
    }

    private func network(
        connected: Bool = true, mode: String = "shared", running: Bool = true, addresses: [String]? = nil,
        sharing: Bool = false, sharingOn: Bool = false
    ) -> [DeviceMenuItem] {
        DeviceMenus.network(
            connected: connected, mode: mode, running: running, addresses: addresses, screenSharing: sharing,
            screenSharingOn: sharingOn)
    }

    @Test func theNetworkMenuChecksTheConnectedMode() {
        let items = network(mode: "bridged")
        #expect(
            titles(items) == [
                "Disconnect", "-", "Shared Network (Recommended)", "Host-Only Network", "Bridged Network", "-",
                "Configure…"
            ])
        #expect(items.filter(\.isOn).map(\.title) == ["Bridged Network"])
        #expect(items[4].tag == 3)
    }

    @Test func aDisconnectedNetworkChecksOnlyDisconnect() {
        let items = network(connected: false, addresses: ["1.2.3.4"])
        #expect(items.filter(\.isOn).map(\.title) == ["Disconnect"])
        #expect(!titles(items).contains("1.2.3.4"))
    }

    @Test func addressesNeedARunningGuest() {
        #expect(!titles(network(running: false, addresses: ["1.2.3.4"])).contains("1.2.3.4"))
        #expect(!titles(network(addresses: [])).contains("IP Addresses:"))
        let items = network(addresses: ["1.2.3.4"])
        let address = items.first { $0.title == "1.2.3.4" }
        #expect(address?.representedObject as? String == "1.2.3.4")
        #expect(items.first { $0.title == "IP Addresses:" }?.isEnabled == false)
    }

    @Test func screenSharingAppearsOnlyWhereOffered() {
        #expect(!titles(network()).contains("Share Screen"))
        let items = network(sharing: true, sharingOn: true)
        #expect(items.first { $0.title == "Share Screen" }?.isOn == true)
        #expect(titles(items).suffix(4) == ["Share Screen", "Open Screen Sharing…", "-", "Configure…"])
    }

    @Test func soundChecksTheSelection() {
        let items = DeviceMenus.sound(
            input: true, selected: "b", devices: [["Name": "A", "UID": "a"], ["Name": "B", "UID": "b"]])
        #expect(titles(items) == ["Default", "A", "B", "-", "Disconnected"])
        #expect(items.filter(\.isOn).map(\.title) == ["B"])
        let choice = items[4].representedObject as? [String: Any]
        #expect(choice?["UID"] as? String == "disabled")
        #expect(choice?["Input"] as? Bool == true)
        #expect(
            titles(DeviceMenus.sound(input: false, selected: "default", devices: nil)) == [
                "Default", "-", "Disconnected"
            ])
    }

    @Test func keyboardShortcutsCarryTheirKeys() {
        let items = DeviceMenus.keyboardMenu
        #expect(items.count == 11)
        #expect(items[0].representedObject as? [String] == ["meta_l", "alt", "esc"])
        #expect(items.allSatisfy { $0.action == "sendMenuShortcut:" })
    }

    @Test func usbListsTheHostsDevicesAndTheUnplugged() {
        let devices: [[String: Any]] = [
            ["Identifier": "a", "Name": "Disk", "Vendor": "Acme"], ["Identifier": "b", "Name": "Key", "Vendor": ""]
        ]
        let items = DeviceMenus.usb(devices: devices, attached: ["a": "Disk", "z": "Gone"], pending: false)
        #expect(titles(items) == ["Disk", "Key", "Gone (unplugged)"])
        #expect(items.map(\.isOn) == [true, false, true])
        #expect(items[0].toolTip == "Acme")
        #expect(items[1].toolTip == nil)
        #expect((items[2].representedObject as? [String: String]) == ["Identifier": "z", "Name": "Gone"])
    }

    @Test func aPendingChangeHoldsOnlyHostDevices() {
        let items = DeviceMenus.usb(
            devices: [["Identifier": "a", "Name": "Disk"]], attached: ["z": "Gone"], pending: true)
        #expect(items.map(\.isEnabled) == [false, true])
    }

    @Test func nothingToListSaysSo() {
        let items = DeviceMenus.usb(devices: [], attached: nil, pending: false)
        #expect(titles(items) == ["No USB Devices Connected to This Mac"])
        #expect(!items[0].isEnabled)
    }
}
