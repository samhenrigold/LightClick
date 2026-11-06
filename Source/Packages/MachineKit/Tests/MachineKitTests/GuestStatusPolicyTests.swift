import Foundation
import InstallerKit
import Testing

@testable import MachineKit

/// The decisions a status pass makes, each breaking one input of a case that passes. Expected values come from reading
/// `finishGuestStatus`, `refreshGuestStatus`, `restoreDisplaySelectionForBoot:` and `enforceGuestSleepPolicyForBoot:`
/// as they were in Objective-C.
@Suite struct GuestStatusPolicyTests {
    private let report = Fixture.report

    private var session: GuestSessionState {
        var state = GuestSessionState()
        state.guest = .mojave
        state.running = true
        state.consoleUID = 501
        return state
    }

    private func policy(
        _ report: GuestReport? = nil, failed: Bool = false, _ change: (inout GuestSessionState) -> Void = { _ in }
    ) -> GuestStatusPolicy {
        var state = session
        change(&state)
        return GuestStatusPolicy(report: report ?? self.report, failed: failed, session: state)
    }

    private let noReport = GuestReport(values: [:])

    // MARK: Console user

    @Test func aNewConsoleUserReplacesTheOldOne() {
        let observed = policy(report.setting("ConsoleUID", 502))
        #expect(observed.consoleUserChanged)
        #expect(observed.reportedConsoleUID == 502)
    }

    @Test func theSameConsoleUserChangesNothing() {
        #expect(!policy(report.setting("ConsoleUID", 501)).consoleUserChanged)
        // `isEqual:` between numbers.
        #expect(!policy(report.setting("ConsoleUID", .number(501.0))).consoleUserChanged)
    }

    @Test func aSystemAccountMeansNobodyIsSignedIn() {
        let loggedOut = policy(report.setting("ConsoleUID", 500))
        #expect(loggedOut.consoleUserChanged)
        #expect(loggedOut.reportedConsoleUID == nil)
        // Nobody, and nobody already known: nil against nil isn't a change.
        #expect(!policy(report.setting("ConsoleUID", 0)) { $0.consoleUID = nil }.consoleUserChanged)
    }

    @Test func aReportWithoutANumberSaysNothingAboutTheUser() {
        #expect(!policy(report).consoleUserChanged)
        #expect(!policy(report.setting("ConsoleUID", "502")).consoleUserChanged)
        #expect(!policy(report.setting("ConsoleUID", 502), failed: true).consoleUserChanged)
    }

    @Test func consoleIDsAreReadAsUnsigned() {
        // Odd but original: a negative number wraps past 501 and counts as a user, and `true` is 1, a system account.
        #expect(policy(report.setting("ConsoleUID", -2)).reportedConsoleUID == -2)
        #expect(policy(report.setting("ConsoleUID", true)).reportedConsoleUID == nil)
    }

    @Test func aConsoleIDAboveInt32StaysTheSameUser() {
        let uid: NSNumber = 3_000_000_000
        let high = report.setting("ConsoleUID", .number(uid))
        #expect(!policy(high) { $0.consoleUID = uid }.consoleUserChanged)
        #expect(GuestReport.consoleUsername(statOutput: "3000000000 someone", expectedUID: uid.intValue) == "someone")
        // What `finishGuestStatus` must not store: the clamped ID reads as a new user on every report.
        let clamped = NSNumber(value: ("3000000000 someone" as NSString).intValue)
        #expect(policy(high) { $0.consoleUID = clamped }.consoleUserChanged)
    }

    // MARK: Addresses

    private func addresses(
        _ report: GuestReport, failed: Bool = false, current: [String]? = ["10.0.0.9"]
    ) -> [String]? {
        policy(report, failed: failed)
            .guestAddresses(replacing: current, macAddress: "02:00:00:AA:BB:CC") { $0.hasPrefix("192.168.") }
    }

    private func interface(_ mac: PropertyListValue, _ addresses: PropertyListValue) -> PropertyListValue {
        ["MACAddress": mac, "Addresses": addresses]
    }

