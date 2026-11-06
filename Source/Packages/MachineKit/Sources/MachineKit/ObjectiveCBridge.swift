// The Objective-C face of MachineKit. VIMMachine keeps its class, its selectors and its dictionary `configuration`,
// which a hundred callers read by key, and keeps the file and lock operations. The decisions come from here. Reports
// and saved plists are untrusted, so parameters are `id`: a value of the wrong type refuses a check instead of trapping
// in a cast.

import Foundation
import InstallerKit

private func propertyList(_ object: Any?) -> [String: PropertyListValue]? {
    (object as? [String: Any])?.mapValues(PropertyListValue.init(foundationObject:))
}

private func machineConfiguration(_ object: Any?) -> MachineConfiguration {
    MachineConfiguration(foundationObject: object) ?? MachineConfiguration()
}

private func installationJournal(_ object: Any?) -> GuestInstallationJournal {
    GuestInstallationJournal(values: propertyList(object) ?? [:])
}

private func guestNamed(_ object: Any?) -> Guest? {
    (object as? String).flatMap(Guest.init(rawValue:))
}

private func foundationDictionary(_ values: [String: PropertyListValue]?) -> NSDictionary? {
    values?.mapValues(\.foundationObject) as NSDictionary?
}

@objc(VIMMachineModel)
public final class MachineModelBridge: NSObject {
    // MARK: Names and paths

    @objc(nameIsValid:)
    public class func nameIsValid(_ name: Any?) -> Bool {
        (name as? String).map(PackageNaming.isValid) ?? false
    }

    @objc(renameIsValid:)
    public class func renameIsValid(_ name: Any?) -> Bool {
        (name as? String).map(PackageNaming.isValidRename) ?? false
    }

    @objc(newPackageURLForName:inLibrary:)
    public class func newPackageURL(name: String, library: URL) -> URL {
        PackageNaming.newPackageURL(for: name, in: library)
    }

    @objc(preparedMediaAttemptForMedia:owner:)
    public class func preparedMediaAttempt(media: URL, owner: URL) -> URL? {
        LibraryLayout.preparedMediaAttempt(media: media, owner: owner)
    }

    // MARK: Configuration

    @objc(settingsAreValid:)
    public class func settingsAreValid(_ object: Any?) -> Bool {
        MachineConfiguration(foundationObject: object)?.hasValidSettings ?? false
    }

    /// Everything loading requires of a package except reading its Machine.plist.
    @objc(validateConfiguration:package:error:)
    public class func validate(_ object: Any?, package: URL) throws {
        guard let configuration = MachineConfiguration(foundationObject: object) else {
            throw MachineConfigurationError.invalidConfiguration
        }
        try configuration.validate(package: package)
    }

    @objc(editableConfiguration:pending:)
    public class func editable(_ object: Any?, pending: Any?) -> NSDictionary {
        PendingChanges(values: propertyList(pending) ?? [:]).editable(from: machineConfiguration(object))
            .foundationObject
    }

    @objc(pendingNameFrom:)
    public class func pendingName(_ pending: Any?) -> String? {
        PendingChanges(values: propertyList(pending) ?? [:]).requestedName
    }

    /// Refuses a key the user may not edit, or edits that leave the configuration invalid.
    @objc(validateSettings:onEditableConfiguration:error:)
    public class func validate(settings: Any?, editable: Any?) throws {
        let settings = propertyList(settings) ?? [:]
        guard settings.keys.allSatisfy(PendingChanges.editableKeys.contains) else {
            throw MachineConfigurationError.unsupportedSetting
        }
        var candidate = machineConfiguration(editable)
        candidate.values.merge(settings) { $1 }
        guard candidate.hasValidSettings else { throw MachineConfigurationError.invalidSettings }
    }

    @objc(configuration:applyingPending:error:)
    public class func applying(_ object: Any?, pending: Any?) throws -> NSDictionary {
        try PendingChanges(values: propertyList(pending) ?? [:]).applied(to: machineConfiguration(object))
            .foundationObject
    }

