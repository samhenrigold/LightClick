import Foundation
import Testing

@testable import GuestControl

/// Answers commands from a script, in order, and records them.
@MainActor
final class ScriptedControl: ControlCommands {
    struct Sent {
        let command: String
        let arguments: [String: Any]
    }

    var sent: [Sent] = []
    var replies: [(String, Result<Any, NSError>)] = []

    func run(_ command: String, arguments: [String: Any], completion: @escaping @MainActor (Any?, NSError?) -> Void) {
        sent.append(Sent(command: command, arguments: arguments))
        let reply = replies.firstIndex { $0.0 == command }.map { replies.remove(at: $0).1 }
        switch reply {
        case .failure(let error): completion(nil, error)
        case .success(let value): completion(value, nil)
        case nil: completion(command == "human-monitor-command" ? "OK\r\n" : [String: Any](), nil)
        }
    }

    var commands: [String] { sent.map(\.command) }
}

private func error(_ message: String) -> NSError {
    NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

@MainActor
struct ImageDrivesTests {
    private let control = ScriptedControl()
    private var drives: ImageDrives { ImageDrives(control: control, bus: "xhci.0", basePort: 1, slotCount: 4) }

    private func change(_ drives: ImageDrives, _ path: String, format: String? = "raw", slot: Int) async -> NSError? {
        await withCheckedContinuation { continuation in
            drives.change(path: path, format: format, slot: slot) { continuation.resume(returning: $0) }
        }
    }

    @Test func deviceNamesFollowSlotAndFormat() {
        #expect(ImageDrives.deviceName(slot: 0, format: "raw") == "cdrom-device")
        #expect(ImageDrives.deviceName(slot: 0, format: nil) == "cdrom-device")
        #expect(ImageDrives.deviceName(slot: 0, format: "dmg") == "image-device")
        #expect(ImageDrives.deviceName(slot: 2, format: "dmg") == "image-disk-2")
        let names = (0..<4).flatMap { slot in ["raw", "dmg"].map { ImageDrives.deviceName(slot: slot, format: $0) } }
        #expect(Set(names).count == 5)
    }

    @Test func startingWithMediaReportsIt() {
        let drives = drives
        #expect(drives.media(inSlot: 0) == nil)
        drives.start(with: "/a.iso", format: "raw", slot: 0)
        #expect(drives.media(inSlot: 0) == ["Path": "/a.iso", "Format": "raw"])
    }

    @Test func slotZeroOnlyChangesMedium() async {
        let drives = drives
        #expect(await change(drives, "/a.dmg", format: "dmg", slot: 0) == nil)
        #expect(control.commands == ["blockdev-change-medium"])
        #expect(control.sent[0].arguments["id"] as? String == "image-device")
        #expect(control.sent[0].arguments["read-only-mode"] as? String == "read-only")
        #expect(drives.media(inSlot: 0) == ["Path": "/a.dmg", "Format": "dmg"])
    }

    @Test func aNewExtraDriveIsBuiltBeforeItsMedium() async {
        let drives = drives
        #expect(await change(drives, "/b.iso", slot: 2) == nil)
        #expect(
            control.commands == [
                "human-monitor-command", "device_add", "device_add", "qom-set", "blockdev-change-medium"
            ])
        #expect(
            control.sent[0].arguments["command-line"] as? String
                == "drive_add 0 id=image-backend-2,if=none,media=disk,readonly=on")
        #expect(control.sent[1].arguments["port"] as? String == "2")
        #expect(control.sent[1].arguments["bus"] as? String == "xhci.0")
        #expect(control.sent[2].arguments["removable"] as? Bool == true)
        #expect(control.sent[3].arguments["path"] as? String == "/machine/peripheral/image-usb-2")
        control.sent = []
        #expect(await change(drives, "", slot: 2) == nil)
        #expect(control.commands == ["eject", "device_del"])
        #expect(drives.media(inSlot: 2) == nil)
        control.sent = []
        #expect(await change(drives, "/c.iso", slot: 2) == nil)
        #expect(control.commands.first == "human-monitor-command")
    }

    @Test func anOccupiedPortMovesOnUpToTheLast() async {
        let drives = drives
        let taken = error("Bus 'xhci.0': port not found (in use?)")
        control.replies = [("device_add", .failure(taken)), ("device_add", .failure(taken))]
        #expect(await change(drives, "/b.iso", slot: 1) == nil)
        #expect(control.sent[1].arguments["port"] as? String == "2")
        #expect(control.sent[2].arguments["port"] as? String == "3")
        #expect(control.sent[3].arguments["port"] as? String == "4")
    }

    @Test func theLastPortBeingTakenFailsAndReleasesTheBackend() async {
        let drives = drives
        let taken = error("Bus 'xhci.0': port not found (in use?)")
        control.replies = Array(repeating: ("device_add", .failure(taken)), count: 3)
        #expect(await change(drives, "/b.iso", slot: 1)?.localizedDescription == taken.localizedDescription)
        #expect(
            control.commands == [
                "human-monitor-command", "device_add", "device_add", "device_add", "human-monitor-command"
            ])
        #expect(control.sent.last?.arguments["command-line"] as? String == "drive_del image-backend-1")
        #expect(drives.media(inSlot: 1) == nil)
    }

    @Test func aFailureAfterTheTransportRemovesItToo() async {
        let drives = drives
        control.replies = [("qom-set", .failure(error("no")))]
        #expect(await change(drives, "/b.iso", slot: 1) != nil)
        #expect(Array(control.commands.suffix(2)) == ["device_del", "human-monitor-command"])
    }

    @Test func aMonitorRefusalStopsBeforeAnyDevice() async {
        let drives = drives
        control.replies = [("human-monitor-command", .success("Duplicate ID"))]
        let failure = await change(drives, "/b.iso", slot: 1)
        #expect(failure?.localizedDescription == "The virtual image drive could not be created.")
        #expect(failure?.domain == "VirtualIntelMac.Session")
        #expect(control.commands == ["human-monitor-command"])
    }

    @Test func aFullDriveRefusesAnotherImageButNotItsOwn() async {
        let drives = drives
        drives.start(with: "/a.iso", format: "raw", slot: 0)
        #expect(await change(drives, "/a.iso", slot: 0) == nil)
        #expect(
            await change(drives, "/z.iso", slot: 0)?.localizedDescription
                == "Disconnect this drive’s current image before choosing another.")
        #expect(control.commands.isEmpty)
    }

    @Test func ejectingEmptiesOnlyAfterTheEmulatorAgrees() async {
        let drives = drives
        drives.start(with: "/a.dmg", format: "dmg", slot: 0)
        control.replies = [("eject", .failure(error("Device 'image-device' is Locked")))]
        let failure = await change(drives, "", slot: 0)
        #expect(failure?.localizedDescription == "This disc is in use")
        #expect(failure?.domain == "VirtualIntelMac.Media")
        #expect(drives.media(inSlot: 0) != nil)
        #expect(control.sent[0].arguments["id"] as? String == "image-device")
        #expect(await change(drives, "", slot: 0) == nil)
        #expect(drives.media(inSlot: 0) == nil)
    }

    @Test func emptyingAnEmptySlotIsFine() async {
        #expect(await change(drives, "", slot: 3) == nil)
        #expect(control.commands.isEmpty)
    }

    @Test func aRefusedChangeIsNotDescribedAsAnImageFailure() async {
        let drives = drives
        drives.describeFailure = { path, _ in error("described \(path)") }
        drives.change(path: "/a.iso", format: "raw", slot: 0) { _ in }
        #expect(drives.changePending)
        let refused = await withCheckedContinuation { continuation in
            drives.change(path: "/b.iso", format: "raw", slot: 0) { continuation.resume(returning: $0) }
        }
        #expect(refused?.localizedDescription == "Wait for the current disc change to finish, then try again.")
    }

    @Test func aFailedConnectionIsDescribedForItsImage() async {
        let drives = drives
        drives.describeFailure = { path, _ in error("described \(path)") }
        control.replies = [("blockdev-change-medium", .failure(error("no")))]
        #expect(await change(drives, "/a.iso", slot: 0)?.localizedDescription == "described /a.iso")
    }

    @Test func theGuestOpeningATrayForgetsWhatWasThere() {
        let drives = drives
        drives.start(with: "/a.iso", format: "raw", slot: 0)
        drives.start(with: "/b.iso", format: "raw", slot: 2)
        #expect(drives.trayOpened(onDevice: "image-device") == [:])
        #expect(drives.trayOpened(onDevice: "cdrom-device") == [0: "/a.iso"])
        #expect(drives.trayOpened(onDevice: "image-disk-1") == [:])
        #expect(drives.trayOpened(onDevice: "image-disk-2") == [2: "/b.iso"])
        #expect(drives.media(inSlot: 2) == nil)
    }

    @Test func aTrayOpeningDuringOurChangeIsOurs() {
        let drives = drives
        drives.start(with: "/a.iso", format: "raw", slot: 1)
        drives.change(path: "", format: nil, slot: 1) { _ in }
        #expect(drives.trayOpened(onDevice: "image-disk-1") == [:])
    }

    @Test func aDeletedTransportNeedsBuildingAgain() async {
        let drives = drives
        drives.start(with: "/a.iso", format: "raw", slot: 1)
        #expect(await change(drives, "", slot: 1) == nil)
        drives.start(with: "/a.iso", format: "raw", slot: 3)
        drives.deviceDeleted("image-usb-3")
        _ = drives.trayOpened(onDevice: "image-disk-3")
        control.sent = []
        #expect(await change(drives, "/b.iso", slot: 3) == nil)
        #expect(control.commands.first == "human-monitor-command")
    }
}
