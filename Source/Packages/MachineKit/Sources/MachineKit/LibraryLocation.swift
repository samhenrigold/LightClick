import Foundation

/// The selected library and its folders. A user-selected root holds Machines, Downloads and Installers children. Legacy
/// items in that same root are renamed only while all machines are idle; choosing another library never transfers Macs
/// from the previous one.
public struct LibraryLocation {
    /// Where this instance's own default library is. It differs between instances that share `preferences`.
    public let standardLibrary: URL
    public let preferences: UserDefaults

    public init(standardLibrary: URL, preferences: UserDefaults) {
        self.standardLibrary = standardLibrary
        self.preferences = preferences
    }

    public var root: URL {
        LibraryLayout.root(forLibrary: LibrarySelection.configuredLibrary(in: preferences) ?? standardLibrary)
    }

    public var machines: URL { LibraryLayout.machines(forLibrary: root) }
    public var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    public var installers: URL { root.appendingPathComponent("Installers", isDirectory: true) }

    private func selection(ofRoot root: URL) -> LibrarySelection {
        LibrarySelection(root: root, standardRoot: LibraryLayout.root(forLibrary: standardLibrary))
    }

    /// The standard library's folders, even when another library is selected. That library isn't migrated or changed.
    public func createStandardFolders() throws {
        for folder in ["", "Machines", "Downloads", "Installers"] {
            try FileManager.default.createDirectory(
                at: standardLibrary.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    /// Organizes the selected library and tidies what preferences say about it. A deferred migration throws `EBUSY`
    /// and leaves everything as it was.
    public func organizeSelectedLibrary() throws -> [MachineRelocation] {
        let root = root
        let previousRoot =
            LibrarySelection.configuredLibrary(in: preferences)
            ?? standardLibrary.appendingPathComponent("Machines", isDirectory: true)
        let relocations = try LibraryMigration(root: root, previousRoot: previousRoot, preferences: preferences).run()
        adoptMachinesKeyedPreferences(root: root)
        selection(ofRoot: root).save(to: preferences)
        return relocations
    }

    /// Selects `url` if it's a folder this user can write to and it can be organized now. Follow this with
    /// `organizeSelectedLibrary()`.
    public func select(_ url: URL?) throws -> [MachineRelocation] {
        guard let url, url.isFileURL, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw LibraryLocationError.notAFolder
        }
        let root = LibraryLayout.root(forLibrary: url)
        // A real exclusive probe catches read-only and offline volumes without relying on an optimistic permissions
        // check. Never touch existing user files.
        let probe = root.appendingPathComponent(".vim-write-check-" + UUID().uuidString)
        try Data().write(to: probe, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: probe)
        let relocations = try LibraryMigration(root: root, previousRoot: root, preferences: preferences).run()
        selection(ofRoot: root).save(to: preferences)
        return relocations
    }

    /// Preserves the catalog and manual ordering from the build that keyed them by `Machines`. Known rows merge, since
    /// older root-keyed records can still describe renamed Macs.
    private func adoptMachinesKeyedPreferences(root: URL) {
        let machines = LibraryLayout.machines(forLibrary: root).path
        for prefix in LibraryPreferences.rootKeyedPrefixes {
            let old = prefix + machines
            let key = prefix + root.path
            guard let previous = preferences.object(forKey: old) else { continue }
            if prefix == "VIMLibraryKnown-" {
                var known = preferences.dictionary(forKey: key) ?? [:]
                if let rows = previous as? [String: Any] { known.merge(rows) { $1 } }
                preferences.set(known, forKey: key)
            } else if preferences.object(forKey: key) == nil {
                preferences.set(previous, forKey: key)
            }
            preferences.removeObject(forKey: old)
        }
    }
}
