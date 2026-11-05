import Foundation

/// A process's outcome in the guest, in the dictionary GuestControl's bridge reports it as. Output is untrusted: it comes
/// from the guest, a key may be missing, and a value may be of any type.
public struct GuestCommandResult: Sendable {
    public var values: [String: PropertyListValue]

    public init(values: [String: PropertyListValue]) {
        self.values = values
    }

    /// An empty result, which succeeds at nothing, if the object isn't a dictionary.
    public init(foundationObject: Any?) {
        values = (foundationObject as? [String: Any])?.mapValues(PropertyListValue.init(foundationObject:)) ?? [:]
    }

    /// Exit status zero, with no `signal` key at all, whatever its value.
    public var succeeded: Bool {
        values["exitcode"].isEqual(0) && values["signal"] == nil
    }

    private func data(_ key: String) -> Data? {
        if case .data(let data)? = values[key] { data } else { nil }
    }

    public var standardOutput: Data { data("stdout") ?? Data() }
    public var standardError: Data { data("stderr") ?? Data() }

    /// Standard error as text, or nil when there's none or it isn't UTF-8.
    public var diagnostic: String? {
        Self.text(standardError).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Foundation's UTF-8 decoding, which is what the journal has always held.
    static func text(_ data: Data) -> String? {
        NSString(data: data, encoding: String.Encoding.utf8.rawValue) as String?
    }

    /// The JSON object a successful guest tool printed, as Foundation parsed it, so a journal can save it verbatim.
    public var jsonObject: [String: Any]? {
        guard succeeded else { return nil }
        return (try? JSONSerialization.jsonObject(with: standardOutput)) as? [String: Any]
    }

    public var json: [String: PropertyListValue]? {
        jsonObject?.mapValues(PropertyListValue.init(foundationObject:))
    }

    /// The property list a successful guest tool printed, or nil if it isn't a dictionary.
    var propertyList: [String: PropertyListValue]? {
        guard succeeded,
            let object = try? PropertyListSerialization.propertyList(from: standardOutput, format: nil),
            let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary.mapValues(PropertyListValue.init(foundationObject:))
    }
}

extension String {
    /// `NSRegularExpression`'s `$` also matches before a final newline, so one trailing newline passes. These values
    /// only become arguments to the guest's own `diskutil`, with no shell involved.
    func matchesWholly(_ pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.numberOfMatches(in: self, range: NSRange(location: 0, length: utf16.count)) == 1
    }
}
