import Foundation
import Testing

@testable import MachineKit

/// Ported from probes/machine-configuration-tests.m, whose file and lock halves remain with VIMMachine.
@Suite struct UpdateRepairEvidenceTests {
    private let journal = Fixture.verifiedJournal
    private let report = Fixture.report

    @Test func aNewBuildOnAVerifiedSameVolumeDesktopSupersedes() {
        #expect(journal.isSuperseded(by: report))
        #expect(report.admitsUpdateRepair(guest: .mojave))
    }

    @Test func eachGuestWithPVGCanRepair() {
        for guest in ["mojave", "catalina", "bigsur"] as [PropertyListValue] {
            let state = journal.setting(
                in: "Preparation", "GuestReport",
                [
                    "Guest": guest, "ProductBuildVersion": "old-build", "VolumeUUID": "same-volume"
                ])
            #expect(state.isSuperseded(by: report.setting("Guest", guest)))
        }
        // An OpenGL guest has no Metal receipt to supersede.
        let leopard = journal.setting(
            in: "Preparation", "GuestReport",
            [
                "Guest": "leopard", "ProductBuildVersion": "old-build", "VolumeUUID": "same-volume"
            ])
        #expect(!leopard.isSuperseded(by: report.setting("Guest", "leopard")))
    }

    @Test(
        arguments: [
            ("ProductBuildVersion", "old-build"), ("VolumeUUID", "different-volume"),
            ("InstalledSystemCandidate", false),
            ("KernelMatchesSystem", false), ("LiveRoot", false), ("BootSessionUUID", "old-boot"),
            ("Guest", "unsupported")
        ] as [(String, PropertyListValue)])
    func aWrongReportIsRefused(key: String, value: PropertyListValue) {
        #expect(!journal.isSuperseded(by: report.setting(key, value)))
    }

    @Test(arguments: [
        "Guest", "InstalledSystemCandidate", "LiveRoot", "KernelMatchesSystem", "VolumeUUID", "BootSessionUUID",
        "ProductBuildVersion"
    ])
    func aMissingReportKeyIsRefused(key: String) {
        #expect(!journal.isSuperseded(by: report.setting(key, nil)))
        #expect(!report.setting(key, nil).admitsUpdateRepair(guest: .mojave))
    }

    @Test func aBuildIsAFilenameSoPathsAreRefused() {
        for build: PropertyListValue in [
            "../../outside", ".hidden", "a/b", "a b", "a\nb", .string(String(repeating: "a", count: 129)), "", 1
        ] {
            #expect(!report.setting("ProductBuildVersion", build).admitsUpdateRepair(guest: .mojave))
        }
        #expect(report.setting("ProductBuildVersion", "20G1426.a-b_c").admitsUpdateRepair(guest: .mojave))
    }

    @Test func aRepairMustNotRequireADesktop() {
        #expect(report.setting("DesktopRunning", false).admitsUpdateRepair(guest: .mojave))
        #expect(journal.isSuperseded(by: report.setting("DesktopRunning", false)))
    }

    @Test func theMachinesGuestMustMatch() {
        #expect(!report.admitsUpdateRepair(guest: .catalina))
        #expect(!report.admitsUpdateRepair(guest: nil))
    }

    @Test(
        arguments: [
            ("Phase", "publishing"), ("Phase", "outcome-unknown"), ("Phase", "rolled-back"),
            ("TransactionID", "not-a-uuid"),
            ("Preparation", "invalid"), ("GuestResult", [:]), ("FormatVersion", 2)
        ] as [(String, PropertyListValue)])
    func aWrongJournalIsRefused(key: String, value: PropertyListValue) {
        #expect(!journal.setting(key, value).isSuperseded(by: report))
    }

    @Test(arguments: ["FormatVersion", "TransactionID", "Phase", "Preparation", "GuestResult", "PostBootVerification"])
    func aMissingJournalKeyIsRefused(key: String) {
        #expect(!journal.setting(key, nil).isSuperseded(by: report))
    }

    @Test(
        arguments: [
            ("GuestResult", "Phase", "publishing"), ("GuestResult", "FilesPublished", false),
            ("GuestResult", "RebootRequired", false), ("GuestResult", "TransactionID", "other"),
            ("GuestResult", "ProductBuildVersion", "other"), ("GuestResult", "VolumeUUID", "other"),
            ("Preparation", "TransactionID", "other"), ("PostBootVerification", "TransactionID", "other"),
            ("PostBootVerification", "VerifiedAfterReboot", false),
            ("PostBootVerification", "MetalCommandVerified", false),
            ("PostBootVerification", "VolumeUUID", "other"), ("PostBootVerification", "BootSessionUUID", ""),
            ("PostBootVerification", "BootSessionUUID", "new-boot"), ("PostBootVerification", "ProductBuildVersion", "")
        ] as [(String, String, PropertyListValue)])
    func aDisagreeingFieldIsRefused(parent: String, key: String, value: PropertyListValue) {
        #expect(!journal.setting(in: parent, key, value).isSuperseded(by: report))
    }

