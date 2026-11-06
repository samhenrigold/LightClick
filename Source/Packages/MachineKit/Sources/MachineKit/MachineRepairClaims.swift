import Foundation

/// The once-only claims that authorize writing graphics files into a guest. Each is a file that can only be created once,
/// so a lost reply or a crash can never turn into a second attempt.
public struct MachineRepairClaims {
    private let package: URL
    private let configuration: MachineConfiguration

    public init(package: URL, configuration: MachineConfiguration) {
        self.package = package
        self.configuration = configuration
    }

    private func file(_ relative: String) -> URL { package.appendingPathComponent(relative) }

    private func binary(_ values: [String: PropertyListValue]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: values.mapValues(\.foundationObject), format: .binary, options: 0)
    }

    /// The initial attempt for a Mac this app created. False, with no error, when it's ineligible or already attempted.
    public func claimAutomaticInstallation(report: GuestReport) throws -> Bool {
        guard report.admitsAutomaticInstallation(on: configuration) else { return false }
        for name in ["GuestPreparation.plist", "GuestInstallation.plist", "AutomaticInstallation.plist"]
        where FileManager.default.fileExists(atPath: file("State/" + name).path) {
            return false
        }
        let owner = GuestInstallationTransaction.record(at: file("Installation/Ownership.plist")) ?? [:]
        guard InstallerOwnership(values: owner).admitsClaim(by: configuration) else { return false }
        let claim: [String: PropertyListValue] = [
            "FormatVersion": 1,
            "MachineIdentifier": configuration[.identifier] ?? .null,
            "Phase": "claimed",
            "GuestReport": .dictionary(report.values),
            "StartedAt": .date(Date())
        ]
        try binary(claim).write(to: file("State/AutomaticInstallation.plist"), options: .withoutOverwriting)
        return true
    }

    /// Whether an update may be repaired, and with `claim`, claims this build's one automatic attempt. Unlike the initial
    /// installation, it needs no Finder: an update may have replaced the very driver WindowServer needs. A failed read of
    /// a completed old-build transaction can pass, since its proof, ID, disk and build must all agree. An unverified or
    /// interrupted new write never does.
    public func authorizeUpdateRepair(report: GuestReport, claim: Bool) throws -> Bool {
        guard report.admitsUpdateRepair(guest: configuration.guest) else { return false }
        var locks = FileLocks()
        guard locks.acquire(file("State/Configuration.lock")) else {
            throw MachinePackageIssue("This Mac’s settings are being saved. Please try again.")
        }
        defer { locks.release() }
        let state = GuestInstallationTransaction.record(at: file("State/GuestInstallation.plist")) ?? [:]
        guard GuestInstallationJournal(values: state).isSuperseded(by: report) else { return false }
        guard claim else { return true }
        return try writeRepairClaim(report: report, state: state)
    }

    private func writeRepairClaim(report: GuestReport, state: [String: PropertyListValue]) throws -> Bool {
        let directory = file("State/UpdateRepairs")
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw MachinePackageIssue(
                "The macOS update’s graphics setup record could not be saved. Make sure the library drive is connected and writable, then restart the virtual Mac."
            )
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw MachinePackageIssue(
                "The macOS update repair records folder is not a regular folder. No automatic repair was started.")
        }
        let verified = state["PostBootVerification"] ?? state["PreviousPostBootVerification"]
        let build = report["ProductBuildVersion"]?.string ?? ""
        let claimFile = directory.appendingPathComponent(build).appendingPathExtension("plist")
        let record: [String: PropertyListValue] = [
            "FormatVersion": 1,
            "MachineIdentifier": configuration[.identifier] ?? .null,
            "Phase": "claimed",
            "PreviousTransactionID": state["TransactionID"] ?? .null,
            "PreviousBuild": verified["ProductBuildVersion"] ?? .null,
            "GuestReport": .dictionary(report.values),
            "StartedAt": .date(Date())
        ]
        do {
            try binary(record).write(to: claimFile, options: .withoutOverwriting)
            return true
        } catch CocoaError.fileWriteFileExists {
            return try recoverRepairClaim(claimFile, report: report, state: state)
        }
    }

    /// Only a failure before dispatch: the old proven journal is still there with its own ID and a failed read. A
    /// dispatched installation creates a new ID and journal after archiving, so it can't pass. Saving the transition
    /// bounds this to once, even if preparation then fails or the app restarts.
    private func recoverRepairClaim(
        _ claimFile: URL, report: GuestReport, state: [String: PropertyListValue]
    ) throws -> Bool {
        let saved = GuestInstallationTransaction.record(at: claimFile)
        guard
            GuestInstallationJournal(values: state)
                .allowsRepairRecovery(claim: saved, configuration: configuration, report: report),
            var recovery = saved
        else { return false }
        recovery["Phase"] = "preflight-recovered"
        recovery["RecoveredAt"] = .date(Date())
        recovery["RecoveryGuestReport"] = .dictionary(report.values)
        try PropertyListSerialization.data(
            fromPropertyList: recovery.mapValues(\.foundationObject), format: .xml, options: 0
        ).write(to: claimFile, options: .atomic)
        return true
    }
}

