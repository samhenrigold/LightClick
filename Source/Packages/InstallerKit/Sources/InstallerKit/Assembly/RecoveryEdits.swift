// What installer preparation changes on a generated recovery volume, per guest and in order. Every edit is relative to the
// attached working copy. None of them can reach an original installer, which stays attached read-only.
//
// These paths and file contents are guest-facing: installed guests and the guest tools depend on them.
import Foundation

/// One change to the attached working copy. WRITES the working image.
public enum RecoveryEdit: Equatable, Sendable {
    /// Copies the guest's support files into `path`, creating its parent.
    case installSupport(path: String)
    /// Adds an executable script. Refused if something is already there.
    case createScript(path: String, contents: String)
    /// Rewrites a startup script in place, or fails if it is not the script this was measured against.
    case patchStartup(path: String, patch: StartupPatch)
    case symlink(path: String, destination: String)
    /// Adds a re-signed copy of Apple's installer beside the original.
    case prepareAutomaticInstaller
}

private let packages = "System/Installation/Packages"
private let extras = packages + "/Extras"
private let supportDirectory = extras + "/VirtualIntelMac"
private let bootstrapTool = "/" + supportDirectory + "/opengl-install-bootstrap"
private let minstallConfiguration = "/var/tmp/VirtualIntelMac-minstallconfig.plist"
private let installerAuthorization = "/var/tmp/VirtualIntelMac-InstallerAuthorization.plist"
private let serialAgentCommand = "/usr/libexec/guest-recovery-agent --start-recovery-service"
private let highSierraLaunch = "\"${LAUNCH}\" /" + supportDirectory + "/opengl-installer-launch \"${TARGET_APP}\""

extension Guest {
    /// The bootstrap's edits, in the order they run. Empty for a guest without the bootstrap.
    public var recoveryEdits: [RecoveryEdit] {
        guard recoveryAutomation.usesBootstrap else { return [] }
        let native = recoveryAutomation.usesNativeInstaller
        let isRestoreDisc = if case .restoreDisc = mediaLayout { true } else { false }
        var edits: [RecoveryEdit] = [.installSupport(path: supportDirectory)]
        if native {
            edits.append(
                .createScript(
                    path: "etc/rc.cdrom.local", contents: "#!/bin/sh\nexec \(bootstrapTool) --start-recovery-agent\n"))
        }
        if self == .highSierra {
            edits.append(.patchStartup(path: "etc/rc.install", patch: .highSierraOpenDocument))
        }
        edits += [
            .symlink(path: extras + "/rc.imaging", destination: bootstrapTool),
            .symlink(path: extras + "/minstallconfig.xml", destination: minstallConfiguration)
        ]
        if isRestoreDisc {
            edits += [
                // The measured restore DVD predates rc.imaging. Its native pre-WindowServer hook runs once as guest root.
                .symlink(path: "etc/rc.cdrom.local", destination: bootstrapTool),
                .symlink(path: "etc/minstallconfig.xml", destination: minstallConfiguration),
                // LanguageChooser-31 (Leopard) and -62 (Snow) check this path, select their first (English) row and call
                // finalizeLanguage:. The target only exists after our root bootstrap authorizes automatic setup, so manual
                // installs keep the normal language picker.
                .symlink(path: "System/Installation/CDIS/auto-pilot", destination: installerAuthorization)
            ]
        }
        if !native {
            edits += [
                .patchStartup(path: "etc/rc.install", patch: .scopedInstallerLaunch),
                .prepareAutomaticInstaller
            ]
        }
        return edits
    }

    /// Apple's own recovery installer. Sierra and High Sierra renamed both the application and executable. The bootstrap
    /// reads the same paths from tools/opengl-installer-paths.h, which a test keeps equal.
    public var recoveryInstallerPath: String? {
        switch self {
        case .leopard, .snowLeopard, .lion:
            "/System/Installation/CDIS/Mac OS X Installer.app/Contents/MacOS/Mac OS X Installer"
        case .mountainLion, .mavericks, .yosemite, .elCapitan:
            "/System/Installation/CDIS/OS X Installer.app/Contents/MacOS/OS X Installer"
        case .sierra, .highSierra: "/System/Installation/CDIS/macOS Installer.app/Contents/MacOS/macOS Installer"
        case .tiger, .mojave, .catalina, .bigSur: nil
        }
    }

