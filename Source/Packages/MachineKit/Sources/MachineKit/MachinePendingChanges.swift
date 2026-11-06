import Foundation

/// Edits to a package's settings. They're staged apart from the live launch snapshot, and only applied while nothing is
/// using the machine: the session lock decides that, including when another app process owns it.
public struct MachinePendingChanges {
    /// A package's location and configuration, after a change has been saved.
    public typealias Adopt = (_ package: URL, _ configuration: NSDictionary, _ movedFrom: URL?) -> Void

    private let package: URL
    private let configuration: Any?
    private let networkDefaults: ([String: Any], URL, URL) -> [String: Any]?
    private let adopt: Adopt

    public init(
        package: URL, configuration: Any?, networkDefaults: @escaping ([String: Any], URL, URL) -> [String: Any]?,
        adopt: @escaping Adopt
    ) {
        self.package = package
        self.configuration = configuration
        self.networkDefaults = networkDefaults
        self.adopt = adopt
    }

    private var pendingFile: URL { package.appendingPathComponent("State/PendingConfiguration.plist") }

    private func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private func save(_ value: [String: Any], _ url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(
            to: url, options: .atomic)
    }

    private func holdingConfigurationLock<Result>(_ body: () throws -> Result) throws -> Result {
        var locks = FileLocks()
        guard locks.acquire(package.appendingPathComponent("State/Configuration.lock")) else {
            throw MachinePackageIssue("This Mac’s settings are being saved. Please try again.")
        }
        defer { locks.release() }
        return try body()
    }

    public func rename(to name: String) throws {
        guard PackageNaming.isValidRename(name) else {
            throw MachinePackageIssue("Enter a name of 1–128 characters without slashes, colons, or a leading dot.")
        }
        try holdingConfigurationLock {
            var pending = plist(pendingFile) ?? [:]
            pending["RequestedBundleName"] = name
            try save(pending, pendingFile)
        }
        try apply()
    }

    public func saveSettings(_ settings: [String: Any]) throws {
        try holdingConfigurationLock {
            let pending = plist(pendingFile)
            let editable = MachineModelBridge.editable(configuration, pending: pending)
            try MachineModelBridge.validate(settings: settings, editable: editable)
            var updated = pending ?? [:]
            updated["Settings"] = (updated["Settings"] as? [String: Any] ?? [:]).merging(settings) { $1 }
            try save(updated, pendingFile)
        }
        try apply()
    }

    /// Applies queued changes, or migrates a legacy package name, while stopped. A running machine isn't touched, and that
    /// counts as success: the changes wait.
    public func apply() throws {
        let lockPath = package.appendingPathComponent("State/Session.lock").path
        let session = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard session >= 0 else { throw MachinePackageIssue("This Mac’s configuration lock could not be opened.") }
        defer { close(session) }
        var info = stat()
        guard fstat(session, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw MachinePackageIssue("This Mac’s configuration lock could not be opened.")
        }
        if flock(session, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { return }
            throw MachinePackageIssue("This Mac’s configuration lock is unavailable.")
        }
        defer { flock(session, LOCK_UN) }
        try holdingConfigurationLock(applyHoldingLocks)
    }

    private func applyHoldingLocks() throws {
        let fresh = try loadMachineConfiguration(package: package)
        let pending = plist(pendingFile)
        var updated = try MachineModelBridge.applying(fresh, pending: pending) as? [String: Any] ?? [:]
        let library = package.deletingLastPathComponent()
        guard let network = networkDefaults(updated, library, package) else {
            throw MachinePackageIssue(
                "No local connection ports are available. Close unused virtual Macs or network services, then try again."
            )
        }
        updated.merge(network) { $1 }
        let stem = package.deletingPathExtension().lastPathComponent
        let requested = MachineModelBridge.destinationName(packageStem: stem, pending: pending, configuration: updated)
        let destination = requested.map { PackageNaming.newPackageURL(for: $0, in: library) } ?? package
        let moved = destination != package
        let files = FileManager.default
        if moved { try files.moveItem(at: package, to: destination) }
        let needsSave = pending != nil || updated["Name"] != nil || !(updated as NSDictionary).isEqual(to: fresh)
        let result = MachineModelBridge.removingLegacyName(updated)
        if needsSave {
            do {
                try save(result as? [String: Any] ?? [:], destination.appendingPathComponent("Machine.plist"))
            } catch {
                if moved { try? files.moveItem(at: destination, to: package) }
                throw error
            }
        }
        adopt(destination, result, moved ? package : nil)
        if pending != nil {
            try files.removeItem(at: destination.appendingPathComponent("State/PendingConfiguration.plist"))
        }
    }
}

/// A new machine's automatic setup: non-secret policy only, since credentials stay private on the host.
public struct MachineAutomaticSetupPolicy {
    private let package: URL
    private let configuration: MachineConfiguration
    private let supportsGuest: Bool
    private let validateUsername: (Any?) throws -> Void
    private let requireInstallerConfiguration: (Any?) throws -> Void

    public init(
        package: URL, configuration: MachineConfiguration, supportsGuest: Bool,
        validateUsername: @escaping (Any?) throws -> Void,
        requireInstallerConfiguration: @escaping (Any?) throws -> Void
    ) {
        self.package = package
        self.configuration = configuration
        self.supportsGuest = supportsGuest
        self.validateUsername = validateUsername
        self.requireInstallerConfiguration = requireInstallerConfiguration
    }