    @Test(arguments: [
        ("GuestResult", "ProductBuildVersion"), ("GuestResult", "VolumeUUID"),
        ("PostBootVerification", "ProductBuildVersion"), ("PostBootVerification", "VolumeUUID"),
        ("PostBootVerification", "BootSessionUUID")
    ])
    func twoMissingFieldsAreNotAMatch(parent: String, key: String) {
        // Would pass if `nil == nil` counted as agreement.
        #expect(!journal.setting(in: parent, key, nil).isSuperseded(by: report))
    }

    @Test func aReadFailureOfAProvenTransactionStillAuthorizes() {
        let missing = journal.setting("PreviousPostBootVerification", journal.values["PostBootVerification"])
            .setting("PostBootVerification", nil).setting("Phase", "outcome-unknown")
            .setting("ReconciliationError", "Old verifier removed by update")
        #expect(missing.isSuperseded(by: report))
        #expect(!missing.setting("ReconciliationError", "").isSuperseded(by: report))
        #expect(!missing.setting("ReconciliationError", 1).isSuperseded(by: report))
        // An uncertain new write can't reuse the old proof.
        #expect(!missing.setting("TransactionID", .string(UUID().uuidString)).isSuperseded(by: report))
    }

    @Test func anEarlierReadOnlyFailureRetainsTheEvidence() {
        let reconciled = journal.setting("PreviousPostBootVerification", journal.values["PostBootVerification"])
            .setting("PostBootVerification", nil).setting("Phase", "awaiting-reboot")
        #expect(reconciled.isSuperseded(by: report))
    }

    @Test func recoveryOfAnExistingClaimIsBoundToThatClaim() {
        let configuration = Fixture.configuration
        let state = journal.setting("Phase", "outcome-unknown").setting("ReconciliationError", "failed")
        let claim: [String: PropertyListValue] = [
            "FormatVersion": 1, "Phase": "claimed", "MachineIdentifier": configuration[.identifier]!,
            "PreviousTransactionID": Fixture.identity, "PreviousBuild": "old-build",
            "GuestReport": ["VolumeUUID": "same-volume", "ProductBuildVersion": "new-build"]
        ]
        func allows(_ claim: [String: PropertyListValue]?, _ state: GuestInstallationJournal) -> Bool {
            state.allowsRepairRecovery(claim: claim, configuration: configuration, report: report)
        }
        #expect(allows(claim, state))
        #expect(!allows(nil, state))
        // Already recovered once: bounded to one retry.
        #expect(!allows(claim.merging(["Phase": "preflight-recovered"]) { $1 }, state))
        #expect(!allows(claim, journal))
        #expect(!allows(claim, state.setting("ReconciliationError", "")))
        #expect(!allows(claim, state.setting("TransactionID", .string(UUID().uuidString))))
        for key in claim.keys {
            var wrong = claim
            wrong[key] = nil
            #expect(!allows(wrong, state), "\(key)")
        }
        #expect(!allows(claim.merging(["MachineIdentifier": "other"]) { $1 }, state))
        #expect(!allows(claim.merging(["PreviousBuild": "other"]) { $1 }, state))
        #expect(
            !allows(
                claim.merging(["GuestReport": ["VolumeUUID": "other", "ProductBuildVersion": "new-build"]]) { $1 },
                state))
        #expect(
            !allows(
                claim.merging(["GuestReport": ["VolumeUUID": "same-volume", "ProductBuildVersion": "x"]]) { $1 }, state)
        )
    }

    @Test func automaticInstallationNeedsALiveDesktopAndItsOwnMedia() {
        let configuration = Fixture.configuration.setting(.installState, "installing")
            .setting(.installerMedia, "Installation/Installer.iso")
        #expect(report.admitsAutomaticInstallation(on: configuration))
        for key in [
            "Guest", "InstalledSystemCandidate", "DesktopRunning", "LiveRoot", "KernelMatchesSystem", "VolumeUUID",
            "BootSessionUUID", "ProductBuildVersion"
        ] {
            #expect(!report.setting(key, nil).admitsAutomaticInstallation(on: configuration), "\(key)")
        }
        #expect(!report.setting("DesktopRunning", false).admitsAutomaticInstallation(on: configuration))
        #expect(!report.admitsAutomaticInstallation(on: configuration.setting(.installState, "installed")))
        #expect(!report.admitsAutomaticInstallation(on: configuration.setting(.installerMedia, nil)))
        #expect(!report.admitsAutomaticInstallation(on: configuration.setting(.guest, "leopard")))
        #expect(!report.setting("Guest", "catalina").admitsAutomaticInstallation(on: configuration))

        let owner = InstallerOwnership(values: [
            "FormatVersion": 1, "MachineIdentifier": configuration[.identifier]!, "Media": "Installation/Installer.iso"
        ])
        #expect(owner.admitsClaim(by: configuration))
        #expect(!InstallerOwnership(values: [:]).admitsClaim(by: configuration))
        #expect(!InstallerOwnership(values: [:]).names(configuration.setting(.installerMedia, nil)))
        #expect(!owner.admitsClaim(by: configuration.setting(.identifier, .string(UUID().uuidString))))
        #expect(!owner.admitsClaim(by: configuration.setting(.installerMedia, "/other.iso")))
    }
}

