import Foundation

/// Runs one disk tool to completion on a worker thread: no shell and no output pipes, so a child with a lot to say can't
/// deadlock its parent, and its output stays in the job's log. It's stopped on a timeout or a cancellation, and while it
/// runs, progress comes from what it reports or from how long it should take.
struct ToolRun {
    var executable: String
    var arguments: [String]
    var workingDirectory: String?
    var timeout: TimeInterval
    /// Cleanup finishes even after a cancellation.
    var isCleanup = false
    var reportsPercent = false
    var log: URL
    /// The share of the whole job this run covers.
    var begin = 0.0
    var end = 0.0
    var estimate: TimeInterval = 1
    var timingKey: String?
    var defaults = UserDefaults.standard
    var isCancelled: () -> Bool = { false }
    var completedWork: (Double) -> Void = { _ in }
    var timeRemaining: (TimeInterval) -> Void = { _ in }
    var terminationGrace: TimeInterval = 2

    func run() throws {
        let descriptor = open(log.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AssemblyFailure.cannotCreateLog.error }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        let start = ProcessInfo.processInfo.systemUptime
        let learned = timingKey.map { defaults.double(forKey: $0) } ?? 0
        let expected = learned > 0 ? learned : max(1, estimate)
        let reader = reportsPercent ? try? FileHandle(forReadingFrom: log) : nil
        var pending = Data()
        var toolFraction = -1.0
        var lastUpdate: TimeInterval = 0
        var interrupted = false
        while ended.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if end > begin && elapsed - lastUpdate >= 0.5 {
                lastUpdate = elapsed
                if let reader { toolFraction = readProgress(reader, pending: &pending, after: toolFraction) }
                let fraction = ToolProgress.fraction(reported: toolFraction, elapsed: elapsed, estimate: expected)
                completedWork(begin + (end - begin) * fraction)
                timeRemaining(
                    ToolProgress.secondsRemaining(reported: toolFraction, elapsed: elapsed, estimate: expected)
                        + (1 - end) * 240)
            }
            if (isCancelled() && !isCleanup) || ProcessInfo.processInfo.systemUptime - start > timeout {
                interrupted = true
                process.terminate()
                if ended.wait(timeout: .now() + terminationGrace) == .timedOut {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                }
                break
            }
        }
        try? reader?.close()
        try? output.close()
        if interrupted { throw AssemblyFailure.timedOutOrCancelled.error }
        guard process.terminationStatus == 0 else {
            throw AssemblyFailure.toolFailed(status: process.terminationStatus, log: log.path)
        }
        if end > begin {
            if let timingKey {
                let measured = ProcessInfo.processInfo.systemUptime - start
                defaults.set(ToolProgress.learnedDuration(previous: learned, measured: measured), forKey: timingKey)
            }
            completedWork(end)
        }
    }

    /// Reads what's new in the log and takes the percentages from its complete lines.
    private func readProgress(_ reader: FileHandle, pending: inout Data, after previous: Double) -> Double {
        pending.append(reader.readData(ofLength: 65536))
        guard let lines = String(data: pending, encoding: .utf8),
            let newline = lines.range(of: "\n", options: .backwards)
        else { return previous }
        let complete = String(lines[..<newline.upperBound])
        pending.removeFirst(complete.utf8.count)
        return ToolProgress.reportedFraction(in: complete, after: previous)
    }
}

@objc(VIMToolRun)
public final class ToolRunBridge: NSObject {
    @objc(runInvocation:log:begin:end:estimate:timingKey:isCancelled:completedWork:timeRemaining:error:)
    public class func run(
        invocation: ToolInvocationBridge, log: URL, begin: Double, end: Double, estimate: TimeInterval,
        timingKey: String,
        isCancelled: @escaping () -> Bool, completedWork: @escaping (Double) -> Void,
        timeRemaining: @escaping (TimeInterval) -> Void
    ) throws {
        try ToolRun(
            executable: invocation.path, arguments: invocation.launchArguments,
            workingDirectory: invocation.workingDirectory, timeout: invocation.timeout, isCleanup: invocation.isCleanup,
            reportsPercent: invocation.reportsPercent, log: log, begin: begin, end: end, estimate: estimate,
            timingKey: timingKey, isCancelled: isCancelled, completedWork: completedWork, timeRemaining: timeRemaining
        ).run()
    }
}
