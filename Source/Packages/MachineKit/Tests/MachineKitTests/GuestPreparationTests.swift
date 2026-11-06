import Foundation
import Testing

@testable import MachineKit

/// What a guest tool's run looks like when GuestControl's bridge has reported it.
private func command(
    json: String? = nil, stderr: String? = nil, plist: [String: Any]? = nil, exitcode: Int = 0,
    signal: PropertyListValue? = nil
) throws -> GuestCommandResult {
    var values: [String: PropertyListValue] = ["exitcode": .number(exitcode as NSNumber)]
    values["signal"] = signal
    if let json { values["stdout"] = .data(Data(json.utf8)) }
    if let stderr { values["stderr"] = .data(Data(stderr.utf8)) }
    if let plist {
        values["stdout"] = .data(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    }
    return GuestCommandResult(values: values)
}

private func refusal(_ check: () throws(GuestPreparationError) -> Void) -> GuestPreparationError? {
    do throws(GuestPreparationError) {
        try check()
        return nil
    } catch {
        return error
    }
}

private let report = GuestReport(values: [
    "Guest": "mojave", "InstalledSystemCandidate": true, "DesktopRunning": true, "LiveRoot": true,
    "KernelMatchesSystem": true, "ProductBuildVersion": "18G103", "VolumeUUID": "volume"
])
private let checks = GuestPreparationChecks(initialReport: report)

@Suite struct GuestCommandResultTests {
    @Test func successIsAZeroExitAndNoSignalKeyAtAll() throws {
        #expect(try command().succeeded)
        #expect(try !command(exitcode: 1).succeeded)
        #expect(try !command(signal: .null).succeeded)
        #expect(try !command(signal: 0).succeeded)
        #expect(!GuestCommandResult(foundationObject: nil).succeeded)
        #expect(!GuestCommandResult(foundationObject: "x").succeeded)
        #expect(GuestCommandResult(values: ["exitcode": false]).succeeded, "false is equal to 0, as with isEqual:")
    }

    @Test func jsonNeedsSuccessAndAnObject() throws {
        #expect(try command(json: #"{"a":1}"#).json?["a"] == 1)
        #expect(try command(json: #"{"a":1}"#, exitcode: 1).json == nil)
        #expect(try command(json: "[1]").json == nil)
        #expect(try command(json: "not json").json == nil)
        #expect(try command().json == nil)
        #expect(GuestCommandResult(values: ["exitcode": 0, "stdout": "not data"]).json == nil)
    }

    @Test func aDiagnosticIsNonEmptyUTF8() throws {
        #expect(try command(stderr: "why").diagnostic == "why")
        #expect(try command(stderr: "").diagnostic == nil)
        #expect(GuestCommandResult(values: ["stderr": .data(Data([0xFF, 0xFE]))]).diagnostic == nil)
    }
}

@Suite struct InitialReportTests {
    @Test func aMatchingDesktopIsAdmitted() throws {
        try checks.verifyInitialReport(allowingHeadlessRepair: false)
    }

    @Test(arguments: ["LiveRoot", "KernelMatchesSystem", "InstalledSystemCandidate", "VolumeUUID", "Guest"])
    func eachRequirementRefusesAlone(key: String) {
        let broken = GuestPreparationChecks(initialReport: report.setting(key, nil))
        #expect(
            refusal { () throws(GuestPreparationError) in try broken.verifyInitialReport(allowingHeadlessRepair: true) }
                == .unsuitableSystem)
    }

    @Test func onlyAHeadlessRepairMayGoWithoutADesktop() throws {
        let headless = GuestPreparationChecks(initialReport: report.setting("DesktopRunning", false))
        #expect(
            refusal { () throws(GuestPreparationError) in
                try headless.verifyInitialReport(allowingHeadlessRepair: false)
            }
                == .unsuitableSystem)
        try headless.verifyInitialReport(allowingHeadlessRepair: true)
    }

    @Test(arguments: ["tiger", "highsierra", "ventura"] as [PropertyListValue])
    func onlyParavirtualizedGuestsArePrepared(guest: PropertyListValue) {
        let other = GuestPreparationChecks(initialReport: report.setting("Guest", guest))
        #expect(
            refusal { () throws(GuestPreparationError) in try other.verifyInitialReport(allowingHeadlessRepair: false) }
                == .unsuitableSystem)
    }

    @Test(arguments: ["", 1] as [PropertyListValue])
    func anEmptyOrWrongTypeVolumeRefuses(volume: PropertyListValue) {
        let other = GuestPreparationChecks(initialReport: report.setting("VolumeUUID", volume))
        #expect(
            refusal { () throws(GuestPreparationError) in try other.verifyInitialReport(allowingHeadlessRepair: false) }
                == .unsuitableSystem)
    }
}

