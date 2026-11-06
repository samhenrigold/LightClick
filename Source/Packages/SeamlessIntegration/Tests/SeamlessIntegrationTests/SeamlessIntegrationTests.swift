import AppKit
import Foundation
import Testing

@testable import SeamlessIntegration

/// The session is Objective-C and writes these by hand, so what it writes has to decode here.
@Test func sessionCommandsDecodeAsTheSessionWritesThem() throws {
    func decode(_ json: String) throws -> SessionCommand {
        try JSONDecoder().decode(SessionCommand.self, from: Data(json.utf8))
    }
    #expect(try decode(#"{"setBadge":{"_0":"7"}}"#) == .setBadge("7"))
    #expect(try decode(#"{"setBadge":{}}"#) == .setBadge(nil))
    #expect(try decode(#"{"requestAttention":{"critical":true}}"#) == .requestAttention(critical: true))
    #expect(try decode(#"{"beginDragOut":{"names":["a.txt"]}}"#) == .beginDragOut(names: ["a.txt"], imagePNG: nil))
    #expect(try decode(#"{"promiseFulfilled":{"id":1}}"#) == .promiseFulfilled(id: 1, error: nil))
    #expect(try decode(#"{"terminate":{}}"#) == .terminate)
}

/// What a guest sends comes in here, so what it lies about has to stop here.
@Test func sessionWireRefusesWhatDoesntAddUp() throws {
    func parsed(_ data: Data) -> SessionWire.Parsed { data.withUnsafeBytes { SessionWire.parse($0) } }
    func frame(width: UInt32, height: UInt32, x: UInt32 = 0, full: UInt32 = 4, pixels: Int) -> Data {
        var body = Data()
        for value in [7, 1, full, full, x, 0, width, height] as [UInt32] {
            withUnsafeBytes(of: value.littleEndian) { body.append(contentsOf: $0) }
        }
        body.append(Data(count: pixels))
        var out = SessionWire.header(.hello, length: body.count)
        out[4] = 3  // A frame.
        return out + body
    }
    let good = frame(width: 2, height: 2, pixels: 16)
    guard case .message(.frame(let decoded), let used) = parsed(good) else {
        Issue.record("A good frame didn't parse")
        return
    }
    #expect(used == good.count && decoded.window == 7 && decoded.pixelOffset == 44)
    #expect(parsed(frame(width: 3, height: 2, x: 2, pixels: 24)) == .bad)  // Past the window's edge.
    #expect(parsed(frame(width: 2, height: 2, pixels: 15)) == .bad)  // Not the size it says.
    #expect(parsed(good.prefix(20)) == .needMore(size: good.count))
    #expect(parsed(Data([1, 2, 3, 4, 5])) == .bad)
    #expect(parsed(SessionWire.value(.quitApp)) == .bad)  // Only ever host to guest.

    let pieces = SessionWire.documentPieces(
        id: 3, name: "a", flags: SessionWire.dragFlag, contents: Data(count: SessionWire.documentPiece + 1))
    #expect(pieces.count == 2)
    guard case .message(.document(let last), _) = parsed(pieces[1]) else {
        Issue.record("A document piece didn't parse")
        return
    }
    #expect(last.id == 3 && last.isLast && last.flags == SessionWire.dragFlag && last.payload.count == 1)
    #expect(parsed(SessionWire.value(.appGone)) == .message(.appGone, used: 16))
}

@Test func guestNameCannotEscapeTheFolder() {
    #expect(!hostFileName(for: "../../etc/passwd").contains("/"))
    #expect(hostFileName(for: "..") == "Untitled")
    #expect(hostFileName(for: "a:b") == "a-b")
    #expect(!hostFileName(for: ".hidden").hasPrefix("."))
}

