// The Objective-C face of the guest status decisions. VIMSession keeps its properties and every side effect. It copies
// its flags into `VIMGuestSessionState` when it needs an answer. Reports stay `id`: the wrong type reads as no report.

import Foundation
import InstallerKit

@objc(VIMGuestSessionState)
@objcMembers
public final class GuestSessionStateBridge: NSObject {
    var state = GuestSessionState()

    public var guest: String? {
        get { state.guest?.rawValue }
        set { state.guest = newValue.flatMap(Guest.init(rawValue:)) }
    }
    public var running: Bool {
        get { state.running }
        set { state.running = newValue }
    }
    public var shutdownRequested: Bool { state.shutdownRequested }
    public var developmentSetupDeferred: Bool {
        get { state.developmentSetupDeferred }
        set { state.developmentSetupDeferred = newValue }
    }
    public var preparing: Bool {
        get { state.preparing }
        set { state.preparing = newValue }
    }
    public var preparationRequested: Bool {
        get { state.preparationRequested }
        set { state.preparationRequested = newValue }
    }
    public var installationRequested: Bool {
        get { state.installationRequested }
        set { state.installationRequested = newValue }
    }
    public var runState: String? {
        get { state.runState }
        set { state.runState = newValue }
    }
    public var mayRunGuestAction: Bool { state.mayRunGuestAction }
    public var guestAgentFree: Bool { state.guestAgentFree }
    public var mayProvisionHelpers: Bool { state.mayProvisionHelpers }
    public var repairRequested: Bool {
        get { state.repairRequested }
        set { state.repairRequested = newValue }
    }
    public var explicitRepair: Bool {
        get { state.explicitRepair }
        set { state.explicitRepair = newValue }
    }
    public var verifiedUpdateRepair: Bool {
        get { state.verifiedUpdateRepair }
        set { state.verifiedUpdateRepair = newValue }
    }
    public var updateRepairHeld: Bool {
        get { state.updateRepairHeld }
        set { state.updateRepairHeld = newValue }
    }
    public var presentedSetupFailures: Set<String> {
        get { state.presentedSetupFailures }
        set { state.presentedSetupFailures = newValue }
    }
    public var guestPending: Bool {
        get { state.guestPending }
        set { state.guestPending = newValue }
    }
    public var diagnosticPending: Bool {
        get { state.diagnosticPending }
        set { state.diagnosticPending = newValue }
    }
    public var clipboardPending: Bool {
        get { state.clipboardPending }
        set { state.clipboardPending = newValue }
    }
    public var bootPolicyPending: Bool {
        get { state.bootPolicyPending }
        set { state.bootPolicyPending = newValue }
    }
    public var displayModePending: Bool {
        get { state.displayModePending }
        set { state.displayModePending = newValue }
    }
    public var hasStatusTool: Bool {
        get { state.hasStatusTool }
        set { state.hasStatusTool = newValue }
    }
    public var hasModernSetup: Bool {
        get { state.hasModernSetup }
        set { state.hasModernSetup = newValue }
    }
    public var modernSetupReportActive: Bool {
        get { state.modernSetupReportActive }
        set { state.modernSetupReportActive = newValue }
    }
    public var openGLDesktopMonitoring: Bool {
        get { state.openGLDesktopMonitoring }
        set { state.openGLDesktopMonitoring = newValue }
    }
    public var passthroughOpenGLEnabled: Bool {
        get { state.passthroughOpenGLEnabled }
        set { state.passthroughOpenGLEnabled = newValue }
    }
    public var legacyTabletGuest: Bool {
        get { state.legacyTabletGuest }
        set { state.legacyTabletGuest = newValue }
    }
    public var legacyTabletObserved: Bool {
        get { state.legacyTabletObserved }
        set { state.legacyTabletObserved = newValue }
    }
    public var networkLinkConnected: Bool {
        get { state.networkLinkConnected }
        set { state.networkLinkConnected = newValue }
    }
    public var hasGuestAddresses: Bool {
        get { state.hasGuestAddresses }
        set { state.hasGuestAddresses = newValue }
    }
    public var consoleUID: NSNumber? {
        get { state.consoleUID }
        set { state.consoleUID = newValue }
    }
    public var displayPolicyRestartRequired: Bool {
        get { state.displayPolicyRestartRequired }
        set { state.displayPolicyRestartRequired = newValue }
    }
    public var displaySelectionRetryAfter: Date? {
        get { state.displaySelectionRetryAfter }
        set { state.displaySelectionRetryAfter = newValue }
    }
    public var bootPolicyCheckedBoot: String? {
        get { state.bootPolicyCheckedBoot }
        set { state.bootPolicyCheckedBoot = newValue }
    }
    public var displaySizedBoot: String? {
        get { state.displaySizedBoot }
        set { state.displaySizedBoot = newValue }
    }
    public var displaySelectedBoot: String? {
        get { state.displaySelectedBoot }
        set { state.displaySelectedBoot = newValue }
    }
    public var usernameBoot: String? {
        get { state.usernameBoot }
        set { state.usernameBoot = newValue }
    }
    public var reconciledBoot: String? {
        get { state.reconciledBoot }
        set { state.reconciledBoot = newValue }
    }
    public var reconciliationAttempts: Int {
        get { state.reconciliationAttempts }
        set { state.reconciliationAttempts = newValue }
    }

