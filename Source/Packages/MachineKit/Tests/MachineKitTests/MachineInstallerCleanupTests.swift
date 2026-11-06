import Foundation
import Testing

@testable import MachineKit

/// One machine in a real temporary library, with its verified installation records written out.
private final class Machine {
    let library: URL
    let package: URL
    let identifier = UUID().uuidString
    var adopted: [MachineConfiguration] = []
    var removedPasswords: [String] = []
    var keepInstallers = false
    var creatingMedia: String?

    var media: URL { file("Installation/Installer.iso") }
    func file(_ relative: String) -> URL { package.appendingPathComponent(relative) }
    func saved(_ relative: String) -> [String: PropertyListValue]? {
        GuestInstallationTransaction.record(at: file(relative))
    }

    init(guest: String = "mojave", shared: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        library = root.appendingPathComponent("Machines")
        package = library.appendingPathComponent("A.vintelmac")
        for folder in ["State", "Installation", "Disks", "Firmware"] {
            try FileManager.default.createDirectory(
                at: package.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        var configuration: [String: Any] = [
            "FormatVersion": 1, "Identifier": identifier, "Guest": guest, "CPUCount": 4, "MemoryMiB": 4096,
            "Disk": "Disks/System.qcow2", "Firmware": "Firmware/CODE.fd", "NVRAM": "Firmware/NVRAM.fd",
            "BootMedia": "Firmware/OpenCore.iso", "BootMediaKind": "legacy-opencore-iso",
            "FirmwareSource": "application", "InstallState": "installing",
            "InstallerMedia": InstallerMediaLocation.ownedPath, "InstallerMediaKind": "optical"
        ]
        let sharedPath = root.appendingPathComponent("Shared.iso").path
        if shared {
            configuration["InstallerMediaShared"] = true
            configuration["InstallerMedia"] = sharedPath
            try Data("media".utf8).write(to: URL(fileURLWithPath: sharedPath))
        }
        for name in ["Disks/System.qcow2", "Firmware/CODE.fd", "Firmware/NVRAM.fd", "Firmware/OpenCore.iso"] {
            try Data("x".utf8).write(to: file(name))
        }
        try write(configuration, "Machine.plist")
        try Data("media".utf8).write(to: media)
        try write(
            [
                "FormatVersion": 1, "MachineIdentifier": identifier, "Size": 5,
                "Media": shared ? sharedPath : InstallerMediaLocation.ownedPath
            ],
            "Installation/Ownership.plist")
        try write(
            [
                "Phase": "graphics-verified", "TransactionID": "t",
                "PostBootVerification": [
                    "TransactionID": "t", "VerifiedAfterReboot": true, "MetalCommandVerified": true, "VolumeUUID": "v",
                    "BootSessionUUID": "b", "ProductBuildVersion": "18G103"
                ] as [String: Any]
            ], "State/GuestInstallation.plist")
    }

    func write(_ value: [String: Any], _ relative: String) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: file(relative))
    }

    var report: GuestReport {
        GuestReport(values: [
            "Guest": "mojave", "InstalledSystemCandidate": true, "LiveRoot": true, "KernelMatchesSystem": true,
            "VolumeUUID": "v", "BootSessionUUID": "b", "ProductBuildVersion": "18G103"
        ])
    }

    var configuration: MachineConfiguration {
        MachineConfiguration(values: saved("Machine.plist") ?? [:])
    }

    var cleanup: MachineInstallerCleanup {
        MachineInstallerCleanup(
            package: package, keepInstallers: keepInstallers, creatingMedia: creatingMedia,
            removePassword: { [unowned self] in removedPasswords.append($0) },
            adopt: { [unowned self] in adopted.append($0) })
    }

