import Foundation
import Testing

@testable import MachineKit

/// A private home and preference domain per test, so nothing reaches the real library or the real app's preferences.
/// The home isn't in the system's temporary folder, whose `/private` alias is a separate case with its own test.
final class LibraryFixture {
    let home: URL
    let suite = "machinekit-tests-\(UUID().uuidString)"
    let preferences: UserDefaults

    init() throws {
        home = Fixture.sourceRoot.appending(path: "Build/machinekit-tests/\(UUID().uuidString)")
        preferences = try #require(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }

    /// An instance with its own home and these shared preferences.
    func location(home name: String = "Support") -> LibraryLocation {
        LibraryLocation(
            standardLibrary: home.appending(path: name).appending(path: "Light Click"), preferences: preferences)
    }

    func folder(_ path: String) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An idle package with a State folder and a Machine.plist.
    @discardableResult
    func machine(_ path: String, plist: [String: Any] = [:], identifier: String = UUID().uuidString) throws -> URL {
        let package = try folder(path)
        try FileManager.default.createDirectory(
            at: package.appending(path: "State"), withIntermediateDirectories: true)
        var contents = plist
        contents["Identifier"] = identifier
        try write(contents, to: package.appending(path: "Machine.plist"))
        return package
    }

    func write(_ plist: Any, to url: URL, format: PropertyListSerialization.PropertyListFormat = .binary) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: url)
    }

    func migration(root: URL, previous: URL? = nil) -> LibraryMigration {
        LibraryMigration(root: root, previousRoot: previous ?? root, preferences: preferences)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Runs `body` while another descriptor, which `flock` treats like another process, holds the lock.
    func holding<Result>(_ lock: URL, _ body: () throws -> Result) throws -> Result {
        var locks = FileLocks()
        let held = locks.acquire(lock)
        #expect(held)
        defer { locks.release() }
        return try body()
    }
}

/// The Objective-C face of a thrown error, which is what the app compares.
func libraryError(_ body: () throws -> Any) -> NSError? {
    do {
        _ = try body()
        return nil
    } catch {
        return error as NSError
    }
}