@Suite struct InstallerCleanupEvidenceTests {
    private let identity: PropertyListValue = "transaction"
    private let report = GuestReport(values: [
        "InstalledSystemCandidate": true, "LiveRoot": true, "KernelMatchesSystem": true, "Guest": "mojave",
        "VolumeUUID": "volume", "BootSessionUUID": "boot", "ProductBuildVersion": "18G103"
    ])
    private var journal: GuestInstallationJournal {
        GuestInstallationJournal(values: [
            "Phase": "graphics-verified", "TransactionID": identity,
            "PostBootVerification": [
                "TransactionID": identity, "VerifiedAfterReboot": true, "MetalCommandVerified": true,
                "VolumeUUID": "volume", "BootSessionUUID": "boot", "ProductBuildVersion": "18G103"
            ]
        ])
    }

    @Test func matchingProofAuthorizesCleanupOnAnyLaterBoot() {
        #expect(journal.authorizesInstallerCleanup(report: report, guest: .mojave))
        #expect(
            journal.authorizesInstallerCleanup(
                report: report.setting("BootSessionUUID", "later-ordinary-boot"), guest: .mojave))
    }

    @Test func mismatchedEvidenceRetainsTheMedia() {
        #expect(
            !journal.authorizesInstallerCleanup(report: report.setting("VolumeUUID", "other-volume"), guest: .mojave))
        #expect(!journal.authorizesInstallerCleanup(report: report.setting("ProductBuildVersion", "x"), guest: .mojave))
        #expect(!journal.authorizesInstallerCleanup(report: report, guest: .catalina))
        #expect(!journal.authorizesInstallerCleanup(report: report, guest: nil))
        for key in report.values.keys {
            #expect(!journal.authorizesInstallerCleanup(report: report.setting(key, nil), guest: .mojave), "\(key)")
        }
        #expect(!journal.setting("Phase", "awaiting-reboot").authorizesInstallerCleanup(report: report, guest: .mojave))
        for key in ["TransactionID", "VerifiedAfterReboot", "MetalCommandVerified", "VolumeUUID", "BootSessionUUID"] {
            #expect(
                !journal.setting(in: "PostBootVerification", key, nil)
                    .authorizesInstallerCleanup(report: report, guest: .mojave), "\(key)")
        }
        // The retained proof of an earlier verification isn't enough to delete anything.
        let previous = journal.setting("PreviousPostBootVerification", journal.values["PostBootVerification"])
            .setting("PostBootVerification", nil)
        #expect(!previous.authorizesInstallerCleanup(report: report, guest: .mojave))
    }

    @Test func ownedMediaNeedsAnExactRecord() {
        let attached = Fixture.configuration.setting(.installerMedia, "Installation/Installer.iso")
        let owner = InstallerOwnership(values: [
            "FormatVersion": 1, "MachineIdentifier": attached[.identifier]!, "Media": "Installation/Installer.iso"
        ])
        #expect(owner.admitsOwnedCleanup(by: attached))
        // Already detached by a crashed cleanup: still finishes idempotently.
        #expect(owner.admitsOwnedCleanup(by: attached.setting(.installerMedia, nil)))
        #expect(!owner.admitsOwnedCleanup(by: attached.setting(.installerMedia, "/other.iso")))
        #expect(!owner.admitsOwnedCleanup(by: attached.setting(.identifier, .string(UUID().uuidString))))
        var wrong = owner
        wrong.values["Media"] = "/Volumes/User.iso"
        #expect(!wrong.admitsOwnedCleanup(by: attached.setting(.installerMedia, "/Volumes/User.iso")))
        wrong = owner
        wrong.values["FormatVersion"] = nil
        #expect(!wrong.admitsOwnedCleanup(by: attached))
    }
}

@Suite struct DisplayEvidenceTests {
    private func evidence(
        _ configuration: MachineConfiguration,
        journal: GuestInstallationJournal = GuestInstallationJournal(values: [:]),
        updater: [String: PropertyListValue]? = nil, native: [String: PropertyListValue]? = nil, firmware: Bool = false
    ) -> InstallerDisplayEvidence {
        InstallerDisplayEvidence(
            configuration: configuration, journal: journal, updater: updater, nativeDisplay: native,
            firmwareSelectsInstaller: firmware)
    }

