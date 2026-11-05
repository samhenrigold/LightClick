import Foundation
import InstallerKit

/// What the guest's status agent says about itself. Reports are untrusted: a key may be missing or the wrong type, and
/// every check here refuses in that case. The original is kept whole, since claims and receipts save it verbatim.
public struct GuestReport: Sendable {
    public var values: [String: PropertyListValue]

    public init(values: [String: PropertyListValue]) {
        self.values = values
    }

    /// Nil unless the object is a dictionary with string keys.
    public init?(foundationObject: Any?) {
        guard let dictionary = foundationObject as? [String: Any] else { return nil }
        values = dictionary.mapValues(PropertyListValue.init(foundationObject:))
    }

    subscript(key: String) -> PropertyListValue? { values[key] }

    public var guest: Guest? { self["Guest"]?.string.flatMap(Guest.init(rawValue:)) }
    public var bootSessionUUID: String? { self["BootSessionUUID"].nonEmptyString }
    public var isDesktopRunning: Bool { self["DesktopRunning"].isTrue }
    public var isSetupComplete: Bool { self["SetupComplete"].isTrue }
    public var isInstalledSystemCandidate: Bool { self["InstalledSystemCandidate"].isTrue }

    func isFrom(_ guest: Guest?) -> Bool {
        guard let guest else { return false }
        return self["Guest"].isEqual(.string(guest.rawValue))
    }

    /// The installed system, running from its own root with its own kernel: not an installer or recovery boot.
    public var isLiveInstalledSystem: Bool {
        isInstalledSystemCandidate && self["LiveRoot"].isTrue && self["KernelMatchesSystem"].isTrue
    }

    /// Every update and installation decision is tied to this identity.
    var hasCompleteIdentity: Bool {
        ["VolumeUUID", "BootSessionUUID", "ProductBuildVersion"].allSatisfy { self[$0].nonEmptyString != nil }
    }

    /// A build is used only as a receipt filename, never as a command. Paths and malformed evidence are refused rather
    /// than normalized, so two builds can't share a claim.
    var hasClaimableBuild: Bool {
        guard let build = self["ProductBuildVersion"]?.string else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_")
        return build.utf16.count <= 128 && !(build as NSString).hasPrefix(".")
            && build.rangeOfCharacter(from: allowed.inverted) == nil
    }

    /// The first automatic graphics installation for an app-created machine. A live desktop is required: it's what
    /// shows macOS setup finished. The claim itself must also be exclusive, and that part is the caller's, on disk.
    public func admitsAutomaticInstallation(on configuration: MachineConfiguration) -> Bool {
        configuration.guest?.traits.contains(.paravirtualizedGraphics) == true
            && configuration.installState == .installing && configuration[.installerMedia] != nil
            && isFrom(configuration.guest) && isInstalledSystemCandidate && isDesktopRunning
            && self["LiveRoot"].isTrue && self["KernelMatchesSystem"].isTrue && hasCompleteIdentity
    }

    /// The report half of a repair after a guest update. Unlike installation it must not require a desktop, since an
    /// update may replace the driver WindowServer needs. `GuestInstallationJournal.isSuperseded(by:)` supplies the
    /// proof.
    public func admitsUpdateRepair(guest: Guest?) -> Bool {
        isFrom(guest) && isLiveInstalledSystem && hasCompleteIdentity && hasClaimableBuild
    }

    // MARK: The session's checks (VIMSession's finishGuestStatus)

    /// Enough to start desktop services on a pre-Metal guest. This never authorizes Metal patching.
    public func hasRunningDesktop(guest: Guest?) -> Bool {
        isFrom(guest) && isDesktopRunning
    }

    /// Whether a later status report still describes the boot and system a saved completion report came from.
    public func stillMatches(completionReport: GuestReport) -> Bool {
        self["BootSessionUUID"].isEqual(completionReport["BootSessionUUID"])
            && self["ProductBuildVersion"].isEqual(completionReport["ProductBuildVersion"])
            && self["VolumeUUID"].isEqual(completionReport["VolumeUUID"]) && isInstalledSystemCandidate
    }

