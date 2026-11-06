import Foundation
import Testing

@testable import MachineKit

@MainActor
private final class FakeTransport: GuestHelperTransport {
    let token = UUID().uuidString
    var isConnected = false
    var failsToStart = false
    var stops = 0
    var handshakes = 0
    var starts: [String] = []
    var lost: (@MainActor (any GuestHelperTransport) -> Void)?

    struct Refused: Error {}

    func start(withSocketPath path: String) throws {
        starts.append(path)
        if failsToStart { throw Refused() }
    }
    func awaitGuestHandshake() { handshakes += 1 }
    func stop() { stops += 1 }
}

@MainActor
private final class FakeHost: GuestHelperHost {
    var isRunning = true
    let sessionState = GuestSessionStateBridge()
    let runtimeDirectory: String
    var isPreMetalGuest = false
    var isClipboardAllowedBySettings = true
    var acceptsDisplayPowerRequests = true
    var nextFailsToStart = false
    var transports: [FakeTransport] = []
    var provisions: [(kind: GuestHelperKind, data: Data, file: URL, wanted: () -> Bool, done: (String?) -> Void)] = []
    var events: [String] = []
    var logged: [String] = []

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        runtimeDirectory = directory.path
        sessionState.state.running = true
        sessionState.consoleUID = 501
    }

    func makeTransport(
        _ kind: GuestHelperKind, connectionLost: @escaping @MainActor (any GuestHelperTransport) -> Void
    ) -> any GuestHelperTransport {
        let transport = FakeTransport()
        transport.failsToStart = nextFailsToStart
        transport.lost = connectionLost
        transports.append(transport)
        return transport
    }

    func provision(
        _ kind: GuestHelperKind, configuration: Data, file: URL, stillWanted: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        provisions.append((kind, configuration, file, stillWanted, completion))
    }

    func displayObserverWentAway() { events.append("observer gone") }
    func refreshGuestStatus() { events.append("refresh") }
    func restoreDisplaySelection(boot: String) { events.append("restore \(boot)") }
    func log(_ message: String) { logged.append(message) }
}

@MainActor
@Suite struct GuestHelperLinksTests {
    private func make() throws -> (GuestHelperLinks, FakeHost) {
        let host = try FakeHost()
        return (GuestHelperLinks(host: host), host)
    }

    @Test func aProvisionedHelperIsNotProvisionedAgainThisBoot() throws {
        let (links, host) = try make()
        links.update(.clipboard, boot: "b")
        #expect(host.provisions.count == 1)
        #expect(host.transports[0].starts == [host.runtimeDirectory + "/clipboard"])
        #expect(host.sessionState.clipboardPending)
        host.provisions[0].done(nil)
        #expect(!host.sessionState.clipboardPending)
        #expect(host.transports[0].handshakes == 1)
        #expect(host.events == ["restore b"])
        host.transports[0].isConnected = true
        links.update(.clipboard, boot: "b")
        #expect(host.provisions.count == 1)
    }

    @Test func aFinishedDisplayObserverLetsTheClipboardGoNext() throws {
        let (links, host) = try make()
        links.update(.displayPower, boot: "b")
        #expect(host.transports[0].starts == [host.runtimeDirectory + "/displaypower"])
        host.provisions[0].done(nil)
        #expect(host.provisions.count == 2)
        #expect(host.provisions[1].kind == .clipboard)
    }

    @Test func aConfigurationIsPrivateAndNamesItsChannel() throws {
        let (links, host) = try make()
        host.isPreMetalGuest = true
        links.update(.clipboard, boot: "b")
        let file = host.provisions[0].file
        #expect(file.lastPathComponent == "Clipboard.json")
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(saved["UID"] as? Int == 501)
        #expect(saved["Transport"] as? String == "isa-serial")
        #expect(saved["Token"] as? String == host.transports[0].token)
        #expect(saved["DisplayPowerOnly"] as? Bool == false)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode == 0o600)
    }

    @Test func aDisplayObserverNeedsNoConsoleUser() throws {
        let (links, host) = try make()
        host.sessionState.consoleUID = nil
        links.update(.clipboard, boot: "b")
        #expect(host.provisions.isEmpty)
        links.update(.displayPower, boot: "b")
        #expect(host.provisions.count == 1)
        let saved = try JSONSerialization.jsonObject(with: host.provisions[0].data) as? [String: Any]
        #expect(saved?["UID"] as? Int == 0)
    }

    @Test func noPowerRequestsGoToTheInstallerDisplay() throws {
        let (links, host) = try make()
        host.acceptsDisplayPowerRequests = false
        links.update(.displayPower, boot: "b")
        #expect(host.transports.isEmpty)
    }

