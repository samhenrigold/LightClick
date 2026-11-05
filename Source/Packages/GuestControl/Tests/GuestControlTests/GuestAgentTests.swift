import Foundation
import Synchronization
import Testing

@testable import GuestControl

/// Ports probes/app-guest-preferences.m, app-status-cache.m, guest-agent-identity-tests.m and the QEMU-free parts of
/// app-guest-agent.m, driving the production transport over a fake socket instead of subclassing the agent.
struct GuestAgentTests {
    private func failure<Value>(of operation: () async throws(GuestAgentError) -> Value) async -> GuestAgentError? {
        do throws(GuestAgentError) {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    private func connected(
        to fake: FakeGuestAgent,
        configure: (GuestAgent) -> Void = { _ in }
    ) async throws -> GuestAgent {
        let agent = GuestAgent(socketPath: fake.path)
        configure(agent)
        try await agent.connect()
        return agent
    }

    // MARK: - Transport

    @Test func transportNamesFollowTheGuestAndEndpoint() async throws {
        let agent = GuestAgent(socketPath: "/nonexistent/native-agent")
        defer { agent.close() }
        #expect(agent.transportName == "AppleVirtIO")
        agent.isPreMetalGuest = true
        #expect(agent.transportName == "Apple16X50Serial")
    }

    @Test func aFailedHandshakeFallsBackToRecoveryOnce() async throws {
        let primary = FakeGuestAgent(refusesHandshake: true)
        let recovery = FakeGuestAgent()
        defer {
            primary.stop()
            recovery.stop()
        }
        let agent = GuestAgent(socketPath: primary.path)
        defer { agent.close() }
        agent.recoverySocketPath = recovery.path
        try await agent.connect()
        #expect(agent.transportName == "Apple16X50SerialRecovery")
        #expect(recovery.state.withLock { $0.syncs } == 1)
        _ = try await agent.runExecutable("/fixture", arguments: [], timeout: 0)
        #expect(recovery.state.withLock { $0.processes.count } == 1)
    }

    @Test func withoutARecoveryPathAFailedHandshakeJustFails() async {
        let primary = FakeGuestAgent(refusesHandshake: true)
        defer { primary.stop() }
        let agent = GuestAgent(socketPath: primary.path)
        defer { agent.close() }
        #expect(await failure { () async throws(GuestAgentError) in try await agent.connect() } != nil)
        #expect(agent.transportName == "AppleVirtIO")
    }

    /// Only handshakes may fall back: a command that fails after connecting isn't replayed on the other endpoint.
    @Test func aFailedCommandIsNeverReplayedOnRecovery() async throws {
        let primary = FakeGuestAgent { _ in .refused }
        let recovery = FakeGuestAgent()
        defer {
            primary.stop()
            recovery.stop()
        }
        let agent = GuestAgent(socketPath: primary.path)
        defer { agent.close() }
        agent.recoverySocketPath = recovery.path
        try await agent.connect()
        let error = await failure { () async throws(GuestAgentError) in
            try await agent.runExecutable("/fixture", arguments: [], timeout: 0)
        }
        #expect(error == .control(.rejected("refused")))
        #expect(primary.state.withLock { $0.processes.count } == 1)
        #expect(recovery.state.withLock { $0.syncs } == 0)
    }

    @Test func concurrentConnectsShareOneAttempt() async throws {
        let fake = FakeGuestAgent()
        defer { fake.stop() }
        let agent = GuestAgent(socketPath: fake.path)
        defer { agent.close() }
        async let first: Void = agent.connect()
        async let second: Void = agent.connect()
        _ = try await (first, second)
        #expect(fake.state.withLock { $0.syncs } == 1)
    }

    @Test func connectingAfterCloseFails() async {
        let agent = GuestAgent(socketPath: "/nonexistent/agent")
        agent.close()
        let error = await failure { () async throws(GuestAgentError) in try await agent.connect() }
        #expect(error == .guest(.closed))
    }

    // MARK: - Processes

    @Test func aZeroTimeoutPollsUntilTheProcessExits() async throws {
        let fake = FakeGuestAgent { _ in .finished(exitCode: 0, output: "done") }
        defer { fake.stop() }
        fake.state.withLock { $0.pollsBeforeExit = 1 }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let result = try await agent.runExecutable("/fixture/setup", arguments: ["a"], timeout: 0)
        #expect(result.isSuccessful)
        #expect(result.output == "done")
        let (processes, polls) = fake.state.withLock { ($0.processes, $0.polls) }
        #expect(polls == 2, "Zero timeout must still poll until process exit")
        #expect(
            processes == [.init(path: "/fixture/setup", arguments: ["a"], captureOutput: true, input: nil)],
            "Never retry a potentially mutating command"
        )
    }

    @Test func aTimeoutIsReportedAsInterruptedAndNotRetried() async throws {
        let fake = FakeGuestAgent { _ in .running }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in
            try await agent.runExecutable("/fixture/setup", arguments: [], timeout: 0.01)
        }
        #expect(error == .guest(.interrupted))
        #expect(fake.state.withLock { $0.processes.count } == 1)
    }