@Suite struct SupportDiscTests {
    private let disc: [String: Any] = ["VolumeName": "Virtual Intel Mac Support", "DeviceIdentifier": "disk2s1"]

    private func lookup(_ disks: Any, mayRetry: Bool = false) throws -> SupportDisc.Lookup {
        try SupportDisc.lookup(
            inDiskList: try command(plist: ["AllDisksAndPartitions": disks]), mayRetry: mayRetry)
    }

    private func lookupRefusal(_ disks: Any, mayRetry: Bool = false) throws -> GuestPreparationError? {
        let result = try command(plist: ["AllDisksAndPartitions": disks])
        return refusal { () throws(GuestPreparationError) in
            _ = try SupportDisc.lookup(inDiskList: result, mayRetry: mayRetry)
        }
    }

    @Test func theDiscIsFoundAtTheTopOrInAPartition() throws {
        #expect(try lookup([disc]) == .found("disk2s1"))
        #expect(try lookup([["Partitions": [disc]]]) == .found("disk2s1"))
        #expect(try lookup(["junk", ["Partitions": [["Partitions": [disc]]]]]) == .found("disk2s1"))
    }

    @Test func absenceOnlyWaitsWhileRetriesRemain() throws {
        #expect(try lookup([], mayRetry: true) == .notPublishedYet)
        #expect(try lookupRefusal([], mayRetry: false) == .supportDiscMissingOrAmbiguous)
    }

    @Test func twoDiscsAreAnAnswerNotAReasonToWait() throws {
        let other: [String: Any] = ["VolumeName": "Virtual Intel Mac Support", "DeviceIdentifier": "disk3"]
        #expect(try lookupRefusal([disc, other], mayRetry: true) == .supportDiscMissingOrAmbiguous)
    }

    @Test(arguments: ["disk", "disk1;rm", "/dev/disk1", "disk1s", "disk1s1s", " disk1"])
    func aMalformedIdentifierNeverReachesDiskutil(identifier: String) throws {
        let bad: [String: Any] = ["VolumeName": "Virtual Intel Mac Support", "DeviceIdentifier": identifier]
        #expect(try lookupRefusal([bad], mayRetry: true) == .supportDiscMissingOrAmbiguous)
    }

    /// Odd, and kept: `$` also matches before a final newline. It's harmless, as an argument with no shell.
    @Test func aTrailingNewlineStillMatchesAsItDidInObjectiveC() throws {
        let bad: [String: Any] = ["VolumeName": "Virtual Intel Mac Support", "DeviceIdentifier": "disk2\n"]
        #expect(try lookup([bad]) == .found("disk2\n"))
    }

    @Test func aDeviceIdentifierOfTheWrongTypeIsNoMatch() throws {
        let bad: [String: Any] = ["VolumeName": "Virtual Intel Mac Support", "DeviceIdentifier": 2]
        #expect(try lookup([bad], mayRetry: true) == .notPublishedYet)
    }

    @Test func tooManyEntriesAtTheTopRefuse() throws {
        #expect(try lookupRefusal(Array(repeating: disc, count: 129)) == .diskListNotRecognized)
        #expect(try lookupRefusal(["not": "a list"]) == .diskListNotRecognized)
    }

    /// Odd, and kept: partitions past the limit are silently not looked at, so a disc there reads as absent.
    @Test func partitionsPastTheLimitAreSkippedNotRefused() throws {
        let filler = Array(repeating: ["x": 1] as [String: Any], count: 126)
        #expect(try lookup(filler + [["Partitions": [disc, disc]]], mayRetry: true) == .notPublishedYet)
        #expect(try lookup(filler + [["Partitions": [disc]]]) == .found("disk2s1"))
    }

