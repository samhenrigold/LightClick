import Foundation
import Testing

@testable import GuestControl

private struct Reply: @unchecked Sendable {
    let values: [String: Any]
}

@MainActor
struct SessionDiagnosticsTests {
    private let control = ScriptedControl()
    private let directory: String

    init() throws {
        directory = NSTemporaryDirectory() + "diagnostics-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private var diagnostics: SessionDiagnostics {
        SessionDiagnostics(
            directory: directory, control: control, agent: GuestAgentBridge(socketPath: "/nonexistent/agent"),
            statusTool: nil, memoryMiB: 4096)
    }

    private func answer(_ command: [String: Any]) async -> [String: Any] {
        let diagnostics = diagnostics
        return await answer(command, from: diagnostics)
    }

    private func answer(_ command: [String: Any], from diagnostics: SessionDiagnostics) async -> [String: Any] {
        let reply: Reply = await withCheckedContinuation { continuation in
            diagnostics.handle(command) { continuation.resume(returning: Reply(values: $0)) }
        }
        return reply.values
    }

    private func write(_ text: String, to name: String, mode: Int = 0o600) throws -> String {
        let path = (directory as NSString).appendingPathComponent(name)
        try text.write(toFile: path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return path
    }

    // MARK: - Requests

    @Test func aRequestMovesAsideAndItsResultReplacesIt() throws {
        let diagnostics = diagnostics
        let request = try write(#"{"Action":"capture"}"#, to: "Request.json")
        let command = try #require(diagnostics.takeRequest(whileAgentBusy: false))
        #expect(command["Action"] as? String == "capture")
        #expect(!FileManager.default.fileExists(atPath: request))
        let running = (directory as NSString).appendingPathComponent("Running.json")
        #expect(FileManager.default.fileExists(atPath: running))
        diagnostics.writeResult(["Captured": true, "Count": 2])
        #expect(!FileManager.default.fileExists(atPath: running))
        let data = try #require(
            FileManager.default.contents(atPath: (directory as NSString).appendingPathComponent("Result.json")))
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(result?["Captured"] as? Bool == true)
        #expect(result?["Count"] as? Int == 2)
    }

    @Test func aBusyAgentHoldsOnlyWhatNeedsIt() throws {
        let diagnostics = diagnostics
        _ = try write(#"{"Executable":"/bin/ls","Arguments":[]}"#, to: "Request.json")
        #expect(diagnostics.takeRequest(whileAgentBusy: true) == nil)
        #expect(diagnostics.takeRequest(whileAgentBusy: false) != nil)
        _ = try write(#"{"Action":"guest-processes"}"#, to: "Request.json")
        #expect(diagnostics.takeRequest(whileAgentBusy: true) != nil)
    }

    @Test func unusableRequestsStay() throws {
        let diagnostics = diagnostics
        let request = try write("[1]", to: "Request.json")
        #expect(diagnostics.takeRequest(whileAgentBusy: false) == nil)
        try FileManager.default.removeItem(atPath: request)
        #expect(diagnostics.takeRequest(whileAgentBusy: false) == nil)
        let target = try write("{}", to: "target")
        try FileManager.default.createSymbolicLink(atPath: request, withDestinationPath: target)
        #expect(diagnostics.takeRequest(whileAgentBusy: false) == nil)
        try FileManager.default.removeItem(atPath: request)
        _ = try write(String(repeating: " ", count: 65537) + "{}", to: "Request.json")
        #expect(diagnostics.takeRequest(whileAgentBusy: false) == nil)
    }

    @Test func aNamedDirectoryServesOnlyTheSelectedMachine() {
        let arguments = ["app", "--open-vm", "/a/b.vintelmac", "--guest-diagnostics", "/tmp/d"]
        #expect(
            SessionDiagnostics.directory(for: arguments, machinePath: "/a/b.vintelmac", identifier: nil) == "/tmp/d")
        #expect(SessionDiagnostics.directory(for: arguments, machinePath: "/a/c.vintelmac", identifier: nil) == nil)
        #expect(
            SessionDiagnostics.directory(
                for: ["app", "--open-vm", "/a/b.vintelmac"], machinePath: "/a/b.vintelmac", identifier: nil) == nil)
        #expect(
            SessionDiagnostics.directory(
                for: ["app", "--open-vm", "/a/b.vintelmac", "--guest-diagnostics", "rel"],
                machinePath: "/a/b.vintelmac", identifier: nil) == nil)
    }

