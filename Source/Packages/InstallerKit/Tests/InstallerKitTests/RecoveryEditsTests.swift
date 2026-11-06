import Foundation
import Testing

@testable import InstallerKit

@Suite struct RecoveryEditsTests {
    private static let bootstrap =
        "/System/Installation/Packages/Extras/VirtualIntelMac/opengl-install-bootstrap"
    private static let shared: [RecoveryEdit] = [
        .symlink(path: "System/Installation/Packages/Extras/rc.imaging", destination: bootstrap),
        .symlink(
            path: "System/Installation/Packages/Extras/minstallconfig.xml",
            destination: "/var/tmp/VirtualIntelMac-minstallconfig.plist")
    ]
    private static let support = RecoveryEdit.installSupport(
        path: "System/Installation/Packages/Extras/VirtualIntelMac")
    private static let early = RecoveryEdit.createScript(
        path: "etc/rc.cdrom.local",
        contents:
            "#!/bin/sh\nexec /System/Installation/Packages/Extras/VirtualIntelMac/opengl-install-bootstrap "
            + "--start-recovery-agent\n")
    private static let scoped: [RecoveryEdit] = [
        .patchStartup(path: "etc/rc.install", patch: .scopedInstallerLaunch), .prepareAutomaticInstaller
    ]

    /// The whole sequence for each guest, as order matters: each step depends on the one before.
    @Test func eachGuestsEditsInOrder() {
        let disc: [RecoveryEdit] = [
            .symlink(path: "etc/rc.cdrom.local", destination: Self.bootstrap),
            .symlink(path: "etc/minstallconfig.xml", destination: "/var/tmp/VirtualIntelMac-minstallconfig.plist"),
            .symlink(
                path: "System/Installation/CDIS/auto-pilot",
                destination: "/var/tmp/VirtualIntelMac-InstallerAuthorization.plist")
        ]
        let expected: [Guest: [RecoveryEdit]] = [
            .tiger: [],
            .leopard: [Self.support] + Self.shared + disc + Self.scoped,
            .snowLeopard: [Self.support] + Self.shared + disc + Self.scoped,
            .lion: [Self.support] + Self.shared + Self.scoped,
            .mountainLion: [Self.support] + Self.shared + Self.scoped,
            .mavericks: [Self.support] + Self.shared + Self.scoped,
            .yosemite: [Self.support, Self.early] + Self.shared,
            .elCapitan: [Self.support, Self.early] + Self.shared,
            .sierra: [Self.support, Self.early] + Self.shared,
            .highSierra: [
                Self.support, Self.early, .patchStartup(path: "etc/rc.install", patch: .highSierraOpenDocument)
            ] + Self.shared,
            .mojave: [], .catalina: [], .bigSur: []
        ]
        #expect(expected.count == Guest.allCases.count)
        for (guest, edits) in expected { #expect(guest.recoveryEdits == edits, "\(guest)") }
    }

    @Test func noEditEscapesTheWorkingCopy() {
        for guest in Guest.allCases {
            for edit in guest.recoveryEdits {
                guard let path = RecoveryEditBridge(edit).path else { continue }
                #expect(!path.hasPrefix("/"), "\(guest) \(path)")
                #expect(!path.split(separator: "/").contains(".."), "\(guest) \(path)")
            }
        }
    }

    // MARK: - Startup scripts

    @Test func highSierraNeedsBothAnchorsExactlyOnce() throws {
        let argument = #""${LAUNCH}" "${TARGET_APP}""#
        let package = "INSTALL_PKG=/System/Installation/Packages/OSInstall.mpkg"
        let good = "a\n\(package)\nb\n\(argument) -f x\n"
        let patched = try #require(StartupPatch.highSierraOpenDocument.applied(to: good))
        #expect(
            patched == "a\nINSTALL_PKG=/InstallInfo.plist\nb\n"
                + #""${LAUNCH}" /System/Installation/Packages/Extras/VirtualIntelMac/opengl-installer-launch "${TARGET_APP}" -f x"#
                + "\n")
        for bad in [nil, "", argument, package, good + argument, good + package] {
            #expect(StartupPatch.highSierraOpenDocument.applied(to: bad) == nil)
        }
    }