@Test func proxyClaimsNoDefaultsOrSchemes() throws {
    var info: [String: Any] = ["CFBundleIdentifier": "com.old/app", "CFBundleName": "Old"]
    info["CFBundleDocumentTypes"] = [
        ["CFBundleTypeExtensions": ["old"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Owner"]
    ]
    info["CFBundleURLTypes"] = [["CFBundleURLSchemes": ["http"]]]
    let app = try #require(GuestApp(infoPlist: info, guestPath: "/Applications/Old.app"))
    let bundle = ProxyBundle(app: app, machine: .init(identifier: "ABC", name: "Tiger", path: ""))
    #expect(bundle.bundleIdentifier == "gold.samhenri.LightClick.guest.abc.com.old-app")
    #expect(bundle.bundleName == "Old (Tiger).app")
    let plist = bundle.infoPlist(sessionSocket: "/s", iconFile: nil)
    let types = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
    #expect(types[0]["LSHandlerRank"] as? String == "Alternate")
    #expect(types[0]["CFBundleTypeRole"] as? String == "Viewer")
    #expect(plist["CFBundleURLTypes"] == nil)
}

@Test func menuModifiersFollowAccessibility() {
    #expect(GuestMenuItem(title: "Save", key: "S").keyModifiers == .command)
    #expect(GuestMenuItem(title: "Save", key: "S").keyEquivalent == "s")
    #expect(GuestMenuItem(title: "As", key: "S", modifiers: 1).keyModifiers == [.command, .shift])
    #expect(GuestMenuItem(title: "No", key: "A", modifiers: 8).keyModifiers == [])
    #expect(
        GuestMenuItem(title: "F", virtualKey: 0x7A).keyEquivalent.unicodeScalars.first?.value == UInt32(NSF1FunctionKey)
    )
    #expect(GuestMenuItem(title: "").isSeparator)
    #expect(GuestMenuItem(title: "Wrap", mark: "\u{2713}").state == .on)
    #expect(GuestMenuItem(title: "Mixed", mark: "-").state == .mixed)
}

@MainActor @Test func mirrorUpdatesInPlace() {
    let menu = NSMenu()
    let target = NSObject()
    let mirror = GuestMenuMirror(target: target, action: NSSelectorFromString("self"))
    mirror.apply(
        [
            GuestMenuItem(title: "A"), GuestMenuItem(title: ""),
            GuestMenuItem(title: "B", children: [GuestMenuItem(title: "C")])
        ], to: menu)
    let first = menu.items[0]
    #expect(menu.items[1].isSeparatorItem)
    #expect(menu.items[2].submenu?.items[0].representedObject as? [String] == ["B", "C"])
    mirror.apply([GuestMenuItem(title: "A2", isEnabled: false), GuestMenuItem(title: "D")], to: menu)
    #expect(menu.items.count == 2)
    #expect(menu.items[0] === first)
    #expect(!menu.items[0].isEnabled)
    #expect(!menu.items[1].isSeparatorItem)
}

@Test func onlyWebAndMailLinksReachTheHost() {
    #expect(HostPolicy.openableURL("https://apple.com/x") != nil)
    #expect(HostPolicy.openableURL("mailto:a@b.c") != nil)
    #expect(HostPolicy.openableURL("file:///etc/passwd") == nil)
    #expect(HostPolicy.openableURL("x-apple.systempreferences:com.apple") == nil)
    #expect(HostPolicy.openableURL("http://") == nil)
    #expect(HostPolicy.openableURL("https://a/" + String(repeating: "x", count: 9000)) == nil)
}

@Test func sharedFolderMappingStaysInside() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "lc-map-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = FileManager.default.temporaryDirectory.path
    try FileManager.default.createSymbolicLink(atPath: root.appending(path: "link").path, withDestinationPath: outside)
    let map = SharedFolderMapping(hostRoot: root.path, guestRoot: "/Volumes/Host")
    #expect(map.guestPath(forHost: root.appending(path: "a b.txt").path) == "/Volumes/Host/a b.txt")
    #expect(map.guestPath(forHost: "/etc/passwd") == nil)
    #expect(map.hostPath(forGuest: "/Volumes/Host/a") == root.path + "/a")
    #expect(map.hostPath(forGuest: "/Volumes/Host/../../etc/passwd") == nil)
    #expect(map.hostPath(forGuest: "/Volumes/Host/link/secret") == nil)
    #expect(map.hostPath(forGuest: "/Users/x") == nil)
}

@Test func pickerRoutesByArchitectureAndVersion() {
    let guests = [
        GuestPicker.Guest(name: "Mojave", version: "10.14.6"),
        GuestPicker.Guest(name: "Mavericks", version: "10.9.5"),
        GuestPicker.Guest(name: "Snow", version: "10.6.8", hasRosetta: true),
        GuestPicker.Guest(name: "Catalina", version: "10.15.7")
    ]
    func names(_ architectures: Set<String>, _ minimum: String? = nil) -> [String] {
        GuestPicker.candidates(for: .init(architectures: architectures, minimumSystemVersion: minimum), among: guests)
            .map(\.name)
    }
    #expect(names(["ppc"]) == ["Snow"])
    #expect(names(["i386"]) == ["Mojave", "Mavericks", "Snow"])
    #expect(names(["x86_64"], "10.10") == ["Catalina", "Mojave"])
    #expect(names(["arm64"]) == [])
}

@Test func machOArchitecturesAreRead() throws {
    let host = try MachOArchitectures.read(URL(fileURLWithPath: "/bin/ls"))
    #expect(host.contains("arm64"))
    let text = FileManager.default.temporaryDirectory.appending(path: "lc-text-\(UUID())")
    try Data("#!/bin/sh\n".utf8).write(to: text)
    defer { try? FileManager.default.removeItem(at: text) }
    #expect(try MachOArchitectures.read(text).isEmpty)
}

@Test func framerSplitsAndRefusesUnboundedLines() throws {
    var framer = LineFramer()
    #expect(try framer.append(Data("a\nb".utf8)) == [Data("a".utf8)])
    #expect(try framer.append(Data("c\n".utf8)) == [Data("bc".utf8)])
    #expect(throws: LineFramer.Failure.self) {
        try framer.append(Data(count: LineFramer.maximumLine + 1))
    }
    let event = ProxyEvent.dragMoved(windowID: 1, x: 2, y: 3)
    let encoded = try LineFramer.encode(event)
    #expect(encoded.last == 0x0A)
    #expect(try JSONDecoder().decode(ProxyEvent.self, from: encoded) == event)
}
