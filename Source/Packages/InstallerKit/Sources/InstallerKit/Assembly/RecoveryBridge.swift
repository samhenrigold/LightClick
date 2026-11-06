// The Objective-C face of RecoveryEdits and HybridMedia.
import Foundation

@objc(VIMRecoveryEditKind)
public enum RecoveryEditKind: Int {
    case installSupport, createScript, patchStartup, symlink, prepareAutomaticInstaller
}

@objc(VIMRecoveryEdit)
public final class RecoveryEditBridge: NSObject {
    private let value: RecoveryEdit

    init(_ value: RecoveryEdit) {
        self.value = value
    }

    @objc public var kind: RecoveryEditKind {
        switch value {
        case .installSupport: .installSupport
        case .createScript: .createScript
        case .patchStartup: .patchStartup
        case .symlink: .symlink
        case .prepareAutomaticInstaller: .prepareAutomaticInstaller
        }
    }

    /// Relative to the attached working copy. Nil only for preparing the automatic installer.
    @objc public var path: String? {
        switch value {
        case .installSupport(let path), .createScript(let path, _), .patchStartup(let path, _), .symlink(let path, _):
            path
        case .prepareAutomaticInstaller: nil
        }
    }

    /// A new script's contents.
    @objc public var contents: String? {
        if case .createScript(_, let contents) = value { contents } else { nil }
    }

    /// A symlink's target.
    @objc public var destination: String? {
        if case .symlink(_, let destination) = value { destination } else { nil }
    }

    /// The script to write, or nil when `original` isn't the one this patch recognizes.
    @objc(patched:)
    public func patched(_ original: String?) -> String? {
        if case .patchStartup(_, let patch) = value { patch.applied(to: original) } else { nil }
    }

    /// Why a patch refused. Only a startup patch can.
    @objc public var unrecognizedFailure: AssemblyFailure {
        if case .patchStartup(_, .highSierraOpenDocument) = value {
            .highSierraStartupUnrecognized
        } else {
            .automaticLaunchUnrecognized
        }
    }
}

extension GuestMediaPlanBridge {
    @objc public var recoveryEdits: [RecoveryEditBridge] { guest.recoveryEdits.map(RecoveryEditBridge.init) }
    @objc public var recoveryInstallerPath: String? { guest.recoveryInstallerPath }

    /// Whether a finished image, attached read-only at `mount`, holds what this guest's media must.
    @objc(requirementsSatisfiedAtMount:)
    public func requirementsSatisfied(at mount: URL) -> Bool {
        guest.mediaRequirements.allSatisfy { $0.isSatisfied(at: mount) }
    }
}

@objc(VIMRecoveryText)
public final class RecoveryTextBridge: NSObject {
    @objc(bypassingModelCheck:)
    public class func bypassingModelCheck(_ original: String?) -> String? {
        RecoveryText.bypassingModelCheck(original)
    }

    @objc(raisingRAMDiskBudgets:)
    public class func raisingRAMDiskBudgets(_ script: String) -> String {
        RecoveryText.raisingRAMDiskBudgets(script)
    }

    @objc(hasSerialHook:)
    public class func hasSerialHook(_ rcInstall: String?) -> Bool {
        RecoveryText.hasSerialHook(rcInstall)
    }

    @objc public class var serialHookScript: String { RecoveryText.serialHookScript }

    @objc(openingInstallationPlan:selectingRosetta:)
    public class func openingInstallationPlan(_ text: String?, selectingRosetta: Bool) -> String? {
        RecoveryText.openingInstallationPlan(text, selectingRosetta: selectingRosetta)
    }

    @objc(isSignedAppleSoftware:)
    public class func isSignedAppleSoftware(_ output: String?) -> Bool {
        RecoveryText.isSignedAppleSoftware(output)
    }

    @objc(acceptsAutomaticInstallerEntitlements:)
    public class func acceptsAutomaticInstaller(entitlements: Any?) -> Bool {
        RecoveryText.acceptsAutomaticInstaller(entitlements: entitlements)
    }
}

@objc(VIMHybridMedia)
public final class HybridMediaBridge: NSObject {
    @objc public class var guest: String { Guest.bigSur.rawValue }
    @objc public class var volumeName: String { HybridMedia.volumeName }
    @objc public class var assetDirectory: String { HybridMedia.assetDirectory }
    @objc public class var assetMetadata: String { HybridMedia.assetMetadata }
    @objc public class var blessedDirectory: String { HybridMedia.blessedDirectory }
    @objc public class var extractedManifests: String { HybridMedia.extractedManifests }
    @objc public class var bootPlistPath: String { HybridMedia.bootPlistPath }
    @objc public class var installerCookiePath: String { HybridMedia.installerCookiePath }
    @objc public class var archiveMembers: [String] { HybridMedia.archiveMembers }
    @objc public class var stagedFiles: [String: String] { HybridMedia.stagedFiles }
    @objc public class var bootPlist: [String: String] { HybridMedia.bootPlist }

    @objc(installerCookieForApplication:productVersion:productBuild:)
    public class func installerCookie(applicationName: String, productVersion: String, productBuild: String)
        -> [String: String]
    {
        HybridMedia.installerCookie(
            applicationName: applicationName, productVersion: productVersion, productBuild: productBuild)
    }
}