    /// The trailing spaces are the anchor; a script that spaces it differently was never measured.
    @Test func scopedLaunchKeepsItsExactSpacing() throws {
        let invocation = "    \"${OSINSTALLER}\"                                "
        let patched = try #require(StartupPatch.scopedInstallerLaunch.applied(to: "a\n\(invocation)-f x\nb\n"))
        #expect(
            patched
                == "a\n    \"${LAUNCH}\" /System/Installation/Packages/Extras/VirtualIntelMac/opengl-installer-launch "
                + "\"${OSINSTALLER}\" -f x\nb\n")
        #expect(StartupPatch.scopedInstallerLaunch.applied(to: nil) == nil)
        #expect(StartupPatch.scopedInstallerLaunch.applied(to: "    \"${OSINSTALLER}\" -f x") == nil)
        #expect(StartupPatch.scopedInstallerLaunch.applied(to: invocation + invocation) == nil)
    }

    @Test func serialHookMustAppearOnce() {
        #expect(RecoveryText.hasSerialHook("a\n\t/etc/rc.cdrom.local\nb"))
        #expect(!RecoveryText.hasSerialHook(nil))
        #expect(!RecoveryText.hasSerialHook("/etc/rc.cdrom.local\n"))
        #expect(!RecoveryText.hasSerialHook("\t/etc/rc.cdrom.local\n\t/etc/rc.cdrom.local\n"))
        #expect(
            RecoveryText.serialHookScript
                == "#!/bin/sh\nexec /usr/libexec/guest-recovery-agent --start-recovery-service >> "
                + "/var/log/virtualintelmac-recovery.log 2>&1\n")
    }

    @Test func aModelCheckIsOnlyBypassedWhenRecognized() {
        #expect(RecoveryText.bypassingModelCheck("#!/usr/bin/perl -w\nlist\n") == "#!/usr/bin/perl -w\nexit 0;\n")
        #expect(RecoveryText.bypassingModelCheck("#!/bin/sh\nlist\n") == "#!/bin/sh\nexit 0\n")
        #expect(RecoveryText.bypassingModelCheck("#!/bin/bash\nlist\n") == "#!/bin/bash\nexit 0\n")
        #expect(RecoveryText.bypassingModelCheck("#!/bin/sh") == "#!/bin/sh\nexit 0\n")
        #expect(RecoveryText.bypassingModelCheck(nil) == nil)
        #expect(RecoveryText.bypassingModelCheck("\u{7F}ELF") == nil)
        #expect(RecoveryText.bypassingModelCheck("#!/bin/zsh\nlist\n") == nil)
        #expect(RecoveryText.bypassingModelCheck("#!/bin/sh -e\nlist\n") == nil)
        #expect(RecoveryText.bypassingModelCheck("not a script\n#!/bin/sh\n") == nil)
    }

    @Test func budgetsOnlyEverGrow() {
        let script = """
            RAMDisk /var/tmp 1024
              RAMDisk\t/var/run 256
            RAMDisk /var/tmp 999999
            RAMDisk /Volumes 1024
            # RAMDisk /var/tmp 1024
            """
        let raised = """
            RAMDisk /var/tmp 262144
              RAMDisk\t/var/run 16384
            RAMDisk /var/tmp 999999
            RAMDisk /Volumes 1024
            # RAMDisk /var/tmp 1024
            """
        #expect(RecoveryText.raisingRAMDiskBudgets(script) == raised)
        #expect(RecoveryText.raisingRAMDiskBudgets(raised) == raised)
        #expect(RecoveryText.raisingRAMDiskBudgets("no budgets") == "no budgets")
    }

    @Test func aPlanOpensItsChecksAndSelectsRosettaOnlyWhenPresent() throws {
        let plan = """
            <installer-gui-script><installation-check script="models()"/><choice id="Rosetta" start_selected="false"/>\
            <choice id="Other" start_selected="false"/></installer-gui-script>
            """
        let opened = try #require(RecoveryText.openingInstallationPlan(plan, selectingRosetta: true))
        #expect(opened.contains(#"script="true""#) && !opened.contains("models()"))
        #expect(opened.contains(#"<choice id="Rosetta" start_selected="true""#))
        #expect(opened.contains(#"<choice id="Other" start_selected="false""#))
        let without = try #require(RecoveryText.openingInstallationPlan(plan, selectingRosetta: false))
        #expect(without.contains(#"<choice id="Rosetta" start_selected="false""#))
        let added = try #require(
            RecoveryText.openingInstallationPlan(
                #"<installer-gui-script><choice id="Rosetta"/></installer-gui-script>"#, selectingRosetta: true))
        #expect(added.contains(#"start_selected="true""#))
    }

    @Test func aDocumentThatIsNotAPlanIsRefused() {
        for text in [nil, "", "not xml", "<other/>"] {
            #expect(RecoveryText.openingInstallationPlan(text, selectingRosetta: true) == nil)
        }
    }

    @Test func onlyAnExactStatusLineIsAppleSoftware() {
        #expect(RecoveryText.isSignedAppleSoftware("Package \"x\":\n   Status: signed Apple Software\n"))
        #expect(!RecoveryText.isSignedAppleSoftware(nil))
        #expect(!RecoveryText.isSignedAppleSoftware("   Status: signed by a developer certificate\n"))
        #expect(!RecoveryText.isSignedAppleSoftware("Status: signed Apple Software Update\n"))
        #expect(!RecoveryText.isSignedAppleSoftware("Package \"Status: signed Apple Software\":\n"))
    }

    @Test func unknownEntitlementsFailClosed() {
        #expect(RecoveryText.acceptsAutomaticInstaller(entitlements: nil))
        #expect(RecoveryText.acceptsAutomaticInstaller(entitlements: [String: Any]()))
        #expect(RecoveryText.acceptsAutomaticInstaller(entitlements: ["com.apple.private.securityd.stash": true]))
        #expect(!RecoveryText.acceptsAutomaticInstaller(entitlements: ["com.apple.private.securityd.stash": false]))
        #expect(!RecoveryText.acceptsAutomaticInstaller(entitlements: ["com.apple.other": true]))
        #expect(
            !RecoveryText.acceptsAutomaticInstaller(
                entitlements: ["com.apple.private.securityd.stash": true, "com.apple.other": true]))
        #expect(!RecoveryText.acceptsAutomaticInstaller(entitlements: "malformed"))
    }

    // MARK: - Finished media

    @Test func installerPathsMatchTheGuestToolsHeader() throws {
        let header = try String(
            contentsOf: Fixture.sourceRoot.appending(path: "tools/opengl-installer-paths.h"), encoding: .utf8)
        for guest in Guest.allCases {
            for path in [guest.recoveryInstallerPath, guest.automaticInstallerPath].compactMap(\.self) {
                #expect(header.contains("\"\(path)\""), "\(guest): \(path)")
            }
        }
        #expect(header.contains("#define VIM_LION_INSTALLER \"\(Guest.lion.recoveryInstallerPath ?? "")\""))
        #expect(header.contains("#define VIM_OSX_INSTALLER \"\(Guest.mavericks.recoveryInstallerPath ?? "")\""))
        #expect(header.contains("#define VIM_MACOS_INSTALLER \"\(Guest.sierra.recoveryInstallerPath ?? "")\""))
    }

    @Test func installerPathsExistExactlyForBootstrappedGuests() {
        for guest in Guest.allCases {
            let bootstrap = guest.recoveryAutomation.usesBootstrap
            let scoped = guest.recoveryAutomation == .scopedInstaller
            #expect((guest.recoveryInstallerPath != nil) == bootstrap, "\(guest)")
            #expect((guest.automaticInstallerPath != nil) == scoped, "\(guest)")
        }
    }

    @Test func mediaRequirementsPerGuest() {
        let boot = MediaRequirement.regularFile("System/Library/CoreServices/boot.efi")
        let packages = MediaRequirement.anyRegularFile([
            "System/Installation/Packages/OSInstall.mpkg/Contents/Info.plist",
            "System/Installation/Packages/OSInstall.mpkg"
        ])
        let base: [MediaRequirement] = [.regularFile("BaseSystem.dmg"), .regularFile("BaseSystem.chunklist")]
        func tool(_ path: String?) -> MediaRequirement { .regularFile(String(path?.dropFirst() ?? "")) }
        #expect(
            Guest.tiger.mediaRequirements == [
                boot, packages, .regularFile("Applications/Utilities/Installer.app/Contents/MacOS/Installer")
            ])
        #expect(
            Guest.lion.mediaRequirements == [
                boot, packages, tool(Guest.lion.recoveryInstallerPath), tool(Guest.lion.automaticInstallerPath)
            ])
        #expect(Guest.sierra.mediaRequirements == [boot, packages, tool(Guest.sierra.recoveryInstallerPath)] + base)
        #expect(
            Guest.highSierra.mediaRequirements == [
                boot, .regularFile("InstallInfo.plist"), .regularFile("InstallESD.dmg"),
                tool(Guest.highSierra.recoveryInstallerPath)
            ] + base + [
                .text(
                    "etc/rc.install",
                    contains:
                        #""${LAUNCH}" /System/Installation/Packages/Extras/VirtualIntelMac/opengl-installer-launch "${TARGET_APP}""#
                )
            ])
        #expect(
            Guest.mojave.mediaRequirements == [
                boot, .nonemptyFile("usr/libexec/guest-recovery-agent"),
                .text(
                    "private/etc/rc.cdrom.local",
                    contains: "/usr/libexec/guest-recovery-agent --start-recovery-service")
            ])
    }

    /// Each requirement against a real directory, with paths containing spaces as the automatic installer's does.
    @Test func requirementsReadTheFilesystem() throws {
        let temporary = try TemporaryDirectory()
        let mount = temporary.url
        let manager = FileManager.default
        let spaced = mount.appending(path: "A B/C D")
        try manager.createDirectory(at: spaced.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: spaced)
        try Data().write(to: mount.appending(path: "empty"))
        try manager.createSymbolicLink(at: mount.appending(path: "link"), withDestinationURL: spaced)
        try Data("has needle inside".utf8).write(to: mount.appending(path: "text"))

        #expect(MediaRequirement.regularFile("A B/C D").isSatisfied(at: mount))
        #expect(MediaRequirement.regularFile("empty").isSatisfied(at: mount))
        #expect(!MediaRequirement.regularFile("missing").isSatisfied(at: mount))
        #expect(!MediaRequirement.regularFile("A B").isSatisfied(at: mount))
        #expect(!MediaRequirement.regularFile("link").isSatisfied(at: mount))
        #expect(MediaRequirement.anyRegularFile(["missing", "empty"]).isSatisfied(at: mount))
        #expect(!MediaRequirement.anyRegularFile(["missing", "link"]).isSatisfied(at: mount))
        #expect(MediaRequirement.nonemptyFile("A B/C D").isSatisfied(at: mount))
        #expect(!MediaRequirement.nonemptyFile("empty").isSatisfied(at: mount))
        #expect(MediaRequirement.text("text", contains: "needle").isSatisfied(at: mount))
        #expect(!MediaRequirement.text("text", contains: "absent").isSatisfied(at: mount))
        #expect(!MediaRequirement.text("missing", contains: "needle").isSatisfied(at: mount))
    }

    // MARK: - Big Sur

    @Test func hybridLayoutStagesEveryExtractedFileExceptManifests() {
        let staged = Set(HybridMedia.stagedFiles.keys)
        #expect(staged == Set(HybridMedia.archiveMembers).subtracting([HybridMedia.extractedManifests + "/*"]))
        #expect(
            HybridMedia.stagedFiles["AssetData/boot/Firmware/System/Library/CoreServices/bootbase.efi"]
                == "System/Library/CoreServices/boot.efi")
        #expect(HybridMedia.bootPlist == ["Kernel Flags": "root-dmg=file:///BaseSystem/BaseSystem.dmg"])
        #expect(
            HybridMedia.installerCookie(applicationName: "A.app", productVersion: "11.7", productBuild: "20G")
                == ["AppName": "A.app", "ProductVersion": "11.7", "ProductBuildVersion": "20G"])
    }
}