    private func checkOptions(_ profile: [String: PropertyListValue]) throws -> Set<String> {
        guard supportsGuest, configuration.values["InstallState"].isEqual("installing"),
            profile["FormatVersion"].isEqual(1), profile["Enabled"].isTrue
        else { throw MachinePackageIssue("Automatic setup is only available for a new virtual Mac installation.") }
        var allowed: Set = [
            "FormatVersion", "Enabled", "Username", "FileSharing", "RemoteLogin", "CredentialIdentifier"
        ]
        // An old saved transaction keeps its one-time login. New ones ask for persistent automatic login.
        if profile["AutomaticLogin"] != nil { allowed.insert("AutomaticLogin") }
        guard allowed == Set(profile.keys) else {
            throw MachinePackageIssue("Automatic setup contains an unsupported option.")
        }
        try validateUsername(profile["Username"]?.foundationObject)
        guard profile["CredentialIdentifier"].isUUID else {
            throw MachinePackageIssue("Check the virtual Mac’s account and setup credential.")
        }
        for key in ["FileSharing", "RemoteLogin", "AutomaticLogin"]
        where key != "AutomaticLogin" || allowed.contains(key) {
            let value = profile[key]?.number?.doubleValue
            guard value == 0 || value == 1 else {
                throw MachinePackageIssue("Check the automatic sharing options.")
            }
        }
        return allowed
    }

    /// Before the first boot only. A journal already there is never reset, so an in-progress or finished setup stands.
    public func save(_ profile: [String: PropertyListValue]) throws {
        let allowed = try checkOptions(profile)
        let target = GuestInstallationTransaction.record(
            at: package.appendingPathComponent("State/InstallationTarget.plist"))
        try requireInstallerConfiguration(target["VolumeUUID"]?.foundationObject)
        var locks = FileLocks()
        guard locks.acquire(package.appendingPathComponent("State/Session.lock")) else {
            throw MachinePackageIssue("Stop this virtual Mac before changing its initial setup.")
        }
        defer { locks.release() }
        let journal = package.appendingPathComponent("State/AutomaticSetup.plist")
        if FileManager.default.fileExists(atPath: journal.path) {
            guard let existing = GuestInstallationTransaction.record(at: journal) else {
                throw MachinePackageIssue("The saved automatic setup state could not be read. It was not replaced.")
            }
            for key in allowed where !existing[key].isEqual(profile[key]) {
                throw MachinePackageIssue(
                    "This Mac’s initial account setup has already been saved. Resume that setup before changing it.")
            }
            return
        }
        var state = profile
        state["Guest"] = configuration.values["Guest"]
        state["MachineIdentifier"] = configuration[.identifier]
        state["VolumeUUID"] = target["VolumeUUID"]
        state["Phase"] = "pending"
        try PropertyListSerialization.data(
            fromPropertyList: state.mapValues(\.foundationObject), format: .xml, options: 0
        ).write(to: journal, options: .atomic)
    }
}

extension MachineFilesBridge {
    @objc(renamePackage:configuration:to:networkDefaults:adopt:error:)
    public class func rename(
        package: URL, configuration: Any?, to name: String,
        networkDefaults: @escaping ([String: Any], URL, URL) -> [String: Any]?,
        adopt: @escaping (URL, NSDictionary, URL?) -> Void
    ) throws {
        try MachinePendingChanges(
            package: package, configuration: configuration, networkDefaults: networkDefaults, adopt: adopt
        ).rename(to: name)
    }

    @objc(saveSettings:package:configuration:networkDefaults:adopt:error:)
    public class func saveSettings(
        _ settings: [String: Any], package: URL, configuration: Any?,
        networkDefaults: @escaping ([String: Any], URL, URL) -> [String: Any]?,
        adopt: @escaping (URL, NSDictionary, URL?) -> Void
    ) throws {
        try MachinePendingChanges(
            package: package, configuration: configuration, networkDefaults: networkDefaults, adopt: adopt
        ).saveSettings(settings)
    }

    @objc(applyPendingChangesOfPackage:configuration:networkDefaults:adopt:error:)
    public class func applyPendingChanges(
        package: URL, configuration: Any?, networkDefaults: @escaping ([String: Any], URL, URL) -> [String: Any]?,
        adopt: @escaping (URL, NSDictionary, URL?) -> Void
    ) throws {
        try MachinePendingChanges(
            package: package, configuration: configuration, networkDefaults: networkDefaults, adopt: adopt
        ).apply()
    }

    @objc(saveAutomaticSetup:package:configuration:supportsGuest:checkUsername:checkVolume:error:)
    public class func saveAutomaticSetup(
        _ profile: Any?, package: URL, configuration: Any?, supportsGuest: Bool,
        checkUsername: @escaping (Any?) -> NSError?, checkVolume: @escaping (Any?) -> NSError?
    ) throws {
        guard let profile = profile as? [String: Any] else {
            throw MachinePackageIssue("Automatic setup is only available for a new virtual Mac installation.")
        }
        try MachineAutomaticSetupPolicy(
            package: package,
            configuration: MachineConfiguration(foundationObject: configuration) ?? MachineConfiguration(),
            supportsGuest: supportsGuest,
            validateUsername: { if let error = checkUsername($0) { throw error } },
            requireInstallerConfiguration: { if let error = checkVolume($0) { throw error } }
        ).save(profile.mapValues(PropertyListValue.init(foundationObject:)))
    }
}
