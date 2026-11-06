import Foundation

/// Why a graphics installation or a check of one stopped. The messages are shown to the user.
public enum GuestInstallationError: Error, Equatable, LocalizedError, CustomNSError {
    case invalidRecord
    case notAtStoppingPoint
    case notAtStoppingPointRecordsKept
    case recordChanged
    case outcomeUnconfirmed
    case recordedPhase(String)
    case verificationIncomplete(diagnostic: String?)
    case noPreparedTransaction
    case incomplete(failure: String?)

    public static var errorDomain: String { "VirtualIntelMac.Installation" }
    public var errorCode: Int { 1 }

    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "The saved installation record is invalid. No guest command was sent."
        case .notAtStoppingPoint:
            "The previous installation has not reached a recoverable stopping point. No repair was started."
        case .notAtStoppingPointRecordsKept:
            "The previous installation has not reached a recoverable stopping point. Its records were kept; no repair "
                + "was started."
        case .recordChanged: "The installation record changed while checking it. No repair was started."
        case .outcomeUnconfirmed: "Cannot confirm the saved guest transaction. Installation was not retried."
        case .recordedPhase(let phase):
            "Graphics installation is recorded as “\(phase)”. Its recovery information has been kept; installation was "
                + "not repeated."
        case .verificationIncomplete(let diagnostic?):
            "Graphics verification couldn’t finish: \(diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)). The "
                + "installer has been kept."
        case .verificationIncomplete(nil):
            "Graphics verification couldn’t finish. The installer has been kept; you can check again after the desktop "
                + "is ready."
        case .noPreparedTransaction: "No valid prepared installation transaction is available."
        case .incomplete(let failure):
            failure ?? "Installation is not complete. Its saved state must be checked before retrying."
        }
    }
}

/// Runs one process in the guest. A thrown error means no answer, so the process may still have done its work.
@MainActor
public protocol GuestCommandRunning {
    func run(_ path: String, arguments: [String], timeout: TimeInterval) async throws -> GuestCommandResult
}

/// One graphics installation transaction: the guest's `guest-install` tool, and the host's journal of what it said.
/// Nothing here repeats an uncertain write, restarts the guest or marks a machine ready.
@MainActor
public struct GuestInstallationTransaction {
    /// What the guest's tool last said, and what went wrong if anything did. Either can come without the other.
    public struct Outcome {
        public var result: [String: PropertyListValue]?
        public var failure: (any Error)?

        public init(result: [String: PropertyListValue]?, failure: (any Error)?) {
            self.result = result
            self.failure = failure
        }
    }

    let runner: any GuestCommandRunning
    let journal: URL

    public init(runner: any GuestCommandRunning, journal: URL) {
        self.runner = runner
        self.journal = journal
    }

    private typealias Record = [String: PropertyListValue]

    private func isJournalPath(_ value: PropertyListValue?) -> Bool {
        guard let path = value?.string,
            path.hasPrefix("/private/var/tmp/VirtualIntelMac.") || path.hasPrefix("/private/var/db/VirtualIntelMac.")
        else { return false }
        let components = (path as NSString).pathComponents
        return components.count == 6 && !components.contains("..") && !components.contains(".")
            && (path as NSString).lastPathComponent == "InstallTransaction.plist"
    }

    private func installTool(beside guestJournal: String) -> String {
        ((guestJournal as NSString).deletingLastPathComponent as NSString).appendingPathComponent("guest-install")
    }

    private func save(_ record: Record, options: Data.WritingOptions = .atomic) throws {
        let object = record.mapValues(\.foundationObject)
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        try data.write(to: journal, options: options)
    }

    private func isSuperseded(_ record: Record?, by report: GuestReport?) -> Bool {
        guard let record, let report else { return false }
        return GuestInstallationJournal(values: record).isSuperseded(by: report)
    }

    /// A newer read-only verifier, if a migration left one. Early ones only recognize the blanket AMFI bypass, and a
    /// preference-first migration brings its own without replacing the old journal or tools.
    private func currentVerifier(volume: PropertyListValue?) -> String? {
        let package = journal.deletingLastPathComponent().deletingLastPathComponent()
        let configuration = Self.record(at: package.appendingPathComponent("Machine.plist"))
        return GuestBootPolicyRecord.verifier(
            at: package.appendingPathComponent("State/BootPolicy.plist"), guest: configuration["Guest"],
            identifier: configuration["Identifier"], volume: volume)
    }

    private func isAtStoppingPoint(_ result: Record?) -> Bool {
        let installed =
            result["Phase"].isEqual("awaiting-reboot") && result["FilesPublished"].isTrue
            && result["RebootRequired"].isTrue
        return installed || result["Phase"].isEqual("rolled-back")
    }

