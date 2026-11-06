import Foundation
import Testing

@testable import InstallerKit

@Suite struct AssemblyFailureTests {
    /// The exact words people see, as this code used to spell them out inline.
    private static let table: [(AssemblyFailure, String)] = [
        (.mainThreadAssembly, "Installer assembly must run on a background worker."),
        (.mainThreadMedia, "Media preparation must run on a background worker."),
        (.cancelledWithDownloadsRetained, "Installer preparation was cancelled. Downloads were retained."),
        (.cancelledWithDownloadSaved, "Installer preparation was cancelled. Your download is saved."),
        (.mediaCancelled, "Media preparation was cancelled. Downloads were retained."),
        (
            .timedOutOrCancelled,
            "Preparing the installer took longer than expected or was cancelled. Your downloads are saved. Try again to resume setup."
        ),
        (.cannotCreateLog, "Cannot create the installer preparation log."),
        (.assemblyNeedsSpace, "Installer preparation needs at least 16 GB of available space."),
        (.assemblyNeedsScratchSpace, "Installer preparation needs at least 16 GB of available scratch space."),
        (.recoveryMediaNeedsScratchSpace, "Media preparation needs at least 24 GB of available scratch space."),
        (.hybridMediaNeedsScratchSpace, "Media preparation needs at least 32 GB of available scratch space."),
        (.needsNewAssemblyJob, "Choose a new installer preparation job directory."),
        (.needsNewMediaJob, "Media preparation requires a new job directory."),
        (
            .unsupportedRestoreDisc,
            "Choose a supported Tiger, Leopard or Snow Leopard restore DVD, or a complete installer app for a newer OS."
        ),
        (
            .unsupportedInstaller,
            "Choose a complete installer app for a supported version from Lion through Big Sur, or a supported Mac OS X restore DVD disk image."
        ),
        (.incompleteRestoreDiscImage, "Choose the complete Mac OS X restore DVD disk image."),
        (.missingRestoreDiscDownload, "Choose the complete Mac OS X restore DVD image."),
        (
            .incompleteInstallerApplication,
            "Choose the complete installer app for the selected Mac OS version. This file is a different version or is missing installation files."
        ),
        (
            .bigSurPackageMissing,
            "This Big Sur installer is missing Apple’s signed installation package. Choose a complete installer app, or download a new copy using Light Click."
        ),
        (
            .incompleteLeopardDisc,
            "Choose a complete Intel Leopard installation or restore disc with boot.efi and its installation packages."
        ),
        (.incompleteDownload, "Choose a complete Apple download and a new preparation directory."),
        (.incompleteMavericksDownload, "Choose a complete Mavericks download and a new preparation directory."),
        (.noCatalogRecord, "This installer has no download record in the installer catalog."),
        (.noMavericksCatalogRecord, "Mavericks has no download record in the installer catalog."),
        (
            .mavericksDownloadIncomplete,
            "The Mavericks download is missing its recovery system or installation packages."
        ),
        (.mavericksVersionMismatch, "The downloaded recovery system is not OS X Mavericks."),
        (.unsupportedInputs, "The installer inputs are missing or unsupported."),
        (.packageNotSignedByApple, "The package is not identified as signed Apple Software. It was not extracted."),
        (.packageInstallerAmbiguous, "The package does not contain exactly one expected OS installer."),
        (.recoveryFilesMissing, "Recovery files are missing, or preparation was cancelled."),
        (.unexpectedInstallESD, "The assembled installer already contains an unexpected ESD image."),
        (.unsupportedMediaInputs, "Choose a complete supported installer and a new media job directory."),
        (.unsupportedHybridInputs, "Choose an assembled Big Sur installer and a new media job directory."),
        (.guestSupportMissing, "This app is missing its OS X guest support. Rebuild or reinstall the complete app."),
        (.guestSupportInvalid, "A bundled guest support file is missing or invalid."),
        (
            .installerSupportMissing,
            "This app is missing its installer support. Reinstall the complete app and try again."
        ),
        (.recoveryVersionMismatch, "Recovery system version or boot files do not match the selected macOS."),
        (
            .bigSurPackageNotSignedByApple,
            "The Big Sur installation package is not identified as signed Apple Software. Choose a complete installer or download it again."
        ),
        (.bigSurMetadataAmbiguous, "The Big Sur update archive or version metadata is ambiguous or missing."),
        (.bigSurBootFileMissing, "A required Big Sur boot file is missing."),
        (.hfsVolumeCopyFailed, "The installer’s HFS volume couldn’t be copied. Its original image was not changed."),
        (
            .hfsPartitionUnidentified,
            "The installer’s HFS partition couldn’t be identified. Its original image was not changed."
        ),
        (
            .workingVolumeNotSaved,
            "The installer’s working volume couldn’t be saved. Its diagnostic files were retained."
        ),
        (
            .leopardVolumeCopyFailed,
            "The Leopard installation volume couldn’t be copied. Check the library drive and try again; the original DVD is unchanged."
        ),
        (
            .leopardPartitionUnidentified,
            "The Leopard DVD’s installation partition couldn’t be identified safely. Its original image was not changed."
        ),
        (
            .serialHookUnrecognized,
            "This installer’s startup files could not be prepared. Its original files have not been changed."
        ),
        (
            .highSierraStartupUnrecognized,
            "This High Sierra installer’s startup interface is not recognized. Its original files were retained."
        ),
        (
            .automaticLaunchUnrecognized,
            "This installer’s automatic launch interface is not recognized. Its original files were retained."
        ),
        (
            .installationPlanUnreadable,
            "This disc’s installation plan could not be read. Its original image was retained."
        ),
        (
            .snowLeopardPackagesUnverified,
            "The Snow Leopard installation packages couldn’t be verified. The original DVD image was retained."
        ),
        (
            .automaticLaunchPolicyUnrecognized,
            "This OS X installer’s automatic launch policy is not recognized. Its original installer was not changed."
        ),
        (
            .startupHookAlreadyPresent,
            "This installer already has an unexpected startup hook. Its original files were retained."
        ),
        (.automaticInstallerAlreadyPresent, "Automatic installer preparation found an unexpected existing copy."),
        (
            .installationDiskFailed,
            "The Mac OS X installation disk couldn’t be prepared. Check available storage and try again; your download is saved."
        ),
        (
            .imageNotSavedReliably,
            "The installer image couldn’t be saved reliably. Its working files were retained. Check that the library drive is connected, then try preparing the installer again."
        ),
        (
            .imageNotReadable,
            "The installer image couldn’t be saved as a readable disk. Its working files were retained. Check that the library drive is connected, then try preparing it again."
        ),
        (
            .mediaUnverified,
            "The prepared installer could not be verified. Its working files were retained; try preparing it again."
        ),
        (
            .preparedMediaUnavailable,
            "The installer image is unavailable. Reconnect its drive or choose the installer again."
        ),
        (
            .preparationRecordUnreadable,
            "The installer’s preparation record couldn’t be read. Reconnect its drive and try again."
        ),
        (
            .preparedMediaChanged,
            "The prepared installer is incomplete or has changed. Prepare it again from the original installer. Your virtual Mac and downloaded installer haven’t been changed."
        ),
        (
            .preparedMediaHeaderUnreadable,
            "The prepared installer’s disk header is unreadable. Prepare it again from the original installer. Your virtual Mac and original installer haven’t been changed."
        )
    ]

    @Test func everyFailureSaysExactlyWhatItAlwaysSaid() {
        for (failure, message) in Self.table {
            #expect(failure.message == message)
        }
        #expect(Set(Self.table.map(\.0)).count == Self.table.count)
    }

    @Test func anErrorKeepsItsObjectiveCIdentity() {
        let error = AssemblyFailureError.error(for: .mediaUnverified)
        #expect(error.domain == "VirtualIntelMac.InstallerAssembly")
        #expect(error.code == 1)
        #expect(error.localizedDescription == AssemblyFailure.mediaUnverified.message)
        #expect(error.userInfo[NSLocalizedDescriptionKey] as? String == AssemblyFailure.mediaUnverified.message)
    }
}