    @Test func anUnparseableOrFailedListRefuses() throws {
        let garbage = try command(json: "not a plist")
        let failed = try command(plist: ["AllDisksAndPartitions": [disc]], exitcode: 1)
        for result in [garbage, failed] {
            #expect(
                refusal { () throws(GuestPreparationError) in
                    _ = try SupportDisc.lookup(inDiskList: result, mayRetry: true)
                }
                    == .supportDiscNotLocated)
        }
    }

    @Test func theDiscMustSayItIsReadOnly() throws {
        try SupportDisc.verify(
            info: try command(plist: ["VolumeName": "Virtual Intel Mac Support", "WritableMedia": false]))
        for info: [String: Any] in [
            ["VolumeName": "Virtual Intel Mac Support", "WritableMedia": true],
            ["VolumeName": "Virtual Intel Mac Support"],
            ["VolumeName": "Other", "WritableMedia": false]
        ] {
            let result = try command(plist: info)
            #expect(
                refusal { () throws(GuestPreparationError) in try SupportDisc.verify(info: result) }
                    == .supportDiscNotReadOnly)
        }
    }
}

@Suite struct StagingTests {
    private let directory = "/private/var/tmp/VirtualIntelMac.1"

    private var transfer: [String: PropertyListValue] {
        [
            "Directory": .string(directory), "Archive": "payload.tar.xz", "FilesStaged": true,
            "MediaDevice": "/dev/disk2s1",
            "Files": [["Name": "other", "Size": 1], ["Name": "payload.tar.xz", "Size": 5]]
        ]
    }

    private func copyRefusal(_ transfer: [String: PropertyListValue]) -> GuestPreparationError? {
        refusal { () throws(GuestPreparationError) in try GuestPreparationChecks.verifyStagedCopy(transfer) }
    }

    @Test func theDirectoryMustComeBackElseTheToolsWordsAreShown() throws {
        try GuestPreparationChecks.verifyStaging(try command(json: #"{"Directory":"/d"}"#), directory: "/d")
        let wrong = try command(json: #"{"Directory":"/e"}"#, stderr: "the tool's words")
        #expect(
            refusal { () throws(GuestPreparationError) in
                try GuestPreparationChecks.verifyStaging(wrong, directory: "/d")
            }
                == .stagingNotVerified(diagnostic: "the tool's words"))
        let silent = try command(json: "{}")
        let error = refusal { () throws(GuestPreparationError) in
            try GuestPreparationChecks.verifyStaging(silent, directory: "/d")
        }
        #expect(error?.errorDescription == "Could not verify the private guest support copy. Nothing was installed.")
    }

    @Test func aCompleteCopyPasses() {
        #expect(copyRefusal(transfer) == nil)
    }

    @Test(arguments: ["payload.tar", "../payload.tar.xz", "payload.tar.bz2"] as [PropertyListValue])
    func onlyKnownArchiveNamesPass(archive: PropertyListValue) {
        var transfer = transfer
        transfer["Archive"] = archive
        #expect(copyRefusal(transfer) == .stagedCopyIncomplete)
    }

    @Test func theArchiveMustBeListedAndNotEmpty() {
        var transfer = transfer
        transfer["Files"] = [["Name": "payload.tar.xz", "Size": 0]]
        #expect(copyRefusal(transfer) == .stagedCopyIncomplete)
        transfer["Files"] = [["Name": "other", "Size": 5]]
        #expect(copyRefusal(transfer) == .stagedCopyIncomplete)
        transfer["Files"] = nil
        #expect(copyRefusal(transfer) == .stagedCopyIncomplete)
    }

    /// `-longLongValue` reads strings too and truncates fractions, and these keep passing or failing as they did.
    @Test func theSizeReadsAsLongLongValueDid() {
        var transfer = transfer
        transfer["Files"] = [["Name": "payload.tar.xz", "Size": "12"]]
        #expect(copyRefusal(transfer) == nil)
        transfer["Files"] = [["Name": "payload.tar.xz", "Size": .number(0.5 as NSNumber)]]
        #expect(copyRefusal(transfer) == .stagedCopyIncomplete)
        transfer["Files"] = [["Name": "payload.tar.xz", "Size": .number(1.5 as NSNumber)]]
        #expect(copyRefusal(transfer) == nil)
    }

    /// Each of these raised an exception in Objective-C, which would have taken the whole app down.
    @Test func malformedFilesRefuseRatherThanCrash() {
        var transfer = transfer
        for files: PropertyListValue in [1, "x", ["not a dictionary"], [["Name": "payload.tar.xz", "Size": ["x"]]]] {
            transfer["Files"] = files
            #expect(copyRefusal(transfer) == .stagedCopyIncomplete)
        }
    }

    @Test func filesStagedMustBeTrue() {
        var transfer = transfer
        transfer["FilesStaged"] = false
        #expect(copyRefusal(transfer) == .stagedCopyIncomplete)
    }

    @Test(arguments: ["disk2", "/dev/rdisk2", "/dev/disk2;x", "/dev/disk", 1] as [PropertyListValue])
    func aDeviceThatCanNotBeIdentifiedRefuses(device: PropertyListValue) {
        var transfer = transfer
        transfer["MediaDevice"] = device
        #expect(copyRefusal(transfer) == .supportDiscDeviceUnknown)
    }
}

@Suite struct UnmountTests {
    @Test func evidenceKeepsStatusAndTextOnly() throws {
        let evidence = GuestPreparationChecks.unmountEvidence(
            GuestCommandResult(values: [
                "exitcode": 1, "signal": 9, "stdout": .data(Data()), "stderr": .data(Data("busy".utf8)), "other": "x"
            ]))
        #expect(evidence == ["exitcode": 1, "signal": 9, "stderr": "busy"])
    }

    /// Odd, and kept: the cut is on bytes, so output with a character across 8 KB is recorded as non-text.
    @Test func a8KBCutThroughACharacterReadsAsNonText() {
        let split = Data(repeating: 0x61, count: 8191) + Data("é".utf8)
        let evidence = GuestPreparationChecks.unmountEvidence(GuestCommandResult(values: ["stderr": .data(split)]))
        #expect(evidence["stderr"] == "Non-text disk unmount response")
        let long = Data(repeating: 0x61, count: 9000)
        let cut = GuestPreparationChecks.unmountEvidence(GuestCommandResult(values: ["stdout": .data(long)]))
        #expect(cut["stdout"]?.string?.utf8.count == 8192)
    }

    @Test func theLoginWindowGetsItsOwnAdvice() throws {
        let held = try command(stderr: "held by loginwindow", exitcode: 1)
        #expect(
            refusal { () throws(GuestPreparationError) in try GuestPreparationChecks.verifyUnmount(held) }
                == .supportDiscHeldByLoginWindow)
        let busy = try command(stderr: "busy", exitcode: 1)
        #expect(
            refusal { () throws(GuestPreparationError) in try GuestPreparationChecks.verifyUnmount(busy) }
                == .supportDiscInUse)
        try GuestPreparationChecks.verifyUnmount(try command())
    }
}

