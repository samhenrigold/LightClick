import Foundation
import Testing

@testable import MachineKit

@Suite struct SettingsTests {
    private func valid(_ key: MachineConfiguration.Key, _ value: PropertyListValue?) -> Bool {
        Fixture.configuration.setting(key, value).hasValidSettings
    }

    @Test func theFixtureIsValid() {
        #expect(Fixture.configuration.hasValidSettings)
    }

    @Test func processorsAndMemoryAreBounded() {
        for cpu: PropertyListValue in [1, 64] { #expect(valid(.cpuCount, cpu)) }
        for cpu: PropertyListValue in [0, 65, 128, "4", .number(1.5 as NSNumber)] { #expect(!valid(.cpuCount, cpu)) }
        #expect(!valid(.cpuCount, nil))
        for memory: PropertyListValue in [1024, 1_048_576] { #expect(valid(.memoryMiB, memory)) }
        for memory: PropertyListValue in [1023, 1_048_577, "4096"] { #expect(!valid(.memoryMiB, memory)) }
        #expect(!valid(.memoryMiB, nil))
    }

    @Test func aHugeRealCannotPassAsAWholeNumber() {
        #expect(!valid(.cpuCount, .number(1e30 as NSNumber)))
    }

    @Test func portsAreBoundedAndDistinct() {
        #expect(valid(.sshPort, 1024))
        #expect(valid(.sshPort, 65535))
        #expect(!valid(.sshPort, 1023))
        #expect(!valid(.fileSharingPort, 65536))
        #expect(!valid(.sshPort, "2222"))
        #expect(!valid(.sshEnabled, true))  // no port
        #expect(!valid(.fileSharingEnabled, true))  // no port
        let both = Fixture.configuration.setting(.sshEnabled, true).setting(.fileSharingEnabled, true)
            .setting(.sshPort, 2222)
        #expect(both.setting(.fileSharingPort, 1445).hasValidSettings)
        #expect(!both.setting(.fileSharingPort, 2222).hasValidSettings)
        // Two disabled services may share a stale port.
        #expect(
            Fixture.configuration.setting(.sshEnabled, false).setting(.sshPort, 2222).setting(.fileSharingPort, 2222)
                .hasValidSettings)
    }

    @Test func booleansMayBeNumbersButOnlyZeroOrOne() {
        for key in [
            MachineConfiguration.Key.sshEnabled, .fileSharingEnabled, .audioEnabled, .retinaEnabled, .networkConnected,
            .clipboardEnabled
        ] {
            #expect(valid(key, false))
            #expect(valid(key, 0))
            #expect(!valid(key, 2))
            #expect(!valid(key, "YES"))
        }
        #expect(valid(.audioEnabled, 1))
        #expect(valid(.audioEnabled, true))
    }

    @Test func enumeratedSettingsAreChecked() {
        for mode: PropertyListValue in ["shared", "host", "bridged"] { #expect(valid(.networkMode, mode)) }
        #expect(!valid(.networkMode, "tap"))
        #expect(!valid(.networkMode, 1))
        for mode: PropertyListValue in ["retina", "scaled", "space"] { #expect(valid(.displayMode, mode)) }
        #expect(!valid(.displayMode, "bogus"))
        for filter: PropertyListValue in ["linear", "nearest"] { #expect(valid(.displayScalingFilter, filter)) }
        #expect(!valid(.displayScalingFilter, "cubic"))
        for engine: PropertyListValue in ["off", "on"] { #expect(valid(.executionEngine, engine)) }
        #expect(!valid(.executionEngine, "On"))
        #expect(!valid(.executionEngine, 1))
        for protection: PropertyListValue in ["off", "on"] { #expect(valid(.meltdownProtection, protection)) }
        #expect(!valid(.meltdownProtection, "On"))
        #expect(!valid(.meltdownProtection, 1))
    }

    @Test func textIsBoundedInUTF16Units() {
        #expect(valid(.bridgeInterface, .string(String(repeating: "a", count: 64))))
        #expect(!valid(.bridgeInterface, .string(String(repeating: "a", count: 65))))
        #expect(!valid(.bridgeInterface, 1))
        #expect(valid(.description, .string(String(repeating: "a", count: 4096))))
        #expect(!valid(.description, .string(String(repeating: "a", count: 4097))))
        // One Character, two UTF-16 units: the limit is Foundation's length.
        #expect(!valid(.description, .string(String(repeating: "\u{1F600}", count: 2049))))
        for key in [MachineConfiguration.Key.audioOutputDevice, .audioInputDevice] {
            #expect(valid(key, .string(String(repeating: "a", count: 1024))))
            #expect(!valid(key, .string(String(repeating: "a", count: 1025))))
            #expect(!valid(key, 1))
        }
    }

    @Test func mediaPathsMustBeEmptyOrAbsolute() {
        #expect(valid(.opticalMedia, ""))
        #expect(valid(.opticalMedia, "/Volumes/a.iso"))
        #expect(!valid(.opticalMedia, "a.iso"))
        #expect(!valid(.opticalMedia, 1))
        #expect(valid(.additionalMedia, ["", "/a.dmg"]))
        #expect(!valid(.additionalMedia, ["a.dmg"]))
        #expect(!valid(.additionalMedia, [1]))
        #expect(!valid(.additionalMedia, "/a.dmg"))
        #expect(valid(.additionalMedia, ["/1", "/2", "/3"]))
        #expect(!valid(.additionalMedia, ["/1", "/2", "/3", "/4"]))
    }

    /// The probe's cases, kept in step with `VIMNetworkMACAddressIsValid`.
    @Test func aMACAddressCannotInjectArguments() {
        #expect(MachineConfiguration.isValidMACAddress("02:34:56:78:9A:BC"))
        #expect(MachineConfiguration.isValidMACAddress("02:34:56:78:9a:bc"))
        for invalid in [
            "01:00:5E:00:00:01", "00:00:00:00:00:00", "52:54:00:12:34:GG", "52:54:0:12:34:56",
            "52:54:00:12:34:56,netdev=x", "52-54-00-12-34-56", "", "+2:34:56:78:9A:BC", "02:34:56:78:9A:B\u{BC}"
        ] {
            #expect(!MachineConfiguration.isValidMACAddress(invalid), "\(invalid)")
        }
        #expect(valid(.macAddress, ""))
        #expect(!valid(.macAddress, 1))
        #expect(!valid(.macAddress, "01:00:5E:00:00:01"))
    }

    @Test func theDefaultMACIsValidStableAndOverridable() {
        let configuration = Fixture.configuration
        #expect(configuration.effectiveMACAddress == "52:54:CF:AD:1C:CA")
        #expect(MachineConfiguration.isValidMACAddress(configuration.effectiveMACAddress))
        #expect(configuration.setting(.macAddress, "02:34:56:78:9a:bc").effectiveMACAddress == "02:34:56:78:9A:BC")
        #expect(configuration.setting(.macAddress, "bad").effectiveMACAddress == "52:54:CF:AD:1C:CA")
        #expect(configuration.setting(.identifier, "short").effectiveMACAddress == "52:54:00:00:00:01")
    }

    @Test func oldDisplayPreferencesMigrateWithoutImpossibleModes() {
        let modern = Fixture.configuration
        #expect(modern.effectiveDisplayMode == .retina)
        #expect(modern.setting(.retinaEnabled, false).effectiveDisplayMode == .scaled)
        #expect(modern.setting(.retinaEnabled, true).effectiveDisplayMode == .retina)
        #expect(modern.setting(.retinaEnabled, false).setting(.displayMode, "space").effectiveDisplayMode == .space)
        let classic = modern.setting(.guest, "leopard")
        #expect(classic.effectiveDisplayMode == .scaled)
        #expect(classic.setting(.retinaEnabled, true).effectiveDisplayMode == .scaled)
        #expect(classic.setting(.displayMode, "retina").effectiveDisplayMode == .scaled)
        #expect(classic.setting(.displayMode, "space").effectiveDisplayMode == .space)
    }

    @Test func theOldGraphicsKeyIsAFallbackOnly() {
        let configuration = Fixture.configuration
        #expect(!configuration.passthroughOpenGLEnabled)
        #expect(configuration.setting(.legacyDirectGLBridge, true).passthroughOpenGLEnabled)
        #expect(
            !configuration.setting(.legacyDirectGLBridge, true).setting(.passthroughOpenGLEnabled, false)
                .passthroughOpenGLEnabled)
        var edited = configuration.setting(.legacyDirectGLBridge, true)
        edited.passthroughOpenGLEnabled = false
        #expect(edited[.legacyDirectGLBridge] == true)
    }
}

@Suite struct NamingTests {
    @Test func namesAreBounded() {
        #expect(PackageNaming.isValid("Mac"))
        #expect(PackageNaming.isValid(String(repeating: "a", count: 128)))
        #expect(!PackageNaming.isValid(String(repeating: "a", count: 129)))
        #expect(!PackageNaming.isValid(""))
        #expect(!PackageNaming.isValid(" \n\t"))
        // A loadable name that came from an old package can contain what a rename can't.
        #expect(PackageNaming.isValid("a/b"))
    }

    @Test func aRenameStaysOneVisibleComponent() {
        #expect(PackageNaming.isValidRename("Work Mac"))
        for name in [".hidden", "a/b", "a:b", "a\nb", "a\rb", "", "  ", String(repeating: "a", count: 129)] {
            #expect(!PackageNaming.isValidRename(name), "\(name)")
        }
    }

    @Test func packageNamesAreSanitized() {
        #expect(PackageNaming.baseName(for: "Work Mac") == "Work Mac")
        #expect(PackageNaming.baseName(for: "a/b:c\nd\re") == "a-b-c-d-e")
        #expect(PackageNaming.baseName(for: "  spaced  ") == "spaced")
        #expect(PackageNaming.baseName(for: ".hidden") == "Mac .hidden")
        #expect(PackageNaming.baseName(for: "../../escape") == "Mac ..-..-escape")
        #expect(PackageNaming.baseName(for: "") == "Mac ")
    }

    @Test func collisionsGetANumber() {
        let library = URL(filePath: "/Library/Machines")
        var taken: Set = ["/Library/Machines/Mojave.vintelmac"]
        #expect(
            PackageNaming.newPackageURL(for: "Mojave", in: library) { taken.contains($0) }.lastPathComponent
                == "Mojave 2.vintelmac")
        taken.insert("/Library/Machines/Mojave 2.vintelmac")
        #expect(
            PackageNaming.newPackageURL(for: "Mojave", in: library) { taken.contains($0) }.lastPathComponent
                == "Mojave 3.vintelmac")
        #expect(
            PackageNaming.newPackageURL(for: "Catalina", in: library) { taken.contains($0) }.lastPathComponent
                == "Catalina.vintelmac")
    }
}

@Suite struct PathTests {
    @Test func aPackagePathIsNonEmptyAndRelative() {
        #expect(PackagePath(rawValue: "Disks/System.qcow2") != nil)
        #expect(PackagePath(rawValue: "") == nil)
        #expect(PackagePath(rawValue: "/etc/passwd") == nil)
        #expect(PackagePath(rawValue: "~/secret") == nil)
    }

    @Test func aPackagePathCannotClimbOutOfItsPackage() throws {
        try Fixture.withPackage { package in
            #expect(PackagePath(rawValue: "Disks/System.qcow2")?.resolved(in: package) != nil)
            #expect(PackagePath(rawValue: "../Other.vintelmac/Disks/System.qcow2")?.resolved(in: package) == nil)
            #expect(PackagePath(rawValue: "Disks/../../outside")?.resolved(in: package) == nil)
            // A sibling that merely starts with the package's name is outside it.
            let sibling = package.deletingLastPathComponent().appending(path: "Fixture.vintelmacs")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            #expect(PackagePath(rawValue: "../Fixture.vintelmacs")?.resolved(in: package) == nil)
            let outside = package.deletingLastPathComponent().appending(path: "outside.img")
            try Data("x".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: package.appending(path: "Disks/Link.qcow2"), withDestinationURL: outside)
            #expect(PackagePath(rawValue: "Disks/Link.qcow2")?.resolved(in: package) == nil)
        }
    }

    @Test func libraryChildrenAreFixed() {
        let root = URL(filePath: "/Volumes/Library", directoryHint: .isDirectory)
        let machines = root.appending(path: "Machines", directoryHint: .isDirectory)
        #expect(LibraryLayout.root(forLibrary: machines).path == root.path)
        #expect(LibraryLayout.root(forLibrary: root).path == root.path)
        #expect(LibraryLayout.machines(forLibrary: machines).path == machines.path)
        #expect(LibraryLayout.machines(forLibrary: root).path == machines.path)
        #expect(LibraryLayout.downloads(forLibrary: machines).path == "/Volumes/Library/Downloads")
        #expect(LibraryLayout.installers(forLibrary: machines).path == "/Volumes/Library/Installers")
    }

    @Test func onlyPreparedMediaHasAnAttemptToDelete() {
        let id = UUID().uuidString
        func attempt(_ media: String, owner: URL = URL(filePath: "/Library/Machines/Mac.vintelmac")) -> String? {
            LibraryLayout.preparedMediaAttempt(media: URL(filePath: media), owner: owner)?.path
        }
        #expect(attempt("/Library/Installers/\(id)/Media/a.iso") == "/Library/Installers/\(id)")
        #expect(attempt("/Library/Downloads/Preparation/\(id)/Media/a.iso") == "/Library/Downloads/Preparation/\(id)")
        // Another library's cache, a user's own file, or a folder not named by a UUID are never this machine's to
        // delete.
        #expect(attempt("/Other/Installers/\(id)/Media/a.iso") == nil)
        #expect(attempt("/Users/me/Downloads/a.iso") == nil)
        #expect(attempt("/Library/Installers/notauuid/Media/a.iso") == nil)
        #expect(attempt("/Library/Installers/\(id)/Other/a.iso") == nil)
        #expect(
            attempt("/Library/Installers/\(id)/Media/a.iso", owner: URL(filePath: "/Elsewhere/Mac.vintelmac")) == nil)
    }
}

@Suite struct LoadingTests {
    private func failure(_ configuration: MachineConfiguration, package: URL) -> MachineConfigurationError? {
        do throws(MachineConfigurationError) {
            try configuration.validate(package: package)
            return nil
        } catch {
            return error
        }
    }

    @Test func aGoodPackageLoads() throws {
        try Fixture.withPackage { package in
            #expect(failure(Fixture.configuration, package: package) == nil)
        }
    }

    @Test func theIdentityGateRefusesEverythingElse() throws {
        try Fixture.withPackage { package in
            let c = Fixture.configuration
            for bad in [
                c.setting(.formatVersion, 2), c.setting(.formatVersion, nil), c.setting(.guest, "plan9"),
                c.setting(.guest, nil), c.setting(.cpuCount, 0), c.setting(.cpuCount, 65), c.setting(.cpuCount, "4"),
                c.setting(.memoryMiB, 1023), c.setting(.memoryMiB, "4096"), c.setting(.identifier, "not-a-uuid"),
                c.setting(.identifier, 1), c.setting(.identifier, nil), c.setting(.name, ""), c.setting(.name, 1)
            ] {
                #expect(failure(bad, package: package) == .invalidConfiguration)
            }
        }
        try Fixture.withPackage(named: " ") { package in
            #expect(failure(Fixture.configuration, package: package) == .invalidConfiguration)
        }
    }

    @Test func applicationFirmwareNeedNotBeInThePackage() throws {
        try Fixture.withPackage { package in
            try FileManager.default.removeItem(at: package.appending(path: "Firmware/CODE.fd"))
            try FileManager.default.removeItem(at: package.appending(path: "Firmware/EFI.img"))
            #expect(failure(Fixture.configuration, package: package) == nil)
            #expect(
                failure(Fixture.configuration.setting(.firmwareSource, "package"), package: package)
                    == .fileMissingOrOutsidePackage("Firmware"))
            #expect(
                failure(Fixture.configuration.setting(.firmwareSource, nil), package: package)
                    == .fileMissingOrOutsidePackage("Firmware"))
        }
    }

    @Test func bootMediaKindIsChecked() throws {
        try Fixture.withPackage { package in
            #expect(failure(Fixture.configuration.setting(.bootMediaKind, "efi-disk"), package: package) == nil)
            #expect(
                failure(Fixture.configuration.setting(.bootMediaKind, "other"), package: package)
                    == .unsupportedBootMedia)
        }
    }

