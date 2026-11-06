import Foundation
import InstallerKit

/// The assistant's sentences that depend on what's being set up.
public enum SetupCopy {
    /// "macOS Mojave"
    public static func systemTitle(_ guest: Guest) -> String {
        "\(guest.family.rawValue) \(guest.name)"
    }

    public static func progressTitle(_ guest: Guest, usingExistingInstaller existing: Bool) -> String {
        "\(existing ? "Preparing" : "Downloading")\n\(systemTitle(guest))"
    }

    public static func progressIntro(_ job: CreationJob) -> String {
        let family = job.guest.family.rawValue
        let restoreDVD = job.guest.traits.contains(.restoreDVD)
        let preparation =
            if job.sourceInstaller != nil {
                "We’ll prepare your \(family) installer."
            } else if restoreDVD {
                "We’ll download Mac OS X \(job.guest.name) from the Internet Archive and prepare its installer."
            } else {
                "We’ll download \(family) from Apple and prepare its installer."
            }
        let instructions =
            if job.automaticSetup?.isEnabled == true {
                "Your virtual Mac will install and set itself up automatically."
            } else if restoreDVD {
                "When the installer opens, follow the onscreen instructions and install on Macintosh HD."
            } else {
                "When \(family) Utilities appears, choose Reinstall \(family) and install on Macintosh HD."
            }
        return "\(preparation) \(instructions) Installation may take up to 2 hours."
    }

    public static func downloading(_ guest: Guest) -> String {
        "Downloading \(guest.family.rawValue)…"
    }

    public static func archiveFailureTitle(_ guest: Guest) -> String {
        "Unable to Download Mac OS X \(guest.name) from the Internet Archive"
    }

    public static func archiveFailureDetail(_ guest: Guest, filename: String) -> String {
        "Installing Mac OS X \(guest.name) requires downloading the installer from the Internet Archive, which is not "
            + "available in your region. Download \(filename) using a connection where the Internet Archive is "
            + "available, then choose Use Existing Installer.\n\nYou can also install Mac OS X Lion 10.7 or later "
            + "instead, which are directly downloaded from Apple and does not require access to the Internet Archive."
    }

    /// A preparation failure, with the tool's recovery suggestion if it gave one.
    public static func preparationFailure(description: String?, recoverySuggestion: String?) -> CreationIssue {
        CreationIssue(
            title: "The installer couldn’t be prepared",
            detail: "\(description ?? "Preparation could not finish.")\n\n"
                + (recoverySuggestion ?? "Your downloads are saved. Try again to resume setup."))
    }
}
