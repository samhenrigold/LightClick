import Foundation
import Testing

@testable import GuestControl

private let directory = "/private/var/tmp/VirtualIntelMacUI.abc123"
private let staging = "/private/var/db/VirtualIntelMac.test"
private let tool = staging + "/guest-progress"

@MainActor
@Suite struct GuestProgressTests {
    private func withAgent(
        outcomes: @escaping @Sendable (FakeGuestAgent.Process) -> FakeGuestAgent.Outcome,
        _ body: (GuestAgentBridge, FakeGuestAgent) async -> Void
    ) async {
        let fake = FakeGuestAgent(outcomes: outcomes)
        defer { fake.stop() }
        let agent = GuestAgentBridge(socketPath: fake.path)
        defer { agent.close() }
        await withCheckedContinuation { continuation in
            agent.connect { _ in continuation.resume() }
        }
        await body(agent, fake)
    }

    private func started(_ agent: GuestAgentBridge) async -> (GuestProgress?, String?) {
        await withCheckedContinuation { continuation in
            GuestProgress.start(agent: agent, staging: staging) { progress, error in
                continuation.resume(returning: (progress, error?.localizedDescription))
            }
        }
    }

    @Test(arguments: [
        (directory, tool, true),
        (directory, "/private/var/tmp/VirtualIntelMac.x/guest-progress", true),
        ("/tmp/VirtualIntelMacUI.abc123", tool, false),
        ("/private/var/tmp/VirtualIntelMacUI.abc", tool, false),
        (directory, "/usr/bin/guest-progress", false),
        (directory, staging + "/other", false),
        (directory, staging + "/../guest-progress", false),
        (directory, staging + "/deeper/guest-progress", false)
    ])
    func receiptsAreCheckedBeforeTheyreRun(directory: String, tool: String, valid: Bool) {
        #expect(GuestProgress.isValid(directory: directory, tool: tool) == valid)
    }

    @Test func startingRunsTheToolAndKeepsItsReceipt() async {
        await withAgent(outcomes: { process in
            process.arguments.first == "--start"
                ? .finished(exitCode: 0, output: #"{"Directory":"\#(directory)"}"#) : .finished(exitCode: 0)
        }) { agent, fake in
            let (progress, message) = await started(agent)
            #expect(message == nil)
            #expect(progress?.receipt["Tool"] as? String == tool)
            #expect(progress?.receipt["Directory"] as? String == directory)
            #expect(fake.state.withLock { $0.processes.map(\.path) } == ["/bin/chmod", tool])
        }
    }

    @Test func aToolThatCantStartIsAFailure() async {
        await withAgent(outcomes: { process in
            process.path == "/bin/chmod" ? .finished(exitCode: 1) : .finished(exitCode: 0)
        }) { agent, fake in
            let (progress, message) = await started(agent)
            #expect(progress == nil)
            #expect(message == "Could not prepare the guest setup window.")
            #expect(fake.state.withLock { $0.processes.count } == 1)
        }
        await withAgent(outcomes: { _ in .finished(exitCode: 0, output: "{}") }) { agent, _ in
            let (progress, message) = await started(agent)
            #expect(progress == nil)
            #expect(message == "The guest setup window could not open. Nothing was installed.")
        }
    }

    @Test func updatesNeedAnAcknowledgement() async {
        await withAgent(outcomes: { process in
            .finished(exitCode: 0, output: process.arguments.contains("working") ? #"{"Updated":true}"# : "{}")
        }) { agent, fake in
            let progress = GuestProgress.progress(agent: agent, receipt: ["Directory": directory, "Tool": tool])
            let answer: (String, Double) async -> String? = { mode, fraction in
                await withCheckedContinuation { continuation in
                    progress?.update(mode: mode, fraction: fraction, message: "Hi") {
                        continuation.resume(returning: $0?.localizedDescription)
                    }
                }
            }
            #expect(await answer("working", 0.12) == nil)
            #expect(await answer("failed", -1) == "The guest setup window did not acknowledge its status.")
            #expect(
                fake.state.withLock { $0.processes.map(\.arguments) } == [
                    ["--update", directory, "working", "0.12", "Hi"], ["--update", directory, "failed", "-1", "Hi"]
                ])
        }
    }

    @Test func aRestartChoiceMustBeOneOfTheTwo() async {
        await withAgent(outcomes: { _ in .finished(exitCode: 0, output: #"{"Action":"restart"}"#) }) { agent, _ in
            let progress = GuestProgress.progress(agent: agent, receipt: ["Directory": directory, "Tool": tool])
            let choice: String? = await withCheckedContinuation { continuation in
                progress?.waitForRestartChoice { choice, _ in continuation.resume(returning: choice) }
            }
            #expect(choice == "restart")
        }
        await withAgent(outcomes: { _ in .finished(exitCode: 0, output: #"{"Action":"format"}"#) }) { agent, _ in
            let progress = GuestProgress.progress(agent: agent, receipt: ["Directory": directory, "Tool": tool])
            let message: String? = await withCheckedContinuation { continuation in
                progress?.waitForRestartChoice { _, error in continuation.resume(returning: error?.localizedDescription)
                }
            }
            #expect(message?.hasPrefix("The guest restart choice") == true)
        }
    }
}