    @Test func installerMediaNeedsAnInstallingStateAndARulePath() throws {
        try Fixture.withPackage { package in
            let owned = package.appending(path: "Installation/Installer.iso")
            try Data("x".utf8).write(to: owned)
            let attached = Fixture.configuration.setting(.installerMedia, "Installation/Installer.iso")
            #expect(failure(attached.setting(.installState, "installing"), package: package) == nil)
            #expect(failure(attached.setting(.installState, "patching"), package: package) == nil)
            for state: PropertyListValue? in ["installed", "imported-prepared", "host-populated", nil] {
                #expect(
                    failure(attached.setting(.installState, state), package: package) == .installerMediaInInvalidState)
            }
            let installing = attached.setting(.installState, "installing")
            #expect(
                failure(installing.setting(.installerMediaKind, "tape"), package: package)
                    == .unsupportedInstallerMediaKind)
            #expect(failure(installing.setting(.installerMediaKind, "optical"), package: package) == nil)
            // Any other package file, or an unflagged absolute path, is not an installer.
            #expect(
                failure(installing.setting(.installerMedia, "Disks/System.qcow2"), package: package)
                    == .installerMediaInInvalidState)
            #expect(
                failure(installing.setting(.installerMedia, .string(owned.path)), package: package)
                    == .installerMediaInInvalidState)
            try FileManager.default.removeItem(at: owned)
            #expect(failure(installing, package: package) == .fileMissingOrOutsidePackage("InstallerMedia"))
        }
    }

    @Test func sharedInstallersAreAbsoluteRegularFiles() throws {
        try Fixture.withPackage { package in
            let library = package.deletingLastPathComponent()
            let media = library.appending(path: "Shared.iso")
            try Data("x".utf8).write(to: media)
            let shared = Fixture.configuration.setting(.installState, "installing")
                .setting(.installerMediaShared, true)
            #expect(failure(shared.setting(.installerMedia, .string(media.path)), package: package) == nil)
            #expect(
                failure(shared.setting(.installerMedia, "Installation/Installer.iso"), package: package)
                    == .sharedInstallerNotAbsolute)
            #expect(
                failure(shared.setting(.installerMedia, "/nonexistent/Shared.iso"), package: package)
                    == .sharedInstallerMissing)
            #expect(
                failure(shared.setting(.installerMedia, .string(library.path)), package: package)
                    == .sharedInstallerMissing)
            let link = library.appending(path: "Link.iso")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: media)
            #expect(
                failure(shared.setting(.installerMedia, .string(link.path)), package: package)
                    == .sharedInstallerMissing)
            // A flag that isn't exactly true doesn't make an absolute path shared.
            #expect(
                failure(
                    shared.setting(.installerMediaShared, false).setting(.installerMedia, .string(media.path)),
                    package: package) == .installerMediaInInvalidState)
        }
    }

    @Test func packageFilesMustBeInsideAndRegular() throws {
        try Fixture.withPackage { package in
            let c = Fixture.configuration
            for value: PropertyListValue? in ["", "/etc/passwd", "~/x", 1, nil] {
                #expect(failure(c.setting(.disk, value), package: package) == .invalidFilePath)
            }
            #expect(failure(c.setting(.disk, "../x"), package: package) == .fileMissingOrOutsidePackage("Disk"))
            #expect(
                failure(c.setting(.nvram, "Firmware/None.fd"), package: package)
                    == .fileMissingOrOutsidePackage("NVRAM"))
            // A folder isn't a disk.
            #expect(failure(c.setting(.disk, "Disks"), package: package) == .fileMissingOrOutsidePackage("Disk"))
            let outside = package.deletingLastPathComponent().appending(path: "outside.qcow2")
            try Data("x".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: package.appending(path: "Disks/Escape.qcow2"), withDestinationURL: outside)
            #expect(
                failure(c.setting(.disk, "Disks/Escape.qcow2"), package: package)
                    == .fileMissingOrOutsidePackage("Disk"))
            // A link that stays inside the package still names a real file.
            try FileManager.default.createSymbolicLink(
                at: package.appending(path: "Disks/Alias.qcow2"),
                withDestinationURL: package.appending(path: "Disks/System.qcow2"))
            #expect(failure(c.setting(.disk, "Disks/Alias.qcow2"), package: package) == nil)
        }
    }

    @Test func settingsAreCheckedAfterFiles() throws {
        try Fixture.withPackage { package in
            #expect(
                failure(Fixture.configuration.setting(.networkMode, "tap"), package: package)
                    == .invalidHardwareSettings)
            #expect(
                failure(
                    Fixture.configuration.setting(.networkMode, "tap").setting(.disk, "/x"), package: package)
                    == .invalidFilePath)
        }
    }

    @Test func theStateFolderMustBeReal() throws {
        try Fixture.withPackage { package in
            let state = package.appending(path: "State")
            try FileManager.default.removeItem(at: state)
            #expect(failure(Fixture.configuration, package: package) == .missingStateFolder)
            let elsewhere = package.deletingLastPathComponent().appending(path: "Elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: state, withDestinationURL: elsewhere)
            #expect(failure(Fixture.configuration, package: package) == .missingStateFolder)
        }
    }

    @Test func errorsBridgeWithTheirOldDomainAndMessages() {
        let error = MachineConfigurationError.fileMissingOrOutsidePackage("Disk") as NSError
        #expect(error.domain == "VirtualIntelMac.Machine")
        #expect(error.code == 1)
        #expect(error.localizedDescription == "The Disk file is missing or outside this package.")
    }
}

