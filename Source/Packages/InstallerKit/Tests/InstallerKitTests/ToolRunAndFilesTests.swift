import Foundation
import Testing

@testable import InstallerKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct ToolRunTests {
    private func run(_ script: String, in directory: URL, configure: (inout ToolRun) -> Void = { _ in }) throws
        -> ToolRun
    {
        var tool = ToolRun(
            executable: "/bin/sh", arguments: ["-c", script], timeout: 30,
            log: directory.appendingPathComponent("tool.log"))
        configure(&tool)
        return tool
    }

    private func log(_ directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("tool.log"), encoding: .utf8)
    }

    @Test func outputGoesToTheLogInTheCLocale() throws {
        let directory = try temporaryDirectory()
        try run("echo out; echo err >&2; echo $LC_ALL", in: directory).run()
        #expect(try log(directory) == "out\nerr\nC\n")
    }

    @Test func aNonzeroExitReportsItsStatus() throws {
        let directory = try temporaryDirectory()
        #expect {
            try run("exit 3", in: directory).run()
        } throws: { error in
            (error as NSError).code == 3
        }
    }

    @Test func aLogThatExistsIsRefused() throws {
        let directory = try temporaryDirectory()
        try Data().write(to: directory.appendingPathComponent("tool.log"))
        #expect {
            try run("exit 0", in: directory).run()
        } throws: { error in
            (error as NSError).localizedDescription == AssemblyFailure.cannotCreateLog.error.localizedDescription
        }
    }

    @Test func aTimeoutStopsIt() throws {
        let directory = try temporaryDirectory()
        let started = Date()
        #expect {
            try run("sleep 30", in: directory) { $0.timeout = 0.2 }.run()
        } throws: { error in
            (error as NSError).localizedDescription == AssemblyFailure.timedOutOrCancelled.error.localizedDescription
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aChildThatIgnoresTerminationIsKilled() throws {
        let directory = try temporaryDirectory()
        let started = Date()
        #expect(throws: (any Error).self) {
            try run("trap '' TERM; while :; do sleep 1; done", in: directory) {
                $0.timeout = 0.2
                $0.terminationGrace = 0.2
            }.run()
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aCancellationStopsAllButCleanup() throws {
        let directory = try temporaryDirectory()
        #expect(throws: (any Error).self) {
            try run("sleep 30", in: directory) { $0.isCancelled = { true } }.run()
        }
        let cleanup = try temporaryDirectory()
        try run("sleep 0.3", in: cleanup) {
            $0.isCancelled = { true }
            $0.isCleanup = true
        }.run()
    }

    @Test func aFinishedRunCompletesItsWorkAndLearnsItsDuration() throws {
        let directory = try temporaryDirectory()
        let suite = "ToolRunTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        nonisolated(unsafe) var work: [Double] = []
        try run("sleep 0.8", in: directory) {
            $0.begin = 0.2
            $0.end = 0.6
            $0.timingKey = "key"
            $0.defaults = defaults
            $0.completedWork = { work.append($0) }
        }.run()
        #expect(work.last == 0.6)
        #expect(work.allSatisfy { $0 >= 0.2 && $0 <= 0.6 })
        #expect(defaults.double(forKey: "key") > 0)
    }

    @Test func percentagesInTheLogDriveProgress() throws {
        let directory = try temporaryDirectory()
        nonisolated(unsafe) var work: [Double] = []
        try run("echo 'PERCENT:50.0'; sleep 1.2", in: directory) {
            $0.begin = 0
            $0.end = 1
            $0.reportsPercent = true
            $0.estimate = 1000
            $0.completedWork = { work.append($0) }
        }.run()
        #expect(work.contains { abs($0 - 0.5) < 0.01 })
    }
}

@Suite struct InstallerFilesTests {
    @Test func flushingReturnsTheSizeOfAPlainFile() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("out.dmg")
        try Data("abc".utf8).write(to: file)
        #expect(try InstallerFiles.flushGeneratedImage(file) == 3)
    }

    @Test func flushingRefusesWhatIsntAPlainGeneratedFile() throws {
        let directory = try temporaryDirectory()
        let empty = directory.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(throws: (any Error).self) { try InstallerFiles.flushGeneratedImage(empty) }
        #expect(throws: (any Error).self) {
            try InstallerFiles.flushGeneratedImage(directory.appendingPathComponent("missing"))
        }
        let file = directory.appendingPathComponent("file")
        try Data("a".utf8).write(to: file)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try InstallerFiles.flushGeneratedImage(link) }
        try FileManager.default.linkItem(at: file, to: directory.appendingPathComponent("hard"))
        #expect(throws: (any Error).self) { try InstallerFiles.flushGeneratedImage(file) }
    }

    @Test func rewritingARestrictedFileKeepsItsModeAndInode() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("script")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        try InstallerFiles.rewriteGeneratedFile(file, bytes: Data("new".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o444)
        #expect(attributes[.systemFileNumber] as? NSNumber == inode)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
    }

    @Test func noBytesLeavesTheFileAndItsMode() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("script")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) { try InstallerFiles.rewriteGeneratedFile(file, bytes: nil) }
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber == 0o444)
        #expect(try Data(contentsOf: file) == Data("old".utf8))
    }

    @Test func aDownloadOutsideTheOwnedLayoutIsNeverRemoved() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("Chosen.dmg")
        try Data("x".utf8).write(to: file)
        try Data().write(to: directory.appendingPathComponent("Download.lock"))
        InstallerFiles.retireCompletedDownloads([file])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func nothingRetainedInAnEmptyOrMissingFolder() throws {
        let directory = try temporaryDirectory()
        #expect(InstallerFiles.retainedInstaller(in: directory, guest: "mojave").isEmpty)
        #expect(InstallerFiles.retainedInstaller(in: directory.appendingPathComponent("no"), guest: "mojave").isEmpty)
    }

    @Test func foldersThatArentAttemptsAreIgnored() throws {
        let directory = try temporaryDirectory()
        let attempt = directory.appendingPathComponent("not-a-uuid/Media")
        try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: attempt.appendingPathComponent("Media.plist"))
        #expect(InstallerFiles.retainedInstaller(in: directory, guest: "mojave").isEmpty)
    }
}
