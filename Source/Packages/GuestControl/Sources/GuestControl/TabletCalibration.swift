import Foundation

/// Maps absolute pointer positions into the part of the tablet's range an old guest uses.
@objc(VIMTabletCalibration)
public final class TabletCalibration: NSObject {
    private static let maximum: Int64 = 32767

    /// `events` with each X and Y position moved inward. IOHIDEventDriver splits its removal percentage, `trim`, between
    /// both ends of the range. Other events, and positions outside the range, pass through untouched.
    @objc(eventsFrom:trim:)
    public class func events(from events: [[String: Any]], trim: Int) -> [[String: Any]] {
        guard trim > 0 else { return events }
        let inset = maximum * Int64(trim) / 200
        let span = maximum - 2 * inset
        return events.map { event in
            guard event["type"] as? String == "abs", var data = event["data"] as? [String: Any],
                let axis = data["axis"] as? String, axis == "x" || axis == "y",
                let value = (data["value"] as? NSNumber)?.int64Value, (0...maximum).contains(value)
            else { return event }
            data["value"] = inset + (value * span + maximum / 2) / maximum
            return ["type": "abs", "data": data]
        }
    }
}
