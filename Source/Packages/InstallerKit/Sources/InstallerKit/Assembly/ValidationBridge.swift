// The Objective-C face of InstallerInspection and PreparationRecords. Saved plists can hold anything, so these take them
// as they came.
import Foundation

extension GuestMediaPlanBridge {
    @objc(matchesProductVersion:)
    public func matchesProductVersion(_ version: Any?) -> Bool {
        guest.matchesProductVersion(version)
    }
}

@objc(VIMInstallerInspection)
public final class InstallerInspectionBridge: NSObject {
    @objc(guestForBundleIdentifier:)
    public class func guest(bundleIdentifier: Any?) -> String? {
        Guest(installerBundleIdentifier: bundleIdentifier)?.rawValue
    }

    @objc(restoreDiscGuestForProductVersion:)
    public class func restoreDiscGuest(productVersion: Any?) -> String? {
        Guest.restoreDisc(productVersion: productVersion)?.rawValue
    }

    @objc(fileHasApplePartitionMap:)
    public class func fileHasApplePartitionMap(_ url: URL?) -> Bool {
        url.map(DiskHeader.fileHasApplePartitionMap) ?? false
    }

    @objc(fileIsRecognizableDisk:)
    public class func fileIsRecognizableDisk(_ url: URL?) -> Bool {
        url.map(DiskHeader.fileIsRecognizableDisk) ?? false
    }

    @objc(fileIsInstallerPackage:)
    public class func fileIsInstallerPackage(_ url: URL?) -> Bool {
        url.map(DiskHeader.fileIsInstallerPackage) ?? false
    }

    @objc(validateInstaller:guest:error:)
    public class func validateInstaller(_ url: URL?, guest: String?) throws {
        let guest = guest.flatMap(Guest.init(rawValue:))
        let missing: AssemblyFailure =
            guest?.traits.contains(.restoreDVD) == true ? .incompleteRestoreDiscImage : .incompleteInstallerApplication
        guard let url else { throw missing.error }
        if let refusal = InstallerValidation.refusal(forInstaller: url, guest: guest) { throw refusal.error }
    }

    /// Every restore disc has the same resume gate.
    @objc(validateRestoreDiscImage:error:)
    public class func validateRestoreDiscImage(_ url: URL?) throws {
        try validateInstaller(url, guest: Guest.leopard.rawValue)
    }

    @objc(validatePreparedMedia:guest:error:)
    public class func validatePreparedMedia(_ url: URL?, guest: String?) throws {
        guard let url else { throw AssemblyFailure.preparedMediaUnavailable.error }
        if let refusal = InstallerValidation.refusal(forPreparedMedia: url, guest: guest) { throw refusal.error }
    }

    @objc(validateGuestSupport:error:)
    public class func validateGuestSupport(_ directory: URL?) throws {
        guard let directory else { throw AssemblyFailure.guestSupportMissing.error }
        if let refusal = InstallerValidation.refusal(forGuestSupport: directory) { throw refusal.error }
    }

    @objc(restoreDiscIsCompleteAtMount:guest:)
    public class func restoreDiscIsComplete(at mount: URL?, guest: String?) -> Bool {
        guard let mount, let guest = guest.flatMap(Guest.init(rawValue:)) else { return false }
        return InstallerValidation.restoreDiscIsComplete(at: mount, guest: guest)
    }
}

@objc(VIMHybridAsset)
public final class HybridAssetBridge: NSObject {
    fileprivate let value: HybridAsset

    private init(value: HybridAsset) {
        self.value = value
    }

    @objc(assetFromMetadata:)
    public class func asset(metadata: Any?) -> HybridAssetBridge? {
        HybridAsset(metadata: metadata).map(HybridAssetBridge.init(value:))
    }

    @objc public var productVersion: String { value.productVersion }
    @objc public var build: String { value.build }
}

@objc(VIMPreparationRecords)
public final class PreparationRecordsBridge: NSObject {
    @objc(retainedImageNameInRecord:guest:)
    public class func retainedImageName(_ record: [String: Any]?, guest: String) -> String? {
        MediaReceipt.retainedImageName(record, guest: guest)
    }

    @objc(installerNameInRecord:guest:)
    public class func installerName(_ record: [String: Any]?, guest: String) -> String? {
        AssemblyReceipt.installerName(record, guest: guest)
    }

    /// Nil for a guest with no recovery media, as such a receipt must not exist.
    @objc(recoveryReceiptForGuest:media:size:productVersion:partitioned:)
    public class func recoveryReceipt(
        guest: String, media: String, size: Int64, productVersion: String, partitioned: Bool
    ) -> [String: Any]? {
        Guest(rawValue: guest).map {
            MediaReceipt.recovery(
                guest: $0, media: media, size: size, productVersion: productVersion, partitioned: partitioned)
        }
    }

    @objc(hybridReceiptForMedia:size:asset:)
    public class func hybridReceipt(media: String, size: Int64, asset: HybridAssetBridge) -> [String: Any] {
        MediaReceipt.hybrid(media: media, size: size, asset: asset.value)
    }

    @objc(assembledReceiptForGuest:installer:)
    public class func assembledReceipt(guest: String, installer: String) -> [String: Any]? {
        Guest(rawValue: guest).map { AssemblyReceipt.assembled(guest: $0, installer: installer) }
    }

    @objc(pinnedImageReceiptForGuest:installer:)
    public class func pinnedImageReceipt(guest: String, installer: String) -> [String: Any]? {
        assembledReceipt(guest: guest, installer: installer)?.merging(AssemblyReceipt.pinnedImage()) { $1 }
    }

    @objc(recoveryPayloadReceiptForGuest:installer:productVersion:productBuild:)
    public class func recoveryPayloadReceipt(
        guest: String, installer: String, productVersion: String, productBuild: Any?
    ) -> [String: Any]? {
        assembledReceipt(guest: guest, installer: installer)?.merging(
            AssemblyReceipt.recoveryPayload(productVersion: productVersion, productBuild: productBuild as? String)
        ) { $1 }
    }
}

@objc(VIMDownloadRetirement)
public final class DownloadRetirementBridge: NSObject {
    @objc(isOwnedPayload:)
    public class func isOwnedPayload(_ file: URL?) -> Bool {
        file.map(DownloadRetirement.isOwnedPayload) ?? false
    }

    @objc(record:allowsRemovalOfPayloadWithSize:)
    public class func record(_ record: [String: Any]?, allowsRemovalOfPayloadWithSize size: Int64) -> Bool {
        DownloadRetirement.recordAllowsRemoval(record, payloadSize: size)
    }
}
