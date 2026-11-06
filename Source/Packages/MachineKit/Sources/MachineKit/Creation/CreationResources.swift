import Foundation
import InstallerKit

/// The files a new machine is made from.
public struct CreationResources: Equatable, Sendable {
    public let firmware: URL
    public let nvram: URL
    public let bootMedia: URL
    public let qemuImage: URL

    /// A packaged app's runtime. A guest's own firmware wins over the common one; the common boot image wins over the
    /// guest's own.
    public init(runtime: URL, guest: Guest, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) {
        let own = runtime.appendingPathComponent("Firmware").appendingPathComponent(guest.rawValue)
        let common = runtime.appendingPathComponent("Firmware/Common")
        let code = own.appendingPathComponent("CODE.fd")
        firmware = fileExists(code.path) ? code : common.appendingPathComponent("CODE.fd")
        nvram = own.appendingPathComponent("VARS.fd")
        let boot = common.appendingPathComponent("EFI.img")
        bootMedia = fileExists(boot.path) ? boot : own.appendingPathComponent("EFI.img")
        qemuImage = runtime.appendingPathComponent("bin/qemu-img")
    }

    /// A UI-only build, which uses the same quiet GPT/ESP image as packaged ones, not the legacy optical boot media.
    public init(developmentSourceRoot root: URL, guest: Guest) {
        let own = root.appendingPathComponent("Build/DevelopmentFirmware").appendingPathComponent(guest.rawValue)
        firmware = own.appendingPathComponent("CODE.fd")
        nvram = own.appendingPathComponent("VARS.fd")
        bootMedia = own.appendingPathComponent("EFI.img")
        qemuImage = root.appendingPathComponent("Build/qemu/build-arm64-pvg/qemu-img")
    }

    /// The name of the first file that isn't there.
    public func missingFile(fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String? {
        [firmware, nvram, bootMedia, qemuImage].first { !fileExists($0.path) }?.lastPathComponent
    }
}
