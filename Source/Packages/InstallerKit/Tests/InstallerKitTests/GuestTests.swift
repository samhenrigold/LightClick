import Foundation
import Testing

@testable import InstallerKit

@Suite struct GuestTests {
    private static let traitNames: [String: Guest.Traits] = [
        "VIMGuestTraitOpenGLDesktop": .openGLDesktop,
        "VIMGuestTraitParavirtualizedGraphics": .paravirtualizedGraphics,
        "VIM_GUEST_CLASSIC": [
            .openGLDesktop, .restoreDVD, .noBackingScale, .windowsFileSharing, .usb2StoragePassthrough,
            .legacyTabletCalibration, .noRoundelArtwork
        ],
        "VIMGuestTraitLegacyTabletCalibration": .legacyTabletCalibration,
        "VIMGuestTraitUSB3Images": .usb3Images
    ]

    /// Until the app adopts this package, VIMGuestProfile.h is a second copy of the table. This keeps them identical.
    @Test func everyGuestMatchesTheObjectiveCProfileTable() throws {
        let header = try String(
            contentsOf: Fixture.sourceRoot.appending(path: "VirtualIntelMac/VIMGuestProfile.h"), encoding: .utf8)
        let rows = header.matches(of: /\{@"(\w+)", @"([^"]+)", @"([^"]+)", @"([^"]+)",\s*([^}]+)\}/)
        #expect(rows.map { String($0.1) } == Guest.allCases.map(\.rawValue))
        for row in rows {
            let guest = try #require(Guest(rawValue: String(row.1)))
            #expect(guest.family.rawValue == row.2)
            #expect(guest.name == row.3)
            #expect(guest.version == row.4)
            let traits = row.5.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let expected = try traits.reduce(into: Guest.Traits()) { result, name in
                result.formUnion(try #require(Self.traitNames[name], "\(name)"))
            }
            #expect(guest.traits == expected, "\(guest)")
        }
    }

    @Test func traitBitsMatchTheObjectiveCOptions() throws {
        let header = try String(
            contentsOf: Fixture.sourceRoot.appending(path: "VirtualIntelMac/VIMGuestProfile.h"), encoding: .utf8)
        let bits: [(String, Guest.Traits)] = [
            ("OpenGLDesktop", .openGLDesktop), ("ParavirtualizedGraphics", .paravirtualizedGraphics),
            ("RestoreDVD", .restoreDVD), ("NoBackingScale", .noBackingScale),
            ("WindowsFileSharing", .windowsFileSharing), ("USB2StoragePassthrough", .usb2StoragePassthrough),
            ("USB3Images", .usb3Images), ("LegacyTabletCalibration", .legacyTabletCalibration),
            ("NoRoundelArtwork", .noRoundelArtwork)
        ]
        for (name, trait) in bits {
            let shift = trait.rawValue.trailingZeroBitCount
            #expect(header.contains("VIMGuestTrait\(name) = 1 << \(shift),"), "\(name)")
        }
    }

    @Test func systemNameReadsLikeTheProduct() {
        #expect(Guest.mavericks.systemName == "OS X Mavericks 10.9")
        #expect(Guest.bigSur.systemName == "macOS Big Sur 11")
        #expect(Guest.snowLeopard.systemName == "Mac OS X Snow Leopard 10.6")
    }

    @Test func aStringOrNothingElseNamesAGuest() throws {
        #expect(Guest(rawValue: "snowleopard") == .snowLeopard)
        #expect(Guest(rawValue: "snowLeopard") == nil)
        #expect(Guest(rawValue: "") == nil)
        #expect(try JSONDecoder().decode(Guest.self, from: Data(#""mountainlion""#.utf8)) == .mountainLion)
    }
}
