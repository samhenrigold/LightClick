// The validating reader of InstallerCatalog.plist. A catalog arrives over the network, so every value here has passed
// the schema, the guest's recipe and the source policy. The types are deliberately not Decodable: this initializer is
// the only way to make one. It reads through NSPropertyListSerialization because the rules (an integer Revision, not a
// real or a Boolean) are about plist types that Codable would coerce.
import CoreFoundation
import Foundation

/// A file an installer needs.
public struct InstallerFile: Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case assistant
        case recovery
        case esd
        case diskImage = "diskimage"
    }

    public let role: Role
    public let url: URL
    /// Mandatory for a recovery payload; the other recipes also validate signatures and versions.
    public let sha256: PayloadDigest?
}

/// A guest's installer as a catalog describes it.
public struct Installer: Hashable, Sendable {
    public let guest: Guest
    public let name: String
    public let version: String
    public let recipe: InstallerRecipe
    public let files: [InstallerFile]
}

/// A validated installer catalog, one installer per supported guest.
public struct InstallerCatalog: Hashable, Sendable {
    private static let maximumSize = 262144
    private static let maximumInstallers = 16

    public let revision: Int
    public let installers: [Installer]

    public init(data: Data) throws(CatalogError) {
        guard !data.isEmpty, data.count <= Self.maximumSize else { throw .emptyOrTooLarge }
        let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        guard let root = object as? NSDictionary,
            (root["FormatVersion"] as? NSNumber)?.isEqual(NSNumber(value: 1)) == true,
            let revision = Self.parseRevision(root["Revision"]),
            let entries = root["Installers"] as? NSArray, entries.count <= Self.maximumInstallers
        else { throw .invalid }
        var seen = Set<Guest>()
        var installers: [Installer] = []
        for entry in entries {
            guard let installer = Self.parseInstaller(entry), seen.insert(installer.guest).inserted else {
                throw .invalid
            }
            installers.append(installer)
        }
        guard installers.count == Guest.allCases.count else { throw .invalid }
        self.revision = revision
        self.installers = installers
    }

    /// The copy to use. Equal revisions keep the baseline: catalog maintainers must increment Revision whenever URLs
    /// or other metadata change.
    static func preferred(_ candidate: InstallerCatalog?, over baseline: InstallerCatalog?) -> InstallerCatalog? {
        guard let candidate else { return baseline }
        guard let baseline else { return candidate }
        return candidate.revision > baseline.revision ? candidate : baseline
    }

    public func file(for guest: Guest, role: InstallerFile.Role) -> InstallerFile? {
        installers.first { $0.guest == guest }?.files.first { $0.role == role }
    }

    public func file(for url: URL) -> InstallerFile? {
        installers.lazy.flatMap(\.files).first { $0.url.absoluteString == url.absoluteString }
    }

    /// Whether `url` is this guest's own restore DVD, so one release's image can't stand in for another's.
    public func isRestoreDVDAsset(_ url: URL, for guest: Guest) -> Bool {
        guest.traits.contains(.restoreDVD)
            && file(for: guest, role: .diskImage)?.url.absoluteString == url.absoluteString
    }

    // MARK: - Schema

    /// A positive integer that fits an Int. Booleans and reals are NSNumbers too.
    private static func parseRevision(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) == CFNumberGetTypeID(),
            !CFNumberIsFloatType(number as CFNumber), number.compare(NSNumber(value: 1)) != .orderedAscending,
            number.compare(NSNumber(value: Int.max)) != .orderedDescending
        else { return nil }
        return number.intValue
    }

    private static func parseInstaller(_ value: Any) -> Installer? {
        guard let entry = value as? NSDictionary,
            let guest = (entry["Guest"] as? String).flatMap(Guest.init(rawValue:)),
            let name = entry["Name"] as? String, (1...80).contains(name.utf16.count),
            let version = entry["Version"] as? String, version.utf16.count <= 30,
            let recipe = (entry["Assembly"] as? String).flatMap(InstallerRecipe.init(rawValue:)),
            recipe == guest.recipe,
            let entries = entry["Files"] as? NSArray
        else { return nil }
        var roles = Set<InstallerFile.Role>()
        var files: [InstallerFile] = []
        for fileEntry in entries {
            guard let file = parseFile(fileEntry, recipe: recipe), roles.insert(file.role).inserted else { return nil }
            files.append(file)
        }
        guard roles == recipe.roles else { return nil }
        return Installer(guest: guest, name: name, version: version, recipe: recipe, files: files)
    }

    private static func parseFile(_ value: Any, recipe: InstallerRecipe) -> InstallerFile? {
        guard let entry = value as? NSDictionary,
            let location = entry["URL"] as? String, let url = URL(string: location),
            let role = (entry["Role"] as? String).flatMap(InstallerFile.Role.init(rawValue:)),
            InstallerSource.isApproved(url)
        else { return nil }
        switch recipe {
        case .recoveryESD:
            guard InstallerSource.isMavericksRecoveryAsset(url) else { return nil }
        case .installerDMG:
            guard url.host == "updates.cdn-apple.com" else { return nil }
        case .restoreDVD:
            guard url.host == "archive.org" || url.host?.hasSuffix(".archive.org") == true else { return nil }
        case .splitLegacy, .assistantPackage:
            break
        }
        var digest: PayloadDigest?
        if let hash = entry["SHA256"] {
            guard let text = hash as? String, let parsed = PayloadDigest(hexadecimal: text) else { return nil }
            digest = parsed
        }
        if recipe == .recoveryESD, digest == nil { return nil }
        return InstallerFile(role: role, url: url, sha256: digest)
    }
}
