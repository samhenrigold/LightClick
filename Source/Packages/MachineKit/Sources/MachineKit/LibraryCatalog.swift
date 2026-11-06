import Foundation

/// What the library remembers about a package, so that a disconnected Mac still has a row.
public struct LibraryRecord: Equatable, Sendable {
    public var name: String?
    public var guest: String?
    public var identifier: String?

    public init(name: String?, guest: String?, identifier: String? = nil) {
        self.name = name
        self.guest = guest
        self.identifier = identifier
    }

    /// A saved record's keys. A value of the wrong type reads as missing.
    public init(foundationObject: Any?) {
        let values = foundationObject as? [String: Any]
        self.init(
            name: values?["Name"] as? String, guest: values?["Guest"] as? String,
            identifier: values?["Identifier"] as? String)
    }

    public var foundationObject: [String: String] {
        var values: [String: String] = [:]
        values["Name"] = name
        values["Guest"] = guest
        values["Identifier"] = identifier
        return values
    }
}

/// A package that loaded, under the path it's at now: applying a queued rename moves it.
public struct LibraryPackage: Equatable, Sendable {
    public var path: String
    public var record: LibraryRecord

    public init(path: String, record: LibraryRecord) {
        self.path = path
        self.record = record
    }
}

/// A package that didn't load and wasn't simply renamed.
public struct UnavailableLibraryRow: Equatable, Sendable {
    public var path: String
    public var name: String
    public var guest: String
}

/// How one library scan compares with what was known.
public enum LibraryCatalog {
    /// Everything to try loading. Known rows stay while an external library is disconnected.
    public static func candidatePaths(
        known: [String: LibraryRecord], registered: [String], inFolder: [String]
    ) -> Set<String> {
        Set(known.keys).union(registered).union(inFolder)
    }

    public static func isPackage(_ url: URL) -> Bool { url.pathExtension.lowercased() == "vintelmac" }

    /// The rows for `missing` paths, and the catalog to save. A missing path whose identifier turned up elsewhere was
    /// renamed, not lost, and is dropped.
    public static func reconcile(
        loaded: [LibraryPackage], missing: [String], known: [String: LibraryRecord]
    ) -> (unavailable: [UnavailableLibraryRow], catalog: [String: LibraryRecord]) {
        var catalog: [String: LibraryRecord] = [:]
        for package in loaded { catalog[package.path] = package.record }
        let identifiers = Set(loaded.compactMap(\.record.identifier))
        var unavailable: [UnavailableLibraryRow] = []
        for path in missing {
            let record = known[path]
            if let identifier = record?.identifier, identifiers.contains(identifier) { continue }
            let name = record?.name ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let guest = record?.guest ?? ""
            unavailable.append(UnavailableLibraryRow(path: path, name: name, guest: guest))
            catalog[path] = record ?? LibraryRecord(name: name, guest: guest)
        }
        return (unavailable, catalog)
    }
}

/// The library's order: the user's where there is one, by name otherwise.
public enum LibraryOrder {
    /// Rows the user has placed come first, in that order. The rest follow by name.
    public static func sorted<Row>(
        _ rows: [Row], savedOrder: [String], path: (Row) -> String, name: (Row) -> String
    ) -> [Row] {
        var positions: [String: Int] = [:]
        for (index, saved) in savedOrder.enumerated() where positions[saved] == nil { positions[saved] = index }
        return rows.sorted { first, second in
            let x = positions[path(first)] ?? .max
            let y = positions[path(second)] ?? .max
            if x != y { return x < y }
            return name(first).localizedStandardCompare(name(second)) == .orderedAscending
        }
    }

    /// `rows` with `moving` placed just before `before`, or last when it's nil or no longer there.
    public static func moved<Row: Equatable>(_ rows: [Row], moving: Row, before: Row?) -> [Row] {
        var ordered = rows
        ordered.removeAll { $0 == moving }
        let destination = before.flatMap { ordered.firstIndex(of: $0) } ?? ordered.endIndex
        ordered.insert(moving, at: destination)
        return ordered
    }
}

/// A sort chosen from View > Arrange By. Dates and sizes go largest first, and a tie goes by name.
public enum LibraryArrangement: Sendable, Equatable {
    case none, name, type, dateLastOpened, dateCreated, size, tags

    /// A saved name this version doesn't know arranges by name, and nothing saved is no arrangement.
    public init(savedName: String?) {
        switch savedName {
        case nil, "None": self = .none
        case "Type": self = .type
        case "Date Last Opened": self = .dateLastOpened
        case "Date Created": self = .dateCreated
        case "Size": self = .size
        case "Tags": self = .tags
        default: self = .name
        }
    }

    public enum Value: Sendable, Equatable {
        case text(String)
        case date(Date)
        case size(Int64)

