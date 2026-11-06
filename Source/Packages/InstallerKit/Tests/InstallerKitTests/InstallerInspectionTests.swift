import Foundation
import Testing

@testable import InstallerKit

@Suite struct InstallerInspectionTests {
    // MARK: - Identity and version

    @Test func bundleIdentifiersNameExactlyTheInstallerAppGuests() {
        let expected: [String: Guest] = [
            "com.apple.InstallAssistant.Lion": .lion, "com.apple.InstallAssistant.MountainLion": .mountainLion,
            "com.apple.InstallAssistant.Mavericks": .mavericks, "com.apple.InstallAssistant.Yosemite": .yosemite,
            "com.apple.InstallAssistant.ElCapitan": .elCapitan, "com.apple.InstallAssistant.Sierra": .sierra,
            "com.apple.InstallAssistant.HighSierra": .highSierra, "com.apple.InstallAssistant.Mojave": .mojave,
            "com.apple.InstallAssistant.Catalina": .catalina, "com.apple.InstallAssistant.macOSBigSur": .bigSur
        ]
        for (identifier, guest) in expected { #expect(Guest(installerBundleIdentifier: identifier) == guest) }
        #expect(Guest.allCases.filter { $0.installerBundleIdentifier == nil } == [.tiger, .leopard, .snowLeopard])
    }

    /// Big Sur's old-looking ID is wrong, and an untrusted plist can hold anything.
    @Test func otherIdentifiersNameNoGuest() {
        for identifier: Any? in [
            "com.apple.InstallAssistant.BigSur", "com.apple.InstallAssistant.macOSMonterey", "", 7, nil
        ] {
            #expect(Guest(installerBundleIdentifier: identifier) == nil)
        }
    }

    @Test(arguments: [
        (Guest.mojave, "10.14"), (.mojave, "10.14.6"), (.mojave, "10.14.99"), (.bigSur, "11"), (.bigSur, "11.7.11"),
        (.bigSur, "10.16"), (.bigSur, "10.16.1"), (.tiger, "10.4.11")
    ])
    func matchingVersions(_ guest: Guest, _ version: String) {
        #expect(guest.matchesProductVersion(version))
    }

    @Test(arguments: [
        (Guest.mojave, "10.15.7"), (.mojave, "10.140.1"), (.mojave, "10.14.bad"), (.mojave, "10.14."),
        (.mojave, ".10.14"),
        (.mojave, ""), (.mojave, "10.14.٣"), (.catalina, "10.16"), (.bigSur, "12"), (.bigSur, "110"), (.tiger, "10.40")
    ])
    func mismatchedVersions(_ guest: Guest, _ version: String) {
        #expect(!guest.matchesProductVersion(version))
    }

    @Test func aNonStringVersionNeverMatches() {
        #expect(!Guest.mojave.matchesProductVersion(14))
        #expect(!Guest.mojave.matchesProductVersion(nil))
        #expect(!Guest.bigSur.matchesProductVersion(11))
    }

    @Test func restoreDiscsAreIdentifiedByVersionOnly() {
        #expect(Guest.restoreDisc(productVersion: "10.4.11") == .tiger)
        #expect(Guest.restoreDisc(productVersion: "10.5") == .leopard)
        #expect(Guest.restoreDisc(productVersion: "10.6.8") == .snowLeopard)
        #expect(Guest.restoreDisc(productVersion: "10.7") == nil)
        #expect(Guest.restoreDisc(productVersion: 10.4) == nil)
        #expect(Guest.restoreDisc(productVersion: nil) == nil)
    }

    // MARK: - Disk headers

    private func reader(_ marks: [Int: String], size: Int = 36864) -> DiskHeader.Reader {
        var bytes = [UInt8](repeating: 0, count: size)
        for (offset, text) in marks { bytes.replaceSubrange(offset..<offset + text.utf8.count, with: text.utf8) }
        return { offset, count in
            let start = Int(offset)
            return start + count <= bytes.count ? Array(bytes[start..<start + count]) : nil
        }
    }

    @Test func eachPublishedContainerIsRecognized() {
        #expect(DiskHeader.isRecognizableDisk(reader([512: "EFI PART"], size: 4096)))
        #expect(DiskHeader.isRecognizableDisk(reader([0: "ER\u{02}\0", 512: "PM"])))
        for volume in ["H+", "HX", "BD"] { #expect(DiskHeader.isRecognizableDisk(reader([1024: volume], size: 4096))) }
        for descriptor in ["CD001", "BEA01"] { #expect(DiskHeader.isRecognizableDisk(reader([32769: descriptor]))) }
    }

    @Test func anythingElseIsNot() {
        #expect(!DiskHeader.isRecognizableDisk(reader([:], size: 4096)))
        #expect(!DiskHeader.isRecognizableDisk(reader([:])))
        // Too short to read every block it needs: a truncated image.
        #expect(!DiskHeader.isRecognizableDisk(reader([512: "EFI PART"], size: 1535)))
        // A driver descriptor with no partition map is not a disk.
        #expect(!DiskHeader.isRecognizableDisk(reader([0: "ER\u{02}\0"])))
        // A descriptor must be at its exact offset.
        #expect(!DiskHeader.isRecognizableDisk(reader([32768: "CD001"])))
    }

    @Test func applePartitionMapBlockSizeRules() {
        #expect(DiskHeader.hasApplePartitionMap(reader([0: "ER\u{02}\0", 512: "PM"])))
        #expect(DiskHeader.hasApplePartitionMap(reader([0: "ER\u{08}\0", 2048: "PM"])))
        // 2048-byte blocks: a map at 512 isn't where the descriptor points.
        #expect(!DiskHeader.hasApplePartitionMap(reader([0: "ER\u{08}\0", 512: "PM"])))
        // Below 512 bytes.
        #expect(!DiskHeader.hasApplePartitionMap(reader([0: "ER\u{01}\0", 256: "PM"])))
        // Not a power of two.
        #expect(!DiskHeader.hasApplePartitionMap(reader([0: "ER\u{02}\u{01}", 513: "PM"])))
        #expect(!DiskHeader.hasApplePartitionMap(reader([:])))
    }

    @Test func aPackageIsWhatItsMagicSays() {
        #expect(DiskHeader.isInstallerPackage(reader([0: "xar!"], size: 4)))
        #expect(!DiskHeader.isInstallerPackage(reader([0: "xar"], size: 3)))
        #expect(!DiskHeader.isInstallerPackage(reader([0: "koly"], size: 4)))
    }

    /// A prepared image reached through a symlink is refused, but a package reached through one isn't.
    @Test func headerChecksDifferOnSymlinks() throws {
        let temporary = try TemporaryDirectory()
        let image = temporary.url.appending(component: "image")
        var bytes = Data(count: 4096)
        bytes.replaceSubrange(512..<520, with: Data("EFI PART".utf8))
        try bytes.write(to: image)
        let package = temporary.url.appending(component: "package")
        try Data("xar!rest".utf8).write(to: package)
        let imageLink = temporary.url.appending(component: "image-link")
        let packageLink = temporary.url.appending(component: "package-link")
        try FileManager.default.createSymbolicLink(at: imageLink, withDestinationURL: image)
        try FileManager.default.createSymbolicLink(at: packageLink, withDestinationURL: package)

        #expect(DiskHeader.fileIsRecognizableDisk(image))
        #expect(!DiskHeader.fileIsRecognizableDisk(imageLink))
        #expect(DiskHeader.fileIsInstallerPackage(package))
        #expect(DiskHeader.fileIsInstallerPackage(packageLink))
        #expect(!DiskHeader.fileIsRecognizableDisk(temporary.url.appending(component: "missing")))
    }

    // MARK: - Choosing an installer

    /// A bundle shaped like Apple's, with only what's named.
    private func application(
        in directory: URL, identifier: String?, version: Any? = nil, files: [String: String] = [:],
        extensionName: String = "app"
    ) throws -> URL {
        let app = directory.appending(component: "\(UUID().uuidString).\(extensionName)")
        let manager = FileManager.default
        for (path, contents) in files {
            let file = app.appending(path: path)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        try manager.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        if let identifier {
            (["CFBundleIdentifier": identifier] as NSDictionary).write(
                to: app.appending(path: "Contents/Info.plist"), atomically: true)
        }
        if let version {
            let support = app.appending(path: "Contents/SharedSupport")
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
            (["System Image Info": version] as NSDictionary).write(
                to: support.appending(path: "InstallInfo.plist"), atomically: true)
        }
        return app
    }

    private let splitFiles = [
        "Contents/Resources/createinstallmedia": "x", "Contents/SharedSupport/InstallESD.dmg": "x",
        "Contents/SharedSupport/BaseSystem.dmg": "x"
    ]
    private let bigSurFiles = [
        "Contents/Resources/createinstallmedia": "x", "Contents/SharedSupport/SharedSupport.dmg": "xar!signed"
    ]

    @Test func aCompleteSplitInstallerIsAccepted() throws {
        let temporary = try TemporaryDirectory()
        let app = try application(
            in: temporary.url, identifier: "com.apple.InstallAssistant.Mojave", version: ["version": "10.14.6"],
            files: splitFiles)
        #expect(InstallerValidation.refusal(forInstaller: app, guest: .mojave) == nil)
        // Another guest's identifier and version: the wrong OS, whichever it claims to be.
        #expect(InstallerValidation.refusal(forInstaller: app, guest: .catalina) == .incompleteInstallerApplication)
        #expect(InstallerValidation.refusal(forInstaller: app, guest: nil) == .incompleteInstallerApplication)
    }

    /// Unlike a flat-package or Big Sur app, a split installer's version is required.
    @Test func aSplitInstallerWithoutAVersionIsRefused() throws {
        let temporary = try TemporaryDirectory()
        let app = try application(
            in: temporary.url, identifier: "com.apple.InstallAssistant.Mojave", files: splitFiles)
        #expect(InstallerValidation.refusal(forInstaller: app, guest: .mojave) == .incompleteInstallerApplication)
    }

    /// Flat-package guests need no createinstallmedia, BaseSystem or InstallInfo, but a version present must match.
    @Test func aFlatInstallerNeedsOnlyItsESD() throws {
        let temporary = try TemporaryDirectory()
        let identifier = "com.apple.InstallAssistant.Lion"
        let esd = ["Contents/SharedSupport/InstallESD.dmg": "x"]
        let bare = try application(in: temporary.url, identifier: identifier, files: esd)
        #expect(InstallerValidation.refusal(forInstaller: bare, guest: .lion) == nil)
        let matching = try application(
            in: temporary.url, identifier: identifier, version: ["version": "10.7.5"], files: esd)
        #expect(InstallerValidation.refusal(forInstaller: matching, guest: .lion) == nil)
        let wrong = try application(in: temporary.url, identifier: identifier, version: ["version": "10.8"], files: esd)
        #expect(InstallerValidation.refusal(forInstaller: wrong, guest: .lion) == .incompleteInstallerApplication)
        let malformed = try application(in: temporary.url, identifier: identifier, version: "malformed", files: esd)
        #expect(InstallerValidation.refusal(forInstaller: malformed, guest: .lion) == .incompleteInstallerApplication)
        let empty = try application(
            in: temporary.url, identifier: identifier, files: ["Contents/SharedSupport/InstallESD.dmg": ""])
        #expect(InstallerValidation.refusal(forInstaller: empty, guest: .lion) == .incompleteInstallerApplication)
    }

    @Test func bigSurNeedsApplesSignedPackageNotItsInnerImage() throws {
        let temporary = try TemporaryDirectory()
        let identifier = "com.apple.InstallAssistant.macOSBigSur"
        let good = try application(in: temporary.url, identifier: identifier, files: bigSurFiles)
        #expect(InstallerValidation.refusal(forInstaller: good, guest: .bigSur) == nil)
        var inner = bigSurFiles
        inner["Contents/SharedSupport/SharedSupport.dmg"] = "inner disk image"
        let damaged = try application(in: temporary.url, identifier: identifier, files: inner)
        #expect(InstallerValidation.refusal(forInstaller: damaged, guest: .bigSur) == .bigSurPackageMissing)
    }

    @Test func aRenamedBundleKeepsItsIdentityButNotAnotherExtension() throws {
        let temporary = try TemporaryDirectory()
        let identifier = "com.apple.InstallAssistant.Lion"
        let esd = ["Contents/SharedSupport/InstallESD.dmg": "x"]
        let upper = try application(in: temporary.url, identifier: identifier, files: esd, extensionName: "APP")
        #expect(InstallerValidation.refusal(forInstaller: upper, guest: .lion) == nil)
        let other = try application(in: temporary.url, identifier: identifier, files: esd, extensionName: "bundle")
        #expect(InstallerValidation.refusal(forInstaller: other, guest: .lion) == .incompleteInstallerApplication)
    }

    @Test func aRestoreDiscImageIsOnlyGatedOnBeingASubstantialFile() throws {
        let temporary = try TemporaryDirectory()
        let image = temporary.url.appending(component: "dvd")
        try Data(count: 513).write(to: image)
        for guest in [Guest.tiger, .leopard, .snowLeopard] {
            #expect(InstallerValidation.refusal(forInstaller: image, guest: guest) == nil)
        }
        let small = temporary.url.appending(component: "small")
        try Data(count: 512).write(to: small)
        #expect(InstallerValidation.refusal(forInstaller: small, guest: .leopard) == .incompleteRestoreDiscImage)
        let link = temporary.url.appending(component: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        #expect(InstallerValidation.refusal(forInstaller: link, guest: .leopard) == .incompleteRestoreDiscImage)
        #expect(
            InstallerValidation.refusal(forInstaller: temporary.url, guest: .leopard) == .incompleteRestoreDiscImage)
    }

    @Test func aCompleteDiscHasItsVersionBootFileAndAnEitherShapePackage() throws {
        func disc(version: String, flat: Bool?, boot: Bool = true) throws -> (TemporaryDirectory, URL) {
            let temporary = try TemporaryDirectory()
            let services = temporary.url.appending(path: "System/Library/CoreServices")
            try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
            (["ProductVersion": version] as NSDictionary).write(
                to: services.appending(component: "SystemVersion.plist"), atomically: true)
            if boot { try Data("x".utf8).write(to: services.appending(component: "boot.efi")) }
            let package = temporary.url.appending(path: "System/Installation/Packages/OSInstall.mpkg")
            if flat == true {
                try FileManager.default.createDirectory(
                    at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("xar!".utf8).write(to: package)
            } else if flat == false {
                let plist = package.appending(path: "Contents/Info.plist")
                try FileManager.default.createDirectory(
                    at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: plist)
            }
            return (temporary, temporary.url)
        }
        for flat in [true, false] {
            let (keep, mount) = try disc(version: "10.5.8", flat: flat)
            #expect(InstallerValidation.restoreDiscIsComplete(at: mount, guest: .leopard))
            #expect(!InstallerValidation.restoreDiscIsComplete(at: mount, guest: .snowLeopard))
            withExtendedLifetime(keep) {}
        }
        let (keepNone, none) = try disc(version: "10.5.8", flat: nil)
        #expect(!InstallerValidation.restoreDiscIsComplete(at: none, guest: .leopard))
        withExtendedLifetime(keepNone) {}
        let (keepBoot, noBoot) = try disc(version: "10.6", flat: true, boot: false)
        #expect(!InstallerValidation.restoreDiscIsComplete(at: noBoot, guest: .snowLeopard))
        withExtendedLifetime(keepBoot) {}
    }

    // MARK: - Guest support

    private func support(in directory: URL) throws -> URL {
        let support = directory.appending(component: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for name in [
            "opengl-guest-agent", "opengl-install-bootstrap", "opengl-create-account", "guest-ssh",
            "guest-host-connection"
        ] {
            try Data("x".utf8).write(to: support.appending(component: name))
        }
        return support
    }

    @Test func completeGuestSupportIsAccepted() throws {
        let temporary = try TemporaryDirectory()
        let directory = try support(in: temporary.url)
        let nested = directory.appending(path: "tools")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appending(component: "extra"))
        #expect(InstallerValidation.refusal(forGuestSupport: directory) == nil)
    }

    @Test func aMissingOrEmptyRequiredToolIsRefused() throws {
        let temporary = try TemporaryDirectory()
        let directory = try support(in: temporary.url)
        try Data().write(to: directory.appending(component: "guest-ssh"))
        #expect(InstallerValidation.refusal(forGuestSupport: directory) == .guestSupportMissing)
        try FileManager.default.removeItem(at: directory.appending(component: "guest-ssh"))
        #expect(InstallerValidation.refusal(forGuestSupport: directory) == .guestSupportMissing)
    }

    /// Anything copied onto a guest's media must be a plain file inside this directory.
    @Test func aSymlinkOrOversizedFileIsRefused() throws {
        let temporary = try TemporaryDirectory()
        let outside = temporary.url.appending(component: "outside")
        try Data("x".utf8).write(to: outside)
        let escaping = try support(in: temporary.url)
        try FileManager.default.createSymbolicLink(
            at: escaping.appending(component: "link"), withDestinationURL: outside)
        #expect(InstallerValidation.refusal(forGuestSupport: escaping) == .guestSupportInvalid)
        try FileManager.default.removeItem(at: escaping.appending(component: "link"))
        let large = escaping.appending(component: "large")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
        try handle.close()
        #expect(InstallerValidation.refusal(forGuestSupport: escaping) == .guestSupportInvalid)
        let exact = try FileHandle(forWritingTo: large)
        try exact.truncate(atOffset: 64 * 1024 * 1024)
        try exact.close()
        #expect(InstallerValidation.refusal(forGuestSupport: escaping) == nil)
    }

    // MARK: - Big Sur's asset

    @Test func theManifestMustDescribeExactlyOneAsset() throws {
        let one: [String: Any] = ["OSVersion": "11.7.11", "Build": "20G"]
        let asset = try #require(HybridAsset(metadata: ["Assets": [one]]))
        #expect(asset.productVersion == "11.7.11" && asset.build == "20G")
        #expect(HybridAsset(metadata: ["Assets": [one, one]]) == nil)
        #expect(HybridAsset(metadata: ["Assets": [Any]()]) == nil)
        #expect(HybridAsset(metadata: ["Assets": "malformed"]) == nil)
        #expect(HybridAsset(metadata: ["Assets": ["malformed"]]) == nil)
        #expect(HybridAsset(metadata: ["Assets": [["OSVersion": "10.15", "Build": "19H"]]]) == nil)
        #expect(HybridAsset(metadata: ["Assets": [["OSVersion": "11.7"]]]) == nil)
        #expect(HybridAsset(metadata: ["Assets": [["OSVersion": "11.7", "Build": 7] as [String: Any]]]) == nil)
        #expect(HybridAsset(metadata: nil) == nil)
    }
}
