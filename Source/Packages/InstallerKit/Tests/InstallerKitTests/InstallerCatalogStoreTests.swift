import Foundation
import Testing

@testable import InstallerKit

extension StubbedNetwork {
    @Suite struct CatalogStoreTests {
        private let directory: TemporaryDirectory
        private let store: InstallerCatalogStore
        private var bundled: URL { directory.url.appending(component: "Bundled.plist") }
        private var cache: URL { directory.url.appending(components: "Nested", "Catalog.plist") }

        init() throws {
            directory = try TemporaryDirectory()
            store = InstallerCatalogStore(
                bundledURL: directory.url.appending(component: "Bundled.plist"),
                cacheURL: directory.url.appending(components: "Nested", "Catalog.plist"),
                session: URLSession(configuration: StubURLProtocol.makeConfiguration()))
            try FileManager.default.createDirectory(
                at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        private func refresh(returning data: Data, status: Int = 200) async -> CatalogRefresh {
            StubURLProtocol.install { _ in StubResponse(status: status, chunks: [data]) }
            return await store.refresh()
        }

        @Test func aNewerBundledCopyWinsOverTheCache() throws {
            try Fixture.catalog(revision: 10).write(to: bundled)
            try Fixture.catalog(revision: 9).write(to: cache)
            #expect(try store.current().revision == 10)
        }

        @Test func aNewerCacheWinsAndAnInvalidOneIsIgnored() throws {
            try Fixture.catalog(revision: 10).write(to: bundled)
            try Fixture.catalog(revision: 11).write(to: cache)
            #expect(try store.current().revision == 11)
            try Data("bad".utf8).write(to: cache)
            #expect(try store.current().revision == 10)
        }

        @Test func nothingValidIsUnavailable() {
            #expect(throws: CatalogError.self) { try store.current() }
        }

        @Test func refreshNeverDowngradesAndPublishesOnlyWhatIsNewer() async throws {
            try Fixture.catalog(revision: 10).write(to: bundled)
            let original = try Fixture.catalog(revision: 9)
            try original.write(to: cache)

            var result = await refresh(returning: try Fixture.catalog(revision: 8))
            #expect(result.error == nil && result.catalog?.revision == 10)
            #expect(try Data(contentsOf: cache) == original, "An older remote does not replace the cache")

            result = await refresh(returning: try Fixture.catalog(revision: 11))
            #expect(result.error == nil && result.catalog?.revision == 11)
            #expect(try store.current().revision == 11, "A newer remote persists")
            let published = try Data(contentsOf: cache)
            #expect(try published == Fixture.catalog(revision: 11), "The remote's own bytes are cached")

            result = await refresh(returning: try Fixture.catalog(revision: 10))
            #expect(result.error == nil && result.catalog?.revision == 11)
            #expect(try Data(contentsOf: cache) == published, "A late older response cannot downgrade the cache")

            result = await refresh(returning: try Fixture.catalog(revision: 11))
            #expect(result.error == nil && result.catalog?.revision == 11)
            #expect(try Data(contentsOf: cache) == published, "An equal revision preserves the cache")
        }

        @Test func refreshAsksForAnUncachedCopyFromTheRepository() async throws {
            _ = await refresh(returning: try Fixture.catalog(revision: 1))
            let request = try #require(StubURLProtocol.requests.first)
            #expect(request.url == InstallerCatalogStore.defaultRemoteURL)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.timeoutInterval == 20)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "VirtualIntelMac/1")
        }

        @Test func aFailedRefreshReportsItAndKeepsTheBestCatalog() async throws {
            try Fixture.catalog(revision: 10).write(to: bundled)

            var result = await refresh(returning: try Fixture.catalog(revision: 11), status: 404)
            #expect(result.catalog?.revision == 10)
            #expect(result.error?.errorDescription == CatalogError.updateFailed.errorDescription)

            result = await refresh(returning: Data("bad".utf8))
            #expect(result.catalog?.revision == 10)
            #expect(result.error?.errorDescription == CatalogError.invalid.errorDescription)

            StubURLProtocol.install { _ in StubResponse(error: .notConnectedToInternet) }
            result = await store.refresh()
            #expect(result.catalog?.revision == 10)
            guard case .system(let underlying) = result.error else {
                Issue.record("Expected the transport error")
                return
            }
            #expect(underlying.code == URLError.notConnectedToInternet.rawValue)
            #expect(!FileManager.default.fileExists(atPath: cache.path))
        }

        @Test func aCacheThatCannotBeWrittenStillReturnsTheNewCatalog() async throws {
            let blocker = directory.url.appending(component: "File")
            try Data().write(to: blocker)
            let store = InstallerCatalogStore(
                bundledURL: nil, cacheURL: blocker.appending(components: "Below", "Catalog.plist"),
                session: URLSession(configuration: StubURLProtocol.makeConfiguration()))
            let data = try Fixture.catalog(revision: 11)
            StubURLProtocol.install { _ in StubResponse(chunks: [data]) }
            let result = await store.refresh()
            #expect(result.catalog?.revision == 11)
            #expect(result.error != nil)
        }
    }
}
