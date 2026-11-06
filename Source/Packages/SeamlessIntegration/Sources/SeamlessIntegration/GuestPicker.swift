import Foundation

/// Decides which guest should run an old app or installer from what its binary and `Info.plist` say. A pure function so
/// the rules can be read and tested without a machine.
public enum GuestPicker {
    public struct Guest: Hashable, Sendable {
        public var name: String
        /// Marketing version, such as `10.9.5`.
        public var version: String
        /// Whether this guest has Rosetta, which is optional on Snow Leopard.
        public var hasRosetta: Bool

        public init(name: String, version: String, hasRosetta: Bool = false) {
            self.name = name
            self.version = version
            self.hasRosetta = hasRosetta
        }
    }

    public struct App: Hashable, Sendable {
        public var architectures: Set<String>
        public var minimumSystemVersion: String?

        public init(architectures: Set<String>, minimumSystemVersion: String? = nil) {
            self.architectures = architectures
            self.minimumSystemVersion = minimumSystemVersion
        }
    }

    /// Newest first among guests that can run it: a newer guest has newer TLS and fonts, and the oldest is kept for what
    /// nothing newer will run. Empty means no guest here can run it.
    public static func candidates(for app: App, among guests: [Guest]) -> [Guest] {
        guests.filter { canRun(app, on: $0) }
            .sorted { compare($0.version, $1.version) == .orderedDescending }
    }

    public static func canRun(_ app: App, on guest: Guest) -> Bool {
        if let minimum = app.minimumSystemVersion, compare(guest.version, minimum) == .orderedAscending { return false }
        let version = guest.version
        // Catalina dropped i386. Rosetta was removed at Lion and absent before 10.4.4's Intel builds.
        let hasNative =
            (app.architectures.contains("x86_64") && compare(version, "10.5") != .orderedAscending)
            || (app.architectures.contains("i386") && compare(version, "10.15") == .orderedAscending)
        if hasNative { return true }
        let isPowerPC = app.architectures.contains("ppc") || app.architectures.contains("ppc7400")
        return isPowerPC && guest.hasRosetta && compare(version, "10.7") == .orderedAscending
    }

    static func compare(_ left: String, _ right: String) -> ComparisonResult {
        left.compare(right, options: .numeric)
    }
}

/// The CPU types in a Mach-O file, thin or fat.
public enum MachOArchitectures {
    public static func read(_ file: URL) throws -> Set<String> {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4096) ?? Data()
        func word(_ offset: Int, big: Bool) -> UInt32? {
            guard data.count >= offset + 4 else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return big ? value.bigEndian : value.littleEndian
        }
        guard let magic = word(0, big: true) else { return [] }
        switch magic {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            let width = magic == 0xCAFE_BABE ? 20 : 32
            let count = Int(word(4, big: true) ?? 0)
            // Java class files share this magic, and have a large "count". No real fat file has many slices.
            guard count <= 16 else { return [] }
            return Set((0..<count).compactMap { word(8 + $0 * width, big: true).flatMap(name) })
        case 0xFEED_FACE, 0xFEED_FACF: return Set([word(4, big: true).flatMap(name)].compactMap { $0 })
        case 0xCEFA_EDFE, 0xCFFA_EDFE: return Set([word(4, big: false).flatMap(name)].compactMap { $0 })
        default: return []
        }
    }

    private static func name(_ cpuType: UInt32) -> String? {
        switch cpuType {
        case 7: "i386"
        case 0x0100_0007: "x86_64"
        case 18: "ppc"
        case 0x0100_0012: "ppc64"
        case 0x0100_000C: "arm64"
        default: nil
        }
    }
}
