import Foundation
import Testing

@testable import MachineKit

private let key = "VIMLibraryPath"

@Suite struct LibrarySelectionTests {
    @Test func aDefaultIsNeverSavedByOrganizing() throws {
        let fixture = try LibraryFixture()
        let location = fixture.location()
        try location.createStandardFolders()
        _ = try location.organizeSelectedLibrary()
        #expect(fixture.preferences.object(forKey: key) == nil)
    }

    /// The old setURL: wrote the path first and relied on prepareLayout to remove it, so a failure between left it.
    @Test func selectingTheDefaultNeverSavesItEvenIfNothingFollows() throws {
        let fixture = try LibraryFixture()
        let location = fixture.location()
        try location.createStandardFolders()
        _ = try location.select(location.standardLibrary)
        #expect(fixture.preferences.object(forKey: key) == nil)
    }

    @Test(arguments: ["Machines", "Machines/", "Machines/../Machines", "./"])
    func aDefaultSpelledDifferentlyIsStillTheDefault(spelling: String) throws {
        let fixture = try LibraryFixture()
        let location = fixture.location()
        try location.createStandardFolders()
        _ = try location.select(location.standardLibrary.appending(path: spelling))
        #expect(fixture.preferences.object(forKey: key) == nil)
    }

    @Test func aTestInstanceDoesNotPinTheRealApp() throws {
        let fixture = try LibraryFixture()
        let test = fixture.location(home: "TestHome")
        let real = fixture.location(home: "RealHome")
        try test.createStandardFolders()
        _ = try test.select(test.standardLibrary)
        _ = try test.organizeSelectedLibrary()
        #expect(real.root.path == real.standardLibrary.path)
        #expect(test.root.path == test.standardLibrary.path)
    }

    @Test func aDefaultAnOlderBuildSavedIsRemoved() throws {
        let fixture = try LibraryFixture()
        let location = fixture.location()
        try location.createStandardFolders()
        fixture.preferences.set(location.standardLibrary.path, forKey: key)
        _ = try location.organizeSelectedLibrary()
        #expect(fixture.preferences.object(forKey: key) == nil)
    }

    @Test func aChosenLibraryIsSavedAndItsMachinesChildNormalized() throws {
        let fixture = try LibraryFixture()
        let location = fixture.location()
        let chosen = try fixture.folder("External")
        try FileManager.default.createDirectory(
            at: chosen.appending(path: "Machines"), withIntermediateDirectories: true)
        _ = try location.select(chosen.appending(path: "Machines"))
        #expect(fixture.preferences.string(forKey: key) == chosen.path)
        #expect(location.root.path == chosen.path)
        fixture.preferences.set(chosen.appending(path: "Machines").path, forKey: key)
        _ = try location.organizeSelectedLibrary()
        #expect(fixture.preferences.string(forKey: key) == chosen.path)
    }

    @Test func aSelectionHasNoPathUnlessItDiffersFromTheStandardRoot() {
        let standard = URL(filePath: "/Home/Light Click")
        #expect(LibrarySelection(root: standard, standardRoot: standard) == .standard)
        guard case .chosen(let library) = LibrarySelection(root: URL(filePath: "/Other"), standardRoot: standard) else {
            Issue.record("Another root is a choice")
            return
        }
        #expect(library.path == "/Other")
    }

    @Test func theMigrationsPreferenceSweepCannotRewriteTheSelection() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        let package = try fixture.machine("Library/Mac.vintelmac")
        let saved = package.appending(path: "Nested").path
        fixture.preferences.set(saved, forKey: key)
        _ = try fixture.migration(root: root).run()
        #expect(fixture.preferences.string(forKey: key) == saved)
    }

    /// `private` keeps this true within the package. This keeps it true for the app's code outside it.
    @Test func onlyLibrarySelectionNamesThePreference() throws {
        var mentions: [String] = []
        for folder in ["Packages/MachineKit/Sources", "VirtualIntelMac"] {
            let files = try #require(
                FileManager.default.enumerator(
                    at: Fixture.sourceRoot.appending(path: folder), includingPropertiesForKeys: nil))
            for case let file as URL in files where ["swift", "m", "h", "mm"].contains(file.pathExtension) {
                if let text = try? String(contentsOf: file, encoding: .utf8), text.contains(key) {
                    mentions.append(file.lastPathComponent)
                }
            }
        }
        #expect(mentions == ["LibrarySelection.swift"])
    }
}

@Suite struct LibraryBridgeTests {
    /// Only the read-only selectors are called here: the others would touch this process's real preferences.
    @Test func theSelectorsTheAppCallsExist() throws {
        let bridge: AnyObject = try #require(NSClassFromString("VIMLibraryLocation"))
        for selector in [
            "downloadsURL", "installersURL", "rootURL", "machinesURL", "defaultURL", "currentURL", "rootURLForLibrary:",
            "machinesURLForLibrary:", "downloadsURLForMachines:", "installersURLForMachines:", "prepareLayout:",
            "setURL:error:"
        ] {
            #expect(bridge.responds(to: Selector(selector)), "\(selector)")
        }
    }

