import Foundation

/// The outcome of a refresh. An update failure still carries the best catalog available, so an open wizard keeps going.
public struct CatalogRefresh: Sendable {
    public let catalog: InstallerCatalog?
    public let error: CatalogError?
}

/// The bundled catalog, the cached copy of the newest remote one, and the rule choosing between them.
public final class InstallerCatalogStore: Sendable {
    public static let defaultRemoteURL = URL(
        string: "https://raw.githubusercontent.com/samhenrigold/LightClick/refs/heads/main/"
            + "Source/VirtualIntelMac/InstallerCatalog.plist")!

    public static var defaultCacheURL: URL {
        URL.applicationSupportDirectory.appending(components: "Light Click", "InstallerCatalog.plist")
    }

    private let bundledURL: URL?
    private let cacheURL: URL
    private let remoteURL: URL
    private let session: URLSession
    /// Held across compare-and-publish. Concurrent refreshes may finish out of order.
    private let publication = NSLock()

    public init(
        bundledURL: URL? = Bundle.main.url(forResource: "InstallerCatalog", withExtension: "plist"),
        cacheURL: URL = InstallerCatalogStore.defaultCacheURL,
        remoteURL: URL = InstallerCatalogStore.defaultRemoteURL,
        session: URLSession = .shared
    ) {
        self.bundledURL = bundledURL
        self.cacheURL = cacheURL
        self.remoteURL = remoteURL
        self.session = session
    }

    /// The newer of the bundled and cached catalogs, read afresh: another process may have published since.
    public func current() throws(CatalogError) -> InstallerCatalog {
        let catalogs = [bundledURL, cacheURL].map { url in
            url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? InstallerCatalog(data: $0) }
        }
        guard let catalog = InstallerCatalog.preferred(catalogs[1], over: catalogs[0]) else { throw .unavailable }
        return catalog
    }

    /// Fetches the remote catalog and caches it only if it's newer. Remote data can select approved assembly recipes,
    /// never executable commands.
    public func refresh() async -> CatalogRefresh {
        var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("VirtualIntelMac/1", forHTTPHeaderField: "User-Agent")
        var failure: CatalogError?
        var fetched: (catalog: InstallerCatalog, data: Data)?
        do {
            let (data, response) = try await session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                fetched = (try InstallerCatalog(data: data), data)
            } else {
                failure = .updateFailed
            }
        } catch let error as CatalogError {
            failure = error
        } catch {
            failure = .system(error as NSError)
        }
        // Compare at publication, not when starting the request. Never replace a newer cache or return an older remote
        // catalog to an already-open wizard.
        let selected = publication.withLock {
            let existing = try? current()
            guard let fetched, fetched.catalog.revision > existing?.revision ?? 0 else { return existing }
            do {
                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fetched.data.write(to: cacheURL, options: .atomic)
            } catch {
                failure = .system(error as NSError)
            }
            return fetched.catalog
        }
        // Another response may have published since unlocking.
        return CatalogRefresh(catalog: InstallerCatalog.preferred(selected, over: try? current()), error: failure)
    }
}
