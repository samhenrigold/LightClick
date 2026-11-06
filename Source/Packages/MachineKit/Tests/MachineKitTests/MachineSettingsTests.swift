import Foundation
import InstallerKit
import Testing

@testable import MachineKit

@Suite struct SettingsSectionTests {
    @Test func sectionsHaveTheirRowsInOrder() {
        #expect(SettingsSection.general.categories.isEmpty)
        #expect(
            SettingsSection.hardware.categories.map(\.rawValue) == [
                "CPU & Memory", "Graphics", "Mouse & Keyboard", "Network", "Sound", "Hard Disk", "CD/DVD"
            ])
        #expect(SettingsSection.sharing.categories.map(\.rawValue) == ["File Sharing", "Remote Login", "Clipboard"])
    }

    @Test func callersMayUseTheOldNames() {
        #expect(SettingsSection(identifier: "Options") == .sharing)
        #expect(SettingsSection(identifier: "Hardware") == .hardware)
        #expect(SettingsSection(identifier: "Nope") == nil)
        #expect(SettingsCategory(identifier: "Sharing") == .fileSharing)
        #expect(SettingsCategory(identifier: "General") == nil)
    }

    @Test func onlySomeRowsCanRestoreDefaults() {
        let rows = SettingsSection.hardware.categories.filter(\.hasRestoreDefaults)
        #expect(rows == [.cpuAndMemory, .graphics, .network, .sound])
    }

    @Test func restoringWritesWhatItAlwaysHas() throws {
        func restored(_ category: SettingsCategory, retina: Bool = true) -> NSDictionary? {
            SettingsDefaults.restored(category, supportsRetina: retina, processorCount: 2).map { $0 as NSDictionary }
        }
        #expect(restored(.cpuAndMemory) == ["CPUCount": 2, "MemoryMiB": 4096])
        #expect(
            restored(.graphics)
                == ["DisplayMode": "retina", "RetinaEnabled": true, "DisplayScalingFilter": "linear"])
        #expect(
            restored(.graphics, retina: false)
                == ["DisplayMode": "scaled", "RetinaEnabled": false, "DisplayScalingFilter": "nearest"])
        #expect(restored(.network) == ["MACAddress": "", "BridgeInterface": ""])
        #expect(
            restored(.sound) == ["AudioEnabled": true, "AudioInputDevice": "default", "AudioOutputDevice": "default"])
        #expect(restored(.hardDisk) == nil)
    }
}

@Suite struct SettingsHardwareLimitsTests {
    private let limits = SettingsHardwareLimits(physicalMemoryBytes: 16 << 30, processorCount: 6)

    @Test func theNumbersFollowTheHost() {
        #expect(limits.maximumMemoryMiB == 15360)
        #expect(limits.memorySliderMaximumGiB == 15)
        #expect(limits.memorySliderMiddleGiB == 8)
        #expect(limits.processorTitles == ["1", "2", "3", "4 (Recommended)", "5", "6"])
        #expect(
            limits.summary
                == "This Mac has 6 logical processors and 16 GB of memory. Leave resources available for other apps.")
    }

    @Test func aSmallHostRecommendsWhatItHas() {
        let small = SettingsHardwareLimits(physicalMemoryBytes: 8 << 30, processorCount: 2)
        #expect(small.processorTitles == ["1", "2 (Recommended)"])
    }

    @Test func theProcessorPopupShowsTheSavedCount() {
        let saved = limits.processorChoices(saved: 3)
        #expect(saved.counts == [1, 2, 3, 4, 5, 6])
        #expect(saved.titles == limits.processorTitles)
        #expect(saved.selectedIndex == 2)
        #expect(limits.processorChoices(saved: 6).selectedIndex == 5)
        #expect(limits.processorChoices(saved: 0).selectedIndex == 0)
    }

    @Test func aSavedCountPastTheHostGetsItsOwnEntry() {
        let moved = limits.processorChoices(saved: 12)
        #expect(moved.counts == [1, 2, 3, 4, 5, 6, 12])
        #expect(moved.titles.last == "12 (more than this Mac has)")
        #expect(moved.selectedIndex == 6)
    }

    @Test func typedMemoryMustFit() {
        #expect(limits.memoryMiB(from: "2048") == .success(2048))
        #expect(limits.memoryMiB(from: " 15360 ") == .success(15360))
        let issue = SettingsFieldIssue(message: "Use up to 6 processors or 15360 MB of memory.")
        for text in ["1023", "15361", "16384", "", "4 GB", "4.5"] {
            #expect(limits.memoryMiB(from: text) == .failure(issue))
        }
    }

    @Test func settingsAndNewMachineShareALimit() {
        for (bytes, cores): (UInt64, Int) in [(1 << 30, 1), (8 << 30, 4), (16 << 30, 6), (256 << 30, 32)] {
            let host = HostCapacity(physicalMemoryBytes: bytes, processorCount: cores)
            let limits = SettingsHardwareLimits(physicalMemoryBytes: bytes, processorCount: cores)
            #expect(limits.maximumMemoryMiB == host.maximumMemoryGiB * 1024)
            #expect(limits.memorySliderMaximumGiB == host.maximumMemoryGiB)
        }
    }

    @Test func aSavedValuePastTheLimitStandsUntilItIsEdited() {
        #expect(limits.memoryMiB(from: "16384", saved: 16384) == .success(16384))
        let issue = SettingsFieldIssue(message: "Use up to 6 processors or 15360 MB of memory.")
        #expect(limits.memoryMiB(from: "16000", saved: 16384) == .failure(issue))
        #expect(limits.memoryMiB(from: "8192", saved: 16384) == .success(8192))
    }

    @Test func theSliderRoundsAndStopsAtTheHost() {
        #expect(limits.memoryMiB(fromSliderGiB: 3.6) == 4096)
        #expect(limits.memoryMiB(fromSliderGiB: 15) == 15360)
        #expect(limits.memoryMiB(fromSliderGiB: 16) == 15360)
    }
}

