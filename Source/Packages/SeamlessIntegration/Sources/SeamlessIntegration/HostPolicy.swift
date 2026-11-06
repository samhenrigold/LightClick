import Foundation

/// What a guest may ask the host to do. Old guests run browsers and mail clients with long-dead TLS and known holes, so
/// each path from guest to host defaults to closed.
public enum HostPolicy {
    /// Links a guest app may hand to the host's default handler. Not `file`, not custom schemes: those would let guest
    /// code open host apps with arguments of its choosing.
    public static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    public static func openableURL(_ text: String) -> URL? {
        // A web link longer than this is more likely to be an exploit than a page.
        guard text.utf8.count <= 8192, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            openableSchemes.contains(scheme)
        else { return nil }
        if scheme != "mailto", url.host()?.isEmpty != false { return nil }
        return url
    }
}

/// Maps between a host document and the path a guest sees through a shared folder. Refuses anything outside the share,
/// whichever way it's going, and any `..` a guest sends.
public struct SharedFolderMapping: Hashable, Sendable {
    public var hostRoot: String
    public var guestRoot: String

    public init(hostRoot: String, guestRoot: String) {
        self.hostRoot = (hostRoot as NSString).standardizingPath
        self.guestRoot = (guestRoot as NSString).standardizingPath
    }

    public func guestPath(forHost path: String) -> String? {
        let standard = Self.resolved(path)
        let root = Self.resolved(hostRoot)
        guard standard == root || standard.hasPrefix(root + "/") else { return nil }
        return guestRoot + standard.dropFirst(root.count)
    }

    public func hostPath(forGuest path: String) -> String? {
        guard path == guestRoot || path.hasPrefix(guestRoot + "/") else { return nil }
        let rest = path.dropFirst(guestRoot.count)
        guard !rest.split(separator: "/").contains("..") else { return nil }
        let joined = hostRoot + rest
        let resolved = Self.resolved(joined)
        let root = Self.resolved(hostRoot)
        guard resolved == root || resolved.hasPrefix(root + "/") else { return nil }
        return joined
    }

    /// Follows every symlink in the part of the path that exists. A file about to be created through a link must count
    /// as where the link leads, which `resolvingSymlinksInPath` doesn't do for a missing leaf.
    static func resolved(_ path: String) -> String {
        var existing = (path as NSString).standardizingPath
        var rest: [String] = []
        while existing != "/" {
            if let real = realpath(existing, nil) {
                defer { free(real) }
                return ([String(cString: real)] + rest).joined(separator: "/")
            }
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return "/" + rest.joined(separator: "/")
    }
}
