import Foundation

/// A transfer directory's Download.plist. VIMInstallerAssembly and MachineKit's InstallerLength read the same file: Complete is a
/// real Boolean and Length an integer, -1 when the server gave no size.
struct DownloadJournal: Encodable, Hashable, Sendable {
    private static let currentFormat = 1

    private(set) var formatVersion = DownloadJournal.currentFormat
    let sourceURL: String
    var length: Int64?
    var isComplete: Bool?
    var etag: String?
    var lastModified: String?

    enum CodingKeys: String, CodingKey {
        case formatVersion = "FormatVersion"
        case sourceURL = "SourceURL"
        case length = "Length"
        case isComplete = "Complete"
        case etag = "ETag"
        case lastModified = "LastModified"
    }

    init(sourceURL: String) {
        self.sourceURL = sourceURL
    }

    /// The journal at `file` for `sourceURL`. An absent or unparseable file is a fresh start, as it always has been.
    init(contentsOf file: URL, sourceURL: String) throws(DownloadError) {
        self.init(sourceURL: sourceURL)
        guard let stored = NSDictionary(contentsOf: file) else { return }
        guard (stored["FormatVersion"] as? NSNumber)?.isEqual(NSNumber(value: Self.currentFormat)) == true,
            stored["SourceURL"] as? String == sourceURL
        else { throw .foreignDirectory }
        if let value = stored["Length"] {
            // shortcut: a fractional Length, which nothing writes, is invalid rather than never matching a file size.
            guard let number = value as? NSNumber, number.doubleValue == Double(number.int64Value) else {
                throw .invalidState
            }
            length = number.int64Value
        }
        if let value = stored["Complete"] {
            guard let number = value as? NSNumber else { throw .invalidState }
            isComplete = number.boolValue
        }
        // A validator of the wrong type is no validator; it doesn't stop a restart.
        etag = stored["ETag"] as? String
        lastModified = stored["LastModified"] as? String
    }

    func save(to file: URL) throws(DownloadError) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        do {
            try encoder.encode(self).write(to: file, options: .atomic)
        } catch {
            throw .system(error as NSError)
        }
    }

    /// A strong ETag, or failing that Last-Modified: what If-Range can safely name.
    var resumeValidator: String? {
        if let etag, !etag.isEmpty, !etag.hasPrefix("W/") { return etag }
        return lastModified?.isEmpty == false ? lastModified : nil
    }

    /// Forgets a payload that preparation retired.
    mutating func retirePayload() {
        length = nil
        isComplete = nil
        etag = nil
        lastModified = nil
    }
}
