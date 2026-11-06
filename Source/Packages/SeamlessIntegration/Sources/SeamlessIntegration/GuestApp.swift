import Foundation

/// An app installed in a guest, as its bundle describes it. The guest is untrusted: nothing here is used as a host path
/// or a shell argument without checking.
public struct GuestApp: Codable, Hashable, Sendable {
    public struct DocumentType: Codable, Hashable, Sendable {
        public var name: String?
        public var role: String?
        public var contentTypes: [String] = []
        public var extensions: [String] = []
        public var osTypes: [String] = []

        public init(
            name: String? = nil, role: String? = nil, contentTypes: [String] = [], extensions: [String] = [],
            osTypes: [String] = []
        ) {
            self.name = name
            self.role = role
            self.contentTypes = contentTypes
            self.extensions = extensions
            self.osTypes = osTypes
        }
    }

    public var bundleIdentifier: String
    public var name: String
    public var guestPath: String
    public var version: String?
    public var iconFile: String?
    public var minimumSystemVersion: String?
    public var documentTypes: [DocumentType] = []
    public var urlSchemes: [String] = []

    public init?(infoPlist: [String: Any], guestPath: String) {
        guard let identifier = infoPlist["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }
        bundleIdentifier = identifier
        let bundleName = (guestPath as NSString).lastPathComponent
        name =
            infoPlist["CFBundleDisplayName"] as? String ?? infoPlist["CFBundleName"] as? String
            ?? (bundleName as NSString).deletingPathExtension
        self.guestPath = guestPath
        version = infoPlist["CFBundleShortVersionString"] as? String ?? infoPlist["CFBundleVersion"] as? String
        iconFile = infoPlist["CFBundleIconFile"] as? String
        minimumSystemVersion = infoPlist["LSMinimumSystemVersion"] as? String
        documentTypes = (infoPlist["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).map {
            DocumentType(
                name: $0["CFBundleTypeName"] as? String,
                role: $0["CFBundleTypeRole"] as? String,
                contentTypes: $0["LSItemContentTypes"] as? [String] ?? [],
                extensions: $0["CFBundleTypeExtensions"] as? [String] ?? [],
                osTypes: $0["CFBundleTypeOSTypes"] as? [String] ?? [])
        }
        urlSchemes = (infoPlist["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap {
            $0["CFBundleURLSchemes"] as? [String] ?? []
        }
    }
}

extension GuestApp {
    /// Finds apps in a guest's folders under `root`, which is `/` in the guest, or a read-only mount of its disk on the
    /// host. Paths in the results are guest paths.
    public static func discover(root: URL, folders: [String] = standardFolders) -> [GuestApp] {
        var found: [GuestApp] = []
        let manager = FileManager.default
        for folder in folders {
            let names = (try? manager.contentsOfDirectory(atPath: root.appending(path: folder).path)) ?? []
            for name in names.sorted() where name.hasSuffix(".app") {
                let guestPath = "\(folder)/\(name)"
                let plist = root.appending(path: guestPath).appending(path: "Contents/Info.plist")
                guard let data = try? Data(contentsOf: plist),
                    let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                        as? [String: Any],
                    let app = GuestApp(infoPlist: info, guestPath: guestPath)
                else { continue }
                found.append(app)
            }
        }
        return found
    }

    public static let standardFolders = ["/Applications", "/Applications/Utilities"]
}