    private var published: GuestInstallationJournal { Fixture.verifiedJournal }
    private let installed = Fixture.configuration.setting(.installState, "installed")
    private let updater: [String: PropertyListValue] = [
        "FormatVersion": 1, "Guest": "mojave", "PreviousTransactionID": Fixture.identity, "PreviousBuild": "old-build",
        "VolumeUUID": "same-volume"
    ]

    @Test func publicationNeedsEveryPiece() {
        #expect(published.hasPublishedGraphics(for: .mojave))
        #expect(!published.hasPublishedGraphics(for: .catalina))
        #expect(!published.hasPublishedGraphics(for: nil))
        #expect(!published.setting("Phase", "publishing").hasPublishedGraphics(for: .mojave))
        #expect(!published.setting("Phase", "rolled-back").hasPublishedGraphics(for: .mojave))
        #expect(!published.setting("GuestResult", nil).hasPublishedGraphics(for: .mojave))
        #expect(!published.setting("Preparation", nil).hasPublishedGraphics(for: .mojave))
        #expect(!published.setting("FormatVersion", 2).hasPublishedGraphics(for: .mojave))
        #expect(!published.setting("TransactionID", "not-a-uuid").hasPublishedGraphics(for: .mojave))
        #expect(!published.setting(in: "GuestResult", "FilesPublished", false).hasPublishedGraphics(for: .mojave))
        #expect(!published.setting(in: "GuestResult", "RebootRequired", false).hasPublishedGraphics(for: .mojave))
        #expect(!published.setting(in: "GuestResult", "TransactionID", "other").hasPublishedGraphics(for: .mojave))
        #expect(!published.setting(in: "GuestResult", "VolumeUUID", "other").hasPublishedGraphics(for: .mojave))
        #expect(!published.setting(in: "Preparation", "TransactionID", "other").hasPublishedGraphics(for: .mojave))
        // Nothing on either side of a volume or build comparison isn't agreement.
        #expect(!published.setting(in: "GuestResult", "VolumeUUID", nil).hasPublishedGraphics(for: .mojave))
    }

    @Test func softwareVideoWhenTheGuestOrFirmwareNeedsIt() {
        #expect(evidence(installed.setting(.guest, "mavericks")).requiresInstallerDisplay)
        #expect(evidence(installed, firmware: true).requiresInstallerDisplay)
        #expect(!evidence(installed).requiresInstallerDisplay)
        #expect(evidence(installed.setting(.installState, "host-populated")).requiresInstallerDisplay)
        #expect(evidence(installed.setting(.installerMedia, "x")).requiresInstallerDisplay)
    }

    @Test func softwareVideoPersistsAfterTheUpdaterClearsNVRAM() {
        #expect(evidence(installed, journal: published, updater: updater).requiresInstallerDisplay)
    }

