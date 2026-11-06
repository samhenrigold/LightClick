import Foundation
import InstallerKit

/// What one guest status report means for the session: the ordered questions `finishGuestStatus` asks, each answered
/// from the report and the session's current flags. Doing the work stays with the caller.
///
/// A report may be missing with no failure, which reads as a report with no keys. Questions that don't look at the
/// report still pass then.
public struct GuestStatusPolicy: Sendable {
    public var report: GuestReport
    /// The status could not be collected. `report` says nothing about the guest then.
    public var failed: Bool
    public var session: GuestSessionState

    public init(report: GuestReport, failed: Bool, session: GuestSessionState) {
        self.report = report
        self.failed = failed
        self.session = session
    }

    private var boot: String? { report.bootSessionUUID }

    private func isNew(_ boot: String, comparedTo last: String?) -> Bool {
        !GuestSessionState.isSame(boot, last)
    }

    // MARK: Who and where the guest is

    /// The console user the report names. Below 501 is a system account, which counts as nobody. The value is read as
    /// an unsigned 32-bit ID, since that's what the guest's `uid_t` is.
    public var reportedConsoleUID: NSNumber? {
        guard let uid = report["ConsoleUID"]?.number, uid.uint32Value >= 501 else { return nil }
        return uid
    }

    /// Whether the session's console user must be replaced. A report without a number says nothing about the user.
    public var consoleUserChanged: Bool {
        !failed && report["ConsoleUID"]?.number != nil && reportedConsoleUID != session.consoleUID
    }

    /// The guest's addresses after this report. `NetworkInterfaces` wins over `Network` when present, even if no
    /// interface has this machine's MAC address. A report with neither leaves `current` alone, and a failure clears it.
    public func guestAddresses(
        replacing current: [String]?, macAddress: String, isUsable: (String) -> Bool
    ) -> [String]? {
        if failed { return nil }
        let reported: [PropertyListValue]
        if let interfaces = report["NetworkInterfaces"]?.array {
            reported =
                interfaces
                .compactMap(\.dictionary)
                .filter { $0["MACAddress"]?.string?.caseInsensitiveCompare(macAddress) == .orderedSame }
                .flatMap { $0["Addresses"]?.array ?? [] }
        } else if let network = report["Network"]?.dictionary {
            // Sorted so that one guest's order doesn't change between reports.
            reported = network.keys.sorted().flatMap { network[$0]?.dictionary?["Addresses"]?.array ?? [] }
        } else {
            return current
        }
        var addresses: [String] = []
        for address in reported.compactMap(\.string) where isUsable(address) && !addresses.contains(address) {
            addresses.append(address)
        }
        return addresses
    }

    public var isFromThisGuest: Bool { report.isFrom(session.guest) }

    // MARK: Pre-Metal desktops

    /// Enough to start desktop services on a pre-Metal guest. This never authorizes Metal patching.
    public var preMetalDesktopReady: Bool {
        !failed && report.hasRunningDesktop(guest: session.guest) && session.consoleUID != nil
    }

    public var preMetalRefreshInterval: TimeInterval { preMetalDesktopReady ? 60 : 15 }

    /// Whether to read the bound tablet driver, once per boot at the installed desktop. This is the one check that
    /// takes `DesktopRunning` as `boolValue`, so a string such as "YES" passes here and nowhere else.
    public var needsTabletProbe: Bool {
        !failed && session.legacyTabletGuest && !session.legacyTabletObserved && report["DesktopRunning"].boolValue
    }

    // MARK: Modern guests, in the order they're asked

    public var mayCheckNativeDisplay: Bool {
        !failed && !session.shutdownRequested && !session.preparing && !session.preparationRequested
            && !session.relaunchForGraphics
    }

    public var mayAdvanceModernSetup: Bool {
        !failed && session.hasModernSetup && !session.modernSetupReportActive && !session.shutdownRequested
            && !session.relaunchForGraphics
    }

