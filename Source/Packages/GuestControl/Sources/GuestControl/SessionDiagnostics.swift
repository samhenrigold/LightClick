// The development diagnostics channel: a client drops Request.json in a private directory and reads Result.json back. It's
// an explicit opt-in on the command line. Everything goes through the session's own control and agent connections, since a
// second QGA client would steal replies and interrupt guest setup.
//
// The commands here need nothing but those connections. Those that touch the window or the display stay with the session.

import Foundation

@MainActor @objc(VIMSessionDiagnostics)
public final class SessionDiagnostics: NSObject {
    typealias Reply = [String: Any]

    private let directory: String
    private let control: any ControlCommands
    private let agent: GuestAgentBridge
    private let statusTool: Data?
    private let memoryMiB: UInt64
    private var audioTraceGeneration = 0

    /// Whether the emulator is still running, for a late automatic stop.
    @objc public var isRunning: () -> Bool = { true }

    public init(
        directory: String, control: any ControlCommands, agent: GuestAgentBridge, statusTool: Data?, memoryMiB: UInt64
    ) {
        self.directory = directory
        self.control = control
        self.agent = agent
        self.statusTool = statusTool
        self.memoryMiB = memoryMiB
    }

    @objc(initWithDirectory:control:agent:statusTool:memoryMiB:)
    public convenience init(
        directory: String, bridge: QMPConnectionBridge, agent: GuestAgentBridge, statusTool: Data?, memoryMiB: UInt64
    ) {
        self.init(directory: directory, control: bridge, agent: agent, statusTool: statusTool, memoryMiB: memoryMiB)
    }

    // MARK: - Where requests come from

    /// The directory this process was told to serve for a machine, or nil. `--guest-diagnostics-root` gives each machine
    /// a directory of its own, and `--guest-diagnostics` names one for the machine the command line selected.
    @objc(directoryForArguments:machinePath:identifier:)
    public class func directory(for arguments: [String], machinePath: String, identifier: String?) -> String? {
        if let option = arguments.firstIndex(of: "--guest-diagnostics-root") {
            guard option + 1 < arguments.count, (arguments[option + 1] as NSString).isAbsolutePath,
                let identifier = identifier.flatMap(UUID.init(uuidString:))
            else { return nil }
            let root = arguments[option + 1]
            let directory = (root as NSString).appendingPathComponent(identifier.uuidString)
            return [root, directory].allSatisfy(isPrivateDirectory(creating:)) ? directory : nil
        }
        let operations = ["--open-vm", "--repair-vm", "--install-vm", "--prepare-vm"]
        guard let target = operations.lazy.compactMap({ arguments.firstIndex(of: $0) }).first,
            target + 1 < arguments.count,
            (arguments[target + 1] as NSString).resolvingSymlinksInPath == machinePath,
            let debug = arguments.firstIndex(of: "--guest-diagnostics"), debug + 1 < arguments.count,
            (arguments[debug + 1] as NSString).isAbsolutePath
        else { return nil }
        return arguments[debug + 1]
    }

    private static func isPrivateDirectory(creating path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
            && info.st_mode & 0o077 == 0
    }

    private func path(_ name: String) -> String { (directory as NSString).appendingPathComponent(name) }

    /// Actions that need no exclusive use of the agent. Framebuffer and emulator reports don't use it at all, and
    /// process-only inspection can share it with a provisioning child. None stages files or changes that transaction.
    static let actionsThatDontNeedTheAgentAlone: Set<String> = [
        "capture", "inspect-hardware", "guest-processes", "guest-process-sample", "installer-log", "cursor-state",
        "network-details", "configuration", "display-state", "display-fingerprint", "display-buffer-count",
        "display-acquire-async", "pointer-workload", "key-workload", "fullscreen", "passthrough-opengl-release-bql",
        "opengl-pirq-f-pic"
    ]

