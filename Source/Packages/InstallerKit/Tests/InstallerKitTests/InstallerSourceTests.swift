import Foundation
import Testing

@testable import InstallerKit

@Suite struct InstallerSourcePolicyTests {
    /// Every row was produced by running VIMInstallerSource.m on the same string.
    @Test(arguments: [
        "https://archive.org/download/a/b.dmg",
        "https://dn720202.ca.archive.org/0/items/a/b%2C1.dmg",
        "https://archive.org:/download/a/b.dmg",
        "https://archive.org/%64ownload/a/b.dmg",
        "https://archive.org/download%2Fa/b.dmg",
        "https://archive.org/download/a/b.dmg/",
        "https://archive.org/download/a/b%2Edmg",
        "https://archive.org/download/a b.dmg",
        "https://swcdn.apple.com/content/downloads/a/b.pkg",
        "https://swcdn.apple.com/content/downloads/a/b.pkg/",
        "https://updates.cdn-apple.com/2019/InstallOS.dmg",
        "https://updates.cdn-apple.com/InstallMacOSX.dmg",
        "https://updates.cdn-apple.com/2019/InstallOS.dmg/",
        "https://updates.cdn-apple.com/2019/Install%4FS.dmg",
        "http://oscdn.apple.com/content/downloads/33/OSInstaller/InstallESD.dmg",
        "http://oscdn.apple.com/content/downloads/InstallESD.dmg/"
    ])
    func approves(_ text: String) throws {
        #expect(InstallerSource.isApproved(try #require(URL(string: text))))
    }

    /// Every row was produced by running VIMInstallerSource.m on the same string.
    @Test(arguments: [
        "https://archive.org/download/a/b.DMG",
        "https://archive.org/details/a/b.dmg",
        "https://evilarchive.org/download/a/b.dmg",
        "https://archive.org.evil.com/download/a/b.dmg",
        "https://ARCHIVE.org/download/a/b.dmg",
        "HTTPS://archive.org/download/a/b.dmg",
        "http://archive.org/download/a/b.dmg",
        "https://archive.org/download/a/b.dmg?",
        "https://archive.org/download/a/b.dmg?x=1",
        "https://archive.org/download/a/b.dmg#",
        "https://archive.org/download/a/b.dmg#f",
        "https://@archive.org/download/a/b.dmg",
        "https://u@archive.org/download/a/b.dmg",
        "https://u:p@archive.org/download/a/b.dmg",
        "https://:p@archive.org/download/a/b.dmg",
        "https://archive.org:443/download/a/b.dmg",
        "https://archive.org%2Fevil.com/download/a/b.dmg",
        "https://archive.org/download/a/b.dmg%3Fx",
        "https://swcdn.apple.com/content/downloads/a/b.dmg",
        "https://swcdn.apple.com/other/b.pkg",
        "https://swcdn.apple.com/content/downloads/a/b.pkg?x",
        "http://swcdn.apple.com/content/downloads/test.pkg",
        "https://sub.swcdn.apple.com/content/downloads/a/b.pkg",
        "https://updates.cdn-apple.com/2019/Other.dmg",
        "http://updates.cdn-apple.com/2019/InstallOS.dmg",
        "http://OSCDN.apple.com/content/downloads/33/OSInstaller/InstallESD.dmg",
        "https://oscdn.apple.com/content/downloads/33/OSInstaller/InstallESD.dmg",
        "http://oscdn.apple.com/other.dmg",
        "http://oscdn.apple.com/content/downloads/InstallESD.dmg?x=1",
        "http://oscdn.apple.com:80/content/downloads/InstallESD.dmg",
        "http://u@oscdn.apple.com/content/downloads/InstallESD.dmg",
        "http://oscdn.apple.com/content/downloads/InstallESD.dmg#a",
        "http://oscdn.apple.com/content/downloads/a/InstallESD.dmg;x",
        "https://example.com/InstallMacOSX.dmg",
        "ftp://archive.org/download/a/b.dmg",
        "file:///download/a/b.dmg",
        "/download/a/b.dmg",
        "archive.org/download/a/b.dmg",
        "https:///download/a/b.dmg",
        "https://archive.org",
        "https://[::1]/download/a.dmg"
    ])
    func rejects(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(!InstallerSource.isApproved(url))
        #expect(!InstallerSource.isMavericksRecoveryAsset(url))
    }

    /// VIMInstallerSource.m approved these: it judged the decoded host and an unnormalized path.
    @Test(arguments: [
        "https://%61rchive.org/download/a/b.dmg",
        "https://archive%2Eorg/download/a/b.dmg",
        "https://swcdn%2Eapple.com/content/downloads/a/b.pkg",
        "https://updates.cdn-apple%2Ecom/2019/InstallOS.dmg",
        "http://oscdn%2Eapple.com/content/downloads/InstallESD.dmg",
        "https://archive.org/download/../secret/b.dmg",
        "https://archive.org/download/./b.dmg",
        "https://archive.org/download/%2E%2E/secret/b.dmg",
        "https://archive.org/download/%2e./secret/b.dmg",
        "https://archive.org/download/a%2F..%2F..%2Fsecret/b.dmg",
        "https://archive.org/download/..%5Csecret/b.dmg",
        "https://archive.org/0/items/../../secret/b.dmg",
        "https://swcdn.apple.com/content/downloads/../../secret/b.pkg",
        "https://updates.cdn-apple.com/../secret/InstallOS.dmg",
        "http://oscdn.apple.com/content/downloads/../../secret/InstallESD.dmg"
    ])
    func rejectsPercentEncodedHostsAndDotSegments(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(!InstallerSource.isApproved(url))
        #expect(!InstallerSource.isMavericksRecoveryAsset(url))
    }

