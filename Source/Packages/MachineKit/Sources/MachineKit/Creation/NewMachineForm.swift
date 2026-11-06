import Foundation
import InstallerKit

/// What stops a setup step, as its alert words it.
public struct CreationIssue: Error, Equatable, Sendable {
    public let title: String
    public let detail: String

    public init(title: String = "Your Mac couldn’t be set up", detail: String) {
        self.title = title
        self.detail = detail
    }
}

/// What this host can give a guest.
public struct HostCapacity: Equatable, Sendable {
    public var physicalMemoryBytes: UInt64
    public var processorCount: Int

    public init(physicalMemoryBytes: UInt64, processorCount: Int) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.processorCount = processorCount
    }

    public static var current: HostCapacity {
        HostCapacity(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            processorCount: ProcessInfo.processInfo.processorCount)
    }

    public var maximumCores: Int { min(64, processorCount) }
    /// Leaves a gibibyte for the host.
    public var maximumMemoryGiB: Int { max(1, min(64, Int(physicalMemoryBytes >> 30) - 1)) }
}

/// The values the configuration page starts from for a guest.
public struct NewMachineDefaults: Equatable, Sendable {
    public let name: String
    public let cores: Int
    public let memoryGiB: Int
    public let diskGiB: Int

    /// `volumeBytes` and `freeBytes` describe the library's volume, nil if it can't be read.
    public init(guest: Guest, host: HostCapacity, volumeBytes: UInt64?, freeBytes: UInt64?) {
        name = guest.name
        cores = min(4, host.maximumCores)
        memoryGiB = min(4, host.maximumMemoryGiB)
        // The disk is sparse, so a big, roomy volume gets 128 GB of headroom.
        diskGiB = (volumeBytes ?? 0) >= 256 << 30 && (freeBytes ?? 0) >= 96 << 30 ? 128 : 64
    }

    /// Whether the configuration page starts over for `guest`. `pageGuest` is the guest it was last filled in for, nil
    /// when nothing on it needs keeping. Going Back and Continuing to the same guest keeps what the user typed, and a
    /// saved job's guest was filled in from the job.
    public static func pageStartsOver(pageGuest: Guest?, jobGuest: Guest?, guest: Guest) -> Bool {
        guest != pageGuest && guest != jobGuest
    }

    /// The name to show after switching to `guest`. A name the user typed stays; an empty or generated one follows the
    /// guest. "macOS Mojave" and its siblings are what older versions generated.
    public static func name(_ current: String, afterSwitchingTo guest: Guest) -> String {
        let generated = Guest.allCases.map(\.name) + ["macOS Mojave", "macOS Catalina", "macOS Big Sur"]
        return current.isEmpty || generated.contains(current) ? guest.name : current
    }
}

/// A machine's name and numbers, checked.
public struct NewMachineSpecification: Equatable, Sendable {
    public let name: String
    public let cores: Int
    public let memoryGiB: Int
    public let diskGiB: Int
}

/// The configuration page's fields as typed, or as `--create-guest` gave them.
public struct NewMachineForm: Equatable, Sendable {
    public static let diskRangeGiB = 40...2048

    public var name: String
    public var cores: String
    public var memory: String
    public var disk: String

    public init(name: String, cores: String, memory: String, disk: String) {
        self.name = name
        self.cores = cores
        self.memory = memory
        self.disk = disk
    }

    /// `NSScanner`'s reading of a whole number, which allows a sign and surrounding whitespace.
    static func wholeNumber(_ text: String, in range: ClosedRange<Int>) -> Int? {
        let scanner = Scanner(string: text)
        guard let value = scanner.scanInt(), scanner.isAtEnd, range.contains(value) else { return nil }
        return value
    }

    /// The first problem, in the order the page reads them, or the machine they describe.
    public func validated(for host: HostCapacity) throws(CreationIssue) -> NewMachineSpecification {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = name.isEmpty ? "this virtual Mac" : name
        guard let cores = Self.wholeNumber(cores, in: 1...host.maximumCores) else {
            throw CreationIssue(
                title: "Enter a valid number of cores",
                detail: "You can assign between 1 and \(host.maximumCores) cores to \(recipient).")
        }
        guard let memory = Self.wholeNumber(memory, in: 1...host.maximumMemoryGiB) else {
            throw CreationIssue(
                title: "Enter a valid amount of memory",
                detail: "You can assign between 1 and \(host.maximumMemoryGiB) GB of memory to \(recipient). Leave "
                    + "memory available for macOS and graphics processing.")
        }
        guard let disk = Self.wholeNumber(disk, in: Self.diskRangeGiB) else {
            throw CreationIssue(
                title: "Enter a valid storage size",
                detail: "You can assign between 40 and 2048 GB of storage to \(recipient).")
        }
        guard !name.isEmpty else {
            throw CreationIssue(
                title: "Enter a name for your Mac",
                detail: "Give this virtual Mac a name so you can find it in your library.")
        }
        guard UInt64(memory) << 30 < host.physicalMemoryBytes else {
            throw CreationIssue(
                detail: "Leave memory available for this Mac. Allocating all of your host’s memory can make both "
                    + "Macs unresponsive. Choose a smaller amount.")
        }
        return NewMachineSpecification(name: name, cores: cores, memoryGiB: memory, diskGiB: disk)
    }
}
