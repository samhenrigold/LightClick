import Foundation
import InstallerKit

/// How far a saved setup has got. Raw values are what preferences hold.
public enum CreationPhase: String, Sendable {
    case downloading, preparing, creating, stopping, paused, failed, downloaded

    /// Whether the host should stay awake for it.
    public var isBusy: Bool {
        switch self {
        case .downloading, .preparing, .creating, .stopping: true
        case .paused, .failed, .downloaded: false
        }
    }

    public var pauseButtonTitle: String {
        if isBusy { "Pause" } else if self == .failed { "Try Again" } else { "Resume" }
    }

    /// Pause and Cancel mean nothing while a disk is being made or a stop is under way.
    public var allowsPauseAndCancel: Bool { self != .creating && self != .stopping }
}

/// A job's account and sharing policy. No password: `VIMAutomaticSetup` keeps that under `credentialIdentifier`.
/// `VIMMachine.saveAutomaticSetup` accepts exactly these keys, with `FormatVersion` 1 and `Enabled` true.
public struct AutomaticSetupProfile: Equatable, Sendable {
    public var isEnabled: Bool
    public var username: String?
    public var fileSharing: Bool
    public var remoteLogin: Bool
    /// Absent on a job saved before automatic login was its own option.
    public var automaticLogin: Bool?
    public var credentialIdentifier: String?

    public init(
        username: String, fileSharing: Bool, remoteLogin: Bool, automaticLogin: Bool, credentialIdentifier: String
    ) {
        isEnabled = true
        self.username = username
        self.fileSharing = fileSharing
        self.remoteLogin = remoteLogin
        self.automaticLogin = automaticLogin
        self.credentialIdentifier = credentialIdentifier
    }

    init(propertyList: [String: Any]) {
        isEnabled = (propertyList["Enabled"] as? NSNumber)?.boolValue ?? false
        username = propertyList["Username"] as? String
        fileSharing = (propertyList["FileSharing"] as? NSNumber)?.boolValue ?? false
        remoteLogin = (propertyList["RemoteLogin"] as? NSNumber)?.boolValue ?? false
        automaticLogin = (propertyList["AutomaticLogin"] as? NSNumber)?.boolValue
        credentialIdentifier = propertyList["CredentialIdentifier"] as? String
    }

    /// `Enabled` is a real Boolean and the three options are integers, as they've always been saved.
    public var propertyList: [String: Any] {
        var list: [String: Any] = [
            "FormatVersion": 1, "Enabled": isEnabled, "FileSharing": fileSharing ? 1 : 0,
            "RemoteLogin": remoteLogin ? 1 : 0
        ]
        list["Username"] = username
        list["AutomaticLogin"] = automaticLogin.map { $0 ? 1 : 0 }
        list["CredentialIdentifier"] = credentialIdentifier
        return list
    }
}

/// A setup in progress, as a value. Preferences hold it under `VIMCreationJob`, which `VIMMachine` and `LibraryMigration`
/// also read and edit, so its keys and their types can't change.
public struct CreationJob: Sendable {
    /// Names the job and its saved password.
    public let identifier: String
    public var library: String
    public let guest: Guest
    public var name: String?
    public var cores: Int?
    public var memoryGiB: Int?
    public var diskGiB: Int?
    public var automaticSetup: AutomaticSetupProfile?
    /// An installer app or restore DVD to prepare media from.
    public var sourceInstaller: String?
    /// A `sourceInstaller` this job assembled, which it can delete once media exists.
    public var preparedInstaller: String?
    public var media: String?
    public var machine: String?
    public var phase: CreationPhase?
    public var progress: Double?

    public init(identifier: String = UUID().uuidString, library: String, guest: Guest) {
        self.identifier = identifier
        self.library = library
        self.guest = guest
    }

