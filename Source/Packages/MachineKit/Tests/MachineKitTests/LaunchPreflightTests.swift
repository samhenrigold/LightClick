import Foundation
import Testing

@testable import MachineKit

@Suite struct LaunchPreflightTests {
    private let directory: String

    init() throws {
        directory = NSTemporaryDirectory() + "preflight-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private func path(_ name: String) -> String { (directory as NSString).appendingPathComponent(name) }

    private func touch(_ name: String) throws {
        let file = path(name)
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: file))
    }

    private func message(_ work: () throws -> Any) -> String? {
        do {
            _ = try work()
            return nil
        } catch {
            return (error as NSError).localizedDescription
        }
    }

    // MARK: - Options

    private func options(_ arguments: [String], appleSilicon: Bool = true, research: Bool = false) throws
        -> LaunchOptions
    {
        try LaunchOptions(arguments: ["app"] + arguments, appleSilicon: appleSilicon, researchGuest: research)
    }

    @Test func noOptionsMeanNothing() throws {
        let plain = try options([])
        #expect(plain.guestEFI == nil && plain.researchCPUModel == nil && plain.systemDiskInterface == nil)
    }

    @Test func aDiskInterfaceMustBeKnown() throws {
        #expect(try options(["--system-disk-interface", "nvme"]).systemDiskInterface == "nvme")
        for arguments in [["--system-disk-interface", "ide"], ["--system-disk-interface"]] {
            #expect(message { try options(arguments) }?.hasPrefix("--system-disk-interface requires") == true)
        }
    }

    @Test func aResearchCPUNeedsAnIntelHostAndResearchGuest() throws {
        let arguments = ["--opengl-cpu-model", "penryn"]
        #expect(try options(arguments, appleSilicon: false, research: true).researchCPUModel == "penryn")
        #expect(message { try options(arguments, appleSilicon: true, research: true) } != nil)
        #expect(message { try options(arguments, appleSilicon: false, research: false) } != nil)
        #expect(message { try options(["--opengl-cpu-model", "x"], appleSilicon: false, research: true) } != nil)
        #expect(message { try options(["--opengl-cpu-model"], appleSilicon: false, research: true) } != nil)
    }

    private func writeImage(_ name: String, signature: String = "EFI PART") throws {
        var bytes = Data(count: 512)
        bytes.append(Data(signature.utf8))
        try bytes.write(to: URL(fileURLWithPath: path(name)))
    }

    @Test func aGuestEFIMustBeAGPTImage() throws {
        try writeImage("good.img")
        try writeImage("bad.img", signature: "NOTAGPT!")
        try Data(count: 100).write(to: URL(fileURLWithPath: path("short.img")))
        try FileManager.default.createSymbolicLink(atPath: path("link.img"), withDestinationPath: path("good.img"))
        #expect(try options(["--guest-efi", path("good.img")]).guestEFI == path("good.img"))
        for bad in ["bad.img", "short.img", "link.img", "missing.img"] {
            #expect(message { try options(["--guest-efi", path(bad)]) }?.hasPrefix("--guest-efi requires") == true)
        }
        #expect(message { try options(["--guest-efi", "relative.img"]) } != nil)
        #expect(message { try options(["--guest-efi"]) } != nil)
    }

    // MARK: - Firmware

    @Test func aGuestsFirmwareWinsForCodeAndCommonForEFI() throws {
        try touch("Common/CODE.fd")
        try touch("Common/EFI.img")
        try touch("lion/CODE.fd")
        try touch("lion/EFI.img")
        let lion = try LaunchFirmware(directory: directory, guestDirectory: "lion", bootMedia: nil)
        #expect(lion.codePath == path("lion/CODE.fd"))
        #expect(lion.bootMediaPath == path("Common/EFI.img"))
        let other = try LaunchFirmware(directory: directory, guestDirectory: "tiger", bootMedia: nil)
        #expect(other.codePath == path("Common/CODE.fd"))
    }

    @Test func efiFallsBackToTheGuestsAndAnOverrideReplacesIt() throws {
        try touch("Common/CODE.fd")
        try touch("lion/EFI.img")
        try touch("override.img")
        #expect(
            try LaunchFirmware(directory: directory, guestDirectory: "lion", bootMedia: nil).bootMediaPath
                == path("lion/EFI.img"))
        #expect(
            try LaunchFirmware(directory: directory, guestDirectory: "lion", bootMedia: path("override.img"))
                .bootMediaPath == path("override.img"))
    }

    @Test func missingFirmwareStopsALaunch() throws {
        let expected = "This app is missing its firmware. Rebuild or reinstall the complete app."
        #expect(
            message { try LaunchFirmware(directory: directory, guestDirectory: "lion", bootMedia: nil) } == expected)
        try touch("Common/CODE.fd")
        #expect(
            message { try LaunchFirmware(directory: directory, guestDirectory: "lion", bootMedia: nil) } == expected)
        try touch("Common/EFI.img")
        #expect(
            message { try LaunchFirmware(directory: directory, guestDirectory: "lion", bootMedia: path("gone")) }
                == expected)
    }

    // MARK: - Media

    private func posix(_ code: POSIXErrorCode) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))
    }

    @Test func imagesKeepTheirSlots() {
        let media = LaunchMedia(paths: ["/a.iso", "", "/b.dmg"]) { $0 == "/a.iso" ? "raw" : "dmg" }
        #expect(media.images.map(\.slot) == [0, 2])
        #expect(media.images.map(\.format) == ["raw", "dmg"])
        #expect(media.unavailable.isEmpty && media.refusal == nil)
    }

    @Test func aMissingImageIsLeftOutAndNoted() {
        let media = LaunchMedia(paths: ["/gone.iso", "/nodir/b.iso", "/c.iso"]) { path in
            switch path {
            case "/gone.iso": posix(.ENOENT)
            case "/nodir/b.iso": posix(.ENOTDIR)
            default: "raw"
            }
        }
        #expect(media.images.map(\.path) == ["/c.iso"])
        #expect(media.unavailable == [0: "/gone.iso", 1: "/nodir/b.iso"])
        #expect(media.refusal == nil)
    }

    @Test func anUnusableImageStopsALaunch() {
        let media = LaunchMedia(paths: ["/a.iso", "/bad.iso", "/c.iso"]) { path in
            path == "/bad.iso" ? NSError(domain: "x", code: 1) : "raw"
        }
        #expect(media.refusedPath == "/bad.iso")
        #expect(media.refusal?.domain == "x")
    }

    @Test func aPermissionErrorIsNotAMissingImage() {
        #expect(LaunchMedia(paths: ["/a.iso"]) { _ in posix(.EACCES) }.refusal != nil)
    }

    @Test func theNoticeNamesImagesInSlotOrder() {
        let two = LaunchMedia.Notice(images: [2: "/x/two.iso", 0: "/y/zero.iso"], forgotten: true)
        #expect(two.title == "Unavailable images were disconnected")
        #expect(two.detail.hasPrefix("Your virtual Mac started without zero.iso, two.iso. To reconnect"))
        #expect(LaunchMedia.Notice(images: [0: "/a"], forgotten: true).title == "An unavailable image was disconnected")
        let kept = LaunchMedia.Notice(images: [0: "/a.iso"], forgotten: false)
        #expect(kept.title == "An image couldn’t be found")
        #expect(kept.detail.contains("couldn’t be cleared"))
    }

    // MARK: - Sound

    @Test func builtInSoundChoicesNeedNoDevices() throws {
        #expect(
            try LaunchMedia.audioDeviceName(selection: "default") {
                Issue.record("listed devices")
                return []
            } == "")
        #expect(try LaunchMedia.audioDeviceName(selection: "disabled") { [] } == "")
    }

    @Test func aDeviceMustBeThereAndNameItself() throws {
        let devices: [[String: Any]] = [
            ["UID": "a", "Name": "Speakers"], ["UID": "b", "Name": "Twin"], ["UID": "c", "Name": "Twin"]
        ]
        #expect(try LaunchMedia.audioDeviceName(selection: "a") { devices } == "Speakers")
        for selection in ["b", "missing"] {
            #expect(
                message { try LaunchMedia.audioDeviceName(selection: selection) { devices } }?
                    .hasPrefix("The selected sound device") == true)
        }
    }

    // MARK: - Session lock

    @Test func aSessionLockIsExclusive() throws {
        let file = path("Session.lock")
        let first = LaunchMedia.acquireSessionLock(atPath: file)
        #expect(first >= 0)
        #expect(LaunchMedia.acquireSessionLock(atPath: file) == -1)
        close(first)
        let again = LaunchMedia.acquireSessionLock(atPath: file)
        #expect(again >= 0)
        close(again)
    }

    @Test func aPlantedLockFileIsRefused() throws {
        try touch("target")
        try FileManager.default.createSymbolicLink(atPath: path("link.lock"), withDestinationPath: path("target"))
        #expect(LaunchMedia.acquireSessionLock(atPath: path("link.lock")) == -1)
        try FileManager.default.linkItem(atPath: path("target"), toPath: path("hard.lock"))
        #expect(LaunchMedia.acquireSessionLock(atPath: path("hard.lock")) == -1)
        try FileManager.default.createDirectory(atPath: path("dir.lock"), withIntermediateDirectories: false)
        #expect(LaunchMedia.acquireSessionLock(atPath: path("dir.lock")) == -1)
    }
}