        func compare(_ other: Value) -> ComparisonResult {
            switch (self, other) {
            case (.text(let x), .text(let y)): x.localizedStandardCompare(y)
            case (.date(let x), .date(let y)): x.compare(y)
            case (.size(let x), .size(let y)): x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            default: .orderedSame
            }
        }
    }

    private var largestFirst: Bool {
        switch self {
        case .dateLastOpened, .dateCreated, .size: true
        default: false
        }
    }

    public func sorted<Row>(_ rows: [Row], value: (Row) -> Value, name: (Row) -> String) -> [Row] {
        guard self != .none else { return rows }
        let keyed = rows.map { (row: $0, value: value($0), name: name($0)) }
        return keyed.sorted { first, second in
            var order = first.value.compare(second.value)
            if largestFirst && order != .orderedSame {
                order = order == .orderedAscending ? .orderedDescending : .orderedAscending
            }
            if order == .orderedSame { order = first.name.localizedStandardCompare(second.name) }
            return order == .orderedAscending
        }.map(\.row)
    }
}

/// What the library window says about the library as a whole.
public enum LibraryNotice {
    /// Whether the library's folder can't be read. A Machines folder that just hasn't been made yet is an empty library,
    /// in the standard location or beneath a selected root that's there. A selected root that's gone is a disconnected
    /// drive.
    public static func libraryIsUnavailable(
        readFailed: Bool, machinesFolderMissing: Bool, rootExists: Bool, isStandardLibrary: Bool
    ) -> Bool {
        readFailed && !(machinesFolderMissing && (rootExists || isStandardLibrary))
    }

    /// Nil when there's nothing to say. A disconnected library explains its unavailable rows, so it comes first.
    public static func text(libraryUnavailable: Bool, unavailableCount: Int) -> String? {
        if libraryUnavailable { return "Library unavailable. Connect its drive, or choose a library in Settings." }
        switch unavailableCount {
        case 0: return nil
        case 1: return "1 Mac package needs attention. Check its files in Finder."
        default: return "\(unavailableCount) Mac packages need attention. Check their files in Finder."
        }
    }
}

/// What a row says about its Mac.
public enum LibraryRowText {
    /// The asset to show for `guest`. A disconnected or registered package may have no saved or known OS type, and its
    /// recovery row still needs a picture.
    public static func wallpaperName(guest: String, isAvailable: (String) -> Bool) -> String {
        let name = guest + "Wallpaper"
        return isAvailable(name) ? name : "tigerWallpaper"
    }

    /// "4 CPU · 8 GB RAM · 64 GB". `locale` is the user's, outside tests.
    public static func resources(cpuCount: Any?, memoryMiB: Double, diskBytes: UInt64, locale: Locale = .current)
        -> String
    {
        let number = NumberFormatter()
        number.locale = locale
        number.numberStyle = .decimal
        number.maximumFractionDigits = 2
        func text(_ value: Double) -> String { number.string(from: value as NSNumber) ?? "" }
        let storage = diskBytes == 0 ? "Storage unavailable" : "\(text(Double(diskBytes) / Double(1 << 30))) GB"
        return "\(cpuCount ?? "(null)") CPU · \(text(memoryMiB / 1024)) GB RAM · \(storage)"
    }

    /// An OpenGL desktop keeps the SVGA adapter after setup, so its adapter is no evidence that it still needs setup.
    public static func continuesSetup(preMetalGuest: Bool, installState: Any?, requiresInstallerDisplay: Bool) -> Bool {
        guard preMetalGuest else { return requiresInstallerDisplay }
        return !((installState ?? "installed") as AnyObject).isEqual("installed")
    }

    public static func action(unavailable: Bool, running: Bool, continuingSetup: Bool) -> String {
        if unavailable { return "Locate" }
        if running { return "Show" }
        return continuingSetup ? "Continue Setup" : "Start"
    }
}

/// The library window's numbers, in points.
public enum LibraryWindowLayout {
    public static func rowHeight(compact: Bool) -> Double { compact ? 63 : 126 }
    public static func thumbnailWidth(compact: Bool) -> Double { compact ? 101 : 202 }

    /// All rows' height, with room for one when the library is empty.
    public static func rowsHeight(count: Int, compact: Bool) -> Double {
        Double(max(1, count)) * rowHeight(compact: compact)
    }

    /// A small library fits, growth is capped, and a larger one scrolls.
    public static func automaticHeight(rowsHeight: Double, availableHeight: Double) -> Double {
        min(rowsHeight, max(126, min(640, availableHeight * 0.8)))
    }

    /// The width Zoom uses, enough for the longest title.
    public static func standardWidth(titleWidth: Double, compact: Bool, visibleWidth: Double) -> Double {
        min(visibleWidth, min(800, max(540, titleWidth + (compact ? 180 : 290))))
    }
}