    /// The re-signed automatic copy, which keeps the original executable's name.
    public var automaticInstallerPath: String? {
        switch self {
        case .leopard, .snowLeopard, .lion:
            "/System/Installation/CDIS/VirtualIntelMac Installer.app/Contents/MacOS/Mac OS X Installer"
        case .mountainLion, .mavericks:
            "/System/Installation/CDIS/VirtualIntelMac Installer.app/Contents/MacOS/OS X Installer"
        case .tiger, .yosemite, .elCapitan, .sierra, .highSierra, .mojave, .catalina, .bigSur: nil
        }
    }
}

/// The recognized startup script rewrites. A script without its exact anchors is refused, never guessed at.
public enum StartupPatch: Equatable, Sendable {
    /// High Sierra 17G66 reaches disk discovery but never opens the `-f minstall` document. AppKit's finishLaunching handles
    /// `-NSOpen`, which a compiled wrapper adds to Language Chooser's child only, keeping the signed installer.
    case highSierraOpenDocument
    /// Apple's minstall branch bypasses Language Chooser, which owns the native gray background. This restores that launcher
    /// around our exec wrapper. The app-owned EFI supplies prev-lang:kbd, so its observed hidden mode chooses that language
    /// without a picker and supervises its child. The wrapper, not Language Chooser, sets the scoped DYLD variable.
    case scopedInstallerLaunch

    /// Nil when `original` is missing or not the script this patch was measured against.
    public func applied(to original: String?) -> String? {
        guard let original = original as NSString? else { return nil }
        switch self {
        case .highSierraOpenDocument:
            let argument = "\"${LAUNCH}\" \"${TARGET_APP}\""
            let package = "INSTALL_PKG=/System/Installation/Packages/OSInstall.mpkg"
            guard original.components(separatedBy: argument).count == 2,
                original.components(separatedBy: package).count == 2
            else { return nil }
            return
                original
                .replacingOccurrences(of: argument, with: highSierraLaunch)
                .replacingOccurrences(of: package, with: "INSTALL_PKG=/InstallInfo.plist")
        case .scopedInstallerLaunch:
            let invocation = "    \"${OSINSTALLER}\"                                "
            guard original.components(separatedBy: invocation).count == 2 else { return nil }
            return original.replacingOccurrences(
                of: invocation,
                with: "    \"${LAUNCH}\" /" + supportDirectory + "/opengl-installer-launch \"${OSINSTALLER}\" ")
        }
    }
}

/// Text edits on a generated copy's own files. Each takes what was read and returns what to write back.
public enum RecoveryText {
    /// Some restore discs run this script before the installer; retail media may not contain it. Bypass only a recognizable
    /// script, and never overwrite an unknown executable or insist on a particular model list. Nil means leave it alone.
    public static func bypassingModelCheck(_ original: String?) -> String? {
        guard let original = original as NSString?, original.hasPrefix("#!"),
            let line = original.components(separatedBy: "\n").first
        else { return nil }
        if line.contains("perl") { return line + "\nexit 0;\n" }
        return line.hasSuffix("/sh") || line.hasSuffix("/bash") ? line + "\nexit 0\n" : nil
    }

