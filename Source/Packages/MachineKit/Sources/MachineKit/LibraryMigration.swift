import Foundation

/// A machine that a migration moved, for the app to tell its open windows.
public struct MachineRelocation: Equatable, Sendable {
    public let oldURL: URL
    public let url: URL
    public let identifier: String
}

/// Organizes a library into the Machines, Downloads and Installers layout, in place and only while it's idle. It saves
/// its plan before moving anything, so an interrupted run resumes with the same plan.
struct LibraryMigration {
    /// Where the library is going to be.
    let root: URL
    /// Where its items may still be. For the standard library that's its old `Machines` root.
    let previousRoot: URL
    let preferences: UserDefaults

    private let fileManager = FileManager.default

    private var marker: URL { root.appendingPathComponent(".VirtualIntelMacLibrary.plist") }
    private var journal: URL { root.appendingPathComponent(".LibraryLayoutMigration.plist") }
    private var machines: URL { root.appendingPathComponent("Machines", isDirectory: true) }

    private static let packageExtension = PackageNaming.pathExtension
    private static let activeCreationPhases: Set<String> = ["downloading", "preparing", "creating", "stopping"]

    var isComplete: Bool {
        (NSDictionary(contentsOf: marker)?["FormatVersion"] as? NSNumber)?.isEqual(to: 2) ?? false
    }

    func run() throws -> [MachineRelocation] {
        if isComplete { return [] }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var locks = FileLocks()
        defer { locks.release() }
        guard locks.acquire(root.appendingPathComponent(".LibraryLayout.lock")) else {
            throw LibraryLocationError.anotherCopyOrganizing
        }
        if isComplete { return [] }
        // Never relocate an active creation job, its resumed transfers, or any machine held by another app process.
        // Locks are retained through publish.
        if creationJobIsActive { throw LibraryLocationError.creationInProgress }
        let saved = try savedMoves()
        let moves = saved ?? plannedMoves()
        let order = moves.physicalOrder
        var packages = Set<String>()
        for old in order {
            let new = moves.destinations[old]!
            guard (old as NSString).isAbsolutePath, (new as NSString).isAbsolutePath,
                old.hasLiteralPrefix(previousRoot.path + "/"), new.hasLiteralPrefix(root.path + "/")
            else { throw LibraryLocationError.unexpectedLocationInRecord }
            let original = fileManager.fileExists(atPath: old)
            let destination = fileManager.fileExists(atPath: new)
            if original && destination { throw LibraryLocationError.duplicateItem }
            if !original && !destination { throw LibraryLocationError.missingItem }
            if (old as NSString).pathExtension == Self.packageExtension { packages.insert(original ? old : new) }
        }
        for item in packagesInMachines() { packages.insert(item.path) }
        for package in packages {
            let state = URL(fileURLWithPath: package).appendingPathComponent("State")
            guard locks.acquire(state.appendingPathComponent("Session.lock")) else {
                throw LibraryLocationError.machineRunning
            }
            guard locks.acquire(state.appendingPathComponent("Configuration.lock")) else {
                throw LibraryLocationError.machineSettingsSaving
            }
        }
        let record: PropertyListValue = [
            "FormatVersion": 1, "Legacy": .string(previousRoot.path),
            "Moves": .dictionary(moves.destinations.mapValues(PropertyListValue.string))
        ]
        try write(record, to: journal)
        try fileManager.createDirectory(at: machines, withIntermediateDirectories: true)
        for old in order where fileManager.fileExists(atPath: old) {
            try fileManager.moveItem(atPath: old, toPath: moves.destinations[old]!)
        }
        for folder in ["Downloads", "Installers"] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try rewriteMachinePropertyLists(moves)
        relocatePreferences(moves)
        try write(["FormatVersion": 2], to: marker)
        // The small journal stays behind as a recoverable path map.
        return relocations(moves)
    }

    private var creationJobIsActive: Bool {
        guard let job = preferences.dictionary(forKey: "VIMCreationJob"), let library = job["Library"] as? String,
            !library.isEmpty, let phase = job["Phase"] as? String
        else { return false }
        return (LibraryLayout.root(forLibrary: URL(fileURLWithPath: library)).path as NSString).isEqual(to: root.path)
            && Self.activeCreationPhases.contains(phase)
    }

