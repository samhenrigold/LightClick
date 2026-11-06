import Foundation
import Testing

@testable import GuestControl

struct TabletCalibrationTests {
    private func value(_ value: Any, axis: String = "x", trim: Int) -> Int64? {
        let event: [String: Any] = ["type": "abs", "data": ["axis": axis, "value": value]]
        let mapped = TabletCalibration.events(from: [event], trim: trim)[0]
        return ((mapped["data"] as? [String: Any])?["value"] as? NSNumber)?.int64Value
    }

    @Test func noTrimLeavesPositionsAlone() {
        #expect(value(1000, trim: 0) == 1000)
    }

    @Test func aTrimSplitsBetweenBothEnds() {
        #expect(value(0, trim: 15) == 2457)
        #expect(value(32767, trim: 15) == 30310)
        #expect(value(16384, axis: "y", trim: 15) == 16384)
    }

    @Test func onlyPositionsInRangeMove() {
        #expect(value(-1, trim: 15) == -1)
        #expect(value(32768, trim: 15) == 32768)
        #expect(value("5", trim: 15) == nil)
        #expect(value(5, axis: "z", trim: 15) == 5)
        let key: [String: Any] = ["type": "key", "data": ["axis": "x", "value": 5]]
        let data = TabletCalibration.events(from: [key], trim: 15)[0]["data"] as? [String: Any]
        #expect(data?["value"] as? Int == 5)
    }

    @Test func otherFieldsSurvive() {
        let event: [String: Any] = ["type": "abs", "data": ["axis": "x", "value": 0, "extra": "kept"]]
        let data = TabletCalibration.events(from: [event], trim: 15)[0]["data"] as? [String: Any]
        #expect(data?["extra"] as? String == "kept")
    }
}
