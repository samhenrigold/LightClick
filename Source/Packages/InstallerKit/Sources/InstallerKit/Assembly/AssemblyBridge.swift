// The Objective-C face of installer preparation's decisions. VIMInstallerAssembly.m runs what these describe; Swift takes
// no process or disk action here. Saved plists and command lines reach these as untrusted strings, so a guest may be nil
// or unknown: `planForGuest:` then returns nil, and messaging it reads as "nothing supported".

import Foundation

/// A guest's assembly route. Zero is what a nil plan reads as.
@objc(VIMAssemblyRoute)
public enum AssemblyRoute: Int {
    case unsupported, restoreDisc, classicDiskImage, recoveryESD, splitPackages, assistantPackage
}

/// The restore disc a guest boots from. Zero is what a nil plan reads as.
@objc(VIMRestoreDiscKind)
public enum RestoreDiscKind: Int {
    case none, tiger, leopard, snowLeopard
}

@objc(VIMGuestMediaPlan)
public final class GuestMediaPlanBridge: NSObject {
    let guest: Guest

    private init(guest: Guest) {
        self.guest = guest
    }

    @objc(planForGuest:)
    public class func plan(guest: String?) -> GuestMediaPlanBridge? {
        guest.flatMap(Guest.init(rawValue:)).map(GuestMediaPlanBridge.init(guest:))
    }

    @objc public var route: AssemblyRoute {
        switch guest.recipe {
        case .restoreDVD: .restoreDisc
        case .installerDMG: .classicDiskImage
        case .recoveryESD: .recoveryESD
        case .splitLegacy: .splitPackages
        case .assistantPackage: .assistantPackage
        }
    }

    @objc public var restoreDisc: RestoreDiscKind {
        switch guest.mediaLayout {
        case .restoreDisc(.tiger): .tiger
        case .restoreDisc(.leopard): .leopard
        case .restoreDisc(.snowLeopard): .snowLeopard
        case .flatPackages, .installerImages, .completeApplication, .hybridImage: .none
        }
    }

    @objc public var installerApplicationName: String { guest.installerApplicationName }
    @objc public var diskImagePackageName: String? { guest.diskImagePackageName }
    @objc public var usesRecoveryMedia: Bool { guest.mediaLayout != .hybridImage }
    @objc public var bootsCDISInstaller: Bool { guest.mediaLayout.bootsCDISInstaller }
    @objc public var carriesInstallerImages: Bool { guest.mediaLayout == .installerImages }
    @objc public var workingCapacity: String? { guest.mediaLayout.workingCapacity }
    @objc public var usesBootstrap: Bool { guest.recoveryAutomation.usesBootstrap }
    @objc public var usesNativeInstaller: Bool { guest.recoveryAutomation.usesNativeInstaller }
    @objc public var usesSerialAgent: Bool { guest.recoveryAutomation == .serialAgent }
    @objc public var baseSystemDirectory: String { guest.recoveryAutomation.baseSystemDirectory }
}

@objc(VIMScratchRequirement)
public final class ScratchRequirementBridge: NSObject {
    @objc public class var assembly: UInt64 { ScratchRequirement.assembly }
    @objc public class var recoveryMedia: UInt64 { ScratchRequirement.recoveryMedia }
    @objc public class var hybridMedia: UInt64 { ScratchRequirement.hybridMedia }
}

@objc(VIMWorkingImageBackend)
public final class WorkingImageBackendBridge: NSObject {
    fileprivate let value: WorkingImageBackend

    private init(value: WorkingImageBackend) {
        self.value = value
    }

    @objc(backendForMacOSMajorVersion:)
    public class func backend(macOSMajorVersion: Int) -> WorkingImageBackendBridge {
        WorkingImageBackendBridge(value: WorkingImageBackend(macOSMajorVersion: macOSMajorVersion))
    }

    @objc public var isDiskutil: Bool { value == .diskutil }
    @objc public var workingImageName: String { value.workingImageName }
}

@objc(VIMImagePartitionDevice)
public final class ImagePartitionDeviceBridge: NSObject {
    fileprivate let value: ImagePartitionDevice

    private init(value: ImagePartitionDevice) {
        self.value = value
    }

    /// From `diskutil info -plist`. Nil unless DeviceNode is exactly a partition, and, when asked, the volume is HFS.
    @objc(deviceFromInfo:requiringHFS:)
    public class func device(info: [String: Any]?, requiringHFS: Bool) -> ImagePartitionDeviceBridge? {
        guard !requiringHFS || info?["FilesystemType"] as? String == "hfs" else { return nil }
        return ImagePartitionDevice(deviceNode: info?["DeviceNode"]).map(ImagePartitionDeviceBridge.init(value:))
    }

