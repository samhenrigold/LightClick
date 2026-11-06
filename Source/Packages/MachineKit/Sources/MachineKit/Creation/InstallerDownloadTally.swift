import CryptoKit
import Foundation
import InstallerKit

/// A download's speed: an exponential average over samples at least half a second apart.
public struct TransferRate: Equatable, Sendable {
    public private(set) var bytesPerSecond = 0.0
    private var sampleTime: TimeInterval = 0
    private var sampleBytes: Int64 = 0

    public init() {}

    /// A drop in `received` means the transfer restarted, so the average does too.
    public mutating func record(received: Int64, at time: TimeInterval) {
        if sampleTime == 0 || received < sampleBytes {
            sampleTime = time
            sampleBytes = received
            bytesPerSecond = 0
        } else if time - sampleTime >= 0.5 {
            let rate = Double(received - sampleBytes) / (time - sampleTime)
            bytesPerSecond = bytesPerSecond > 0 ? 0.7 * bytesPerSecond + 0.3 * rate : rate
            sampleTime = time
            sampleBytes = received
        }
    }
}

/// One monotonic bar over a whole setup: downloads take it to 70%, preparation the rest.
public struct SetupProgress: Equatable, Sendable {
    public static let downloadShare = 0.70

    public private(set) var fraction: Double

    public init(fraction: Double = 0) {
        self.fraction = fraction
    }

    public mutating func advance(to value: Double) {
        fraction = max(fraction, min(1, max(0, value)))
    }

    public mutating func advance(toPreparation work: Double) {
        advance(to: Self.downloadShare + (1 - Self.downloadShare) * work)
    }

    /// Whether `saved` is stale enough to rewrite. Byte updates shouldn't hammer preferences.
    public func needsSaving(over saved: Double?) -> Bool {
        abs((saved ?? 0) - fraction) >= 0.005
    }
}

/// What a guest's installer files have transferred so far, and how to say it.
public struct InstallerDownloadTally: Sendable {
    public let files: [InstallerFile]
    public private(set) var fileIndex = 0
    public private(set) var rate = TransferRate()
    private var lengths: [String: Int64] = [:]
    private var received: [String: Int64] = [:]

    public init(files: [InstallerFile]) {
        self.files = files
    }

    public var currentFile: InstallerFile? { fileIndex < files.count ? files[fileIndex] : nil }

    public mutating func setLength(_ length: Int64, of source: URL) {
        lengths[source.absoluteString] = length
    }

    public mutating func restartRate() {
        rate = TransferRate()
    }

    /// A progress update for `source`. `total` is -1 when the server gives no size.
    public mutating func record(received count: Int64, total: Int64, of source: URL, at time: TimeInterval) {
        received[source.absoluteString] = count
        if total > 0 { lengths[source.absoluteString] = total }
        rate.record(received: count, at: time)
    }

    /// Records a finished file, whose `size` on disk is the truth if it can be read, and moves to the next.
    public mutating func finishCurrentFile(size: Int64?) {
        if let size, let source = currentFile?.url.absoluteString {
            received[source] = size
            lengths[source] = size
        }
        fileIndex += 1
    }

    /// The bar's position. Fixed role weights stop each part of a legacy Apple download restarting at zero.
    public func overallFraction(ofCurrentFile fraction: Double) -> Double {
        var total = 0.0
        var completed = 0.0
        for (index, file) in files.enumerated() {
            let weight = Self.weight(of: file.role)
            total += weight
            if index < fileIndex {
                completed += weight
            } else if index == fileIndex {
                completed += weight * fraction
            }
        }
        return total > 0 ? SetupProgress.downloadShare * completed / total : 0
    }

    /// "1.20 GB of 6.40 GB (64.00 MB/s) - 2 minutes remaining"
    public var detail: String {
        var receivedTotal: Int64 = 0
        var lengthTotal: Int64 = 0
        var known = !files.isEmpty
        for file in files {
            let key = file.url.absoluteString
            receivedTotal += received[key] ?? 0
            let length = lengths[key] ?? 0
            if length <= 0 { known = false } else { lengthTotal += length }
        }
        let amount =
            known
            ? String(format: "%.2f GB of %.2f GB", Double(receivedTotal) / 1e9, Double(lengthTotal) / 1e9)
            : String(format: "%.2f GB downloaded", Double(receivedTotal) / 1e9)
        let speed =
            rate.bytesPerSecond > 0
            ? String(format: " (%.2f MB/s)", rate.bytesPerSecond / 1e6) : " (Calculating speed…)"
        var remaining = "Estimating time remaining…"
        if known, rate.bytesPerSecond > 0, lengthTotal > receivedTotal {
            remaining = Self.remainingText(seconds: Double(lengthTotal - receivedTotal) / rate.bytesPerSecond)
        }
        if known, receivedTotal >= lengthTotal { remaining = "Download complete" }
        return "\(amount)\(speed) - \(remaining)"
    }

    private static func weight(of role: InstallerFile.Role) -> Double {
        switch role {
        case .assistant: 0.03
        case .recovery: 0.1
        case .esd: 0.87
        case .diskImage: 1
        }
    }

    private static func remainingText(seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        guard minutes >= 60 else { return "\(plural(minutes, "minute")) remaining" }
        let hours = plural(minutes / 60, "hour")
        return minutes % 60 == 0 ? "\(hours) remaining" : "\(hours) \(plural(minutes % 60, "minute")) remaining"
    }

    fileprivate static func plural(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}

extension SetupCopy {
    /// The preparation tools' own estimate.
    public static func preparationRemaining(seconds: TimeInterval) -> String {
        "About \(InstallerDownloadTally.plural(max(1, Int((seconds / 60).rounded(.up))), "minute")) remaining"
    }
}

extension LibraryLayout {
    /// The persistent transfer directory for one installer URL.
    public static func downloadDirectory(for source: URL, library: URL) -> URL {
        let digest = SHA256.hash(data: Data(source.absoluteString.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return downloads(forLibrary: library).appendingPathComponent(key)
    }
}

/// What can be known of an installer file's size without transferring it.
public enum InstallerLength {
    /// The length a transfer directory's journal recorded for `source`, if it's that transfer and a real size.
    public static func recorded(inDirectory directory: URL, source: URL) -> Int64? {
        let journal = NSDictionary(contentsOf: directory.appendingPathComponent("Download.plist"))
        guard let journal, journal["SourceURL"] as? String == source.absoluteString,
            let length = (journal["Length"] as? NSNumber)?.int64Value, length > 0
        else { return nil }
        return length
    }

    /// A HEAD response's length, if it's plausibly the installer's.
    public static func probed(statusCode: Int, expectedContentLength: Int64) -> Int64? {
        statusCode == 200 && expectedContentLength > 0 && expectedContentLength <= 100 << 30
            ? expectedContentLength : nil
    }
}