    /// Once per boot, and never under an explicit guest firmware. `policyReady` is a saved verification for this guest.
    public func needsBootPolicyCheck(policyReady: Bool, bootingGuestFirmware: Bool) -> Bool {
        guard !failed, !bootingGuestFirmware, let boot else { return false }
        return isNew(boot, comparedTo: session.bootPolicyCheckedBoot)
            && report.admitsBootPolicyCheck(guest: session.guest, policyAlreadyReady: policyReady)
    }

    /// Guest preferences can restore a saved 1× mode at login, so the window's size is sent again once.
    public var needsDisplayResize: Bool {
        guard !failed, let boot else { return false }
        return report.isDesktopRunning && isNew(boot, comparedTo: session.displaySizedBoot)
    }

    public var mayClaimAutomaticInstallation: Bool {
        !failed && !session.preparationRequested && !session.repairRequested
    }

    public var needsDisplayPowerBridge: Bool { !failed && boot != nil && report.isSetupComplete }

    /// Remote Login needs the account's short name, learned from the signed-in console user once per boot.
    public var needsConsoleUsername: Bool {
        guard !failed, let boot else { return false }
        return session.consoleUID != nil && report.isDesktopRunning && isNew(boot, comparedTo: session.usernameBoot)
    }

    /// An explicit repair before the desktop is verified again on each report. With a desktop the last answer stands.
    public var needsUpdateRepairCheck: Bool {
        session.explicitRepair && session.repairRequested && !failed && !report.isDesktopRunning
    }

    public var mayClaimUpdateRepair: Bool {
        !failed && !session.repairRequested && !session.preparationRequested
    }

    private var admitsPreparation: Bool {
        report.admitsPreparation(guest: session.guest, verifiedUpdateRepair: session.verifiedUpdateRepair)
    }

    public var mayBeginRepair: Bool { session.repairRequested && !failed && admitsPreparation }

    /// Desktop availability can precede Metal readiness, so a boot gets at most three read-only checks. A new boot
    /// starts again even if the last one used all three.
    public func needsReconciliation(journalExists: Bool) -> Bool {
        guard !failed, !session.preparationRequested, let boot else { return false }
        return (isNew(boot, comparedTo: session.reconciledBoot) || session.reconciliationAttempts < 3)
            && report.admitsReconciliation(guest: session.guest) && journalExists
    }

    /// The count to record when a reconciliation starts.
    public var nextReconciliationAttempt: Int {
        guard let boot, !isNew(boot, comparedTo: session.reconciledBoot) else { return 1 }
        return session.reconciliationAttempts + 1
    }

    public var mayBeginPreparation: Bool { session.preparationRequested && !failed && admitsPreparation }

    public var needsDesktopServices: Bool { !failed && report.isDesktopRunning }

    /// Fifteen seconds while something is still expected to change: a failure, requested preparation, no desktop yet,
    /// or a connected link with no address. A minute otherwise.
    public var refreshInterval: TimeInterval {
        failed || session.preparationRequested || !report.isDesktopRunning
            || (!session.hasGuestAddresses && session.networkLinkConnected) ? 15 : 60
    }
}

extension GuestReport {
    /// A journal whose guest result names another boot was installed before this one, so it needs post-reboot proof.
    /// A missing result counts as another boot.
    public func reconciliationVerifiesAfterReboot(journal: [String: PropertyListValue]?) -> Bool {
        let guestResult = journal?["GuestResult"]
        return !guestResult["BootSessionUUID"].isEqual(self["BootSessionUUID"])
    }

    /// What a finished reconciliation with no failure tells the user. `Phase` comes from a saved journal, so any value
    /// is shown as it stands.
    public static func reconciliationMessage(result: [String: PropertyListValue]?, verified: Bool) -> String {
        if verified { return "Graphics verified — installer cleanup will finish when this Mac shuts down" }
        let phase = result?["Phase"]
        if phase.isEqual("awaiting-reboot") {
            return "Installation status recovered — restart required for graphics verification"
        }
        return "Installation status: \(phase?.foundationObject.description ?? "unknown")"
    }
}
