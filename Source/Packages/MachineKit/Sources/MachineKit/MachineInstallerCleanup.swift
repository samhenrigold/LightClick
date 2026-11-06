import Foundation
import InstallerKit

/// Reads a package's Machine.plist and checks it. A package that can't be read says how to get it back.
public func loadMachineConfiguration(package: URL) throws -> [String: Any] {
    let data: Data
    do {
        data = try Data(contentsOf: package.appendingPathComponent("Machine.plist"))
    } catch {
        throw NSError(
            domain: MachinePackageIssue.errorDomain, code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "This Mac isn’t available. Reconnect its drive or locate its current folder.",
                NSUnderlyingErrorKey: error
            ])
    }
    let object = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let configuration = MachineConfiguration(foundationObject: object) else {
        throw MachineConfigurationError.invalidConfiguration
    }
    try configuration.validate(package: package)
    return object as? [String: Any] ?? [:]
}

/// Retires a machine's installer once its installation is proven. Boot routing goes before any media, so a crash can leave
/// surplus media but never a dangling boot reference, and every step can be retried after a restart.
public struct MachineInstallerCleanup {
    private let package: URL
    private let keepInstallers: Bool
    /// The media of a creation job under way, whose folder is never removed.
    private let creatingMedia: String?
    private let removePassword: (String) throws -> Void
    /// Told each configuration as soon as it's saved, whatever happens to the steps after it.
    private let adopt: (MachineConfiguration) -> Void

    public init(
        package: URL, keepInstallers: Bool, creatingMedia: String?, removePassword: @escaping (String) throws -> Void,
        adopt: @escaping (MachineConfiguration) -> Void
    ) {
        self.package = package
        self.keepInstallers = keepInstallers
        self.creatingMedia = creatingMedia
        self.removePassword = removePassword
        self.adopt = adopt
    }

    private func file(_ relative: String) -> URL { package.appendingPathComponent(relative) }
    private func plist(_ relative: String) -> [String: PropertyListValue]? {
        GuestInstallationTransaction.record(at: file(relative))
    }

    private func save(_ values: [String: PropertyListValue], _ relative: String) throws {
        let object = values.mapValues(\.foundationObject)
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            .write(to: file(relative), options: .atomic)
    }

    private func save(_ configuration: MachineConfiguration) throws {
        try save(configuration.values, "Machine.plist")
        adopt(configuration)
    }

    private func fresh() throws -> MachineConfiguration {
        guard let configuration = MachineConfiguration(foundationObject: try loadMachineConfiguration(package: package))
        else { throw MachineConfigurationError.invalidConfiguration }
        return configuration
    }

    private func holdingSessionLock<Result>(refusal: String, _ body: () throws -> Result) throws -> Result {
        var locks = FileLocks()
        guard locks.acquire(file("State/Session.lock")) else { throw MachinePackageIssue(refusal) }
        defer { locks.release() }
        return try body()
    }

    // MARK: Retrying

    /// Repeats only a cleanup that was already authorized, with all its checks. With nothing pending, it succeeds.
    public func retry(configuration: MachineConfiguration, preMetalGuest: Bool) throws {
        if preMetalGuest {
            try retryOpenGL(configuration: configuration)
            return
        }
        let pending = plist("State/Install.plist")
        guard pending["Phase"].isEqual("cleanup-pending") else {
            // Verification is durable and the session's report isn't. This recovers it after a restart, so the installer
            // isn't kept forever once the original session has gone. `finish` checks everything again before acting.
            guard configuration[.installerMedia] != nil,
                plist("State/GuestInstallation.plist")["Phase"].isEqual("graphics-verified")
            else { return }
            guard let report = plist("State/GuestStatus.plist")["Report"]?.dictionary else {
                throw MachinePackageIssue("Saved guest status is unavailable. Installer media was retained.")
            }
            try finish(report: GuestReport(values: report))
            return
        }
        guard pending["Identifier"].isEqual(configuration[.identifier]), let report = pending["GuestReport"]?.dictionary
        else { throw MachinePackageIssue("Saved installer cleanup does not match this Mac. Media was retained.") }
        try finish(report: GuestReport(values: report))
    }

