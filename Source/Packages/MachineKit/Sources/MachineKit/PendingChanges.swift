import Foundation

/// State/PendingConfiguration.plist: edits staged while the machine may be running, published only once it's stopped.
public struct PendingChanges: Sendable {
    public var values: [String: PropertyListValue]

    public init(values: [String: PropertyListValue]) {
        self.values = values
    }

    /// The settings a user may change. Everything else in Machine.plist, such as `Disk` and `InstallerMedia`, can never
    /// be redirected through a pending edit.
    public static let editableKeys: Set<String> = Set(
        [
            MachineConfiguration.Key.cpuCount, .memoryMiB, .sshEnabled, .sshPort, .fileSharingEnabled, .fileSharingPort,
            .audioEnabled, .description, .retinaEnabled, .opticalMedia, .networkConnected, .macAddress, .displayMode,
            .audioOutputDevice, .audioInputDevice, .clipboardEnabled, .networkMode, .bridgeInterface,
            .displayScalingFilter, .additionalMedia, .screenSharingEnabled, .screenSharingPort, .executionEngine,
            .meltdownProtection
        ].map(\.rawValue))

    public var settings: [String: PropertyListValue]? { values["Settings"]?.dictionary }

    /// The rename the file asks for, if it's a valid name.
    public var requestedName: String? {
        guard let name = values["RequestedBundleName"]?.string, PackageNaming.isValid(name) else { return nil }
        return name
    }

    /// The configuration a settings window shows: the queued edits it can apply, if the result is valid, and otherwise
    /// the launch snapshot.
    public func editable(from configuration: MachineConfiguration) -> MachineConfiguration {
        var result = configuration
        for (key, value) in settings ?? [:] where Self.editableKeys.contains(key) {
            result.values[key] = value
        }
        return result.hasValidSettings ? result : configuration
    }

    /// The configuration to publish. Unlike `editable(from:)`, an unsupported key refuses the whole file.
    public func applied(to configuration: MachineConfiguration) throws(MachineConfigurationError)
        -> MachineConfiguration
    {
        var result = configuration
        if let settings {
            guard settings.keys.allSatisfy(Self.editableKeys.contains) else { throw .queuedUnsupportedSetting }
            result.values.merge(settings) { $1 }
        }
        guard result.hasValidSettings else { throw .invalidSettings }
        return result
    }

    /// The name to move the package to, or nil to leave it. A legacy package named by UUID migrates to its `Name`, and
    /// the raw request is what's checked, so a malformed one never falls back to `Name`.
    public func destinationName(packageStem: String, configuration: MachineConfiguration) -> String? {
        let requested: PropertyListValue?
        if let request = values["RequestedBundleName"] {
            requested = request
        } else if UUID(uuidString: packageStem) != nil, let name = configuration.name {
            requested = .string(name)
        } else {
            requested = nil
        }
        guard let name = requested?.string, PackageNaming.isValid(name), !requested.isEqual(.string(packageStem)) else {
            return nil
        }
        return name
    }
}

extension MachineConfiguration {
    /// A migrated configuration: the package's filename holds the name, so `Name` isn't written back.
    public func removingLegacyName() -> MachineConfiguration {
        var result = self
        result[.name] = nil
        return result
    }

    /// Fills the local forwarding defaults on a stopped legacy machine: both on, unless opted out, with ports from
    /// `suggestedPorts` only where none is assigned. Nil if a needed port couldn't be found, shown by one below 1024.
    public func withNetworkDefaults(suggestedPorts: () -> (ssh: Int, fileSharing: Int)) -> MachineConfiguration? {
        var result = self
        if result[.sshEnabled] == nil { result[.sshEnabled] = true }
        if result[.fileSharingEnabled] == nil { result[.fileSharingEnabled] = true }
        if result[.sshPort] != nil && result[.fileSharingPort] != nil { return result }
        let ports = suggestedPorts()
        if result[.sshPort] == nil {
            guard ports.ssh >= 1024 else { return nil }
            result.sshPort = ports.ssh
        }
        if result[.fileSharingPort] == nil {
            guard ports.fileSharing >= 1024 else { return nil }
            result.fileSharingPort = ports.fileSharing
        }
        return result
    }

    // MARK: Install state transitions

    private mutating func detachInstaller(keepingSharedFlag: Bool = false) {
        self[.installerMedia] = nil
        self[.installerMediaKind] = nil
        if !keepingSharedFlag { self[.installerMediaShared] = nil }
    }

    /// Classic setup's first-login restart: installer routing is retired before the orderly restart.
    public func restartingForOpenGLSetup() -> MachineConfiguration {
        var result = self
        result.detachInstaller()
        result.installState = .patching
        return result
    }

    /// Classic setup verified on a boot without its installer. It's refused while one is attached.
    public func finishingOpenGLSetup() throws(MachineConfigurationError) -> MachineConfiguration {
        guard self[.installerMedia] == nil else { throw .installerStillAttached }
        var result = self
        result.installState = .installed
        return result
    }

    /// A verified installation from shared media, which is detached and never treated as this machine's to delete.
    public func finishingWithSharedInstaller() -> MachineConfiguration {
        var result = self
        result.detachInstaller()
        result.installState = .installed
        return result
    }

    /// A verified installation from owned media. Persisted before the media is deleted, so a crash can leave surplus
    /// media but never a dangling boot reference.
    public func finishingWithOwnedInstaller() -> MachineConfiguration {
        var result = self
        result.detachInstaller(keepingSharedFlag: true)
        result.installState = .installed
        return result
    }
}