    @objc(destinationNameForPackageStem:pending:configuration:)
    public class func destinationName(packageStem: String, pending: Any?, configuration object: Any?) -> String? {
        PendingChanges(values: propertyList(pending) ?? [:])
            .destinationName(packageStem: packageStem, configuration: machineConfiguration(object))
    }

    @objc(configurationRemovingLegacyName:)
    public class func removingLegacyName(_ object: Any?) -> NSDictionary {
        machineConfiguration(object).removingLegacyName().foundationObject
    }

    @objc(passthroughOpenGLEnabled:)
    public class func passthroughOpenGLEnabled(_ object: Any?) -> Bool {
        machineConfiguration(object).passthroughOpenGLEnabled
    }

    // MARK: Screen sharing

    /// Each command as its executable, then its arguments. The verification comes last, and its exit status is the only
    /// one that decides anything. Nil for a guest that can't share its screen.
    @objc(screenSharingCommandsForGuest:enabling:)
    public class func screenSharingCommands(guest name: Any?, enabling: Bool) -> [[String]]? {
        guard let guest = guestNamed(name), let commands = ScreenSharing.commands(enabling: enabling, on: guest) else {
            return nil
        }
        return (commands + [ScreenSharing.verification]).map { [$0.executable] + $0.arguments }
    }

    @objc(screenSharingAvailableOnConfiguration:)
    public class func screenSharingAvailable(_ object: Any?) -> Bool {
        ScreenSharing.isAvailable(on: machineConfiguration(object))
    }

    @objc(screenSharingURLForConfiguration:)
    public class func screenSharingURL(_ object: Any?) -> URL? {
        ScreenSharing.connectionURL(for: machineConfiguration(object))
    }

    // MARK: Install state

    @objc(configurationRestartingForOpenGLSetup:)
    public class func restartingForOpenGLSetup(_ object: Any?) -> NSDictionary {
        machineConfiguration(object).restartingForOpenGLSetup().foundationObject
    }

    @objc(configurationFinishingOpenGLSetup:error:)
    public class func finishingOpenGLSetup(_ object: Any?) throws -> NSDictionary {
        try machineConfiguration(object).finishingOpenGLSetup().foundationObject
    }

    @objc(configurationFinishingWithSharedInstaller:)
    public class func finishingWithSharedInstaller(_ object: Any?) -> NSDictionary {
        machineConfiguration(object).finishingWithSharedInstaller().foundationObject
    }

    @objc(configurationFinishingWithOwnedInstaller:)
    public class func finishingWithOwnedInstaller(_ object: Any?) -> NSDictionary {
        machineConfiguration(object).finishingWithOwnedInstaller().foundationObject
    }

    // MARK: Display evidence

    @objc(journal:hasPublishedGraphicsForGuest:)
    public class func hasPublishedGraphics(journal object: Any?, guest name: Any?) -> Bool {
        installationJournal(object).hasPublishedGraphics(for: guestNamed(name))
    }

    private class func displayEvidence(
        _ object: Any?, journal state: Any?, updater: Any?, nativeDisplay: Any?, firmwareSelectsInstaller: Bool
    ) -> InstallerDisplayEvidence {
        InstallerDisplayEvidence(
            configuration: machineConfiguration(object), journal: installationJournal(state),
            updater: propertyList(updater),
            nativeDisplay: propertyList(nativeDisplay), firmwareSelectsInstaller: firmwareSelectsInstaller)
    }

    @objc(configuration:requiresInstallerDisplayWithJournal:updater:nativeDisplay:firmwareSelectsInstaller:)
    public class func requiresInstallerDisplay(
        _ object: Any?, journal state: Any?, updater: Any?, nativeDisplay: Any?, firmwareSelectsInstaller: Bool
    ) -> Bool {
        displayEvidence(
            object, journal: state, updater: updater, nativeDisplay: nativeDisplay,
            firmwareSelectsInstaller: firmwareSelectsInstaller
        ).requiresInstallerDisplay
    }

