// Compiled host and protocol policy; asset locations and verification values live in the remotely configurable catalog,
// not duplicated in executable code.
//
// Trust boundaries, each ported from the Objective-C and pinned by a test:
// - Catalog (network): size cap, integer revision, one recipe per guest, exact roles, approved URLs, digest format,
//   mandatory recovery digest, and no downgrade at publication (InstallerCatalog, InstallerCatalogStore).
// - Source URL: no credentials, port, query, fragment, encoded host or dot segment; exact scheme, host and path shape
//   (`isApproved`). Plain HTTP only for the one recovery asset, whose digest is then mandatory. The debug server must be plain loopback (`downloadURL`).
// - Recovery service: ephemeral session, 64 KiB replies, hex challenge, the returned asset must equal the requested one,
//   and the token is bounded, free of control characters and never persisted (RecoveryAuthorization).
// - Disk: O_NOFOLLOW and flock on the lock and partial, regular-file checks, foreign and mistyped journals refused, and
//   a digest checked before publishing and on every reuse (InstallerDownload, DownloadJournal, PayloadDigest).
// - HTTP responses: status, exact Content-Range, no ETag change on resume, no content encoding, 100 GiB and declared
//   length caps (InstallerDownload).
import Foundation

/// Where installers may come from, and whether what arrived is what the catalog promised.
public enum InstallerSource {
    /// The Mavericks recovery payload. The legacy CDN has no valid HTTPS certificate for oscdn.apple.com, so this is
    /// the one HTTP asset, and its catalog SHA-256 is mandatory before use.
    public static func isMavericksRecoveryAsset(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "oscdn.apple.com" && url.path.hasPrefix("/content/downloads/")
            && url.lastPathComponent == "InstallESD.dmg" && url.query == nil && url.user == nil
            && url.password == nil && url.port == nil && url.fragment == nil && isUnambiguous(url)
    }

    /// `URL.host` and `URL.path` decode, and a client or server may normalize dot segments, so a percent-encoded host
    /// or a `..` in any spelling could pass these checks and then name something else.
    private static func isUnambiguous(_ url: URL) -> Bool {
        url.host(percentEncoded: true) == url.host
            && !url.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains { $0 == "." || $0 == ".." }
    }

    public static func isApproved(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.port == nil, url.fragment == nil, url.query == nil,
            isUnambiguous(url)
        else {
            return false
        }
        if isMavericksRecoveryAsset(url) { return true }
        guard url.scheme == "https", let host = url.host else { return false }
        if host == "archive.org" || host.hasSuffix(".archive.org") {
            return (url.path.hasPrefix("/download/") || url.path.hasPrefix("/0/items/")) && url.pathExtension == "dmg"
        }
        if host == "swcdn.apple.com" {
            return url.path.hasPrefix("/content/downloads/") && url.pathExtension == "pkg"
        }
        if host == "updates.cdn-apple.com" {
            return ["InstallMacOSX.dmg", "InstallOS.dmg"].contains(url.lastPathComponent)
        }
        return false
    }

    /// Error-path guidance only: whether to mention that archive.org may be blocked. Never blocks a download or
    /// reclassifies disk errors.
    public static func shouldExplainArchiveFailure(
        _ error: any Error, source: URL, guest: Guest, region: String?, timeZone: String?
    ) -> Bool {
        let host = source.host?.lowercased()
        guard guest.traits.contains(.restoreDVD), host == "archive.org" || host?.hasSuffix(".archive.org") == true,
            region?.uppercased() == "CN" || mainlandTimeZones.contains(timeZone ?? "")
        else { return false }
        let error = (error as? DownloadError)?.bridged ?? error as NSError
        if error.domain == DownloadError.errorDomain { return error.code == DownloadError.invalidResponseCode }
        return error.domain == NSURLErrorDomain && regionalFailures.contains(URLError.Code(rawValue: error.code))
    }

    /// The URL to fetch `url` from. A debug override retains the exact Apple path and query on a loopback HTTP server.
    public static func downloadURL(for url: URL, defaults: UserDefaults = .standard) -> URL {
        guard defaults.bool(forKey: "VIMDebugMode"),
            var override = URLComponents(string: defaults.string(forKey: "VIMDownloadServer") ?? ""),
            let host = override.host, ["127.0.0.1", "localhost", "::1"].contains(host),
            override.scheme == "http", override.user == nil, override.password == nil, override.query == nil,
            override.fragment == nil,
            let original = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        override.percentEncodedPath = original.percentEncodedPath
        override.percentEncodedQuery = original.percentEncodedQuery
        return override.url ?? url
    }

    /// Checks a completed file against the catalog's digest. A recovery payload must have one; other assets without
    /// one rely on their recipe's signature and version validation.
    public static func verify(file: URL, source: URL, catalog: InstallerCatalog?) throws(InstallerSourceError) {
        guard let expected = catalog?.file(for: source)?.sha256 else {
            if isMavericksRecoveryAsset(source) { throw .noVerificationRecord }
            return
        }
        guard try PayloadDigest.ofFile(at: file) == expected else { throw .digestMismatch }
    }

    // MARK: - Tables

    private static let mainlandTimeZones: Set<String> = [
        "Asia/Shanghai", "Asia/Chongqing", "Asia/Chungking", "Asia/Harbin", "Asia/Urumqi", "Asia/Kashgar", "PRC"
    ]

    private static let regionalFailures: Set<URLError.Code> = [
        .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
        .resourceUnavailable, .notConnectedToInternet, .badServerResponse, .internationalRoamingOff, .callIsActive,
        .dataNotAllowed, .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid
    ]
}