@Suite struct SettingsValidationTests {
    @Test func aGuestUsernameIsAShortName() {
        #expect(SettingsValidation.guestUsernameIssue("sam.h-g_1") == nil)
        #expect(SettingsValidation.guestUsernameIssue("") == nil)
        let issue = "Use the guest account’s short name (letters, numbers, dots, hyphens or underscores)."
        for name in ["sam henri", "sam'; rm", "sám", "a/b"] {
            #expect(SettingsValidation.guestUsernameIssue(name)?.message == issue)
        }
    }

    @Test func aLocalPortIsUnprivileged() {
        #expect(SettingsValidation.localPort("1024") == .success(1024))
        #expect(SettingsValidation.localPort("65535") == .success(65535))
        let issue = SettingsFieldIssue(message: "Enter a local port from 1024 to 65535.")
        for text in ["1023", "65536", "x", ""] { #expect(SettingsValidation.localPort(text) == .failure(issue)) }
    }

    /// Always the same bytes, so the only thing this can't check is that they're random.
    private struct Fixed: RandomNumberGenerator {
        let value: UInt64
        mutating func next() -> UInt64 { value }
    }

    @Test(arguments: [UInt64.max, 0, 0x0101_0101_0101_0101])
    func aGeneratedMACIsLocalAndUnicast(value: UInt64) throws {
        var generator = Fixed(value: value)
        let address = SettingsValidation.randomMACAddress(using: &generator)
        let parts = address.split(separator: ":")
        #expect(parts.count == 6 && parts.allSatisfy { $0.count == 2 && $0.uppercased() == $0 })
        let first = try #require(UInt8(parts[0], radix: 16))
        #expect(first & 2 == 2 && first & 1 == 0)
    }
}

@Suite struct DisplayChoiceTests {
    @Test func olderGuestsHaveNoRetinaChoice() {
        #expect(DisplayResolutionChoice.available(supportsRetina: true) == [.moreSpace, .bestForRetina, .scaled])
        #expect(DisplayResolutionChoice.available(supportsRetina: false) == [.moreSpace, .scaled])
        #expect(
            DisplayResolutionChoice.moreSpace.detail(supportsRetina: true)?.hasPrefix("Graphics at full Retina") == true
        )
        #expect(
            DisplayResolutionChoice.moreSpace.detail(supportsRetina: false)?.hasPrefix("Graphics at full display")
                == true)
        #expect(DisplayResolutionChoice.bestForRetina.detail(supportsRetina: true) == nil)
    }

    /// Machine.plist holds an integer here, unlike Restore Defaults' Boolean.
    @Test func aChoiceWritesAnIntegerFlag() throws {
        let settings = DisplayResolutionChoice.scaled.settings as NSDictionary
        #expect(settings == ["DisplayMode": "scaled", "RetinaEnabled": 0])
        #expect(CFGetTypeID(try #require(settings["RetinaEnabled"]) as CFTypeRef) == CFNumberGetTypeID())
        #expect(DisplayResolutionChoice.moreSpace.settings["RetinaEnabled"] as? Int == 1)
    }

    @Test func theNetworkMenuMapsBothWays() {
        #expect(NetworkSource.selectedIndex(mode: "shared", isDisconnected: false) == 1)
        #expect(NetworkSource.selectedIndex(mode: "bridged", isDisconnected: false) == 3)
        #expect(NetworkSource.selectedIndex(mode: "host", isDisconnected: true) == 0)
        #expect(NetworkSource.selectedIndex(mode: "strange", isDisconnected: false) == 1)
        #expect(NetworkSource.mode(forIndex: 0, current: "host") == ("host", false))
        #expect(NetworkSource.mode(forIndex: 2, current: "shared") == ("host", true))
        #expect(NetworkSource.explanation(mode: "shared") == "The virtual Mac shares this Mac’s internet connection.")
    }
}

