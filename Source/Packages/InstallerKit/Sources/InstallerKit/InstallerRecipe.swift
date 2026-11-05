/// An approved way of assembling an installer. Remote data can select one of these, never an executable command.
public enum InstallerRecipe: String, Codable, Sendable {
    case splitLegacy = "split-legacy"
    case assistantPackage = "assistant-pkg"
    case installerDMG = "installer-dmg"
    case recoveryESD = "recovery-esd"
    case restoreDVD = "restore-dvd"

    /// The exact files this recipe needs.
    public var roles: Set<InstallerFile.Role> {
        switch self {
        case .splitLegacy: [.assistant, .recovery, .esd]
        case .assistantPackage: [.assistant]
        case .installerDMG, .restoreDVD: [.diskImage]
        case .recoveryESD: [.esd]
        }
    }
}
