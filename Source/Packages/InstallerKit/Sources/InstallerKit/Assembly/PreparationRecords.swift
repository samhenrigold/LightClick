// The plists preparation leaves beside its output, and what they must say before anything trusts or removes that output.
// A saved plist is untrusted. Values compare as `-isEqual:` did, so `<true/>` and 1 are the same number.
import Foundation

extension Guest {
    /// Earlier Leopard images can fall through to the manual language picker before Disk Arbitration publishes the already
    /// attached setup medium. Sierra's updated helpers recover a lost native first-login handoff. Zero without the bootstrap.
    public var bootstrapMediaVersion: Int {
        guard recoveryAutomation.usesBootstrap else { return 0 }
        return self == .leopard || self == .sierra ? 5 : 4
    }
}

/// A Media.plist: the receipt for a finished bootable image.
public enum MediaReceipt {
    private static func isCurrentFormat(_ record: [String: Any]) -> Bool { plistEqual(record["FormatVersion"], 1) }

    /// The Tiger policy keys VIMTigerRestoreProfile.h and VIMTigerInstallerSupport.h record.
    private static func holdsTigerPolicy(_ record: [String: Any]) -> Bool {
        plistEqual(record["TigerRestorePolicyVersion"], 1) && plistEqual(record["TigerControlBootstrapVersion"], 8)
            && plistEqual(record["DiscTwoExcluded"], true) && plistEqual(record["RestoreModelRestrictionRemoved"], true)
    }

    /// Whether a receipt describes this image for this guest, at launch.
    public static func matchesImage(_ record: [String: Any]?, guest: String?, mediaName: String, size: Int64) -> Bool {
        guard let record, let guest, isCurrentFormat(record), record["Stage"] as? String == "media-created",
            record["Guest"] as? String == guest, record["Media"] as? String == mediaName,
            let recorded = record["Size"] as? NSNumber, recorded.int64Value == size
        else { return false }
        let known = Guest(rawValue: guest)
        if known?.traits.contains(.restoreDVD) == true, !plistEqual(record["PartitionedInstaller"], true) {
            return false
        }
        return known != .tiger || holdsTigerPolicy(record)
    }

    /// The image name to reuse for `guest`, or nil unless the receipt shows media made by the current preparation for it.
    /// An unknown guest has no retained media.
    public static func retainedImageName(_ record: [String: Any]?, guest: String) -> String? {
        guard let record, let known = Guest(rawValue: guest), isCurrentFormat(record),
            record["Guest"] as? String == guest, record["Stage"] as? String == "media-created",
            record["Size"] is NSNumber
        else { return nil }
        let automation = known.recoveryAutomation
        if automation.usesBootstrap {
            guard plistEqual(record["LegacyBootstrapVersion"], known.bootstrapMediaVersion as NSNumber),
                plistEqual(record["ReadbackVerified"], true), plistEqual(record["OpenGLSupportVersion"], 1)
            else { return nil }
        }
        if known == .bigSur, !plistEqual(record["SignedSharedSupportPackage"], true) { return nil }
        if automation == .serialAgent, !plistEqual(record["SerialRecoveryVersion"], 2) { return nil }
        if known == .leopard, !plistEqual(record["LeopardRecoveryMemoryVersion"], 1) { return nil }
        if case .nativeInstaller(let version) = automation,
            !plistEqual(record["NativeRecoverySystemVersion"], version as NSNumber)
        {
            return nil
        }
        if known.traits.contains(.restoreDVD), !plistEqual(record["PartitionedInstaller"], true) { return nil }
        if known == .tiger, !holdsTigerPolicy(record) || !plistEqual(record["ReadbackVerified"], true) { return nil }
        guard let media = record["Media"] as? String, ["Installer.iso", "Installer.img"].contains(media) else {
            return nil
        }
        return media
    }

