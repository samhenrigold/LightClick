// What a window really puts on the display: frames ScreenCaptureKit gets of that one window, and how many differ. One window by
// its ID, never the screen. Prints when each change came, for timing input against.
//
//     seamless-present-meter WINDOW_ID SECONDS [--times]
import AVFoundation
import AppKit
import CoreMedia
@preconcurrency import ScreenCaptureKit

final class Meter: NSObject, SCStreamOutput, @unchecked Sendable {
    var complete = 0, distinct = 0
    var last: UInt64 = 0
    var times: [Double] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)), status == .complete,
            let pixels = CMSampleBufferGetImageBuffer(sample)
        else { return }
        complete += 1
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        var hash: UInt64 = 14_695_981_039_346_656_037
        let row = CVPixelBufferGetBytesPerRow(pixels)
        for y in stride(from: 0, to: CVPixelBufferGetHeight(pixels), by: 8) {
            let words = (base + y * row).assumingMemoryBound(to: UInt64.self)
            for x in 0..<(row / 8) { hash = (hash ^ words[x]) &* 1_099_511_628_211 }
        }
        if hash != last {
            distinct += 1
            times.append(CACurrentMediaTimeLike())
        }
        last = hash
    }
}

func CACurrentMediaTimeLike() -> Double { Date().timeIntervalSince1970 }

let arguments = CommandLine.arguments
guard arguments.count >= 3, let id = CGWindowID(arguments[1]), let seconds = Double(arguments[2]) else {
    print("usage: seamless-present-meter WINDOW_ID SECONDS [--times]")
    exit(64)
}
let meter = Meter()
_ = NSApplication.shared  // ScreenCaptureKit needs a window server connection.
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            print("# ERROR no window \(id)")
            exit(1)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width) * 2
        configuration.height = Int(window.frame.height) * 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.queueDepth = 8
        configuration.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(meter, type: .screen, sampleHandlerQueue: DispatchQueue(label: "meter"))
        try await stream.startCapture()
        let started = Date()
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        let spent = Date().timeIntervalSince(started)
        print(String(format: "presented %.1f/s, %.1f distinct, over %.0f s", Double(meter.complete) / spent, Double(meter.distinct) / spent, spent))
        if arguments.contains("--times") {
            print("times " + meter.times.map { String(format: "%.4f", $0) }.joined(separator: " "))
        }
        exit(0)
    } catch {
        print("# ERROR \(error)")
        exit(1)
    }
}
RunLoop.main.run()
