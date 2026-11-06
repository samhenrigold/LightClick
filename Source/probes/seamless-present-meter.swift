// What a window really has on the display: reads that one window from WindowServer as fast as it can, by its ID, never the screen,
// and counts how many reads differ. It can only see as many frames as it gets reads, so it prints both.
//
//     seamless-present-meter WINDOW_ID SECONDS [--times]
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3, let id = CGWindowID(arguments[1]), let seconds = Double(arguments[2]) else {
    print("usage: seamless-present-meter WINDOW_ID SECONDS [--times]")
    exit(64)
}
_ = NSApplication.shared  // For the window server connection.
var reads = 0, distinct = 0
var last: UInt64 = 0
var times: [Double] = []
let started = Date()
while Date().timeIntervalSince(started) < seconds {
    guard
        let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]),
        let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data)
    else { continue }
    reads += 1
    var hash: UInt64 = 14_695_981_039_346_656_037
    for y in stride(from: 0, to: image.height, by: 4) {
        let words = UnsafeRawPointer(base + y * image.bytesPerRow).assumingMemoryBound(to: UInt64.self)
        for x in 0..<(image.bytesPerRow / 8) { hash = (hash ^ words[x]) &* 1_099_511_628_211 }
    }
    if hash != last {
        distinct += 1
        times.append(Date().timeIntervalSince1970)
    }
    last = hash
}
let spent = Date().timeIntervalSince(started)
print(String(format: "presented %.1f distinct/s, from %.1f reads/s, over %.0f s", Double(distinct) / spent, Double(reads) / spent, spent))
if arguments.contains("--times") {
    print("times " + times.map { String(format: "%.4f", $0) }.joined(separator: " "))
}
