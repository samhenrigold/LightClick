import Foundation
import Testing

@testable import MachineKit

@Suite struct ObjectiveCBridgeTests {
    private let report = Fixture.report.values.mapValues(\.foundationObject) as NSDictionary
    private let journal = Fixture.verifiedJournal.values.mapValues(\.foundationObject) as NSDictionary

    @Test func wrongTypesRefuseRatherThanTrap() {
        #expect(!MachineModelBridge.verifiedInstallationSuperseded(nil, report: report))
        #expect(!MachineModelBridge.verifiedInstallationSuperseded(journal, report: nil))
        #expect(!MachineModelBridge.verifiedInstallationSuperseded("journal", report: 1))
        #expect(!MachineModelBridge.settingsAreValid(nil))
        #expect(!MachineModelBridge.settingsAreValid("c"))
        #expect(!MachineModelBridge.hasPublishedGraphics(journal: journal, guest: 1))
        #expect(!MachineModelBridge.admitsUpdateRepair(report: report, guest: nil))
        #expect(MachineModelBridge.updaterDisplayRecord(journal: journal, guest: nil) == nil)
        #expect(!MachineModelBridge.authorizesInstallerCleanup(journal: journal, report: nil, guest: "mojave"))
        #expect(!MachineModelBridge.openGLGraphicsNeedsRestart(report: nil, restart: nil, boot: nil))
    }

    @Test func aMalformedNestedJournalRefusesRatherThanCrashing() {
        // `state[@"PostBootVerification"][@"…"]` on a string was an exception in Objective-C.
        let malformed: NSDictionary = [
            "FormatVersion": 1, "TransactionID": UUID().uuidString, "GuestResult": "x", "Preparation": "y",
            "PostBootVerification": "z", "Phase": "graphics-verified"
        ]
        #expect(!MachineModelBridge.verifiedInstallationSuperseded(malformed, report: report))
        #expect(!MachineModelBridge.hasPublishedGraphics(journal: malformed, guest: "mojave"))
        #expect(!MachineModelBridge.authorizesInstallerCleanup(journal: malformed, report: report, guest: "mojave"))
    }

    @Test func dictionariesComeBackAsTheyWent() throws {
        let original = Fixture.configuration.setting(.audioEnabled, 1).setting(.description, "x").foundationObject
        let edited = MachineModelBridge.editable(original, pending: nil)
        #expect(edited == original)
        let number = try #require(edited["AudioEnabled"] as? NSNumber)
        #expect(CFGetTypeID(number) != CFBooleanGetTypeID())
    }

    @Test func aFullClaimDecisionMatchesTheModel() {
        #expect(MachineModelBridge.verifiedInstallationSuperseded(journal, report: report))
        #expect(MachineModelBridge.admitsUpdateRepair(report: report, guest: "mojave"))
        #expect(MachineModelBridge.hasPublishedGraphics(journal: journal, guest: "mojave"))
        #expect(MachineModelBridge.isLiveInstalledSystem(report: report))
        #expect(MachineModelBridge.stillMatches(report: report, completionReport: report))
        #expect(MachineModelBridge.admitsPreparation(report: report, guest: "mojave", verifiedUpdateRepair: false))
    }

    @Test func foundationBooleansAndNumbersFromJSONCompareAsBefore() throws {
        let json = try JSONSerialization.jsonObject(
            with: Data(#"{"LiveRoot":1,"KernelMatchesSystem":true,"InstalledSystemCandidate":1.0}"#.utf8))
        #expect(MachineModelBridge.isLiveInstalledSystem(report: json))
        let nulled = try JSONSerialization.jsonObject(
            with: Data(#"{"LiveRoot":null,"KernelMatchesSystem":true,"InstalledSystemCandidate":true}"#.utf8))
        #expect(!MachineModelBridge.isLiveInstalledSystem(report: nulled))
    }

    @Test func theBridgeRefusesAnUneditableKeyBeforeQueueingIt() {
        let base = Fixture.configuration.foundationObject
        #expect(throws: (any Error).self) { try MachineModelBridge.validate(settings: ["Disk": "/x"], editable: base) }
        #expect(throws: (any Error).self) {
            try MachineModelBridge.validate(settings: ["CPUCount": 128], editable: base)
        }
        #expect(throws: (any Error).self) {
            try MachineModelBridge.validate(settings: ["MACAddress": 1], editable: base)
        }
        #expect(throws: (any Error).self) {
            try MachineModelBridge.validate(settings: ["DisplayMode": "bogus"], editable: base)
        }
        #expect(throws: Never.self) {
            try MachineModelBridge.validate(
                settings: ["MACAddress": "02:34:56:78:9A:BC", "DisplayMode": "space", "NetworkConnected": false],
                editable: base)
        }
    }

    @Test func namesThatAreNotStringsAreInvalid() {
        #expect(!MachineModelBridge.nameIsValid(1))
        #expect(!MachineModelBridge.nameIsValid(nil))
        #expect(!MachineModelBridge.renameIsValid(1))
        #expect(MachineModelBridge.nameIsValid("Mac"))
    }

    @Test func aRefusedConfigurationBridgesItsOldError() throws {
        try Fixture.withPackage { package in
            #expect(throws: Never.self) {
                try MachineModelBridge.validate(Fixture.configuration.foundationObject, package: package)
            }
            do {
                try MachineModelBridge.validate(["FormatVersion": 2] as NSDictionary, package: package)
                Issue.record("Accepted")
            } catch {
                let error = error as NSError
                #expect(error.domain == "VirtualIntelMac.Machine")
                #expect(error.localizedDescription.hasPrefix("This Mac’s configuration is invalid"))
            }
        }
    }

    @Test func theMachineKeepsItsTransitionsThroughTheBridge() throws {
        let attached = Fixture.configuration.setting(.installState, "installing").setting(.installerMedia, "/a.iso")
            .setting(.installerMediaShared, true).foundationObject
        #expect(MachineModelBridge.finishingWithSharedInstaller(attached)["InstallerMedia"] == nil)
        #expect(MachineModelBridge.finishingWithSharedInstaller(attached)["InstallState"] as? String == "installed")
        #expect(MachineModelBridge.restartingForOpenGLSetup(attached)["InstallState"] as? String == "patching")
        #expect(throws: (any Error).self) { try MachineModelBridge.finishingOpenGLSetup(attached) }
        #expect(MachineModelBridge.removingLegacyName(["Name": "Mac", "CPUCount": 4] as NSDictionary)["Name"] == nil)
    }
}
