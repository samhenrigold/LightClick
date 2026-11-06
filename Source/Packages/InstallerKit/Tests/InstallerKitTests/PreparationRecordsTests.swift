import Foundation
import Testing

@testable import InstallerKit

@Suite struct PreparationRecordsTests {
    /// What VIMTigerRestoreProfile.h and VIMTigerInstallerSupport.h add to Tiger's receipt.
    private static var tigerKeys: [String: Any] {
        [
            "TigerRestorePolicyVersion": 1, "TigerControlBootstrapVersion": 8, "DiscTwoExcluded": true,
            "RestoreModelRestrictionRemoved": true
        ]
    }

    private func receipt(_ guest: Guest, partitioned: Bool? = nil) -> [String: Any] {
        if guest == .bigSur {
            let asset = HybridAsset(metadata: ["Assets": [["OSVersion": "11.7", "Build": "20G"]]])
            return MediaReceipt.hybrid(media: "Installer.iso", size: 4096, asset: asset!)
        }
        var receipt = MediaReceipt.recovery(
            guest: guest, media: "Installer.iso", size: 4096, productVersion: guest.version,
            partitioned: partitioned ?? guest.traits.contains(.restoreDVD))
        if guest == .tiger { receipt.merge(Self.tigerKeys) { $1 } }
        return receipt
    }

    /// Plist round trip: what's read back is NSNumbers and strings, not what was written.
    private func saved(_ receipt: [String: Any]) throws -> [String: Any] {
        let data = try PropertyListSerialization.data(fromPropertyList: receipt, format: .xml, options: 0)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    // MARK: - What we write is what we accept

    @Test(arguments: Guest.allCases) func aFreshReceiptIsAccepted(_ guest: Guest) throws {
        let saved = try saved(receipt(guest))
        #expect(MediaReceipt.retainedImageName(saved, guest: guest.rawValue) == "Installer.iso")
        #expect(MediaReceipt.matchesImage(saved, guest: guest.rawValue, mediaName: "Installer.iso", size: 4096))
    }

    @Test(arguments: Guest.allCases) func aReceiptForAnotherGuestIsRefused(_ guest: Guest) throws {
        let saved = try saved(receipt(guest))
        for other in Guest.allCases where other != guest {
            #expect(MediaReceipt.retainedImageName(saved, guest: other.rawValue) == nil)
            #expect(!MediaReceipt.matchesImage(saved, guest: other.rawValue, mediaName: "Installer.iso", size: 4096))
        }
    }

    // MARK: - Exact contents

    @Test func aRecoveryReceiptsExactKeys() throws {
        let lion = try #require(receipt(.lion) as NSDictionary?)
        #expect(
            lion
                == [
                    "FormatVersion": 1, "Guest": "lion", "Stage": "media-created", "Media": "Installer.iso",
                    "Size": 4096,
                    "ProductVersion": "10.7", "BootValidated": false, "FilesystemMetadataPreserved": true,
                    "ReadbackVerified": true, "LegacyBootstrapVersion": 4, "OpenGLSupportVersion": 1
                ] as NSDictionary)
    }

    @Test func leopardsReceiptNamesItsHardwareProfile() {
        let leopard = receipt(.leopard) as NSDictionary
        #expect(leopard["RestoreHardwareProfile"] as? String == "MacBookPro5,3")
        #expect(plistEqual(leopard["LeopardRecoveryMemoryVersion"], 1))
        #expect(plistEqual(leopard["PartitionedInstaller"], true))
        #expect(plistEqual(leopard["LegacyBootstrapVersion"], 5))
    }

    @Test func versionsPerGuest() {
        #expect(Guest.leopard.bootstrapMediaVersion == 5)
        #expect(Guest.sierra.bootstrapMediaVersion == 5)
        #expect(Guest.highSierra.bootstrapMediaVersion == 4)
        #expect(Guest.tiger.bootstrapMediaVersion == 0)
        #expect(Guest.mojave.bootstrapMediaVersion == 0)
        #expect(plistEqual(receipt(.highSierra)["NativeRecoverySystemVersion"], 6))
        #expect(plistEqual(receipt(.sierra)["NativeRecoverySystemVersion"], 1))
        #expect(plistEqual(receipt(.catalina)["SerialRecoveryVersion"], 2))
        #expect(receipt(.bigSur)["ProductBuildVersion"] as? String == "20G")
    }