@Suite struct PackageStorageTests {
    @Test func theBarNeverHidesEitherPart() {
        #expect(PackageStorage().diskShare == 0.98)
        #expect(PackageStorage(diskBytes: 1, otherBytes: 1).diskShare == 0.5)
        #expect(PackageStorage(diskBytes: 1000, otherBytes: 0).diskShare == 0.99)
        #expect(PackageStorage(diskBytes: 0, otherBytes: 1000).diskShare == 0.01)
    }

    @Test func theSummaryNamesWhatItCannotRead() {
        #expect(
            PackageStorage.summary(capacityBytes: 0, allocatedBytes: nil)
                == "Disk capacity: Not recorded\nDisk file space on this Mac: Unavailable")
        #expect(
            PackageStorage.summary(capacityBytes: 64 << 30, allocatedBytes: nil).hasPrefix("Disk capacity: 64 GB\n"))
        #expect(PackageStorage.summary(capacityBytes: 3 << 29, allocatedBytes: 0).hasPrefix("Disk capacity: 1.5 GB\n"))
    }

    @Test func measuringSeparatesTheDiskAndSkipsLinksAndHiddenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disks = root.appendingPathComponent("Disks")
        try FileManager.default.createDirectory(at: disks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 100_000).write(to: disks.appendingPathComponent("System.qcow2"))
        try Data(repeating: 2, count: 8192).write(to: root.appendingPathComponent("Machine.plist"))
        try Data(repeating: 3, count: 500_000).write(to: root.appendingPathComponent(".hidden"))
        // Sorts or hashes anywhere relative to Disks, which must still be counted.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Link"), withDestinationURL: disks.appendingPathComponent("System.qcow2"))
        let measured = PackageStorage.measure(package: root, disk: "Disks/System.qcow2")
        #expect(measured.diskBytes >= 100_000 && measured.diskBytes < 500_000)
        #expect(measured.otherBytes >= 8192 && measured.otherBytes < 100_000)
        let noDisk = PackageStorage.measure(package: root, disk: nil)
        #expect(noDisk.diskBytes == 0 && noDisk.otherBytes == measured.diskBytes + measured.otherBytes)
    }

    @Test func theRemoteLoginMessageSaysWhetherToRestart() {
        #expect(RemoteLoginMessage.enabled(needsRestart: true).contains("restart the virtual Mac to apply that change"))
        #expect(RemoteLoginMessage.enabled(needsRestart: false).hasSuffix("there’s no need to restart."))
    }

    @Test func aTerminalProfileHoldsOnlyTheCommand() throws {
        let settings = TerminalConnectionProfile.settings(name: "Mac", command: "ssh x") as NSDictionary
        #expect(settings["CommandString"] as? String == "ssh x" && settings["RunCommandAsShell"] as? Bool == false)
        #expect(settings["type"] as? String == "Window Settings")
        #expect(settings.count == 5)
    }
}

@Suite struct SharingDirectionsTests {
    private func toHost(
        _ service: SharingDirections.Service, address: String? = "10.0.2.2", user: String = "sam",
        preMetal: Bool = false,
        windows: Bool = false, connected: Bool = true
    ) -> SharingDirections {
        .toHost(
            service: service, hostAddress: address, hostUser: user, isPreMetalGuest: preMetal,
            usesWindowsFileSharing: windows, isConnected: connected)
    }

    private func toGuest(
        _ service: SharingDirections.Service, shared: Bool = true, port: NSNumber? = 2222, guest: String? = nil,
        user: String = "sam", preMetal: Bool = false, connected: Bool = true, enabled: Bool = true
    ) -> SharingDirections {
        .toGuest(
            service: service, isShared: shared, port: port, guestAddress: guest, guestUsername: user,
            smbForwardURL: "smb://Mac-VM._smb._tcp.local", isPreMetalGuest: preMetal,
            identifier: "00000000-0000-4000-8000-00000000ABCD", isConnected: connected, isEnabled: enabled)
    }