    public var nextRefreshStep: GuestRefreshStep { state.nextRefreshStep }
    public var mayHandOff: Bool { state.mayHandOff }
    public var mayRequestShutdown: Bool { state.mayRequestShutdown }
    public var mayShutDownForQuit: Bool { state.mayShutDownForQuit }
    public var mayForceReset: Bool { state.mayForceReset }
    public var mayStartGraphicsAction: Bool { state.mayStartGraphicsAction }
    public var graphicsActionsEnabled: Bool { state.graphicsActionsEnabled }
    public var lifecycleDescription: String { state.lifecycle.phase.description }

    @objc(applyEvent:)
    public func apply(_ event: SessionEvent) {
        state.lifecycle = state.lifecycle.applying(event)
    }

    @objc(exitPlanWithExited:terminationStatus:recentGuestReboots:)
    public func exitPlan(exited: Bool, terminationStatus: Int32, recentGuestReboots: [Date]?) -> SessionExitPlan {
        state.lifecycle.exitPlan(
            exited: exited, terminationStatus: terminationStatus, recentGuestReboots: recentGuestReboots ?? [])
    }

    @objc(sleepPolicyArgumentsWithNativeIdleGuard:)
    public func sleepPolicyArguments(nativeIdleGuard: Bool) -> [String]? {
        state.sleepPolicyArguments(nativeIdleGuard: nativeIdleGuard)
    }

    @objc(keepsHostAwakeWithInstallerMedia:installState:completionReport:)
    public func keepsHostAwake(hasInstallerMedia: Bool, installState: Any?, hasCompletionReport: Bool) -> Bool {
        state.keepsHostAwake(
            hasInstallerMedia: hasInstallerMedia, installState: installState as? String,
            hasCompletionReport: hasCompletionReport)
    }

    @objc(enablesMenuAction:controlReady:)
    public func enablesMenuAction(_ action: String, controlReady: Bool) -> NSNumber? {
        state.enablesMenuAction(action, controlReady: controlReady).map { $0 as NSNumber }
    }

    @objc(presentsSetupFailure:)
    public func presentsSetupFailure(_ message: String) -> Bool {
        state.presentsSetupFailure(message)
    }

    @objc(allowsDisplaySelectionForBoot:)
    public func allowsDisplaySelection(boot: String?) -> Bool {
        state.allowsDisplaySelection(boot: boot, now: Date())
    }
}

@objc(VIMGuestStatusPolicy)
@objcMembers
public final class GuestStatusPolicyBridge: NSObject {
    private let policy: GuestStatusPolicy

    public init(report: Any?, failed: Bool, session: GuestSessionStateBridge) {
        policy = GuestStatusPolicy(
            report: GuestReport(foundationObject: report) ?? GuestReport(values: [:]), failed: failed,
            session: session.state)
    }

    public var reportedConsoleUID: NSNumber? { policy.reportedConsoleUID }
    public var consoleUserChanged: Bool { policy.consoleUserChanged }
    public var isFromThisGuest: Bool { policy.isFromThisGuest }
    public var preMetalDesktopReady: Bool { policy.preMetalDesktopReady }
    public var preMetalRefreshInterval: TimeInterval { policy.preMetalRefreshInterval }
    public var needsTabletProbe: Bool { policy.needsTabletProbe }
    public var mayCheckNativeDisplay: Bool { policy.mayCheckNativeDisplay }
    public var mayAdvanceModernSetup: Bool { policy.mayAdvanceModernSetup }
    public var needsDisplayResize: Bool { policy.needsDisplayResize }
    public var mayClaimAutomaticInstallation: Bool { policy.mayClaimAutomaticInstallation }
    public var needsDisplayPowerBridge: Bool { policy.needsDisplayPowerBridge }
    public var needsConsoleUsername: Bool { policy.needsConsoleUsername }
    public var needsUpdateRepairCheck: Bool { policy.needsUpdateRepairCheck }
    public var mayClaimUpdateRepair: Bool { policy.mayClaimUpdateRepair }
    public var mayBeginRepair: Bool { policy.mayBeginRepair }
    public var nextReconciliationAttempt: Int { policy.nextReconciliationAttempt }
    public var mayBeginPreparation: Bool { policy.mayBeginPreparation }
    public var needsDesktopServices: Bool { policy.needsDesktopServices }
    public var refreshInterval: TimeInterval { policy.refreshInterval }

    @objc(followUpAfterInstallation:requiresInstallerDisplay:)
    public func followUpAfterInstallation(outcome: Any?, requiresInstallerDisplay: Bool) -> InstallationFollowUp {
        let values = outcome as? [String: Any]
        return policy.followUpAfterInstallation(
            outcomePhase: values?["Phase"] as? String,
            rebootRequired: values?["RebootRequired"] as? Bool ?? false,
            requiresInstallerDisplay: requiresInstallerDisplay)
    }

    @objc(guestAddressesReplacing:macAddress:isUsable:)
    public func guestAddresses(
        replacing current: [String]?, macAddress: String, isUsable: (String) -> Bool
    ) -> [String]? {
        policy.guestAddresses(replacing: current, macAddress: macAddress, isUsable: isUsable)
    }

    @objc(needsBootPolicyCheckWithPolicyReady:bootingGuestFirmware:)
    public func needsBootPolicyCheck(policyReady: Bool, bootingGuestFirmware: Bool) -> Bool {
        policy.needsBootPolicyCheck(policyReady: policyReady, bootingGuestFirmware: bootingGuestFirmware)
    }

    @objc(needsReconciliationWithJournalExists:)
    public func needsReconciliation(journalExists: Bool) -> Bool {
        policy.needsReconciliation(journalExists: journalExists)
    }
}