    @Test func onlyAFreshNewBuildPublishReleasesTheUpdaterHold() {
        let fresh: PropertyListValue = .string(UUID().uuidString)
        let repaired = GuestInstallationJournal(values: [
            "FormatVersion": 1, "TransactionID": fresh, "Phase": "awaiting-reboot",
            "Preparation": [
                "TransactionID": fresh,
                "GuestReport": ["Guest": "mojave", "ProductBuildVersion": "new-build", "VolumeUUID": "same-volume"]
            ],
            "GuestResult": [
                "TransactionID": fresh, "Phase": "awaiting-reboot", "FilesPublished": true, "RebootRequired": true,
                "ProductBuildVersion": "new-build", "VolumeUUID": "same-volume"
            ]
        ])
        #expect(!evidence(installed, journal: repaired, updater: updater).requiresInstallerDisplay)
        // An interrupted publication never enables PVG.
        #expect(
            evidence(installed, journal: repaired.setting("Phase", "publishing"), updater: updater)
                .requiresInstallerDisplay)
        // A malformed hold record is no hold.
        for key in updater.keys {
            var malformed = updater
            malformed[key] = nil
            #expect(!evidence(installed, journal: repaired, updater: malformed).requiresInstallerDisplay, "\(key)")
        }
    }

    @Test func publishedSupportEndsTheInstallerDisplay() {
        let installing = installed.setting(.installState, "installing").setting(.installerMedia, "x")
        #expect(evidence(installing).requiresInstallerDisplay)
        #expect(!evidence(installing, journal: published).requiresInstallerDisplay)
    }

    @Test func theUpdaterBaselineIsOnlyAVerifiedOne() throws {
        let record = try #require(
            Fixture.verifiedJournal.updaterDisplayRecord(guest: .mojave, startedAt: Date(timeIntervalSince1970: 0)))
        #expect(record["Guest"] == "mojave")
        #expect(record["PreviousBuild"] == "old-build")
        #expect(record["PreviousTransactionID"] == Fixture.identity)
        #expect(record["VolumeUUID"] == "same-volume")
        #expect(record["StartedAt"] == .date(Date(timeIntervalSince1970: 0)))
        let journal = Fixture.verifiedJournal
        #expect(
            journal.setting("PostBootVerification", nil).updaterDisplayRecord(guest: .mojave, startedAt: Date()) == nil)
        for key in ["TransactionID", "ProductBuildVersion", "VolumeUUID", "VerifiedAfterReboot", "MetalCommandVerified"]
        {
            #expect(
                journal.setting(in: "PostBootVerification", key, nil).updaterDisplayRecord(
                    guest: .mojave, startedAt: Date()) == nil,
                "\(key)")
        }
        #expect(
            journal.setting(in: "GuestResult", "VolumeUUID", "other").updaterDisplayRecord(
                guest: .mojave, startedAt: Date()) == nil)
        #expect(
            journal.setting(in: "GuestResult", "ProductBuildVersion", "other").updaterDisplayRecord(
                guest: .mojave, startedAt: Date()) == nil)
    }

    private let bigSur = Fixture.configuration.setting(.guest, "bigsur").setting(.installState, "installing")
        .setting(.installerMedia, "Installation/Installer.iso")
    private var nativeReport: GuestReport {
        GuestReport(values: [
            "Guest": "bigsur", "LiveRoot": true, "KernelMatchesSystem": true, "InstalledRootPresent": true,
            "NativePVGAvailable": true, "SetupComplete": false, "RecoveryToolsPresent": false, "InstallerMarkers": [],
            "VolumeUUID": .string(UUID().uuidString), "BootSessionUUID": .string(UUID().uuidString),
            "ProductBuildVersion": "20G1426"
        ])
    }

    @Test(arguments: [
        "Guest", "LiveRoot", "KernelMatchesSystem", "InstalledRootPresent", "NativePVGAvailable", "SetupComplete",
        "RecoveryToolsPresent", "InstallerMarkers", "VolumeUUID", "BootSessionUUID", "ProductBuildVersion"
    ])
    func incompleteNativeEvidenceIsRefused(key: String) {
        #expect(evidence(bigSur).nativeBigSurDisplayRecord(report: nativeReport.setting(key, nil)) == nil)
    }

    @Test func nativeDisplayDoesNotFabricateCompletion() throws {
        let report = nativeReport
        #expect(evidence(bigSur).requiresInstallerDisplay)
        let record = try #require(evidence(bigSur).nativeBigSurDisplayRecord(report: report))
        #expect(record["NativePVGAvailable"] == true)
        #expect(record["MachineIdentifier"] == bigSur[.identifier])
        #expect(record["VolumeUUID"] == report["VolumeUUID"])
        let handed = evidence(bigSur, native: record)
        #expect(!handed.requiresInstallerDisplay)
        #expect(!handed.journal.hasPublishedGraphics(for: .bigSur))
        #expect(handed.configuration.installState == .installing)
        #expect(handed.configuration[.installerMedia] != nil)
        // Once only.
        #expect(handed.nativeBigSurDisplayRecord(report: report) == nil)
    }

    @Test func nativeDisplayRefusesAnythingButABigSurInstallingOnItsOwn() {
        let report = nativeReport
        #expect(evidence(bigSur, firmware: true).nativeBigSurDisplayRecord(report: report) == nil)
        #expect(evidence(bigSur.setting(.installState, "installed")).nativeBigSurDisplayRecord(report: report) == nil)
        #expect(evidence(bigSur.setting(.installerMedia, nil)).nativeBigSurDisplayRecord(report: report) == nil)
        #expect(evidence(bigSur.setting(.guest, "catalina")).nativeBigSurDisplayRecord(report: report) == nil)
        #expect(evidence(bigSur).nativeBigSurDisplayRecord(report: report.setting("SetupComplete", true)) == nil)
        #expect(evidence(bigSur).nativeBigSurDisplayRecord(report: report.setting("RecoveryToolsPresent", true)) == nil)
        #expect(evidence(bigSur).nativeBigSurDisplayRecord(report: report.setting("InstallerMarkers", ["x"])) == nil)
        #expect(evidence(bigSur).nativeBigSurDisplayRecord(report: report.setting("VolumeUUID", "not-a-uuid")) == nil)
        #expect(
            evidence(bigSur).nativeBigSurDisplayRecord(report: report.setting("ProductBuildVersion", "../x")) == nil)
        #expect(
            evidence(bigSur).nativeBigSurDisplayRecord(
                report: report.setting("ProductBuildVersion", .string(String(repeating: "a", count: 41)))) == nil)
    }

    @Test func aMalformedNativeRecordDoesNotChooseTheDriver() {
        let record: [String: PropertyListValue] = [
            "FormatVersion": 1, "Guest": "bigsur", "NativePVGAvailable": true,
            "MachineIdentifier": bigSur[.identifier]!,
            "VolumeUUID": .string(UUID().uuidString)
        ]
        #expect(!evidence(bigSur, native: record).requiresInstallerDisplay)
        for key in record.keys {
            var malformed = record
            malformed[key] = nil
            #expect(evidence(bigSur, native: malformed).requiresInstallerDisplay, "\(key)")
        }
        #expect(evidence(bigSur.setting(.guest, "catalina"), native: record).requiresInstallerDisplay)
    }
}

