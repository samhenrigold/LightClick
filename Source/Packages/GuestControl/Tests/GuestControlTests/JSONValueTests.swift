import Foundation
import Testing

@testable import GuestControl

struct JSONValueTests {
    private func parse(_ text: String) throws -> JSONValue {
        try #require(JSONValue(foundationObject: JSONSerialization.jsonObject(with: Data(text.utf8))))
    }

    /// The checks ported from Objective-C rely on `isEqual:` and on booleans being numbers.
    @Test func numbersCompareAsNSNumberDoes() throws {
        let parsed = try parse(#"{"one":1,"float":1.0,"yes":true,"no":false,"text":"1"}"#)
        #expect(parsed["one"] == parsed["float"])
        #expect(parsed["one"] == parsed["yes"])
        #expect(parsed["no"] == 0)
        #expect(parsed["one"] != parsed["text"])
        #expect(parsed["yes"]?.isBoolean == true)
        #expect(parsed["one"]?.isBoolean == false)
    }

    @Test func foundationRoundTripsKeepBooleansAndNull() throws {
        let parsed = try parse(#"{"flag":true,"nothing":null,"list":[1,"a"]}"#)
        let written = try JSONSerialization.data(withJSONObject: parsed.foundationObject)
        let reparsed = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(reparsed["flag"] as? NSNumber == kCFBooleanTrue)
        #expect(reparsed["nothing"] is NSNull)
        #expect((reparsed["list"] as? [Any])?.count == 2)
    }

    @Test func anythingJSONCannotRepresentIsRefused() {
        #expect(JSONValue(foundationObject: Data()) == nil)
        #expect(JSONValue(foundationObject: ["key": Date()]) == nil)
    }
}
