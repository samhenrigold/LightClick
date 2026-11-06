// What a launch checks before it starts an emulator: its development options, firmware, removable media, sound devices and
// session lock. Each refuses in words for the user, and nothing here changes the machine.

import Foundation

private func launchError(_ message: String) -> NSError {
    NSError(domain: "VirtualIntelMac.Session", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// The explicit development options on the command line that change a launch.
@objc(VIMLaunchOptions)
@objcMembers
public final class LaunchOptions: NSObject {
    /// An EFI disk image to boot instead of the machine's own.
    public let guestEFI: String?
    public let researchCPUModel: String?
    public let systemDiskInterface: String?

    @objc(initWithArguments:appleSilicon:researchGuest:error:)
    public init(arguments: [String], appleSilicon: Bool, researchGuest: Bool) throws {
        func value(after option: String) -> String?? {
            guard let index = arguments.firstIndex(of: option) else { return .none }
            return .some(index + 1 < arguments.count ? arguments[index + 1] : nil)
        }
        if let path = value(after: "--guest-efi") {
            guard let path, Self.isGPTImage(path) else {
                throw launchError(
                    "--guest-efi requires an absolute path to a regular GPT EFI disk image. The VM’s firmware was not "
                        + "changed.")
            }
            guestEFI = path
        } else {
            guestEFI = nil
        }
        if let model = value(after: "--opengl-cpu-model") {
            guard !appleSilicon, researchGuest, let model, ["penryn", "haswell"].contains(model) else {
                throw launchError(
                    "--opengl-cpu-model requires an Intel-host research Mac and penryn or haswell. The Mac was not "
                        + "started.")
            }
            researchCPUModel = model
        } else {
            researchCPUModel = nil
        }
        if let interface = value(after: "--system-disk-interface") {
            guard let interface, ["sata", "nvme"].contains(interface) else {
                throw launchError("--system-disk-interface requires sata or nvme. The Mac was not started.")
            }
            systemDiskInterface = interface
        } else {
            systemDiskInterface = nil
        }
    }

    /// An absolute path to a regular file, not a link, with a GPT header in its second sector.
    static func isGPTImage(_ path: String) -> Bool {
        guard (path as NSString).isAbsolutePath else { return false }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        var signature = [UInt8](repeating: 0, count: 8)
        return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && pread(descriptor, &signature, 8, 512) == 8 && signature == Array("EFI PART".utf8)
    }
}

/// One immutable firmware per guest, falling back to the common one. OpenCore reads its eight policy bytes once through
/// fw_cfg: there's no generated EFI, copied template or policy variable in NVRAM.
@objc(VIMLaunchFirmware)
@objcMembers
public final class LaunchFirmware: NSObject {
    public let codePath: String
    public let bootMediaPath: String

    /// - Parameters:
    ///   - directory: The folder of per-guest firmware.
    ///   - guestDirectory: The subfolder for this guest. Research guests use Mojave's.
    ///   - bootMedia: The EFI disk to use instead of the shipped one.
    @objc(initWithDirectory:guestDirectory:bootMedia:error:)
    public init(directory: String, guestDirectory: String, bootMedia: String?) throws {
        let manager = FileManager.default
        let root = directory as NSString
        let common = root.appendingPathComponent("Common") as NSString
        let guest = root.appendingPathComponent(guestDirectory) as NSString
        var code = guest.appendingPathComponent("CODE.fd")
        if !manager.fileExists(atPath: code) { code = common.appendingPathComponent("CODE.fd") }
        var efi = common.appendingPathComponent("EFI.img")
        if !manager.fileExists(atPath: efi) { efi = guest.appendingPathComponent("EFI.img") }
        codePath = code
        bootMediaPath = bootMedia ?? efi
        guard manager.fileExists(atPath: codePath), manager.fileExists(atPath: bootMediaPath) else {
            throw launchError("This app is missing its firmware. Rebuild or reinstall the complete app.")
        }
    }
}

/// The removable images a launch starts with.
@objc(VIMLaunchMedia)
@objcMembers
public final class LaunchMedia: NSObject {
    /// An image to attach, in its slot. Slot 0 is the boot drive.
    @objc(VIMLaunchMediaImage)
    @objcMembers
    public final class Image: NSObject {
        public let slot: Int
        public let path: String
        public let format: String

        init(slot: Int, path: String, format: String) {
            self.slot = slot
            self.path = path
            self.format = format
        }
    }

    public private(set) var images: [Image] = []
    /// Saved images that are gone, by slot. Removable media can disappear when a library moves to another Mac, so the
    /// launch goes on with those drives empty, and the settings forget them. This never applies to a disk the guest needs.
    public private(set) var unavailable: [NSNumber: String] = [:]
    /// The image that can't be used, and why, which stops the launch.
    public private(set) var refusedPath: String?
    public private(set) var refusal: NSError?

    /// - Parameters:
    ///   - paths: The saved image for each slot, empty for none.
    ///   - inspect: The format of the image at a path as a string, or else the error that says why it has none.
    @objc(initWithPaths:inspect:)
    public init(paths: [String], inspect: (String) -> Any?) {
        super.init()
        for (slot, path) in paths.enumerated() where !path.isEmpty {
            let inspection = inspect(path)
            if let format = inspection as? String {
                images.append(Image(slot: slot, path: path, format: format))
            } else if let failure = inspection as? NSError {
                if failure.domain == NSPOSIXErrorDomain && (failure.code == ENOENT || failure.code == ENOTDIR) {
                    unavailable[slot as NSNumber] = path
                } else {
                    refusedPath = path
                    refusal = failure
                    return
                }
            }
        }
    }

    /// The alert for images the guest started without.
    @objc(VIMUnavailableImagesNotice)
    @objcMembers
    public final class Notice: NSObject {
        public let title: String
        public let detail: String

        @objc(initWithImages:forgotten:)
        public init(images: [NSNumber: String], forgotten: Bool) {
            title =
                !forgotten
                ? "An image couldn’t be found"
                : images.count == 1 ? "An unavailable image was disconnected" : "Unavailable images were disconnected"
            let names = images.keys.sorted { $0.intValue < $1.intValue }.compactMap { images[$0] }
                .map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            let next =
                forgotten
                ? "To reconnect an image, choose its current location when its file or drive is available."
                : "Its saved selection couldn’t be cleared. You can still disconnect it from CD/DVD or choose it again "
                    + "when its drive is available."
            detail = "Your virtual Mac started without \(names). \(next)"
        }
    }

    /// The name QEMU's SDL audio needs for a selected device, or an empty string for the default or none. Names are all
    /// SDL takes, so a device that shares its name can't be selected.
    @objc(audioDeviceNameForSelection:devices:error:)
    public class func audioDeviceName(selection: String, devices: () -> [[String: Any]]) throws -> String {
        if selection == "default" || selection == "disabled" { return "" }
        let devices = devices()
        guard let name = devices.last(where: { $0["UID"] as? String == selection })?["Name"] as? String,
            devices.filter({ $0["Name"] as? String == name }).count == 1
        else {
            throw launchError(
                "The selected sound device is unavailable or has a duplicate name. Choose Default or another device in "
                    + "Sound settings.")
        }
        return name
    }

    /// Takes the exclusive lock that says a session owns this machine, or returns -1. The file stays in place: unlinking
    /// it would allow two processes to lock different inodes for the same package. A planted link isn't followed.
    @objc(acquireSessionLockAtPath:)
    public class func acquireSessionLock(atPath path: String) -> Int32 {
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return -1 }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
            flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            close(descriptor)
            return -1
        }
        return descriptor
    }
}
