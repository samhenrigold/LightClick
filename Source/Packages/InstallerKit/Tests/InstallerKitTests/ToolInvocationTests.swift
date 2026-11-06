import Foundation
import Testing

@testable import InstallerKit

@Suite struct ToolInvocationTests {
    private static let device = ImagePartitionDevice(deviceNode: "/dev/disk7s2")!

    private struct Golden: Sendable, CustomTestStringConvertible {
        let invocation: ToolInvocation
        let tool: ToolInvocation.Tool
        let arguments: [String]
        let timeout: TimeInterval
        var writes: String?
        var testDescription: String { "\(tool) \(arguments.joined(separator: " "))" }
    }

    /// Exact arguments, as a wrong one can change what a command touches.
    private static let goldens: [Golden] = [
        Golden(
            invocation: .attachReadOnly(image: "/i", mountPoint: "/m"), tool: .hdiutil,
            arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", "/m", "/i"], timeout: 180),
        Golden(
            invocation: .attachReadOnly(image: "/i", mountPoint: "/m", ignoringOwners: true), tool: .hdiutil,
            arguments: ["attach", "-readonly", "-owners", "off", "-nobrowse", "-noautoopen", "-mountpoint", "/m", "/i"],
            timeout: 180),
        Golden(
            invocation: .attachWorkingImage("/w", mountPoint: "/m", rawVolume: false), tool: .hdiutil,
            arguments: ["attach", "-owners", "off", "-nobrowse", "-noautoopen", "-mountpoint", "/m", "/w"],
            timeout: 180, writes: "/w"),
        Golden(
            invocation: .attachWorkingImage("/w", mountPoint: "/m", rawVolume: true), tool: .hdiutil,
            arguments: [
                "attach", "-owners", "off", "-nobrowse", "-noautoopen", "-mountpoint", "/m", "-imagekey",
                "diskimage-class=CRawDiskImage", "/w"
            ],
            timeout: 180, writes: "/w"),
        Golden(invocation: .detach(mountPoint: "/m"), tool: .hdiutil, arguments: ["detach", "/m"], timeout: 60),
        Golden(
            invocation: .deviceInfo(mountPoint: "/m"), tool: .diskutil, arguments: ["info", "-plist", "/m"], timeout: 60
        ),
        Golden(
            invocation: .imageInfo(image: "/i"), tool: .hdiutil, arguments: ["imageinfo", "-plist", "/i"], timeout: 60),
        Golden(
            invocation: .createWorkingImage(from: "/b", at: "/w", backend: .diskutil), tool: .diskutil,
            arguments: ["image", "create", "from", "--format", "RAW", "/b", "/w"], timeout: 600, writes: "/w"),
        Golden(
            invocation: .createWorkingImage(from: "/b", at: "/w", backend: .hdiutil), tool: .hdiutil,
            arguments: ["convert", "-format", "UDSB", "-o", "/w", "/b"], timeout: 600, writes: "/w"),
        Golden(
            invocation: .createWorkingImage(fromDevice: device, at: "/w"), tool: .hdiutil,
            arguments: ["create", "-srcdevice", "/dev/disk7s2", "-format", "UDSB", "-o", "/w"], timeout: 600,
            writes: "/w"),
        Golden(
            invocation: .resizeWorkingImage("/w", capacity: "8g", backend: .diskutil), tool: .diskutil,
            arguments: ["image", "resize", "--size", "8g", "/w"], timeout: 180, writes: "/w"),
        Golden(
            invocation: .resizeWorkingImage("/w", capacity: "8g", backend: .hdiutil), tool: .hdiutil,
            arguments: ["resize", "-size", "8g", "/w"], timeout: 180, writes: "/w"),
        Golden(
            invocation: .convertToBlocks("/w", output: "/o"), tool: .hdiutil,
            arguments: ["convert", "/w", "-format", "UDTO", "-o", "/o"], timeout: 1800, writes: "/o"),
        Golden(
            invocation: .makeHybridImage(stage: "/s", blessedDirectory: "/s/c", volumeName: "V", output: "/o"),
            tool: .hdiutil,
            arguments: [
                "makehybrid", "-hfs", "-udf", "-hfs-volume-name", "V", "-hfs-blessed-directory", "/s/c", "-o", "/o",
                "/s"
            ],
            timeout: 1800, writes: "/o"),
        Golden(
            invocation: .checkSignature(package: "/p"), tool: .pkgutil, arguments: ["--check-signature", "/p"],
            timeout: 300),
        Golden(
            invocation: .expandPackage("/p", into: "/e"), tool: .pkgutil, arguments: ["--expand-full", "/p", "/e"],
            timeout: 1800, writes: "/e"),
        Golden(
            invocation: .copy("/a", to: "/b", timeout: 120), tool: .ditto,
            arguments: ["--norsrc", "--noextattr", "--noacl", "/a", "/b"], timeout: 120, writes: "/b"),
        Golden(
            invocation: .extractArchive("/a", into: "/d"), tool: .xar, arguments: ["-xf", "/a", "-C", "/d"],
            timeout: 180, writes: "/d"),
        Golden(
            invocation: .createArchive("/o", members: ["b", "a"], directory: "/d"), tool: .xar,
            arguments: ["-cf", "/o", "a", "b"], timeout: 180, writes: "/o"),
        Golden(
            invocation: .signAdHoc(application: "/a", entitlements: "/e"), tool: .codesign,
            arguments: ["--force", "--sign", "-", "--digest-algorithm=sha1,sha256", "--entitlements", "/e", "/a"],
            timeout: 60, writes: "/a"),
        Golden(
            invocation: .verifySignature(application: "/a"), tool: .codesign, arguments: ["--verify", "--strict", "/a"],
            timeout: 60),
        Golden(
            invocation: .unzip("/z", members: ["m/*"], into: "/d"), tool: .unzip,
            arguments: ["-q", "/z", "m/*", "-d", "/d"], timeout: 600, writes: "/d")
    ]

    @Test(arguments: goldens) private func argumentsAreExact(_ golden: Golden) {
        #expect(golden.invocation.tool == golden.tool)
        #expect(golden.invocation.arguments == golden.arguments)
        #expect(golden.invocation.timeout == golden.timeout)
        #expect(golden.invocation.writes == golden.writes)
    }

    @Test(arguments: goldens) private func nothingWritesADeviceOrErases(_ golden: Golden) {
        #expect(golden.writes?.hasPrefix("/dev/") != true)
        for word in ["erase", "eraseDisk", "eraseVolume", "partitionDisk", "partition", "apfs", "restore", "asr"] {
            #expect(!golden.arguments.contains(word))
        }
    }

    @Test(arguments: goldens) private func everyWriteNamesATargetInItsArguments(_ golden: Golden) {
        if let target = golden.writes { #expect(golden.arguments.contains(target)) }
    }

    @Test func toolsArePinnedSystemBinaries() {
        let tools: [ToolInvocation.Tool: String] = [
            .hdiutil: "/usr/bin/hdiutil", .diskutil: "/usr/sbin/diskutil", .pkgutil: "/usr/sbin/pkgutil",
            .ditto: "/usr/bin/ditto", .xar: "/usr/bin/xar", .codesign: "/usr/bin/codesign", .unzip: "/usr/bin/unzip"
        ]
        for (tool, path) in tools { #expect(tool.rawValue == path) }
    }

    /// An attach without `-readonly` is the one way a mount can change an image.
    @Test func onlyTheWorkingImageAttachIsWritable() {
        for golden in Self.goldens where golden.arguments.first == "attach" {
            #expect(golden.arguments.contains("-readonly") == (golden.writes == nil), "\(golden)")
        }
    }

    @Test func onlyDetachRunsAfterCancellation() {
        for golden in Self.goldens {
            #expect(golden.invocation.isCleanup == (golden.arguments.first == "detach"), "\(golden)")
        }
    }

    @Test func onlyConvertAsksForPercentagesAndOnlyWhenLaunched() {
        let convert = ToolInvocation.convertToBlocks("/w", output: "/o")
        #expect(convert.reportsPercent)
        #expect(convert.launchArguments == convert.arguments + ["-puppetstrings"])
        #expect(!convert.arguments.contains("-puppetstrings"))
        let working = ToolInvocation.createWorkingImage(from: "/b", at: "/w", backend: .hdiutil)
        #expect(working.reportsPercent)
        for golden in Self.goldens where golden.arguments.first != "convert" {
            #expect(!golden.invocation.reportsPercent)
            #expect(golden.invocation.launchArguments == golden.arguments)
        }
    }

    @Test func archiveCreationNeedsAWorkingDirectory() {
        #expect(ToolInvocation.createArchive("/o", members: ["a"], directory: "/d").workingDirectory == "/d")
        #expect(ToolInvocation.extractArchive("/a", into: "/d").workingDirectory == nil)
    }

    @Test func archiveMembersSortLikeNSString() {
        let sorted = ToolInvocation.createArchive("/o", members: ["b", "B", "a"], directory: "/d").arguments
        #expect(Array(sorted.dropFirst(2)) == ["B", "a", "b"])
    }

    @Test func theBackendFollowsTheHostVersion() {
        #expect(WorkingImageBackend(macOSMajorVersion: 26) == .hdiutil)
        #expect(WorkingImageBackend(macOSMajorVersion: 27) == .diskutil)
        #expect(WorkingImageBackend(macOSMajorVersion: 28) == .diskutil)
        #expect(WorkingImageBackend.hdiutil.workingImageName == "Recovery-working.sparsebundle")
        #expect(WorkingImageBackend.diskutil.workingImageName == "Recovery-working.img")
    }

    @Test(arguments: ["/dev/disk0s1", "/dev/disk12s34"]) func aPartitionNodeIsAccepted(_ node: String) throws {
        let device = try #require(ImagePartitionDevice(deviceNode: node))
        #expect(device.blockPath == node)
        #expect(device.rawPath == node.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk"))
    }

    /// A whole disk is what a wrong argument could damage most, so its refusal is pinned, along with every near miss.
    @Test(arguments: [
        "/dev/disk0", "/dev/rdisk0s1", "/dev/disk0s", "/dev/disks1", "disk0s1", "/dev/disk0s1\n", " /dev/disk0s1",
        "/dev/disk0s1s2", "/dev/disk٣s1", "/dev/disk0s1/../disk0", ""
    ])
    func anythingButAPartitionNodeIsRefused(_ node: String) {
        #expect(ImagePartitionDevice(deviceNode: node) == nil)
    }

    @Test func aNonStringNodeIsRefused() {
        #expect(ImagePartitionDevice(deviceNode: nil) == nil)
        #expect(ImagePartitionDevice(deviceNode: 7) == nil)
    }

    @Test func theBridgeNeedsHFSOnlyWhenAsked() throws {
        let hfs: [String: Any] = ["DeviceNode": "/dev/disk4s1", "FilesystemType": "hfs"]
        let apfs: [String: Any] = ["DeviceNode": "/dev/disk4s1", "FilesystemType": "apfs"]
        #expect(ImagePartitionDeviceBridge.device(info: hfs, requiringHFS: true)?.rawPath == "/dev/rdisk4s1")
        #expect(ImagePartitionDeviceBridge.device(info: apfs, requiringHFS: true) == nil)
        #expect(ImagePartitionDeviceBridge.device(info: apfs, requiringHFS: false)?.rawPath == "/dev/rdisk4s1")
        #expect(ImagePartitionDeviceBridge.device(info: nil, requiringHFS: false) == nil)
    }
}
