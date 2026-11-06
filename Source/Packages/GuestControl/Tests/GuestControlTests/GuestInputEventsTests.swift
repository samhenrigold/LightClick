import Foundation
import Testing

@testable import GuestControl

private let command: UInt = 1 << 20
private let leftCommand: UInt = 0x8
private let rightCommand: UInt = 0x10
private let shift: UInt = 1 << 17
private let leftShift: UInt = 0x2

@MainActor
@Suite struct GuestInputEventsTests {
    @MainActor private final class Recorder {
        var batches: [[[String: Any]]] = []
        lazy var input = GuestInputEvents { [unowned self] in batches.append($0) }

        /// "+a" and "-a" for keys and buttons, "x=5" for positions.
        var summary: [String] {
            batches.joined().map { event in
                let data = event["data"] as? [String: Any] ?? [:]
                let sign = data["down"] as? Bool == true ? "+" : "-"
                switch event["type"] as? String {
                case "key": return sign + ((data["key"] as? [String: Any])?["data"] as? String ?? "?")
                case "btn": return sign + (data["button"] as? String ?? "?")
                default: return "\(data["axis"] ?? "?")=\(data["value"] ?? "?")"
                }
            }
        }
    }

    @Test func aKeyGoesDownAndUpOnce() {
        let recorder = Recorder()
        recorder.input.keyDown(0, repeating: false, modifiers: 0)
        recorder.input.keyDown(0, repeating: false, modifiers: 0)
        recorder.input.keyDown(0, repeating: true, modifiers: 0)
        recorder.input.keyUp(0, modifiers: 0)
        recorder.input.keyUp(0, modifiers: 0)
        #expect(recorder.summary == ["+a", "-a"])
    }

    @Test func keysAreQMPsQcodes() {
        let recorder = Recorder()
        recorder.input.keyDown(36, repeating: false, modifiers: 0)
        recorder.input.keyDown(126, repeating: false, modifiers: 0)
        recorder.input.keyDown(52, repeating: false, modifiers: 0)
        #expect(recorder.summary == ["+ret", "+up"], "A code with no name sends nothing.")
    }

    @Test func aKeysQMPShapeIsExact() throws {
        let recorder = Recorder()
        recorder.input.keyDown(0, repeating: false, modifiers: 0)
        let event = try #require(recorder.batches.first?.first)
        let json = try JSONSerialization.data(withJSONObject: event, options: .sortedKeys)
        #expect(
            String(decoding: json, as: UTF8.self)
                == #"{"data":{"down":true,"key":{"data":"a","type":"qcode"}},"type":"key"}"#)
    }

    /// What actually goes down the control channel, through the same conversion the session's commands take.
    @Test func eventsEncodeForQMPWithRealBooleansAndNumbers() throws {
        let recorder = Recorder()
        recorder.input.keyDown(0, repeating: false, modifiers: 0)
        recorder.input.pointer(x: 1, y: 0)
        let events = Array(recorder.batches.joined())
        let encoded = try #require(JSONValue(foundationObject: ["events": events]))
        let list = try #require(encoded["events"]?.foundationObject as? [[String: Any]])
        #expect(JSONValue(foundationObject: list[0])?["data"]?["down"] == true)
        #expect(JSONValue(foundationObject: list[1])?["data"]?["value"] == 32767)
    }

    @Test func modifiersFollowDeviceFlags() {
        let recorder = Recorder()
        recorder.input.synchronizeModifiers(command | rightCommand)
        #expect(recorder.summary == ["+meta_r"])
        recorder.input.synchronizeModifiers(command | leftCommand)
        #expect(recorder.summary == ["+meta_r", "+meta_l", "-meta_r"])
    }

    @Test func anAggregateFlagAloneKeepsAKnownRightSide() {
        let recorder = Recorder()
        recorder.input.synchronizeModifiers(command | rightCommand)
        recorder.input.synchronizeModifiers(command)
        #expect(recorder.summary == ["+meta_r"])
        recorder.input.synchronizeModifiers(0)
        #expect(recorder.summary == ["+meta_r", "-meta_r"])
    }

    @Test func anAggregateFlagAloneWithNothingHeldPressesLeft() {
        let recorder = Recorder()
        recorder.input.synchronizeModifiers(shift)
        #expect(recorder.summary == ["+shift"])
    }

    @Test func aKeyEquivalentIsAWholePress() {
        let recorder = Recorder()
        recorder.input.keyEquivalent(8, modifiers: command | leftCommand)
        #expect(recorder.summary == ["+meta_l", "+c", "-c"])
    }