    /// Takes the waiting request, or leaves it for later if it needs the agent and the agent is busy.
    @objc(takeRequestWhileAgentBusy:)
    public func takeRequest(whileAgentBusy agentBusy: Bool) -> [String: Any]? {
        let request = path("Request.json")
        var info = stat()
        guard lstat(request, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_size <= 65536, let data = FileManager.default.contents(atPath: request),
            let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if agentBusy && !Self.actionsThatDontNeedTheAgentAlone.contains(command["Action"] as? String ?? "") {
            return nil
        }
        return rename(request, path("Running.json")) == 0 ? command : nil
    }

    /// Answers the request taken, which frees the directory for the next.
    @objc(writeResult:)
    public func writeResult(_ result: [String: Any]) {
        let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
        try? data?.write(to: URL(fileURLWithPath: path("Result.json")), options: .atomic)
        unlink(path("Running.json"))
    }

    // MARK: - Commands

    /// Runs `command`, which is one of these or else names a guest executable. `finish` then runs once, on main.
    @objc(handleCommand:finish:)
    public func handle(_ command: [String: Any], finish: @escaping ([String: Any]) -> Void) {
        let action = command["Action"] as? String
        switch action {
        case "inspect-hardware": perform(finish) { [self] in try await inspectHardware(command) }
        case "trace-usb": traceUSB(enabled: Self.flag(command["Enabled"]), finish)
        case "trace-audio-gaps": traceAudioGaps(enabled: Self.flag(command["Enabled"]), finish)
        case "trace-sound", "trace-sound-mix":
            let enabled = Self.flag(command["Enabled"])
            perform(finish) { [control] in
                try await control.run(
                    "trace-event-set-state",
                    [
                        "name": action == "trace-sound-mix" ? "audio_sw_write" : "virtio_snd_handle_code",
                        "enable": enabled
                    ])
                return ["Enabled": enabled]
            }
        case "status-probe": statusProbe(finish)
        case "installer-log": installerLog(finish)
        case "open-guest-preferences":
            withAgent(finish) { [agent] in
                agent.openPreferencesPane(command["Pane"]) { failure in
                    finish(failure.map { ["Error": $0.localizedDescription] } ?? ["Opened": true])
                }
            }
        case "guest-processes", "guest-process-sample":
            guestProcesses(action == "guest-process-sample", command, finish)
        case "stage-probe": stageProbe(finish)
        default: runExecutable(command, finish)
        }
    }

    /// `[object boolValue]`: JSON gives a number, and a string answers too.
    private static func flag(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? (value as? NSString)?.boolValue ?? false
    }

    private static func text(_ reply: [String: Any]?, _ key: String) -> String? {
        NSString(data: reply?[key] as? Data ?? Data(), encoding: String.Encoding.utf8.rawValue) as String?
    }

    private static func failure(_ error: Error) -> Reply { ["Error": (error as NSError).localizedDescription] }

    private func perform(_ finish: @escaping (Reply) -> Void, _ work: @escaping @MainActor () async throws -> Reply) {
        Task {
            do {
                finish(try await work())
            } catch {
                finish(Self.failure(error))
            }
        }
    }

    private func withAgent(_ finish: @escaping (Reply) -> Void, _ work: @escaping () -> Void) {
        agent.connect { error in
            if let error {
                finish(Self.failure(error))
            } else {
                work()
            }
        }
    }

    // MARK: - Hardware reports

    private static let reportCommands = [
        "cpu": "query-cpus-fast", "pci": "query-pci", "media": "query-block", "network": "x-query-network",
        "interrupts": "x-query-interrupt-controllers"
    ]
    /// Metadata-only UART registers. Reading RBR/FIFOs, IIR, LSR or MSR would consume data or clear status. These three
    /// are non-destructive even if DLAB is set, when IER aliases the divisor's high byte.
    static let serialPorts = [0x3f9, 0x3fb, 0x3fc, 0x2f9, 0x2fb, 0x2fc]

    /// The monitor command that reads guest memory, or nil if the request is out of bounds.
    static func memoryRead(component: String, address: Any?, words: Any?, memoryMiB: UInt64) -> String? {
        guard let address = address as? NSNumber, let words = words as? NSNumber, words.int64Value >= 1,
            words.uint64Value <= 64
        else { return nil }
        let kernel = component == "kernel-memory"
        let start = address.uint64Value
        let count = words.uint64Value
        let inBounds =
            kernel
            ? start >= 0xffff_ff80_0000_0000 && start <= UInt64.max - count * 8
            : address.int64Value >= 0 && start <= (memoryMiB << 20) &- count * 8
        guard inBounds else { return nil }
        return "\(kernel ? "x" : "xp") /\(count)gx 0x\(String(start, radix: 16))"
    }

    private func monitor(_ commandLine: String) async throws -> Any? {
        try await control.run("human-monitor-command", ["command-line": commandLine])
    }

    /// Whitelisted read-only reports through the production owner. Available before the guest agent or OS boots.
    private func inspectHardware(_ command: [String: Any]) async throws -> Reply {
        let component = command["Component"] as? String ?? ""
        let report: Any?
        switch component {
        case "memory-map": report = try await monitor("info mtree -f")
        case "devices": report = try await monitor("info qtree")
        case "registers": report = try await monitor("info registers -a")
        case "physical-memory", "kernel-memory":
            guard
                let read = Self.memoryRead(
                    component: component, address: command["Address"], words: command["Words"], memoryMiB: memoryMiB)
            else {
                return [
                    "Error": "Choose 1–64 words within this virtual Mac’s RAM or its identified x86 kernel mapping."
                ]
            }
            report = try await monitor(read)
        case "phy", "link-history":
            report = try await control.run(
                "qom-get",
                [
                    "path": "/machine/peripheral/ethernet",
                    "property": component == "phy" ? "x-phy-state" : "x-link-history"
                ])
        case "serial":
            var values: [[String: Any]] = []
            for port in Self.serialPorts {
                let read = try await monitor("i /b 0x\(String(port, radix: 16))")
                values.append(["Port": port, "Report": read ?? ""])
            }
            return ["Registers": values]
        default:
            guard let query = Self.reportCommands[component] else {
                return ["Error": "Choose cpu, pci, network, interrupts, registers, serial, phy, or link-history."]
            }
            report = try await control.run(query)
        }
        return ["Report": report ?? ""]
    }

    // MARK: - Traces

    private func setTraceEvents(_ events: [String], enabled: Bool) async -> Error? {
        var failure: Error?
        for event in events {
            do {
                try await control.run("trace-event-set-state", ["name": event, "enable": enabled])
            } catch {
                failure = failure ?? error
            }
        }
        return failure
    }

    /// Metadata only, and bounded. This never turns on usbredir's payload or hex-dump logging.
    private func traceUSB(enabled: Bool, _ finish: @escaping (Reply) -> Void) {
        let events = ["usb_xhci_xfer_*", "usb_xhci_ep_*", "usb_xhci_irq_*"]
        perform(finish) { [self] in
            if let failure = await setTraceEvents(events, enabled: enabled) { throw failure }
            // QMP's dynamic state alone doesn't enable the log backend's LOG_TRACE mask. A fixed command; no client text.
            _ = try await monitor(
                enabled ? "log trace:usb_xhci_xfer_*,trace:usb_xhci_ep_*,trace:usb_xhci_irq_*" : "log none")
            return ["Enabled": enabled, "AutomaticStopSeconds": 15]
        }
        guard enabled else { return }
        Task { [self] in
            try? await Task.sleep(for: .seconds(15))
            _ = try? await monitor("log none")
            _ = await setTraceEvents(events, enabled: false)
        }
    }

    /// Exceptional gaps plus one continuity summary per second. FIFO clock adjustment can run every backend callback, so
    /// that trace stays off, especially with the session log on external storage.
    private func traceAudioGaps(enabled: Bool, _ finish: @escaping (Reply) -> Void) {
        let events = ["audio_sdl_underrun", "audio_timer_delayed", "hda_audio_overrun", "audio_sdl_continuity"]
        audioTraceGeneration += 1
        let generation = audioTraceGeneration
        perform(finish) { [self] in
            if let failure = await setTraceEvents(events, enabled: enabled) { throw failure }
            return ["Enabled": enabled, "AutomaticStopSeconds": 15]
        }
        guard enabled else { return }
        Task { [self] in
            try? await Task.sleep(for: .seconds(15))
            guard audioTraceGeneration == generation, isRunning() else { return }
            _ = await setTraceEvents(events, enabled: false)
        }
    }

    // MARK: - Guest commands

    /// Times the read-only production status path, without a second agent connection or starting any setup.
    private func statusProbe(_ finish: @escaping (Reply) -> Void) {
        let started = ProcessInfo.processInfo.systemUptime
        withAgent(finish) { [agent, statusTool] in
            agent.collectStatus(tool: statusTool ?? Data()) { report, failure in
                if let failure {
                    finish(Self.failure(failure))
                } else {
                    finish([
                        "Report": report ?? [:], "Seconds": ProcessInfo.processInfo.systemUptime - started
                    ])
                }
            }
        }
    }

    /// The UTF-8 text of `bytes`, which may begin partway through a character, as a byte-bounded tail can.
    static func tailText(_ bytes: Data) -> String {
        let skip = bytes.prefix(3).prefix { $0 & 0xc0 == 0x80 }.count
        let tail = bytes.dropFirst(skip)
        return NSString(data: tail, encoding: String.Encoding.utf8.rawValue) as String?
            ?? String(data: tail, encoding: .isoLatin1) ?? ""
    }

    /// Recovery may lack the privileged status probe, so this reads the tail through the same serialized owner. Verbose
    /// PackageKit logs can exceed the agent's bounded JSON response when captured whole, which would drop control.
    private func installerLog(_ finish: @escaping (Reply) -> Void) {
        withAgent(finish) { [agent] in
            agent.runExecutable(
                "/usr/bin/tail", arguments: ["-c", "49152", "/var/log/install.log"], timeout: 30
            ) { result, failure in
                if let failure {
                    finish(Self.failure(failure))
                    return
                }
                finish([
                    "Log": Self.tailText(result?["stdout"] as? Data ?? Data()),
                    "Stderr": Self.text(result, "stderr") ?? "",
                    "ExitCode": result?["exitcode"] ?? -1
                ])
            }
        }
    }

    /// Read-only, for use while setup owns a long-running child. Reuses the same multiplexed agent owner.
    private func guestProcesses(_ sample: Bool, _ command: [String: Any], _ finish: @escaping (Reply) -> Void) {
        var arguments = ["-axo", "pid,ppid,state,etime,time,comm"]
        if sample {
            guard let pid = command["PID"] as? NSNumber, pid.int64Value >= 2, pid.int64Value <= Int64(Int32.max) else {
                finish(["Error": "Choose a guest process identifier greater than one."])
                return
            }
            arguments = [pid.stringValue, "1", "-file", "/dev/stdout"]
        }
        withAgent(finish) { [agent] in
            agent.runExecutable(sample ? "/usr/bin/sample" : "/bin/ps", arguments: arguments, timeout: 0) {
                result, failure in
                finish(Self.processReply(result, failure))
            }
        }
    }

    private static func processReply(_ result: [String: Any]?, _ failure: NSError?) -> Reply {
        if let failure { return Self.failure(failure) }
        return [
            "ExitCode": result?["exitcode"] ?? -1, "Stdout": text(result, "stdout") ?? "",
            "Stderr": text(result, "stderr") ?? ""
        ]
    }

    /// Exercises the production private staging and acknowledged transfer, confined to a fresh root-owned directory.
    private func stageProbe(_ finish: @escaping (Reply) -> Void) {
        let input = URL(fileURLWithPath: path("Transfer.bin"))
        let started = ProcessInfo.processInfo.systemUptime
        withAgent(finish) { [agent] in
            agent.stageFiles(["Transfer.bin": input], progress: nil) { receipt, failure in
                if let failure {
                    finish(Self.failure(failure))
                } else {
                    finish(["Transfer": receipt ?? [:], "Seconds": ProcessInfo.processInfo.systemUptime - started])
                }
            }
        }
    }

    private func runExecutable(_ command: [String: Any], _ finish: @escaping (Reply) -> Void) {
        guard let path = command["Executable"] as? String, (path as NSString).isAbsolutePath,
            let list = command["Arguments"] as? [Any]
        else {
            finish(["Error": "Invalid command"])
            return
        }
        guard let arguments = list as? [String] else {
            finish(["Error": "Invalid argument"])
            return
        }
        var standardInput: Data?
        if let name = command["PrivateInput"] {
            guard name as? String == "Input.bin" else {
                finish(["Error": "Invalid private input"])
                return
            }
            guard let input = Self.consumePrivateInput(atPath: self.path("Input.bin")) else {
                finish(["Error": "Private input could not be consumed safely"])
                return
            }
            standardInput = input
        }
        withAgent(finish) { [agent] in
            // An observation deadline must not discard the process handle for a native installer or cache rebuild that's
            // still legitimately running. The diagnostic client can stop observing without cancelling this task.
            agent.runExecutable(path, arguments: arguments, standardInput: standardInput, timeout: 0) {
                result, failure in
                finish(Self.processReply(result, failure))
            }
        }
    }

    /// Secrets go through the agent's stdin, never argv, Request.json or diagnostic output. Reads and removes one small
    /// private file, or returns nil and leaves anything unexpected where it is. A link is never followed.
    static func consumePrivateInput(atPath path: String) -> Data? {
        let limit = 16384
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= limit
        else { return nil }
        var input = Data()
        var chunk = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, input.count + count <= limit else { return nil }
            input.append(contentsOf: chunk[..<count])
        }
        guard input.count == Int(info.st_size), unlink(path) == 0 else { return nil }
        return input
    }
}
