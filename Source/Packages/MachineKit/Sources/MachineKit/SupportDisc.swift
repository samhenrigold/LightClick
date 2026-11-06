import Foundation

/// Finding the setup support disc before login, when Disk Arbitration won't have mounted it. Only the uniquely named disc
/// may be mounted, read-only; `guest-macho stage-media` still verifies its manifest and every file before anything runs.
public enum SupportDisc {
    /// The disc's volume name, which guests see. Installed guests and prebuilt images depend on it.
    static let volumeName = "Virtual Intel Mac Support"
    private static let entryLimit = 128

    public enum Lookup: Equatable, Sendable {
        case found(String)
        /// Insertion is acknowledged before the guest's asynchronous CD and HFS probe publishes the partition label.
        case notPublishedYet
    }

    /// The disc's device identifier from `diskutil list -plist`. Only an absence may wait, and only while `mayRetry`:
    /// two matches are an answer, and a retry never repeats a mount with an uncertain outcome.
    public static func lookup(inDiskList result: GuestCommandResult, mayRetry: Bool) throws(GuestPreparationError)
        -> Lookup
    {
        guard let list = result.propertyList else { throw .supportDiscNotLocated }
        guard var queue = list["AllDisksAndPartitions"]?.array, queue.count <= entryLimit else {
            throw .diskListNotRecognized
        }
        var matches: [String] = []
        var index = 0
        while index < queue.count {
            defer { index += 1 }
            guard let entry = queue[index].dictionary else { continue }
            if entry["VolumeName"].isEqual(.string(volumeName)), let device = entry["DeviceIdentifier"]?.string {
                matches.append(device)
            }
            if let partitions = entry["Partitions"]?.array, queue.count + partitions.count <= entryLimit {
                queue += partitions
            }
        }
        if matches.isEmpty && mayRetry { return .notPublishedYet }
        guard matches.count == 1, matches[0].matchesWholly("^disk[0-9]+(s[0-9]+)*$") else {
            throw .supportDiscMissingOrAmbiguous
        }
        return .found(matches[0])
    }

    /// `diskutil info -plist` must name the disc and say it's unwritable.
    public static func verify(info result: GuestCommandResult) throws(GuestPreparationError) {
        let info = result.propertyList ?? [:]
        guard info["VolumeName"].isEqual(.string(volumeName)), info["WritableMedia"].isFalse else {
            throw .supportDiscNotReadOnly
        }
    }

    public static func verify(mount result: GuestCommandResult) throws(GuestPreparationError) {
        guard result.succeeded else { throw .supportDiscMountFailed }
    }
}