    @Test func capsLockIsATapAndLeavesModifiersAlone() {
        let recorder = Recorder()
        recorder.input.flagsChanged(57, modifiers: shift | leftShift)
        #expect(recorder.summary == ["+caps_lock", "-caps_lock"])
    }

    @Test func keyCodeZeroInAFocusNotificationIsNotA() {
        let recorder = Recorder()
        recorder.input.flagsChanged(0, modifiers: 0)
        #expect(recorder.summary.isEmpty)
    }

    @Test func hardwareModifierEventsUseTheirSideBits() {
        let recorder = Recorder()
        recorder.input.flagsChanged(54, modifiers: command | rightCommand)
        recorder.input.flagsChanged(54, modifiers: 0)
        #expect(recorder.summary == ["+meta_r", "-meta_r"])
    }

    @Test func aSyntheticEventWithOnlyTheAggregateTogglesOnceAndAClearedOneIsUp() {
        let recorder = Recorder()
        recorder.input.flagsChanged(60, modifiers: shift)
        #expect(recorder.summary == ["+shift_r"])
        recorder.input.flagsChanged(60, modifiers: 0)
        #expect(recorder.summary == ["+shift_r", "-shift_r"])
        recorder.input.flagsChanged(60, modifiers: 0)
        #expect(recorder.summary.count == 2, "A cleared aggregate never makes up a held modifier.")
    }

    @Test func releasingCommandLetsGoOfTheKeyMacOSSwallowed() {
        let recorder = Recorder()
        recorder.input.keyDown(8, repeating: false, modifiers: command | leftCommand)
        recorder.input.flagsChanged(55, modifiers: 0)
        #expect(recorder.summary == ["+meta_l", "+c", "-meta_l", "-c"])
    }

    @Test func releasingEverythingIsOneRequest() {
        let recorder = Recorder()
        recorder.input.keyDown(0, repeating: false, modifiers: 0)
        recorder.batches = []
        recorder.input.releaseAll()
        #expect(recorder.batches.count == 1)
        #expect(recorder.summary == ["-a", "-left", "-right", "-middle"])
        recorder.batches = []
        recorder.input.keyDown(0, repeating: false, modifiers: 0)
        #expect(recorder.summary == ["+a"], "Nothing is held any more.")
    }

    @Test func pointerPositionsAreClampedToTheTablet() {
        let recorder = Recorder()
        recorder.input.pointer(x: 0.5, y: -1)
        recorder.input.pointer(x: 2, y: 1)
        #expect(recorder.summary == ["x=16383", "y=0", "x=32767", "y=32767"])
    }

    @Test func wheelFractionsAddUp() {
        let recorder = Recorder()
        recorder.input.scroll(x: 0, y: 0.6)
        #expect(recorder.batches.isEmpty)
        recorder.input.scroll(x: 0, y: 0.6)
        #expect(recorder.summary == ["+wheel-up", "-wheel-up"])
        recorder.batches = []
        recorder.input.scroll(x: 0, y: 0.8)
        #expect(recorder.summary == ["+wheel-up", "-wheel-up"], "0.2 was kept.")
    }

    @Test func wheelDirectionsAndBothAxes() {
        let recorder = Recorder()
        recorder.input.scroll(x: 1, y: -1)
        #expect(recorder.summary == ["+wheel-left", "-wheel-left", "+wheel-down", "-wheel-down"])
        recorder.batches = []
        recorder.input.scroll(x: -1, y: 0)
        #expect(recorder.summary == ["+wheel-right", "-wheel-right"])
    }

    @Test func aHugeWheelEventIsBoundedWithNoBacklog() {
        let recorder = Recorder()
        recorder.input.scroll(x: 1000, y: 1000)
        #expect(recorder.summary.count == 64)
        recorder.batches = []
        recorder.input.scroll(x: 0, y: 0)
        #expect(recorder.batches.isEmpty)
    }

    @Test func aResetAndABadValueDropTheRemainderOrNothing() {
        let recorder = Recorder()
        recorder.input.scroll(x: 0, y: 0.9)
        recorder.input.resetWheel()
        recorder.input.scroll(x: 0, y: 0.2)
        #expect(recorder.batches.isEmpty)
        recorder.input.scroll(x: .nan, y: 1)
        recorder.input.scroll(x: 0, y: .infinity)
        #expect(recorder.batches.isEmpty)
        recorder.input.scroll(x: 0, y: 0.8)
        #expect(recorder.summary == ["+wheel-up", "-wheel-up"])
    }
}
