import Foundation
import Testing

@testable import MachineKit

@Suite struct LibraryMovesTests {
    private let overlap = LibraryMoves(destinations: [
        "/test/Downloads": "/new/Downloads", "/test/Downloads/Preparation": "/new/Installers"
    ])

    @Test func theLongestMovedAncestorWins() {
        #expect(overlap.relocated("/test/Downloads/Preparation/id/Media/file") == "/new/Installers/id/Media/file")
        #expect(overlap.relocated("/test/Downloads/file") == "/new/Downloads/file")
        #expect(overlap.relocated("/test/Downloads") == "/new/Downloads")
    }

    @Test func aSiblingSharingAPrefixStays() {
        #expect(overlap.relocated("/test/Downloads2/file") == "/test/Downloads2/file")
        #expect(overlap.relocated("x/test/Downloads") == "x/test/Downloads")
    }

    @Test func pathsCompareLiterallyNotCanonically() {
        let moves = LibraryMoves(destinations: ["/é": "/moved"])
        #expect(moves.relocated("/e\u{301}/file") == "/e\u{301}/file")
    }

    @Test func nestedMovesRunFirstAndTiesAreRepeatable() {
        #expect(overlap.physicalOrder == ["/test/Downloads/Preparation", "/test/Downloads"])
        #expect(LibraryMoves(destinations: ["/b": "/x", "/a": "/y"]).physicalOrder == ["/a", "/b"])
    }

    @Test func valuesAndKeysMoveAndOtherTypesKeepTheirForm() throws {
        let date = Date(timeIntervalSince1970: 1)
        let value: PropertyListValue = [
            "/test/Downloads/k": "/test/Downloads/v", "number": 1, "flag": true, "date": .date(date),
            "data": .data(Data([1])), "list": ["/test/Downloads", 2]
        ]
        let relocated = try #require(overlap.relocated(value).dictionary)
        #expect(relocated["/new/Downloads/k"] == .string("/new/Downloads/v"))
        #expect(relocated["flag"] == true)
        #expect(relocated["date"] == .date(date))
        #expect(relocated["list"] == ["/new/Downloads", 2])
        let flag = try #require(relocated["flag"]?.number)
        #expect(CFGetTypeID(flag) == CFBooleanGetTypeID())
    }
}

@Suite struct LibraryMigrationTests {
    /// The old native probe's scenario: deferred while busy, then moved, rewritten and idempotent.
    @Test func aBusyMachineDefersThenEverythingMovesOnce() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        let attempt = UUID().uuidString + "/Media/Installer.img"
        let media = root.appending(path: "Downloads/Preparation/" + attempt)
        try FileManager.default.createDirectory(
            at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("fixture disk, not a VM".utf8)
        try bytes.write(to: media)
        let identifier = UUID().uuidString
        let machine = try fixture.machine(
            "Library/Test.vintelmac", plist: ["InstallerMedia": media.path], identifier: identifier)
        let migration = fixture.migration(root: root)

        let busy = try fixture.holding(machine.appending(path: "State/Session.lock")) {
            libraryError { try migration.run() }
        }
        #expect(busy?.code == Int(EBUSY))
        #expect(fixture.exists(machine) && !migration.isComplete)

        let relocations = try migration.run()
        let newMachine = root.appending(path: "Machines/Test.vintelmac")
        let newMedia = root.appending(path: "Installers/" + attempt)
        #expect(relocations.count == 1)
        #expect(relocations.first?.oldURL.path == machine.path)
        #expect(relocations.first?.url.path == newMachine.path)
        #expect(relocations.first?.identifier == identifier)
        let config = try #require(NSDictionary(contentsOf: newMachine.appending(path: "Machine.plist")))
        #expect(config["InstallerMedia"] as? String == newMedia.path)
        #expect(try Data(contentsOf: newMedia) == bytes)
        #expect(!fixture.exists(machine) && migration.isComplete)
        #expect(try migration.run().isEmpty)
        #expect(fixture.exists(root.appending(path: "Downloads")))
    }