    @Test func closingInterruptsAnUnlimitedWait() async throws {
        let fake = FakeGuestAgent { _ in .running }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        async let error = failure { () async throws(GuestAgentError) in
            try await agent.runExecutable("/fixture/setup", arguments: [], timeout: 0)
        }
        try await Task.sleep(for: .milliseconds(100))
        agent.close()
        #expect(await error != nil)
        #expect(fake.state.withLock { $0.processes.count } == 1)
    }

    @Test func cancellingEndsAnUnlimitedWaitWithoutSpinning() async throws {
        let fake = FakeGuestAgent { _ in .running }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let task = Task { () -> GuestAgentError? in
            await failure { () async throws(GuestAgentError) in
                try await agent.runExecutable("/fixture/setup", arguments: [], timeout: 0)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(await task.value == .guest(.interrupted))
    }

    @Test(arguments: [-1, Double.nan, Double.infinity, 1201])
    func anInvalidTimeoutDispatchesNothing(timeout: Double) async throws {
        let fake = FakeGuestAgent()
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in
            try await agent.runExecutable("/fixture/setup", arguments: [], timeout: timeout)
        }
        #expect(error == .guest(.cannotStart))
        #expect(fake.state.withLock { $0.processes.isEmpty })
    }

    @Test func aRelativePathOrOversizedInputDispatchesNothing() async throws {
        let fake = FakeGuestAgent()
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let relative = await failure { () async throws(GuestAgentError) in
            try await agent.runExecutable("setup", arguments: [], timeout: 1)
        }
        let oversized = await failure { () async throws(GuestAgentError) in
            try await agent.runExecutable("/setup", arguments: [], standardInput: Data(count: 16385), timeout: 1)
        }
        #expect(relative == .guest(.cannotStart))
        #expect(oversized == .guest(.cannotStart))
        #expect(fake.state.withLock { $0.processes.isEmpty })
    }

    @Test func standardInputGoesThroughInputDataNotArguments() async throws {
        let fake = FakeGuestAgent()
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        _ = try await agent.runExecutable("/setup", arguments: [], standardInput: Data("secret".utf8), timeout: 1)
        let process = fake.state.withLock { $0.processes.first }
        #expect(process?.input == Data("secret".utf8).base64EncodedString())
        #expect(process?.arguments == [])
    }

    private static let badExitStatuses: [(JSONValue, GuestAgentError.Reason)] = [
        (["exitcode": 0], .invalidProcessStatus),
        (["exited": "yes"], .invalidProcessStatus),
        (["exited": true, "exitcode": 0, "out-truncated": true], .outputIncomplete),
        (["exited": true, "exitcode": 0, "err-truncated": "no"], .outputIncomplete),
        (["exited": true, "exitcode": 0, "out-data": 7], .outputIncomplete),
        (["exited": true, "exitcode": 0, "out-data": "not base64!"], .outputInvalid),
        (["exited": true], .noExitStatus),
        (["exited": true, "exitcode": "0"], .noExitStatus)
    ]

    @Test(arguments: badExitStatuses)
    func aBadExitStatusIsRefused(reply: JSONValue, reason: GuestAgentError.Reason) async throws {
        let fake = FakeGuestAgent { _ in .status(reply) }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in
            try await agent.runExecutable("/fixture", arguments: [], timeout: 5)
        }
        #expect(error == .guest(reason))
    }

