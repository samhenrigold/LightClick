import Foundation

/// Whether this app carries newer guest support than a machine last prepared, so the machine window can offer the update.
/// The packaged digest is in the runtime's `Packaging.plist`; what a machine got is in its preparation journal.
public enum GuestPayloadUpdate {
    /// The packaged support archive's digest for a guest, or nil when the runtime doesn't say.
    public static func bundledDigest(packaging: Data?, guest: String) -> String? {
        guard let packaging,
            let plist = try? PropertyListSerialization.propertyList(from: packaging, format: nil) as? [String: Any],
            let guests = (plist["GuestPayloads"] as? [String: Any])?["Guests"] as? [String: Any]
        else { return nil }
        return (guests[guest] as? [String: Any])?["ArchiveSHA256"] as? String
    }

    /// What a preparation journal recorded about the support it was preparing. Machines prepared before this was
    /// recorded have neither.
    public static func prepared(journal: Data?) -> (digest: String?, appVersion: String?) {
        guard let journal,
            let plist = try? PropertyListSerialization.propertyList(from: journal, format: nil) as? [String: Any]
        else { return (nil, nil) }
        return (plist["PayloadSHA256"] as? String, plist["AppVersion"] as? String)
    }

    /// Offer the update when the support differs and this app is newer than the one that prepared the machine. A
    /// machine with no record is offered it once, as it predates the record; an older app never offers its support.
    public static func offersUpdate(
        preparedDigest: String?, preparedAppVersion: String?, bundledDigest: String?, appVersion: String
    ) -> Bool {
        guard let bundledDigest, preparedDigest != bundledDigest else { return false }
        guard let preparedAppVersion else { return true }
        return isVersion(appVersion, newerThan: preparedAppVersion)
    }

    /// Dotted numeric versions: "1.10" is newer than "1.9", and "2" than "1.9.9". Anything that isn't numbers isn't newer.
    public static func isVersion(_ version: String, newerThan other: String) -> Bool {
        func numbers(_ text: String) -> [Int]? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap(\.self)
        }
        guard let mine = numbers(version), let theirs = numbers(other) else { return false }
        for index in 0..<max(mine.count, theirs.count) {
            let a = index < mine.count ? mine[index] : 0
            let b = index < theirs.count ? theirs[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

@objc(VIMGuestPayloadUpdate)
public final class GuestPayloadUpdateBridge: NSObject {
    /// Whether the machine's window should offer this app's newer guest support.
    @objc public class func offersUpdate(machine: URL, guest: String, runtime: URL, appVersion: String) -> Bool {
        let journal = machine.appendingPathComponent("State/GuestPreparation.plist")
        let prepared = GuestPayloadUpdate.prepared(journal: try? Data(contentsOf: journal))
        return GuestPayloadUpdate.offersUpdate(
            preparedDigest: prepared.digest, preparedAppVersion: prepared.appVersion,
            bundledDigest: GuestPayloadUpdate.bundledDigest(
                packaging: try? Data(contentsOf: runtime.appendingPathComponent("Packaging.plist")), guest: guest),
            appVersion: appVersion)
    }
}