    @Test func aRootGivesEachMachineAPrivateDirectory() throws {
        let identifier = "11111111-2222-3333-4444-555555555555"
        let root = (directory as NSString).appendingPathComponent("root")
        let served = SessionDiagnostics.directory(
            for: ["app", "--guest-diagnostics-root", root], machinePath: "/a", identifier: identifier.lowercased())
        #expect(served == root + "/" + identifier)
        let attributes = try FileManager.default.attributesOfItem(atPath: try #require(served))
        #expect(attributes[.posixPermissions] as? Int == 0o700)
        #expect(
            SessionDiagnostics.directory(
                for: ["app", "--guest-diagnostics-root", root], machinePath: "/a", identifier: "nope") == nil)
        #expect(
            SessionDiagnostics.directory(
                for: ["app", "--guest-diagnostics-root", "rel"], machinePath: "/a", identifier: identifier) == nil)
        let open = (directory as NSString).appendingPathComponent("open")
        try FileManager.default.createDirectory(
            atPath: open, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        #expect(
            SessionDiagnostics.directory(
                for: ["app", "--guest-diagnostics-root", open], machinePath: "/a", identifier: identifier) == nil)
    }

    // MARK: - Hardware reports

    @Test(arguments: [
        (["Component": "memory-map"], "info mtree -f"), (["Component": "devices"], "info qtree"),
        (["Component": "registers"], "info registers -a")
    ])
    func monitorReports(command: [String: String], line: String) async {
        var request: [String: Any] = command
        request["Action"] = "inspect-hardware"
        control.replies = [("human-monitor-command", .success("report"))]
        let reply = await answer(request)
        #expect(reply["Report"] as? String == "report")
        #expect(control.sent[0].arguments["command-line"] as? String == line)
    }

    @Test func queryReportsAndUnknownComponents() async {
        control.replies = [("query-pci", .success(["bus"]))]
        let reply = await answer(["Action": "inspect-hardware", "Component": "pci"])
        #expect(reply["Report"] as? [String] == ["bus"])
        let unknown = await answer(["Action": "inspect-hardware", "Component": "nope"])
        #expect((unknown["Error"] as? String)?.hasPrefix("Choose cpu") == true)
        #expect(control.commands == ["query-pci"])
    }

    @Test func serialReadsOnlyConfigurationRegisters() async {
        let reply = await answer(["Action": "inspect-hardware", "Component": "serial"])
        #expect((reply["Registers"] as? [[String: Any]])?.count == 6)
        #expect(control.sent.first?.arguments["command-line"] as? String == "i /b 0x3f9")
        #expect(control.sent.last?.arguments["command-line"] as? String == "i /b 0x2fc")
    }

    @Test func serialStopsAtTheFirstFailure() async {
        control.replies = [
            (
                "human-monitor-command",
                .failure(NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "gone"]))
            )
        ]
        let reply = await answer(["Action": "inspect-hardware", "Component": "serial"])
        #expect(reply["Error"] as? String == "gone")
        #expect(control.sent.count == 1)
    }

    @Test func memoryReadsStayInBounds() {
        func read(_ component: String, _ address: Any?, _ words: Any?) -> String? {
            SessionDiagnostics.memoryRead(component: component, address: address, words: words, memoryMiB: 4096)
        }
        #expect(read("physical-memory", 0x1000, 2) == "xp /2gx 0x1000")
        #expect(read("physical-memory", UInt64(4096) << 20 - 8, 1) == "xp /1gx 0xfffffff8")
        #expect(read("physical-memory", UInt64(4096) << 20, 1) == nil)
        #expect(read("physical-memory", -1, 1) == nil)
        #expect(read("physical-memory", 0, 0) == nil)
        #expect(read("physical-memory", 0, 65) == nil)
        #expect(read("physical-memory", "0", 1) == nil)
        #expect(read("physical-memory", nil, 1) == nil)
        #expect(read("kernel-memory", 0x1000, 1) == nil)
        #expect(read("kernel-memory", NSNumber(value: UInt64(0xffff_ff80_0000_0000)), 1) == "x /1gx 0xffffff8000000000")
        #expect(read("kernel-memory", NSNumber(value: UInt64.max), 1) == nil)
    }

    @Test func phyAndLinkHistoryReadTheNIC() async {
        control.replies = [("qom-get", .success("state"))]
        let reply = await answer(["Action": "inspect-hardware", "Component": "link-history"])
        #expect(reply["Report"] as? String == "state")
        #expect(control.sent[0].arguments["property"] as? String == "x-link-history")
    }

    // MARK: - Traces

    @Test func stoppingAUSBTraceClearsTheLogMask() async {
        let reply = await answer(["Action": "trace-usb", "Enabled": false])
        #expect(reply["Enabled"] as? Bool == false)
        #expect(control.commands == Array(repeating: "trace-event-set-state", count: 3) + ["human-monitor-command"])
        #expect(control.sent.last?.arguments["command-line"] as? String == "log none")
    }

    @Test func aFailedTraceEventStillSetsTheOthersAndReportsIt() async {
        control.replies = [
            (
                "trace-event-set-state",
                .failure(NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "no"]))
            )
        ]
        let reply = await answer(["Action": "trace-audio-gaps", "Enabled": false])
        #expect(reply["Error"] as? String == "no")
        #expect(control.sent.count == 4)
    }

    @Test func soundTraceChoosesItsEvent() async {
        _ = await answer(["Action": "trace-sound-mix", "Enabled": true])
        _ = await answer(["Action": "trace-sound", "Enabled": false])
        #expect(control.sent[0].arguments["name"] as? String == "audio_sw_write")
        #expect(control.sent[1].arguments["name"] as? String == "virtio_snd_handle_code")
    }

    // MARK: - Guest commands

    @Test func guestCommandsCheckTheirRequest() async {
        #expect(await answer(["Executable": "rel", "Arguments": []])["Error"] as? String == "Invalid command")
        #expect(await answer(["Executable": "/bin/ls"])["Error"] as? String == "Invalid command")
        #expect(await answer([:])["Error"] as? String == "Invalid command")
        #expect(await answer(["Executable": "/bin/ls", "Arguments": [1]])["Error"] as? String == "Invalid argument")
        #expect(
            await answer(["Executable": "/bin/ls", "Arguments": [], "PrivateInput": "x"])["Error"] as? String
                == "Invalid private input")
        #expect(
            await answer(["Executable": "/bin/ls", "Arguments": [], "PrivateInput": "Input.bin"])["Error"] as? String
                == "Private input could not be consumed safely")
        #expect(
            await answer(["Action": "guest-process-sample", "PID": 1])["Error"] as? String
                == "Choose a guest process identifier greater than one.")
    }

    @Test func aGoneAgentReportsItsError() async {
        #expect(await answer(["Action": "guest-processes"])["Error"] != nil)
        #expect(await answer(["Action": "installer-log"])["Error"] != nil)
    }

    @Test func aProcessAnswersThroughTheAgent() async throws {
        let fake = FakeGuestAgent { _ in .finished(exitCode: 3, output: "hello") }
        let agent = GuestAgentBridge(socketPath: fake.path)
        let diagnostics = SessionDiagnostics(
            directory: directory, control: control, agent: agent, statusTool: nil, memoryMiB: 1)
        let reply = await answer(["Executable": "/bin/echo", "Arguments": ["a"]], from: diagnostics)
        #expect(reply["ExitCode"] as? Int == 3)
        #expect(reply["Stdout"] as? String == "hello")
        #expect(reply["Stderr"] as? String == "")
        agent.close()
    }

    @Test func aLogTailMayStartInsideACharacter() {
        #expect(SessionDiagnostics.tailText(Data([0xa9, 0x41])) == "A")
        #expect(SessionDiagnostics.tailText(Data([0x41, 0xc3, 0xa9])) == "Aé")
        #expect(SessionDiagnostics.tailText(Data([0xe9, 0x41])) == "éA")
        #expect(SessionDiagnostics.tailText(Data()) == "")
    }

    // MARK: - Private input

    @Test func privateInputIsConsumedOnce() throws {
        let path = try write("secret", to: "Input.bin")
        #expect(SessionDiagnostics.consumePrivateInput(atPath: path) == Data("secret".utf8))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(SessionDiagnostics.consumePrivateInput(atPath: path) == nil)
    }

    @Test func unsafePrivateInputIsRefusedAndLeft() throws {
        let readable = try write("secret", to: "Input.bin", mode: 0o644)
        #expect(SessionDiagnostics.consumePrivateInput(atPath: readable) == nil)
        #expect(FileManager.default.fileExists(atPath: readable))
        try FileManager.default.removeItem(atPath: readable)

        let target = try write("secret", to: "target")
        try FileManager.default.createSymbolicLink(atPath: readable, withDestinationPath: target)
        #expect(SessionDiagnostics.consumePrivateInput(atPath: readable) == nil)
        #expect(FileManager.default.fileExists(atPath: target))
        try FileManager.default.removeItem(atPath: readable)

        let big = try write(String(repeating: "x", count: 16385), to: "Input.bin")
        #expect(SessionDiagnostics.consumePrivateInput(atPath: big) == nil)
        try FileManager.default.removeItem(atPath: big)

        let linked = try write("secret", to: "Input.bin")
        try FileManager.default.linkItem(atPath: linked, toPath: linked + ".2")
        #expect(SessionDiagnostics.consumePrivateInput(atPath: linked) == nil)
    }
}
