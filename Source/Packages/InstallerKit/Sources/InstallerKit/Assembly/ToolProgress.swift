import Foundation

/// How a running tool's progress is read and estimated. Tool output is authoritative. Otherwise a measured duration stands
/// in, slowing near the end instead of claiming completion prematurely.
public enum ToolProgress {
    /// The defaults key for a step's learned duration. Stage text is part of it, so rewording a stage forgets its timing.
    public static func timingKey(guest: String, stage: String, invocation: ToolInvocation) -> String {
        let tool = (invocation.tool.rawValue as NSString).lastPathComponent
        return "VIMPreparationDuration-\(guest)-\(stage)-\(tool)-\(invocation.arguments.first ?? "(null)")"
    }

    /// The highest fraction reported by whole lines of `-puppetstrings` output. Below zero means none yet: hdiutil can
    /// report an indeterminate -1.
    public static func reportedFraction(in lines: String, after previous: Double) -> Double {
        (lines as NSString).components(separatedBy: "\n").reduce(previous) { highest, line in
            guard line.hasPrefix("PERCENT:") else { return highest }
            return max(highest, min(1, (String(line.dropFirst(8)) as NSString).doubleValue / 100))
        }
    }

    /// How far through this step it is.
    public static func fraction(reported: Double, elapsed: TimeInterval, estimate: TimeInterval) -> Double {
        if reported >= 0 { return min(0.99, reported) }
        let measured =
            elapsed < estimate * 0.9
            ? elapsed / estimate : 0.9 + 0.08 * (1 - exp(-(elapsed - estimate * 0.9) / estimate))
        return min(0.98, measured)
    }

    /// The seconds this step still needs.
    public static func secondsRemaining(reported: Double, elapsed: TimeInterval, estimate: TimeInterval) -> TimeInterval
    {
        reported > 0.01 && elapsed > 1
            ? elapsed * (1 - min(0.999, reported)) / reported : max(1, estimate - elapsed)
    }

    /// The duration to remember after a successful run.
    public static func learnedDuration(previous: TimeInterval, measured: TimeInterval) -> TimeInterval {
        previous > 0 ? 0.6 * previous + 0.4 * measured : measured
    }
}

extension AssemblyFailure {
    /// A tool exited nonzero. The log stays in the job for diagnostics.
    public static func toolFailed(status: Int32, log: String) -> NSError {
        NSError(
            domain: "VirtualIntelMac.InstallerAssembly", code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: "The OS installer couldn’t be prepared.",
                NSLocalizedRecoverySuggestionErrorKey:
                    "Your downloads are saved. Try again to resume setup. If it fails again, check that your library’s "
                    + "drive is connected and has enough free space.",
                "PreparationLog": log
            ])
    }
}

@objc(VIMToolProgress)
public final class ToolProgressBridge: NSObject {
    @objc(timingKeyForGuest:stage:invocation:)
    public class func timingKey(guest: String?, stage: String?, invocation: ToolInvocationBridge) -> String {
        ToolProgress.timingKey(guest: guest ?? "", stage: stage ?? "", invocation: invocation.value)
    }

    @objc(reportedFractionInLines:after:)
    public class func reportedFraction(in lines: String?, after previous: Double) -> Double {
        lines.map { ToolProgress.reportedFraction(in: $0, after: previous) } ?? previous
    }

    @objc(fractionWithReported:elapsed:estimate:)
    public class func fraction(reported: Double, elapsed: TimeInterval, estimate: TimeInterval) -> Double {
        ToolProgress.fraction(reported: reported, elapsed: elapsed, estimate: estimate)
    }

    @objc(secondsRemainingWithReported:elapsed:estimate:)
    public class func secondsRemaining(reported: Double, elapsed: TimeInterval, estimate: TimeInterval) -> TimeInterval
    {
        ToolProgress.secondsRemaining(reported: reported, elapsed: elapsed, estimate: estimate)
    }

    @objc(learnedDurationAfter:measured:)
    public class func learnedDuration(previous: TimeInterval, measured: TimeInterval) -> TimeInterval {
        ToolProgress.learnedDuration(previous: previous, measured: measured)
    }

    @objc(toolFailureWithStatus:log:)
    public class func toolFailure(status: Int32, log: String) -> NSError {
        AssemblyFailure.toolFailed(status: status, log: log)
    }
}
