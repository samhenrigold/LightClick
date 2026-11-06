import Foundation

/// State/BootPolicy.plist: the host's record that the guest's boot policy was verified on this volume.
public enum GuestBootPolicyRecord {
    private static func isGuestDirectory(_ value: PropertyListValue?) -> Bool {
        guard let path = value?.string, path.hasPrefix("/private/var/db/VirtualIntelMac.") else { return false }
        let name = path as NSString
        return name.pathComponents.count == 5 && path == name.standardizingPath
            && name.lastPathComponent.utf16.count > 16
    }

    /// Whether the record, the last status report saved beside it and this machine all agree on a finished migration.
    public static func isReady(at journal: URL, guest: PropertyListValue?, identifier: PropertyListValue?) -> Bool {
        let status = GuestInstallationTransaction.record(
            at: journal.deletingLastPathComponent().appendingPathComponent("GuestStatus.plist"))
        let observed = status["Report"]
        guard let state = GuestInstallationTransaction.record(at: journal), state["Result"].isDictionary,
            observed.isDictionary
        else { return false }
        let result = state["Result"]
        return state["FormatVersion"].isEqual(1) && state["MachineIdentifier"].isEqual(identifier)
            && state["Guest"].isEqual(guest) && state["Phase"].isEqual("ready") && state["DispatchAttempted"].isTrue
            && isGuestDirectory(state["GuestDirectory"]) && observed["Guest"].isEqual(guest)
            && observed["VolumeUUID"].isEqual(state["VolumeUUID"]) && result["PreferenceVerified"].isTrue
            && result["TaskForPIDRestrictionDisabled"].isTrue && result["VolumeUUID"].isEqual(state["VolumeUUID"])
            && state["VolumeUUID"].nonEmptyString != nil && result["Guest"].isEqual(guest)
            && result["ProtocolVersion"].isEqual(1)
    }

    /// The read-only verifier the record's migration left in the guest, if it's for this volume.
    public static func verifier(
        at journal: URL, guest: PropertyListValue?, identifier: PropertyListValue?, volume: PropertyListValue?
    ) -> String? {
        let state = GuestInstallationTransaction.record(at: journal)
        guard isReady(at: journal, guest: guest, identifier: identifier), state["VolumeUUID"].isEqual(volume),
            let directory = state["GuestDirectory"]?.string
        else { return nil }
        return (directory as NSString).appendingPathComponent("guest-install")
    }
}
