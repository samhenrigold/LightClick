import Foundation
import Testing

@testable import MachineKit

private final class Package {
    let library: URL
    var url: URL
    var adopted: [(url: URL, configuration: NSDictionary, movedFrom: URL?)] = []
    var ports = true

    init(guest: String = "mojave", installState: String = "installed") throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath().appendingPathComponent("Machines")
        url = library.appendingPathComponent("A.vintelmac")
        for folder in ["State", "Disks", "Firmware", "Installation"] {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for name in ["Disks/System.qcow2", "Firmware/CODE.fd", "Firmware/NVRAM.fd", "Firmware/OpenCore.iso"] {
            try Data("x".utf8).write(to: url.appendingPathComponent(name))
        }
        try write(
            [
                "FormatVersion": 1, "Identifier": UUID().uuidString, "Guest": guest, "CPUCount": 4, "MemoryMiB": 4096,
                "Disk": "Disks/System.qcow2", "Firmware": "Firmware/CODE.fd", "NVRAM": "Firmware/NVRAM.fd",
                "BootMedia": "Firmware/OpenCore.iso", "BootMediaKind": "legacy-opencore-iso",
                "FirmwareSource": "application", "InstallState": installState
            ], "Machine.plist")
    }

    func write(_ value: [String: Any], _ relative: String) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            .write(to: url.appendingPathComponent(relative))
    }

    func saved(_ relative: String) -> [String: PropertyListValue]? {
        GuestInstallationTransaction.record(at: url.appendingPathComponent(relative))
    }

    var configuration: [String: Any] { (try? loadMachineConfiguration(package: url)) ?? [:] }

    var changes: MachinePendingChanges {
        MachinePendingChanges(
            package: url, configuration: configuration,
            networkDefaults: { [ports] configuration, _, _ in ports ? configuration : nil },
            adopt: { [unowned self] in
                adopted.append(($0, $1, $2))
                url = $0
            })
    }
}

@Suite struct MachinePendingChangesTests {
    @Test func settingsReachTheConfigurationAndThePendingFileGoes() throws {
        let package = try Package()
        try package.changes.saveSettings(["CPUCount": 2])
        #expect(package.saved("Machine.plist")?["CPUCount"] == 2)
        #expect(package.saved("State/PendingConfiguration.plist") == nil)
        #expect(package.adopted.count == 1)
        #expect(package.adopted[0].configuration["CPUCount"] as? Int == 2)
        #expect(package.adopted[0].movedFrom == nil)
    }

    @Test func invalidSettingsAreRefusedAndNotQueued() throws {
        let package = try Package()
        #expect(throws: (any Error).self) { try package.changes.saveSettings(["CPUCount": -1]) }
        #expect(package.saved("State/PendingConfiguration.plist") == nil)
        #expect(package.adopted.isEmpty)
    }

    @Test func aRunningMachineKeepsItsChangesPending() throws {
        let package = try Package()
        var locks = FileLocks()
        let held = locks.acquire(package.url.appendingPathComponent("State/Session.lock"))
        #expect(held)
        defer { locks.release() }
        try package.changes.saveSettings(["CPUCount": 2])
        #expect(package.saved("Machine.plist")?["CPUCount"] == 4)
        #expect(package.saved("State/PendingConfiguration.plist")?["Settings"]?.dictionary?["CPUCount"] == 2)
        #expect(package.adopted.isEmpty)
    }

    @Test func queuedSettingsBuildOnEachOther() throws {
        let package = try Package()
        var locks = FileLocks()
        let held = locks.acquire(package.url.appendingPathComponent("State/Session.lock"))
        #expect(held)
        try package.changes.saveSettings(["CPUCount": 2])
        try package.changes.saveSettings(["MemoryMiB": 2048])
        locks.release()
        try package.changes.apply()
        #expect(package.saved("Machine.plist")?["CPUCount"] == 2)
        #expect(package.saved("Machine.plist")?["MemoryMiB"] == 2048)
    }