    @Test func nilGivesNilRatherThanTrapping() {
        #expect(LibraryLocationBridge.rootURL(forLibrary: nil) == nil)
        #expect(LibraryLocationBridge.machinesURL(forLibrary: nil) == nil)
        #expect(LibraryLocationBridge.downloadsURL(forMachines: nil) == nil)
        #expect(LibraryLocationBridge.installersURL(forMachines: nil) == nil)
    }

    @Test func oldJobsMachinesChildFindsTheSameFolders() {
        let machines = URL(filePath: "/Volumes/Library/Machines")
        #expect(LibraryLocationBridge.rootURL(forLibrary: machines)?.path == "/Volumes/Library")
        #expect(LibraryLocationBridge.machinesURL(forLibrary: machines)?.path == machines.path)
        #expect(LibraryLocationBridge.downloadsURL(forMachines: machines)?.path == "/Volumes/Library/Downloads")
        #expect(LibraryLocationBridge.installersURL(forMachines: machines)?.path == "/Volumes/Library/Installers")
    }

    @Test func theDefaultIsInThisHomesApplicationSupport() {
        #expect(LibraryLocationBridge.defaultURL.path.hasSuffix("/Library/Application Support/Light Click"))
    }
}

@Suite struct LibraryPathTests {
    /// Each spelling against the NSURL calls the Objective-C made. A root's path is part of saved preference keys, so
    /// any difference would orphan a library's saved order and known machines.
    @Test(arguments: [
        "/tmp/x", "/private/tmp", "/private/var/tmp/x", "/a/../b/./c/", "~/x", "/a b/é", "/a b/e\u{301}",
        "/Foo/Machines/", "/Machines", "/", "/private/nonexistent/x", "/tmp/Machines/../y", "/x/Machines/Machines"
    ])
    func rootsMatchFoundationsStandardizing(path: String) throws {
        let input = URL(fileURLWithPath: path, isDirectory: true)
        let url = try #require((input as NSURL).standardizingPath)
        let expected = url.lastPathComponent == "Machines" ? url.deletingLastPathComponent() : url
        #expect(LibraryLayout.root(forLibrary: input).path == expected.path)
    }

    /// Unusual, and kept: `Machines` collapses once per lookup, so a library really named this way disagrees with
    /// itself. Its root is the first `Machines`, and its machines are in that same folder.
    @Test func aDoubleMachinesFolderCollapsesTwiceForMachines() throws {
        let fixture = try LibraryFixture()
        let location = fixture.location()
        fixture.preferences.set(fixture.home.appending(path: "x/Machines/Machines").path, forKey: key)
        #expect(location.root.path == fixture.home.appending(path: "x/Machines").path)
        #expect(location.machines.path == fixture.home.appending(path: "x/Machines").path)
        #expect(location.downloads.path == fixture.home.appending(path: "x/Machines/Downloads").path)
    }

    @Test(arguments: ["", "relative/path", "./x"])
    func anUnusablePreferenceMeansTheDefault(value: String) throws {
        let fixture = try LibraryFixture()
        let location = fixture.location()
        fixture.preferences.set(value, forKey: key)
        #expect(location.root.path == location.standardLibrary.path)
    }

    @Test func aTildeCountsAsAbsolute() throws {
        let fixture = try LibraryFixture()
        fixture.preferences.set("~/Elsewhere", forKey: key)
        #expect(fixture.location().root.path == NSHomeDirectory() + "/Elsewhere")
    }

    @Test func folderChildrenBelongToTheRoot() throws {
        let fixture = try LibraryFixture()
        let location = fixture.location()
        let standard = location.standardLibrary.path
        #expect(location.root.path == standard)
        #expect(location.machines.path == standard + "/Machines")
        #expect(location.downloads.path == standard + "/Downloads")
        #expect(location.installers.path == standard + "/Installers")
    }
}

@Suite struct LibraryChoosingTests {
    @Test func onlyAnExistingFolderCanBeChosen() throws {
        let fixture = try LibraryFixture()
        let location = fixture.location()
        let file = fixture.home.appending(path: "file")
        try Data().write(to: file)
        for url in [nil, URL(string: "https://example.com/x"), file] {
            let error = libraryError { try location.select(url) }
            #expect(error?.domain == "VirtualIntelMac.Library")
            #expect(error?.code == 1)
            #expect(error?.localizedDescription == "Choose an existing folder for your Macs.")
        }
        let missing = libraryError { try location.select(fixture.home.appending(path: "missing")) }
        #expect(missing?.domain == NSCocoaErrorDomain)
        #expect(fixture.preferences.object(forKey: key) == nil)
    }

