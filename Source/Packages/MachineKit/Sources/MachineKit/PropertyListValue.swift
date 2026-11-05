import Foundation

/// One value from a machine's property lists or a guest report, in the form Foundation gave it.
///
/// Numbers stay `NSNumber` and equality is Objective-C `isEqual:`, as in GuestControl's `JSONValue`. The checks ported
/// here depend on it: `true`, `1` and `1.0` compare equal, strings compare literally, and an integer stays an integer
/// when written back.
public enum PropertyListValue: Sendable {
    /// JSON's null in a guest report, or an object no property list can hold. It's kept rather than dropped because a
    /// present value that isn't `true` refuses a check that a missing one passes.
    case null
    case number(NSNumber)
    case string(String)
    case date(Date)
    case data(Data)
    case array([PropertyListValue])
    case dictionary([String: PropertyListValue])

    public init(foundationObject: Any) {
        switch foundationObject {
        case let number as NSNumber: self = .number(number)
        case let string as String: self = .string(string)
        case let date as Date: self = .date(date)
        case let data as Data: self = .data(data)
        case let array as [Any]: self = .array(array.map(PropertyListValue.init(foundationObject:)))
        case let dictionary as [String: Any]:
            self = .dictionary(dictionary.mapValues(PropertyListValue.init(foundationObject:)))
        default: self = .null
        }
    }

    public var foundationObject: NSObject {
        switch self {
        case .null: NSNull()
        case .number(let number): number
        case .string(let string): string as NSString
        case .date(let date): date as NSDate
        case .data(let data): data as NSData
        case .array(let values): values.map(\.foundationObject) as NSArray
        case .dictionary(let values): values.mapValues(\.foundationObject) as NSDictionary
        }
    }

    public var number: NSNumber? {
        if case .number(let number) = self { number } else { nil }
    }

    public var string: String? {
        if case .string(let string) = self { string } else { nil }
    }

    public var array: [PropertyListValue]? {
        if case .array(let array) = self { array } else { nil }
    }

    public var dictionary: [String: PropertyListValue]? {
        if case .dictionary(let dictionary) = self { dictionary } else { nil }
    }
}

extension PropertyListValue: Equatable {
    public static func == (lhs: PropertyListValue, rhs: PropertyListValue) -> Bool {
        lhs.foundationObject.isEqual(rhs.foundationObject)
    }
}

extension PropertyListValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(value as NSNumber) }
    public init(booleanLiteral value: Bool) { self = .number(value as NSNumber) }
    public init(arrayLiteral elements: PropertyListValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, PropertyListValue)...) {
        self = .dictionary(Dictionary(elements) { $1 })
    }
}

extension PropertyListValue: Codable {
    // shortcut: a decoder can't tell `<real>4</real>` from `<integer>4</integer>`, so Codable reads it as an integer.
    // `MachineConfiguration(propertyList:)` keeps it exact; use that for files.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // A property list has no null: this is the literal string "$null", the encoder's sentinel.
        if container.decodeNil() {
            self = .string("$null")
        } else if let value = try? container.decode(Bool.self) {
            self = .number(value as NSNumber)
        } else if let value = try? container.decode(Int64.self) {
            self = .number(value as NSNumber)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value as NSNumber)
        } else if let value = try? container.decode(Date.self) {
            self = .date(value)
        } else if let value = try? container.decode(Data.self) {
            self = .data(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PropertyListValue].self) {
            self = .array(value)
        } else {
            self = .dictionary(try container.decode([String: PropertyListValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .number(let number):
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                try container.encode(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                try container.encode(number.doubleValue)
            } else {
                try container.encode(number.int64Value)
            }
        case .string(let string): try container.encode(string)
        case .date(let date): try container.encode(date)
        case .data(let data): try container.encode(data)
        case .array(let values): try container.encode(values)
        case .dictionary(let values): try container.encode(values)
        }
    }
}

/// The Objective-C checks' nil messaging. `[nil isEqual:nil]` is NO, so two missing values never count as matching
/// evidence. Compare with `isEqual`, never `==`, which calls two nil optionals equal.
extension PropertyListValue? {
    func isEqual(_ other: PropertyListValue?) -> Bool {
        guard let self, let other else { return false }
        return self == other
    }

    subscript(key: String) -> PropertyListValue? { self?.dictionary?[key] }

    var isTrue: Bool { isEqual(true) }
    var isFalse: Bool { isEqual(false) }
    var isDictionary: Bool { self?.dictionary != nil }

    var nonEmptyString: String? {
        guard let string = self?.string, !string.isEmpty else { return nil }
        return string
    }

    /// A string `NSUUID` would accept.
    var isUUID: Bool { self?.string.flatMap(UUID.init(uuidString:)) != nil }

    /// `-[id boolValue]` for what a report can hold. Anything else was a crash in Objective-C and is false here.
    var boolValue: Bool {
        switch self {
        case .number(let number): number.boolValue
        case .string(let string): (string as NSString).boolValue
        default: false
        }
    }
}