/// Ported from probes/opengl-restart-evidence-tests.m.
@Suite struct OpenGLEvidenceTests {
    private let old = "CFAD1CCA-49A1-450C-8559-81FEDA907D98"
    private let now = "00112233-4455-6677-8899-AABBCCDDEEFF"

    private var initial: GuestReport {
        GuestReport(values: [
            "MachineIdentifier": .string(now), "VolumeUUID": .string(old), "KernelMatchesSystem": true, "Graphics": [:]
        ])
    }

    private func resumes(
        _ report: GuestReport, machine: String? = nil, volume: String? = nil, installing: Bool = true,
        systemMatches: Bool = true
    ) -> Bool {
        report.openGLInitialGraphicsCanResume(
            machine: machine ?? now, volume: volume ?? old, installing: installing, systemMatches: systemMatches)
    }

    @Test func firstInstallResumesOnlyOnItsOwnMachineAndVolume() {
        // The older Leopard status tool omits the separate authorization bit.
        #expect(resumes(initial))
        #expect(!resumes(initial, machine: old))
        #expect(!resumes(initial, volume: now))
        #expect(!resumes(initial, installing: false))
        #expect(!resumes(initial, systemMatches: false))
        #expect(!resumes(initial.setting("InstallationOwnershipVerified", false)))
        #expect(resumes(initial.setting("InstallationOwnershipVerified", true)))
        #expect(!resumes(initial.setting("KernelMatchesSystem", false)))
        #expect(!resumes(initial.setting("Graphics", ["Phase": "installed"])))
        #expect(!resumes(initial.setting("Graphics", "not a dictionary")))
        // JSON null is an explicit answer from a newer tool, and it isn't yes.
        #expect(!resumes(initial.setting("InstallationOwnershipVerified", .null)))
        #expect(
            !initial.openGLInitialGraphicsCanResume(machine: nil, volume: old, installing: true, systemMatches: true))
    }

    private var graphics: [String: PropertyListValue] {
        ["ChangedThisBoot": true, "EngineSHA256": "engine", "BackendSHA256": "backend"]
    }

    private func report(_ graphics: [String: PropertyListValue]) -> GuestReport {
        GuestReport(values: [
            "MachineIdentifier": "machine", "VolumeUUID": "volume", "ProductBuildVersion": "9L31a",
            "Graphics": .dictionary(graphics)
        ])
    }

    @Test func bundledSupportNeedsTheNewReceiptExceptOnTiger() {
        let expected: [String: PropertyListValue] = ["EngineSHA256": "engine", "BackendSHA256": "backend"]
        let plain = report(graphics)
        #expect(!plain.openGLBundledSupportMatches(guest: "leopard", expected: expected))
        #expect(
            plain.setting("GraphicsRestartEvidenceVersion", 1).openGLBundledSupportMatches(
                guest: "leopard", expected: expected))
        #expect(plain.openGLBundledSupportMatches(guest: "tiger", expected: expected))
        #expect(!plain.openGLBundledSupportMatches(guest: "tiger", expected: ["EngineSHA256": "engine"]))
        #expect(!plain.openGLBundledSupportMatches(guest: "tiger", expected: nil))
        #expect(!report([:]).openGLBundledSupportMatches(guest: "tiger", expected: [:]))
    }

    private var acknowledged: [String: PropertyListValue] {
        [
            "MachineIdentifier": "machine", "RequestState": "acknowledged", "FromBootSessionUUID": .string(old),
            "GuestReport": [
                "MachineIdentifier": "machine", "VolumeUUID": "volume", "ProductBuildVersion": "9L31a",
                "Graphics": .dictionary(graphics)
            ]
        ]
    }

    @Test func aChangedPayloadRestartsOnceAcrossAnAcknowledgedBoot() {
        let plain = report(graphics)
        #expect(plain.openGLGraphicsNeedsRestart(restart: nil, boot: now))
        #expect(plain.openGLGraphicsNeedsRestart(restart: acknowledged, boot: old))
        #expect(!plain.openGLGraphicsNeedsRestart(restart: acknowledged, boot: now))
        #expect(!report(["ChangedThisBoot": false]).openGLGraphicsNeedsRestart(restart: nil, boot: now))
        var changed = graphics
        changed["BackendSHA256"] = "new backend"
        #expect(report(changed).openGLGraphicsNeedsRestart(restart: acknowledged, boot: now))
    }

    @Test func aStampedReceiptDecidesByItsBoot() {
        var stamped = graphics
        stamped["InstalledBootSessionUUID"] = .string(now)
        #expect(report(stamped).openGLGraphicsNeedsRestart(restart: acknowledged, boot: now))
        stamped["InstalledBootSessionUUID"] = .string(old)
        #expect(!report(stamped).openGLGraphicsNeedsRestart(restart: nil, boot: now))
    }

    @Test func aRestartRecordMustBeOursAndComplete() {
        let plain = report(graphics)
        var record = acknowledged
        record["RequestState"] = "prepared"
        #expect(plain.openGLGraphicsNeedsRestart(restart: record, boot: now))
        record = acknowledged
        record["FromBootSessionUUID"] = "not-a-uuid"
        #expect(plain.openGLGraphicsNeedsRestart(restart: record, boot: now))
        record = acknowledged
        record["MachineIdentifier"] = "other"
        #expect(plain.openGLGraphicsNeedsRestart(restart: record, boot: now))
        record = acknowledged
        record["GuestReport"] = nil
        #expect(plain.openGLGraphicsNeedsRestart(restart: record, boot: now))
    }

    private let target: [String: PropertyListValue] = ["VolumeUUID": "volume"]

    private var setup: GuestReport {
        GuestReport(values: [
            "OwnershipVerified": true, "KernelMatchesSystem": true, "PixelChecksPassed": true,
            "MachineIdentifier": Fixture.configuration[.identifier]!, "VolumeUUID": "volume",
            "BootSessionUUID": .string(now), "ProductBuildVersion": "9L31a",
            "Graphics": ["ProductBuildVersion": "9L31a", "Phase": "installed"]
        ])
    }

    @Test func setupEvidenceRequiresEveryPiece() {
        let leopard = Fixture.configuration.setting(.guest, "leopard")
        #expect(setup.isOpenGLSetupEvidence(on: leopard, target: target, requirePixels: true))
        #expect(!setup.isOpenGLSetupEvidence(on: Fixture.configuration, target: target, requirePixels: true))
        #expect(!setup.isOpenGLSetupEvidence(on: leopard, target: nil, requirePixels: true))
        for key in setup.values.keys {
            #expect(
                !setup.setting(key, nil).isOpenGLSetupEvidence(on: leopard, target: target, requirePixels: true),
                "\(key)")
        }
        #expect(
            !setup.setting("BootSessionUUID", "not-a-uuid").isOpenGLSetupEvidence(
                on: leopard, target: target, requirePixels: true))
        #expect(
            !setup.setting("BootSessionUUID", 1).isOpenGLSetupEvidence(on: leopard, target: target, requirePixels: true)
        )
    }

    @Test func aRestartDoesNotNeedPixelsButCompletionDoes() {
        let leopard = Fixture.configuration.setting(.guest, "leopard")
        let unpainted = setup.setting("PixelChecksPassed", false)
        #expect(unpainted.isOpenGLSetupEvidence(on: leopard, target: target, requirePixels: false))
        #expect(!unpainted.isOpenGLSetupEvidence(on: leopard, target: target, requirePixels: true))
    }

    @Test func tigerAlsoNeedsItsFilesVerified() {
        let tiger = Fixture.configuration.setting(.guest, "tiger")
        #expect(!setup.isOpenGLSetupEvidence(on: tiger, target: target, requirePixels: true))
        #expect(
            setup.setting("GraphicsFilesVerified", true).isOpenGLSetupEvidence(
                on: tiger, target: target, requirePixels: true))
    }

    @Test func automaticSetupMustHaveFinishedFirstLogin() {
        #expect(setup.hasFinishedFirstLogin(automaticSetup: nil))
        #expect(setup.hasFinishedFirstLogin(automaticSetup: ["Enabled": false]))
        #expect(!setup.hasFinishedFirstLogin(automaticSetup: ["Enabled": true]))
        #expect(
            setup.setting("Account", ["Phase": "complete"]).hasFinishedFirstLogin(automaticSetup: ["Enabled": true]))
        #expect(
            !setup.setting("Account", ["Phase": "pending"]).hasFinishedFirstLogin(automaticSetup: ["Enabled": true]))
    }
}

