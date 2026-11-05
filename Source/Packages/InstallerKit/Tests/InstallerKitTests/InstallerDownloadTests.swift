import Foundation
import Testing

@testable import InstallerKit

extension StubbedNetwork {
    @Suite struct InstallerDownloadTests {
        private static let source = URL(string: "https://swcdn.apple.com/content/downloads/vim-test/Payload.pkg")!
        private static let etag = "\"strong\""

        private let temporary: TemporaryDirectory
        private let store: InstallerCatalogStore
        private var directory: URL { temporary.url.appending(component: "Transfer") }
        private var journalURL: URL { directory.appending(component: "Download.plist") }
        private var lockURL: URL { directory.appending(component: "Download.lock") }
        private var partialURL: URL { directory.appending(component: "Payload.partial") }
        private var finishedURL: URL { directory.appending(component: "Payload.pkg") }

        init() throws {
            temporary = try TemporaryDirectory()
            let bundled = temporary.url.appending(component: "Catalog.plist")
            try Fixture.catalogData.write(to: bundled)
            store = InstallerCatalogStore(
                bundledURL: bundled, cacheURL: temporary.url.appending(component: "Cache.plist"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        private func makeDownload(
            source: URL = Self.source, store: InstallerCatalogStore? = nil, fetchURL: URL? = nil
        ) throws -> InstallerDownload {
            try InstallerDownload(
                source: source, directory: directory, catalogStore: store ?? self.store, fetchURL: fetchURL,
                makeConfiguration: StubURLProtocol.makeConfiguration)
        }

        private func writeJournal(_ fields: [String: Any]) throws {
            let base: [String: Any] = ["FormatVersion": 1, "SourceURL": Self.source.absoluteString]
            let plist = base.merging(fields) { $1 }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: journalURL)
        }

        private func journal() throws -> NSDictionary {
            try #require(NSDictionary(contentsOf: journalURL))
        }

        /// A server honoring Range when If-Range still names `etag`.
        private func serve(_ payload: Data, etag: String = Self.etag, stallingFirstRequest: Bool = false) {
            let isFirst = NSLock()
            nonisolated(unsafe) var requests = 0
            StubURLProtocol.install { request in
                let count = isFirst.withLock {
                    requests += 1
                    return requests
                }
                let chunks = stride(from: 0, to: payload.count, by: 64 * 1024).map { start in
                    payload[start..<min(start + 64 * 1024, payload.count)]
                }
                if stallingFirstRequest, count == 1 {
                    return StubResponse(
                        headers: ["ETag": etag, "Content-Length": "\(payload.count)"], chunks: [Data(chunks[0])],
                        stalls: true)
                }
                if let range = request.value(forHTTPHeaderField: "Range"),
                    request.value(forHTTPHeaderField: "If-Range") == etag,
                    let first = range.wholeMatch(of: /bytes=([0-9]+)-/).flatMap({ Int($0.1) })
                {
                    return StubResponse(
                        status: 206,
                        headers: [
                            "ETag": etag, "Content-Range": "bytes \(first)-\(payload.count - 1)/\(payload.count)",
                            "Content-Length": "\(payload.count - first)"
                        ],
                        chunks: [Data(payload[first...])])
                }
                return StubResponse(
                    headers: ["ETag": etag, "Content-Length": "\(payload.count)"], chunks: chunks.map { Data($0) })
            }
        }

        private func expectFailure(
            _ download: InstallerDownload, _ expected: DownloadError,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async {
            do {
                let outcome = try await download.run()
                Issue.record("Expected \(expected), got \(outcome)", sourceLocation: sourceLocation)
            } catch {
                #expect(error.errorDescription == expected.errorDescription, sourceLocation: sourceLocation)
            }
        }

        private func waitForFirstProgress(_ download: InstallerDownload) async {
            for await _ in download.progress { break }
        }

        // MARK: - Pausing and resuming

        /// The persistent-download probe: resume relies on persisted bytes and state, not on an in-memory resume blob.
        @Test func pausePersistsAndANewInstanceResumesToExactBytesThenReusesTheCache() async throws {
            let payload = Fixture.payload(count: 2 * 1024 * 1024)
            serve(payload, stallingFirstRequest: true)

            let first = try makeDownload()
            async let firstOutcome = first.run()
            await waitForFirstProgress(first)
            await first.pause()
            #expect(try await firstOutcome == .paused)
            let saved = try Data(contentsOf: partialURL)
            #expect(!saved.isEmpty && saved.count < payload.count)
            #expect(saved == payload.prefix(saved.count))
            #expect(try journal()["ETag"] as? String == Self.etag)
            #expect(!FileManager.default.fileExists(atPath: finishedURL.path))

            let second = try makeDownload()
            #expect(try await second.run() == .finished(finishedURL))
            let resumed = try #require(StubURLProtocol.requests.last)
            #expect(resumed.value(forHTTPHeaderField: "Range") == "bytes=\(saved.count)-")
            #expect(resumed.value(forHTTPHeaderField: "If-Range") == Self.etag)
            #expect(resumed.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
            #expect(try Data(contentsOf: finishedURL) == payload)
            #expect(!FileManager.default.fileExists(atPath: partialURL.path))

            let requests = StubURLProtocol.requests.count
            let third = try makeDownload()
            #expect(try await third.run() == .finished(finishedURL))
            #expect(StubURLProtocol.requests.count == requests, "Completed cache is reused without a request")
        }

        @Test func theSameInstanceCanRunAgainAfterPausing() async throws {
            let payload = Fixture.payload(count: 256 * 1024)
            serve(payload, stallingFirstRequest: true)
            let download = try makeDownload()
            async let outcome = download.run()
            await waitForFirstProgress(download)
            await download.pause()
            #expect(try await outcome == .paused)
            #expect(try await download.run() == .finished(finishedURL))
            #expect(try Data(contentsOf: finishedURL) == payload)
        }

        @Test func cancellingTheTaskPausesAndKeepsTheBytes() async throws {
            serve(Fixture.payload(count: 256 * 1024), stallingFirstRequest: true)
            let download = try makeDownload()
            let task = Task { try await download.run() }
            await waitForFirstProgress(download)
            task.cancel()
            #expect(try await task.value == .paused)
            #expect(try Data(contentsOf: partialURL).count == 64 * 1024)
        }

        @Test func aSecondRunWhileRunningIsRefused() async throws {
            serve(Fixture.payload(count: 256 * 1024), stallingFirstRequest: true)
            let download = try makeDownload()
            async let outcome = download.run()
            await waitForFirstProgress(download)
            await expectFailure(download, .alreadyRunning)
            await download.pause()
            #expect(try await outcome == .paused)
        }

        @Test func pausingWhenIdleDoesNothing() async throws {
            let payload = Fixture.payload(count: 1024)
            serve(payload)
            let download = try makeDownload()
            await download.pause()
            #expect(try await download.run() == .finished(finishedURL))
        }

        @Test func progressReportsAnUnknownTotalAsNil() async throws {
            StubURLProtocol.install { _ in StubResponse(chunks: [Data("abc".utf8)]) }
            let download = try makeDownload()
            async let outcome = download.run()
            var iterator = download.progress.makeAsyncIterator()
            let update = await iterator.next()
            #expect(update == DownloadProgress(received: 3, total: nil))
            #expect(try await outcome == .finished(finishedURL))
            #expect(try journal()["Length"] as? Int == 3, "Completion replaces the unknown length")
        }

        // MARK: - Responses

        @Test func aFullBodyAfterAMismatchedValidatorReplacesThePartial() async throws {
            let payload = Fixture.payload(count: 1024)
            try Data("stale bytes".utf8).write(to: partialURL)
            try writeJournal(["ETag": "\"old\"", "Length": 2048])
            serve(payload)
            #expect(try await makeDownload().run() == .finished(finishedURL))
            #expect(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "If-Range") == "\"old\"")
            #expect(try Data(contentsOf: finishedURL) == payload)
        }

        @Test func aPartialWithNoValidatorRestartsWithoutARange() async throws {
            let payload = Fixture.payload(count: 1024)
            try Data("stale".utf8).write(to: partialURL)
            serve(payload)
            #expect(try await makeDownload().run() == .finished(finishedURL))
            #expect(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Range") == nil)
            #expect(try Data(contentsOf: finishedURL) == payload)
        }

        @Test func aWeakETagFallsBackToLastModifiedAndNeverToItself() {
            var journal = DownloadJournal(sourceURL: "x")
            journal.etag = "W/\"weak\""
            #expect(journal.resumeValidator == nil)
            journal.lastModified = "Thu"
            #expect(journal.resumeValidator == "Thu")
            journal.etag = "\"strong\""
            #expect(journal.resumeValidator == "\"strong\"")
            journal.etag = ""
            #expect(journal.resumeValidator == "Thu")
            journal.lastModified = ""
            #expect(journal.resumeValidator == nil)
        }

        @Test(arguments: [
            "bytes 4-7/9", "bytes 0-7/8", "bytes 4-8/8", "bytes 4-7/*", "bytes */8", "bytes 7-4/8", "bytes 4-7/8 ",
            "bytes 4-7/8x", "4-7/8", "bytes 4-107374182399/107374182401"
        ])
        func aBadContentRangeIsRefusedAndNotAppended(_ range: String) async throws {
            try Data("part".utf8).write(to: partialURL)
            try writeJournal(["ETag": Self.etag])
            StubURLProtocol.install { _ in
                StubResponse(
                    status: 206, headers: ["ETag": Self.etag, "Content-Range": range], chunks: [Data("rest".utf8)])
            }
            await expectFailure(try makeDownload(), .invalidResponse(status: 206))
            #expect(try Data(contentsOf: partialURL) == Data("part".utf8))
        }

        @Test func aGoodContentRangeAppends() async throws {
            try Data("part".utf8).write(to: partialURL)
            try writeJournal(["ETag": Self.etag])
            StubURLProtocol.install { _ in
                StubResponse(status: 206, headers: ["Content-Range": "bytes 4-7/8"], chunks: [Data("rest".utf8)])
            }
            #expect(try await makeDownload().run() == .finished(finishedURL))
            #expect(try Data(contentsOf: finishedURL) == Data("partrest".utf8))
        }

        @Test func aChangedStrongETagOnAResumeIsRefused() async throws {
            try Data("part".utf8).write(to: partialURL)
            try writeJournal(["ETag": Self.etag])
            StubURLProtocol.install { _ in
                StubResponse(
                    status: 206, headers: ["ETag": "\"other\"", "Content-Range": "bytes 4-7/8"],
                    chunks: [Data("rest".utf8)])
            }
            await expectFailure(try makeDownload(), .invalidResponse(status: 206))
        }

        @Test(arguments: [404, 500, 301, 416])
        func otherStatusesAreRefusedAndKeepThePartial(_ status: Int) async throws {
            try Data("part".utf8).write(to: partialURL)
            try writeJournal(["ETag": Self.etag])
            StubURLProtocol.install { _ in StubResponse(status: status, headers: ["Location": "https://example.com/"]) }
            let download = try makeDownload()
            await expectFailure(download, .invalidResponse(status: status))
            #expect(try Data(contentsOf: partialURL) == Data("part".utf8))
        }

        @Test func aCompressedBodyIsRefused() async throws {
            StubURLProtocol.install { _ in StubResponse(headers: ["Content-Encoding": "gzip"], chunks: [Data("x".utf8)])
            }
            await expectFailure(try makeDownload(), .invalidResponse(status: 200))
        }

        @Test func anIdentityEncodingIsFine() async throws {
            StubURLProtocol.install { _ in
                StubResponse(headers: ["Content-Encoding": "IDENTITY"], chunks: [Data("x".utf8)])
            }
            #expect(try await makeDownload().run() == .finished(finishedURL))
        }

        @Test func aDeclaredLengthOverTheLimitIsRefused() async throws {
            StubURLProtocol.install { _ in StubResponse(headers: ["Content-Length": "107374182401"]) }
            await expectFailure(try makeDownload(), .invalidResponse(status: 200))
        }

        @Test func moreBytesThanDeclaredAreRefused() async throws {
            StubURLProtocol.install { _ in
                StubResponse(headers: ["Content-Length": "4"], chunks: [Data("too long".utf8)])
            }
            await expectFailure(try makeDownload(), .exceededExpectedLength)
            #expect(!FileManager.default.fileExists(atPath: finishedURL.path))
        }

        @Test func fewerBytesThanDeclaredAreNotPublished() async throws {
            StubURLProtocol.install { _ in StubResponse(headers: ["Content-Length": "8"], chunks: [Data("part".utf8)]) }
            await expectFailure(try makeDownload(), .incompleteTransfer)
            #expect(!FileManager.default.fileExists(atPath: finishedURL.path))
            #expect(try Data(contentsOf: partialURL) == Data("part".utf8))
        }

        @Test func anEmptyBodyIsNotAFile() async throws {
            StubURLProtocol.install { _ in StubResponse() }
            await expectFailure(try makeDownload(), .incompleteTransfer)
        }

        @Test func aTransportFailureKeepsItsIdentity() async throws {
            StubURLProtocol.install { _ in StubResponse(error: .notConnectedToInternet) }
            let download = try makeDownload()
            do {
                _ = try await download.run()
                Issue.record("Expected a failure")
            } catch {
                #expect(error.bridged.domain == NSURLErrorDomain)
                #expect(error.bridged.code == NSURLErrorNotConnectedToInternet)
            }
        }

        @Test func theDebugServerChangesWhereBytesComeFromNotWhatTheyAre() async throws {
            let suite = "InstallerKitTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: "VIMDebugMode")
            defaults.set("http://127.0.0.1:8765", forKey: "VIMDownloadServer")
            serve(Fixture.payload(count: 16))
            let fetchURL = InstallerSource.downloadURL(for: Self.source, defaults: defaults)
            #expect(try await makeDownload(fetchURL: fetchURL).run() == .finished(finishedURL))
            #expect(StubURLProtocol.requests.last?.url?.host == "127.0.0.1")
            #expect(try journal()["SourceURL"] as? String == Self.source.absoluteString)
        }

        // MARK: - Trust boundaries

        @Test func onlyApprovedSourcesAndFileDirectoriesAreAccepted() throws {
            let bad = try #require(URL(string: "https://example.com/Payload.pkg"))
            #expect(throws: DownloadError.self) { try makeDownload(source: bad) }
            #expect(throws: DownloadError.self) {
                try InstallerDownload(source: Self.source, directory: Self.source, catalogStore: store)
            }
        }

        @Test func anotherHolderOfTheLockIsRefused() async throws {
            let descriptor = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
            defer { close(descriptor) }
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            await expectFailure(try makeDownload(), .lockedByAnotherProcess)
        }

        @Test func theLockIsReleasedWhenARunEnds() async throws {
            StubURLProtocol.install { _ in StubResponse(status: 404) }
            await expectFailure(try makeDownload(), .invalidResponse(status: 404))
            let descriptor = open(lockURL.path, O_RDWR)
            defer { close(descriptor) }
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        }

        @Test func aSymlinkedLockOrPartialIsNotFollowed() async throws {
            let target = temporary.url.appending(component: "Target")
            try Data("keep".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: partialURL, withDestinationURL: target)
            await expectFailure(try makeDownload(), .cannotOpenPartial)
            #expect(try Data(contentsOf: target) == Data("keep".utf8))
            try FileManager.default.removeItem(at: partialURL)
            try FileManager.default.removeItem(at: lockURL)
            try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)
            await expectFailure(try makeDownload(), .lockedByAnotherProcess)
        }

        @Test func aDirectoryAtThePartialIsRefused() async throws {
            try FileManager.default.createDirectory(at: partialURL, withIntermediateDirectories: false)
            await expectFailure(try makeDownload(), .cannotOpenPartial)
        }

        @Test func aFolderBelongingToAnotherFileIsRefused() async throws {
            try writeJournal(["SourceURL": "https://swcdn.apple.com/content/downloads/other/Payload.pkg"])
            await expectFailure(try makeDownload(), .foreignDirectory)
            try writeJournal(["FormatVersion": 2])
            await expectFailure(try makeDownload(), .foreignDirectory)
            try writeJournal(["SourceURL": 7])
            await expectFailure(try makeDownload(), .foreignDirectory)
        }

        @Test func aMistypedJournalIsInvalid() async throws {
            try writeJournal(["Length": "8"])
            await expectFailure(try makeDownload(), .invalidState)
            try writeJournal(["Complete": "yes"])
            await expectFailure(try makeDownload(), .invalidState)
            try writeJournal(["Length": 8.5])
            await expectFailure(try makeDownload(), .invalidState)
        }

        @Test func anUnparseableJournalIsAFreshStart() async throws {
            try Data("garbage".utf8).write(to: journalURL)
            serve(Fixture.payload(count: 16))
            #expect(try await makeDownload().run() == .finished(finishedURL))
            #expect(try journal()["Complete"] as? Bool == true)
        }

        @Test func aMistypedValidatorIsNoValidator() async throws {
            try Data("stale".utf8).write(to: partialURL)
            try writeJournal(["ETag": 7, "LastModified": 8])
            serve(Fixture.payload(count: 16))
            #expect(try await makeDownload().run() == .finished(finishedURL))
            #expect(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Range") == nil)
        }

        // MARK: - Interrupted states

        @Test func aCrashBetweenRenameAndJournalIsRecovered() async throws {
            try Data("complete".utf8).write(to: finishedURL)
            try writeJournal(["Length": 8])
            StubURLProtocol.install { _ in StubResponse(status: 500) }
            #expect(try await makeDownload().run() == .finished(finishedURL))
            #expect(StubURLProtocol.requests.isEmpty)
            #expect(try journal()["Complete"] as? Bool == true)
        }

        @Test func aWrongSizedCachedPayloadIsNeitherUsedNorReplaced() async throws {
            try Data("short".utf8).write(to: finishedURL)
            try writeJournal(["Length": 8, "Complete": true])
            await expectFailure(try makeDownload(), .incompleteCache)
            #expect(try Data(contentsOf: finishedURL) == Data("short".utf8))
        }

        @Test func aSymlinkedCachedPayloadIsNotUsed() async throws {
            let target = temporary.url.appending(component: "Target")
            try Data("complete".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: finishedURL, withDestinationURL: target)
            try writeJournal(["Length": 8, "Complete": true])
            await expectFailure(try makeDownload(), .incompleteCache)
        }

        @Test func aRetiredPayloadRestartsFromAClearedJournal() async throws {
            try writeJournal(["Length": 8, "Complete": true, "ETag": Self.etag, "LastModified": "Thu"])
            StubURLProtocol.install { _ in StubResponse(status: 404) }
            await expectFailure(try makeDownload(), .invalidResponse(status: 404))
            let stored = try journal()
            #expect(stored["Complete"] == nil && stored["Length"] == nil && stored["ETag"] == nil)
            #expect(stored["LastModified"] == nil && stored["SourceURL"] as? String == Self.source.absoluteString)
        }

        @Test func aPartialOfTheJournaledLengthCompletesWithoutARequest() async throws {
            try Data("complete".utf8).write(to: partialURL)
            try writeJournal(["Length": 8])
            StubURLProtocol.install { _ in StubResponse(status: 500) }
            #expect(try await makeDownload().run() == .finished(finishedURL))
            #expect(StubURLProtocol.requests.isEmpty)
        }

        // MARK: - Verification

        private func storeRequiringDigest(of payload: Data, for guest: Guest, url: URL) throws -> InstallerCatalogStore
        {
            let bundled = temporary.url.appending(component: "Digest.plist")
            try Fixture.catalog {
                Fixture.file($0, guest)["URL"] = url.absoluteString
                Fixture.file($0, guest)["SHA256"] = Fixture.sha256(payload)
            }.write(to: bundled)
            return InstallerCatalogStore(bundledURL: bundled, cacheURL: temporary.url.appending(component: "None"))
        }

        private static let lion = URL(string: "https://updates.cdn-apple.com/2021/InstallMacOSX.dmg")!

        @Test func aDigestMismatchRetainsTheBytesButNeverPublishesThem() async throws {
            let store = try storeRequiringDigest(of: Data("expected".utf8), for: .lion, url: Self.lion)
            StubURLProtocol.install { _ in StubResponse(chunks: [Data("tampered".utf8)]) }
            let download = try makeDownload(source: Self.lion, store: store)
            await expectFailure(download, .source(.digestMismatch))
            #expect(!FileManager.default.fileExists(atPath: finishedURL.path))
            #expect(try Data(contentsOf: partialURL) == Data("tampered".utf8))
            #expect(try journal()["Complete"] == nil)
        }

        @Test func aMatchingDigestPublishes() async throws {
            let payload = Data("expected".utf8)
            let store = try storeRequiringDigest(of: payload, for: .lion, url: Self.lion)
            StubURLProtocol.install { _ in StubResponse(chunks: [payload]) }
            #expect(try await makeDownload(source: Self.lion, store: store).run() == .finished(finishedURL))
        }

        @Test func aCachedPayloadIsVerifiedAgainOnEveryUse() async throws {
            let store = try storeRequiringDigest(of: Data("expected".utf8), for: .lion, url: Self.lion)
            try Data("tampered".utf8).write(to: finishedURL)
            try PropertyListSerialization.data(
                fromPropertyList: [
                    "FormatVersion": 1, "SourceURL": Self.lion.absoluteString, "Length": 8, "Complete": true
                ] as [String: Any],
                format: .xml, options: 0
            ).write(to: journalURL)
            await expectFailure(try makeDownload(source: Self.lion, store: store), .source(.digestMismatch))
        }

        @Test func theRecoveryPayloadAuthorizesThenVerifiesAndNeverPersistsItsToken() async throws {
            let asset = try #require(URL(string: "http://oscdn.apple.com/content/downloads/33/InstallESD.dmg"))
            let payload = Data("recovery payload".utf8)
            let store = try storeRequiringDigest(of: payload, for: .mavericks, url: asset)
            StubURLProtocol.install { request in
                switch request.url?.host {
                case "osrecovery.apple.com":
                    request.httpMethod == "POST"
                        ? .body("AU: \(asset)\nAT: secret-token\n")
                        : .body("", headers: ["Set-Cookie": "session=ID~ABCD; Path=/"])
                default: StubResponse(chunks: [payload])
                }
            }
            #expect(try await makeDownload(source: asset, store: store).run() == .finished(finishedURL))
            let transfer = try #require(StubURLProtocol.requests.last)
            #expect(transfer.url == asset)
            #expect(transfer.value(forHTTPHeaderField: "Cookie") == "AssetToken=secret-token")
            let contents = try String(contentsOf: journalURL, encoding: .utf8)
            #expect(!contents.contains("secret-token"))
        }

        /// The Objective-C pause queued behind the blocking handshake, then cancelled the task it created.
        @Test func aPauseDuringAuthorizationTakesEffectBeforeTheTransfer() async throws {
            let asset = try #require(URL(string: "http://oscdn.apple.com/content/downloads/33/InstallESD.dmg"))
            let store = try storeRequiringDigest(of: Data("x".utf8), for: .mavericks, url: asset)
            let reachedHandshake = AsyncStream.makeStream(of: Void.self)
            let pauseSent = DispatchSemaphore(value: 0)
            StubURLProtocol.install { request in
                guard request.httpMethod != "POST" else { return .body("AU: \(asset)\nAT: token\n") }
                reachedHandshake.continuation.yield()
                pauseSent.wait()
                return .body("", headers: ["Set-Cookie": "session=ID~ABCD; Path=/"])
            }
            let download = try makeDownload(source: asset, store: store)
            async let outcome = download.run()
            for await _ in reachedHandshake.stream { break }
            await download.pause()
            pauseSent.signal()
            #expect(try await outcome == .paused)
            #expect(StubURLProtocol.requests.allSatisfy { $0.url?.host == "osrecovery.apple.com" })
        }

        @Test func aRefusedAuthorizationKeepsThePartial() async throws {
            let asset = try #require(URL(string: "http://oscdn.apple.com/content/downloads/33/InstallESD.dmg"))
            let store = try storeRequiringDigest(of: Data(), for: .mavericks, url: asset)
            try Data("part".utf8).write(to: partialURL)
            try PropertyListSerialization.data(
                fromPropertyList: ["FormatVersion": 1, "SourceURL": asset.absoluteString, "ETag": Self.etag]
                    as [String: Any],
                format: .xml, options: 0
            ).write(to: journalURL)
            StubURLProtocol.install { _ in StubResponse(status: 503) }
            await expectFailure(try makeDownload(source: asset, store: store), .source(.recoveryUnavailable))
            #expect(try Data(contentsOf: partialURL) == Data("part".utf8))
        }

        // MARK: - On-disk format

        /// VIMInstallerAssembly's retireCompletedDownloads and VIMNewMachineWindow read this file with these exact checks.
        @Test func theJournalIsWhatTheObjectiveCCallersExpect() async throws {
            serve(Fixture.payload(count: 16))
            #expect(try await makeDownload().run() == .finished(finishedURL))
            let record = try journal()
            #expect((record["FormatVersion"] as? NSNumber)?.isEqual(NSNumber(value: 1)) == true)
            #expect((record["Complete"] as? NSNumber)?.isEqual(NSNumber(value: true)) == true)
            #expect(record["Complete"] as? NSNumber === kCFBooleanTrue)
            #expect((record["Length"] as? NSNumber)?.int64Value == 16)
            #expect(record["SourceURL"] as? String == Self.source.absoluteString)
            #expect(record["ETag"] as? String == Self.etag)
            #expect(record.count == 5)
            let text = try String(contentsOf: journalURL, encoding: .utf8)
            #expect(text.hasPrefix("<?xml"))
            #expect(text.contains("<key>Length</key>") && text.contains("<integer>16</integer>"))
        }

        /// The exact file the Objective-C writer produces for a paused transfer of unknown length.
        @Test func aJournalWrittenByTheObjectiveCAppResumes() async throws {
            let plist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>ETag</key>
                    <string>\(Self.etag.replacingOccurrences(of: "\"", with: "&quot;"))</string>
                    <key>FormatVersion</key>
                    <integer>1</integer>
                    <key>Length</key>
                    <integer>-1</integer>
                    <key>SourceURL</key>
                    <string>\(Self.source.absoluteString)</string>
                </dict>
                </plist>
                """
            try Data(plist.utf8).write(to: journalURL)
            let payload = Fixture.payload(count: 32)
            try payload.prefix(16).write(to: partialURL)
            serve(payload)
            #expect(try await makeDownload().run() == .finished(finishedURL))
            #expect(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Range") == "bytes=16-")
            #expect(try Data(contentsOf: finishedURL) == payload)
        }

        @Test func anUnknownLengthIsJournaledAsMinusOne() async throws {
            // More than URLSession buffers to sniff a content type, or the response never arrives while stalled.
            StubURLProtocol.install { _ in
                StubResponse(headers: ["ETag": Self.etag], chunks: [Data(count: 4096)], stalls: true)
            }
            let download = try makeDownload()
            async let outcome = download.run()
            await waitForFirstProgress(download)
            #expect(try journal()["Length"] as? Int == -1)
            await download.pause()
            #expect(try await outcome == .paused)
        }

        @Test func errorsKeepTheirObjectiveCIdentity() {
            let invalid = DownloadError.invalidResponse(status: 404) as NSError
            #expect(invalid.domain == "VirtualIntelMac.Download" && invalid.code == 2)
            #expect(invalid.localizedDescription == "The server returned an invalid download response (HTTP 404).")
            let other = DownloadError.cannotSave as NSError
            #expect(other.domain == "VirtualIntelMac.Download" && other.code == 1)
            #expect(DownloadError.source(.digestMismatch).bridged.domain == "VirtualIntelMac.InstallerSource")
        }

        @Test func contentRangeReadsOnlyTheCompleteForm() {
            #expect(ContentRange(header: "bytes 4-7/8") != nil)
            #expect(ContentRange(header: "bytes 4-7/*") == nil)
            #expect(ContentRange(header: "bytes 4-7/99999999999999999999") == nil)
        }
    }
}