    @objc(nativeBigSurDisplayRecordForConfiguration:report:journal:updater:nativeDisplay:firmwareSelectsInstaller:)
    public class func nativeBigSurDisplayRecord(
        _ object: Any?, report: Any?, journal state: Any?, updater: Any?, nativeDisplay: Any?,
        firmwareSelectsInstaller: Bool
    ) -> NSDictionary? {
        guard let report = GuestReport(foundationObject: report) else { return nil }
        return foundationDictionary(
            displayEvidence(
                object, journal: state, updater: updater, nativeDisplay: nativeDisplay,
                firmwareSelectsInstaller: firmwareSelectsInstaller
            ).nativeBigSurDisplayRecord(report: report))
    }

    @objc(updaterDisplayRecordForJournal:guest:)
    public class func updaterDisplayRecord(journal object: Any?, guest name: Any?) -> NSDictionary? {
        guard let guest = guestNamed(name) else { return nil }
        return foundationDictionary(installationJournal(object).updaterDisplayRecord(guest: guest, startedAt: Date()))
    }

    // MARK: Installation and repair evidence

    @objc(report:admitsAutomaticInstallationOnConfiguration:)
    public class func admitsAutomaticInstallation(report: Any?, configuration object: Any?) -> Bool {
        GuestReport(foundationObject: report)?.admitsAutomaticInstallation(on: machineConfiguration(object)) ?? false
    }

    @objc(ownership:admitsClaimByConfiguration:)
    public class func ownershipAdmitsClaim(_ owner: Any?, configuration object: Any?) -> Bool {
        InstallerOwnership(values: propertyList(owner) ?? [:]).admitsClaim(by: machineConfiguration(object))
    }

    @objc(ownership:namesConfiguration:)
    public class func ownershipNames(_ owner: Any?, configuration object: Any?) -> Bool {
        InstallerOwnership(values: propertyList(owner) ?? [:]).names(machineConfiguration(object))
    }

    @objc(ownership:admitsOwnedCleanupByConfiguration:)
    public class func ownershipAdmitsOwnedCleanup(_ owner: Any?, configuration object: Any?) -> Bool {
        InstallerOwnership(values: propertyList(owner) ?? [:]).admitsOwnedCleanup(by: machineConfiguration(object))
    }

    @objc(report:admitsUpdateRepairForGuest:)
    public class func admitsUpdateRepair(report: Any?, guest name: Any?) -> Bool {
        GuestReport(foundationObject: report)?.admitsUpdateRepair(guest: guestNamed(name)) ?? false
    }

    @objc(bootPolicyReadyAtURL:guest:identifier:)
    public class func bootPolicyReady(at journal: URL, guest: Any?, identifier: Any?) -> Bool {
        GuestBootPolicyRecord.isReady(
            at: journal, guest: guest.map(PropertyListValue.init(foundationObject:)),
            identifier: identifier.map(PropertyListValue.init(foundationObject:)))
    }

    @objc(verifiedInstallationSuperseded:report:)
    public class func verifiedInstallationSuperseded(_ state: Any?, report: Any?) -> Bool {
        guard let state = propertyList(state), let report = GuestReport(foundationObject: report) else { return false }
        return GuestInstallationJournal(values: state).isSuperseded(by: report)
    }

    @objc(journal:allowsRepairRecoveryOfClaim:configuration:report:)
    public class func allowsRepairRecovery(journal state: Any?, claim: Any?, configuration object: Any?, report: Any?)
        -> Bool
    {
        guard let report = GuestReport(foundationObject: report) else { return false }
        return installationJournal(state).allowsRepairRecovery(
            claim: propertyList(claim), configuration: machineConfiguration(object), report: report)
    }