@Suite struct GuestToolChecksTests {
    private func environment(_ json: String, stderr: String? = nil) throws -> GuestPreparationError? {
        let result = try command(json: json, stderr: stderr)
        return refusal { () throws(GuestPreparationError) in try checks.verifyEnvironment(result) }
    }

    @Test func theEnvironmentMustBeEligibleAndTheSameSystem() throws {
        #expect(try environment(#"{"Eligible":true,"VolumeUUID":"volume","ProductBuildVersion":"18G103"}"#) == nil)
        #expect(
            try environment(#"{"Eligible":false,"VolumeUUID":"volume","ProductBuildVersion":"18G103"}"#, stderr: "why")
                == .environmentNotEligible(diagnostic: "why"))
        #expect(
            try environment(#"{"Eligible":true,"VolumeUUID":"other","ProductBuildVersion":"18G103"}"#)
                == .environmentNotEligible(diagnostic: nil))
        #expect(
            try environment(#"{"Eligible":true,"VolumeUUID":"volume"}"#) == .environmentNotEligible(diagnostic: nil))
    }

    private func extraction(_ receipt: String, payload: String) throws -> GuestPreparationError? {
        let result = try command(json: receipt)
        return refusal { () throws(GuestPreparationError) in
            try GuestPreparationChecks.verifyExtraction(result, payload: payload)
        }
    }

    private func receipt(directory: String, installed: String = "false") -> String {
        #"{"Extracted":true,"Installed":\#(installed),"PayloadDirectory":"\#(directory)"}"#
    }

    @Test func extractionAcceptsTheExactPathOrOnlyTheKnownPrivateAlias() throws {
        let tmp = "/private/var/tmp/VirtualIntelMac.1/Extracted/payload"
        let db = "/private/var/db/VirtualIntelMac.1/Extracted/payload"
        #expect(try extraction(receipt(directory: tmp), payload: tmp) == nil)
        #expect(try extraction(receipt(directory: "/var/tmp/VirtualIntelMac.1/Extracted/payload"), payload: tmp) == nil)
        #expect(try extraction(receipt(directory: "/var/db/VirtualIntelMac.1/Extracted/payload"), payload: db) == nil)
        #expect(try extraction(receipt(directory: "/tmp/VirtualIntelMac.1/payload"), payload: tmp) == .extractionFailed)
        let other = "/private/tmp/VirtualIntelMac.1/payload"
        #expect(
            try extraction(receipt(directory: "/tmp/VirtualIntelMac.1/payload"), payload: other) == .extractionFailed)
    }

