import Foundation
import InstallerKit

/// What each step of guest preparation must have heard from the guest before the next may start. VIMGuestPreparation
/// runs the steps and owns the journal. A check throws a message for the user, and its caller prefers any transport
/// error it already has.
public struct GuestPreparationChecks: Sendable {
    /// What every later step must still agree with.
    public let initialReport: GuestReport

    public init(initialReport: GuestReport) {
        self.initialReport = initialReport
    }

    /// A headless repair after an update doesn't need a desktop, which may be what's broken.
    public func verifyInitialReport(allowingHeadlessRepair headless: Bool) throws(GuestPreparationError) {
        guard initialReport.guest?.traits.contains(.paravirtualizedGraphics) == true,
            initialReport.isLiveInstalledSystem, headless || initialReport.isDesktopRunning,
            initialReport["VolumeUUID"].nonEmptyString != nil
        else { throw .unsuitableSystem }
    }

    private static let archiveNames = ["payload.tar.xz", "payload.tar.gz"]

    /// `stage-media` must report the directory it was given.
    public static func verifyStaging(_ result: GuestCommandResult, directory: String) throws(GuestPreparationError) {
        guard result.json?["Directory"].isEqual(.string(directory)) == true else {
            throw .stagingNotVerified(diagnostic: result.diagnostic)
        }
    }

    /// The staged archive must be one of the known names and not empty, and the disc must be identifiable for removal.
    public static func verifyStagedCopy(_ transfer: [String: PropertyListValue]) throws(GuestPreparationError) {
        guard let archive = transfer["Archive"]?.string, archiveNames.contains(archive),
            transfer["Files"]?.array?.contains(where: { names($0, archive) }) == true,
            transfer["FilesStaged"].isTrue
        else { throw .stagedCopyIncomplete }
        guard transfer["MediaDevice"]?.string?.matchesWholly("^/dev/disk[0-9]+(s[0-9]+)*$") == true else {
            throw .supportDiscDeviceUnknown
        }
    }

    private static func names(_ file: PropertyListValue, _ archive: String) -> Bool {
        guard let file = file.dictionary, file["Name"].isEqual(.string(archive)) else { return false }
        // `-longLongValue`, which also reads a number out of a string and truncates a fraction.
        switch file["Size"] {
        case .number(let size)?: return size.int64Value > 0
        case .string(let size)?: return (size as NSString).longLongValue > 0
        default: return false
        }
    }

    /// What's journaled about the unmount. The output is cut at 8 KB, which can split a character and make it non-text.
    public static func unmountEvidence(_ result: GuestCommandResult) -> [String: PropertyListValue] {
        var evidence = result.values.filter { $0.key == "exitcode" || $0.key == "signal" }
        for (key, data) in [("stdout", result.standardOutput), ("stderr", result.standardError)] where !data.isEmpty {
            let text = GuestCommandResult.text(data.prefix(8192))
            evidence[key] = .string(text ?? "Non-text disk unmount response")
        }
        return evidence
    }

    public static func verifyUnmount(_ result: GuestCommandResult) throws(GuestPreparationError) {
        guard !result.succeeded else { return }
        if unmountEvidence(result)["stderr"]?.string?.contains("loginwindow") == true {
            throw .supportDiscHeldByLoginWindow
        }
        throw .supportDiscInUse
    }

    public static func verifyUtilities(_ result: GuestCommandResult) throws(GuestPreparationError) {
        guard result.succeeded else { throw .utilitiesNotPrepared }
    }

    public func verifyEnvironment(_ result: GuestCommandResult) throws(GuestPreparationError) {
        let admission = result.json ?? [:]
        guard admission["Eligible"].isTrue, admission["VolumeUUID"].isEqual(initialReport["VolumeUUID"]),
            admission["ProductBuildVersion"].isEqual(initialReport["ProductBuildVersion"])
        else { throw .environmentNotEligible(diagnostic: result.diagnostic) }
    }

    /// Foundation in Catalina canonicalizes `/private/var` to `/var`. This accepts only that exact alias of the known
    /// private staging paths.
    public static func verifyExtraction(_ result: GuestCommandResult, payload: String) throws(GuestPreparationError) {
        let receipt = result.json ?? [:]
        var samePath = receipt["PayloadDirectory"].isEqual(.string(payload))
        if payload.hasLiteralPrefix("/private/var/tmp/VirtualIntelMac.")
            || payload.hasLiteralPrefix("/private/var/db/VirtualIntelMac.")
        {
            let alias = (payload as NSString).substring(from: "/private".utf16.count)
            samePath = samePath || receipt["PayloadDirectory"].isEqual(.string(alias))
        }
        guard receipt["Extracted"].isTrue, receipt["Installed"].isFalse, samePath else { throw .extractionFailed }
    }

    public func verifyPreparedFiles(_ result: GuestCommandResult) throws(GuestPreparationError) {
        let prepared = result.json ?? [:]
        guard prepared["Prepared"].isTrue, prepared["Installed"].isFalse,
            prepared["Guest"].isEqual(initialReport["Guest"]),
            prepared["ProductBuildVersion"].isEqual(initialReport["ProductBuildVersion"])
        else { throw .filePreparationFailed }
    }

    public func verifyUnchanged(_ report: GuestReport) throws(GuestPreparationError) {
        guard report["LiveRoot"].isTrue, report["KernelMatchesSystem"].isTrue,
            report["VolumeUUID"].isEqual(initialReport["VolumeUUID"]),
            report["ProductBuildVersion"].isEqual(initialReport["ProductBuildVersion"])
        else { throw .guestChanged }
    }

    /// Planning records recovery information and changes nothing, so a plan that claims more than that is refused.
    public func verifyPlan(_ result: GuestCommandResult) throws(GuestPreparationError) {
        let plan = result.json ?? [:]
        guard plan["Planned"].isTrue, plan["Installed"].isFalse, plan["Ready"].isFalse,
            plan["Guest"].isEqual(initialReport["Guest"])
        else { throw .planningFailed }
    }

    public static func verifyTransaction(_ plan: [String: PropertyListValue]) throws(GuestPreparationError) {
        guard plan["TransactionID"].isUUID else { throw .planHasNoTransaction }
    }
}
