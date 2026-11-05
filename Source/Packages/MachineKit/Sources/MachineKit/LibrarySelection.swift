import Foundation

/// Which library this instance uses, and the one thing allowed to write that choice to preferences.
///
/// Preferences are shared when `CFFIXED_USER_HOME` redirects Application Support, so saving a default library's path
/// pins every other instance to it. The key is private to this file and `.standard` has no path, which means there's
/// no way to save a default: asking to select the standard root removes the preference instead.
public enum LibrarySelection: Equatable, Sendable {
    case standard
    case chosen(ChosenLibrary)

    /// A library the user picked: never the standard root it was compared with when it was made.
    public struct ChosenLibrary: Equatable, Sendable {
        public let path: String

        fileprivate init(path: String) {
            self.path = path
        }
    }

    private static let preferenceKey = "VIMLibraryPath"

    /// `root` and `standardRoot` must already be library roots, from `LibraryLayout.root(forLibrary:)`.
    public init(root: URL, standardRoot: URL) {
        self = root.path == standardRoot.path ? .standard : .chosen(ChosenLibrary(path: root.path))
    }

    /// Replaces the saved choice. The saved value is what `configuredLibrary(in:)` reads back.
    public func save(to preferences: UserDefaults) {
        switch self {
        case .standard: preferences.removeObject(forKey: Self.preferenceKey)
        case .chosen(let library): preferences.set(library.path, forKey: Self.preferenceKey)
        }
    }

    /// The saved library, or nil if nothing usable is saved. `~` counts as absolute, as it does for
    /// `-[NSString isAbsolutePath]`. This can be a reserved `Machines` child, as old preferences stored it.
    static func configuredLibrary(in preferences: UserDefaults) -> URL? {
        guard let configured = preferences.string(forKey: preferenceKey), AbsolutePath(rawValue: configured) != nil
        else { return nil }
        return URL(fileURLWithPath: configured, isDirectory: true)
    }

    /// The migration's sweep of `VIM…` preferences must leave this one alone: only `save(to:)` writes it.
    static func isPreferenceKey(_ key: String) -> Bool {
        key == preferenceKey
    }
}