    @Test func reachingTheHostOverSMB() {
        let directions = toHost(.fileSharing)
        #expect(directions.address == "smb://10.0.2.2")
        #expect(directions.openTarget == "smb://10.0.2.2")
        #expect(directions.canCopy && directions.canOpen)
        #expect(directions.openTitle == "Open in Finder" && directions.copyTitle == "Copy Address")
        #expect(
            directions.firstStep == "1. On this Mac, open System Settings → General → Sharing and enable File Sharing.")
    }

    @Test func classicGuestsAreToldAboutWindowsFileSharing() {
        #expect(toHost(.fileSharing, windows: true).firstStep.contains("under Windows File Sharing"))
        #expect(!toHost(.remoteLogin, windows: true).firstStep.contains("Windows File Sharing"))
    }

    @Test func reachingTheHostOverSSHQuotesTheUser() {
        let directions = toHost(.remoteLogin, user: "o'brien")
        #expect(directions.address == "ssh -l 'o'\\''brien' 10.0.2.2")
        #expect(directions.openTarget.hasPrefix("ssh://") && directions.openTarget.hasSuffix("@10.0.2.2"))
        #expect(directions.openTitle == "Open in Terminal" && directions.copyTitle == "Copy Command")
    }

    /// Installed guests have this path; it can't change.
    @Test func olderGuestsUseTheirInstalledClient() {
        #expect(
            toHost(.remoteLogin, preMetal: true).address
                == "'/Library/Application Support/Virtual Intel Mac/GuestTools/guest-ssh' -l 'sam' 10.0.2.2")
        #expect(toHost(.fileSharing, preMetal: true).address == "smb://10.0.2.2")
    }

    @Test func noHostAddressYet() {
        let directions = toHost(.remoteLogin, address: "")
        #expect(directions.address.isEmpty && directions.openTarget.isEmpty)
        #expect(!directions.canCopy && !directions.canOpen)
        #expect(
            directions.addressLine == "Start the virtual Mac and connect its network to discover this Mac’s address.")
        #expect(toHost(.fileSharing, address: nil).address.isEmpty)
    }

    @Test func aDisconnectedGuestCanStillCopy() {
        let directions = toHost(.fileSharing, connected: false)
        #expect(directions.canCopy && !directions.canOpen)
    }

    @Test func reachingTheGuestThroughTheForward() {
        let files = toGuest(.fileSharing)
        #expect(files.address == "smb://Mac-VM._smb._tcp.local")
        #expect(files.openTarget == files.address)
        let ssh = toGuest(.remoteLogin)
        #expect(ssh.address == "ssh -p 2222 -l 'sam' 127.0.0.1")
        #expect(ssh.addressLine == ssh.address)
        #expect(ssh.openTarget == "ssh://sam@127.0.0.1:2222")
        #expect(ssh.canCopy && ssh.canOpen)
    }

    @Test func reachingTheGuestDirectly() {
        #expect(toGuest(.fileSharing, shared: false, guest: "192.168.1.9").address == "smb://192.168.1.9")
        let ssh = toGuest(.remoteLogin, shared: false, guest: "192.168.1.9")
        #expect(ssh.address == "ssh -l 'sam' 192.168.1.9")
        #expect(ssh.openTarget == "ssh://sam@192.168.1.9")
        let waiting = toGuest(.remoteLogin, shared: false, guest: nil)
        #expect(waiting.address.isEmpty && !waiting.canCopy && !waiting.canOpen)
        #expect(waiting.addressLine == "Start the virtual Mac and wait for its network address.")
    }

    /// Stock 13F34's sshd aborts on AES-GCM, and the options stay scoped to this machine's host key alias.
    @Test func olderGuestsGetPeriodCrypto() {
        #expect(
            toGuest(.remoteLogin, preMetal: true).address
                == "ssh -o HostKeyAlgorithms=+ssh-rsa -c aes128-ctr -o HostKeyAlias=vim-00000000-0000-4000-8000-00000000abcd "
                + "-p 2222 -l 'sam' '127.0.0.1'")
        let direct = toGuest(.remoteLogin, shared: false, guest: "192.168.1.9", user: "o'b", preMetal: true)
        #expect(direct.address.hasSuffix("-p 22 -l 'o'\\''b' '192.168.1.9'"))
        #expect(direct.openTarget == direct.address)
        #expect(toGuest(.remoteLogin, shared: false, guest: nil, preMetal: true).address.isEmpty)
    }

    @Test func sshWaitsForAnAccountName() {
        let directions = toGuest(.remoteLogin, user: "")
        #expect(!directions.canCopy && !directions.canOpen)
        #expect(directions.addressLine == "Enter your guest account’s short name above.")
        #expect(toGuest(.fileSharing, user: "").canCopy)
    }

    @Test func aTurnedOffForwardOnlyStopsSharedConnections() {
        #expect(!toGuest(.fileSharing, enabled: false).canOpen)
        #expect(toGuest(.fileSharing, enabled: false).canCopy)
        #expect(toGuest(.fileSharing, shared: false, guest: "192.168.1.9", enabled: false).canOpen)
        #expect(!toGuest(.fileSharing, connected: false).canOpen)
    }
}