/// VIMSession's finishGuestStatus.
@Suite struct SessionEvidenceTests {
    private let report = Fixture.report

    @Test func aLiveInstalledSystemNeedsAllThree() {
        #expect(report.isLiveInstalledSystem)
        for key in ["InstalledSystemCandidate", "LiveRoot", "KernelMatchesSystem"] {
            #expect(!report.setting(key, nil).isLiveInstalledSystem, "\(key)")
            #expect(!report.setting(key, false).isLiveInstalledSystem, "\(key)")
        }
    }

    @Test func aDesktopBelongsToTheMachinesGuest() {
        #expect(report.hasRunningDesktop(guest: .mojave))
        #expect(!report.hasRunningDesktop(guest: .catalina))
        #expect(!report.setting("DesktopRunning", false).hasRunningDesktop(guest: .mojave))
    }

    @Test func aCompletionReportGoesStaleWithItsSystem() {
        #expect(report.stillMatches(completionReport: report))
        for key in ["BootSessionUUID", "ProductBuildVersion", "VolumeUUID"] {
            #expect(!report.setting(key, "other").stillMatches(completionReport: report), "\(key)")
            #expect(!report.setting(key, nil).stillMatches(completionReport: report.setting(key, nil)), "\(key)")
        }
        #expect(!report.setting("InstalledSystemCandidate", false).stillMatches(completionReport: report))
    }

