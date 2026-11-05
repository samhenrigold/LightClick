import Foundation
import Testing

@testable import InstallerKit

@Suite struct ObjectiveCBridgeSourceTests {
    @Test func aCatalogHasTheDictionaryShapeItsCallersRead() throws {
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Fixture.catalogData, format: nil) as? [String: Any])
        let expected = try #require(plist["Installers"] as? [[String: Any]])
        let bridged = InstallerCatalogBridge(catalog: try InstallerCatalog(data: Fixture.catalogData))
            .supportedInstallers
        #expect(bridged.count == expected.count)
        for (installer, original) in zip(bridged, expected) {
            for key in ["Guest", "Name", "Version", "Assembly"] {
                #expect(installer[key] as? String == original[key] as? String)
            }
            let files = try #require(installer["Files"] as? [[String: String]])
            let originals = try #require(original["Files"] as? [[String: String]])
            #expect(
                files.map { $0.mapValues { $0.uppercased() } } == originals.map { $0.mapValues { $0.uppercased() } })
        }
    }

    @Test func aMissingOrUnapprovedURLIsNotApproved() throws {
        #expect(!InstallerSourceBridge.isApproved(nil))
        #expect(!InstallerSourceBridge.isApproved(URL(string: "https://%61rchive.org/download/a/b.dmg")))
        #expect(InstallerSourceBridge.isApproved(URL(string: "https://archive.org/download/a/b.dmg")))
    }

    @Test func archiveGuidanceTakesAMissingSourceAndAnUnknownGuest() throws {
        let error = URLError(.timedOut) as NSError
        let archive = try #require(URL(string: "https://archive.org/download/a/b.dmg"))
        let explain = { (source: URL?, guest: String) in
            InstallerSourceBridge.shouldExplainArchiveFailure(
                error, source: source, guest: guest, region: "CN", timeZone: nil)
        }
        #expect(explain(archive, "tiger"))
        #expect(!explain(nil, "tiger"))
        #expect(!explain(archive, "unknown"))
    }

    @Test func aRecoveryWithoutARecordFailsInItsOwnDomain() throws {
        let temporary = try TemporaryDirectory()
        let file = temporary.url.appending(component: "Payload")
        try Data("x".utf8).write(to: file)
        let recovery = try #require(URL(string: "http://oscdn.apple.com/content/downloads/vim-test/InstallESD.dmg"))
        #expect {
            try InstallerSourceBridge.verify(file: file, source: recovery)
        } throws: {
            ($0 as NSError).domain == "VirtualIntelMac.InstallerSource"
        }
        let other = try #require(URL(string: "https://swcdn.apple.com/content/downloads/vim-test/Payload.pkg"))
        try InstallerSourceBridge.verify(file: file, source: other)
    }
}

extension StubbedNetwork {
    @MainActor @Suite struct ObjectiveCBridgeDownloadTests {
        private static let source = URL(string: "https://swcdn.apple.com/content/downloads/vim-test/Payload.pkg")!

        private func start(_ bridge: InstallerDownloadBridge) async -> (URL?, NSError?, Bool) {
            await withCheckedContinuation { continuation in
                bridge.start { file, error, paused in
                    #expect(Thread.isMainThread)
                    continuation.resume(returning: (file, error, paused))
                }
            }
        }

        @Test func invalidLocationsFailWithTheDownloadDomain() throws {
            let temporary = try TemporaryDirectory()
            let unapproved = try #require(URL(string: "https://example.com/InstallOS.dmg"))
            for (source, directory) in [(unapproved, temporary.url), (nil, temporary.url), (Self.source, nil)] {
                #expect {
                    try InstallerDownloadBridge(sourceURL: source, directory: directory)
                } throws: {
                    ($0 as NSError).domain == "VirtualIntelMac.Download"
                }
            }
        }

        @Test func pausingThenRestartingTheSameBridgeFinishesAndKeepsReportingProgress() async throws {
            let temporary = try TemporaryDirectory()
            let directory = temporary.url.appending(component: "Transfer")
            let payload = Fixture.payload(count: 256 * 1024)
            let served = NSLock()
            nonisolated(unsafe) var requests = 0
            StubURLProtocol.install { _ in
                let count = served.withLock {
                    requests += 1
                    return requests
                }
                return count == 1
                    ? StubResponse(chunks: [Data(payload.prefix(1024))], stalls: true)
                    : StubResponse(chunks: [payload])
            }
            let bridge = InstallerDownloadBridge(
                download: try InstallerDownload(
                    source: Self.source, directory: directory, catalogStore: InstallerCatalogStore(bundledURL: nil),
                    makeConfiguration: StubURLProtocol.makeConfiguration))
            #expect(bridge.sourceURL == Self.source)

            var totals: [Int64] = []
            bridge.progress = { [weak bridge] _, total in
                #expect(Thread.isMainThread)
                totals.append(total)
                bridge?.pause()
            }
            let (firstFile, firstError, paused) = await start(bridge)
            #expect(firstFile == nil && firstError == nil && paused)
            #expect(totals == [-1])

            let (file, error, stillPaused) = await start(bridge)
            #expect(error == nil && !stillPaused)
            #expect(try Data(contentsOf: try #require(file)) == payload)
        }
    }
}
