import CoreFoundation
import Foundation

/// A Sendable JSON document that keeps `JSONSerialization`'s exact number semantics.
///
/// Booleans stay `kCFBoolean` numbers rather than a separate case because the protocol checks ported from Objective-C
/// depend on `NSNumber` behavior: `isKindOfClass:NSNumber` accepts `true`, and `@YES` is equal to `@1`.
public enum JSONValue: Sendable {
    case null
    case number(NSNumber)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Returns nil for anything `JSONSerialization` couldn't have produced or written.
    public init?(foundationObject: Any) {
        switch foundationObject {
        case is NSNull: self = .null
        case let number as NSNumber: self = .number(number)
        case let string as String: self = .string(string)
        case let array as [Any]:
            var values: [JSONValue] = []
            for element in array {
                guard let value = JSONValue(foundationObject: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: JSONValue] = [:]
            for (key, element) in dictionary {
                guard let value = JSONValue(foundationObject: element) else { return nil }
                values[key] = value
            }
            self = .object(values)
        default: return nil
        }
    }

    public var foundationObject: NSObject {
        switch self {
        case .null: NSNull()
        case .number(let number): number
        case .string(let string): string as NSString
        case .array(let values): values.map(\.foundationObject) as NSArray
        case .object(let values): values.mapValues(\.foundationObject) as NSDictionary
        }
    }

    public var number: NSNumber? {
        if case .number(let number) = self { number } else { nil }
    }

    public var string: String? {
        if case .string(let string) = self { string } else { nil }
    }

    public var object: [String: JSONValue]? {
        if case .object(let object) = self { object } else { nil }
    }

    public subscript(key: String) -> JSONValue? { object?[key] }

    var isBoolean: Bool {
        guard case .number(let number) = self else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

extension JSONValue: Equatable {
    /// Objective-C `isEqual:`, so `1`, `1.0` and `true` compare equal as they did in the checks this replaces.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        lhs.foundationObject.isEqual(rhs.foundationObject)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(value as NSNumber) }
    public init(booleanLiteral value: Bool) { self = .number(value as NSNumber) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements) { $1 })
    }
}
