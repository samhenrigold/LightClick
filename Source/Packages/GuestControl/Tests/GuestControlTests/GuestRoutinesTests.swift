import Foundation
import Testing

@testable import GuestControl

private let setupDiscPolicy = """
    <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>\
    <key>MachineIdentifier</key><string>m</string><key>VolumeUUID</key><string>v</string></dict></plist>
    """

@MainActor
struct GuestRoutinesTests {
    private func withAgent(
        outcomes: @escaping @Sendable (FakeGuestAgent.Process) -> FakeGuestAgent.Outcome,
        _ body: (GuestAgentBridge, FakeGuestAgent) async throws -> Void
    ) async rethrows {
        let fake = FakeGuestAgent(outcomes: outcomes)
        defer { fake.stop() }
        let agent = GuestAgentBridge(socketPath: fake.path)
        defer { agent.close() }
        try await body(agent, fake)
    }

    private func remoteLogin(_ agent: GuestAgentBridge) async -> String? {
        await withCheckedContinuation { continuation in
            agent.enableRemoteLogin { continuation.resume(returning: $0?.localizedDescription) }
        }
    }

    @Test func remoteLoginIsCheckedAfterBeingSet() async {
        await withAgent(outcomes: { process in
            process.arguments.contains("-getremotelogin")
                ? .finished(exitCode: 0, output: "Remote Login: On\n") : .finished(exitCode: 0)
        }) { agent, fake in
            #expect(await remoteLogin(agent) == nil)
            #expect(
                fake.state.withLock { $0.processes.map(\.arguments) } == [
                    ["-setremotelogin", "on"], ["-getremotelogin"]
                ])
        }
    }

    @Test func remoteLoginStillOffIsAFailure() async {
        await withAgent(outcomes: { process in
            process.arguments.contains("-getremotelogin")
                ? .finished(exitCode: 0, output: "You need administrator access\nRemote Login: Off\n")
                : .finished(exitCode: 0)
        }) { agent, _ in
            #expect(await remoteLogin(agent)?.hasPrefix("Remote Login is still off") == true)
        }
    }

    @Test func aRefusedRemoteLoginStopsThere() async {
        await withAgent(outcomes: { _ in .finished(exitCode: 1) }) { agent, fake in
            #expect(await remoteLogin(agent)?.hasPrefix("macOS could not enable") == true)
            #expect(fake.state.withLock { $0.processes.count } == 1)
        }
    }

    private func screenSharing(_ agent: GuestAgentBridge, enabling: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            agent.applyScreenSharing(steps: [["/a", "1"], ["/b"]], enabling: enabling) {
                continuation.resume(returning: $0?.localizedDescription)
            }
        }
    }

    @Test func theLastScreenSharingStepSaysWhetherItIsOn() async {
        await withAgent(outcomes: { $0.path == "/b" ? .finished(exitCode: 0) : .finished(exitCode: 1) }) {
            agent, fake in
            #expect(await screenSharing(agent, enabling: true) == nil)
            #expect(await screenSharing(agent, enabling: false)?.hasPrefix("Screen Sharing is still on") == true)
            #expect(fake.state.withLock { $0.processes.first?.arguments } == ["1"])
        }
        await withAgent(outcomes: { _ in .finished(exitCode: 1) }) { agent, _ in
            #expect(await screenSharing(agent, enabling: false) == nil)
            #expect(await screenSharing(agent, enabling: true)?.hasPrefix("Screen Sharing is still off") == true)
        }
    }

    @Test func theSetupDiscRetiresOnlyWithMatchingIdentityAndGoodPixels() {
        let owner: [String: Any] = ["MachineIdentifier": "m", "VolumeUUID": "v"]
        let good: [String: Any] = ["VolumeUUID": "v", "PixelChecksPassed": true]
        let mayRetire = GuestAgentBridge.setupDiscMayRetire
        #expect(mayRetire(owner, "m", good))
        #expect(!mayRetire(nil, "m", good))
        #expect(!mayRetire(owner, nil, good))
        #expect(!mayRetire(owner, "x", good))
        #expect(!mayRetire(owner, "m", nil))
        #expect(!mayRetire(owner, "m", ["VolumeUUID": "other", "PixelChecksPassed": true]))
        #expect(!mayRetire(owner, "m", ["VolumeUUID": "v", "PixelChecksPassed": false]))
        #expect(!mayRetire(owner, "m", ["VolumeUUID": "v"]))
        #expect(!mayRetire(["MachineIdentifier": "m"], "m", ["PixelChecksPassed": true]))
    }

    private func retire(_ agent: GuestAgentBridge, _ control: ScriptedControl) async {
        // The session's agent is connected by the time setup finishes.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            agent.connect { _ in continuation.resume() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            agent.retireSetupDisc(
                owner: ["MachineIdentifier": "m", "VolumeUUID": "v"], machineIdentifier: "m",
                report: ["VolumeUUID": "v", "PixelChecksPassed": true], commands: control
            ) { continuation.resume() }
        }
    }

    @Test func aMatchingDiscEjectsInTheGuestAndThenTheEmulator() async {
        let control = ScriptedControl()
        await withAgent(outcomes: { process in
            process.path == "/usr/bin/plutil" ? .finished(exitCode: 0, output: setupDiscPolicy) : .finished(exitCode: 0)
        }) { agent, fake in
            await retire(agent, control)
            #expect(fake.state.withLock { $0.processes.map(\.path) } == ["/usr/bin/plutil", "/usr/sbin/diskutil"])
            #expect(control.commands == ["eject"])
            #expect(control.sent[0].arguments["id"] as? String == "opengl-setup-device")
        }
    }

    @Test func aHelpersFailureNamesItsStepAndExit() {
        #expect(GuestAgentBridge.helperFailure("setup", code: 0, failed: false) == nil)
        #expect(GuestAgentBridge.helperFailure("setup", code: 3, failed: false) == "setup (exit 3)")
        #expect(GuestAgentBridge.helperFailure("setup", code: nil, failed: true) == "setup")
        #expect(GuestAgentBridge.helperFailure("setup", code: nil, failed: false) == "setup")
    }

    private func provision(_ agent: GuestAgentBridge, wanted: Bool = true) async throws -> String? {
        let directory = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let helper = URL(fileURLWithPath: directory + "/guest-clipboard")
        let settings = URL(fileURLWithPath: directory + "/Clipboard.json")
        try Data("h".utf8).write(to: helper)
        try Data("{}".utf8).write(to: settings)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            agent.connect { _ in continuation.resume() }
        }
        return await withCheckedContinuation { continuation in
            agent.provisionHelper(helper, configuration: settings, named: "Clipboard.json", stillWanted: { wanted }) {
                continuation.resume(returning: $0)
            }
        }
    }

    /// What a guest answers to staging, then `rest` for the helper's own steps.
    private static func stagingOutcome(
        _ rest: @escaping @Sendable (FakeGuestAgent.Process) -> FakeGuestAgent.Outcome = { _ in .finished(exitCode: 0) }
    ) -> @Sendable (FakeGuestAgent.Process) -> FakeGuestAgent.Outcome {
        { process in
            switch process.path {
            case "/usr/bin/mktemp": .finished(exitCode: 0, output: "/private/var/tmp/VirtualIntelMac.abc123\n")
            case "/bin/sh": .finished(exitCode: 0, output: "0\n")
            default: rest(process)
            }
        }
    }

    @Test func aHelperRunsOnlyOnceItsFilesAreSecured() async throws {
        try await withAgent(outcomes: Self.stagingOutcome()) { agent, fake in
            let failure = try await provision(agent)
            #expect(failure == nil)
            let run = fake.state.withLock { $0.processes.map { [$0.path] + $0.arguments } }
            let tail = Array(run.suffix(3))
            #expect(tail[0] == ["/bin/chmod", "0700", "/private/var/tmp/VirtualIntelMac.abc123/guest-clipboard"])
            #expect(tail[1] == ["/bin/chmod", "0600", "/private/var/tmp/VirtualIntelMac.abc123/Clipboard.json"])
            #expect(tail[2].first?.hasSuffix("guest-clipboard") == true)
            #expect(tail[2].dropFirst().first == "--provision")
        }
    }

    @Test func aHelperNoLongerWantedStopsAfterTheTransfer() async throws {
        try await withAgent(outcomes: Self.stagingOutcome()) { agent, fake in
            let failure = try await provision(agent, wanted: false)
            #expect(failure == "transfer")
            #expect(fake.state.withLock { $0.processes.contains { $0.arguments.first == "--provision" } } == false)
        }
    }

    @Test func aFailedChmodNamesItsStep() async throws {
        try await withAgent(
            outcomes: Self.stagingOutcome {
                $0.arguments == ["0700", "/private/var/tmp/VirtualIntelMac.abc123/guest-clipboard"]
                    ? .finished(exitCode: 1) : .finished(exitCode: 0)
            }
        ) { agent, _ in
            let failure = try await provision(agent)
            #expect(failure == "executable preparation")
        }
    }

    @Test func aFailedHelperReportsItsExit() async throws {
        try await withAgent(
            outcomes: Self.stagingOutcome {
                $0.arguments.first == "--provision" ? .finished(exitCode: 7) : .finished(exitCode: 0)
            }
        ) { agent, _ in
            let failure = try await provision(agent)
            #expect(failure == "GUI helper setup (exit 7)")
        }
    }

    @Test func anEmulatedVolumeIsOneTheEmulatorMounted() {
        #expect(GuestAgentBridge.isEmulatedVolume(["MountPoint": "/V", "MediaName": "QEMU HARDDISK"], at: "/V"))
        #expect(!GuestAgentBridge.isEmulatedVolume(["MountPoint": "/V", "MediaName": "SanDisk"], at: "/V"))
        #expect(!GuestAgentBridge.isEmulatedVolume(["MountPoint": "/W", "MediaName": "QEMU"], at: "/V"))
        #expect(!GuestAgentBridge.isEmulatedVolume(["MountPoint": "/V"], at: "/V"))
        #expect(!GuestAgentBridge.isEmulatedVolume(nil, at: "/V"))
    }
}