    @Test(arguments: ["https://archive.org/download/a..b/c...dmg", "https://archive.org/download/.a/b.dmg"])
    func dotsInsideANameAreNotDotSegments(_ text: String) throws {
        #expect(InstallerSource.isApproved(try #require(URL(string: text))))
    }

    @Test func onlyTheRecoveryPayloadIsARecoveryAsset() throws {
        let plain = try #require(URL(string: "https://archive.org/download/a/b.dmg"))
        let recovery = try #require(URL(string: "http://oscdn.apple.com/content/downloads/33/InstallESD.dmg"))
        #expect(!InstallerSource.isMavericksRecoveryAsset(plain))
        #expect(InstallerSource.isMavericksRecoveryAsset(recovery))
    }

    // MARK: - Debug override

    private func override(debug: Bool, server: String?) throws -> String {
        let suite = "InstallerKitTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(debug, forKey: "VIMDebugMode")
        defaults.set(server, forKey: "VIMDownloadServer")
        let apple = try #require(URL(string: "https://archive.org/download/a%2Cb/c%20d.dmg?q=1"))
        return InstallerSource.downloadURL(for: apple, defaults: defaults).absoluteString
    }

    private static let unchanged = "https://archive.org/download/a%2Cb/c%20d.dmg?q=1"

    /// Results produced by running VIMInstallerCatalog.m on the same strings.
    @Test(arguments: [
        ("http://127.0.0.1:8765", "http://127.0.0.1:8765/download/a%2Cb/c%20d.dmg?q=1"),
        ("http://localhost:1", "http://localhost:1/download/a%2Cb/c%20d.dmg?q=1"),
        ("http://127.0.0.1/base", "http://127.0.0.1/download/a%2Cb/c%20d.dmg?q=1"),
        ("http://[::1]:8080", unchanged), ("http://[::1]", unchanged), ("http://::1:8", unchanged),
        ("https://127.0.0.1:1", unchanged), ("http://example.com", unchanged), ("http://u@127.0.0.1", unchanged),
        ("http://u:p@localhost", unchanged), ("http://127.0.0.1/x?y", unchanged), ("http://127.0.0.1/#f", unchanged),
        ("HTTP://127.0.0.1", unchanged), ("http://LOCALHOST", unchanged), ("", unchanged)
    ])
    func theDebugServerMustBePlainLoopback(_ server: String, _ expected: String) throws {
        #expect(try override(debug: true, server: server) == expected)
    }

    @Test func theDebugServerIsIgnoredOutsideDebugMode() throws {
        #expect(try override(debug: false, server: "http://127.0.0.1:8765") == Self.unchanged)
        #expect(try override(debug: true, server: nil) == Self.unchanged)
    }

    // MARK: - Archive failure guidance

    private static let snow = URL(string: "https://archive.org/download/macosx-snowleopard-archive/a.dmg")!
    private static let offline = URLError(.notConnectedToInternet)

