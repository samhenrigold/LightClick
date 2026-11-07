import AppKit
import Darwin

struct OwnerWindowCaptureRequest: Sendable {
    let guestID: Int
    let nonce: String

    init?(command: String) {
        let parts = command.split(whereSeparator: \.isWhitespace)
        guard parts.count == 3, parts[0] == "owner-capture-report", let guestID = Int(parts[1]),
              guestID > 0, guestID <= Int(UInt32.max), UUID(uuidString: String(parts[2])) != nil else { return nil }
        self.guestID = guestID
        nonce = String(parts[2])
    }
}

/// A one-shot, metadata-only proof. Captures only the NSWindow resolved by the proxy's own guest-ID dictionary.
struct OwnerWindowCaptureReport: Codable, Sendable {
    let guestID: Int
    let nonce: String
    let proxyPID: Int32
    let hostWindowID: Int
    let preflightAvailable: Bool
    let preflightAllowed: Bool?
    var readCount = 0
    var width = 0
    var height = 0
    var failureCategory: String
}

@MainActor
enum OwnerWindowCapture {
    private typealias Capture = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?
    private typealias Connection = @convention(c) () -> Int32
    private typealias Preflight = @convention(c) () -> Bool

    private struct Pending {
        let token: UUID
        weak var window: NSWindow?
        let report: OwnerWindowCaptureReport
        let completion: @MainActor (OwnerWindowCaptureReport) -> Void
    }

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
    // A timed-out private C call cannot be cancelled. Keep its slot until it actually returns.
    private static var inFlight: UUID?
    private static var pending: Pending?

    static func capture(window: NSWindow?, guestID: Int, nonce: String,
                        completion: @escaping @MainActor (OwnerWindowCaptureReport) -> Void) {
        let preflight = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGPreflightScreenCaptureAccess")
            .map { unsafeBitCast($0, to: Preflight.self) }
        let number = window?.windowNumber ?? 0
        var report = OwnerWindowCaptureReport(guestID: guestID, nonce: nonce,
                                              proxyPID: ProcessInfo.processInfo.processIdentifier,
                                              hostWindowID: number, preflightAvailable: preflight != nil,
                                              preflightAllowed: preflight?(), failureCategory: "none")
        guard guestID > 0, guestID <= Int(UInt32.max), let window else {
            report.failureCategory = "guestWindowMissing"
            completion(report)
            return
        }
        guard number > 0, number <= Int(UInt32.max) else {
            report.failureCategory = "invalidWindowID"
            completion(report)
            return
        }
        guard inFlight == nil else {
            report.failureCategory = "captureAlreadyRunning"
            completion(report)
            return
        }
        guard let skyLight,
              let captureSymbol = dlsym(skyLight, "SLSHWCaptureWindowList"),
              let connectionSymbol = dlsym(skyLight, "SLSMainConnectionID") else {
            report.failureCategory = "symbolUnavailable"
            completion(report)
            return
        }
        let capture = unsafeBitCast(captureSymbol, to: Capture.self)
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        let token = UUID()
        inFlight = token
        pending = Pending(token: token, window: window, report: report, completion: completion)
        let base = report
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            var timedOut = base
            timedOut.failureCategory = "captureTimedOut"
            deliver(token: token, report: timedOut)
        }
        DispatchQueue.global(qos: .utility).async {
            var result = base
            var target = UInt32(number)
            if let images = capture(connection, &target, 1, 1 | (1 << 11))?.takeRetainedValue(),
               let image = (images as? [CGImage])?.first, image.width > 0, image.height > 0 {
                result.readCount = 1
                result.width = image.width
                result.height = image.height
            } else {
                result.failureCategory = "noImages"
            }
            let finished = result
            DispatchQueue.main.async {
                if inFlight == token { inFlight = nil }
                deliver(token: token, report: finished)
            }
        }
    }

    private static func deliver(token: UUID, report: OwnerWindowCaptureReport) {
        guard let waiting = pending, waiting.token == token else { return }
        pending = nil // Late completion cannot overwrite a timeout or a newer request's artifact.
        var result = report
        if waiting.window?.windowNumber != waiting.report.hostWindowID {
            result.failureCategory = "windowChanged"
            result.readCount = 0
            result.width = 0
            result.height = 0
        }
        waiting.completion(result)
    }
}