    /// The receipt for a verified recovery image. A guest with no recovery media has no such receipt.
    public static func recovery(guest: Guest, media: String, size: Int64, productVersion: String, partitioned: Bool)
        -> [String: Any]
    {
        let automation = guest.recoveryAutomation
        var receipt: [String: Any] = [
            "FormatVersion": 1, "Guest": guest.rawValue, "Stage": "media-created", "Media": media, "Size": size,
            "ProductVersion": productVersion, "BootValidated": false, "FilesystemMetadataPreserved": true,
            "ReadbackVerified": true, "LegacyBootstrapVersion": guest.bootstrapMediaVersion
        ]
        if automation.usesBootstrap { receipt["OpenGLSupportVersion"] = 1 }
        if automation == .serialAgent { receipt["SerialRecoveryVersion"] = 2 }
        if case .nativeInstaller(let version) = automation { receipt["NativeRecoverySystemVersion"] = version }
        if partitioned { receipt["PartitionedInstaller"] = true }
        if guest == .leopard {
            receipt["RestoreHardwareProfile"] = "MacBookPro5,3"
            receipt["LeopardRecoveryMemoryVersion"] = 1
        }
        return receipt
    }

    /// The receipt for Big Sur's hybrid image.
    public static func hybrid(media: String, size: Int64, asset: HybridAsset) -> [String: Any] {
        [
            "FormatVersion": 1, "Guest": Guest.bigSur.rawValue, "Stage": "media-created", "Media": media, "Size": size,
            "ProductVersion": asset.productVersion, "ProductBuildVersion": asset.build, "BootValidated": false,
            "SignedSharedSupportPackage": true
        ]
    }
}

/// An Assembly.plist: the receipt for an assembled installer app.
public enum AssemblyReceipt {
    public static func assembled(guest: Guest, installer: String) -> [String: Any] {
        ["FormatVersion": 1, "Guest": guest.rawValue, "Stage": "assembled", "Installer": installer]
    }

    /// Added when the installer came from a disk image whose bytes the catalog pins.
    public static func pinnedImage() -> [String: Any] { ["OriginalImagePinned": true] }

    /// Added when the installer came from Mavericks' pinned recovery payload.
    public static func recoveryPayload(productVersion: String, productBuild: String?) -> [String: Any] {
        var receipt: [String: Any] = ["ProductVersion": productVersion, "RecoveryPayloadPinned": true]
        receipt["ProductBuildVersion"] = productBuild
        return receipt
    }

    /// The installer named by a receipt for `guest`, or nil. A name that isn't a single path component is refused.
    public static func installerName(_ record: [String: Any]?, guest: String) -> String? {
        guard let record, plistEqual(record["FormatVersion"], 1), record["Guest"] as? String == guest,
            record["Stage"] as? String == "assembled", let name = record["Installer"] as? String,
            name == (name as NSString).lastPathComponent
        else { return nil }
        return name
    }
}

/// When a completed download may be removed. WRITES: this guards deleting a file, so every check is a refusal. Only an
/// app-owned completed Apple transfer qualifies; active downloads and user-selected installers never do.
public enum DownloadRetirement {
    /// Downloads are SHA-256 keyed with a fixed payload basename: `.../Downloads/<64 lowercase hex>/Payload.pkg`.
    public static func isOwnedPayload(_ file: URL) -> Bool {
        let directory = file.deletingLastPathComponent()
        let key = directory.lastPathComponent
        return file.lastPathComponent == "Payload.pkg"
            && directory.deletingLastPathComponent().lastPathComponent == "Downloads" && key.utf8.count == 64
            && key.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Whether a transfer's Download.plist shows it finished from an approved source and its payload has that exact length.
    public static func recordAllowsRemoval(_ record: [String: Any]?, payloadSize: Int64) -> Bool {
        guard let record, plistEqual(record["FormatVersion"], 1), plistEqual(record["Complete"], true),
            let length = record["Length"] as? NSNumber, payloadSize > 0, payloadSize == length.int64Value,
            let source = record["SourceURL"] as? String, let url = NSURL(string: source) as URL?
        else { return false }
        return InstallerSource.isApproved(url)
    }
}