    /// The plan an interrupted run saved, or nil if there's none. A file that doesn't parse at all counts as none, and
    /// its plan is made again from what's on disk. A parsed record that's wrong refuses.
    private func savedMoves() throws -> LibraryMoves? {
        guard let object = NSDictionary(contentsOf: journal) else { return nil }
        let record = PropertyListValue(foundationObject: object).dictionary
        guard let record, record["FormatVersion"].isEqual(1), record["Legacy"].isEqual(.string(previousRoot.path)),
            let saved = record["Moves"]?.dictionary
        else { throw LibraryLocationError.unreadableLayoutRecord }
        let destinations = saved.compactMapValues(\.string)
        guard destinations.count == saved.count else { throw LibraryLocationError.invalidLayoutRecord }
        return LibraryMoves(destinations: destinations)
    }

    private func plannedMoves() -> LibraryMoves {
        var moves = LibraryMoves()
        let items = (try? fileManager.contentsOfDirectory(at: previousRoot, includingPropertiesForKeys: nil)) ?? []
        for item in items
        where item.pathExtension == Self.packageExtension && item.deletingLastPathComponent().path != machines.path {
            moves.destinations[item.path] = machines.appendingPathComponent(item.lastPathComponent).path
        }
        let downloads = previousRoot.appendingPathComponent("Downloads")
        let preparation = downloads.appendingPathComponent("Preparation")
        if fileManager.fileExists(atPath: preparation.path) {
            moves.destinations[preparation.path] = root.appendingPathComponent("Installers").path
        }
        let newDownloads = root.appendingPathComponent("Downloads")
        if downloads.path != newDownloads.path, fileManager.fileExists(atPath: downloads.path) {
            moves.destinations[downloads.path] = newDownloads.path
        }
        return moves
    }

    private func packagesInMachines() -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: machines, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == Self.packageExtension }
    }

    /// Only property lists belonging to a machine are rewritten. Guest disks, firmware, downloaded package bytes and
    /// image contents are never touched.
    private func rewriteMachinePropertyLists(_ moves: LibraryMoves) throws {
        for package in packagesInMachines() {
            var files = [package.appendingPathComponent("Machine.plist")]
            for folder in ["Installation", "State"] {
                guard
                    let contents = fileManager.enumerator(
                        at: package.appendingPathComponent(folder), includingPropertiesForKeys: nil,
                        options: .skipsHiddenFiles)
                else { continue }
                for case let file as URL in contents where file.pathExtension == "plist" { files.append(file) }
            }
            for file in files {
                guard let data = try? Data(contentsOf: file),
                    let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
                else { continue }
                let value = PropertyListValue(foundationObject: object)
                let relocated = moves.relocated(value)
                if value != relocated { try write(relocated, to: file) }
            }
        }
    }

    /// Paths inside any `VIM…` preference, and the preferences whose names hold a path. The selection isn't among
    /// them: it says which library this is, and only `LibrarySelection` writes it.
    private func relocatePreferences(_ moves: LibraryMoves) {
        for key in preferences.dictionaryRepresentation().keys
        where key.hasPrefix("VIM") && !LibrarySelection.isPreferenceKey(key) {
            guard let object = preferences.object(forKey: key) else { continue }
            let value = PropertyListValue(foundationObject: object)
            var updated = moves.relocated(value)
            var newKey = key
            for prefix in LibraryPreferences.rootKeyedPrefixes where key == prefix + previousRoot.path {
                newKey = prefix + root.path
            }
            let usernamePrefix = "VIMGuestUsername-"
            if key.hasPrefix(usernamePrefix) {
                newKey = usernamePrefix + moves.relocated((key as NSString).substring(from: usernamePrefix.utf16.count))
            }
            if key == "VIMCreationJob", var job = updated.dictionary,
                job["Library"].isEqual(.string(previousRoot.path))
            {
                job["Library"] = .string(root.path)
                updated = .dictionary(job)
            }
            if key != newKey { preferences.removeObject(forKey: key) }
            if key != newKey || value != updated { preferences.set(updated.foundationObject, forKey: newKey) }
        }
    }

    private func relocations(_ moves: LibraryMoves) -> [MachineRelocation] {
        moves.destinations.compactMap { old, new in
            guard (old as NSString).pathExtension == Self.packageExtension else { return nil }
            let url = URL(fileURLWithPath: new)
            let plist = NSDictionary(contentsOf: url.appendingPathComponent("Machine.plist"))
            guard let identifier = plist?["Identifier"] as? String else { return nil }
            return MachineRelocation(oldURL: URL(fileURLWithPath: old), url: url, identifier: identifier)
        }
    }

    private func write(_ value: PropertyListValue, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value.foundationObject, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }
}

enum LibraryPreferences {
    /// Library window state, saved under the path of the library it describes.
    static let rootKeyedPrefixes = ["VIMLibraryKnown-", "VIMLibraryOrder-", "VIMLibraryArrange-"]
}
