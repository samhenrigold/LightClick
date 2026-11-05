import Foundation
import Testing

@testable import InstallerKit

private func isRejected(_ change: (NSMutableDictionary) -> Void) throws -> Bool {
    (try? InstallerCatalog(data: Fixture.catalog(change))) == nil
}

@Suite struct InstallerCatalogTests {
    private static let valid = "A".padding(toLength: 64, withPad: "A", startingAt: 0)

    @Test func theBundledCatalogHasThirteenGuestsInChronologicalOrder() throws {
        let catalog = try InstallerCatalog(data: Fixture.catalogData)
        #expect(catalog.installers.map(\.guest) == Guest.allCases)
        #expect(catalog.revision == 8)
        #expect(catalog.installers.allSatisfy { $0.recipe == $0.guest.recipe })
        #expect(catalog.file(for: .mavericks, role: .esd)?.sha256 != nil)
        #expect(catalog.file(for: .tiger, role: .esd) == nil)
    }

    @Test func rejectsAnEmptyOrOversizedCatalog() throws {
        #expect((try? InstallerCatalog(data: Data())) == nil)
        #expect((try? InstallerCatalog(data: Data(count: 262145))) == nil)
        #expect(throws: CatalogError.self) { try InstallerCatalog(data: Data(count: 262145)) }
    }

    @Test func rejectsMalformedPropertyLists() throws {
        #expect((try? InstallerCatalog(data: Data("bad".utf8))) == nil)
        let array = try PropertyListSerialization.data(fromPropertyList: ["x"], format: .xml, options: 0)
        #expect((try? InstallerCatalog(data: array)) == nil)
    }

    @Test(arguments: [true, 0, -1, 1.5, "2", 9_223_372_036_854_775_808 as UInt64, UInt64.max] as [any Sendable])
    func revisionMustBeAPositiveIntegerThatFitsAnInt(_ invalid: any Sendable) throws {
        #expect((try? InstallerCatalog(data: Fixture.catalog(revision: invalid))) == nil)
    }

    @Test func revisionMayBeTheLargestInt() throws {
        #expect(try InstallerCatalog(data: Fixture.catalog(revision: Int.max)).revision == Int.max)
    }

    @Test func formatVersionMustEqualOne() throws {
        #expect(try isRejected { $0["FormatVersion"] = 2 })
        #expect(try isRejected { $0["FormatVersion"] = "1" })
        #expect(try isRejected { $0["FormatVersion"] = nil })
        // Numerically equal plist types are what the Objective-C reader accepted.
        #expect(try !isRejected { $0["FormatVersion"] = 1.0 })
        #expect(try !isRejected { $0["FormatVersion"] = true })
    }