    @Test func theStandardLibraryMovesOutOfItsOldMachinesRoot() throws {
        let fixture = try LibraryFixture()
        let location = fixture.location()
        let root = location.standardLibrary
        let machine = try fixture.machine("Support/Light Click/Machines/Mac.vintelmac")
        let file = root.appending(path: "Machines/Downloads/file")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        #expect(try location.organizeSelectedLibrary().isEmpty)
        #expect(fixture.exists(machine))
        #expect(fixture.exists(root.appending(path: "Downloads/file")))
    }

    @Test func aHeldConfigurationLockAlsoDefersWithItsOwnMessage() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        let machine = try fixture.machine("Library/Machines/Mac.vintelmac")
        let error = try fixture.holding(machine.appending(path: "State/Configuration.lock")) {
            libraryError { try fixture.migration(root: root).run() }
        }
        #expect(error?.code == Int(EBUSY))
        #expect(error?.localizedDescription == "Wait for this Mac’s settings to finish saving, then try again.")
    }

    /// Odd, and kept: no State folder means no lock can be created, which reads as a running Mac, forever.
    @Test func aPackageWithoutStateLooksRunning() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        _ = try fixture.folder("Library/Bare.vintelmac")
        let error = libraryError { try fixture.migration(root: root).run() }
        #expect(error?.code == Int(EBUSY))
        #expect(
            error?.localizedDescription == "The library will be organized after all its virtual Macs have shut down.")
    }

    @Test func aSymlinkOrHardLinkedLockIsNotALock() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        let machine = try fixture.machine("Library/Machines/Mac.vintelmac")
        let elsewhere = fixture.home.appending(path: "elsewhere")
        try Data().write(to: elsewhere)
        let lock = machine.appending(path: "State/Session.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: elsewhere)
        #expect(libraryError { try fixture.migration(root: root).run() }?.code == Int(EBUSY))
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.linkItem(at: elsewhere, to: lock)
        #expect(libraryError { try fixture.migration(root: root).run() }?.code == Int(EBUSY))
    }

    @Test func anotherCopyHoldingTheLayoutLockDefers() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        let error = try fixture.holding(root.appending(path: ".LibraryLayout.lock")) {
            libraryError { try fixture.migration(root: root).run() }
        }
        #expect(error?.code == Int(EBUSY))
        #expect(error?.localizedDescription.hasPrefix("Another copy of Light Click") == true)
    }

    @Test(arguments: ["downloading", "preparing", "creating", "stopping"])
    func anActiveCreationJobDefers(phase: String) throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        // Old jobs saved the Machines child, and it must still mean this library.
        fixture.preferences.set(
            ["Library": root.appending(path: "Machines").path, "Phase": phase], forKey: "VIMCreationJob")
        #expect(libraryError { try fixture.migration(root: root).run() }?.code == Int(EBUSY))
    }

    @Test func anotherLibrarysJobOrAFinishedOneDoesNotDefer() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        fixture.preferences.set(["Library": "/elsewhere", "Phase": "creating"], forKey: "VIMCreationJob")
        _ = try fixture.migration(root: root).run()
        let other = try fixture.folder("Other")
        fixture.preferences.set(["Library": other.path, "Phase": "failed"], forKey: "VIMCreationJob")
        _ = try fixture.migration(root: other).run()
        let malformed = try fixture.folder("Malformed")
        fixture.preferences.set(["Library": 1, "Phase": "creating"], forKey: "VIMCreationJob")
        _ = try fixture.migration(root: malformed).run()
    }

    private func saveJournal(_ fixture: LibraryFixture, root: URL, _ record: [String: Any]) throws {
        try fixture.write(record, to: root.appending(path: ".LibraryLayoutMigration.plist"))
    }

    @Test func anInterruptedRunResumesFromItsSavedPlan() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        let done = try fixture.machine("Library/Machines/Done.vintelmac", identifier: "done")
        let left = try fixture.machine("Library/Left.vintelmac")
        // A package in no plan stays put on a resume, where a fresh plan would have moved it.
        let unplanned = try fixture.machine("Library/Unplanned.vintelmac")
        try saveJournal(
            fixture, root: root,
            [
                "FormatVersion": 1, "Legacy": root.path,
                "Moves": [
                    root.appending(path: "Done.vintelmac").path: done.path,
                    left.path: root.appending(path: "Machines/Left.vintelmac").path
                ]
            ])
        let relocations = try fixture.migration(root: root).run()
        #expect(fixture.exists(root.appending(path: "Machines/Left.vintelmac")))
        #expect(fixture.exists(unplanned))
        #expect(relocations.count == 2)
    }

    /// Odd, and kept: a damaged journal is forgotten rather than refused, so its plan is rebuilt from the disk.
    @Test func aJournalThatDoesNotParseIsPlannedAgain() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        try fixture.machine("Library/Mac.vintelmac")
        try Data("not a plist".utf8).write(to: root.appending(path: ".LibraryLayoutMigration.plist"))
        _ = try fixture.migration(root: root).run()
        #expect(fixture.exists(root.appending(path: "Machines/Mac.vintelmac")))
    }

    @Test func aJournalThatParsesButIsWrongRefuses() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        let unreadable = "The library’s layout record is unreadable. Its files have not been removed."
        let invalid = "The library’s layout record is invalid."
        let unexpected = "The library’s layout record contains an unexpected location."
        let inside = root.appending(path: "a.vintelmac").path
        let new = root.appending(path: "Machines/a.vintelmac").path
        let empty: [String: String] = [:]
        let cases: [([String: Any], String)] = [
            (["FormatVersion": 2, "Legacy": root.path, "Moves": empty], unreadable),
            (["FormatVersion": 1, "Legacy": "/other", "Moves": empty], unreadable),
            (["FormatVersion": 1, "Legacy": root.path, "Moves": "x"], unreadable),
            (["FormatVersion": 1, "Legacy": root.path, "Moves": [inside: 1]], invalid),
            (["FormatVersion": 1, "Legacy": root.path, "Moves": ["/etc/passwd": new]], unexpected),
            (["FormatVersion": 1, "Legacy": root.path, "Moves": [inside: "/tmp/stolen"]], unexpected),
            (["FormatVersion": 1, "Legacy": root.path, "Moves": [root.path + "2/x": new]], unexpected)
        ]
        for (record, message) in cases {
            try saveJournal(fixture, root: root, record)
            let error = libraryError { try fixture.migration(root: root).run() }
            #expect(error?.code == 1)
            #expect(error?.localizedDescription == message)
        }
    }

    @Test func aMoveNeverOverwritesAndNeverGuesses() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        let package = try fixture.machine("Library/Mac.vintelmac")
        let keep = try fixture.machine("Library/Machines/Mac.vintelmac", identifier: "keep")
        let duplicate = libraryError { try fixture.migration(root: root).run() }
        #expect(duplicate?.localizedDescription.hasPrefix("Two library items") == true)
        #expect(fixture.exists(package))
        #expect(NSDictionary(contentsOf: keep.appending(path: "Machine.plist"))?["Identifier"] as? String == "keep")

        let other = try fixture.folder("Other")
        try saveJournal(
            fixture, root: other,
            [
                "FormatVersion": 1, "Legacy": other.path,
                "Moves": [other.appending(path: "gone").path: other.appending(path: "Machines/gone").path]
            ])
        let missing = libraryError { try fixture.migration(root: other).run() }
        #expect(missing?.localizedDescription.hasPrefix("A library item is missing") == true)
    }

    @Test func onlyAMachinesVisiblePropertyListsAreRewritten() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        let old = try fixture.machine("Library/Mac.vintelmac")
        let new = root.appending(path: "Machines/Mac.vintelmac")
        try FileManager.default.createDirectory(
            at: old.appending(path: "Installation/Deep"), withIntermediateDirectories: true)
        let plist = ["Path": old.appending(path: "Disk").path]
        try fixture.write(plist, to: old.appending(path: "Installation/Deep/Record.plist"), format: .xml)
        try fixture.write(plist, to: old.appending(path: "State/.Hidden.plist"), format: .xml)
        try fixture.write(plist, to: old.appending(path: "State/Other.txt"), format: .xml)
        try fixture.write(["Path": "/unrelated"], to: old.appending(path: "State/Unrelated.plist"), format: .xml)
        let unrelated = try Data(contentsOf: old.appending(path: "State/Unrelated.plist"))

        _ = try fixture.migration(root: root).run()

        let record = new.appending(path: "Installation/Deep/Record.plist")
        #expect(NSDictionary(contentsOf: record)?["Path"] as? String == new.appending(path: "Disk").path)
        #expect(try Data(contentsOf: record).starts(with: Data("bplist".utf8)), "A rewrite saves the binary format")
        #expect(
            NSDictionary(contentsOf: new.appending(path: "State/.Hidden.plist"))?["Path"] as? String == plist["Path"])
        #expect(!(try Data(contentsOf: new.appending(path: "State/Other.txt"))).starts(with: Data("bplist".utf8)))
        #expect(try Data(contentsOf: new.appending(path: "State/Unrelated.plist")) == unrelated)
    }

    @Test func preferencesFollowTheMoves() throws {
        let fixture = try LibraryFixture()
        let previous = try fixture.folder("Previous")
        let root = try fixture.folder("Library")
        let oldMac = previous.appending(path: "Mac.vintelmac")
        let newMac = root.appending(path: "Machines/Mac.vintelmac")
        try fixture.machine("Previous/Mac.vintelmac")
        let preferences = fixture.preferences
        preferences.set(oldMac.path + "/Disk", forKey: "VIMSomePath")
        preferences.set(oldMac.path + "/Disk", forKey: "OtherPrefix")
        preferences.set("gem", forKey: "VIMGuestUsername-" + oldMac.path)
        preferences.set(["x": 1], forKey: "VIMLibraryKnown-" + previous.path)
        preferences.set(["Library": previous.path, "Phase": "failed"], forKey: "VIMCreationJob")

        _ = try fixture.migration(root: root, previous: previous).run()

        #expect(preferences.string(forKey: "VIMSomePath") == newMac.path + "/Disk")
        #expect(preferences.string(forKey: "OtherPrefix") == oldMac.path + "/Disk")
        #expect(preferences.string(forKey: "VIMGuestUsername-" + newMac.path) == "gem")
        #expect(preferences.object(forKey: "VIMGuestUsername-" + oldMac.path) == nil)
        #expect(preferences.dictionary(forKey: "VIMLibraryKnown-" + root.path) != nil)
        #expect(preferences.object(forKey: "VIMLibraryKnown-" + previous.path) == nil)
        #expect(preferences.dictionary(forKey: "VIMCreationJob")?["Library"] as? String == root.path)
    }

    @Test func aMachineWithoutAnIdentifierMovesSilently() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        let state = try fixture.folder("Library/Mac.vintelmac/State")
        try fixture.write(["Name": "x"], to: state.deletingLastPathComponent().appending(path: "Machine.plist"))
        #expect(try fixture.migration(root: root).run().isEmpty)
        #expect(fixture.exists(root.appending(path: "Machines/Mac.vintelmac")))
    }

    @Test func aFormatTwoMarkerShortCircuitsAndOtherMarkersDont() throws {
        let fixture = try LibraryFixture()
        let root = try fixture.folder("Library")
        let marker = root.appending(path: ".VirtualIntelMacLibrary.plist")
        try fixture.write(["FormatVersion": 2.0], to: marker)
        let package = try fixture.machine("Library/Mac.vintelmac")
        #expect(try fixture.migration(root: root).run().isEmpty)
        #expect(fixture.exists(package))
        try fixture.write(["FormatVersion": "2"], to: marker)
        #expect(try fixture.migration(root: root).run().count == 1)
    }
}