    @Test(arguments: [
        "Asia/Shanghai", "Asia/Chongqing", "Asia/Chungking", "Asia/Harbin", "Asia/Urumqi", "Asia/Kashgar", "PRC"
    ])
    func mainlandTimeZonesGetGuidance(_ zone: String) {
        #expect(
            InstallerSource.shouldExplainArchiveFailure(
                Self.offline, source: Self.snow, guest: .snowLeopard, region: "US", timeZone: zone))
    }

    @Test(arguments: [Guest.tiger, .leopard, .snowLeopard])
    func aMainlandRegionGetsGuidanceForAnHTTPFailure(_ guest: Guest) {
        #expect(
            InstallerSource.shouldExplainArchiveFailure(
                DownloadError.invalidResponse(status: 403), source: Self.snow, guest: guest, region: "cn",
                timeZone: "America/Chicago"))
    }

    @Test func hongKongAndTaiwanAreNotMainland() {
        #expect(
            !InstallerSource.shouldExplainArchiveFailure(
                Self.offline, source: Self.snow, guest: .snowLeopard, region: "HK", timeZone: "Asia/Hong_Kong"))
        #expect(
            !InstallerSource.shouldExplainArchiveFailure(
                Self.offline, source: Self.snow, guest: .snowLeopard, region: "TW", timeZone: "Asia/Taipei"))
    }

    @Test func appleDownloadsAndNonRestoreGuestsKeepTheirNormalErrors() throws {
        let apple = try #require(URL(string: "https://updates.cdn-apple.com/InstallMacOSX.dmg"))
        #expect(
            !InstallerSource.shouldExplainArchiveFailure(
                Self.offline, source: apple, guest: .lion, region: "CN", timeZone: "Asia/Shanghai"))
        #expect(
            !InstallerSource.shouldExplainArchiveFailure(
                Self.offline, source: Self.snow, guest: .lion, region: "CN", timeZone: "Asia/Shanghai"))
    }

    @Test(arguments: [
        NSError(domain: NSPOSIXErrorDomain, code: 28),
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
        DownloadError.cannotSave as NSError,
        NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile)
    ])
    func localStateAndCancellationErrorsAreNeverRegional(_ error: NSError) {
        #expect(
            !InstallerSource.shouldExplainArchiveFailure(
                error, source: Self.snow, guest: .snowLeopard, region: "CN", timeZone: "Asia/Shanghai"))
    }

    @Test func aWrappedTransportErrorIsJudgedByItsOwnIdentity() {
        let lost = DownloadError.system(URLError(.networkConnectionLost) as NSError)
        let cancelled = DownloadError.system(URLError(.cancelled) as NSError)
        #expect(
            InstallerSource.shouldExplainArchiveFailure(
                lost, source: Self.snow, guest: .snowLeopard, region: "CN", timeZone: nil))
        #expect(
            !InstallerSource.shouldExplainArchiveFailure(
                cancelled, source: Self.snow, guest: .snowLeopard, region: "CN", timeZone: nil))
    }

    @Test func anObjectiveCDownloadErrorStillCounts() {
        #expect(
            InstallerSource.shouldExplainArchiveFailure(
                NSError(domain: "VirtualIntelMac.Download", code: 2), source: Self.snow, guest: .tiger, region: "CN",
                timeZone: nil))
    }

    // MARK: - Verification

    private static let recovery = URL(string: "http://oscdn.apple.com/content/downloads/33/InstallESD.dmg")!

    private func catalog(recoveryDigest digest: String) throws -> InstallerCatalog {
        try InstallerCatalog(
            data: Fixture.catalog {
                Fixture.file($0, .mavericks)["URL"] = Self.recovery.absoluteString
                Fixture.file($0, .mavericks)["SHA256"] = digest
            })
    }

    @Test func aMatchingDigestInEitherCaseVerifies() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(component: "Payload")
        try Data("payload".utf8).write(to: file)
        for digest in [Fixture.sha256(Data("payload".utf8)), Fixture.sha256(Data("payload".utf8)).uppercased()] {
            try InstallerSource.verify(file: file, source: Self.recovery, catalog: catalog(recoveryDigest: digest))
        }
    }

    @Test func aDifferentFileFailsVerification() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(component: "Payload")
        try Data("other".utf8).write(to: file)
        let catalog = try catalog(recoveryDigest: Fixture.sha256(Data("payload".utf8)))
        #expect(throws: InstallerSourceError.digestMismatch) {
            try InstallerSource.verify(file: file, source: Self.recovery, catalog: catalog)
        }
    }

    @Test func aLargeFileHashesThroughTheBoundedBuffer() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(component: "Payload")
        let payload = Fixture.payload(count: 200_000)
        try payload.write(to: file)
        try InstallerSource.verify(
            file: file, source: Self.recovery, catalog: catalog(recoveryDigest: Fixture.sha256(payload)))
    }

    @Test func aSymlinkIsNotFollowed() throws {
        let directory = try TemporaryDirectory()
        let real = directory.url.appending(component: "Real")
        let link = directory.url.appending(component: "Link")
        try Data("payload".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let catalog = try catalog(recoveryDigest: Fixture.sha256(Data("payload".utf8)))
        #expect(throws: InstallerSourceError.unreadableDownload) {
            try InstallerSource.verify(file: link, source: Self.recovery, catalog: catalog)
        }
    }

    @Test func recoveryWithoutACatalogRecordFailsButOtherSourcesPass() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(component: "Payload")
        let elsewhere = try #require(URL(string: "http://oscdn.apple.com/content/downloads/other/InstallESD.dmg"))
        let catalog = try InstallerCatalog(data: Fixture.catalogData)
        #expect(throws: InstallerSourceError.noVerificationRecord) {
            try InstallerSource.verify(file: file, source: elsewhere, catalog: catalog)
        }
        #expect(throws: InstallerSourceError.noVerificationRecord) {
            try InstallerSource.verify(file: file, source: elsewhere, catalog: nil)
        }
        let unlisted = try #require(URL(string: "https://swcdn.apple.com/content/downloads/a/b.pkg"))
        try InstallerSource.verify(file: file, source: unlisted, catalog: catalog)
    }

    @Test func errorsKeepTheirObjectiveCIdentity() {
        let error = InstallerSourceError.digestMismatch as NSError
        #expect(error.domain == "VirtualIntelMac.InstallerSource")
        #expect(error.code == 1)
        #expect(
            error.localizedDescription
                == "The download did not match the expected Apple installer. It was not used. Remove the saved "
                + "download and try again.")
    }
}