    @objc(journal:authorizesInstallerCleanupWithReport:guest:)
    public class func authorizesInstallerCleanup(journal state: Any?, report: Any?, guest name: Any?) -> Bool {
        guard let report = GuestReport(foundationObject: report) else { return false }
        return installationJournal(state).authorizesInstallerCleanup(report: report, guest: guestNamed(name))
    }

    // MARK: OpenGL setup evidence

    @objc(openGLInitialGraphicsCanResumeWithReport:machine:volume:installing:systemMatches:)
    public class func openGLInitialGraphicsCanResume(
        report: Any?, machine: Any?, volume: Any?, installing: Bool, systemMatches: Bool
    ) -> Bool {
        GuestReport(foundationObject: report)?.openGLInitialGraphicsCanResume(
            machine: machine as? String, volume: volume as? String, installing: installing, systemMatches: systemMatches
        )
            ?? false
    }

    @objc(openGLBundledSupportMatchesForGuest:report:expected:)
    public class func openGLBundledSupportMatches(guest: Any?, report: Any?, expected: Any?) -> Bool {
        GuestReport(foundationObject: report)?.openGLBundledSupportMatches(
            guest: guest as? String, expected: propertyList(expected)) ?? false
    }

    @objc(openGLGraphicsNeedsRestartWithReport:restart:boot:)
    public class func openGLGraphicsNeedsRestart(report: Any?, restart: Any?, boot: Any?) -> Bool {
        GuestReport(foundationObject: report)?.openGLGraphicsNeedsRestart(
            restart: propertyList(restart), boot: boot as? String)
            ?? false
    }

    @objc(report:isOpenGLSetupEvidenceOnConfiguration:target:requirePixels:)
    public class func isOpenGLSetupEvidence(report: Any?, configuration object: Any?, target: Any?, requirePixels: Bool)
        -> Bool
    {
        GuestReport(foundationObject: report)?.isOpenGLSetupEvidence(
            on: machineConfiguration(object), target: propertyList(target), requirePixels: requirePixels) ?? false
    }

    @objc(report:hasFinishedFirstLoginWithAutomaticSetup:)
    public class func hasFinishedFirstLogin(report: Any?, automaticSetup: Any?) -> Bool {
        GuestReport(foundationObject: report)?.hasFinishedFirstLogin(automaticSetup: propertyList(automaticSetup))
            ?? false
    }

    // MARK: Session checks

    @objc(reportIsLiveInstalledSystem:)
    public class func isLiveInstalledSystem(report: Any?) -> Bool {
        GuestReport(foundationObject: report)?.isLiveInstalledSystem ?? false
    }

    @objc(report:stillMatchesCompletionReport:)
    public class func stillMatches(report: Any?, completionReport: Any?) -> Bool {
        guard let report = GuestReport(foundationObject: report),
            let completion = GuestReport(foundationObject: completionReport)
        else { return false }
        return report.stillMatches(completionReport: completion)
    }

    @objc(report:admitsPreparationForGuest:verifiedUpdateRepair:)
    public class func admitsPreparation(report: Any?, guest name: Any?, verifiedUpdateRepair: Bool) -> Bool {
        GuestReport(foundationObject: report)?
            .admitsPreparation(guest: guestNamed(name), verifiedUpdateRepair: verifiedUpdateRepair) ?? false
    }

    @objc(report:bootPolicyRepairNeedsRestart:)
    public class func bootPolicyRepairNeedsRestart(report: Any?, policy: Any?) -> Bool {
        GuestReport(foundationObject: report)?.bootPolicyRepairNeedsRestart(policy: propertyList(policy)) ?? false
    }

    @objc(consoleUsernameFromStatOutput:expectedUID:)
    public class func consoleUsername(statOutput: String?, expectedUID: NSNumber) -> String? {
        GuestReport.consoleUsername(statOutput: statOutput ?? "", expectedUID: Int(expectedUID.uint32Value))
    }
}