    @Test func assemblyReceipts() {
        #expect(
            AssemblyReceipt.assembled(guest: .mojave, installer: "A.app") as NSDictionary
                == ["FormatVersion": 1, "Guest": "mojave", "Stage": "assembled", "Installer": "A.app"] as NSDictionary)
        let pinned = PreparationRecordsBridge.pinnedImageReceipt(guest: "lion", installer: "A.app")
        #expect(plistEqual(pinned?["OriginalImagePinned"], true))
        let payload = PreparationRecordsBridge.recoveryPayloadReceipt(
            guest: "mavericks", installer: "A.app", productVersion: "10.9.5", productBuild: "13F34")
        #expect(payload?["ProductVersion"] as? String == "10.9.5")
        #expect(payload?["ProductBuildVersion"] as? String == "13F34")
        #expect(plistEqual(payload?["RecoveryPayloadPinned"], true))
        #expect(PreparationRecordsBridge.assembledReceipt(guest: "unknown", installer: "A.app") == nil)
    }

    // MARK: - Refusals, each by the key that fails

    @Test(arguments: [
        ("FormatVersion", Guest.lion), ("LegacyBootstrapVersion", .lion), ("ReadbackVerified", .lion),
        ("OpenGLSupportVersion", .lion), ("NativeRecoverySystemVersion", .yosemite), ("SerialRecoveryVersion", .mojave),
        ("SignedSharedSupportPackage", .bigSur), ("LeopardRecoveryMemoryVersion", .leopard),
        ("PartitionedInstaller", .snowLeopard), ("TigerRestorePolicyVersion", .tiger),
        ("TigerControlBootstrapVersion", .tiger), ("DiscTwoExcluded", .tiger),
        ("RestoreModelRestrictionRemoved", .tiger),
        ("ReadbackVerified", .tiger), ("Size", .lion), ("Media", .lion), ("Stage", .lion), ("Guest", .lion)
    ])
    func eachRetainedRequirementIsNeeded(_ key: String, _ guest: Guest) throws {
        var without = receipt(guest)
        without[key] = nil
        #expect(MediaReceipt.retainedImageName(try saved(without), guest: guest.rawValue) == nil)
    }

    @Test(arguments: [
        ("FormatVersion", 2, Guest.lion), ("LegacyBootstrapVersion", 3, .lion),
        ("NativeRecoverySystemVersion", 1, .highSierra), ("SerialRecoveryVersion", 1, .mojave),
        ("LeopardRecoveryMemoryVersion", 2, .leopard), ("TigerControlBootstrapVersion", 7, .tiger)
    ])
    func anOlderVersionIsNotRetained(_ key: String, _ value: Int, _ guest: Guest) throws {
        var old = receipt(guest)
        old[key] = value
        #expect(MediaReceipt.retainedImageName(try saved(old), guest: guest.rawValue) == nil)
    }

    @Test func anUnknownImageNameIsNotRetained() throws {
        var other = receipt(.lion)
        other["Media"] = "Other.iso"
        #expect(MediaReceipt.retainedImageName(try saved(other), guest: "lion") == nil)
        other["Media"] = "../Installer.iso"
        #expect(MediaReceipt.retainedImageName(try saved(other), guest: "lion") == nil)
        other["Media"] = "Installer.img"
        #expect(MediaReceipt.retainedImageName(try saved(other), guest: "lion") == "Installer.img")
    }

    @Test func nothingIsRetainedForAnUnknownGuestOrMissingRecord() {
        #expect(MediaReceipt.retainedImageName(nil, guest: "lion") == nil)
        var unknown = receipt(.mojave)
        unknown["Guest"] = "windows"
        #expect(MediaReceipt.retainedImageName(unknown, guest: "windows") == nil)
    }

    /// `-isEqual:` on NSNumber makes `<true/>` and 1 the same, which old receipts could rely on.
    @Test func valuesCompareAsTheyAlwaysDid() {
        #expect(plistEqual(true, 1) && plistEqual(1, true) && plistEqual(1.0, 1))
        #expect(!plistEqual(0, true) && !plistEqual(nil, 1) && !plistEqual("1", 1) && !plistEqual("YES", true))
    }

    @Test func launchCheckSizeAndNameMustMatch() {
        let record = receipt(.lion)
        #expect(MediaReceipt.matchesImage(record, guest: "lion", mediaName: "Installer.iso", size: 4096))
        #expect(!MediaReceipt.matchesImage(record, guest: "lion", mediaName: "Installer.iso", size: 4095))
        #expect(!MediaReceipt.matchesImage(record, guest: "lion", mediaName: "Other.iso", size: 4096))
        #expect(!MediaReceipt.matchesImage(record, guest: nil, mediaName: "Installer.iso", size: 4096))
        #expect(!MediaReceipt.matchesImage(nil, guest: "lion", mediaName: "Installer.iso", size: 4096))
    }

    /// Launch needs no bootstrap version or readback: only retained media does, so older prepared images keep booting.
    @Test func launchIsLaxerThanReuse() {
        let minimal: [String: Any] = [
            "FormatVersion": 1, "Stage": "media-created", "Guest": "lion", "Media": "Installer.iso", "Size": 4096
        ]
        #expect(MediaReceipt.matchesImage(minimal, guest: "lion", mediaName: "Installer.iso", size: 4096))
        #expect(MediaReceipt.retainedImageName(minimal, guest: "lion") == nil)
    }

    @Test func launchRequiresTheDiscAndTigerKeys() {
        var snow = receipt(.snowLeopard)
        snow["PartitionedInstaller"] = nil
        #expect(!MediaReceipt.matchesImage(snow, guest: "snowleopard", mediaName: "Installer.iso", size: 4096))
        for key in Self.tigerKeys.keys {
            var tiger = receipt(.tiger)
            tiger[key] = nil
            #expect(!MediaReceipt.matchesImage(tiger, guest: "tiger", mediaName: "Installer.iso", size: 4096), "\(key)")
        }
    }

    // MARK: - The launch check on real files

    @Test func preparedMediaOnDisk() throws {
        let temporary = try TemporaryDirectory()
        let image = temporary.url.appending(component: "Installer.iso")
        #expect(InstallerValidation.refusal(forPreparedMedia: image, guest: "lion") == .preparedMediaUnavailable)
        try Data().write(to: image)
        #expect(InstallerValidation.refusal(forPreparedMedia: image, guest: "lion") == .preparedMediaUnavailable)
        var bytes = Data(count: 4096)
        try bytes.write(to: image)
        // No receipt: an ordinary image, whatever is in it.
        #expect(InstallerValidation.refusal(forPreparedMedia: image, guest: "lion") == nil)
        let record = temporary.url.appending(component: "Media.plist")
        try saved(receipt(.lion)).withPlist(to: record)
        #expect(InstallerValidation.refusal(forPreparedMedia: image, guest: "lion") == .preparedMediaHeaderUnreadable)
        bytes.replaceSubrange(512..<520, with: Data("EFI PART".utf8))
        try bytes.write(to: image)
        #expect(InstallerValidation.refusal(forPreparedMedia: image, guest: "lion") == nil)
        #expect(InstallerValidation.refusal(forPreparedMedia: image, guest: "mavericks") == .preparedMediaChanged)
        // An oversized or linked receipt isn't a preparation record.
        try Data(count: 65537).write(to: record)
        #expect(InstallerValidation.refusal(forPreparedMedia: image, guest: "lion") == .preparedMediaChanged)
        try FileManager.default.removeItem(at: record)
        let elsewhere = temporary.url.appending(component: "elsewhere.plist")
        try saved(receipt(.lion)).withPlist(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: elsewhere)
        #expect(InstallerValidation.refusal(forPreparedMedia: image, guest: "lion") == .preparedMediaChanged)
        // A linked image isn't one we prepared.
        let link = temporary.url.appending(component: "link.iso")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        #expect(InstallerValidation.refusal(forPreparedMedia: link, guest: "lion") == .preparedMediaUnavailable)
    }

    // MARK: - Assembly records

    @Test func anInstallerNameMustBeOneComponent() {
        let good: [String: Any] = ["FormatVersion": 1, "Guest": "lion", "Stage": "assembled", "Installer": "A.app"]
        #expect(AssemblyReceipt.installerName(good, guest: "lion") == "A.app")
        #expect(AssemblyReceipt.installerName(good, guest: "mojave") == nil)
        #expect(AssemblyReceipt.installerName(nil, guest: "lion") == nil)
        for bad: Any in ["../A.app", "a/b.app", "/A.app", "A.app/", 7] {
            var record = good
            record["Installer"] = bad
            #expect(AssemblyReceipt.installerName(record, guest: "lion") == nil, "\(bad)")
        }
        var stage = good
        stage["Stage"] = "media-created"
        #expect(AssemblyReceipt.installerName(stage, guest: "lion") == nil)
    }

    // MARK: - Retiring a download

    private static let key = String(repeating: "a", count: 64)
    private static let source = "https://swcdn.apple.com/content/downloads/x/Payload.pkg"

    @Test func onlyAKeyedPayloadUnderDownloadsIsOwned() {
        func file(_ path: String) -> URL { URL(filePath: path) }
        #expect(DownloadRetirement.isOwnedPayload(file("/L/Downloads/\(Self.key)/Payload.pkg")))
        #expect(!DownloadRetirement.isOwnedPayload(file("/L/Downloads/\(Self.key)/Payload.partial")))
        #expect(!DownloadRetirement.isOwnedPayload(file("/L/Downloads/\(Self.key)/Install macOS.app")))
        #expect(!DownloadRetirement.isOwnedPayload(file("/L/Other/\(Self.key)/Payload.pkg")))
        #expect(!DownloadRetirement.isOwnedPayload(file("/Users/me/Payload.pkg")))
        #expect(!DownloadRetirement.isOwnedPayload(file("/L/Downloads/\(String(Self.key.dropLast()))/Payload.pkg")))
        let upper = Self.key.uppercased()
        #expect(!DownloadRetirement.isOwnedPayload(file("/L/Downloads/\(upper)/Payload.pkg")))
        let notHex = String(repeating: "g", count: 64)
        #expect(!DownloadRetirement.isOwnedPayload(file("/L/Downloads/\(notHex)/Payload.pkg")))
    }

    @Test func aRecordMustShowACompleteApprovedTransferOfThisLength() {
        let good: [String: Any] = ["FormatVersion": 1, "Complete": true, "Length": 100, "SourceURL": Self.source]
        #expect(DownloadRetirement.recordAllowsRemoval(good, payloadSize: 100))
        #expect(!DownloadRetirement.recordAllowsRemoval(good, payloadSize: 99))
        #expect(!DownloadRetirement.recordAllowsRemoval(good, payloadSize: 0))
        #expect(!DownloadRetirement.recordAllowsRemoval(nil, payloadSize: 100))
        for key in good.keys {
            var without = good
            without[key] = nil
            #expect(!DownloadRetirement.recordAllowsRemoval(without, payloadSize: 100), "\(key)")
        }
        for (key, value) in [
            ("FormatVersion", 2 as Any), ("Complete", false), ("Length", "100"),
            ("SourceURL", "https://example.com/a.pkg"),
            ("SourceURL", ""), ("SourceURL", 7)
        ] {
            var changed = good
            changed[key] = value
            #expect(!DownloadRetirement.recordAllowsRemoval(changed, payloadSize: 100), "\(key)")
        }
        var zero = good
        zero["Length"] = 0
        #expect(!DownloadRetirement.recordAllowsRemoval(zero, payloadSize: 0))
    }

    /// InstallerDownload writes the journal this reads, so a change to either has to keep them agreeing.
    @Test func theDownloadJournalsOwnFormatIsAccepted() throws {
        let temporary = try TemporaryDirectory()
        let file = temporary.url.appending(component: "Download.plist")
        var journal = DownloadJournal(sourceURL: Self.source)
        journal.length = 100
        journal.isComplete = true
        try journal.save(to: file)
        let saved = try #require(NSDictionary(contentsOf: file) as? [String: Any])
        #expect(DownloadRetirement.recordAllowsRemoval(saved, payloadSize: 100))
    }
}

extension [String: Any] {
    fileprivate func withPlist(to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: self, format: .xml, options: 0).write(to: url)
    }
}