    @Test func onlyThisMachinesInterfaceCounts() {
        let interfaces: PropertyListValue = [
            interface("02:00:00:aa:bb:cc", ["192.168.1.2", "192.168.1.2", "127.0.0.1", 7, "192.168.1.3"]),
            interface("02:00:00:00:00:01", ["192.168.9.9"])
        ]
        #expect(addresses(report.setting("NetworkInterfaces", interfaces)) == ["192.168.1.2", "192.168.1.3"])
    }

    @Test func malformedInterfacesAreSkipped() {
        let interfaces: PropertyListValue = [
            "not a dictionary", interface(5, ["192.168.1.1"]), interface("02:00:00:AA:BB:CC", "192.168.1.2")
        ]
        #expect(addresses(report.setting("NetworkInterfaces", interfaces)) == [])
    }

    @Test func interfacesWinOverTheOlderNetworkKeyEvenWithNoMatch() {
        let both = report.setting("NetworkInterfaces", []).setting("Network", ["en0": ["Addresses": ["192.168.1.2"]]])
        #expect(addresses(both) == [])
    }

    @Test func theOlderNetworkKeyListsEveryInterfaceInOrderOfName() {
        let network: PropertyListValue = [
            "en1": ["Addresses": ["192.168.1.3", "192.168.1.2"]], "en0": ["Addresses": ["192.168.1.2"]],
            "lo0": "not a dictionary", "en2": ["Addresses": "not an array"]
        ]
        #expect(addresses(report.setting("Network", network)) == ["192.168.1.2", "192.168.1.3"])
    }

    @Test func aReportWithNoNetworkKeepsTheAddressesAndAFailureClearsThem() {
        #expect(addresses(report) == ["10.0.0.9"])
        #expect(addresses(report, current: nil) == nil)
        #expect(addresses(report.setting("NetworkInterfaces", "wrong type")) == ["10.0.0.9"])
        #expect(addresses(report.setting("NetworkInterfaces", []), failed: true) == nil)
    }

    // MARK: Pre-Metal desktops

    @Test func aPreMetalDesktopNeedsItsGuestAndAConsoleUser() {
        #expect(policy().preMetalDesktopReady)
        #expect(policy().preMetalRefreshInterval == 60)
        #expect(!policy { $0.consoleUID = nil }.preMetalDesktopReady)
        #expect(!policy { $0.guest = .catalina }.preMetalDesktopReady)
        #expect(!policy(report.setting("DesktopRunning", false)).preMetalDesktopReady)
        #expect(!policy(failed: true).preMetalDesktopReady)
        #expect(policy(failed: true).preMetalRefreshInterval == 15)
    }

