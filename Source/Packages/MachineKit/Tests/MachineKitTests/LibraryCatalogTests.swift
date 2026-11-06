import Foundation
import Testing

@testable import MachineKit

@Suite struct LibraryCatalogTests {
    @Test func aRecordRoundTripsAndWrongTypesReadAsMissing() {
        let saved: [String: Any] = ["Name": "A", "Guest": "lion", "Identifier": "i"]
        let record = LibraryRecord(foundationObject: saved)
        #expect(record == LibraryRecord(name: "A", guest: "lion", identifier: "i"))
        #expect(record.foundationObject == ["Name": "A", "Guest": "lion", "Identifier": "i"])
        #expect(LibraryRecord(foundationObject: ["Name": 1]).name == nil)
        #expect(LibraryRecord(foundationObject: nil).foundationObject == [:])
    }

    @Test func everyKnownRegisteredAndFoundPathIsTriedOnce() {
        let paths = LibraryCatalog.candidatePaths(
            known: ["/a": LibraryRecord(name: nil, guest: nil)], registered: ["/a", "/b"], inFolder: ["/c"])
        #expect(paths == ["/a", "/b", "/c"])
    }

    @Test func onlyPackagesCount() {
        #expect(LibraryCatalog.isPackage(URL(fileURLWithPath: "/x/A.VIntelMac")))
        #expect(!LibraryCatalog.isPackage(URL(fileURLWithPath: "/x/A.txt")))
    }

    @Test func aRenamedPackageIsNotLost() {
        let known = ["/old.vintelmac": LibraryRecord(name: "Old", guest: "lion", identifier: "i")]
        let new = LibraryPackage(
            path: "/new.vintelmac", record: LibraryRecord(name: "New", guest: "lion", identifier: "i"))
        let result = LibraryCatalog.reconcile(loaded: [new], missing: ["/old.vintelmac"], known: known)
        #expect(result.unavailable.isEmpty)
        #expect(Array(result.catalog.keys) == ["/new.vintelmac"])
    }

    @Test func aMissingPackageKeepsWhatWasKnown() {
        let record = LibraryRecord(name: "Old", guest: "lion", identifier: "i")
        let result = LibraryCatalog.reconcile(
            loaded: [], missing: ["/x/old.vintelmac"], known: ["/x/old.vintelmac": record])
        #expect(result.unavailable == [UnavailableLibraryRow(path: "/x/old.vintelmac", name: "Old", guest: "lion")])
        #expect(result.catalog["/x/old.vintelmac"] == record)
    }

    @Test func anUnknownMissingPackageIsNamedAfterItsFile() {
        let result = LibraryCatalog.reconcile(loaded: [], missing: ["/x/My Mac.vintelmac"], known: [:])
        #expect(result.unavailable == [UnavailableLibraryRow(path: "/x/My Mac.vintelmac", name: "My Mac", guest: "")])
        #expect(result.catalog["/x/My Mac.vintelmac"] == LibraryRecord(name: "My Mac", guest: ""))
    }

    private struct Row: Equatable {
        var path: String
        var name: String
    }

    @Test func savedOrderComesFirstThenNames() {
        let rows = [
            Row(path: "/a", name: "Zed"), Row(path: "/b", name: "Mac 10"), Row(path: "/c", name: "Mac 9"),
            Row(path: "/d", name: "Q")
        ]
        let sorted = LibraryOrder.sorted(rows, savedOrder: ["/d", "/a"], path: \.path, name: \.name)
        #expect(sorted.map(\.path) == ["/d", "/a", "/c", "/b"])
    }

    @Test func movingPlacesARowBeforeAnotherOrLast() {
        #expect(LibraryOrder.moved(["a", "b", "c"], moving: "c", before: "a") == ["c", "a", "b"])
        #expect(LibraryOrder.moved(["a", "b", "c"], moving: "a", before: "c") == ["b", "a", "c"])
        #expect(LibraryOrder.moved(["a", "b", "c"], moving: "a", before: nil) == ["b", "c", "a"])
        #expect(LibraryOrder.moved(["a", "b"], moving: "a", before: "gone") == ["b", "a"])
    }

    @Test func savedArrangementNames() {
        #expect(LibraryArrangement(savedName: nil) == .none)
        #expect(LibraryArrangement(savedName: "None") == .none)
        #expect(LibraryArrangement(savedName: "Size") == .size)
        #expect(LibraryArrangement(savedName: "Date Created") == .dateCreated)
        #expect(LibraryArrangement(savedName: "Name") == .name)
        #expect(LibraryArrangement(savedName: "Anything else") == .name)
    }

    private func arranged(_ arrangement: LibraryArrangement, _ values: [(String, LibraryArrangement.Value)]) -> [String]
    {
        let table = Dictionary(uniqueKeysWithValues: values)
        return arrangement.sorted(values.map(\.0), value: { table[$0]! }, name: { $0 })
    }

    @Test func noArrangementKeepsTheOrder() {
        #expect(arranged(.none, [("b", .text("1")), ("a", .text("0"))]) == ["b", "a"])
    }

    @Test func textGoesUpAndATieGoesByName() {
        #expect(arranged(.type, [("b", .text("x")), ("a", .text("x")), ("c", .text("w"))]) == ["c", "a", "b"])
        #expect(arranged(.name, [("Mac 10", .text("Mac 10")), ("Mac 9", .text("Mac 9"))]) == ["Mac 9", "Mac 10"])
    }