    @Test func installersMustCoverEachGuestExactlyOnce() throws {
        #expect(try isRejected { ($0["Installers"] as? NSMutableArray)?.removeLastObject() })
        #expect(
            try isRejected { plist in
                let installers = plist["Installers"] as? NSMutableArray
                installers?.replaceObject(at: 1, with: installers?[0] as Any)
            })
        #expect(
            try isRejected { plist in
                let installers = plist["Installers"] as? NSMutableArray
                for _ in 0..<4 { installers?.add(installers?[0] as Any) }
            })
        #expect(try isRejected { ($0["Installers"] as? NSMutableArray)?[0] = "tiger" })
        #expect(try isRejected { Fixture.entry($0, .tiger)["Guest"] = "panther" })
        #expect(try isRejected { Fixture.entry($0, .tiger)["Guest"] = 7 })
        #expect(try isRejected { $0["Installers"] = "tiger" })
    }

    @Test func nameAndVersionAreBounded() throws {
        #expect(try isRejected { Fixture.entry($0, .lion)["Name"] = "" })
        #expect(try isRejected { Fixture.entry($0, .lion)["Name"] = String(repeating: "x", count: 81) })
        #expect(try isRejected { Fixture.entry($0, .lion)["Name"] = 1 })
        #expect(try !isRejected { Fixture.entry($0, .lion)["Name"] = String(repeating: "x", count: 80) })
        #expect(try isRejected { Fixture.entry($0, .lion)["Version"] = String(repeating: "1", count: 31) })
        #expect(try isRejected { Fixture.entry($0, .lion)["Version"] = nil })
        #expect(try !isRejected { Fixture.entry($0, .lion)["Version"] = "" })
    }

    @Test func aRemoteCatalogCannotChooseAnotherRecipe() throws {
        #expect(try isRejected { Fixture.entry($0, .bigSur)["Assembly"] = "split-legacy" })
        #expect(try isRejected { Fixture.entry($0, .bigSur)["Assembly"] = "/bin/sh" })
        #expect(try isRejected { Fixture.entry($0, .bigSur)["Assembly"] = nil })
    }

    @Test func filesMustBeExactlyTheRecipesRoles() throws {
        #expect(try isRejected { Fixture.files($0, .mojave).removeLastObject() })
        #expect(try isRejected { Fixture.file($0, .mojave)["Role"] = "esd" })
        #expect(try isRejected { Fixture.file($0, .lion)["Role"] = "installer" })
        #expect(try isRejected { Fixture.file($0, .lion)["Role"] = nil })
        #expect(try isRejected { Fixture.entry($0, .lion)["Files"] = "x" })
        #expect(try isRejected { Fixture.files($0, .lion)[0] = "x" })
    }

    @Test func fileURLsMustPassTheSourcePolicyAndTheirRecipesHost() throws {
        #expect(try isRejected { Fixture.file($0, .tiger)["URL"] = "https://example.org/untrusted.pkg" })
        #expect(try isRejected { Fixture.file($0, .tiger)["URL"] = 1 })
        #expect(
            try isRejected {
                Fixture.file($0, .lion)["URL"] = "https://archive.org/download/a/InstallMacOSX.dmg"
            })
        #expect(
            try isRejected {
                Fixture.file($0, .tiger)["URL"] = "https://updates.cdn-apple.com/2019/InstallOS.dmg"
            })
        #expect(try isRejected { Fixture.file($0, .mavericks)["URL"] = "https://archive.org/download/a/b.dmg" })
    }

    @Test func digestsAreSixtyFourHexCharacters() throws {
        #expect(try isRejected { Fixture.file($0, .tiger)["SHA256"] = "" })
        #expect(try isRejected { Fixture.file($0, .tiger)["SHA256"] = String(Self.valid.dropFirst()) })
        #expect(try isRejected { Fixture.file($0, .tiger)["SHA256"] = "G" + Self.valid.dropFirst() })
        #expect(try isRejected { Fixture.file($0, .tiger)["SHA256"] = 1 })
        #expect(try !isRejected { Fixture.file($0, .tiger)["SHA256"] = Self.valid.lowercased() })
    }

    @Test func theRecoveryPayloadMustHaveADigest() throws {
        #expect(try isRejected { Fixture.file($0, .mavericks)["SHA256"] = nil })
    }

    @Test func unknownKeysAreIgnored() throws {
        #expect(try !isRejected { $0["Comment"] = "x" })
        #expect(try !isRejected { Fixture.entry($0, .lion)["Comment"] = "x" })
        #expect(try !isRejected { Fixture.file($0, .lion)["Comment"] = "x" })
    }

    @Test func aDigestIsTheSameInEitherCase() {
        #expect(PayloadDigest(hexadecimal: Self.valid.lowercased()) == PayloadDigest(hexadecimal: Self.valid))
    }

    @Test func equalRevisionsKeepTheBaseline() throws {
        let older = try InstallerCatalog(data: Fixture.catalog(revision: 8))
        let newer = try InstallerCatalog(data: Fixture.catalog(revision: 9))
        #expect(InstallerCatalog.preferred(newer, over: older) == newer)
        #expect(InstallerCatalog.preferred(older, over: newer) == newer)
        #expect(InstallerCatalog.preferred(nil, over: older) == older)
        #expect(InstallerCatalog.preferred(older, over: nil) == older)
        let edited = try InstallerCatalog(
            data: Fixture.catalog {
                $0["Revision"] = 8
                Fixture.entry($0, .lion)["Name"] = "Edited"
            })
        #expect(InstallerCatalog.preferred(edited, over: older) == older)
    }

    @Test func restoreImagesCannotBeInterchanged() throws {
        let catalog = try InstallerCatalog(data: Fixture.catalogData)
        let tiger = try #require(catalog.file(for: .tiger, role: .diskImage)?.url)
        let leopard = try #require(URL(string: "https://archive.org/download/10.5.7-9-j-3050/10.5.7-9J3050.dmg"))
        let snow = try #require(catalog.file(for: .snowLeopard, role: .diskImage)?.url)
        #expect(InstallerSource.isApproved(tiger) && catalog.isRestoreDVDAsset(tiger, for: .tiger))
        #expect(!catalog.isRestoreDVDAsset(tiger, for: .leopard))
        #expect(catalog.isRestoreDVDAsset(snow, for: .snowLeopard))
        #expect(InstallerSource.isApproved(leopard) && catalog.isRestoreDVDAsset(leopard, for: .leopard))
        #expect(
            !catalog.isRestoreDVDAsset(leopard, for: .snowLeopard) && !catalog.isRestoreDVDAsset(snow, for: .leopard))
        let other = try #require(URL(string: "https://archive.org/download/10.5.7-9-j-3050/other.dmg"))
        #expect(!catalog.isRestoreDVDAsset(other, for: .leopard))
    }

    @Test func errorsKeepTheirObjectiveCIdentity() {
        let error = CatalogError.invalid as NSError
        #expect(error.domain == "VirtualIntelMac.Installers")
        #expect(error.code == 1)
        #expect(error.localizedDescription == "The installer catalog is invalid or incompatible.")
    }
}
