import Foundation
import InstallerKit

/// State/GuestInstallation.plist: the record of one graphics installation transaction. Each decision here insists that
/// the transaction, the guest, the volume and the build all agree.
public struct GuestInstallationJournal: Sendable {
    public var values: [String: PropertyListValue]

    public init(values: [String: PropertyListValue]) {
        self.values = values
    }

    subscript(key: String) -> PropertyListValue? { values[key] }

    private var verification: PropertyListValue? {
        self["PostBootVerification"] ?? self["PreviousPostBootVerification"]
    }

    private var preparedReport: PropertyListValue? { self["Preparation"]["GuestReport"] }

    /// Published files that a reboot will load. A preparation receipt alone, an interrupted publication or a rollback
    /// must never switch a fresh installation to a driver it can't yet load.
    public func hasPublishedGraphics(for guest: Guest?) -> Bool {
        guard let guest, self["FormatVersion"].isEqual(1), self["TransactionID"].isUUID,
            self["GuestResult"].isDictionary,
            self["Preparation"].isDictionary
        else { return false }
        let identity = self["TransactionID"]
        let result = self["GuestResult"]
        return (self["Phase"].isEqual("awaiting-reboot") || self["Phase"].isEqual("graphics-verified"))
            && result["Phase"].isEqual("awaiting-reboot") && result["TransactionID"].isEqual(identity)
            && self["Preparation"]["TransactionID"].isEqual(identity) && preparedReport.isDictionary
            && preparedReport["Guest"].isEqual(.string(guest.rawValue))
            && preparedReport["ProductBuildVersion"].isEqual(result["ProductBuildVersion"])
            && preparedReport["VolumeUUID"].isEqual(result["VolumeUUID"]) && result["FilesPublished"].isTrue
            && result["RebootRequired"].isTrue
    }

    /// Whether a macOS update replaced a verified installation. An old verified transaction isn't an uncertain new
    /// write merely because the update removed its verifier, and it's the only thing that may authorize another. A new
    /// attempt has a new ID, so it can never reuse this proof.
    public func isSuperseded(by report: GuestReport) -> Bool {
        let identity = self["TransactionID"]
        let result = self["GuestResult"]
        let prepared = preparedReport
        let verified = verification
        guard self["FormatVersion"].isEqual(1), identity.isUUID, result.isDictionary, self["Preparation"].isDictionary,
            prepared.isDictionary, verified.isDictionary
        else { return false }
        let terminal = self["Phase"].isEqual("graphics-verified") || self["Phase"].isEqual("awaiting-reboot")
        let readFailed = self["Phase"].isEqual("outcome-unknown") && self["ReconciliationError"].nonEmptyString != nil
        guard terminal || readFailed, result["Phase"].isEqual("awaiting-reboot"), result["FilesPublished"].isTrue,
            result["RebootRequired"].isTrue, result["TransactionID"].isEqual(identity),
            self["Preparation"]["TransactionID"].isEqual(identity), verified["TransactionID"].isEqual(identity),
            verified["VerifiedAfterReboot"].isTrue, verified["MetalCommandVerified"].isTrue
        else { return false }
        guard report.isLiveInstalledSystem, report.guest?.traits.contains(.paravirtualizedGraphics) == true,
            prepared["Guest"].isEqual(report["Guest"]), report.hasCompleteIdentity
        else { return false }
        guard let previous = verified["ProductBuildVersion"].nonEmptyString else { return false }
        let previousBuild = PropertyListValue.string(previous)
        return !report["ProductBuildVersion"].isEqual(previousBuild)
            && result["ProductBuildVersion"].isEqual(previousBuild)
            && prepared["ProductBuildVersion"].isEqual(previousBuild)
            && verified["VolumeUUID"].isEqual(report["VolumeUUID"])
            && result["VolumeUUID"].isEqual(report["VolumeUUID"])
            && prepared["VolumeUUID"].isEqual(report["VolumeUUID"])
            && verified["BootSessionUUID"].nonEmptyString != nil
            && !verified["BootSessionUUID"].isEqual(report["BootSessionUUID"])
    }