    /// Nil unless it names a supported guest and a library, which everything else needs. Preferences are untrusted.
    public init?(propertyList: [String: Any]) {
        guard let guest = (propertyList["Guest"] as? String).flatMap(Guest.init(rawValue:)),
            let library = propertyList["Library"] as? String
        else { return nil }
        self.init(
            identifier: propertyList["Identifier"] as? String ?? UUID().uuidString, library: library, guest: guest)
        name = propertyList["Name"] as? String
        cores = (propertyList["CPU"] as? NSNumber)?.intValue
        memoryGiB = (propertyList["Memory"] as? NSNumber)?.intValue
        diskGiB = (propertyList["Disk"] as? NSNumber)?.intValue
        automaticSetup = (propertyList["AutomaticSetup"] as? [String: Any]).map(
            AutomaticSetupProfile.init(propertyList:))
        sourceInstaller = propertyList["SourceInstaller"] as? String
        preparedInstaller = propertyList["PreparedInstaller"] as? String
        media = propertyList["Media"] as? String
        machine = propertyList["Machine"] as? String
        phase = (propertyList["Phase"] as? String).flatMap(CreationPhase.init(rawValue:))
        progress = (propertyList["Progress"] as? NSNumber)?.doubleValue
    }

    public var propertyList: [String: Any] {
        var list: [String: Any] = ["Identifier": identifier, "Library": library, "Guest": guest.rawValue]
        list["Name"] = name
        list["CPU"] = cores
        list["Memory"] = memoryGiB
        list["Disk"] = diskGiB
        list["AutomaticSetup"] = automaticSetup?.propertyList
        list["SourceInstaller"] = sourceInstaller
        list["PreparedInstaller"] = preparedInstaller
        list["Media"] = media
        list["Machine"] = machine
        list["Phase"] = phase?.rawValue
        list["Progress"] = progress
        return list
    }

    public var libraryURL: URL { URL(fileURLWithPath: library) }

    public mutating func apply(_ specification: NewMachineSpecification) {
        name = specification.name
        cores = specification.cores
        memoryGiB = specification.memoryGiB
        diskGiB = specification.diskGiB
    }

    /// Records the installer the user chose. An app or a restore DVD still needs preparing; any other image is media.
    public mutating func useInstaller(_ installer: URL) {
        let kind = installer.pathExtension.lowercased()
        if kind == "app" || (guest.traits.contains(.restoreDVD) && kind == "dmg") {
            sourceInstaller = installer.path
            media = nil
        } else {
            media = installer.path
            sourceInstaller = nil
        }
    }

    /// What setup writes: downloads, the peak of assembly and media creation (each step's scratch is deleted as it
    /// finishes), and the installed system. The guest disk is sparse, so its capacity doesn't count.
    public var requiredFreeBytes: UInt64 {
        let gibibytes: UInt64 = media != nil ? (guest == .bigSur ? 28 : 22) : (guest == .bigSur ? 64 : 44)
        return gibibytes << 30
    }

    /// The problem with `freeBytes` of space, if any. A machine that already exists needs no more.
    public func spaceIssue(freeBytes: UInt64) -> CreationIssue? {
        guard machine == nil, freeBytes < requiredFreeBytes else { return nil }
        let amount = ByteCountFormatter.string(fromByteCount: Int64(requiredFreeBytes), countStyle: .file)
        return CreationIssue(
            detail: "Your library drive needs at least \(amount) available for this disk and installer preparation.")
    }

    /// What continuing this job does next.
    public enum Step: Equatable, Sendable {
        case openMachine(URL)
        case createMachine(media: URL)
        case prepareMedia(installer: URL)
        case download
    }

    public func nextStep(fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Step {
        if let machine { return .openMachine(URL(fileURLWithPath: machine)) }
        if let media, fileExists(media) { return .createMachine(media: URL(fileURLWithPath: media)) }
        if let sourceInstaller { return .prepareMedia(installer: URL(fileURLWithPath: sourceInstaller)) }
        return .download
    }

    /// `VIMMachine.saveSettings` for this job.
    public var machineSettings: [String: Any] {
        ["CPUCount": cores ?? 4, "MemoryMiB": (memoryGiB ?? 0) * 1024]
    }
}

/// Where preferences keep a job. A download-only run has its own key, so it can't clobber a real setup.
public struct CreationJobStore {
    public enum Slot: String, Sendable {
        case creation = "VIMCreationJob"
        case installerDownload = "VIMInstallerDownloadJob"
    }

    public let preferences: UserDefaults

    public init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
    }

    public func load(_ slot: Slot) -> CreationJob? {
        preferences.dictionary(forKey: slot.rawValue).flatMap(CreationJob.init(propertyList:))
    }

    public func save(_ job: CreationJob, to slot: Slot) {
        preferences.set(job.propertyList, forKey: slot.rawValue)
    }

    public func remove(_ slot: Slot) {
        preferences.removeObject(forKey: slot.rawValue)
    }
}