    private func retryOpenGL(configuration: MachineConfiguration) throws {
        let finished = plist("State/Install.plist")
        if finished["Phase"].isEqual("complete"), finished["Identifier"].isEqual(configuration[.identifier]) { return }
        let receipt = plist("State/LegacyGuestInstallation.plist")
        guard receipt["Phase"].isEqual("graphics-verified") else { return }
        // Before a session starts or after QEMU exits, so never with a live optical backend.
        try holdingSessionLock(refusal: "Shut down this Mac before retiring its installer files.") {
            let current = try fresh()
            guard current[.installerMedia] == nil, current.installState == .installed,
                receipt["MachineIdentifier"].isEqual(current[.identifier])
            else { throw MachinePackageIssue("Installer cleanup is not yet authorized for this Mac.") }
            guard let owner = plist("Installation/Ownership.plist") else { return }
            guard owner["MachineIdentifier"].isEqual(current[.identifier]) else {
                throw MachinePackageIssue("Installer ownership changed. Its files were retained.")
            }
            let removed = removePreparedMedia(owner["Media"]?.string)
            if let credential = plist("State/AutomaticSetup.plist")["CredentialIdentifier"]?.string {
                try removePassword(credential)
            }
            try save(
                [
                    "Phase": "complete", "Identifier": current[.identifier] ?? .null, "InstallerDetached": true,
                    "SharedMediaRetained": .number(!removed as NSNumber), "CompletedAt": .date(Date())
                ], "State/Install.plist")
        }
    }

    // MARK: Finishing

    /// Only while stopped, after verification that survived a restart and with a report that matches it.
    public func finish(report: GuestReport) throws {
        try holdingSessionLock(refusal: "Shut down this Mac before finishing installer cleanup.") {
            let current = try fresh()
            let state = plist("State/GuestInstallation.plist")
            guard
                GuestInstallationJournal(values: state ?? [:]).authorizesInstallerCleanup(
                    report: report, guest: current.guest)
            else {
                throw MachinePackageIssue(
                    "Matching completed guest installation and graphics verification are required. Media was retained.")
            }
            let owner = InstallerOwnership(values: plist("Installation/Ownership.plist") ?? [:])
            if current.values["InstallerMediaShared"].isTrue {
                try finishShared(current, owner: owner)
            } else {
                try finishOwned(
                    current, owner: owner, report: report, transaction: state["PostBootVerification"]["TransactionID"])
            }
        }
    }

    /// Shared library media belongs to the download cache, so this detaches it and never deletes another's ISO.
    private func finishShared(_ current: MachineConfiguration, owner: InstallerOwnership) throws {
        guard owner.names(current) else { throw MachinePackageIssue("Installer reference does not match its record.") }
        let configuration = current.finishingWithSharedInstaller()
        try save(configuration)
        let removed = removePreparedMedia(current[.installerMedia]?.string)
        try save(
            [
                "Phase": "complete", "Identifier": configuration[.identifier] ?? .null, "InstallerDetached": true,
                "SharedMediaRetained": .number(!removed as NSNumber), "CompletedAt": .date(Date())
            ], "State/Install.plist")
    }

    private func finishOwned(
        _ current: MachineConfiguration, owner: InstallerOwnership, report: GuestReport, transaction: PropertyListValue?
    ) throws {
        guard owner.admitsOwnedCleanup(by: current) else {
            throw MachinePackageIssue("Installer ownership could not be established. Media was retained.")
        }
        let media = file("Installation/Installer.iso")
        // A relocated Installation folder is never followed, and a linked file is never deleted.
        guard media.resolvingSymlinksInPath().path == media.path else {
            throw MachinePackageIssue("Installer media has been relocated. Automatic cleanup is unavailable.")
        }
        var info = stat()
        let exists = lstat(media.path, &info) == 0
        if !exists && errno != ENOENT { throw MachinePackageIssue("Cannot inspect installer media.") }
        if exists {
            let size = owner.values["Size"]?.number?.uint64Value
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size > 0, UInt64(info.st_size) == size
            else { throw MachinePackageIssue("Installer media no longer matches its ownership record.") }
        }
        try ensureUnreferenced(media, current: current)
        let configuration = current.finishingWithOwnedInstaller()
        // The validated evidence is saved before routing is retired, so a failed deletion or final save can be retried.
        let transaction = transaction ?? .null
        try save(
            [
                "Phase": "cleanup-pending", "Identifier": configuration[.identifier] ?? .null,
                "TransactionID": transaction, "GuestReport": .dictionary(report.values), "UpdatedAt": .date(Date())
            ], "State/Install.plist")
        try save(configuration)
        if exists && !keepInstallers { try FileManager.default.removeItem(at: media) }
        try save(
            [
                "Phase": "complete", "Identifier": configuration[.identifier] ?? .null, "TransactionID": transaction,
                "InstallerMediaRemoved": .number(!keepInstallers as NSNumber), "CompletedAt": .date(Date())
            ], "State/Install.plist")
    }

