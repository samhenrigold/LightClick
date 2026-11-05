import Darwin
import Foundation
import Synchronization

/// A controller for the local QGA-compatible guest agent. No command is dispatched through a shell, apart from the
/// fixed privilege check in `confirmPrivilegedAgent`.
///
/// Like `QMPConnection`, this runs on its own serial queue, so operations reach the socket in the order callers reach
/// the actor. Operations interleave at their suspension points, as VIMGuestAgent's did on the main thread between
/// completions; the `isCollecting`, `isStaging` and `isOpeningPreferences` flags keep the exclusive ones apart.
public actor GuestAgent {
    private nonisolated let queue = DispatchSerialQueue(label: "gold.samhenri.LightClick.guest-agent")
    private nonisolated let socketPath: String
    /// `close()` and the settings are synchronous, as they were in Objective-C, so these can't be actor state.
    private let shared: Mutex<Shared>

    private var isConnecting = false
    private var connectWaiters: [CheckedContinuation<GuestAgentError?, Never>] = []
    private var isCollecting = false
    private var isStaging = false
    private var isOpeningPreferences = false

    private struct Shared: Sendable {
        var connection: QMPConnection
        var isClosed = false
        var isRecoveryTransport = false
        var processPollInterval: TimeInterval = 0.25
        var isPreMetalGuest = false
        var isTigerGuest = false
        var recoverySocketPath: String?
        var statusDirectory: String?
        var statusPayload: Data?
    }

    private static let guestTools = "/Library/Application Support/Virtual Intel Mac/GuestTools/"

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(socketPath: String) {
        self.socketPath = socketPath
        shared = Mutex(Shared(connection: QMPConnection(socketPath: socketPath, mode: .guestAgent)))
    }

    // MARK: - Settings

    /// Modern VirtIO defaults to 0.25 s. The legacy UART uses a slower cold-work cadence; this never creates an
    /// idle/background polling timer.
    public nonisolated var processPollInterval: TimeInterval {
        get { shared.withLock { $0.processPollInterval } }
        set { shared.withLock { $0.processPollInterval = newValue } }
    }

    public nonisolated var isPreMetalGuest: Bool {
        get { shared.withLock { $0.isPreMetalGuest } }
        set { shared.withLock { $0.isPreMetalGuest = newValue } }
    }

    public nonisolated var isTigerGuest: Bool {
        get { shared.withLock { $0.isTigerGuest } }
        set { shared.withLock { $0.isTigerGuest = newValue } }
    }

    /// Mojave/Catalina Recovery lacks Apple's agent. Only connection handshakes may fall back to this private UART;
    /// commands are never replayed on error.
    public nonisolated var recoverySocketPath: String? {
        get { shared.withLock { $0.recoverySocketPath } }
        set { shared.withLock { $0.recoverySocketPath = newValue } }
    }

    /// Selected endpoint after a successful handshake, for diagnostic records. Recovery's UART is not Apple's
    /// installed-system VirtIO agent.
    public nonisolated var transportName: String {
        shared.withLock { state in
            if state.isRecoveryTransport { return "Apple16X50SerialRecovery" }
            return state.isPreMetalGuest ? "Apple16X50Serial" : "AppleVirtIO"
        }
    }

    private nonisolated var isClosed: Bool { shared.withLock { $0.isClosed } }
    private nonisolated var connection: QMPConnection { shared.withLock { $0.connection } }

    // MARK: - Connecting

    /// Callers that arrive during a connection attempt share its outcome.
    public func connect() async throws(GuestAgentError) {
        guard !isClosed else { throw .guest(.closed) }
        if isConnecting {
            let failure = await withCheckedContinuation { connectWaiters.append($0) }
            if let failure { throw failure }
            return
        }
        isConnecting = true
        let failure = await connectAllowingRecoveryFallback()
        let waiters = connectWaiters
        connectWaiters = []
        isConnecting = false
        for waiter in waiters { waiter.resume(returning: failure) }
        if let failure { throw failure }
    }

    private func connectAllowingRecoveryFallback() async -> GuestAgentError? {
        var mayFallBack = true
        while true {
            do throws(QMPError) {
                try await connection.connect()
                return nil
            } catch {
                guard mayFallBack, selectOtherTransport() else { return .control(error) }
                mayFallBack = false
            }
        }
    }

    /// No guest command has been dispatched. Release the failed endpoint before selecting the other transport; retain
    /// one protocol owner. Returns false, changing nothing, when there's no other transport to try.
    private nonisolated func selectOtherTransport() -> Bool {
        shared.withLock { state in
            guard let recovery = state.recoverySocketPath, !recovery.isEmpty, !state.isClosed else { return false }
            state.connection.close()
            state.isRecoveryTransport.toggle()
            state.statusDirectory = nil
            state.statusPayload = nil
            let path = state.isRecoveryTransport ? recovery : socketPath
            state.connection = QMPConnection(socketPath: path, mode: .guestAgent)
            return true
        }
    }

    // MARK: - Running processes

    private func command(_ name: String, arguments: [String: JSONValue]) async throws(GuestAgentError) -> JSONValue {
        do throws(QMPError) {
            return try await connection.execute(name, arguments: arguments)
        } catch {
            throw .control(error)
        }
    }

    /// Runs `path` directly, with no shell, and returns once it has exited.
    ///
    /// A timeout has an uncertain outcome: callers must not blindly repeat a write. Pass zero for setup work that must
    /// wait for actual process completion. Closing the agent or a transport error still interrupts the host's wait.
    ///
    /// - Parameter standardInput: Small private setup input goes through stdin, never argv or a saved command file.
    ///   Intended for account provisioning; bulk payloads belong on support media.
    public func runExecutable(
        _ path: String,
        arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval
    ) async throws(GuestAgentError) -> GuestProcessResult {
        // NSString's rule, under which "~/x" also counts as absolute, as it did in the original.
        guard !isClosed, (path as NSString).isAbsolutePath, timeout.isFinite, timeout >= 0, timeout <= 1200,
            (standardInput?.count ?? 0) <= 16384
        else { throw .guest(.cannotStart) }
        let deadline = timeout > 0 ? ProcessInfo.processInfo.systemUptime + timeout : 0
        var request: [String: JSONValue] = [
            "path": .string(path), "arg": .array(arguments.map(JSONValue.string)), "capture-output": true
        ]
        if let standardInput { request["input-data"] = .string(standardInput.base64EncodedString()) }
        let reply = try await command("guest-exec", arguments: request)
        guard let pid = reply["pid"], let number = pid.number, number.int64Value > 0 else {
            throw .guest(.noProcessIdentifier)
        }
        return try await waitForProcess(pid, deadline: deadline)
    }

    private func waitForProcess(
        _ pid: JSONValue,
        deadline: TimeInterval
    ) async throws(GuestAgentError) -> GuestProcessResult {
        while true {
            guard !isClosed, !Task.isCancelled, deadline <= 0 || ProcessInfo.processInfo.systemUptime < deadline else {
                throw .guest(.interrupted)
            }
            let reply = try await command("guest-exec-status", arguments: ["pid": pid])
            guard let exited = reply["exited"]?.number else { throw .guest(.invalidProcessStatus) }
            if exited.boolValue { return try Self.decodeExitedProcess(reply) }
            let (requested, isRecovery) = shared.withLock { ($0.processPollInterval, $0.isRecoveryTransport) }
            var interval = requested.isFinite ? max(0.25, min(15, requested)) : 0.25
            // cold UART, not a VirtIO work queue
            if isRecovery { interval = max(1, interval) }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private static func decodeExitedProcess(_ reply: JSONValue) throws(GuestAgentError) -> GuestProcessResult {
        func decode(_ stream: String) throws(GuestAgentError) -> Data {
            let encoded = reply["\(stream)-data"]
            if let truncated = reply["\(stream)-truncated"], truncated.number?.boolValue != false {
                throw .guest(.outputIncomplete)
            }
            guard let encoded else { return Data() }
            guard let text = encoded.string else { throw .guest(.outputIncomplete) }
            guard let data = Data(base64Encoded: text) else { throw .guest(.outputInvalid) }
            return data
        }
        let output = try decode("out")
        let error = try decode("err")
        guard reply["exitcode"]?.number != nil || reply["signal"]?.number != nil else {
            throw .guest(.noExitStatus)
        }
        return GuestProcessResult(status: reply.object ?? [:], standardOutput: output, standardError: error)
    }

    /// Execute in the actual console user's bootstrap session, using the period launchctl bsexec API on later pre-Metal
    /// guests, or Tiger's native child bootstrap-port launcher, rather than unsupported asuser.
    public func runConsoleExecutable(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws(GuestAgentError) -> GuestProcessResult {
        let (isTiger, isPreMetal) = shared.withLock { ($0.isTigerGuest, $0.isPreMetalGuest) }
        if isTiger {
            return try await runExecutable(
                Self.guestTools + "opengl-tiger-console",
                arguments: ["--", path] + arguments,
                timeout: timeout
            )
        }
        let console = try await runExecutable("/usr/bin/stat", arguments: ["-f", "%u", "/dev/console"], timeout: 15)
        let text = console.output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanner = text.map(Scanner.init(string:))
        guard console.isSuccessful, let scanner, let uid = scanner.scanUInt64(), scanner.isAtEnd, uid >= 501,
            uid <= Int32.max
        else { throw .guest(.notSignedIn) }
        let account = String(uid)
        // Enter the real Aqua session, then drop root before Launch Services. Period sudo predates -n. -S reads the
        // agent's closed stdin instead of prompting; modern guests retain -n. No credential input is sent. All
        // arguments are fixed or allowlisted URLs and validated numeric values, never shell text.
        var child = ["/usr/bin/sudo", isPreMetal ? "-S" : "-n", "-u", "#" + account]
        // Leopard liblaunch treats inherited SUDO_COMMAND as a request for the system socket, even after bsexec enters
        // the actual Aqua port. env -i is native there; -u is not. Only this child is affected.
        if isPreMetal { child += ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"] }
        child += [path] + arguments
        guard isPreMetal else {
            return try await runExecutable("/bin/launchctl", arguments: ["asuser", account] + child, timeout: timeout)
        }
        let processes = try await runExecutable("/bin/ps", arguments: ["-axo", "uid=,pid=,comm="], timeout: 15)
        guard processes.isSuccessful, let finder = Self.finderProcess(in: processes.output ?? "", uid: uid) else {
            throw .guest(.notSignedIn)
        }
        return try await runExecutable(
            "/bin/launchctl",
            arguments: ["bsexec", String(finder)] + child,
            timeout: timeout
        )
    }

    private static func finderProcess(in listing: String, uid: UInt64) -> Int64? {
        for line in listing.components(separatedBy: "\n") {
            let scanner = Scanner(string: line)
            guard let owner = scanner.scanInt64(), let process = scanner.scanInt64(), owner == Int64(uid), process > 0
            else { continue }
            let command = line[scanner.currentIndex...].trimmingCharacters(in: .whitespaces)
            if command == "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder" { return process }
        }
        return nil
    }

    // MARK: - Power

    /// Start macOS shutdown, acknowledging the spawned command rather than polling its exit after the agent has gone
    /// away. Never retry an uncertain request.
    public func requestShutdown() async throws(GuestAgentError) {
        try await requestPowerOperation("-h")
    }

    public func requestRestart() async throws(GuestAgentError) {
        try await requestPowerOperation("-r")
    }

    private func requestPowerOperation(_ operation: String) async throws(GuestAgentError) {
        guard !isClosed else { throw .guest(.notConnected) }
        // Apple's agent supports guest-exec; its guest-shutdown implementation is not assumed to match upstream QGA. A
        // virtual ACPI power button may sleep macOS instead. Use the same native command as the setup restart handoff,
        // but do not poll a process whose agent normally terminates during shutdown.
        let reply = try await command(
            "guest-exec",
            arguments: ["path": "/sbin/shutdown", "arg": [.string(operation), "now"], "capture-output": false]
        )
        guard let pid = reply["pid"]?.number, pid.int64Value > 0 else { throw .guest(.shutdownNotAcknowledged) }
    }

    // MARK: - File transfer

    private func writeFile(
        _ data: Data,
        path: String,
        deadline: TimeInterval,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws(GuestAgentError) {
        let handle = try await command("guest-file-open", arguments: ["path": .string(path), "mode": "wb"])
        guard handle.number != nil else { throw .guest(.stagingFileNotOpened) }
        var writeFailure: GuestAgentError?
        do throws(GuestAgentError) {
            try await writeChunks(data, handle: handle, deadline: deadline, progress: progress)
        } catch {
            writeFailure = error
        }
        var closeFailure: GuestAgentError?
        do throws(GuestAgentError) {
            _ = try await command("guest-file-close", arguments: ["handle": handle])
        } catch {
            closeFailure = error
        }
        if let failure = writeFailure ?? closeFailure { throw failure }
    }

    private func writeChunks(
        _ data: Data,
        handle: JSONValue,
        deadline: TimeInterval,
        progress: (@Sendable (Int) -> Void)?
    ) async throws(GuestAgentError) {
        var offset = 0
        while true {
            guard !isClosed, !Task.isCancelled, deadline <= 0 || ProcessInfo.processInfo.systemUptime < deadline else {
                throw .guest(.transferInterrupted)
            }
            if offset == data.count { return }
            // 384 KiB produces a 512 KiB base64 request, comfortably below QGA's 64 MiB JSON limit. The former 48 KiB
            // blocks required eight times as many serial round trips for the large graphics archive. Keep
            // acknowledgement but avoid copying each mapped input slice.
            // A physical 16550 FIFO is not a VirtIO bulk queue. Keep UART packets bounded and acknowledged, rather than
            // feeding half-megabyte JSON lines through the period serial driver's receive watermarks in one burst.
            let isUART = shared.withLock { $0.isPreMetalGuest || $0.isRecoveryTransport }
            let count = min(isUART ? 256 : 384 * 1024, data.count - offset)
            let start = data.startIndex + offset
            let chunk = data[start..<(start + count)].base64EncodedString()
            let reply = try await command(
                "guest-file-write",
                arguments: ["handle": handle, "buf-b64": .string(chunk)]
            )
            guard let written = reply["count"]?.number, written.uintValue == UInt(count) else {
                throw .guest(.stagingFileIncomplete)
            }
            offset += count
            progress?(offset)
        }
    }

    /// Both period DVDs and genuine Big Sur Recovery omit /usr/bin/id. All supported guests ship Bash as /bin/sh; its
    /// readonly EUID comes from the process identity, not an inherited environment variable. Use the same native check
    /// in Recovery and the installed OS, without probing an optional executable and disrupting an otherwise healthy
    /// agent stream.
    func confirmPrivilegedAgent() async throws(GuestAgentError) {
        let identity = try await runExecutable(
            "/bin/sh",
            arguments: ["-c", "test \"${EUID-}\" = 0 && printf '0\\n'"],
            timeout: 15
        )
        guard identity.isSuccessful, identity.output == "0\n" else { throw .guest(.notPrivileged) }
    }

    /// Trims and checks `mktemp`'s output against its template, whose six trailing characters must be alphanumeric.
    private static func makePrivateDirectory(
        template prefix: String,
        failure: GuestAgentError.Reason,
        using agent: isolated GuestAgent
    ) async throws(GuestAgentError) -> String {
        let created = try await agent.runExecutable(
            "/usr/bin/mktemp", arguments: ["-d", prefix + "XXXXXX"], timeout: 15)
        let directory = created.output?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard created.isSuccessful, let directory, directory.hasPrefix(prefix) else { throw .guest(failure) }
        let suffix = directory.utf8.dropFirst(prefix.utf8.count)
        let isAlphanumeric = suffix.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
        }
        guard suffix.count == 6, isAlphanumeric else { throw .guest(failure) }
        return directory
    }

    // MARK: - Staging

    /// Upload into a new root-owned temporary directory with acknowledged writes. Transfers only the requested files
    /// through the guest agent. Never installs files or retries ambiguous writes. Failure retains staging for diagnosis.
    ///
    /// - Parameter persistent: Installation journals, backups and verification tools must survive macOS updates, which
    ///   may remove /var/tmp. Uses root-only /private/var/db staging.
    public func stageFiles(
        _ files: [String: URL],
        persistent: Bool = false,
        progress: (@Sendable (_ completed: UInt64, _ total: UInt64) -> Void)? = nil
    ) async throws(GuestAgentError) -> GuestStagingReceipt {
        guard !isClosed, !isStaging, !isCollecting, !isOpeningPreferences, !files.isEmpty, files.count <= 16 else {
            throw .guest(.transferUnavailable)
        }
        isStaging = true
        defer { isStaging = false }
        // Reading and mapping the inputs is file I/O, so it stays off this actor's queue.
        let loaded = await Task.detached(priority: .utility) { Self.loadInputs(files) }.value
        let inputs = try loaded.get()
        guard !isClosed else { throw .guest(.transferCancelled) }
        try await confirmPrivilegedAgent()
        let base = persistent ? "/private/var/db" : "/private/var/tmp"
        let directory = try await Self.makePrivateDirectory(
            template: base + "/VirtualIntelMac.",
            failure: .transferDirectoryNotCreated,
            using: self
        )
        let total = inputs.reduce(UInt64(0)) { $0 + UInt64($1.data.count) }
        progress?(0, total)
        var completed: UInt64 = 0
        do throws(GuestAgentError) {
            for input in inputs {
                let path = (directory as NSString).appendingPathComponent(input.name)
                let base = completed
                try await writeFile(input.data, path: path, deadline: 0) { progress?(base + UInt64($0), total) }
                let mode = try await runExecutable(
                    "/bin/chmod",
                    arguments: [input.name == "guest-macho" ? "0700" : "0600", path],
                    timeout: 15
                )
                guard mode.isSuccessful else { throw GuestAgentError.guest(.stagingFileNotSecured) }
                completed += UInt64(input.data.count)
            }
        } catch {
            throw .staging(error, directory: directory)
        }
        return GuestStagingReceipt(
            directory: directory,
            files: inputs.map { .init(name: $0.name, size: $0.data.count) }
        )
    }

    private struct StagingInput: Sendable {
        let name: String
        let data: Data
    }

    private nonisolated static func loadInputs(_ files: [String: URL]) -> Result<[StagingInput], GuestAgentError> {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.".utf8)
        var inputs: [StagingInput] = []
        var total: UInt64 = 0
        for name in files.keys.sorted(by: { $0.compare($1) == .orderedAscending }) {
            guard let url = files[name], !name.isEmpty, !name.hasPrefix("."), name.utf16.count <= 128,
                name.utf8.allSatisfy(allowed.contains), url.isFileURL
            else { return .failure(.guest(.invalidInputName)) }
            do {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    return .failure(.guest(.inputNotRegularFile))
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 512 * 1024 * 1024, total + UInt64(data.count) <= 1024 * 1024 * 1024 else {
                    return .failure(.guest(.transferLimitExceeded))
                }
                inputs.append(StagingInput(name: name, data: data))
                total += UInt64(data.count)
            } catch {
                return .failure(.foundation(error as NSError))
            }
        }
        return .success(inputs)
    }

    // MARK: - Status

    /// Stages the read-only status probe in a root-only private run directory. Reuse requires unchanged requested bytes
    /// and root-only cache metadata; every call executes it again for fresh evidence. Never marks a VM installed.
    public func collectStatus(tool: Data) async throws(GuestAgentError) -> [String: JSONValue] {
        guard !isClosed, !isCollecting, !isStaging, !isOpeningPreferences, !tool.isEmpty, tool.count <= 1024 * 1024
        else { throw .guest(.statusProbeUnavailable) }
        isCollecting = true
        defer { isCollecting = false }
        let cached = shared.withLock { state -> String? in
            guard let directory = state.statusDirectory, state.statusPayload == tool else {
                state.statusDirectory = nil
                state.statusPayload = nil
                return nil
            }
            return directory
        }
        guard let directory = cached else { return try await stageStatusTool(tool) }
        let path = (directory as NSString).appendingPathComponent("guest-status")
        // BSD stat defaults to lstat: reject symlinks, non-root ownership, shared directories and extra hard links
        // before executing the cache. Root-only execute permission also prevents an unprivileged replacement agent from
        // supplying a successful privileged status report.
        let metadata = try await runExecutable(
            "/usr/bin/stat",
            arguments: ["-f", "%u:%p:%l:%z", directory, path],
            timeout: 15
        )
        let lines = metadata.output?.trimmingCharacters(in: .newlines).components(separatedBy: "\n") ?? []
        let parent = lines.count == 2 ? lines[0].components(separatedBy: ":") : []
        if metadata.isSuccessful, parent.count == 4, parent[0] == "0", parent[1] == "40700",
            lines[1] == "0:100700:1:\(tool.count)"
        {
            return try await readStatus(at: path)
        }
        // A guest reboot/recovery environment may remove the private run directory. Restage after this definitive
        // read-only miss, never after an ambiguous transport failure and never delete a changed or untrusted cache path.
        shared.withLock { state in
            state.statusDirectory = nil
            state.statusPayload = nil
        }
        return try await stageStatusTool(tool)
    }

    /// Installed by the root-owned support manifest. This observation cannot authorize framework replacement or mark an
    /// imported VM as installed.
    public func collectInstalledOpenGLDesktopStatus() async throws(GuestAgentError) -> [String: JSONValue] {
        try await readStatus(at: Self.guestTools + "opengl-desktop-status")
    }

    /// Cache executable bytes only, never readiness, build, volume or boot data.
    private func readStatus(at path: String) async throws(GuestAgentError) -> [String: JSONValue] {
        let result = try await runExecutable(path, arguments: [], timeout: 30)
        guard result.isSuccessful else { throw .guest(.invalidReport) }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: result.standardOutput)
        } catch {
            throw .foundation(error as NSError)
        }
        guard let report = JSONValue(foundationObject: parsed)?.object, report["ProtocolVersion"] == 1,
            report["Ready"] == false
        else { throw .guest(.invalidReport) }
        return report
    }

    private func stageStatusTool(_ payload: Data) async throws(GuestAgentError) -> [String: JSONValue] {
        try await confirmPrivilegedAgent()
        let directory = try await Self.makePrivateDirectory(
            template: "/private/var/run/VirtualIntelMacStatus.",
            failure: .probeDirectoryNotCreated,
            using: self
        )
        let path = (directory as NSString).appendingPathComponent("guest-status")
        do throws(GuestAgentError) {
            try await writeFile(payload, path: path, deadline: ProcessInfo.processInfo.systemUptime + 600)
            let mode = try await runExecutable("/bin/chmod", arguments: ["0700", path], timeout: 15)
            guard mode.isSuccessful else { throw GuestAgentError.guest(.probeNotPrepared) }
        } catch {
            // The original failure is the one reported, whatever cleanup finds.
            _ = try? await runExecutable("/bin/rm", arguments: ["-f", path], timeout: 15)
            _ = try? await runExecutable("/bin/rmdir", arguments: [directory], timeout: 15)
            throw error
        }
        shared.withLock { state in
            state.statusDirectory = directory
            state.statusPayload = payload
        }
        return try await readStatus(at: path)
    }

    // MARK: - Opening things in the guest

    /// Open an allowed System Preferences pane in the signed-in guest's GUI session. Does not enable services, change
    /// permissions, collect passwords or use AppleEvents.
    public func openPreferencesPane(_ pane: String) async throws(GuestAgentError) {
        var url: String? =
            switch pane {
            case "sharing": "x-apple.systempreferences:com.apple.preferences.sharing"
            case "microphone": "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            default: nil
            }
        // Period open(1) treats the later x-apple.systempreferences: spelling as a local filename. Open the real Apple
        // pane through Launch Services.
        if isPreMetalGuest && pane == "sharing" { url = "/System/Library/PreferencePanes/SharingPref.prefPane" }
        try await openGUIURL(url)
    }

    /// Open an SMB/SSH URL after the session validates the actual host network IP.
    public func openHostConnection(_ url: URL) async throws(GuestAgentError) {
        // The session first matches this IP to its actual host-side network address. Do not resolve arbitrary names or
        // pass untrusted URL options to open.
        let parts = url as NSURL
        let scheme = parts.scheme?.lowercased()
        var address = in_addr()
        guard let host = parts.host, inet_pton(AF_INET, host, &address) == 1, scheme == "ssh" || scheme == "smb",
            parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.port == nil || parts.port == 22
        else { throw .guest(.unsupportedConnection) }
        if isPreMetalGuest && scheme == "ssh" {
            guard !isClosed, !isCollecting, !isStaging, !isOpeningPreferences else {
                throw .guest(.busyOpeningConnection)
            }
            isOpeningPreferences = true
            defer { isOpeningPreferences = false }
            let opened = try await runConsoleExecutable(
                Self.guestTools + "guest-host-connection",
                arguments: ["--ssh", host, parts.user ?? NSUserName()],
                timeout: 30
            )
            guard opened.isSuccessful else { throw .guest(.sshClientFailed) }
            return
        }
        try await openGUIURL(parts.absoluteString)
    }

    private func openGUIURL(_ url: String?) async throws(GuestAgentError) {
        guard let url, !isClosed, !isCollecting, !isStaging, !isOpeningPreferences else {
            throw .guest(.guestInterfaceUnavailable)
        }
        isOpeningPreferences = true
        defer { isOpeningPreferences = false }
        let opened = try await runConsoleExecutable("/usr/bin/open", arguments: [url], timeout: 30)
        guard opened.isSuccessful else { throw .guest(.connectionNotOpened) }
    }

    // MARK: - Close

    /// Synchronous: nothing new starts once this returns, and any blocked read wakes at once.
    public nonisolated func close() {
        shared.withLock { state in
            state.isClosed = true
            state.statusDirectory = nil
            state.statusPayload = nil
            state.connection.close()
        }
    }
}