    @Test func noBootMeansNothingHappens() throws {
        let (links, host) = try make()
        links.update(.clipboard, boot: nil)
        links.update(.clipboard, boot: "")
        #expect(host.transports.isEmpty)
    }

    @Test func clipboardOffStopsItAndClearsItsRetry() throws {
        let (links, host) = try make()
        links.update(.clipboard, boot: "b")
        #expect(links.clipboardSharingEnabled)
        host.isClipboardAllowedBySettings = false
        links.update(.clipboard, boot: "b")
        #expect(!links.clipboardSharingEnabled)
        #expect(host.transports[0].stops == 1)
        #expect(links.transport(.clipboard) == nil)
        host.provisions[0].done(nil)
        host.isClipboardAllowedBySettings = true
        links.update(.clipboard, boot: "b")
        #expect(host.transports.count == 2, "No minute's wait after being turned back on.")
    }

    @Test func aFailedStartWaitsAMinute() throws {
        let (links, host) = try make()
        host.nextFailsToStart = true
        links.update(.clipboard, boot: "b")
        #expect(host.transports[0].stops == 1)
        #expect(links.transport(.clipboard) == nil)
        #expect(host.provisions.isEmpty)
        host.nextFailsToStart = false
        links.update(.clipboard, boot: "b")
        #expect(host.transports.count == 1)
    }

    @Test func aFailedProvisioningIsLoggedOnceAndWaits() throws {
        let (links, host) = try make()
        links.update(.clipboard, boot: "b")
        host.provisions[0].done("transfer")
        #expect(host.logged == ["Guest clipboard transfer did not finish."])
        #expect(links.clipboardFailure == "Guest clipboard transfer did not finish.")
        #expect(host.transports[0].stops == 1)
        links.update(.clipboard, boot: "b")
        #expect(host.provisions.count == 1, "Still within the minute.")
    }

    @Test func onlyOneProvisioningRunsAtATime() throws {
        let (links, host) = try make()
        links.update(.displayPower, boot: "b")
        links.update(.clipboard, boot: "b")
        #expect(host.provisions.count == 1)
    }

    @Test func anOldProvisioningsAnswerIsIgnored() throws {
        let (links, host) = try make()
        links.update(.clipboard, boot: "b")
        let old = host.provisions[0]
        links.forgetClipboard()
        #expect(!old.wanted())
        old.done(nil)
        #expect(host.events.isEmpty)
        #expect(host.transports[0].handshakes == 0)
        #expect(!host.sessionState.clipboardPending)
    }

    @Test func aStoppedMachineNoLongerWantsAHelper() throws {
        let (links, host) = try make()
        links.update(.displayPower, boot: "b")
        #expect(host.provisions[0].wanted())
        host.isRunning = false
        #expect(!host.provisions[0].wanted())
    }

    @Test func losingTheClipboardForgetsTheConsoleUser() throws {
        let (links, host) = try make()
        host.sessionState.usernameBoot = "b"
        links.update(.clipboard, boot: "b")
        let transport = host.transports[0]
        transport.lost?(transport)
        #expect(transport.stops == 1)
        #expect(links.transport(.clipboard) == nil)
        #expect(host.sessionState.consoleUID == nil && host.sessionState.usernameBoot == nil)
        #expect(host.events == ["refresh"])
    }

    @Test func losingTheDisplayObserverWakesTheDisplayAndKeepsTheUser() throws {
        let (links, host) = try make()
        links.update(.displayPower, boot: "b")
        let transport = host.transports[0]
        transport.lost?(transport)
        #expect(host.events == ["observer gone", "refresh"])
        #expect(host.sessionState.consoleUID == 501)
    }

    @Test func aLossFromAReplacedOrStoppedTransportIsIgnored() throws {
        let (links, host) = try make()
        links.update(.clipboard, boot: "b")
        let old = host.transports[0]
        links.forgetClipboard()
        host.provisions[0].done(nil)
        links.update(.clipboard, boot: "b")
        old.lost?(old)
        #expect(host.events.isEmpty)

        let current = host.transports[1]
        host.isRunning = false
        current.lost?(current)
        #expect(links.transport(.clipboard) != nil)
    }

    @Test func stoppingEndsBothAndKeepsOnlyTheClipboardsRetry() throws {
        let (links, host) = try make()
        links.update(.displayPower, boot: "b")
        host.provisions[0].done(nil)
        #expect(host.transports.count == 2)
        links.stop()
        #expect(host.transports.allSatisfy { $0.stops == 1 })
        #expect(!host.sessionState.clipboardPending)
        links.update(.displayPower, boot: "b")
        host.provisions[2].done(nil)
        #expect(host.transports.count == 3, "The display observer goes again at once, the clipboard after its minute.")
    }
}
