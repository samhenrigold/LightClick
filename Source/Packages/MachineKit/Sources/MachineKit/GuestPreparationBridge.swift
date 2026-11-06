// The Objective-C face of guest preparation's checks. VIMGuestPreparation keeps its class and selector, runs the steps
// and owns the journal. Each `refusal` is nil when a step's outcome is acceptable, so the caller can write
// `transportError ?: [… refusal…]` as it always has. Guest output is untrusted, so parameters are `id`.

import Foundation

private func refused(_ check: () throws -> Void) -> NSError? {
    do {
        try check()
        return nil
    } catch {
        return error as NSError
    }
}

private func checks(_ report: Any?) -> GuestPreparationChecks {
    GuestPreparationChecks(initialReport: GuestReport(foundationObject: report) ?? GuestReport(values: [:]))
}

private func command(_ result: Any?) -> GuestCommandResult {
    GuestCommandResult(foundationObject: result)
}

/// One look at the guest's disk list. `refusal` ends the search, `identifier` found the disc, and neither means look again.
@objc(VIMSupportDiscLookup)
public final class SupportDiscLookupBridge: NSObject {
    @objc public let identifier: String?
    @objc public let refusal: NSError?

    init(identifier: String?, refusal: NSError?) {
        self.identifier = identifier
        self.refusal = refusal
    }
}

@objc(VIMGuestPreparationChecks)
public final class GuestPreparationBridge: NSObject {
    @objc(JSONFromCommand:)
    public class func json(fromCommand result: Any?) -> NSDictionary? {
        command(result).jsonObject as NSDictionary?
    }

    /// Standard error for the journal, or `nonText` if it can't be decoded. Nil if there's none to record.
    @objc(logFromCommand:nonText:)
    public class func log(fromCommand result: Any?, nonText: String?) -> String? {
        let output = command(result).standardError
        return output.isEmpty ? nil : GuestCommandResult.text(output) ?? nonText
    }

    @objc(refusalOfInitialReport:allowingHeadlessRepair:)
    public class func refusal(ofInitialReport report: Any?, allowingHeadlessRepair headless: Bool) -> NSError? {
        refused { try checks(report).verifyInitialReport(allowingHeadlessRepair: headless) }
    }

    // MARK: The support disc

    @objc(supportDiscInDiskList:mayRetry:)
    public class func supportDisc(inDiskList result: Any?, mayRetry: Bool) -> SupportDiscLookupBridge {
        do {
            switch try SupportDisc.lookup(inDiskList: command(result), mayRetry: mayRetry) {
            case .found(let identifier): return SupportDiscLookupBridge(identifier: identifier, refusal: nil)
            case .notPublishedYet: return SupportDiscLookupBridge(identifier: nil, refusal: nil)
            }
        } catch {
            return SupportDiscLookupBridge(identifier: nil, refusal: error as NSError)
        }
    }

    @objc(refusalOfSupportDiscInfo:)
    public class func refusal(ofSupportDiscInfo result: Any?) -> NSError? {
        refused { try SupportDisc.verify(info: command(result)) }
    }

    @objc(refusalOfSupportDiscMount:)
    public class func refusal(ofSupportDiscMount result: Any?) -> NSError? {
        refused { try SupportDisc.verify(mount: command(result)) }
    }

    @objc(unmountEvidenceFromCommand:)
    public class func unmountEvidence(fromCommand result: Any?) -> NSDictionary {
        GuestPreparationChecks.unmountEvidence(command(result)).mapValues(\.foundationObject) as NSDictionary
    }

    @objc(refusalOfUnmount:)
    public class func refusal(ofUnmount result: Any?) -> NSError? {
        refused { try GuestPreparationChecks.verifyUnmount(command(result)) }
    }

    // MARK: Staging

    @objc(refusalOfStaging:directory:)
    public class func refusal(ofStaging result: Any?, directory: String) -> NSError? {
        refused { try GuestPreparationChecks.verifyStaging(command(result), directory: directory) }
    }

    /// `transfer` is the JSON `stage-media` printed.
    @objc(refusalOfStagedCopy:)
    public class func refusal(ofStagedCopy transfer: Any?) -> NSError? {
        refused { try GuestPreparationChecks.verifyStagedCopy(GuestReport(foundationObject: transfer)?.values ?? [:]) }
    }

    // MARK: The guest's tools

    @objc(refusalOfUtilities:)
    public class func refusal(ofUtilities result: Any?) -> NSError? {
        refused { try GuestPreparationChecks.verifyUtilities(command(result)) }
    }

    @objc(refusalOfEnvironment:report:)
    public class func refusal(ofEnvironment result: Any?, report: Any?) -> NSError? {
        refused { try checks(report).verifyEnvironment(command(result)) }
    }

    @objc(refusalOfExtraction:payload:)
    public class func refusal(ofExtraction result: Any?, payload: String) -> NSError? {
        refused { try GuestPreparationChecks.verifyExtraction(command(result), payload: payload) }
    }

    @objc(refusalOfPreparedFiles:report:)
    public class func refusal(ofPreparedFiles result: Any?, report: Any?) -> NSError? {
        refused { try checks(report).verifyPreparedFiles(command(result)) }
    }

    @objc(refusalOfLaterReport:report:)
    public class func refusal(ofLaterReport later: Any?, report: Any?) -> NSError? {
        refused { try checks(report).verifyUnchanged(GuestReport(foundationObject: later) ?? GuestReport(values: [:])) }
    }

    @objc(refusalOfPlan:report:)
    public class func refusal(ofPlan result: Any?, report: Any?) -> NSError? {
        refused { try checks(report).verifyPlan(command(result)) }
    }

    /// `plan` is the JSON `guest-install --plan` printed.
    @objc(refusalOfTransaction:)
    public class func refusal(ofTransaction plan: Any?) -> NSError? {
        refused { try GuestPreparationChecks.verifyTransaction(GuestReport(foundationObject: plan)?.values ?? [:]) }
    }
}
