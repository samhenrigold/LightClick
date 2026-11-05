// One persistent, app-owned transfer directory per Apple URL: Download.lock, Download.plist, Payload.partial, then
// Payload.pkg. Validity here means a complete HTTP transfer and the catalog's digest if it has one; installer signature
// validation is separate. The actor runs on its own serial queue, which is also the URLSession delegate queue, so
// writes happen synchronously in delegate callbacks (slowing the transfer, not queueing bytes in memory) and blocking
// disk work never occupies a cooperative thread.
import Foundation

/// How far a transfer has got.
public struct DownloadProgress: Hashable, Sendable {
    public let received: Int64
    /// `nil` when the server gives no size.
    public let total: Int64?
}

/// How a run ended without an error.
public enum DownloadOutcome: Hashable, Sendable {
    case finished(URL)
    /// The bytes and journal are on disk; a new run resumes from them.
    case paused
}

/// A resumable transfer of an approved installer URL into a directory.
public actor InstallerDownload {
    private static let maximumLength: Int64 = 100 * 1024 * 1024 * 1024
    private static let progressInterval: TimeInterval = 0.2

    public nonisolated let sourceURL: URL
    public nonisolated let directory: URL
    /// The latest progress, at most five times a second, for this object's lifetime across runs. Cancel the task
    /// consuming it when the run returns.
    public nonisolated let progress: AsyncStream<DownloadProgress>

    private enum Phase {
        case idle, preparing, authorizing, transferring
    }

    private let queue = DispatchSerialQueue(label: "InstallerKit.Download", qos: .utility)
    private let progressContinuation: AsyncStream<DownloadProgress>.Continuation
    private let catalogStore: InstallerCatalogStore
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    /// Where bytes really come from: `sourceURL`, unless the debug override names a loopback server.
    private let fetchURL: URL

    private var phase = Phase.idle
    private var partial: Int32 = -1
    private var lock: Int32 = -1
    private var received: Int64 = 0
    private var total: Int64?
    private var journal: DownloadJournal
    private var failure: DownloadError?
    private var isPausing = false
    private var isAccepted = false
    private var lastProgress = Date.distantPast
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completion: CheckedContinuation<Result<DownloadOutcome, DownloadError>, Never>?

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var journalURL: URL { directory.appending(component: "Download.plist") }
    private var lockURL: URL { directory.appending(component: "Download.lock") }
    private var partialURL: URL { directory.appending(component: "Payload.partial") }
    private var finishedURL: URL { directory.appending(component: "Payload.pkg") }

    /// - Parameters:
    ///   - fetchURL: Where to request the bytes, if not `InstallerSource.downloadURL(for: source)`. The source's policy,
    ///     headers and digest still apply.
    ///   - makeConfiguration: The base session configuration, which tests replace with a stub.
    public init(
        source: URL,
        directory: URL,
        catalogStore: InstallerCatalogStore,
        fetchURL: URL? = nil,
        makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) throws(DownloadError) {
        guard InstallerSource.isApproved(source), directory.isFileURL else { throw .invalidLocation }
        sourceURL = source
        self.directory = directory.resolvingSymlinksInPath()
        self.catalogStore = catalogStore
        self.fetchURL = fetchURL ?? InstallerSource.downloadURL(for: source)
        self.makeConfiguration = makeConfiguration
        journal = DownloadJournal(sourceURL: source.absoluteString)
        let stream = AsyncStream.makeStream(of: DownloadProgress.self, bufferingPolicy: .bufferingNewest(1))
        progress = stream.stream
        progressContinuation = stream.continuation
    }

    /// Transfers until the file is complete, or `pause()` or cancellation stops it. Both keep the partial bytes.
    public func run() async throws(DownloadError) -> DownloadOutcome {
        guard phase == .idle else { throw .alreadyRunning }
        phase = .preparing
        isPausing = false
        failure = nil
        isAccepted = false
        let result = await withTaskCancellationHandler {
            await transfer()
        } onCancel: {
            Task { await self.pause() }
        }
        finish()
        phase = .idle
        return try result.get()
    }

    /// Stops a transfer that has reached the network. Earlier than that, or once it has ended, this does nothing.
    public func pause() {
        guard phase == .authorizing || phase == .transferring else { return }
        isPausing = true
        task?.cancel()
    }

    // MARK: - Preparing

    private func transfer() async -> Result<DownloadOutcome, DownloadError> {
        let validator: String?
        do throws(DownloadError) {
            switch try prepare() {
            case .ended(let result): return result
            case .needsRequest(let resumeValidator): validator = resumeValidator
            }
        } catch {
            return .failure(error)
        }
        phase = .authorizing
        var request = URLRequest(
            url: fetchURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        do throws(InstallerSourceError) {
            let headers = try await InstallerSource.authorizationHeaders(
                for: sourceURL, makeConfiguration: makeConfiguration)
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
        } catch {
            return Task.isCancelled ? .success(.paused) : .failure(.source(error))
        }
        guard !isPausing, !Task.isCancelled else { return .success(.paused) }
        if received > 0 {
            request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        let configuration = makeConfiguration()
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        // URLSession's ordinary redirect handling. CDN redirects are not a new catalog source; the original source's
        // completed-file checks remain in force.
        let session = URLSession(
            configuration: configuration, delegate: TransferDelegate(owner: self), delegateQueue: delegateQueue)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        phase = .transferring
        return await withCheckedContinuation { continuation in
            completion = continuation
            task.resume()
        }
    }

    private enum Preparation {
        case ended(Result<DownloadOutcome, DownloadError>)
        case needsRequest(resumeValidator: String?)
    }

    private func prepare() throws(DownloadError) -> Preparation {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .system(error as NSError)
        }
        lock = openExclusively(lockURL)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw .lockedByAnotherProcess }
        journal = try DownloadJournal(contentsOf: journalURL, sourceURL: sourceURL.absoluteString)

        // Recover an interruption between the final rename and the completion journal.
        let finishedExists = (try? FileManager.default.attributesOfItem(atPath: finishedURL.path)) != nil
        if journal.isComplete != true, finishedFileMatchesJournal {
            journal.isComplete = true
            try journal.save(to: journalURL)
        }
        if journal.isComplete == true {
            if finishedFileMatchesJournal {
                try verify(finishedURL)
                return .ended(.success(.finished(finishedURL)))
            }
            guard !finishedExists else { throw .incompleteCache }
            // Preparation retired the completed payload. A crash between its unlink and the journal's removal must not
            // make this URL unresumable.
            journal.retirePayload()
            try journal.save(to: journalURL)
        }

        partial = openExclusively(partialURL)
        var status = stat()
        guard partial >= 0, flock(partial, LOCK_EX | LOCK_NB) == 0, fstat(partial, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG
        else { throw .cannotOpenPartial }
        received = status.st_size
        if received > 0, received == journal.length {
            isAccepted = true
            total = received
            return .ended(completeTransfer(nil))
        }
        let validator = journal.resumeValidator
        if received > 0, validator == nil {
            guard ftruncate(partial, 0) == 0 else { throw .cannotRestartPartial }
            received = 0
        }
        try journal.save(to: journalURL)
        return .needsRequest(resumeValidator: validator)
    }

    /// A regular file, not a link to one, of the journal's length.
    private var finishedFileMatchesJournal: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: finishedURL.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return false }
        return size > 0 && size == journal.length
    }

    /// Neither of a transfer directory's descriptors follows a link.
    private func openExclusively(_ file: URL) -> Int32 {
        file.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1
        }
    }

    private func verify(_ file: URL) throws(DownloadError) {
        do {
            try InstallerSource.verify(file: file, source: sourceURL, catalog: try? catalogStore.current())
        } catch {
            throw .source(error)
        }
    }

    // MARK: - Transferring

    private func accept(_ response: URLResponse) -> URLSession.ResponseDisposition {
        do {
            try validate(response)
            isAccepted = true
            return .allow
        } catch {
            failure = error
            return .cancel
        }
    }

    private func validate(_ response: URLResponse) throws(DownloadError) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard let http, status == 200 || status == 206 else { throw .invalidResponse(status: status) }
        let etag = http.value(forHTTPHeaderField: "ETag")
        if status == 206 {
            guard let range = http.value(forHTTPHeaderField: "Content-Range").flatMap(ContentRange.init(header:)),
                range.first == received, range.last >= range.first, range.total > range.last,
                range.total <= Self.maximumLength, range.last == range.total - 1
            else { throw .invalidResponse(status: status) }
            if let previous = journal.etag, !previous.hasPrefix("W/"), let etag, previous != etag {
                throw .invalidResponse(status: status)
            }
            total = range.total
        } else {
            // If-Range mismatch or ignored Range: replace, never append a full body.
            guard received == 0 || ftruncate(partial, 0) == 0 else { throw .invalidResponse(status: status) }
            received = 0
            total = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), !encoding.isEmpty,
            encoding.lowercased() != "identity"
        {
            throw .invalidResponse(status: status)
        }
        if let total, total > Self.maximumLength { throw .invalidResponse(status: status) }
        guard lseek(partial, received, SEEK_SET) >= 0 else { throw .cannotPositionPartial }
        journal.etag = etag
        journal.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        journal.length = total ?? -1
        try journal.save(to: journalURL)
    }

    private func append(_ data: Data, task: URLSessionTask) {
        guard isAccepted, failure == nil else { return }
        let count = Int64(data.count)
        if received > Self.maximumLength - count || total.map({ count > $0 - received }) == true {
            failure = .exceededExpectedLength
            task.cancel()
            return
        }
        let saved = data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(partial, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
                received += Int64(written)
            }
            return true
        }
        guard saved else {
            failure = .cannotSave
            task.cancel()
            return
        }
        let now = Date.now
        if now.timeIntervalSince(lastProgress) >= Self.progressInterval {
            lastProgress = now
            progressContinuation.yield(DownloadProgress(received: received, total: total))
        }
    }

    private func taskCompleted(_ error: NSError?) {
        completion?.resume(returning: completeTransfer(error))
        completion = nil
    }

    private func completeTransfer(_ error: NSError?) -> Result<DownloadOutcome, DownloadError> {
        if isPausing { return .success(.paused) }
        if let failure { return .failure(failure) }
        if let error { return .failure(.system(error)) }
        guard isAccepted, received > 0, total.map({ $0 == received }) ?? true else {
            return .failure(.incompleteTransfer)
        }
        guard fsync(partial) == 0 else { return .failure(.cannotFlush) }
        do throws(DownloadError) {
            // A failure retains the bytes for diagnosis but never publishes them as complete.
            try verify(partialURL)
            do {
                try FileManager.default.moveItem(at: partialURL, to: finishedURL)
            } catch {
                throw .system(error as NSError)
            }
            journal.isComplete = true
            journal.length = received
            try journal.save(to: journalURL)
            return .success(.finished(finishedURL))
        } catch {
            return .failure(error)
        }
    }

    private func finish() {
        if partial >= 0 {
            fsync(partial)
            close(partial)
            partial = -1
        }
        if lock >= 0 {
            close(lock)
            lock = -1
        }
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
    }

    // MARK: - Delegate

    /// Runs on the actor's queue, because that underlies the session's delegate queue.
    private final class TransferDelegate: NSObject, URLSessionDataDelegate, Sendable {
        let owner: InstallerDownload

        init(owner: InstallerDownload) {
            self.owner = owner
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            completionHandler(owner.assumeIsolated { $0.accept(response) })
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner.assumeIsolated { $0.append(data, task: dataTask) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            owner.assumeIsolated { $0.taskCompleted(error as NSError?) }
        }
    }
}

/// A complete `Content-Range` header value.
struct ContentRange: Hashable {
    let first: Int64
    let last: Int64
    let total: Int64

    init?(header: String) {
        guard let match = header.wholeMatch(of: /bytes ([0-9]+)-([0-9]+)\/([0-9]+)/),
            let first = Int64(match.1), let last = Int64(match.2), let total = Int64(match.3)
        else { return nil }
        self.first = first
        self.last = last
        self.total = total
    }
}