    /// A claim that already exists may be retried once, and only for a failure before dispatch: the old proven journal
    /// is still here, with its original ID and a failed read. A dispatched installation creates a new ID, so it can't
    /// match.
    public func allowsRepairRecovery(
        claim: [String: PropertyListValue]?, configuration: MachineConfiguration, report: GuestReport
    ) -> Bool {
        guard let claim, let previous = verification["ProductBuildVersion"] else { return false }
        return self["Phase"].isEqual("outcome-unknown") && self["ReconciliationError"].nonEmptyString != nil
            && claim["FormatVersion"].isEqual(1) && claim["Phase"].isEqual("claimed")
            && claim["MachineIdentifier"].isEqual(configuration[.identifier])
            && claim["PreviousTransactionID"].isEqual(self["TransactionID"]) && claim["PreviousBuild"].isEqual(previous)
            && claim["GuestReport"]["VolumeUUID"].isEqual(report["VolumeUUID"])
            && claim["GuestReport"]["ProductBuildVersion"].isEqual(report["ProductBuildVersion"])
    }

    /// The installer may be retired only after a persisted Metal proof after reboot, and a report from the same system.
    /// A verified installation survives ordinary later reboots, so the boot itself needn't match.
    public func authorizesInstallerCleanup(report: GuestReport, guest: Guest?) -> Bool {
        let verified = self["PostBootVerification"]
        return self["Phase"].isEqual("graphics-verified") && verified["TransactionID"].isEqual(self["TransactionID"])
            && verified["VerifiedAfterReboot"].isTrue && verified["MetalCommandVerified"].isTrue
            && report.isLiveInstalledSystem && report.isFrom(guest)
            && report["VolumeUUID"].isEqual(verified["VolumeUUID"])
            && report.bootSessionUUID != nil && verified["BootSessionUUID"].nonEmptyString != nil
            && report["ProductBuildVersion"].isEqual(verified["ProductBuildVersion"])
    }

    /// The baseline to keep software video across an updater's reboots, or nil if there's no verified one. Firmware may
    /// still select software video without it: that must not invent authorization for an automatic repair.
    public func updaterDisplayRecord(guest: Guest, startedAt: Date) -> [String: PropertyListValue]? {
        let verified = verification
        guard verified.isDictionary, verified["TransactionID"].isEqual(self["TransactionID"]),
            let identity = self["TransactionID"], let build = verified["ProductBuildVersion"].nonEmptyString,
            let volume = verified["VolumeUUID"].nonEmptyString, verified["VerifiedAfterReboot"].isTrue,
            verified["MetalCommandVerified"].isTrue,
            self["GuestResult"]["ProductBuildVersion"].isEqual(.string(build)),
            self["GuestResult"]["VolumeUUID"].isEqual(.string(volume))
        else { return nil }
        return [
            "FormatVersion": 1, "Guest": .string(guest.rawValue), "PreviousTransactionID": identity,
            "PreviousBuild": .string(build), "VolumeUUID": .string(volume), "StartedAt": .date(startedAt)
        ]
    }
}

/// What decides between software video and paravirtualized graphics at launch. Media ownership and display selection
/// are independent: a completed native installation boots PVG for verification while its installer is still retained.
public struct InstallerDisplayEvidence: Sendable {
    public var configuration: MachineConfiguration
    public var journal: GuestInstallationJournal
    /// State/UpdateDisplay.plist
    public var updater: [String: PropertyListValue]?
    /// State/NativeBigSurDisplay.plist
    public var nativeDisplay: [String: PropertyListValue]?
    /// Apple's live firmware variable selects the updater's temporary OS.
    public var firmwareSelectsInstaller: Bool