    @Test func aBootPolicyCheckMayPrecedeTheDesktopOnlyWhenAlreadyProven() {
        #expect(report.admitsBootPolicyCheck(guest: .mojave, policyAlreadyReady: false))
        let headless = report.setting("DesktopRunning", false)
        #expect(!headless.admitsBootPolicyCheck(guest: .mojave, policyAlreadyReady: false))
        #expect(headless.admitsBootPolicyCheck(guest: .mojave, policyAlreadyReady: true))
        #expect(!report.admitsBootPolicyCheck(guest: .catalina, policyAlreadyReady: true))
        for key in ["BootSessionUUID", "InstalledSystemCandidate", "LiveRoot", "KernelMatchesSystem"] {
            #expect(!report.setting(key, nil).admitsBootPolicyCheck(guest: .mojave, policyAlreadyReady: true), "\(key)")
        }
    }

    @Test func aPolicyRepairRestartsOnlyTheBootItRepaired() {
        let headless = report.setting("DesktopRunning", false)
        let policy: [String: PropertyListValue] = [
            "RecoveryBootSessionUUID": "new-boot", "Result": ["Changed": true]
        ]
        #expect(headless.bootPolicyRepairNeedsRestart(policy: policy))
        #expect(!report.bootPolicyRepairNeedsRestart(policy: policy))
        #expect(!headless.bootPolicyRepairNeedsRestart(policy: nil))
        #expect(!headless.setting("BootSessionUUID", "later").bootPolicyRepairNeedsRestart(policy: policy))
        #expect(!headless.bootPolicyRepairNeedsRestart(policy: ["RecoveryBootSessionUUID": "new-boot", "Result": [:]]))
    }

    @Test func preparationNeedsADesktopUnlessARepairWasVerified() {
        #expect(report.admitsPreparation(guest: .mojave, verifiedUpdateRepair: false))
        let headless = report.setting("DesktopRunning", false)
        #expect(!headless.admitsPreparation(guest: .mojave, verifiedUpdateRepair: false))
        #expect(headless.admitsPreparation(guest: .mojave, verifiedUpdateRepair: true))
        #expect(!report.admitsPreparation(guest: .catalina, verifiedUpdateRepair: true))
        #expect(
            !report.setting("InstalledSystemCandidate", false).admitsPreparation(
                guest: .mojave, verifiedUpdateRepair: true))
    }

    @Test func reconciliationIsForAnIdentifiedDesktop() {
        #expect(report.admitsReconciliation(guest: .mojave))
        for key in ["BootSessionUUID", "DesktopRunning", "InstalledSystemCandidate", "Guest"] {
            #expect(!report.setting(key, nil).admitsReconciliation(guest: .mojave), "\(key)")
        }
        #expect(report.isVerifiedByReconciliation(result: ["VerifiedAfterReboot": true, "BootSessionUUID": "new-boot"]))
        #expect(
            !report.isVerifiedByReconciliation(result: ["VerifiedAfterReboot": true, "BootSessionUUID": "old-boot"]))
        #expect(!report.isVerifiedByReconciliation(result: ["BootSessionUUID": "new-boot"]))
        #expect(!report.isVerifiedByReconciliation(result: nil))
    }

    @Test func theConsoleUserMustBeTheExpectedRealUser() {
        #expect(GuestReport.consoleUsername(statOutput: "501 someone\n", expectedUID: 501) == "someone")
        #expect(GuestReport.consoleUsername(statOutput: "501 someone", expectedUID: 502) == nil)
        #expect(GuestReport.consoleUsername(statOutput: "0 root", expectedUID: 0) == nil)
        #expect(GuestReport.consoleUsername(statOutput: "500 service", expectedUID: 500) == nil)
        #expect(GuestReport.consoleUsername(statOutput: "501", expectedUID: 501) == nil)
        #expect(GuestReport.consoleUsername(statOutput: "501 two words", expectedUID: 501) == nil)
        #expect(GuestReport.consoleUsername(statOutput: "", expectedUID: 501) == nil)
    }
}
