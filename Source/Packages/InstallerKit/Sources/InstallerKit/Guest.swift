// One case per supported guest, oldest first, so adding or correcting a guest is one edit. Raw values are the
// identifiers in saved machines, reports and the installer catalog; installed libraries depend on them.

/// A guest operating system.
///
/// Reports and saved plists are untrusted: `Guest(rawValue:)` is the only way in from a string.
public enum Guest: String, CaseIterable, Codable, Sendable {
    case tiger
    case leopard
    case snowLeopard = "snowleopard"
    case lion
    case mountainLion = "mountainlion"
    case mavericks
    case yosemite
    case elCapitan = "elcapitan"
    case sierra
    case highSierra = "highsierra"
    case mojave
    case catalina
    case bigSur = "bigsur"

    /// The marketing family a release shipped under.
    public enum Family: String, Codable, Sendable {
        case macOSX = "Mac OS X"
        case osX = "OS X"
        case macOS
    }

    /// What differs between guests. Raw values match `VIMGuestTraits`.
    public struct Traits: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// Desktop graphics architecture, deliberately independent of whether the account/installer automation backend
        /// supports this guest version.
        public static let openGLDesktop = Traits(rawValue: 1 << 0)
        public static let paravirtualizedGraphics = Traits(rawValue: 1 << 1)
        /// Installs from a whole restore DVD, not an Install app.
        public static let restoreDVD = Traits(rawValue: 1 << 2)
        /// These systems have no distinct backing-pixel/logical-point mode.
        public static let noBackingScale = Traits(rawValue: 1 << 3)
        /// Reaches host files over SMB1, which macOS only offers as Windows File Sharing.
        public static let windowsFileSharing = Traits(rawValue: 1 << 4)
        public static let usb2StoragePassthrough = Traits(rawValue: 1 << 5)
        /// El Capitan introduced the native USBHost xHCI driver used for extra images.
        public static let usb3Images = Traits(rawValue: 1 << 6)
        public static let legacyTabletCalibration = Traits(rawValue: 1 << 7)
        public static let noRoundelArtwork = Traits(rawValue: 1 << 8)

        fileprivate static let classic: Traits = [
            .openGLDesktop, .restoreDVD, .noBackingScale, .windowsFileSharing, .usb2StoragePassthrough,
            .legacyTabletCalibration, .noRoundelArtwork
        ]
    }

    public var family: Family { facts.family }
    public var name: String { facts.name }
    public var version: String { facts.version }
    public var traits: Traits { facts.traits }
    /// The only assembly a catalog may select for this guest.
    public var recipe: InstallerRecipe { facts.recipe }
    /// "OS X Mavericks 10.9"
    public var systemName: String { "\(family.rawValue) \(name) \(version)" }

    private var facts: (family: Family, name: String, version: String, traits: Traits, recipe: InstallerRecipe) {
        switch self {
        case .tiger: (.macOSX, "Tiger", "10.4", .classic, .restoreDVD)
        case .leopard: (.macOSX, "Leopard", "10.5", .classic, .restoreDVD)
        case .snowLeopard: (.macOSX, "Snow Leopard", "10.6", .classic, .restoreDVD)
        case .lion: (.macOSX, "Lion", "10.7", [.openGLDesktop, .legacyTabletCalibration], .installerDMG)
        case .mountainLion: (.osX, "Mountain Lion", "10.8", [.openGLDesktop, .legacyTabletCalibration], .installerDMG)
        case .mavericks: (.osX, "Mavericks", "10.9", [.openGLDesktop, .legacyTabletCalibration], .recoveryESD)
        case .yosemite: (.osX, "Yosemite", "10.10", [.openGLDesktop], .installerDMG)
        case .elCapitan: (.osX, "El Capitan", "10.11", [.openGLDesktop, .usb3Images], .installerDMG)
        case .sierra: (.macOS, "Sierra", "10.12", [.openGLDesktop, .usb3Images], .installerDMG)
        case .highSierra: (.macOS, "High Sierra", "10.13", [.openGLDesktop, .usb3Images], .splitLegacy)
        case .mojave: (.macOS, "Mojave", "10.14", [.paravirtualizedGraphics, .usb3Images], .splitLegacy)
        case .catalina: (.macOS, "Catalina", "10.15", [.paravirtualizedGraphics, .usb3Images], .splitLegacy)
        case .bigSur: (.macOS, "Big Sur", "11", [.paravirtualizedGraphics, .usb3Images], .assistantPackage)
        }
    }
}