    @Test func theWriteProbeLeavesNothingBehind() throws {
        let fixture = try LibraryFixture()
        let chosen = try fixture.folder("External")
        _ = try fixture.location().select(chosen)
        let names = try FileManager.default.contentsOfDirectory(atPath: chosen.path)
        #expect(!names.contains { $0.hasPrefix(".vim-write-check-") })
    }

    @Test func aDeferredMigrationKeepsTheSelection() throws {
        let fixture = try LibraryFixture()
        let previous = try fixture.folder("Previous")
        fixture.preferences.set(previous.path, forKey: key)
        let chosen = try fixture.folder("External")
        let package = try fixture.machine("External/Mac.vintelmac")
        let error = try fixture.holding(package.appending(path: "State/Session.lock")) {
            libraryError { try fixture.location().select(chosen) }
        }
        #expect(error?.code == Int(EBUSY))
        #expect(fixture.preferences.string(forKey: key) == previous.path)
    }

    @Test func standardFoldersAppearEvenWithAnotherLibrarySelected() throws {
        let fixture = try LibraryFixture()
        fixture.preferences.set(try fixture.folder("External").path, forKey: key)
        let location = fixture.location()
        try location.createStandardFolders()
        for folder in ["Machines", "Downloads", "Installers"] {
            #expect(fixture.exists(location.standardLibrary.appending(path: folder)))
        }
        #expect(!fixture.exists(fixture.home.appending(path: "External/Machines")))
    }

    @Test func preferencesKeyedByMachinesAreAdopted() throws {
        let fixture = try LibraryFixture()
        let location = fixture.location()
        let root = location.standardLibrary.path
        let machines = root + "/Machines"
        try location.createStandardFolders()
        _ = try location.organizeSelectedLibrary()
        fixture.preferences.set(["a": 1, "b": 1], forKey: "VIMLibraryKnown-" + root)
        fixture.preferences.set(["b": 2, "c": 2], forKey: "VIMLibraryKnown-" + machines)
        fixture.preferences.set(["kept"], forKey: "VIMLibraryOrder-" + root)
        fixture.preferences.set(["dropped"], forKey: "VIMLibraryOrder-" + machines)
        fixture.preferences.set("name", forKey: "VIMLibraryArrange-" + machines)
        _ = try location.organizeSelectedLibrary()
        let known = try #require(fixture.preferences.dictionary(forKey: "VIMLibraryKnown-" + root) as? [String: Int])
        #expect(known == ["a": 1, "b": 2, "c": 2])
        #expect(fixture.preferences.stringArray(forKey: "VIMLibraryOrder-" + root) == ["kept"])
        #expect(fixture.preferences.string(forKey: "VIMLibraryArrange-" + root) == "name")
        for prefix in LibraryPreferences.rootKeyedPrefixes {
            #expect(fixture.preferences.object(forKey: prefix + machines) == nil)
        }
    }

    /// Odd, and kept: the first migration's sweep renames the Machines-keyed rows onto the root's, replacing them. Only
    /// a later launch merges.
    @Test func theFirstMigrationReplacesRootKeyedRows() throws {
        let fixture = try LibraryFixture()
        let location = fixture.location()
        let root = location.standardLibrary.path
        fixture.preferences.set(["a": 1], forKey: "VIMLibraryKnown-" + root)
        fixture.preferences.set(["b": 2], forKey: "VIMLibraryKnown-" + root + "/Machines")
        try location.createStandardFolders()
        _ = try location.organizeSelectedLibrary()
        let known = fixture.preferences.dictionary(forKey: "VIMLibraryKnown-" + root) as? [String: Int]
        #expect(known == ["b": 2])
    }

    /// Odd, and kept: Foundation lists children of `/tmp` and `/var` under `/private`, but a standardized root drops
    /// `/private`, so nothing in such a library looks like it's inside it.
    @Test func aLibraryBehindThePrivateAliasRefusesItsItems() throws {
        let fixture = try LibraryFixture()
        let temporary = URL(filePath: "/tmp/machinekit-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(
            at: temporary.appending(path: "Mac.vintelmac/State"), withIntermediateDirectories: true)
        let error = libraryError { try fixture.location().select(temporary) }
        #expect(error?.localizedDescription == "The library’s layout record contains an unexpected location.")
    }

    @Test func errorsKeepTheirDomainCodesAndCurlyQuotes() {
        let busy = LibraryLocationError.machineSettingsSaving as NSError
        #expect(busy.domain == "VirtualIntelMac.Library")
        #expect(busy.code == Int(EBUSY))
        #expect(busy.localizedDescription == "Wait for this Mac’s settings to finish saving, then try again.")
        #expect((LibraryLocationError.duplicateItem as NSError).code == 1)
    }
}