    /// Checks the last outcome without retiring its evidence, while new files are only being prepared. A verified
    /// installation an update superseded passes with no command, since the update may have removed its verifier.
    public func checkForRepair(updatedSystem report: GuestReport?) async throws {
        if isSuperseded(Self.record(at: journal), by: report) { return }
        let outcome = await reconcile(verifyAfterReboot: false)
        if let failure = outcome.failure { throw failure }
        if !isAtStoppingPoint(outcome.result) { throw GuestInstallationError.notAtStoppingPoint }
    }

    /// Confirms a terminal outcome, then moves the whole host record into history. Guest files and receipts stay.
    public func archiveForRepair(updatedSystem report: GuestReport?) async throws {
        let prior = Self.record(at: journal)
        let superseded = isSuperseded(prior, by: report)
        var result = prior["GuestResult"]?.dictionary
        // All the original proof and errors go to history. A superseded record isn't checked again: that would invent a
        // status or run an old tool that's gone.
        if !superseded {
            let outcome = await reconcile(verifyAfterReboot: false)
            if let failure = outcome.failure { throw failure }
            result = outcome.result
        }
        if !isAtStoppingPoint(result) { throw GuestInstallationError.notAtStoppingPointRecordsKept }
        let record = Self.record(at: journal)
        let identity = result["TransactionID"]
        guard record["TransactionID"].isEqual(identity), !superseded || isSuperseded(record, by: report),
            let name = identity?.string
        else { throw GuestInstallationError.recordChanged }
        let history = journal.deletingLastPathComponent().appendingPathComponent(
            "InstallationHistory", isDirectory: true)
        let files = FileManager.default
        var destination = history.appendingPathComponent(name).appendingPathExtension("plist")
        // A recovered record can be checked again after staging failed. Each observation stays.
        if files.fileExists(atPath: destination.path) {
            destination = history.appendingPathComponent("\(name)-\(UUID().uuidString)").appendingPathExtension("plist")
        }
        try files.createDirectory(at: history, withIntermediateDirectories: true)
        try files.moveItem(at: journal, to: destination)
    }

    /// Reads the existing transaction, and optionally verifies it after a restart.
    public func reconcile(verifyAfterReboot verify: Bool) async -> Outcome {
        guard var state = Self.record(at: journal), let path = state["GuestJournal"]?.string,
            state["FormatVersion"].isEqual(1), state["TransactionID"].isUUID, isJournalPath(state["GuestJournal"]),
            state["Preparation"].isDictionary,
            state["Preparation"]["TransactionID"].isEqual(state["TransactionID"]),
            state["Preparation"]["TransactionJournal"].isEqual(state["GuestJournal"])
        else { return Outcome(result: nil, failure: GuestInstallationError.invalidRecord) }
        let identity = state["TransactionID"]
        let binary = installTool(beside: path)
        // Old evidence is kept apart, never shown as a fresh check when the guest can't be reached or has changed.
        if let verification = state["PostBootVerification"] { state["PreviousPostBootVerification"] = verification }
        state["PostBootVerification"] = nil
        state["Phase"] = "reconciling"

        func finish(_ result: Record?, _ failure: (any Error)?) -> Outcome {
            state["Ready"] = false
            state["UpdatedAt"] = .date(Date())
            state["ReconciliationError"] = failure.map { .string($0.localizedDescription) }
            do {
                try save(state)
            } catch {
                return Outcome(result: nil, failure: error)
            }
            return Outcome(result: result, failure: failure)
        }

        var status: GuestCommandResult?
        var transportFailure: (any Error)?
        do {
            status = try await runner.run(binary, arguments: ["--status", path], timeout: 30)
        } catch {
            transportFailure = error
        }
        guard let result = status?.json, result["TransactionID"].isEqual(identity) else {
            state["Phase"] = "outcome-unknown"
            if let exit = status?.values["exitcode"] { state["ReconciliationExitCode"] = exit }
            if let status, !status.standardError.isEmpty {
                state["ReconciliationLog"] = .string(
                    GuestCommandResult.text(status.standardError) ?? "Non-text guest output")
            }
            return finish(nil, transportFailure ?? GuestInstallationError.outcomeUnconfirmed)
        }
        state["GuestResult"] = .dictionary(result)
        state["Phase"] = result["Phase"] ?? "outcome-unknown"
        guard verify else { return finish(result, nil) }
        guard result["Phase"].isEqual("awaiting-reboot"), result["RebootRequired"].isTrue else {
            let phase = result["Phase"]?.foundationObject.description ?? "unknown"
            return finish(result, GuestInstallationError.recordedPhase(phase))
        }

        var reply: GuestCommandResult?
        var verifyFailure: (any Error)?
        do {
            reply = try await runner.run(
                currentVerifier(volume: result["VolumeUUID"]) ?? binary, arguments: ["--verify-after-reboot", path],
                timeout: 120)
        } catch {
            verifyFailure = error
        }
        let diagnostic = reply?.diagnostic
        if let diagnostic { state["VerificationLog"] = .string(diagnostic) }
        if let exit = reply?.values["exitcode"] { state["VerificationExitCode"] = exit }
        let evidence = reply?.json
        guard let evidence, evidence["TransactionID"].isEqual(identity), evidence["VerifiedAfterReboot"].isTrue,
            evidence["MetalCommandVerified"].isTrue,
            evidence["ProductBuildVersion"].isEqual(result["ProductBuildVersion"]),
            evidence["VolumeUUID"].isEqual(result["VolumeUUID"]), evidence["BootSessionUUID"].nonEmptyString != nil,
            !evidence["BootSessionUUID"].isEqual(result["BootSessionUUID"])
        else {
            return finish(
                result, verifyFailure ?? GuestInstallationError.verificationIncomplete(diagnostic: diagnostic))
        }
        state["PostBootVerification"] = .dictionary(evidence)
        state["Phase"] = "graphics-verified"
        return finish(evidence, nil)
    }