    @Test func extractionThatClaimsAnInstallRefuses() throws {
        let tmp = "/private/var/tmp/VirtualIntelMac.1/payload"
        #expect(try extraction(receipt(directory: tmp, installed: "true"), payload: tmp) == .extractionFailed)
        #expect(try extraction(#"{"Extracted":true,"PayloadDirectory":"\#(tmp)"}"#, payload: tmp) == .extractionFailed)
    }

    @Test func preparedFilesMustBeForThisGuestAndBuild() throws {
        let good = try command(
            json: #"{"Prepared":true,"Installed":false,"Guest":"mojave","ProductBuildVersion":"18G103"}"#)
        try checks.verifyPreparedFiles(good)
        for json in [
            #"{"Prepared":true,"Installed":true,"Guest":"mojave","ProductBuildVersion":"18G103"}"#,
            #"{"Prepared":true,"Installed":false,"Guest":"catalina","ProductBuildVersion":"18G103"}"#,
            #"{"Prepared":true,"Installed":false,"Guest":"mojave","ProductBuildVersion":"other"}"#,
            #"{"Installed":false,"Guest":"mojave","ProductBuildVersion":"18G103"}"#
        ] {
            let bad = try command(json: json)
            #expect(
                refusal { () throws(GuestPreparationError) in try checks.verifyPreparedFiles(bad) }
                    == .filePreparationFailed)
        }
    }

    @Test func aLaterReportMustBeTheSameLiveSystem() throws {
        try checks.verifyUnchanged(report)
        // A desktop isn't required any more: only the identity has to hold.
        try checks.verifyUnchanged(report.setting("DesktopRunning", false).setting("InstalledSystemCandidate", nil))
        for changed in [
            report.setting("LiveRoot", false), report.setting("KernelMatchesSystem", nil),
            report.setting("VolumeUUID", "other"), report.setting("ProductBuildVersion", "other")
        ] {
            #expect(
                refusal { () throws(GuestPreparationError) in try checks.verifyUnchanged(changed) } == .guestChanged)
        }
    }

    @Test func aPlanInstallsNothingYet() throws {
        try checks.verifyPlan(try command(json: #"{"Planned":true,"Installed":false,"Ready":false,"Guest":"mojave"}"#))
        for json in [
            #"{"Planned":true,"Installed":true,"Ready":false,"Guest":"mojave"}"#,
            #"{"Planned":true,"Installed":false,"Ready":true,"Guest":"mojave"}"#,
            #"{"Planned":true,"Installed":false,"Guest":"mojave"}"#,
            #"{"Planned":true,"Installed":false,"Ready":false,"Guest":"catalina"}"#
        ] {
            let bad = try command(json: json)
            #expect(refusal { () throws(GuestPreparationError) in try checks.verifyPlan(bad) } == .planningFailed)
        }
    }

    @Test func aTransactionNeedsAUUID() throws {
        try GuestPreparationChecks.verifyTransaction(["TransactionID": "00112233-4455-6677-8899-AABBCCDDEEFF"])
        for plan: [String: PropertyListValue] in [["TransactionID": "not-a-uuid"], ["TransactionID": 1], [:]] {
            #expect(
                refusal { () throws(GuestPreparationError) in try GuestPreparationChecks.verifyTransaction(plan) }
                    == .planHasNoTransaction)
        }
    }
}

@Suite struct GuestPreparationErrorTests {
    @Test func aRefusalKeepsItsDomainAndMessageForTheApp() {
        let error = GuestPreparationError.utilitiesNotPrepared as NSError
        #expect(error.domain == "VirtualIntelMac.GuestPreparation")
        #expect(error.code == 1)
        #expect(error.localizedDescription == "Could not prepare guest utilities.")
    }

    @Test func aLogIsTextOrItsFallbackOrNothing() throws {
        #expect(try command(stderr: "text").log(nonText: "fallback") == "text")
        #expect(try command().log(nonText: "fallback") == nil)
        let binary = GuestCommandResult(values: ["stderr": .data(Data([0xFF]))])
        #expect(binary.log(nonText: "fallback") == "fallback")
        #expect(binary.log(nonText: nil) == nil)
    }
}
