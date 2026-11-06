import Foundation
import Testing

@testable import MachineKit

@Suite struct MachineRepairClaimsTests {
    private let package: URL
    private let identity = UUID().uuidString
    private let configuration = MachineConfiguration(values: [
        "Identifier": "m", "Guest": "catalina", "InstallState": "installed"
    ])

    init() throws {
        package = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("State"), withIntermediateDirectories: true)
    }

    private func write(_ value: [String: Any], _ relative: String) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            .write(to: package.appendingPathComponent(relative))
    }

    private var claims: MachineRepairClaims { MachineRepairClaims(package: package, configuration: configuration) }

    private var updated: GuestReport {
        GuestReport(values: [
            "Guest": "catalina", "InstalledSystemCandidate": true, "LiveRoot": true, "KernelMatchesSystem": true,
            "DesktopRunning": true, "SetupComplete": true, "VolumeUUID": "volume", "ProductBuildVersion": "19H2036",
            "BootSessionUUID": "updated-boot"
        ])
    }

    private func writeVerifiedJournal() throws {
        let terminal: [String: Any] = [
            "TransactionID": identity, "Phase": "awaiting-reboot", "RebootRequired": true, "FilesPublished": true,
            "ProductBuildVersion": "19H15", "VolumeUUID": "volume", "BootSessionUUID": "before"
        ]
        let verified: [String: Any] = [
            "TransactionID": identity, "VerifiedAfterReboot": true, "MetalCommandVerified": true,
            "ProductBuildVersion": "19H15", "VolumeUUID": "volume", "BootSessionUUID": "after"
        ]
        try write(
            [
                "FormatVersion": 1, "TransactionID": identity, "Phase": "graphics-verified", "GuestResult": terminal,
                "PostBootVerification": verified,
                "Preparation": [
                    "TransactionID": identity,
                    "GuestReport": ["Guest": "catalina", "ProductBuildVersion": "19H15", "VolumeUUID": "volume"]
                ] as [String: Any]
            ], "State/GuestInstallation.plist")
    }

    private var claimFile: URL { package.appendingPathComponent("State/UpdateRepairs/19H2036.plist") }

    @Test func noVerifiedInstallationMeansNoRepair() throws {
        #expect(try !claims.authorizeUpdateRepair(report: updated, claim: true))
        #expect(!FileManager.default.fileExists(atPath: claimFile.path))
    }

    @Test func askingCreatesNoClaim() throws {
        try writeVerifiedJournal()
        #expect(try claims.authorizeUpdateRepair(report: updated, claim: false))
        #expect(!FileManager.default.fileExists(atPath: claimFile.path))
    }

    @Test func aClaimRecordsWhatItReplaced() throws {
        try writeVerifiedJournal()
        #expect(try claims.authorizeUpdateRepair(report: updated, claim: true))
        let saved = GuestInstallationTransaction.record(at: claimFile)
        #expect(saved?["PreviousBuild"] == "19H15")
        #expect(saved?["PreviousTransactionID"] == .string(identity))
        #expect(saved?["Phase"] == "claimed")
    }

    @Test func aBuildIsClaimedOnce() throws {
        try writeVerifiedJournal()
        #expect(try claims.authorizeUpdateRepair(report: updated, claim: true))
        #expect(try !claims.authorizeUpdateRepair(report: updated, claim: true))
    }

    @Test func aFileWhereTheFolderBelongsStopsIt() throws {
        try writeVerifiedJournal()
        try Data().write(to: package.appendingPathComponent("State/UpdateRepairs"))
        #expect(throws: MachinePackageIssue.self) { try claims.authorizeUpdateRepair(report: updated, claim: true) }
    }

    @Test func aHeldConfigurationLockAsksToTryAgain() throws {
        var locks = FileLocks()
        let held = locks.acquire(package.appendingPathComponent("State/Configuration.lock"))
        #expect(held)
        defer { locks.release() }
        #expect(throws: MachinePackageIssue("This Mac’s settings are being saved. Please try again.")) {
            try claims.authorizeUpdateRepair(report: updated, claim: true)
        }
    }

    @Test func anIneligibleReportSaysSoWithNoError() throws {
        #expect(try !claims.claimAutomaticInstallation(report: GuestReport(values: [:])))
        #expect(try !claims.authorizeUpdateRepair(report: GuestReport(values: [:]), claim: true))
    }

    @Test func qcowSizesComeFromTheHeader() {
        var header = [UInt8](repeating: 0, count: 32)
        header.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xfb])
        header[7] = 3
        header[28] = 1
        #expect(MachineDisk.qcowVirtualSize(header) == 1 << 24)
        header[7] = 4
        #expect(MachineDisk.qcowVirtualSize(header) == nil)
        #expect(MachineDisk.qcowVirtualSize([0, 1]) == nil)
    }

    @Test func aRecordedCapacityWinsAndABadOneFallsBack() throws {
        #expect(MachineDisk.capacity(recordedGiB: 64, diskPath: nil, package: package) == 64 << 30)
        #expect(MachineDisk.capacity(recordedGiB: 0, diskPath: nil, package: package) == 0)
        #expect(MachineDisk.capacity(recordedGiB: "64", diskPath: "missing", package: package) == 0)
        var header = [UInt8](repeating: 0, count: 32)
        header.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xfb])
        header[7] = 2
        header[31] = 9
        try Data(header).write(to: package.appendingPathComponent("disk.qcow2"))
        #expect(MachineDisk.capacity(recordedGiB: 2_000_000, diskPath: "disk.qcow2", package: package) == 9)
    }

    @Test func aMoveUpdatesEverythingRememberedByPath() throws {
        let suite = "MachineRelocationTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/a", "/b"], forKey: "VIMLibraryOrder-/lib")
        defaults.set(["/a"], forKey: "VIMRegisteredPackages")
        defaults.set(["/a": ["Name": "A"]], forKey: "VIMLibraryKnown-/lib")
        defaults.set(["Machine": "/a", "Name": "A"], forKey: "VIMCreationJob")
        defaults.set("sam", forKey: "VIMGuestUsername-/a")
        MovedPackagePreferences.updatePreferences(defaults, from: "/a", to: "/z")
        #expect(defaults.array(forKey: "VIMLibraryOrder-/lib") as? [String] == ["/z", "/b"])
        #expect(defaults.array(forKey: "VIMRegisteredPackages") as? [String] == ["/z"])
        let known = defaults.dictionary(forKey: "VIMLibraryKnown-/lib")
        #expect(known?["/a"] == nil && known?["/z"] != nil)
        #expect(defaults.dictionary(forKey: "VIMCreationJob")?["Machine"] as? String == "/z")
        #expect(defaults.string(forKey: "VIMGuestUsername-/z") == "sam")
        #expect(defaults.object(forKey: "VIMGuestUsername-/a") == nil)
    }
}