    /// Dispatches a prepared transaction, once. Creating the journal is what makes it once: a second try finds the
    /// journal and has to reconcile it. An uncertain outcome needs a status check and is never applied again.
    public func apply(preparation prepared: [String: PropertyListValue]) async -> Outcome {
        guard prepared["Prepared"].isTrue, prepared["Planned"].isTrue, prepared["Installed"].isFalse,
            prepared["TransactionID"].isUUID, isJournalPath(prepared["TransactionJournal"]),
            let guestJournal = prepared["TransactionJournal"]?.string, let identity = prepared["TransactionID"]
        else { return Outcome(result: nil, failure: GuestInstallationError.noPreparedTransaction) }
        var state: Record = [
            "FormatVersion": 1,
            "TransactionID": identity,
            "GuestJournal": .string(guestJournal),
            "Preparation": .dictionary(prepared),
            "Phase": "dispatching",
            "Ready": false,
            "StartedAt": .date(Date())
        ]
        do {
            try save(state, options: .withoutOverwriting)
        } catch {
            return Outcome(result: nil, failure: error)
        }
        let binary = installTool(beside: guestJournal)
        var arguments = ["--apply", guestJournal]
        if let progress = prepared["GuestProgress"]["Directory"]?.string { arguments += ["--progress", progress] }
        // No timeout, since a slow TCG host shouldn't abandon a healthy install. The guest records progress durably.
        var commandFailure: (any Error)?
        do {
            let command = try await runner.run(binary, arguments: arguments, timeout: 0)
            if !command.standardError.isEmpty {
                state["CommandLog"] = .string(GuestCommandResult.text(command.standardError) ?? "Non-text guest output")
            }
        } catch {
            commandFailure = error
            state["CommandError"] = .string(error.localizedDescription)
        }
        // Even a nonzero exit or a lost reply can have a finished rollback or a running operation behind it, so the
        // guest's durable result decides.
        var status: GuestCommandResult?
        var statusFailure: (any Error)?
        do {
            status = try await runner.run(binary, arguments: ["--status", guestJournal], timeout: 30)
        } catch {
            statusFailure = error
        }
        var result = status?.json
        if !result["TransactionID"].isEqual(identity) { result = nil }
        state["Phase"] = result["Phase"] ?? "outcome-unknown"
        if let result { state["GuestResult"] = .dictionary(result) }
        state["UpdatedAt"] = .date(Date())
        do {
            try save(state)
        } catch {
            return Outcome(result: nil, failure: error)
        }
        if result["Phase"].isEqual("awaiting-reboot"), result["RebootRequired"].isTrue {
            return Outcome(result: result, failure: nil)
        }
        return Outcome(
            result: result,
            failure: statusFailure ?? commandFailure
                ?? GuestInstallationError.incomplete(failure: result["Failure"]?.string))
    }

    /// The journal at `url` as a dictionary, or nil for anything else. Missing keys and wrong types are the caller's.
    public nonisolated static func record(at url: URL) -> [String: PropertyListValue]? {
        guard let data = try? Data(contentsOf: url),
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary.mapValues(PropertyListValue.init(foundationObject:))
    }
}

extension [String: PropertyListValue]? {
    subscript(key: String) -> PropertyListValue? { self?[key] }
}
