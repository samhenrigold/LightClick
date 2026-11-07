import Foundation
import Testing

@testable import MachineKit

@Suite struct GuestPayloadUpdateTests {
    @Test func versionsCompareByNumber() {
        #expect(GuestPayloadUpdate.isVersion("1.10", newerThan: "1.9"))
        #expect(GuestPayloadUpdate.isVersion("2", newerThan: "1.9.9"))
        #expect(GuestPayloadUpdate.isVersion("15.0.1", newerThan: "15.0"))
        #expect(!GuestPayloadUpdate.isVersion("15.0", newerThan: "15"))
        #expect(!GuestPayloadUpdate.isVersion("1.9", newerThan: "1.10"))
        #expect(!GuestPayloadUpdate.isVersion("1.2b", newerThan: "1.1"))
        #expect(!GuestPayloadUpdate.isVersion("", newerThan: "1"))
        #expect(!GuestPayloadUpdate.isVersion("1..2", newerThan: "1"))
    }

    @Test func itOffersOnlyNewerDifferentSupport() {
        #expect(
            GuestPayloadUpdate.offersUpdate(
                preparedDigest: "A", preparedAppVersion: "15.0", bundledDigest: "B", appVersion: "15.1"))
        #expect(
            !GuestPayloadUpdate.offersUpdate(
                preparedDigest: "B", preparedAppVersion: "15.0", bundledDigest: "B", appVersion: "15.1"))
        // An older app opening a machine a newer one prepared leaves it alone.
        #expect(
            !GuestPayloadUpdate.offersUpdate(
                preparedDigest: "A", preparedAppVersion: "15.2", bundledDigest: "B", appVersion: "15.1"))
        // Prepared before the record existed.
        #expect(
            GuestPayloadUpdate.offersUpdate(
                preparedDigest: nil, preparedAppVersion: nil, bundledDigest: "B", appVersion: "15.1"))
        // Later holds until the app's support changes.
        #expect(
            !GuestPayloadUpdate.offersUpdate(
                preparedDigest: "A", preparedAppVersion: "15.0", bundledDigest: "B", appVersion: "15.1",
                declinedDigest: "B"))
        #expect(
            GuestPayloadUpdate.offersUpdate(
                preparedDigest: "A", preparedAppVersion: "15.0", bundledDigest: "C", appVersion: "15.2",
                declinedDigest: "B"))
        // A runtime that doesn't say has nothing to offer.
        #expect(
            !GuestPayloadUpdate.offersUpdate(
                preparedDigest: "A", preparedAppVersion: "15.0", bundledDigest: nil, appVersion: "15.1"))
    }

    @Test func itReadsTheRecords() throws {
        let packaging = try PropertyListSerialization.data(
            fromPropertyList: ["GuestPayloads": ["Guests": ["mojave": ["ArchiveSHA256": "B"]]]], format: .binary,
            options: 0)
        #expect(GuestPayloadUpdate.bundledDigest(packaging: packaging, guest: "mojave") == "B")
        #expect(GuestPayloadUpdate.bundledDigest(packaging: packaging, guest: "catalina") == nil)
        #expect(GuestPayloadUpdate.bundledDigest(packaging: nil, guest: "mojave") == nil)
        let journal = try PropertyListSerialization.data(
            fromPropertyList: ["PayloadSHA256": "A", "AppVersion": "15.0"], format: .binary, options: 0)
        let prepared = GuestPayloadUpdate.prepared(journal: journal)
        #expect(prepared.digest == "A" && prepared.appVersion == "15.0")
        #expect(GuestPayloadUpdate.prepared(journal: nil).digest == nil)
    }
}