    /// Measured 9J3050 recovery uses 512-byte sectors: 128 KB /var/run cannot hold the adapter plus a status tool, and
    /// 512 KB /var/tmp cannot stage the compiled setup controls. Only raises this copy's native RAMDisk budgets.
    public static func raisingRAMDiskBudgets(_ script: String) -> String {
        var text = script as NSString
        for (path, budget) in [("/var/tmp", 262144), ("/var/run", 16384)] {
            let escaped = NSRegularExpression.escapedPattern(for: path)
            guard let pattern = try? NSRegularExpression(pattern: "(?m)^(\\s*RAMDisk[ \\t]+\(escaped)[ \\t]+)([0-9]+)")
            else { continue }
            for match in pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length))
                .reversed()
            {
                let number = match.range(at: 2)
                if text.substring(with: number).withCString({ strtoll($0, nil, 10) }) < budget {
                    text = text.replacingCharacters(in: number, with: String(budget)) as NSString
                }
            }
        }
        return text as String
    }

    /// Mojave's and Catalina's rc.install call this native hook before Language Chooser, so Apple's script stays as it is.
    public static func hasSerialHook(_ rcInstall: String?) -> Bool {
        (rcInstall as NSString?)?.components(separatedBy: "\t/etc/rc.cdrom.local\n").count == 2
    }

    public static let serialHookScript =
        "#!/bin/sh\nexec \(serialAgentCommand) >> /var/log/virtualintelmac-recovery.log 2>&1\n"

    /// Retail and model-specific discs have different eligibility scripts. Change only the native installation-check hook,
    /// not a hardcoded model list or arbitrary JavaScript, and start Rosetta selected when the disc includes it. Nil when
    /// this is not an installation plan.
    public static func openingInstallationPlan(_ text: String?, selectingRosetta: Bool) -> String? {
        guard let text,
            let plan = try? XMLDocument(xmlString: text, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]),
            let root = plan.rootElement(), root.name == "installer-gui-script"
        else { return nil }
        for check in root.elements(forName: "installation-check") {
            check.attribute(forName: "script")?.stringValue = "true"
        }
        if selectingRosetta {
            for choice in root.elements(forName: "choice")
            where choice.attribute(forName: "id")?.stringValue == "Rosetta" {
                if let selected = choice.attribute(forName: "start_selected") {
                    selected.stringValue = "true"
                } else if let selected = XMLNode.attribute(withName: "start_selected", stringValue: "true") as? XMLNode
                {
                    choice.addAttribute(selected)
                }
            }
        }
        return plan.xmlString
    }

    /// pkgutil's output locale is fixed by the runner. A valid third-party Developer ID is not an Apple OS installer.
    public static func isSignedAppleSoftware(_ checkSignatureOutput: String?) -> Bool {
        guard let output = checkSignatureOutput as NSString? else { return false }
        return output.components(separatedBy: .newlines).contains {
            $0.trimmingCharacters(in: .whitespaces) == "Status: signed Apple Software"
        }
    }

    /// The installer's signing is only replaced when dropping nothing but securityd credential stashing, which an existing
    /// encrypted installation would need and our authorization (a new empty HFS target only) does not. Unknown entitlements
    /// fail closed rather than being silently stripped.
    public static func acceptsAutomaticInstaller(entitlements: Any?) -> Bool {
        guard let entitlements else { return true }
        guard let dictionary = entitlements as? [String: Any], dictionary.count <= 1 else { return false }
        return dictionary.isEmpty || plistEqual(dictionary["com.apple.private.securityd.stash"], true)
    }
}

/// `-isEqual:` on a property list value: `<true/>` and 1 are the same NSNumber, and anything else is not a match.
func plistEqual(_ value: Any?, _ expected: NSNumber) -> Bool {
    (value as? NSNumber)?.isEqual(expected) == true
}

/// A requirement on the finished image, checked after reopening it read-only: a successful conversion or the expected length
/// is not proof of usable media.
public enum MediaRequirement: Equatable, Sendable {
    case regularFile(String)
    case anyRegularFile([String])
    case nonemptyFile(String)
    case text(String, contains: String)

    func isSatisfied(at mount: URL) -> Bool {
        switch self {
        case .regularFile(let path): mount.appending(path: path).isRegularFile
        case .anyRegularFile(let paths): paths.contains { mount.appending(path: $0).isRegularFile }
        case .nonemptyFile(let path): mount.appending(path: path).isNonemptyFile
        case .text(let path, let expected):
            (try? String(contentsOf: mount.appending(path: path), encoding: .utf8))?.contains(expected) == true
        }
    }
}

extension Guest {
    /// What a finished recovery image must hold. A hybrid image has its own checks.
    public var mediaRequirements: [MediaRequirement] {
        var requirements: [MediaRequirement] = [.regularFile("System/Library/CoreServices/boot.efi")]
        switch mediaLayout {
        case .installerImages: requirements += [.regularFile("InstallInfo.plist"), .regularFile("InstallESD.dmg")]
        case .restoreDisc, .flatPackages:
            requirements.append(
                .anyRegularFile([
                    packages + "/OSInstall.mpkg/Contents/Info.plist", packages + "/OSInstall.mpkg"
                ]))
        case .completeApplication, .hybridImage: break
        }
        if self == .tiger {
            requirements.append(.regularFile("Applications/Utilities/Installer.app/Contents/MacOS/Installer"))
        }
        if let installer = recoveryInstallerPath { requirements.append(.regularFile(String(installer.dropFirst()))) }
        if let installer = automaticInstallerPath { requirements.append(.regularFile(String(installer.dropFirst()))) }
        if recoveryAutomation.usesNativeInstaller {
            requirements += [.regularFile("BaseSystem.dmg"), .regularFile("BaseSystem.chunklist")]
        }
        if recoveryAutomation == .serialAgent {
            requirements += [
                .nonemptyFile("usr/libexec/guest-recovery-agent"),
                .text("private/etc/rc.cdrom.local", contains: serialAgentCommand)
            ]
        }
        if self == .highSierra { requirements.append(.text("etc/rc.install", contains: highSierraLaunch)) }
        return requirements
    }
}

extension URL {
    /// A regular file itself, not a symlink to one.
    var isRegularFile: Bool {
        isFileURL && (try? resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    var isNonemptyFile: Bool {
        isRegularFile && ((try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
    }
}