@Suite struct PendingChangesTests {
    private func pending(_ settings: PropertyListValue?, name: PropertyListValue? = nil) -> PendingChanges {
        var values: [String: PropertyListValue] = [:]
        values["Settings"] = settings
        values["RequestedBundleName"] = name
        return PendingChanges(values: values)
    }

    @Test func theEditableKeysAreExactlyTheOriginalOnes() {
        #expect(
            PendingChanges.editableKeys == [
                "CPUCount", "MemoryMiB", "SSHEnabled", "SSHPort", "FileSharingEnabled", "FileSharingPort",
                "AudioEnabled",
                "Description", "RetinaEnabled", "OpticalMedia", "NetworkConnected", "MACAddress", "DisplayMode",
                "AudioOutputDevice", "AudioInputDevice", "ClipboardEnabled", "NetworkMode", "BridgeInterface",
                "DisplayScalingFilter", "AdditionalMedia", "ScreenSharingEnabled", "ScreenSharingPort",
                "ExecutionEngine", "MeltdownProtection"
            ])
    }

    @Test func theEngineChoicesWaitLikeOtherSettings() throws {
        let base = Fixture.configuration
        let edit = pending(["ExecutionEngine": "on", "MeltdownProtection": "on"])
        #expect(edit.editable(from: base).executionEngine == .on)
        let applied = try edit.applied(to: base)
        #expect(applied.executionEngine == .on)
        #expect(applied.meltdownProtection == .on)
        #expect(throws: MachineConfigurationError.invalidSettings) {
            try pending(["MeltdownProtection": "maybe"]).applied(to: base)
        }
    }

    @Test func aSettingsWindowSeesOnlyEditableValidEdits() {
        let base = Fixture.configuration
        let edited = pending(["CPUCount": 8, "Disk": "/etc/passwd"]).editable(from: base)
        #expect(edited.cpuCount == 8)
        #expect(edited.values["Disk"] == "Disks/System.qcow2")
        // Invalid queued values fall back to the launch snapshot.
        #expect(pending(["CPUCount": 128]).editable(from: base) == base)
        #expect(pending("not a dictionary").editable(from: base) == base)
    }

    @Test func publishingRefusesAWholeFileWithAnUnsupportedKey() throws {
        let base = Fixture.configuration
        #expect(throws: MachineConfigurationError.queuedUnsupportedSetting) {
            try pending(["CPUCount": 8, "Disk": "/etc/passwd"]).applied(to: base)
        }
        #expect(throws: MachineConfigurationError.invalidSettings) { try pending(["CPUCount": 128]).applied(to: base) }
        #expect(try pending(["CPUCount": 8]).applied(to: base).cpuCount == 8)
        #expect(try pending(nil).applied(to: base) == base)
    }

    @Test func aRenameIsOnlyAValidDifferentName() {
        let base = Fixture.configuration
        #expect(pending(nil, name: "Work").destinationName(packageStem: "Mac", configuration: base) == "Work")
        #expect(pending(nil, name: "Mac").destinationName(packageStem: "Mac", configuration: base) == nil)
        #expect(pending(nil, name: "").destinationName(packageStem: "Mac", configuration: base) == nil)
        #expect(pending(nil, name: 1).destinationName(packageStem: "Mac", configuration: base) == nil)
        #expect(pending(nil, name: "Work").requestedName == "Work")
        #expect(pending(nil, name: 1).requestedName == nil)
        #expect(pending(nil).destinationName(packageStem: "Mac", configuration: base) == nil)
    }

    @Test func aUUIDPackageMigratesToItsName() {
        let stem = UUID().uuidString
        let named = Fixture.configuration.setting(.name, "Mojave")
        #expect(pending(nil).destinationName(packageStem: stem, configuration: named) == "Mojave")
        #expect(pending(nil).destinationName(packageStem: "Mac", configuration: named) == nil)
        #expect(pending(nil, name: "Work").destinationName(packageStem: stem, configuration: named) == "Work")
        // A request that's present but malformed doesn't fall back to the old key.
        #expect(pending(nil, name: 1).destinationName(packageStem: stem, configuration: named) == nil)
        #expect(pending(nil).destinationName(packageStem: stem, configuration: Fixture.configuration) == nil)
    }

    @Test func theFilenameReplacesTheNameKey() {
        #expect(Fixture.configuration.setting(.name, "Mojave").removingLegacyName() == Fixture.configuration)
    }

    @Test func forwardingDefaultsPreserveOptOutsAndAssignedPorts() {
        let suggested = { (ssh: 2222, fileSharing: 1445) }
        let legacy = Fixture.configuration.withNetworkDefaults(suggestedPorts: suggested)
        #expect(legacy?.sshEnabled == true)
        #expect(legacy?.fileSharingEnabled == true)
        #expect(legacy?.sshPort == 2222)
        #expect(legacy?.fileSharingPort == 1445)
        #expect(legacy?.hasValidSettings == true)
        // Assigned ports are stable on later starts, and don't even ask.
        #expect(
            legacy?.withNetworkDefaults {
                Issue.record("Asked for ports")
                return (0, 0)
            } == legacy)
        let optedOut = Fixture.configuration.setting(.sshEnabled, false).setting(.fileSharingEnabled, false)
            .withNetworkDefaults(suggestedPorts: suggested)
        #expect(optedOut?.sshEnabled == false)
        #expect(optedOut?.fileSharingEnabled == false)
        #expect(Fixture.configuration.withNetworkDefaults { (0, 1445) } == nil)
        #expect(Fixture.configuration.withNetworkDefaults { (2222, 0) } == nil)
        #expect(Fixture.configuration.setting(.sshPort, 3000).withNetworkDefaults { (0, 1445) }?.sshPort == 3000)
    }
}

