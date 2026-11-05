import Foundation
import Testing

@testable import MachineKit

/// Test fixtures. Nothing here touches a real library: every package lives in its own temporary directory.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: "plist")))
    }

    static let sourceRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A configuration that passes every check, for one test to break.
    static let configuration = MachineConfiguration(values: [
        "FormatVersion": 1, "Identifier": "CFAD1CCA-49A1-450C-8559-81FEDA907D98", "Guest": "mojave", "CPUCount": 4,
        "MemoryMiB": 4096, "Disk": "Disks/System.qcow2", "NVRAM": "Firmware/NVRAM.fd", "Firmware": "Firmware/CODE.fd",
        "BootMedia": "Firmware/EFI.img", "FirmwareSource": "application"
    ])

    /// A package that passes `validate(package:)`, deleted when the test ends.
    static func withPackage<Result>(
        named name: String = "Fixture", _ body: (URL) throws -> Result
    ) throws -> Result {
        let root = FileManager.default.temporaryDirectory.appending(path: "machinekit-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appending(path: name + ".vintelmac")
        for folder in ["Disks", "Firmware", "State", "Installation"] {
            try FileManager.default.createDirectory(
                at: package.appending(path: folder), withIntermediateDirectories: true)
        }
        for file in ["Disks/System.qcow2", "Firmware/NVRAM.fd", "Firmware/CODE.fd", "Firmware/EFI.img"] {
            try Data("fixture".utf8).write(to: package.appending(path: file))
        }
        return try body(package)
    }

    static let report = GuestReport(values: [
        "Guest": "mojave", "InstalledSystemCandidate": true, "DesktopRunning": true, "LiveRoot": true,
        "KernelMatchesSystem": true, "ProductBuildVersion": "new-build", "VolumeUUID": "same-volume",
        "BootSessionUUID": "new-boot"
    ])

    static let identity: PropertyListValue = "00112233-4455-6677-8899-AABBCCDDEEFF"

    /// A verified transaction on the old build, which `report` supersedes.
    static let verifiedJournal = GuestInstallationJournal(values: [
        "FormatVersion": 1, "TransactionID": identity, "Phase": "graphics-verified",
        "Preparation": [
            "TransactionID": identity,
            "GuestReport": ["Guest": "mojave", "ProductBuildVersion": "old-build", "VolumeUUID": "same-volume"]
        ],
        "GuestResult": [
            "TransactionID": identity, "Phase": "awaiting-reboot", "FilesPublished": true, "RebootRequired": true,
            "ProductBuildVersion": "old-build", "VolumeUUID": "same-volume"
        ],
        "PostBootVerification": [
            "TransactionID": identity, "VerifiedAfterReboot": true, "MetalCommandVerified": true,
            "ProductBuildVersion": "old-build", "VolumeUUID": "same-volume", "BootSessionUUID": "old-boot"
        ]
    ])
}

extension GuestReport {
    func setting(_ key: String, _ value: PropertyListValue?) -> GuestReport {
        var copy = self
        copy.values[key] = value
        return copy
    }
}

extension GuestInstallationJournal {
    func setting(_ key: String, _ value: PropertyListValue?) -> GuestInstallationJournal {
        var copy = self
        copy.values[key] = value
        return copy
    }

    func setting(in parent: String, _ key: String, _ value: PropertyListValue?) -> GuestInstallationJournal {
        var dictionary = values[parent]?.dictionary ?? [:]
        dictionary[key] = value
        return setting(parent, .dictionary(dictionary))
    }
}

extension MachineConfiguration {
    func setting(_ key: MachineConfiguration.Key, _ value: PropertyListValue?) -> MachineConfiguration {
        var copy = self
        copy[key] = value
        return copy
    }
}