public enum MachineDisk {
    /// Configured capacity, not sparse allocation, and zero if it's unknown. A recorded size wins, and otherwise a QCOW2
    /// v2 or v3 header says, read directly so that painting a row launches no tool and touches no disk contents.
    public static func capacity(recordedGiB: Any?, diskPath: Any?, package: URL) -> UInt64 {
        if let recorded = recordedGiB as? NSNumber, recorded.doubleValue > 0, recorded.doubleValue <= 1_048_576 {
            let bytes = UInt64(recorded.doubleValue * Double(1 << 30))
            if bytes != 0 { return bytes }
        }
        guard let path = diskPath as? String, !path.isEmpty else { return 0 }
        let descriptor = open(package.appendingPathComponent(path).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return 0 }
        defer { close(descriptor) }
        var info = stat()
        var header = [UInt8](repeating: 0, count: 32)
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            pread(descriptor, &header, header.count, 0) == header.count
        else { return 0 }
        return qcowVirtualSize(header) ?? 0
    }

    /// The big-endian virtual size at bytes 24 to 31 of a QCOW2 v2 or v3 header.
    static func qcowVirtualSize(_ header: [UInt8]) -> UInt64? {
        guard header.count >= 32, header[0..<4].elementsEqual([0x51, 0x46, 0x49, 0xfb]),
            header[4..<7].allSatisfy({ $0 == 0 }), header[7] == 2 || header[7] == 3
        else { return nil }
        return header[24..<32].reduce(0) { $0 << 8 | UInt64($1) }
    }
}

public enum MovedPackagePreferences {
    /// Everything preferences remember by a package's path, after it moves.
    public static func updatePreferences(_ defaults: UserDefaults, from old: String, to new: String) {
        for key in defaults.dictionaryRepresentation().keys {
            if key.hasPrefix("VIMLibraryOrder-") || key == "VIMRegisteredPackages" {
                guard let paths = defaults.array(forKey: key) as? [String], paths.contains(old) else { continue }
                defaults.set(paths.map { $0 == old ? new : $0 }, forKey: key)
            } else if key.hasPrefix("VIMLibraryKnown-") {
                guard var known = defaults.dictionary(forKey: key), let record = known[old] else { continue }
                known[new] = record
                known[old] = nil
                defaults.set(known, forKey: key)
            }
        }
        if var job = defaults.dictionary(forKey: "VIMCreationJob"), job["Machine"] as? String == old {
            job["Machine"] = new
            defaults.set(job, forKey: "VIMCreationJob")
        }
        let oldKey = "VIMGuestUsername-" + old
        if let username = defaults.object(forKey: oldKey) {
            defaults.set(username, forKey: "VIMGuestUsername-" + new)
            defaults.removeObject(forKey: oldKey)
        }
    }
}

extension MachineFilesBridge {
    /// NO with no error means ineligible, which the callers tell apart from a failure.
    private class func answer(_ error: NSErrorPointer, _ body: () throws -> Bool) -> Bool {
        do {
            return try body()
        } catch let failure {
            error?.pointee = failure as NSError
            return false
        }
    }

    private class func claims(_ package: URL, _ configuration: Any?) -> MachineRepairClaims {
        MachineRepairClaims(
            package: package,
            configuration: MachineConfiguration(foundationObject: configuration) ?? MachineConfiguration())
    }

    @objc(claimAutomaticInstallationOfPackage:configuration:report:error:)
    public class func claimAutomaticInstallation(
        package: URL, configuration: Any?, report: Any?, error: NSErrorPointer
    ) -> Bool {
        answer(error) {
            try claims(package, configuration).claimAutomaticInstallation(
                report: GuestReport(foundationObject: report) ?? GuestReport(values: [:]))
        }
    }

    @objc(authorizeUpdateRepairOfPackage:configuration:report:claim:error:)
    public class func authorizeUpdateRepair(
        package: URL, configuration: Any?, report: Any?, claim: Bool, error: NSErrorPointer
    ) -> Bool {
        answer(error) {
            try claims(package, configuration).authorizeUpdateRepair(
                report: GuestReport(foundationObject: report) ?? GuestReport(values: [:]), claim: claim)
        }
    }

    @objc(diskCapacityOfPackage:recordedGiB:disk:)
    public class func diskCapacity(package: URL, recordedGiB: Any?, disk: Any?) -> UInt64 {
        MachineDisk.capacity(recordedGiB: recordedGiB, diskPath: disk, package: package)
    }

    @objc(updatePreferencesForPackageMovedFrom:to:)
    public class func updatePreferences(from old: String, to new: String) {
        MovedPackagePreferences.updatePreferences(.standard, from: old, to: new)
    }
}