    @Test func anExplicitFalseTruncationIsAcceptedAndAnySignalKeyMeansFailure() async throws {
        let fake = FakeGuestAgent { _ in
            .status(["exited": true, "exitcode": 0, "out-truncated": false, "signal": .null])
        }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let result = try await agent.runExecutable("/fixture", arguments: [], timeout: 5)
        #expect(!result.isSuccessful)
    }

    @Test func aSignalAloneCountsAsAnExitStatus() async throws {
        let fake = FakeGuestAgent { _ in .status(["exited": true, "signal": 9]) }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        #expect(try await !agent.runExecutable("/fixture", arguments: [], timeout: 5).isSuccessful)
    }

    // MARK: - Power

    @Test func shutdownUsesTheNativeCommandAndNeverPolls() async throws {
        let fake = FakeGuestAgent()
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        try await agent.requestShutdown()
        try await agent.requestRestart()
        let (processes, polls) = fake.state.withLock { ($0.processes, $0.polls) }
        #expect(
            processes == [
                .init(path: "/sbin/shutdown", arguments: ["-h", "now"], captureOutput: false, input: nil),
                .init(path: "/sbin/shutdown", arguments: ["-r", "now"], captureOutput: false, input: nil)
            ],
            "Use native macOS shutdown, not ACPI sleep or guest-shutdown's absent success reply"
        )
        #expect(polls == 0, "Never poll a dead agent")
    }

    @Test func aRefusedShutdownIsNotRepeated() async throws {
        let fake = FakeGuestAgent { _ in .refused }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in try await agent.requestShutdown() }
        #expect(error == .control(.rejected("refused")))
        #expect(fake.state.withLock { $0.processes.count } == 1)
    }

    // MARK: - Privilege check

    @Test(arguments: [(0, "0\n", true), (0, "501\n", false), (255, "", false), (1, "0\n", false)])
    func onlyAnActualSuccessfulRootReplyIsAccepted(exitCode: Int, output: String, isAccepted: Bool) async throws {
        let fake = FakeGuestAgent { _ in .finished(exitCode: exitCode, output: output) }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in try await agent.confirmPrivilegedAgent() }
        #expect(error == (isAccepted ? nil : .guest(.notPrivileged)))
        #expect(
            fake.state.withLock { $0.processes.first?.path } == "/bin/sh",
            "Recovery identity does not require optional /usr/bin/id"
        )
    }

    // MARK: - Preferences

    private static func preferences(console: String = "501\n", launchExit: Int = 0) -> FakeGuestAgent {
        FakeGuestAgent { process in
            process.path == "/usr/bin/stat" ? .finished(exitCode: 0, output: console) : .finished(exitCode: launchExit)
        }
    }

    @Test(arguments: [
        ("sharing", "x-apple.systempreferences:com.apple.preferences.sharing"),
        ("microphone", "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    ])
    func aPaneOpensInTheConsoleUsersSessionWithRootDropped(pane: String, url: String) async throws {
        let fake = Self.preferences()
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        try await agent.openPreferencesPane(pane)
        let processes = fake.state.withLock { $0.processes }
        #expect(processes.count == 2, "One console lookup and one GUI launch")
        #expect(processes.first?.arguments == ["-f", "%u", "/dev/console"], "Discover the account, do not assume UID")
        #expect(processes.last?.path == "/bin/launchctl")
        #expect(
            processes.last?.arguments == ["asuser", "501", "/usr/bin/sudo", "-n", "-u", "#501", "/usr/bin/open", url],
            "Drop root, enter Aqua and never prompt for credentials"
        )
    }

    @Test(arguments: ["0\n", "248\n", "-1\n", "4294967295\n", "501;open /tmp\n", "501\n502\n"])
    func noGUILaunchWithoutAValidSignedInAccount(console: String) async throws {
        let fake = Self.preferences(console: console)
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in try await agent.openPreferencesPane("sharing") }
        #expect(error == .guest(.notSignedIn))
        #expect(fake.state.withLock { $0.processes.count } == 1)
    }

    @Test func onlyTheTwoFixedPanesAreAccepted() async throws {
        let fake = Self.preferences()
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in
            try await agent.openPreferencesPane("/tmp/arbitrary")
        }
        #expect(error == .guest(.guestInterfaceUnavailable))
        #expect(fake.state.withLock { $0.processes.isEmpty })
    }

    @Test func aRejectedGUILaunchIsNotRetried() async throws {
        let fake = Self.preferences(launchExit: 1)
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in try await agent.openPreferencesPane("sharing") }
        #expect(error == .guest(.connectionNotOpened))
        #expect(fake.state.withLock { $0.processes.count } == 2)
    }

    @Test func aTransportFailureDoesNotLaunchOrRetry() async throws {
        let fake = FakeGuestAgent { _ in .refused }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in try await agent.openPreferencesPane("sharing") }
        #expect(error == .control(.rejected("refused")))
        #expect(fake.state.withLock { $0.processes.count } == 1)
    }

    @Test func aClosedAgentCannotOpenGuestInterface() async throws {
        let fake = Self.preferences()
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        agent.close()
        let error = await failure { () async throws(GuestAgentError) in try await agent.openPreferencesPane("sharing") }
        #expect(error == .guest(.guestInterfaceUnavailable))
        #expect(fake.state.withLock { $0.processes.isEmpty })
    }

    @Test func aPreMetalGuestEntersTheFinderSessionWithAScrubbedEnvironment() async throws {
        let finder = "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
        let fake = FakeGuestAgent { process in
            switch process.path {
            case "/usr/bin/stat": .finished(exitCode: 0, output: "501\n")
            case "/bin/ps":
                .finished(
                    exitCode: 0, output: "  0 1 /sbin/launchd\n 502 77 \(finder)\n 501 88 /other\n 501 99 \(finder)\n")
            default: .finished(exitCode: 0)
            }
        }
        defer { fake.stop() }
        let agent = try await connected(to: fake) { $0.isPreMetalGuest = true }
        defer { agent.close() }
        try await agent.openPreferencesPane("sharing")
        #expect(
            fake.state.withLock { $0.processes.last?.arguments } == [
                "bsexec", "99", "/usr/bin/sudo", "-S", "-u", "#501", "/usr/bin/env", "-i",
                "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "/usr/bin/open",
                "/System/Library/PreferencePanes/SharingPref.prefPane"
            ]
        )
    }

    @Test func aTigerGuestUsesItsNativeLauncherWithNoLookup() async throws {
        let fake = FakeGuestAgent()
        defer { fake.stop() }
        let agent = try await connected(to: fake) { $0.isTigerGuest = true }
        defer { agent.close() }
        _ = try await agent.runConsoleExecutable("/usr/bin/open", arguments: ["x"], timeout: 30)
        let processes = fake.state.withLock { $0.processes }
        #expect(processes.count == 1)
        #expect(
            processes.first?.path == "/Library/Application Support/Virtual Intel Mac/GuestTools/opengl-tiger-console")
        #expect(processes.first?.arguments == ["--", "/usr/bin/open", "x"])
    }

    // MARK: - Host connections

    @Test(arguments: [
        "ssh://10.0.2.2", "smb://10.0.2.2/share", "ssh://me@10.0.2.2:22", "SSH://10.0.2.2"
    ])
    func aNumericHostConnectionIsAllowed(url: String) async throws {
        let fake = Self.preferences()
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        try await agent.openHostConnection(try #require(URL(string: url)))
        #expect(fake.state.withLock { $0.processes.last?.arguments.last } == url)
    }

    @Test(arguments: [
        "http://10.0.2.2", "ssh://example.com", "ssh://me:pw@10.0.2.2", "ssh://10.0.2.2?x=1", "smb://10.0.2.2#f",
        "ssh://10.0.2.2:2222", "file:///etc/passwd", "ssh:"
    ])
    func anythingElseIsRefusedBeforeReachingTheGuest(url: String) async throws {
        let fake = Self.preferences()
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let target = try #require(URL(string: url))
        let error = await failure { () async throws(GuestAgentError) in try await agent.openHostConnection(target) }
        #expect(error == .guest(.unsupportedConnection))
        #expect(fake.state.withLock { $0.processes.isEmpty })
    }

    @Test func aPreMetalSSHConnectionUsesTheGuestToolWithTheURLUser() async throws {
        let fake = FakeGuestAgent { _ in .finished(exitCode: 0) }
        defer { fake.stop() }
        let agent = try await connected(to: fake) {
            $0.isPreMetalGuest = true
            $0.isTigerGuest = true
        }
        defer { agent.close() }
        try await agent.openHostConnection(try #require(URL(string: "ssh://me@10.0.2.2")))
        #expect(
            fake.state.withLock { $0.processes.last?.arguments } == [
                "--", "/Library/Application Support/Virtual Intel Mac/GuestTools/guest-host-connection", "--ssh",
                "10.0.2.2", "me"
            ]
        )
    }

    // MARK: - Status cache

    /// The fake guest's status tool: stat answers, mktemp hands out directories, and the probe reports a build.
    private final class StatusGuest: Sendable {
        struct Settings: Sendable {
            var isRoot = true
            var statText: String?
            var build = "first"
            var isReportInvalid = false
            var isStatRefused = false
            var mktempOutput: String?
            var chmodExit = 0
        }
        let settings = Mutex(Settings())

        func outcome(for process: FakeGuestAgent.Process) -> FakeGuestAgent.Outcome {
            settings.withLock { settings in
                switch process.path {
                case "/bin/sh": return .finished(exitCode: 0, output: settings.isRoot ? "0\n" : "501\n")
                case "/usr/bin/mktemp":
                    let directory = settings.mktempOutput ?? "/private/var/run/VirtualIntelMacStatus.abc123\n"
                    return .finished(exitCode: 0, output: directory)
                case "/usr/bin/stat":
                    if settings.isStatRefused { return .refused }
                    return .finished(exitCode: 0, output: settings.statText ?? "0:40700:2:64\n0:100700:1:3\n")
                case "/bin/chmod": return .finished(exitCode: settings.chmodExit)
                case "/bin/rm", "/bin/rmdir": return .finished(exitCode: 0)
                default:
                    let ready = settings.isReportInvalid ? "true" : "false"
                    return .finished(
                        exitCode: 0,
                        output:
                            "{\"ProtocolVersion\":1,\"Ready\":\(ready),\"ProductBuildVersion\":\"\(settings.build)\"}"
                    )
                }
            }
        }
    }

    private static let tool = Data("one".utf8)

    @Test func theStatusCacheNeverReusesEvidenceOrUntrustedMetadata() async throws {
        let guest = StatusGuest()
        let fake = FakeGuestAgent { guest.outcome(for: $0) }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        func writes() -> Int { fake.state.withLock { $0.closedHandles } }
        func launches() -> Int { fake.state.withLock { $0.processes.count } }

        #expect(try await agent.collectStatus(tool: Self.tool)["ProductBuildVersion"] == "first")
        #expect(writes() == 1)
        #expect(launches() == 4, "Cold status uses one upload and four processes")

        guest.settings.withLock { $0.build = "updated" }
        var before = launches()
        #expect(
            try await agent.collectStatus(tool: Self.tool)["ProductBuildVersion"] == "updated",
            "Never cache guest build evidence"
        )
        #expect(writes() == 1)
        #expect(launches() - before == 2, "Warm status uses metadata check plus fresh execution only")

        for bad in [
            "501:40700:2:64\n0:100700:1:3\n", "0:40777:2:64\n0:100700:1:3\n", "0:40700:2:64\n501:100700:1:3\n",
            "0:40700:2:64\n0:100700:2:3\n", "0:40700:2:64\n0:100700:1:4\n", "0:40700:2:64\n0:120777:1:3\n",
            "malformed\n"
        ] {
            before = writes()
            guest.settings.withLock { $0.statText = bad }
            _ = try await agent.collectStatus(tool: Self.tool)
            guest.settings.withLock { $0.statText = nil }
            #expect(writes() == before + 1, "Untrusted owner/mode/link/size metadata must restage safely")
        }

        before = writes()
        let same = Data("two".utf8)
        _ = try await agent.collectStatus(tool: same)
        #expect(writes() == before + 1, "Same-size changed payload must be restaged")

        guest.settings.withLock { $0.isReportInvalid = true }
        let invalid = await failure { () async throws(GuestAgentError) in try await agent.collectStatus(tool: same) }
        #expect(invalid == .guest(.invalidReport))
        #expect(writes() == before + 1, "Invalid evidence does not become success or trigger repeated uploads")
        guest.settings.withLock { $0.isReportInvalid = false }

        // Transport uncertainty: the QGA stream is discarded, and nothing is restaged.
        guest.settings.withLock { $0.isStatRefused = true }
        let uncertain = await failure { () async throws(GuestAgentError) in try await agent.collectStatus(tool: same) }
        #expect(uncertain == .control(.rejected("refused")))
        #expect(writes() == before + 1, "Transport uncertainty must not restage/retry a write")
        guest.settings.withLock { $0.isStatRefused = false }
        try await agent.connect()
        _ = try await agent.collectStatus(tool: same)
        #expect(writes() == before + 1, "A later valid read reuses the secured file")

        agent.close()
        let closed = await failure { () async throws(GuestAgentError) in try await agent.collectStatus(tool: same) }
        #expect(closed == .guest(.statusProbeUnavailable), "Closed agent cannot use cache")
        #expect(writes() == before + 1)
    }

    @Test func anUnprivilegedAgentGetsNoProbe() async throws {
        let guest = StatusGuest()
        guest.settings.withLock { $0.isRoot = false }
        let fake = FakeGuestAgent { guest.outcome(for: $0) }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in try await agent.collectStatus(tool: Self.tool) }
        #expect(error == .guest(.notPrivileged))
        #expect(fake.state.withLock { $0.files.isEmpty })
    }

    @Test(arguments: [
        "/tmp/evil\n", "/private/var/run/VirtualIntelMacStatus.abc\n",
        "/private/var/run/VirtualIntelMacStatus.abc12!\n",
        "/private/var/run/VirtualIntelMacStatus.abc123/../x\n"
    ])
    func anUnexpectedTemporaryDirectoryIsNeverWrittenTo(output: String) async throws {
        let guest = StatusGuest()
        guest.settings.withLock { $0.mktempOutput = output }
        let fake = FakeGuestAgent { guest.outcome(for: $0) }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in try await agent.collectStatus(tool: Self.tool) }
        #expect(error == .guest(.probeDirectoryNotCreated))
        #expect(fake.state.withLock { $0.files.isEmpty })
    }

    @Test func aFailedProbeSetupCleansUpAndReportsTheOriginalFailure() async throws {
        let guest = StatusGuest()
        guest.settings.withLock { $0.chmodExit = 1 }
        let fake = FakeGuestAgent { guest.outcome(for: $0) }
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in try await agent.collectStatus(tool: Self.tool) }
        #expect(error == .guest(.probeNotPrepared))
        let paths = fake.state.withLock { $0.processes.map(\.path) }
        #expect(paths.suffix(2) == ["/bin/rm", "/bin/rmdir"])
    }

    // MARK: - Staging

    private func makeInputs(_ sizes: [String: Int]) throws -> (urls: [String: URL], directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [String: URL] = [:]
        for (name, size) in sizes {
            let url = directory.appendingPathComponent(name)
            try Data((0..<size).map { UInt8(truncatingIfNeeded: $0) }).write(to: url)
            urls[name] = url
        }
        return (urls, directory)
    }

    private static func stagingGuest(mktemp: String = "/private/var/tmp/VirtualIntelMac.abc123\n") -> FakeGuestAgent {
        FakeGuestAgent { process in
            switch process.path {
            case "/bin/sh": .finished(exitCode: 0, output: "0\n")
            case "/usr/bin/mktemp": .finished(exitCode: 0, output: mktemp)
            default: .finished(exitCode: 0)
            }
        }
    }

    @Test func stagingChunksAcknowledgesAndReturnsASortedReceipt() async throws {
        let (urls, directory) = try makeInputs(["transfer-test": 500_000, "guest-macho": 10, "empty": 0])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = Self.stagingGuest()
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let progress = Recorder<UInt64>()
        let receipt = try await agent.stageFiles(urls) { completed, total in
            #expect(total == 500_010)
            progress.append(completed)
        }
        let staging = "/private/var/tmp/VirtualIntelMac.abc123"
        #expect(receipt.directory == staging)
        #expect(
            receipt.files == [
                .init(name: "empty", size: 0), .init(name: "guest-macho", size: 10),
                .init(name: "transfer-test", size: 500_000)
            ]
        )
        let state = fake.state.withLock { $0 }
        #expect(state.chunkSizes == [10, 384 * 1024, 500_000 - 384 * 1024], "384 KiB chunks over VirtIO")
        #expect(state.files["\(staging)/transfer-test"] == (try Data(contentsOf: urls["transfer-test"]!)))
        #expect(state.files["\(staging)/empty"] == Data(), "An empty file still gets created")
        #expect(state.closedHandles == 3)
        #expect(progress.all == [0, 10, 10 + 384 * 1024, 500_010])
        let modes = state.processes.filter { $0.path == "/bin/chmod" }.map(\.arguments)
        #expect(
            modes == [
                ["0600", "\(staging)/empty"], ["0700", "\(staging)/guest-macho"], ["0600", "\(staging)/transfer-test"]
            ],
            "Only guest-macho is executable"
        )
        #expect(state.processes.first?.path == "/bin/sh", "Privilege is confirmed before anything is created")
    }

    @Test func aUARTGuestGetsSmallAcknowledgedPackets() async throws {
        let (urls, directory) = try makeInputs(["payload": 600])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = Self.stagingGuest()
        defer { fake.stop() }
        let agent = try await connected(to: fake) { $0.isPreMetalGuest = true }
        defer { agent.close() }
        _ = try await agent.stageFiles(urls)
        #expect(fake.state.withLock { $0.chunkSizes } == [256, 256, 88])
    }

    @Test func theRecoveryTransportIsPacedLikeAUART() async throws {
        let (urls, directory) = try makeInputs(["payload": 300])
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = FakeGuestAgent(refusesHandshake: true)
        let recovery = Self.stagingGuest()
        defer {
            primary.stop()
            recovery.stop()
        }
        let agent = GuestAgent(socketPath: primary.path)
        defer { agent.close() }
        agent.recoverySocketPath = recovery.path
        try await agent.connect()
        _ = try await agent.stageFiles(urls)
        #expect(recovery.state.withLock { $0.chunkSizes } == [256, 44])
    }

    @Test func installationFilesStageUnderTheDirectoryThatSurvivesUpdates() async throws {
        let (urls, directory) = try makeInputs(["payload": 1])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = Self.stagingGuest(mktemp: "/private/var/db/VirtualIntelMac.abc123\n")
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let receipt = try await agent.stageFiles(urls, persistent: true)
        #expect(receipt.directory == "/private/var/db/VirtualIntelMac.abc123")
        #expect(
            fake.state.withLock { $0.processes[1].arguments } == ["-d", "/private/var/db/VirtualIntelMac.XXXXXX"]
        )
    }

    @Test func aFailedWriteRetainsStagingAndNamesItsDirectory() async throws {
        let (urls, directory) = try makeInputs(["payload": 800_000])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = Self.stagingGuest()
        defer { fake.stop() }
        fake.state.withLock { $0.failWriteAtChunk = 1 }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in try await agent.stageFiles(urls) }
        let staging = "/private/var/tmp/VirtualIntelMac.abc123"
        #expect(error == .staging(.control(.rejected("disk full")), directory: staging))
        #expect(error?.nsError.userInfo["GuestStagingDirectory"] as? String == staging)
        #expect(error?.nsError.domain == "VirtualIntelMac.Control")
        let state = fake.state.withLock { $0 }
        #expect(state.chunkSizes == [384 * 1024], "No retried write")
        #expect(!state.processes.contains { $0.path == "/bin/rm" || $0.path == "/bin/rmdir" }, "Staging is retained")
    }

    @Test func aShortWriteAcknowledgementFailsTheTransfer() async throws {
        let (urls, directory) = try makeInputs(["payload": 10])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = Self.stagingGuest()
        defer { fake.stop() }
        fake.state.withLock { $0.shortWrites = true }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in try await agent.stageFiles(urls) }
        #expect(
            error == .staging(.guest(.stagingFileIncomplete), directory: "/private/var/tmp/VirtualIntelMac.abc123")
        )
        #expect(fake.state.withLock { $0.closedHandles } == 1, "The handle is closed even after a failed write")
    }

    @Test(arguments: ["", ".hidden", "a/b", "../x", "spa ce", String(repeating: "a", count: 129), "é"])
    func aBadFileNameStagesNothing(name: String) async throws {
        let (urls, directory) = try makeInputs(["payload": 1])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = Self.stagingGuest()
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let input = try #require(urls["payload"])
        let error = await failure { () async throws(GuestAgentError) in try await agent.stageFiles([name: input]) }
        #expect(error == .guest(.invalidInputName))
        #expect(fake.state.withLock { $0.processes.isEmpty })
    }

    @Test func nonFileAndDirectorySourcesAreRefused() async throws {
        let (_, directory) = try makeInputs([:])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = Self.stagingGuest()
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let remote = try #require(URL(string: "https://example.com/x"))
        let notFile = await failure { () async throws(GuestAgentError) in try await agent.stageFiles(["x": remote]) }
        let folder = await failure { () async throws(GuestAgentError) in try await agent.stageFiles(["x": directory]) }
        #expect(notFile == .guest(.invalidInputName))
        #expect(folder == .guest(.inputNotRegularFile))
    }

    @Test func tooManyOrNoFilesAreRefused() async throws {
        let agent = GuestAgent(socketPath: "/nonexistent/agent")
        defer { agent.close() }
        let url = URL(fileURLWithPath: "/nonexistent")
        let many = Dictionary(uniqueKeysWithValues: (0..<17).map { ("f\($0)", url) })
        let tooMany = await failure { () async throws(GuestAgentError) in try await agent.stageFiles(many) }
        let none = await failure { () async throws(GuestAgentError) in try await agent.stageFiles([:]) }
        #expect(tooMany == .guest(.transferUnavailable))
        #expect(none == .guest(.transferUnavailable))
    }

    @Test func anUnexpectedTransferDirectoryIsNeverWrittenTo() async throws {
        let (urls, directory) = try makeInputs(["payload": 1])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = Self.stagingGuest(mktemp: "/tmp/VirtualIntelMac.abc123\n")
        defer { fake.stop() }
        let agent = try await connected(to: fake)
        defer { agent.close() }
        let error = await failure { () async throws(GuestAgentError) in try await agent.stageFiles(urls) }
        #expect(error == .guest(.transferDirectoryNotCreated))
        #expect(fake.state.withLock { $0.files.isEmpty })
    }
}