    private func ensureUnreferenced(_ media: URL, current: MachineConfiguration) throws {
        for key in ["BootMedia", "Disk", "Firmware", "NVRAM"] {
            guard let path = current.values[key]?.string else { continue }
            if file(path).resolvingSymlinksInPath().path == media.path {
                throw MachinePackageIssue("Installer media is still used by another device in this Mac.")
            }
        }
        let siblings = try FileManager.default.contentsOfDirectory(
            at: package.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        for sibling in siblings
        where sibling.pathExtension == "vintelmac" && sibling.resolvingSymlinksInPath().path != package.path {
            guard
                let other = GuestInstallationTransaction.record(at: sibling.appendingPathComponent("Machine.plist"))
            else { throw MachinePackageIssue("Another Mac's configuration could not be checked. Media was retained.") }
            for key in ["InstallerMedia", "BootMedia", "Disk", "Firmware", "NVRAM"] {
                guard let path = other[key]?.string else { continue }
                if sibling.appendingPathComponent(path).resolvingSymlinksInPath().path == media.path {
                    throw MachinePackageIssue("Another Mac still references this installer.")
                }
            }
        }
    }

    /// Media the app prepared lives in its own attempt folder and is never reused for another Mac. With its owner
    /// installed, the folder goes unless a job or another Mac in the library still refers to it. True if it went.
    private func removePreparedMedia(_ path: String?) -> Bool {
        guard !keepInstallers, let path, (path as NSString).isAbsolutePath else { return false }
        let media = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let attempt = LibraryLayout.preparedMediaAttempt(media: media, owner: package) else { return false }
        let prefix = attempt.path + "/"
        func isInAttempt(_ other: String?) -> Bool {
            other.map { ($0 as NSString).resolvingSymlinksInPath.hasPrefix(prefix) } ?? false
        }
        if isInAttempt(creatingMedia) { return false }
        let files = FileManager.default
        let siblings =
            (try? files.contentsOfDirectory(at: package.deletingLastPathComponent(), includingPropertiesForKeys: nil))
            ?? []
        for sibling in siblings
        where sibling.pathExtension == "vintelmac"
            && sibling.resolvingSymlinksInPath().path != package.resolvingSymlinksInPath().path
        {
            guard let other = GuestInstallationTransaction.record(at: sibling.appendingPathComponent("Machine.plist"))
            else { return false }
            if isInAttempt(other["InstallerMedia"]?.string) { return false }
        }
        return (try? files.removeItem(at: attempt)) != nil
    }
}

/// The Objective-C face of the cleanup. VIMMachine keeps its selectors and its configuration.
@objc(VIMMachineFiles)
public final class MachineFilesBridge: NSObject {
    @objc(loadConfigurationOfPackage:error:)
    public class func loadConfiguration(package: URL) throws -> NSDictionary {
        try loadMachineConfiguration(package: package) as NSDictionary
    }

    private static func cleanup(
        package: URL, removePassword: @escaping (String) -> NSError?, adopt: @escaping (NSDictionary) -> Void
    ) -> MachineInstallerCleanup {
        let defaults = UserDefaults.standard
        return MachineInstallerCleanup(
            package: package, keepInstallers: defaults.bool(forKey: "VIMKeepInstallers"),
            creatingMedia: defaults.dictionary(forKey: "VIMCreationJob")?["Media"] as? String,
            removePassword: { identifier in
                if let error = removePassword(identifier) { throw error }
            },
            adopt: { adopt($0.foundationObject) })
    }

    @objc(finishInstallerCleanupOfPackage:report:removePassword:adopt:error:)
    public class func finishCleanup(
        package: URL, report: Any?, removePassword: @escaping (String) -> NSError?,
        adopt: @escaping (NSDictionary) -> Void
    ) throws {
        try cleanup(package: package, removePassword: removePassword, adopt: adopt)
            .finish(report: GuestReport(foundationObject: report) ?? GuestReport(values: [:]))
    }

    @objc(retryInstallerCleanupOfPackage:configuration:preMetalGuest:removePassword:adopt:error:)
    public class func retryCleanup(
        package: URL, configuration: Any?, preMetalGuest: Bool, removePassword: @escaping (String) -> NSError?,
        adopt: @escaping (NSDictionary) -> Void
    ) throws {
        try cleanup(package: package, removePassword: removePassword, adopt: adopt).retry(
            configuration: MachineConfiguration(foundationObject: configuration) ?? MachineConfiguration(),
            preMetalGuest: preMetalGuest)
    }
}