    @Test func theTabletProbeRunsOnceAndReadsTheDesktopLoosely() {
        let probing = { (state: inout GuestSessionState) in state.legacyTabletGuest = true }
        #expect(policy(report, probing).needsTabletProbe)
        #expect(!policy().needsTabletProbe)
        #expect(!policy(failed: true, probing).needsTabletProbe)
        #expect(
            !policy {
                probing(&$0)
                $0.legacyTabletObserved = true
            }.needsTabletProbe)
        // Odd but original: `boolValue` here, `isEqual:@YES` everywhere else.
        let loose = report.setting("DesktopRunning", "YES")
        #expect(policy(loose, probing).needsTabletProbe)
        #expect(!policy(loose).needsDesktopServices)
        #expect(!policy(report.setting("DesktopRunning", ["wrong type"]), probing).needsTabletProbe)
    }

    // MARK: Refresh steps

    private func step(_ change: (inout GuestSessionState) -> Void = { _ in }) -> GuestRefreshStep {
        var state = session
        state.hasStatusTool = true
        change(&state)
        return state.nextRefreshStep
    }

    @Test func aModernGuestCollectsStatusWhenTheToolExists() {
        #expect(step() == .collectStatus)
        #expect(step { $0.hasStatusTool = false } == .statusToolMissing)
    }

    @Test(arguments: [
        \GuestSessionState.guestPending, \.preparing, \.shutdownRequested
    ])
    func workInProgressStartsNothing(flag: WritableKeyPath<GuestSessionState, Bool> & Sendable) {
        #expect(step { $0[keyPath: flag] = true } == .busy)
        // Ahead of a pending command, which would otherwise schedule a retry.
        #expect(
            step {
                $0[keyPath: flag] = true
                $0.clipboardPending = true
            } == .busy)
    }

    @Test func aStoppedGuestStartsNothing() {
        #expect(step { $0.running = false } == .busy)
    }

    @Test(arguments: [
        \GuestSessionState.diagnosticPending, \.clipboardPending, \.bootPolicyPending
    ])
    func aGuestCommandDefersThePass(flag: WritableKeyPath<GuestSessionState, Bool> & Sendable) {
        #expect(step { $0[keyPath: flag] = true } == .retryAfterCommand)
    }

    @Test func preMetalGuestsGoThroughOpenGLSetupUntilMonitoring() {
        #expect(step { $0.guest = .mavericks } == .openGLSetup)
        #expect(
            step {
                $0.guest = .mavericks
                $0.developmentSetupDeferred = true
            } == .setupPaused)
        #expect(
            step {
                $0.guest = .mavericks
                $0.openGLDesktopMonitoring = true
            } == .collectStatus)
        // Monitoring doesn't excuse a missing tool.
        #expect(
            step {
                $0.guest = .mavericks
                $0.openGLDesktopMonitoring = true
                $0.hasStatusTool = false
            }
                == .statusToolMissing)
    }

    @Test func tigerInstallsNativelyUntilItsOpenGLProfileIsEnabled() {
        #expect(step { $0.guest = .tiger } == .nativeTigerInstallation)
        #expect(
            step {
                $0.guest = .tiger
                $0.developmentSetupDeferred = true
            } == .nativeTigerInstallation)
        #expect(
            step {
                $0.guest = .tiger
                $0.passthroughOpenGLEnabled = true
            } == .openGLSetup)
        #expect(
            step {
                $0.guest = .tiger
                $0.openGLDesktopMonitoring = true
            } == .collectStatus)
    }

    // MARK: Modern guests

    @Test func noReportStillPassesTheChecksThatDontReadOne() {
        #expect(policy(noReport).mayCheckNativeDisplay)
        #expect(policy(noReport).mayClaimAutomaticInstallation)
        #expect(policy(noReport).mayClaimUpdateRepair)
        #expect(!policy(noReport).needsDesktopServices)
        #expect(!policy(noReport).isFromThisGuest)
        #expect(policy(noReport).refreshInterval == 15)
    }

    @Test func aFailedReportPassesNothing() {
        let failed = policy(failed: true) {
            $0.hasModernSetup = true
            $0.repairRequested = true
            $0.explicitRepair = true
            $0.preparationRequested = true
        }
        #expect(!failed.mayCheckNativeDisplay)
        #expect(!failed.mayAdvanceModernSetup)
        #expect(!failed.needsBootPolicyCheck(policyReady: true, bootingGuestFirmware: false))
        #expect(!failed.needsDisplayResize)
        #expect(!failed.mayClaimAutomaticInstallation)
        #expect(!failed.needsDisplayPowerBridge)
        #expect(!failed.needsConsoleUsername)
        #expect(!failed.needsUpdateRepairCheck)
        #expect(!failed.mayClaimUpdateRepair)
        #expect(!failed.mayBeginRepair)
        #expect(!failed.needsReconciliation(journalExists: true))
        #expect(!failed.mayBeginPreparation)
        #expect(!failed.needsDesktopServices)
        #expect(failed.refreshInterval == 15)
    }

    @Test func theNativeDisplayCheckWaitsForStoppingAndPreparing() {
        #expect(policy().mayCheckNativeDisplay)
        #expect(!policy { $0.shutdownRequested = true }.mayCheckNativeDisplay)
        #expect(!policy { $0.preparing = true }.mayCheckNativeDisplay)
        #expect(!policy { $0.preparationRequested = true }.mayCheckNativeDisplay)
        #expect(!policy { $0.relaunchForGraphics = true }.mayCheckNativeDisplay)
    }

    @Test func modernSetupAdvancesOnlyOutsideItsOwnReplay() {
        let setup = { (state: inout GuestSessionState) in state.hasModernSetup = true }
        #expect(!policy().mayAdvanceModernSetup)
        #expect(policy(report, setup).mayAdvanceModernSetup)
        // Preparing doesn't stop it, though it does stop the native display check.
        #expect(
            policy {
                setup(&$0)
                $0.preparing = true
            }.mayAdvanceModernSetup)
        #expect(
            !policy {
                setup(&$0)
                $0.modernSetupReportActive = true
            }.mayAdvanceModernSetup)
        #expect(
            !policy {
                setup(&$0)
                $0.shutdownRequested = true
            }.mayAdvanceModernSetup)
        #expect(
            !policy {
                setup(&$0)
                $0.relaunchForGraphics = true
            }.mayAdvanceModernSetup)
    }

    @Test func bootPolicyIsCheckedOncePerBoot() {
        #expect(policy().needsBootPolicyCheck(policyReady: false, bootingGuestFirmware: false))
        #expect(
            !policy { $0.bootPolicyCheckedBoot = "new-boot" }
                .needsBootPolicyCheck(policyReady: true, bootingGuestFirmware: false))
        #expect(
            policy { $0.bootPolicyCheckedBoot = "old-boot" }
                .needsBootPolicyCheck(policyReady: false, bootingGuestFirmware: false))
        #expect(!policy().needsBootPolicyCheck(policyReady: true, bootingGuestFirmware: true))
        #expect(
            !policy(report.setting("BootSessionUUID", "")).needsBootPolicyCheck(
                policyReady: true, bootingGuestFirmware: false))
    }

    @Test func aPreviouslyVerifiedGuestIsCheckedBeforeItsDesktop() {
        let headless = policy(report.setting("DesktopRunning", false))
        #expect(!headless.needsBootPolicyCheck(policyReady: false, bootingGuestFirmware: false))
        #expect(headless.needsBootPolicyCheck(policyReady: true, bootingGuestFirmware: false))
    }

    @Test func theDisplayIsResizedOnceAtLogin() {
        #expect(policy().needsDisplayResize)
        #expect(!policy { $0.displaySizedBoot = "new-boot" }.needsDisplayResize)
        #expect(!policy(report.setting("DesktopRunning", false)).needsDisplayResize)
        #expect(!policy(report.setting("BootSessionUUID", nil)).needsDisplayResize)
    }

    @Test func thePowerBridgeNeedsFinishedSetupAndABoot() {
        let complete = report.setting("SetupComplete", true)
        #expect(policy(complete).needsDisplayPowerBridge)
        #expect(!policy().needsDisplayPowerBridge)
        #expect(!policy(complete.setting("BootSessionUUID", "")).needsDisplayPowerBridge)
    }

    @Test func theConsoleUsernameIsLearnedOncePerBoot() {
        #expect(policy().needsConsoleUsername)
        #expect(!policy { $0.usernameBoot = "new-boot" }.needsConsoleUsername)
        #expect(!policy { $0.consoleUID = nil }.needsConsoleUsername)
        #expect(!policy(report.setting("DesktopRunning", false)).needsConsoleUsername)
    }

    @Test func claimsDontOverlap() {
        #expect(!policy { $0.preparationRequested = true }.mayClaimAutomaticInstallation)
        #expect(!policy { $0.repairRequested = true }.mayClaimAutomaticInstallation)
        #expect(!policy { $0.preparationRequested = true }.mayClaimUpdateRepair)
        #expect(!policy { $0.repairRequested = true }.mayClaimUpdateRepair)
    }

    @Test func anExplicitRepairIsRecheckedOnlyBeforeTheDesktop() {
        let explicit = { (state: inout GuestSessionState) in
            state.explicitRepair = true
            state.repairRequested = true
        }
        let headless = report.setting("DesktopRunning", false)
        #expect(policy(headless, explicit).needsUpdateRepairCheck)
        #expect(!policy(report, explicit).needsUpdateRepairCheck)
        #expect(!policy(headless) { $0.repairRequested = true }.needsUpdateRepairCheck)
    }

    @Test func repairAndPreparationBeginOnlyWhenRequestedAndAdmitted() {
        let headless = report.setting("DesktopRunning", false)
        #expect(!policy().mayBeginRepair)
        #expect(policy { $0.repairRequested = true }.mayBeginRepair)
        #expect(!policy(headless) { $0.repairRequested = true }.mayBeginRepair)
        #expect(
            policy(headless) {
                $0.repairRequested = true
                $0.verifiedUpdateRepair = true
            }.mayBeginRepair)
        #expect(!policy().mayBeginPreparation)
        #expect(policy { $0.preparationRequested = true }.mayBeginPreparation)
        #expect(!policy(headless) { $0.preparationRequested = true }.mayBeginPreparation)
        #expect(
            policy(headless) {
                $0.preparationRequested = true
                $0.verifiedUpdateRepair = true
            }.mayBeginPreparation)
        #expect(
            !policy {
                $0.preparationRequested = true
                $0.guest = .catalina
            }.mayBeginPreparation)
    }

    // MARK: Reconciliation

    @Test func aBootGetsThreeReconciliations() {
        func attempt(_ count: Int) -> GuestStatusPolicy {
            policy {
                $0.reconciledBoot = "new-boot"
                $0.reconciliationAttempts = count
            }
        }
        #expect(attempt(1).needsReconciliation(journalExists: true))
        #expect(attempt(2).needsReconciliation(journalExists: true))
        #expect(!attempt(3).needsReconciliation(journalExists: true))
        #expect(attempt(2).nextReconciliationAttempt == 3)
    }

    @Test func aNewBootStartsTheCountAgain() {
        let next = policy {
            $0.reconciledBoot = "old-boot"
            $0.reconciliationAttempts = 3
        }
        #expect(next.needsReconciliation(journalExists: true))
        #expect(next.nextReconciliationAttempt == 1)
        #expect(policy().nextReconciliationAttempt == 1)
    }

    @Test func reconciliationNeedsAJournalAndARunningDesktop() {
        #expect(policy().needsReconciliation(journalExists: true))
        #expect(!policy().needsReconciliation(journalExists: false))
        #expect(!policy { $0.preparationRequested = true }.needsReconciliation(journalExists: true))
        #expect(!policy(report.setting("DesktopRunning", false)).needsReconciliation(journalExists: true))
    }

    @Test func aJournalFromAnotherBootNeedsPostRebootProof() {
        let boot = "new-boot" as PropertyListValue
        #expect(!report.reconciliationVerifiesAfterReboot(journal: ["GuestResult": ["BootSessionUUID": boot]]))
        #expect(report.reconciliationVerifiesAfterReboot(journal: ["GuestResult": ["BootSessionUUID": "old-boot"]]))
        #expect(report.reconciliationVerifiesAfterReboot(journal: ["GuestResult": "wrong type"]))
        #expect(report.reconciliationVerifiesAfterReboot(journal: [:]))
        #expect(report.reconciliationVerifiesAfterReboot(journal: nil))
    }

    @Test func reconciliationMessages() {
        typealias Report = GuestReport
        #expect(
            Report.reconciliationMessage(result: ["Phase": "awaiting-reboot"], verified: true)
                == "Graphics verified — installer cleanup will finish when this Mac shuts down")
        #expect(
            Report.reconciliationMessage(result: ["Phase": "awaiting-reboot"], verified: false)
                == "Installation status recovered — restart required for graphics verification")
        #expect(
            Report.reconciliationMessage(result: ["Phase": "rolled-back"], verified: false)
                == "Installation status: rolled-back")
        #expect(Report.reconciliationMessage(result: nil, verified: false) == "Installation status: unknown")
        #expect(Report.reconciliationMessage(result: ["Phase": 7], verified: false) == "Installation status: 7")
    }

    // MARK: End of a pass

    @Test func theNextPassComesSoonWhileThingsAreChanging() {
        #expect(policy().refreshInterval == 60)
        #expect(policy(failed: true).refreshInterval == 15)
        #expect(policy { $0.preparationRequested = true }.refreshInterval == 15)
        #expect(policy(report.setting("DesktopRunning", false)).refreshInterval == 15)
        #expect(policy { $0.networkLinkConnected = true }.refreshInterval == 15)
        #expect(
            policy {
                $0.networkLinkConnected = true
                $0.hasGuestAddresses = true
            }.refreshInterval == 60)
    }

    // MARK: Sleep

    @Test func sleepPolicyArgumentsDependOnTheGuest() {
        var state = session
        #expect(state.sleepPolicyArguments(nativeIdleGuard: true) == ["-a", "sleep", "0", "disablesleep", "1"])
        #expect(state.sleepPolicyArguments(nativeIdleGuard: false) == ["-a", "sleep", "0", "disablesleep", "1"])
        state.guest = .tiger
        #expect(state.sleepPolicyArguments(nativeIdleGuard: true) == nil)
        #expect(state.sleepPolicyArguments(nativeIdleGuard: false) == ["-a", "sleep", "0"])
    }

    // MARK: Display selection

    private let now = Date(timeIntervalSinceReferenceDate: 1000)

    private func selects(_ boot: String? = "boot", _ change: (inout GuestSessionState) -> Void = { _ in }) -> Bool {
        var state = session
        change(&state)
        return state.allowsDisplaySelection(boot: boot, now: now)
    }

    @Test func theDisplayModeIsReassertedOncePerBoot() {
        #expect(selects())
        #expect(!selects(nil))
        #expect(!selects(""))
        #expect(!selects { $0.displaySelectedBoot = "boot" })
        #expect(selects { $0.displaySelectedBoot = "earlier" })
    }

    @Test func bootsCompareLiterally() {
        // Two spellings of "é" are equal to `==` but not to `isEqual:`.
        #expect(selects("caf\u{E9}") { $0.displaySelectedBoot = "cafe\u{301}" })
    }

    @Test func aFailedSelectionWaitsForItsRetryTime() {
        #expect(!selects { $0.displaySelectionRetryAfter = now.addingTimeInterval(1) })
        #expect(selects { $0.displaySelectionRetryAfter = now })
        #expect(selects { $0.displaySelectionRetryAfter = now.addingTimeInterval(-1) })
    }

    @Test func theDisplayModeNeedsAConsoleUser() {
        #expect(!selects { $0.consoleUID = nil })
    }

    @Test(arguments: [
        \GuestSessionState.displayPolicyRestartRequired, \.preparing, \.preparationRequested, \.repairRequested,
        \.guestPending, \.clipboardPending, \.bootPolicyPending, \.displayModePending, \.shutdownRequested
    ])
    func otherWorkHoldsTheDisplayMode(flag: WritableKeyPath<GuestSessionState, Bool> & Sendable) {
        #expect(!selects { $0[keyPath: flag] = true })
    }

    // MARK: Bridge

    @Test func theBridgeCarriesEveryFlagToTheModel() {
        let bridge = GuestSessionStateBridge()
        bridge.guest = "mojave"
        #expect(bridge.state.guest == .mojave)
        #expect(bridge.guest == "mojave")
        bridge.guest = "not a guest"
        #expect(bridge.state.guest == nil)
        bridge.running = true
        bridge.hasStatusTool = true
        #expect(bridge.nextRefreshStep == .collectStatus)
        bridge.consoleUID = 501
        #expect(bridge.state.consoleUID == 501)
        bridge.reconciledBoot = "boot"
        bridge.reconciliationAttempts = 2
        #expect(bridge.state.reconciledBoot == "boot")
        #expect(bridge.state.reconciliationAttempts == 2)
        #expect(bridge.allowsDisplaySelection(boot: "boot"))
    }

    @Test func aReportOfTheWrongTypeReadsAsNoReport() {
        let bridge = GuestSessionStateBridge()
        let policy = GuestStatusPolicyBridge(report: "not a dictionary", failed: false, session: bridge)
        #expect(!policy.needsDesktopServices)
        #expect(policy.mayCheckNativeDisplay)
    }

    @Test func consoleUsernameThroughTheBridge() {
        typealias Bridge = MachineModelBridge
        #expect(Bridge.consoleUsername(statOutput: "501 someone\n", expectedUID: 501) == "someone")
        #expect(Bridge.consoleUsername(statOutput: nil, expectedUID: 501) == nil)
        #expect(Bridge.consoleUsername(statOutput: "4294967294 nobody", expectedUID: -2) == "nobody")
    }
}
