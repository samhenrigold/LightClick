import Foundation

/// Why installer preparation stopped, and what the person sees. Not itself an `Error`: an @objc enum that is one bridges
/// under a generated domain, and callers depend on `error` keeping `VirtualIntelMac.InstallerAssembly`.
@objc(VIMAssemblyFailure)
public enum AssemblyFailure: Int, Sendable {
    case mainThreadAssembly
    case mainThreadMedia
    case cancelledWithDownloadsRetained
    case cancelledWithDownloadSaved
    case mediaCancelled
    case timedOutOrCancelled
    case cannotCreateLog
    case assemblyNeedsSpace
    case assemblyNeedsScratchSpace
    case recoveryMediaNeedsScratchSpace
    case hybridMediaNeedsScratchSpace
    case needsNewAssemblyJob
    case needsNewMediaJob
    case unsupportedRestoreDisc
    case unsupportedInstaller
    case incompleteRestoreDiscImage
    case missingRestoreDiscDownload
    case incompleteInstallerApplication
    case bigSurPackageMissing
    case incompleteLeopardDisc
    case incompleteDownload
    case incompleteMavericksDownload
    case noCatalogRecord
    case noMavericksCatalogRecord
    case mavericksDownloadIncomplete
    case mavericksVersionMismatch
    case unsupportedInputs
    case packageNotSignedByApple
    case packageInstallerAmbiguous
    case recoveryFilesMissing
    case unexpectedInstallESD
    case unsupportedMediaInputs
    case unsupportedHybridInputs
    case guestSupportMissing
    case guestSupportInvalid
    case installerSupportMissing
    case recoveryVersionMismatch
    case bigSurPackageNotSignedByApple
    case bigSurMetadataAmbiguous
    case bigSurBootFileMissing
    case hfsVolumeCopyFailed
    case hfsPartitionUnidentified
    case workingVolumeNotSaved
    case leopardVolumeCopyFailed
    case leopardPartitionUnidentified
    case serialHookUnrecognized
    case highSierraStartupUnrecognized
    case automaticLaunchUnrecognized
    case installationPlanUnreadable
    case snowLeopardPackagesUnverified
    case automaticLaunchPolicyUnrecognized
    case automaticInstallerAlreadyPresent
    case startupHookAlreadyPresent
    case installationDiskFailed
    case imageNotSavedReliably
    case imageNotReadable
    case mediaUnverified
    case preparedMediaUnavailable
    case preparationRecordUnreadable
    case preparedMediaChanged
    case preparedMediaHeaderUnreadable