    @Test func datesAndSizesGoLargestFirstAndTiesStillByName() {
        let early = Date(timeIntervalSince1970: 1)
        let late = Date(timeIntervalSince1970: 2)
        #expect(arranged(.dateCreated, [("old", .date(early)), ("new", .date(late))]) == ["new", "old"])
        #expect(
            arranged(.size, [("s", .size(1)), ("l", .size(2)), ("b", .size(1)), ("a", .size(2))]) == [
                "a", "l", "b", "s"
            ])
    }

    private let english = Locale(identifier: "en_US")

    @Test func resourcesAreInCPUMemoryAndStorage() {
        #expect(
            LibraryRowText.resources(cpuCount: 4, memoryMiB: 8192, diskBytes: 64 << 30, locale: english)
                == "4 CPU · 8 GB RAM · 64 GB")
        #expect(
            LibraryRowText.resources(cpuCount: 2, memoryMiB: 1536, diskBytes: 0, locale: english)
                == "2 CPU · 1.5 GB RAM · Storage unavailable")
    }

    @Test func aPreMetalMacContinuesSetupByItsInstallStateAlone() {
        #expect(!LibraryRowText.continuesSetup(preMetalGuest: true, installState: nil, requiresInstallerDisplay: true))
        #expect(
            !LibraryRowText.continuesSetup(
                preMetalGuest: true, installState: "installed", requiresInstallerDisplay: true))
        #expect(
            LibraryRowText.continuesSetup(
                preMetalGuest: true, installState: "installing", requiresInstallerDisplay: false))
        #expect(
            LibraryRowText.continuesSetup(
                preMetalGuest: false, installState: "installed", requiresInstallerDisplay: true))
        #expect(
            !LibraryRowText.continuesSetup(
                preMetalGuest: false, installState: "installing", requiresInstallerDisplay: false))
    }

    @Test func aRowWithNoArtworkShowsTiger() {
        let assets: Set<String> = ["lionWallpaper", "tigerWallpaper"]
        #expect(LibraryRowText.wallpaperName(guest: "lion", isAvailable: assets.contains) == "lionWallpaper")
        #expect(LibraryRowText.wallpaperName(guest: "", isAvailable: assets.contains) == "tigerWallpaper")
        #expect(LibraryRowText.wallpaperName(guest: "unknown", isAvailable: assets.contains) == "tigerWallpaper")
    }

    @Test func aMissingMachinesFolderIsOnlyEmptyWhereTheLibraryIsThere() {
        func unavailable(failed: Bool = true, missing: Bool = true, root: Bool, standard: Bool = false) -> Bool {
            LibraryNotice.libraryIsUnavailable(
                readFailed: failed, machinesFolderMissing: missing, rootExists: root, isStandardLibrary: standard)
        }
        #expect(!unavailable(failed: false, missing: false, root: true))
        #expect(!unavailable(root: true), "A connected library with nothing in it yet.")
        #expect(!unavailable(root: false, standard: true), "A first launch.")
        #expect(unavailable(root: false), "A disconnected drive.")
        #expect(unavailable(missing: false, root: true), "A folder there's no permission to read.")
        #expect(unavailable(missing: false, root: true, standard: true))
    }

    @Test func theNoticeSaysTheMostImportantThing() {
        #expect(LibraryNotice.text(libraryUnavailable: false, unavailableCount: 0) == nil)
        #expect(
            LibraryNotice.text(libraryUnavailable: false, unavailableCount: 1)?.hasPrefix("1 Mac package needs") == true
        )
        #expect(
            LibraryNotice.text(libraryUnavailable: false, unavailableCount: 3)?.hasPrefix("3 Mac packages need") == true
        )
        #expect(
            LibraryNotice.text(libraryUnavailable: true, unavailableCount: 3)?.hasPrefix("Library unavailable") == true)
    }

    @Test func aRowsActionGoesByWhatItsMacCanDo() {
        #expect(LibraryRowText.action(unavailable: true, running: true, continuingSetup: true) == "Locate")
        #expect(LibraryRowText.action(unavailable: false, running: true, continuingSetup: true) == "Show")
        #expect(LibraryRowText.action(unavailable: false, running: false, continuingSetup: true) == "Continue Setup")
        #expect(LibraryRowText.action(unavailable: false, running: false, continuingSetup: false) == "Start")
    }

    @Test func aSmallLibraryFitsAndALargeOneScrolls() {
        #expect(LibraryWindowLayout.rowsHeight(count: 0, compact: false) == 126)
        #expect(LibraryWindowLayout.rowsHeight(count: 3, compact: true) == 189)
        #expect(LibraryWindowLayout.automaticHeight(rowsHeight: 252, availableHeight: 1000) == 252)
        #expect(LibraryWindowLayout.automaticHeight(rowsHeight: 2000, availableHeight: 1000) == 640)
        #expect(LibraryWindowLayout.automaticHeight(rowsHeight: 2000, availableHeight: 500) == 400)
        #expect(LibraryWindowLayout.automaticHeight(rowsHeight: 2000, availableHeight: 100) == 126)
    }

    @Test func zoomFitsTheLongestTitleWithinLimits() {
        #expect(LibraryWindowLayout.standardWidth(titleWidth: 10, compact: false, visibleWidth: 2000) == 540)
        #expect(LibraryWindowLayout.standardWidth(titleWidth: 300, compact: false, visibleWidth: 2000) == 590)
        #expect(LibraryWindowLayout.standardWidth(titleWidth: 300, compact: true, visibleWidth: 2000) == 540)
        #expect(LibraryWindowLayout.standardWidth(titleWidth: 900, compact: false, visibleWidth: 2000) == 800)
        #expect(LibraryWindowLayout.standardWidth(titleWidth: 900, compact: false, visibleWidth: 700) == 700)
    }
}
