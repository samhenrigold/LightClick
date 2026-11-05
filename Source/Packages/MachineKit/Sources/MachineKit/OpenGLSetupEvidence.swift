import Foundation
import InstallerKit

/// Classic guests prove their setup with their own volume and OpenGL evidence, not a fabricated Metal receipt.
extension GuestReport {
    /// Old status tools report the identifier from the root-owned setup journal, but expose only a combined ownership
    /// and graphics Boolean. An explicit failure from a newer tool is never eligible for retry.
    public func openGLInitialGraphicsCanResume(
        machine: String?, volume: String?, installing: Bool, systemMatches: Bool
    ) -> Bool {
        guard let machine, let volume else { return false }
        let authorization = self["InstallationOwnershipVerified"]
        return installing && systemMatches && self["KernelMatchesSystem"].isTrue
            && self["MachineIdentifier"].isEqual(.string(machine)) && self["VolumeUUID"].isEqual(.string(volume))
            && (authorization == nil || authorization.isTrue) && self["Graphics"]?.dictionary?.isEmpty == true
    }

    /// Tiger already uses its separate boot-fenced installer, and its graphics repair doesn't replace these controls.
    public func openGLBundledSupportMatches(guest: String?, expected: [String: PropertyListValue]?) -> Bool {
        let graphics = self["Graphics"]
        return graphics["EngineSHA256"].isEqual(expected?["EngineSHA256"])
            && graphics["BackendSHA256"].isEqual(expected?["BackendSHA256"])
            && (guest == Guest.tiger.rawValue || self["GraphicsRestartEvidenceVersion"].isEqual(1))
    }

    /// Older receipts predate the boot field. One acknowledged restart into a different validated boot satisfies only
    /// the exact installed pair, build, machine and volume recorded in that transaction. A stale persistent Boolean
    /// must never become a fresh restart on every cold boot.
    public func openGLGraphicsNeedsRestart(restart: [String: PropertyListValue]?, boot: String?) -> Bool {
        let graphics = self["Graphics"]
        guard graphics["ChangedThisBoot"].boolValue else { return false }
        if let installed = graphics["InstalledBootSessionUUID"].nonEmptyString {
            return boot.map { (installed as NSString).isEqual(to: $0) } ?? false
        }
        guard let restart, restart["RequestState"].isEqual("acknowledged"), restart["FromBootSessionUUID"].isUUID,
            !restart["FromBootSessionUUID"].isEqual(boot.map(PropertyListValue.string)),
            restart["MachineIdentifier"].isEqual(self["MachineIdentifier"])
        else { return true }
        let before = restart["GuestReport"]
        for key in ["MachineIdentifier", "VolumeUUID", "ProductBuildVersion"] where !before[key].isEqual(self[key]) {
            return true
        }
        for key in ["EngineSHA256", "BackendSHA256"] where !before["Graphics"][key].isEqual(graphics[key]) {
            return true
        }
        return false
    }

    /// Matching installed-system and accelerated graphics evidence. A restart is authorized by verified installed files
    /// and identity; actual accelerated pixels are mandatory only for completion. `target` is
    /// State/InstallationTarget.plist.
    public func isOpenGLSetupEvidence(
        on configuration: MachineConfiguration, target: [String: PropertyListValue]?, requirePixels: Bool
    ) -> Bool {
        let graphics = self["Graphics"]
        return configuration.guest?.traits.contains(.openGLDesktop) == true && self["OwnershipVerified"].isTrue
            && self["KernelMatchesSystem"].isTrue && (!requirePixels || self["PixelChecksPassed"].isTrue)
            && self["MachineIdentifier"].isEqual(configuration[.identifier])
            && self["VolumeUUID"].isEqual(target?["VolumeUUID"]) && self["BootSessionUUID"].isUUID
            && graphics["ProductBuildVersion"].isEqual(self["ProductBuildVersion"])
            && graphics["Phase"].isEqual("installed")
            && (configuration.guest != .tiger || self["GraphicsFilesVerified"].isTrue)
    }

    /// Completion's further check: the first-login handoff, when automatic setup was enabled, must have finished too.
    public func hasFinishedFirstLogin(automaticSetup: [String: PropertyListValue]?) -> Bool {
        !(automaticSetup ?? [:])["Enabled"].boolValue || self["Account"]["Phase"].isEqual("complete")
    }
}