    @Test func aHeldConfigurationLockAsksToTryAgain() throws {
        let package = try Package()
        var locks = FileLocks()
        let held = locks.acquire(package.url.appendingPathComponent("State/Configuration.lock"))
        #expect(held)
        defer { locks.release() }
        #expect(throws: MachinePackageIssue("This Mac’s settings are being saved. Please try again.")) {
            try package.changes.saveSettings(["CPUCount": 2])
        }
    }

    @Test func aRenameMovesThePackageAndSaysWhereFrom() throws {
        let package = try Package()
        let old = package.url
        try package.changes.rename(to: "New Name")
        #expect(package.url.lastPathComponent == "New Name.vintelmac")
        #expect(package.adopted[0].movedFrom == old)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(package.saved("State/PendingConfiguration.plist") == nil)
    }

    @Test func aBadNameIsRefused() throws {
        let package = try Package()
        #expect(throws: MachinePackageIssue.self) { try package.changes.rename(to: "a/b") }
        #expect(package.saved("State/PendingConfiguration.plist") == nil)
    }

    @Test func aRenameOfARunningMachineWaits() throws {
        let package = try Package()
        var locks = FileLocks()
        let held = locks.acquire(package.url.appendingPathComponent("State/Session.lock"))
        #expect(held)
        defer { locks.release() }
        try package.changes.rename(to: "Later")
        #expect(package.url.lastPathComponent == "A.vintelmac")
        #expect(package.saved("State/PendingConfiguration.plist")?["RequestedBundleName"] == "Later")
    }

    @Test func noPortsLeavesEverythingWhereItWas() throws {
        let package = try Package()
        package.ports = false
        #expect(throws: MachinePackageIssue.self) { try package.changes.rename(to: "New Name") }
        #expect(package.url.lastPathComponent == "A.vintelmac")
        #expect(FileManager.default.fileExists(atPath: package.url.path))
        #expect(package.adopted.isEmpty)
    }

    @Test func withNothingPendingNothingIsSaved() throws {
        let package = try Package()
        let machine = package.url.appendingPathComponent("Machine.plist")
        let before = try Data(contentsOf: machine)
        try package.changes.apply()
        #expect(try Data(contentsOf: machine) == before)
        #expect(package.adopted.count == 1)
    }

    @Test func aPackageThatWontLoadIsAnError() throws {
        let package = try Package()
        let changes = package.changes
        try FileManager.default.removeItem(at: package.url.appendingPathComponent("Machine.plist"))
        #expect(throws: (any Error).self) { try changes.apply() }
    }
}

@Suite struct MachineAutomaticSetupPolicyTests {
    private func policy(_ package: Package, supports: Bool = true) -> MachineAutomaticSetupPolicy {
        MachineAutomaticSetupPolicy(
            package: package.url, configuration: MachineConfiguration(values: package.saved("Machine.plist") ?? [:]),
            supportsGuest: supports, validateUsername: { _ in }, requireInstallerConfiguration: { _ in })
    }

    private var profile: [String: PropertyListValue] {
        [
            "FormatVersion": 1, "Enabled": true, "Username": "sam", "FileSharing": true, "RemoteLogin": false,
            "CredentialIdentifier": .string(UUID().uuidString)
        ]
    }

    private func installing() throws -> Package {
        let package = try Package(installState: "installing")
        try package.write(["VolumeUUID": "volume"], "State/InstallationTarget.plist")
        return package
    }

    private let journal = "State/AutomaticSetup.plist"

    @Test func aProfileBecomesAPendingJournalWithoutASecret() throws {
        let package = try installing()
        try policy(package).save(profile)
        let saved = package.saved(journal)
        #expect(saved?["Phase"] == "pending")
        #expect(saved?["Guest"] == "mojave")
        #expect(saved?["VolumeUUID"] == "volume")
        #expect(saved?["Password"] == nil)
    }

    @Test func onlyANewInstallationCanHaveOne() throws {
        #expect(throws: MachinePackageIssue.self) { try policy(Package()).save(profile) }
        #expect(throws: MachinePackageIssue.self) { try policy(installing(), supports: false).save(profile) }
    }

    @Test func unknownOptionsAndBadValuesAreRefused() throws {
        let package = try installing()
        var extra = profile
        extra["Password"] = "secret"
        #expect(throws: MachinePackageIssue("Automatic setup contains an unsupported option.")) {
            try policy(package).save(extra)
        }
        var sharing = profile
        sharing["FileSharing"] = 2
        #expect(throws: MachinePackageIssue("Check the automatic sharing options.")) {
            try policy(package).save(sharing)
        }
        var credential = profile
        credential["CredentialIdentifier"] = "not-a-uuid"
        #expect(throws: MachinePackageIssue.self) { try policy(package).save(credential) }
        #expect(package.saved(journal) == nil)
    }

    @Test func automaticLoginIsAllowedAndChecked() throws {
        let package = try installing()
        var login = profile
        login["AutomaticLogin"] = 3
        #expect(throws: MachinePackageIssue.self) { try policy(package).save(login) }
        login["AutomaticLogin"] = true
        try policy(package).save(login)
        #expect(package.saved(journal)?["AutomaticLogin"] == true)
    }

    @Test func aSavedSetupIsNeverResetAndOnlyTheSameOnePasses() throws {
        let package = try installing()
        let first = profile
        try policy(package).save(first)
        try package.write(
            (package.saved(journal) ?? [:]).merging(["Phase": "in-progress"]) { $1 }.mapValues(\.foundationObject),
            journal)
        try policy(package).save(first)
        #expect(package.saved(journal)?["Phase"] == "in-progress")
        #expect(throws: MachinePackageIssue.self) { try policy(package).save(profile) }
    }

    @Test func aRunningMachineCantChangeIt() throws {
        let package = try installing()
        var locks = FileLocks()
        let held = locks.acquire(package.url.appendingPathComponent("State/Session.lock"))
        #expect(held)
        defer { locks.release() }
        #expect(throws: MachinePackageIssue("Stop this virtual Mac before changing its initial setup.")) {
            try policy(package).save(profile)
        }
    }
}
