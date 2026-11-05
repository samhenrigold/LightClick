// The Objective-C face of InstallerKit. These classes take the names, selectors and dictionary shapes of
// VIMInstallerCatalog, VIMInstallerSource and VIMDownload, to replace them without changing their callers. Only the
// selectors the app calls are here. URL parameters stay optional where a caller can pass nil, which would trap if bridged
// to a non-optional URL. Completions always run on the main thread.

import Foundation

private let store = InstallerCatalogStore()

extension InstallerFile {
    fileprivate var dictionary: [String: Any] {
        var dictionary: [String: Any] = ["Role": role.rawValue, "URL": url.absoluteString]
        dictionary["SHA256"] = sha256?.description
        return dictionary
    }
}

@objc(VIMInstallerCatalog)
public final class InstallerCatalogBridge: NSObject {
    @objc public let supportedInstallers: [[String: Any]]

    init(catalog: InstallerCatalog) {
        supportedInstallers = catalog.installers.map { installer in
            [
                "Guest": installer.guest.rawValue,
                "Name": installer.name,
                "Version": installer.version,
                "Assembly": installer.recipe.rawValue,
                "Files": installer.files.map(\.dictionary)
            ]
        }
    }

    @objc(currentCatalogWithError:)
    public class func current() throws -> InstallerCatalogBridge {
        InstallerCatalogBridge(catalog: try store.current())
    }

    @objc(fileForGuest:role:)
    public class func file(guest: String, role: String) -> [String: Any]? {
        guard let guest = Guest(rawValue: guest), let role = InstallerFile.Role(rawValue: role) else { return nil }
        return (try? store.current())?.file(for: guest, role: role)?.dictionary
    }

    /// Remote data can select approved assembly recipes, never executable commands.
    @objc(refreshWithCompletion:)
    public class func refresh(completion: @escaping @Sendable (InstallerCatalogBridge?, NSError?) -> Void) {
        Task {
            let refresh = await store.refresh()
            await MainActor.run {
                completion(refresh.catalog.map(InstallerCatalogBridge.init(catalog:)), refresh.error as NSError?)
            }
        }
    }

    /// Debug override retains the exact Apple URL path on a loopback HTTP server.
    @objc(downloadURLForAppleURL:)
    public class func downloadURL(forAppleURL url: URL) -> URL {
        InstallerSource.downloadURL(for: url)
    }
}

@objc(VIMInstallerSource)
public final class InstallerSourceBridge: NSObject {
    @objc(isApprovedURL:)
    public class func isApproved(_ url: URL?) -> Bool {
        url.map(InstallerSource.isApproved) ?? false
    }

    /// Error-path guidance only; never blocks a download or reclassifies disk errors.
    @objc(shouldExplainArchiveFailure:source:guest:region:timeZone:)
    public class func shouldExplainArchiveFailure(
        _ error: NSError, source: URL?, guest: String, region: String?, timeZone: String?
    ) -> Bool {
        guard let source, let guest = Guest(rawValue: guest) else { return false }
        return InstallerSource.shouldExplainArchiveFailure(
            error, source: source, guest: guest, region: region, timeZone: timeZone)
    }

    /// Validates the pinned recovery payload. Other assets use their recipe's signature and version validation.
    @objc(verifyFile:source:error:)
    public class func verify(file: URL, source: URL) throws {
        try InstallerSource.verify(file: file, source: source, catalog: try? store.current())
    }
}

/// Main-thread owned, as VIMDownload was. One persistent, app-owned transfer directory per Apple URL. Payload validity
/// here means complete HTTP transfer; installer signature validation is separate.
@MainActor @objc(VIMDownload)
public final class InstallerDownloadBridge: NSObject {
    private let download: InstallerDownload
    private var forwarding: Task<Void, Never>?

    @objc public var directory: URL { download.directory }
    @objc public var sourceURL: URL { download.sourceURL }
    /// Progress uses -1 total when the server gives no size.
    @objc public var progress: ((Int64, Int64) -> Void)?

    @objc(initWithSourceURL:directory:error:)
    public convenience init(sourceURL: URL?, directory: URL?) throws {
        guard let sourceURL, let directory else { throw DownloadError.invalidLocation }
        do throws(DownloadError) {
            self.init(download: try InstallerDownload(source: sourceURL, directory: directory, catalogStore: store))
        } catch {
            throw error.bridged
        }
    }

    init(download: InstallerDownload) {
        self.download = download
        super.init()
        // One task for the bridge's lifetime: cancelling an iteration would end the stream for later runs.
        forwarding = Task { [weak self, stream = download.progress] in
            for await update in stream {
                self?.progress?(update.received, update.total ?? -1)
            }
        }
    }

    deinit {
        forwarding?.cancel()
    }

    @objc(startWithCompletion:)
    public func start(completion: @escaping (URL?, NSError?, Bool) -> Void) {
        Task {
            do throws(DownloadError) {
                switch try await download.run() {
                case .finished(let file): completion(file, nil, false)
                case .paused: completion(nil, nil, true)
                }
            } catch {
                completion(nil, error.bridged, false)
            }
        }
    }

    @objc public func pause() {
        Task { [download] in await download.pause() }
    }
}