    func sibling(_ values: [String: Any]?) throws -> URL {
        let other = library.appendingPathComponent("B.vintelmac")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        if let values {
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
                .write(to: other.appendingPathComponent("Machine.plist"))
        }
        return other
    }
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@Suite struct MachineInstallerCleanupTests {
    private func refused(_ message: String, _ body: () throws -> Void) {
        #expect(throws: MachinePackageIssue(message)) { try body() }
    }

    @Test func provenInstallationRetiresRoutingAndThenItsMedia() throws {
        let machine = try Machine()
        try machine.cleanup.finish(report: machine.report)
        #expect(!exists(machine.media))
        #expect(machine.configuration[.installerMedia] == nil)
        #expect(machine.configuration.installState == .installed)
        #expect(machine.adopted.count == 1)
        let install = machine.saved("State/Install.plist")
        #expect(install?["Phase"] == "complete")
        #expect(install?["TransactionID"] == "t")
        #expect(install?["InstallerMediaRemoved"] == true)
    }

    @Test func aSecondFinishIsHarmless() throws {
        let machine = try Machine()
        try machine.cleanup.finish(report: machine.report)
        try machine.cleanup.finish(report: machine.report)
        #expect(machine.saved("State/Install.plist")?["Phase"] == "complete")
    }

    @Test func keepingInstallersLeavesTheFile() throws {
        let machine = try Machine()
        machine.keepInstallers = true
        try machine.cleanup.finish(report: machine.report)
        #expect(exists(machine.media))
        #expect(machine.saved("State/Install.plist")?["InstallerMediaRemoved"] == false)
    }

    private func nothingHappened(_ machine: Machine) {
        #expect(exists(machine.media))
        #expect(machine.configuration[.installerMedia] != nil)
        #expect(machine.adopted.isEmpty)
    }

    @Test func aReportFromAnotherVolumeIsRefused() throws {
        let machine = try Machine()
        var values = machine.report.values
        values["VolumeUUID"] = "other"
        refused("Matching completed guest installation and graphics verification are required. Media was retained.") {
            try machine.cleanup.finish(report: GuestReport(values: values))
        }
        nothingHappened(machine)
    }

    @Test func theSessionLockIsRequired() throws {
        let machine = try Machine()
        var locks = FileLocks()
        let held = locks.acquire(machine.file("State/Session.lock"))
        #expect(held)
        defer { locks.release() }
        refused("Shut down this Mac before finishing installer cleanup.") {
            try machine.cleanup.finish(report: machine.report)
        }
        nothingHappened(machine)
    }

    @Test func anotherMachinesOwnershipIsRefused() throws {
        let machine = try Machine()
        try machine.write(
            ["FormatVersion": 1, "MachineIdentifier": "other", "Size": 5, "Media": InstallerMediaLocation.ownedPath],
            "Installation/Ownership.plist")
        refused("Installer ownership could not be established. Media was retained.") {
            try machine.cleanup.finish(report: machine.report)
        }
        nothingHappened(machine)
    }

    @Test func aFileOfAnotherSizeIsRefused() throws {
        let machine = try Machine()
        try Data("changed media".utf8).write(to: machine.media)
        refused("Installer media no longer matches its ownership record.") {
            try machine.cleanup.finish(report: machine.report)
        }
        nothingHappened(machine)
    }

    @Test func aLinkedFileIsRefused() throws {
        let machine = try Machine()
        try FileManager.default.linkItem(at: machine.media, to: machine.file("Disks/Hard.iso"))
        refused("Installer media no longer matches its ownership record.") {
            try machine.cleanup.finish(report: machine.report)
        }
        nothingHappened(machine)
    }

    @Test func aRelocatedInstallationFolderIsRefused() throws {
        let machine = try Machine()
        let elsewhere = machine.library.deletingLastPathComponent().appendingPathComponent("Elsewhere")
        try FileManager.default.moveItem(at: machine.file("Installation"), to: elsewhere)
        try FileManager.default.createSymbolicLink(at: machine.file("Installation"), withDestinationURL: elsewhere)
        // Loading the package refuses a file outside it, even before cleanup's own check.
        #expect(throws: MachineConfigurationError.self) { try machine.cleanup.finish(report: machine.report) }
        #expect(exists(elsewhere.appendingPathComponent("Installer.iso")))
    }

    @Test func mediaThisMacStillBootsFromIsRefused() throws {
        let machine = try Machine()
        var configuration = machine.configuration.values.mapValues(\.foundationObject) as [String: Any]
        configuration["BootMedia"] = InstallerMediaLocation.ownedPath
        try machine.write(configuration, "Machine.plist")
        refused("Installer media is still used by another device in this Mac.") {
            try machine.cleanup.finish(report: machine.report)
        }
        nothingHappened(machine)
    }

    @Test func anotherMacsReferenceIsRefused() throws {
        let machine = try Machine()
        _ = try machine.sibling(["InstallerMedia": "../A.vintelmac/" + InstallerMediaLocation.ownedPath])
        refused("Another Mac still references this installer.") { try machine.cleanup.finish(report: machine.report) }
        nothingHappened(machine)
    }

    @Test func anUnreadableSiblingStopsIt() throws {
        let machine = try Machine()
        _ = try machine.sibling(nil)
        refused("Another Mac's configuration could not be checked. Media was retained.") {
            try machine.cleanup.finish(report: machine.report)
        }
        nothingHappened(machine)
    }

    @Test func aSharedInstallerIsDetachedAndNeverDeleted() throws {
        let machine = try Machine(shared: true)
        try machine.cleanup.finish(report: machine.report)
        #expect(exists(machine.media), "Not this path's to delete.")
        #expect(machine.configuration[.installerMedia] == nil)
        let install = machine.saved("State/Install.plist")
        #expect(install?["InstallerDetached"] == true)
        #expect(install?["SharedMediaRetained"] == true)
    }

    private func preparedMachine() throws -> (Machine, URL) {
        let machine = try Machine(shared: true)
        let attempt = machine.library.deletingLastPathComponent()
            .appendingPathComponent("Installers").appendingPathComponent(UUID().uuidString)
        let media = attempt.appendingPathComponent("Media/Install.iso")
        try FileManager.default.createDirectory(
            at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("media".utf8).write(to: media)
        var configuration = machine.configuration.values.mapValues(\.foundationObject) as [String: Any]
        configuration["InstallerMedia"] = media.path
        try machine.write(configuration, "Machine.plist")
        try machine.write(
            ["FormatVersion": 1, "MachineIdentifier": machine.identifier, "Size": 5, "Media": media.path],
            "Installation/Ownership.plist")
        return (machine, attempt)
    }

    @Test func aPreparedAttemptGoesWhenNothingElseUsesIt() throws {
        let (machine, attempt) = try preparedMachine()
        try machine.cleanup.finish(report: machine.report)
        #expect(!exists(attempt))
        #expect(machine.saved("State/Install.plist")?["SharedMediaRetained"] == false)
    }

    @Test func aPreparedAttemptStaysForAJobOrAnotherMac() throws {
        let (machine, attempt) = try preparedMachine()
        machine.creatingMedia = attempt.appendingPathComponent("Media/Install.iso").path
        try machine.cleanup.finish(report: machine.report)
        #expect(exists(attempt))

        let (second, secondAttempt) = try preparedMachine()
        _ = try second.sibling(["InstallerMedia": secondAttempt.appendingPathComponent("Media/Install.iso").path])
        try second.cleanup.finish(report: second.report)
        #expect(exists(secondAttempt))

        let (third, thirdAttempt) = try preparedMachine()
        _ = try third.sibling(nil)
        try third.cleanup.finish(report: third.report)
        #expect(exists(thirdAttempt), "A Mac that can't be read might be using it.")
    }

    @Test func retryWithNothingPendingIsANoOp() throws {
        let machine = try Machine()
        try FileManager.default.removeItem(at: machine.file("State/GuestInstallation.plist"))
        try machine.cleanup.retry(configuration: machine.configuration, preMetalGuest: false)
        nothingHappenedExceptJournal(machine)
    }

    private func nothingHappenedExceptJournal(_ machine: Machine) {
        #expect(exists(machine.media))
        #expect(machine.saved("State/Install.plist") == nil)
    }

    @Test func retryFinishesAPendingCleanup() throws {
        let machine = try Machine()
        try machine.write(
            [
                "Phase": "cleanup-pending", "Identifier": machine.identifier,
                "GuestReport": machine.report.values.mapValues(\.foundationObject)
            ], "State/Install.plist")
        try machine.cleanup.retry(configuration: machine.configuration, preMetalGuest: false)
        #expect(machine.saved("State/Install.plist")?["Phase"] == "complete")
    }

    @Test func retryRefusesAnotherMachinesPendingCleanup() throws {
        let machine = try Machine()
        try machine.write(["Phase": "cleanup-pending", "Identifier": "other"], "State/Install.plist")
        refused("Saved installer cleanup does not match this Mac. Media was retained.") {
            try machine.cleanup.retry(configuration: machine.configuration, preMetalGuest: false)
        }
    }

    @Test func retryRecoversTheReportAfterARestart() throws {
        let machine = try Machine()
        refused("Saved guest status is unavailable. Installer media was retained.") {
            try machine.cleanup.retry(configuration: machine.configuration, preMetalGuest: false)
        }
        try machine.write(["Report": machine.report.values.mapValues(\.foundationObject)], "State/GuestStatus.plist")
        try machine.cleanup.retry(configuration: machine.configuration, preMetalGuest: false)
        #expect(!exists(machine.media))
    }

    private func openGLMachine(installState: String = "installed") throws -> Machine {
        let machine = try Machine(guest: "lion")
        var configuration = machine.configuration.values.mapValues(\.foundationObject) as [String: Any]
        configuration["InstallerMedia"] = nil
        configuration["InstallerMediaKind"] = nil
        configuration["InstallState"] = installState
        try machine.write(configuration, "Machine.plist")
        try machine.write(
            ["Phase": "graphics-verified", "MachineIdentifier": machine.identifier],
            "State/LegacyGuestInstallation.plist")
        return machine
    }

    @Test func openGLCleanupRemovesTheSetupCredential() throws {
        let machine = try openGLMachine()
        try machine.write(["CredentialIdentifier": "c"], "State/AutomaticSetup.plist")
        try machine.cleanup.retry(configuration: machine.configuration, preMetalGuest: true)
        #expect(machine.removedPasswords == ["c"])
        #expect(machine.saved("State/Install.plist")?["Phase"] == "complete")
    }

    @Test func openGLCleanupWaitsForTheInstallerToBeDetached() throws {
        let machine = try openGLMachine(installState: "installing")
        refused("Installer cleanup is not yet authorized for this Mac.") {
            try machine.cleanup.retry(configuration: machine.configuration, preMetalGuest: true)
        }
        #expect(machine.removedPasswords.isEmpty)
    }

    @Test func openGLCleanupWithNoReceiptOrAlreadyDoneDoesNothing() throws {
        let unproven = try Machine(guest: "lion")
        try unproven.cleanup.retry(configuration: unproven.configuration, preMetalGuest: true)
        #expect(unproven.saved("State/Install.plist") == nil)

        let done = try openGLMachine()
        try done.write(["Phase": "complete", "Identifier": done.identifier], "State/Install.plist")
        try done.write(["CredentialIdentifier": "c"], "State/AutomaticSetup.plist")
        try done.cleanup.retry(configuration: done.configuration, preMetalGuest: true)
        #expect(done.removedPasswords.isEmpty)
    }

    @Test func aMissingPackageSaysHowToGetItBack() {
        #expect(throws: (any Error).self) {
            try loadMachineConfiguration(package: URL(fileURLWithPath: "/nonexistent"))
        }
        do {
            _ = try loadMachineConfiguration(package: URL(fileURLWithPath: "/nonexistent"))
        } catch {
            #expect(error.localizedDescription.hasPrefix("This Mac isn’t available."))
            #expect((error as NSError).userInfo[NSUnderlyingErrorKey] != nil)
        }
    }
}
