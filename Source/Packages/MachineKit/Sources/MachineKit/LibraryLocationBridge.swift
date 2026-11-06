// The Objective-C face of LibraryLocation, with VIMLibraryLocation's name and selectors. The panel and icon methods stay
// in VIMLibraryLocation.m as a category, because they present through the app's alerts. The URL parameters are optional
// because a nil here returned nil there, and would trap if bridged to a non-optional URL.

import AppKit
import Foundation

@objc(VIMLibraryLocation)
public final class LibraryLocationBridge: NSObject {
    private static var location: LibraryLocation {
        LibraryLocation(standardLibrary: defaultURL, preferences: .standard)
    }

    @objc public class var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Light Click", isDirectory: true)
    }

    @objc public class var rootURL: URL { location.root }
    /// The selected library root, never its Machines child.
    @objc public class var currentURL: URL { location.root }
    @objc public class var machinesURL: URL { location.machines }
    @objc public class var downloadsURL: URL { location.downloads }
    @objc public class var installersURL: URL { location.installers }

    /// Accepts the selected root, or the reserved Machines child from older jobs.
    @objc(rootURLForLibrary:)
    public class func rootURL(forLibrary library: URL?) -> URL? {
        library.map(LibraryLayout.root(forLibrary:))
    }

    @objc(machinesURLForLibrary:)
    public class func machinesURL(forLibrary library: URL?) -> URL? {
        library.map(LibraryLayout.machines(forLibrary:))
    }

    @objc(downloadsURLForMachines:)
    public class func downloadsURL(forMachines machines: URL?) -> URL? {
        machines.map(LibraryLayout.downloads(forLibrary:))
    }

    @objc(installersURLForMachines:)
    public class func installersURL(forMachines machines: URL?) -> URL? {
        machines.map(LibraryLayout.installers(forLibrary:))
    }

    @objc(prepareLayout:)
    public class func prepareLayout() throws {
        let location = location
        try location.createStandardFolders()
        clearLegacyFolderIcon()
        post(try location.organizeSelectedLibrary())
    }

    @objc(setURL:error:)
    public class func setURL(_ url: URL?) throws {
        post(try location.select(url))
        try prepareLayout()
    }

    /// Undoes only the custom icon an older app installed. Libraries now have their normal Finder icon.
    private class func clearLegacyFolderIcon() {
        let version = "VIMDefaultFolderIcon-v1"
        guard Thread.isMainThread, UserDefaults.standard.bool(forKey: version) else { return }
        let cleared = MainActor.assumeIsolated {
            NSWorkspace.shared.setIcon(nil, forFile: defaultURL.path, options: [])
        }
        if cleared { UserDefaults.standard.removeObject(forKey: version) }
    }

    private class func post(_ relocations: [MachineRelocation]) {
        for relocation in relocations {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Notification.Name("VIMMachineRelocated"), object: nil,
                    userInfo: ["OldURL": relocation.oldURL, "URL": relocation.url, "Identifier": relocation.identifier])
            }
        }
    }
}
