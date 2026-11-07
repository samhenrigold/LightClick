// What a window really has on the display: reads that one window from WindowServer as fast as it can, by its ID, never the screen,
// and counts how many reads differ. It can only see as many frames as it gets reads, so it prints both.
//
//     seamless-present-meter WINDOW_ID SECONDS [--clicks FILE] [--save PNG]
//
// --save keeps the last read. It works with the Mac's display asleep, when screencapture can't.
//
// With --clicks, FILE holds the time of each input, one a line, and it also prints how long each took to change the window.
import AppKit
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count >= 3, let id = CGWindowID(arguments[1]), let seconds = Double(arguments[2]) else {
    print("usage: seamless-present-meter WINDOW_ID SECONDS [--clicks FILE] [--save PNG]")
    exit(64)
}
_ = NSApplication.shared  // For the window server connection.
// CGWindowListCreateImage manages one read a second on this macOS, and ScreenCaptureKit delivered nothing for a window.
typealias Read = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
let connection = unsafeBitCast(dlsym(skyLight, "SLSMainConnectionID"), to: (@convention(c) () -> Int32).self)()
let read = unsafeBitCast(dlsym(skyLight, "SLSHWCaptureWindowList"), to: Read.self)
var window = id
var lastImage: CGImage?
var reads = 0, distinct = 0
var last: UInt64 = 0
var times: [Double] = []
let started = Date()
while Date().timeIntervalSince(started) < seconds {
    guard
        let images = read(connection, &window, 1, 1 | 1 << 11)?.takeRetainedValue() as? [CGImage], let image = images.first,
        let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data)
    else { continue }
    reads += 1
    lastImage = image
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
if let flag = arguments.firstIndex(of: "--save"), let lastImage,
    let file = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: arguments[flag + 1]) as CFURL, "public.png" as CFString, 1, nil)
{
    CGImageDestinationAddImage(file, lastImage, nil)
    CGImageDestinationFinalize(file)
}
if let flag = arguments.firstIndex(of: "--clicks"), let text = try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8) {
    let clicks = text.split(separator: "\n").compactMap { Double($0) }
    let delays = clicks.compactMap { click in times.first { $0 > click }.map { ($0 - click) * 1000 } }.filter { $0 < 900 }.sorted()
    if let worst = delays.last {
        print(String(format: "input to window change: median %.0f ms, worst %.0f ms, %d of %d", delays[delays.count / 2], worst, delays.count, clicks.count))
    } else {
        print("input to window change: none of \(clicks.count) inputs changed it")
    }
}