    /// Whether boot policy may be checked this boot. A previously verified guest doesn't need a desktop, since a
    /// missing preference can itself prevent WindowServer.
    public func admitsBootPolicyCheck(guest: Guest?, policyAlreadyReady: Bool) -> Bool {
        bootSessionUUID != nil && isInstalledSystemCandidate && (isDesktopRunning || policyAlreadyReady)
            && self["LiveRoot"].isTrue && self["KernelMatchesSystem"].isTrue && isFrom(guest)
    }

    /// A repaired boot policy restarts the guest only when this boot, before its desktop, is the one it repaired.
    public func bootPolicyRepairNeedsRestart(policy: [String: PropertyListValue]?) -> Bool {
        guard let policy, let boot = self["BootSessionUUID"]?.string else { return false }
        return !isDesktopRunning && policy["RecoveryBootSessionUUID"].isEqual(.string(boot))
            && policy["Result"]["Changed"].isTrue
    }

    /// Whether a requested repair or preparation may start. `verifiedUpdateRepair` replaces only the desktop
    /// requirement.
    public func admitsPreparation(guest: Guest?, verifiedUpdateRepair: Bool) -> Bool {
        (isDesktopRunning || verifiedUpdateRepair) && isInstalledSystemCandidate && isFrom(guest)
    }

    /// Whether a read-only reconciliation of the journal may run for this boot.
    public func admitsReconciliation(guest: Guest?) -> Bool {
        bootSessionUUID != nil && isDesktopRunning && isInstalledSystemCandidate && isFrom(guest)
    }

    /// A read-only reconciliation's result counts only if it verified this boot.
    public func isVerifiedByReconciliation(result: [String: PropertyListValue]?) -> Bool {
        guard let result, let boot = self["BootSessionUUID"]?.string else { return false }
        return result["VerifiedAfterReboot"].isTrue && result["BootSessionUUID"].isEqual(.string(boot))
    }

    /// The guest account's short name, from `stat -f '%u %Su' /dev/console` run in the guest. Refuses a system account,
    /// or a console owned by anyone but the expected user.
    public static func consoleUsername(statOutput: String, expectedUID: Int) -> String? {
        let fields = statOutput.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
        guard fields.count == 2, !fields[1].isEmpty else { return nil }
        let uid = (fields[0] as NSString).integerValue
        return uid >= 501 && uid == expectedUID ? fields[1] : nil
    }
}

/// Installation/Ownership.plist: which machine a piece of installer media was created for. A machine deletes or claims
/// only what this record says is its own.
public struct InstallerOwnership: Sendable {
    public var values: [String: PropertyListValue]

    public init(values: [String: PropertyListValue]) {
        self.values = values
    }

    public var media: PropertyListValue? { values["Media"] }

    /// Who the record names, against the configuration on disk now.
    public func names(_ configuration: MachineConfiguration) -> Bool {
        values["MachineIdentifier"].isEqual(configuration[.identifier])
            && values["Media"].isEqual(configuration[.installerMedia])
    }

    /// The installer may become the subject of an automatic installation.
    public func admitsClaim(by configuration: MachineConfiguration) -> Bool {
        values["FormatVersion"].isEqual(1) && names(configuration)
    }

    /// Owned media may be deleted only with an exact record. A configuration that has already detached it can still
    /// finish.
    public func admitsOwnedCleanup(by configuration: MachineConfiguration) -> Bool {
        values["FormatVersion"].isEqual(1) && values["MachineIdentifier"].isEqual(configuration[.identifier])
            && values["Media"].isEqual(.string(InstallerMediaLocation.ownedPath))
            && (configuration[.installerMedia] == nil || values["Media"].isEqual(configuration[.installerMedia]))
    }
}