    @objc public var rawPath: String { value.rawPath }
}

@objc(VIMToolInvocation)
public final class ToolInvocationBridge: NSObject {
    private let value: ToolInvocation

    private init(_ value: ToolInvocation) {
        self.value = value
    }

    @objc public var path: String { value.tool.rawValue }
    @objc public var arguments: [String] { value.arguments }
    @objc public var launchArguments: [String] { value.launchArguments }
    @objc public var workingDirectory: String? { value.workingDirectory }
    @objc public var timeout: TimeInterval { value.timeout }
    @objc public var isCleanup: Bool { value.isCleanup }
    @objc public var reportsPercent: Bool { value.reportsPercent }

    @objc(attachReadOnlyImage:mountPoint:)
    public class func attachReadOnly(image: String, mountPoint: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.attachReadOnly(image: image, mountPoint: mountPoint))
    }

    @objc(attachReadOnlyIgnoringOwnersImage:mountPoint:)
    public class func attachReadOnlyIgnoringOwners(image: String, mountPoint: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.attachReadOnly(image: image, mountPoint: mountPoint, ignoringOwners: true))
    }

    @objc(attachWorkingImage:mountPoint:rawVolume:)
    public class func attachWorkingImage(_ image: String, mountPoint: String, rawVolume: Bool) -> ToolInvocationBridge {
        ToolInvocationBridge(.attachWorkingImage(image, mountPoint: mountPoint, rawVolume: rawVolume))
    }

    @objc(detachMountPoint:)
    public class func detach(mountPoint: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.detach(mountPoint: mountPoint))
    }

    @objc(deviceInfoForMountPoint:)
    public class func deviceInfo(mountPoint: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.deviceInfo(mountPoint: mountPoint))
    }

    @objc(imageInfoForImage:)
    public class func imageInfo(image: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.imageInfo(image: image))
    }

    @objc(createWorkingImageFrom:at:backend:)
    public class func createWorkingImage(from base: String, at working: String, backend: WorkingImageBackendBridge)
        -> ToolInvocationBridge
    {
        ToolInvocationBridge(.createWorkingImage(from: base, at: working, backend: backend.value))
    }

    @objc(createWorkingImageFromDevice:at:)
    public class func createWorkingImage(fromDevice device: ImagePartitionDeviceBridge, at working: String)
        -> ToolInvocationBridge
    {
        ToolInvocationBridge(.createWorkingImage(fromDevice: device.value, at: working))
    }

    @objc(resizeWorkingImage:capacity:backend:)
    public class func resizeWorkingImage(_ working: String, capacity: String, backend: WorkingImageBackendBridge)
        -> ToolInvocationBridge
    {
        ToolInvocationBridge(.resizeWorkingImage(working, capacity: capacity, backend: backend.value))
    }

    @objc(convertToBlocks:output:)
    public class func convertToBlocks(_ working: String, output: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.convertToBlocks(working, output: output))
    }

    @objc(makeHybridImageFromStage:blessedDirectory:volumeName:output:)
    public class func makeHybridImage(stage: String, blessedDirectory: String, volumeName: String, output: String)
        -> ToolInvocationBridge
    {
        ToolInvocationBridge(
            .makeHybridImage(stage: stage, blessedDirectory: blessedDirectory, volumeName: volumeName, output: output))
    }

    @objc(checkSignatureOfPackage:)
    public class func checkSignature(package: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.checkSignature(package: package))
    }

    @objc(expandPackage:into:)
    public class func expandPackage(_ package: String, into destination: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.expandPackage(package, into: destination))
    }

    @objc(copy:to:timeout:)
    public class func copy(_ source: String, to destination: String, timeout: TimeInterval) -> ToolInvocationBridge {
        ToolInvocationBridge(.copy(source, to: destination, timeout: timeout))
    }

    @objc(extractArchive:into:)
    public class func extractArchive(_ archive: String, into destination: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.extractArchive(archive, into: destination))
    }

    @objc(createArchive:members:directory:)
    public class func createArchive(_ output: String, members: [String], directory: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.createArchive(output, members: members, directory: directory))
    }

    @objc(signAdHocApplication:entitlements:)
    public class func signAdHoc(application: String, entitlements: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.signAdHoc(application: application, entitlements: entitlements))
    }

    @objc(verifySignatureOfApplication:)
    public class func verifySignature(application: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.verifySignature(application: application))
    }

    @objc(unzip:members:into:)
    public class func unzip(_ archive: String, members: [String], into destination: String) -> ToolInvocationBridge {
        ToolInvocationBridge(.unzip(archive, members: members, into: destination))
    }
}