    public var message: String {
        switch self {
        case .mainThreadAssembly:
            "Installer assembly must run on a background worker."
        case .mainThreadMedia:
            "Media preparation must run on a background worker."
        case .cancelledWithDownloadsRetained:
            "Installer preparation was cancelled. Downloads were retained."
        case .cancelledWithDownloadSaved:
            "Installer preparation was cancelled. Your download is saved."
        case .mediaCancelled:
            "Media preparation was cancelled. Downloads were retained."
        case .timedOutOrCancelled:
            "Preparing the installer took longer than expected or was cancelled. Your downloads are saved. "
                + "Try again to resume setup."
        case .cannotCreateLog:
            "Cannot create the installer preparation log."
        case .assemblyNeedsSpace:
            "Installer preparation needs at least 16 GB of available space."
        case .assemblyNeedsScratchSpace:
            "Installer preparation needs at least 16 GB of available scratch space."
        case .recoveryMediaNeedsScratchSpace:
            "Media preparation needs at least 24 GB of available scratch space."
        case .hybridMediaNeedsScratchSpace:
            "Media preparation needs at least 32 GB of available scratch space."
        case .needsNewAssemblyJob:
            "Choose a new installer preparation job directory."
        case .needsNewMediaJob:
            "Media preparation requires a new job directory."
        case .unsupportedRestoreDisc:
            "Choose a supported Tiger, Leopard or Snow Leopard restore DVD, or a complete installer app for a"
                + " newer OS."
        case .unsupportedInstaller:
            "Choose a complete installer app for a supported version from Lion through Big Sur, or a "
                + "supported Mac OS X restore DVD disk image."
        case .incompleteRestoreDiscImage:
            "Choose the complete Mac OS X restore DVD disk image."
        case .missingRestoreDiscDownload:
            "Choose the complete Mac OS X restore DVD image."
        case .incompleteInstallerApplication:
            "Choose the complete installer app for the selected Mac OS version. This file is a different "
                + "version or is missing installation files."
        case .bigSurPackageMissing:
            "This Big Sur installer is missing Apple’s signed installation package. Choose a complete "
                + "installer app, or download a new copy using Light Click."
        case .incompleteLeopardDisc:
            "Choose a complete Intel Leopard installation or restore disc with boot.efi and its installation "
                + "packages."
        case .incompleteDownload:
            "Choose a complete Apple download and a new preparation directory."
        case .incompleteMavericksDownload:
            "Choose a complete Mavericks download and a new preparation directory."
        case .noCatalogRecord:
            "This installer has no download record in the installer catalog."
        case .noMavericksCatalogRecord:
            "Mavericks has no download record in the installer catalog."
        case .mavericksDownloadIncomplete:
            "The Mavericks download is missing its recovery system or installation packages."
        case .mavericksVersionMismatch:
            "The downloaded recovery system is not OS X Mavericks."
        case .unsupportedInputs:
            "The installer inputs are missing or unsupported."
        case .packageNotSignedByApple:
            "The package is not identified as signed Apple Software. It was not extracted."
        case .packageInstallerAmbiguous:
            "The package does not contain exactly one expected OS installer."
        case .recoveryFilesMissing:
            "Recovery files are missing, or preparation was cancelled."
        case .unexpectedInstallESD:
            "The assembled installer already contains an unexpected ESD image."
        case .unsupportedMediaInputs:
            "Choose a complete supported installer and a new media job directory."
        case .unsupportedHybridInputs:
            "Choose an assembled Big Sur installer and a new media job directory."
        case .guestSupportMissing:
            "This app is missing its OS X guest support. Rebuild or reinstall the complete app."
        case .guestSupportInvalid:
            "A bundled guest support file is missing or invalid."
        case .installerSupportMissing:
            "This app is missing its installer support. Reinstall the complete app and try again."
        case .recoveryVersionMismatch:
            "Recovery system version or boot files do not match the selected macOS."
        case .bigSurPackageNotSignedByApple:
            "The Big Sur installation package is not identified as signed Apple Software. Choose a complete "
                + "installer or download it again."
        case .bigSurMetadataAmbiguous:
            "The Big Sur update archive or version metadata is ambiguous or missing."
        case .bigSurBootFileMissing:
            "A required Big Sur boot file is missing."
        case .hfsVolumeCopyFailed:
            "The installer’s HFS volume couldn’t be copied. Its original image was not changed."
        case .hfsPartitionUnidentified:
            "The installer’s HFS partition couldn’t be identified. Its original image was not changed."
        case .workingVolumeNotSaved:
            "The installer’s working volume couldn’t be saved. Its diagnostic files were retained."
        case .leopardVolumeCopyFailed:
            "The Leopard installation volume couldn’t be copied. Check the library drive and try again; the "
                + "original DVD is unchanged."
        case .leopardPartitionUnidentified:
            "The Leopard DVD’s installation partition couldn’t be identified safely. Its original image was "
                + "not changed."
        case .serialHookUnrecognized:
            "This installer’s startup files could not be prepared. Its original files have not been changed."
        case .highSierraStartupUnrecognized:
            "This High Sierra installer’s startup interface is not recognized. Its original files were "
                + "retained."
        case .automaticLaunchUnrecognized:
            "This installer’s automatic launch interface is not recognized. Its original files were retained."
        case .installationPlanUnreadable:
            "This disc’s installation plan could not be read. Its original image was retained."
        case .snowLeopardPackagesUnverified:
            "The Snow Leopard installation packages couldn’t be verified. The original DVD image was "
                + "retained."
        case .automaticLaunchPolicyUnrecognized:
            "This OS X installer’s automatic launch policy is not recognized. Its original installer was not "
                + "changed."
        case .startupHookAlreadyPresent:
            "This installer already has an unexpected startup hook. Its original files were retained."
        case .automaticInstallerAlreadyPresent:
            "Automatic installer preparation found an unexpected existing copy."
        case .installationDiskFailed:
            "The Mac OS X installation disk couldn’t be prepared. Check available storage and try again; your"
                + " download is saved."
        case .imageNotSavedReliably:
            "The installer image couldn’t be saved reliably. Its working files were retained. Check that the "
                + "library drive is connected, then try preparing the installer again."
        case .imageNotReadable:
            "The installer image couldn’t be saved as a readable disk. Its working files were retained. Check"
                + " that the library drive is connected, then try preparing it again."
        case .mediaUnverified:
            "The prepared installer could not be verified. Its working files were retained; try preparing it "
                + "again."
        case .preparedMediaUnavailable:
            "The installer image is unavailable. Reconnect its drive or choose the installer again."
        case .preparationRecordUnreadable:
            "The installer’s preparation record couldn’t be read. Reconnect its drive and try again."
        case .preparedMediaChanged:
            "The prepared installer is incomplete or has changed. Prepare it again from the original "
                + "installer. Your virtual Mac and downloaded installer haven’t been changed."
        case .preparedMediaHeaderUnreadable:
            "The prepared installer’s disk header is unreadable. Prepare it again from the original "
                + "installer. Your virtual Mac and original installer haven’t been changed."
        }
    }
}

extension AssemblyFailure {
    public var error: NSError {
        NSError(
            domain: "VirtualIntelMac.InstallerAssembly", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@objc(VIMAssemblyFailureError)
public final class AssemblyFailureError: NSObject {
    @objc(errorForFailure:)
    public class func error(for failure: AssemblyFailure) -> NSError { failure.error }
}
