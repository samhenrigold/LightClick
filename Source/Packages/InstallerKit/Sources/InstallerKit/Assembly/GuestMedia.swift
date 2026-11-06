// Which media and layout each guest uses. Every guest-specific branch of installer preparation reads from here.

/// How a guest's bootable installer is laid out.
public enum MediaLayout: Equatable, Sendable {
    /// The restore DVD's own volume, edited in a generated copy. It already holds its Packages tree.
    case restoreDisc(RestoreDisc)
    /// BaseSystem booting the genuine CDIS installer against a local Packages tree copied from InstallESD.
    case flatPackages
    /// High Sierra's InstallInfo reader resolves payload and recovery images together, so a flattened Packages tree
    /// loads the distribution but leaves image paths nil. The genuine SharedSupport goes at the volume root.
    case installerImages
    /// BaseSystem with the complete InstallAssistant app replacing its stub.
    case completeApplication
    /// A generated HFS/UDF hybrid holding the app and Big Sur's boot files from its update archive.
    case hybridImage
}

/// The discs that have no installer app to assemble.
public enum RestoreDisc: Equatable, Sendable {
    case tiger, leopard, snowLeopard
}

/// How setup runs unattended inside the guest's installer environment.
public enum RecoveryAutomation: Equatable, Sendable {
    /// Tiger's measured native Darwin 8 rc.cdrom/minstall handoff, not the Darwin 9/x64 bootstrap.
    case tigerControls
    /// The bootstrap, plus an exec wrapper around a re-signed automatic copy of Apple's installer.
    case scopedInstaller
    /// The bootstrap and Apple's signed installer. Genuine 14F27, 15G31, 16G29 and 17G66 rc.install launch Language Chooser
    /// with TARGET_APP and `-f minstall`. Yosemite 660's OSIWindowController::start natively selects options.target and
    /// enters the installing pane when isAutomated is true (confirmed by decompilation), so no adapter is needed.
    case nativeInstaller(systemVersion: Int)
    /// A serial agent started through rc.install's own hook, leaving Apple's startup script and UI as they are.
    case serialAgent
    /// Nothing is added to the installer.
    case none
}

extension Guest {
    public var mediaLayout: MediaLayout {
        switch self {
        case .tiger: .restoreDisc(.tiger)
        case .leopard: .restoreDisc(.leopard)
        case .snowLeopard: .restoreDisc(.snowLeopard)
        case .lion, .mountainLion, .mavericks, .yosemite, .elCapitan, .sierra: .flatPackages
        case .highSierra: .installerImages
        case .mojave, .catalina: .completeApplication
        case .bigSur: .hybridImage
        }
    }

    public var recoveryAutomation: RecoveryAutomation {
        switch self {
        case .tiger: .tigerControls
        case .leopard, .snowLeopard, .lion, .mountainLion, .mavericks: .scopedInstaller
        case .yosemite, .elCapitan, .sierra: .nativeInstaller(systemVersion: 1)
        case .highSierra: .nativeInstaller(systemVersion: 6)
        case .mojave, .catalina: .serialAgent
        case .bigSur: .none
        }
    }

    /// The app's name on Apple's media. A restore disc has no such app; this is only the name of what it boots.
    public var installerApplicationName: String {
        switch self {
        case .tiger, .leopard, .snowLeopard: "Install Mac OS X.app"
        case .lion: "Install Mac OS X Lion.app"
        case .mountainLion: "Install OS X Mountain Lion.app"
        case .mavericks: "Install OS X Mavericks.app"
        case .yosemite: "Install OS X Yosemite.app"
        case .elCapitan: "Install OS X El Capitan.app"
        case .sierra: "Install macOS Sierra.app"
        case .highSierra: "Install macOS High Sierra.app"
        case .mojave: "Install macOS Mojave.app"
        case .catalina: "Install macOS Catalina.app"
        case .bigSur: "Install macOS Big Sur.app"
        }
    }

    /// The installer package inside a downloaded disk image, for guests assembled from one.
    public var diskImagePackageName: String? {
        switch self {
        case .sierra: "InstallOS.pkg"
        case .lion, .mountainLion, .yosemite, .elCapitan: "InstallMacOSX.pkg"
        case .tiger, .leopard, .snowLeopard, .mavericks, .highSierra, .mojave, .catalina, .bigSur: nil
        }
    }
}

extension MediaLayout {
    /// This generation boots the genuine CDIS installer, so its Packages tree must be on the volume.
    public var bootsCDISInstaller: Bool {
        switch self {
        case .restoreDisc, .flatPackages, .installerImages: true
        case .completeApplication, .hybridImage: false
        }
    }

    /// The size a generated working image grows to. A hybrid image has no working image.
    public var workingCapacity: String? {
        switch self {
        case .restoreDisc: "10g"
        case .flatPackages, .installerImages: "8g"
        case .completeApplication: "16g"
        case .hybridImage: nil
        }
    }
}

extension RecoveryAutomation {
    /// Whether the bootstrap and OpenGL support go on the media.
    public var usesBootstrap: Bool {
        switch self {
        case .scopedInstaller, .nativeInstaller: true
        case .tigerControls, .serialAgent, .none: false
        }
    }

    public var usesNativeInstaller: Bool {
        if case .nativeInstaller = self { true } else { false }
    }

    /// Yosemite's recovery element resolves BaseSystem from the distribution volume's root on flat media; a file only
    /// under System/Installation yields false with errno 0, which the installer shows as "Undefined error: 0".
    public var baseSystemDirectory: String { usesNativeInstaller ? "" : "System/Installation" }
}

/// Free space preparation requires before it starts.
public enum ScratchRequirement {
    public static let assembly: UInt64 = 16 << 30
    public static let recoveryMedia: UInt64 = 24 << 30
    public static let hybridMedia: UInt64 = 32 << 30
}