    public init(
        configuration: MachineConfiguration, journal: GuestInstallationJournal, updater: [String: PropertyListValue]?,
        nativeDisplay: [String: PropertyListValue]?, firmwareSelectsInstaller: Bool
    ) {
        self.configuration = configuration
        self.journal = journal
        self.updater = updater
        self.nativeDisplay = nativeDisplay
        self.firmwareSelectsInstaller = firmwareSelectsInstaller
    }

    public var requiresInstallerDisplay: Bool {
        let guest = configuration.guest
        if guest?.traits.contains(.openGLDesktop) == true || firmwareSelectsInstaller { return true }
        let published = journal.hasPublishedGraphics(for: guest)
        if let updater, updater["FormatVersion"].isEqual(1), updater["Guest"].isEqual(configuration[.guest]),
            updater["PreviousTransactionID"].isUUID, updater["PreviousBuild"].nonEmptyString != nil,
            updater["VolumeUUID"].nonEmptyString != nil
        {
            // The updater may clear its firmware selection before the first normal boot, although it has replaced PVG.
            // Only a completed new-build, same-volume publish releases the hold.
            let result = journal["GuestResult"]
            let repaired =
                published && !journal["TransactionID"].isEqual(updater["PreviousTransactionID"])
                && result["ProductBuildVersion"]?.string != nil
                && !result["ProductBuildVersion"].isEqual(updater["PreviousBuild"])
                && result["VolumeUUID"].isEqual(updater["VolumeUUID"])
            if !repaired { return true }
        }
        if configuration[.installerMedia] == nil && configuration.installState != .hostPopulated { return false }
        return !published && !hasNativeBigSurDisplay
    }

    private var hasNativeBigSurDisplay: Bool {
        guard configuration.guest == .bigSur, let nativeDisplay else { return false }
        return nativeDisplay["FormatVersion"].isEqual(1)
            && nativeDisplay["MachineIdentifier"].isEqual(configuration[.identifier])
            && nativeDisplay["Guest"].isEqual(.string(Guest.bigSur.rawValue))
            && nativeDisplay["NativePVGAvailable"].isTrue
            && nativeDisplay["VolumeUUID"].isUUID
    }

    /// The record that lets Big Sur's own driver accelerate Setup Assistant, or nil if not admitted. It selects a
    /// driver the guest shipped. It isn't an account change, install completion or installer cleanup, and it never
    /// marks one done.
    public func nativeBigSurDisplayRecord(report: GuestReport) -> [String: PropertyListValue]? {
        let bigSur = PropertyListValue.string(Guest.bigSur.rawValue)
        guard configuration.guest == .bigSur, requiresInstallerDisplay, !journal.hasPublishedGraphics(for: .bigSur),
            configuration.installState == .installing, configuration[.installerMedia] != nil,
            report["Guest"].isEqual(bigSur), report["LiveRoot"].isTrue, report["KernelMatchesSystem"].isTrue,
            report["InstalledRootPresent"].isTrue, report["RecoveryToolsPresent"].isFalse,
            report["InstallerMarkers"].isEqual([]), report["SetupComplete"].isFalse,
            report["NativePVGAvailable"].isTrue,
            !firmwareSelectsInstaller
        else { return nil }
        let previous = nativeDisplay ?? [:]
        if previous["MachineIdentifier"].isEqual(configuration[.identifier]),
            previous["VolumeUUID"].isEqual(report["VolumeUUID"]), previous["NativePVGAvailable"].isTrue
        {
            return nil
        }
        guard report["VolumeUUID"].isUUID, report["BootSessionUUID"].isUUID,
            let build = report["ProductBuildVersion"].nonEmptyString, build.utf16.count <= 40,
            build.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil,
            let identifier = configuration[.identifier], let volume = report["VolumeUUID"],
            let boot = report["BootSessionUUID"]
        else { return nil }
        return [
            "FormatVersion": 1, "Guest": bigSur, "NativePVGAvailable": true, "MachineIdentifier": identifier,
            "VolumeUUID": volume, "BootSessionUUID": boot, "ProductBuildVersion": .string(build)
        ]
    }
}
