import Foundation

extension String {
    /// `-[NSString hasPrefix:]`: code units, unnormalized. Swift's `hasPrefix` would treat two normalizations as one and
    /// then cut at the wrong offset, and so does an `as NSString` cast, which bridges back to the same implementation.
    func hasLiteralPrefix(_ prefix: String) -> Bool {
        utf16.starts(with: prefix.utf16)
    }
}

/// The old-to-new path map of one layout migration, as its journal saves it. Paths compare literally.
struct LibraryMoves: Sendable {
    var destinations: [String: String] = [:]

    /// Deepest first, so nested Preparation moves before its old Downloads parent. Ties sort for a repeatable order.
    var physicalOrder: [String] {
        destinations.keys.sorted { a, b in
            let (aLength, bLength) = (a.utf16.count, b.utf16.count)
            return aLength == bLength ? (a as NSString).compare(b) == .orderedAscending : aLength > bLength
        }
    }

    /// A path after the moves, by its longest moved ancestor. A sibling that merely shares a prefix doesn't count.
    func relocated(_ path: String) -> String {
        let best = destinations.keys
            .filter { path.utf16.elementsEqual($0.utf16) || path.hasLiteralPrefix($0 + "/") }
            .max { $0.utf16.count < $1.utf16.count }
        guard let best, let new = destinations[best] else { return path }
        return new + (path as NSString).substring(from: best.utf16.count)
    }

    /// Paths anywhere in a saved property list, in keys as well as values. Everything else stays as it is.
    func relocated(_ value: PropertyListValue) -> PropertyListValue {
        switch value {
        case .string(let string): .string(relocated(string))
        case .array(let array): .array(array.map(relocated))
        case .dictionary(let dictionary):
            .dictionary(
                Dictionary(dictionary.map { (relocated($0.key), relocated($0.value)) }) { $1 })
        default: value
        }
    }
}