@Suite struct InstallStateTests {
    private let installing = Fixture.configuration.setting(.installState, "installing")
        .setting(.installerMedia, "/Volumes/a.iso").setting(.installerMediaKind, "optical")
        .setting(.installerMediaShared, true)

    private func hasNoInstaller(_ configuration: MachineConfiguration) -> Bool {
        configuration[.installerMedia] == nil && configuration[.installerMediaKind] == nil
    }

    @Test func aClassicRestartRetiresRoutingAndMovesToPatching() {
        let next = installing.restartingForOpenGLSetup()
        #expect(next.installState == .patching)
        #expect(hasNoInstaller(next))
        #expect(next[.installerMediaShared] == nil)
    }

    @Test func classicCompletionRefusesAnAttachedInstaller() throws {
        #expect(throws: MachineConfigurationError.installerStillAttached) { try installing.finishingOpenGLSetup() }
        let finished = try installing.restartingForOpenGLSetup().finishingOpenGLSetup()
        #expect(finished.installState == .installed)
    }

    @Test func sharedMediaIsDetachedCompletely() {
        let next = installing.finishingWithSharedInstaller()
        #expect(next.installState == .installed)
        #expect(hasNoInstaller(next))
        #expect(next[.installerMediaShared] == nil)
    }

    @Test func ownedMediaLeavesOnlyWhatItAlwaysLeft() {
        let next = installing.setting(.installerMediaShared, false).finishingWithOwnedInstaller()
        #expect(next.installState == .installed)
        #expect(hasNoInstaller(next))
        #expect(next[.installerMediaShared] == false)
    }

    @Test func aTransitionKeepsEverythingElse() {
        let next = installing.setting(.description, "keep").finishingWithSharedInstaller()
        #expect(next.machineDescription == "keep")
        #expect(next.cpuCount == 4)
    }

    @Test func installerMediaIsTyped() {
        var configuration = Fixture.configuration
        #expect(configuration.installerMedia == nil)
        configuration.installerMedia = .owned
        #expect(configuration.values["InstallerMedia"] == "Installation/Installer.iso")
        #expect(configuration.installerMedia == .owned)
        configuration.installerMedia = .shared(AbsolutePath(rawValue: "/a.iso")!)
        #expect(configuration.values["InstallerMediaShared"] == true)
        configuration.installerMedia = nil
        #expect(configuration.values["InstallerMedia"] == nil)
        #expect(configuration.values["InstallerMediaShared"] == nil)
        #expect(Fixture.configuration.setting(.installerMedia, "Disks/System.qcow2").installerMedia == nil)
    }
}
