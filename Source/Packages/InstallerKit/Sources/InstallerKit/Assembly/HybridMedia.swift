/// Big Sur's generated hybrid image: what comes out of its update archive, and where it goes.
public enum HybridMedia {
    public static let volumeName = "Install macOS Big Sur"
    public static let assetDirectory = "com_apple_MobileAsset_MacSoftwareUpdate"
    public static let assetMetadata = "com_apple_MobileAsset_MacSoftwareUpdate.xml"
    public static let blessedDirectory = "System/Library/CoreServices"
    public static let extractedManifests = "AssetData/boot/Firmware/Manifests/InstallerBoot"
    public static let bootPlistPath = "Library/Preferences/SystemConfiguration/com.apple.Boot.plist"
    public static let installerCookiePath = ".IAPhysicalMedia"

    /// Exact entries used by Big Sur's CIMUtilities, observed in its shipped createinstallmedia.dylib. No OS-wide restore or
    /// package scripts.
    public static let archiveMembers = [
        "AssetData/Restore/BaseSystem.dmg", "AssetData/Restore/BaseSystem.chunklist",
        extractedManifests + "/*",
        "AssetData/boot/Firmware/System/Library/CoreServices/bootbase.efi",
        "AssetData/boot/System/Library/KernelCollections/BootKernelExtensions.kc",
        "AssetData/boot/BridgeVersion.plist", "AssetData/boot/BridgeVersion.bin",
        "AssetData/boot/PlatformSupport.plist", "AssetData/boot/SystemVersion.plist"
    ]

    /// Extracted path to staged path. Each must exist.
    public static let stagedFiles = [
        "AssetData/Restore/BaseSystem.dmg": "BaseSystem/BaseSystem.dmg",
        "AssetData/Restore/BaseSystem.chunklist": "BaseSystem/BaseSystem.chunklist",
        "AssetData/boot/Firmware/System/Library/CoreServices/bootbase.efi": "System/Library/CoreServices/boot.efi",
        "AssetData/boot/System/Library/KernelCollections/BootKernelExtensions.kc":
            "System/Library/KernelCollections/BootKernelExtensions.kc",
        "AssetData/boot/BridgeVersion.plist": "System/Library/CoreServices/BridgeVersion.plist",
        "AssetData/boot/BridgeVersion.bin": "System/Library/CoreServices/BridgeVersion.bin",
        "AssetData/boot/PlatformSupport.plist": "System/Library/CoreServices/PlatformSupport.plist",
        "AssetData/boot/SystemVersion.plist": "System/Library/CoreServices/SystemVersion.plist"
    ]

    public static let bootPlist = ["Kernel Flags": "root-dmg=file:///BaseSystem/BaseSystem.dmg"]

    public static func installerCookie(applicationName: String, productVersion: String, productBuild: String)
        -> [String: String]
    {
        ["AppName": applicationName, "ProductVersion": productVersion, "ProductBuildVersion": productBuild]
    }
}
