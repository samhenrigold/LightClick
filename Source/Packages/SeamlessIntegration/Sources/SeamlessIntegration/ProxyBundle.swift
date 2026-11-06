import CoreServices
import Foundation

/// The host `.app` that stands for one guest app in one machine: its Dock tile, Cmd-Tab entry, document handling and menu
/// bar. The executable is the same small binary in every proxy.
public struct ProxyBundle: Sendable {
    /// Which `LSHandlerRank` the guest's document types get. `alternate` is listed under Open With but never becomes a
    /// default on its own, as the integration probe measures; `none` receives only explicit drops and `open -a`.
    public enum HandlerRank: String, Sendable {
        case alternate = "Alternate"
        case none = "None"
    }

    public struct Machine: Codable, Hashable, Sendable {
        public var identifier: String
        public var name: String
        public var path: String

        public init(identifier: String, name: String, path: String) {
            self.identifier = identifier
            self.name = name
            self.path = path
        }
    }

    public var app: GuestApp
    public var machine: Machine
    public var rank = HandlerRank.alternate

    public init(app: GuestApp, machine: Machine, rank: HandlerRank = .alternate) {
        self.app = app
        self.machine = machine
        self.rank = rank
    }

    public static let sessionSocketKey = "LCSessionSocket"
    public static let machinePathKey = "LCMachinePath"
    public static let guestPathKey = "LCGuestPath"
    public static let guestIdentifierKey = "LCGuestBundleIdentifier"

    /// Stable, so the Dock and LaunchServices keep treating a regenerated proxy as the same app.
    public var bundleIdentifier: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        func clean(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
        }
        return "gold.samhenri.LightClick.guest.\(clean(machine.identifier).lowercased()).\(clean(app.bundleIdentifier))"
    }

    public var displayName: String { "\(app.name) (\(machine.name))" }

    /// A bundle name a guest can't use to step out of `directory`.
    public var bundleName: String { hostFileName(for: displayName) + ".app" }

    public func infoPlist(sessionSocket: String, iconFile: String?) -> [String: Any] {
        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleExecutable": "SeamlessProxy",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": app.version ?? "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            "LSMultipleInstancesProhibited": true,
            "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": true,
            "NSSupportsAutomaticTermination": false,
            Self.sessionSocketKey: sessionSocket,
            Self.machinePathKey: machine.path,
            Self.guestPathKey: app.guestPath,
            Self.guestIdentifierKey: app.bundleIdentifier
        ]
        if let iconFile { plist["CFBundleIconFile"] = iconFile }
        let types = app.documentTypes.compactMap { type -> [String: Any]? in
            guard !type.contentTypes.isEmpty || !type.extensions.isEmpty || !type.osTypes.isEmpty else { return nil }
            var entry: [String: Any] = [
                "CFBundleTypeName": type.name ?? "Document",
                // A proxy never claims to own a host type, whatever the guest's bundle says.
                "CFBundleTypeRole": "Viewer",
                "LSHandlerRank": rank.rawValue
            ]
            if !type.contentTypes.isEmpty { entry["LSItemContentTypes"] = type.contentTypes }
            if !type.extensions.isEmpty { entry["CFBundleTypeExtensions"] = type.extensions }
            if !type.osTypes.isEmpty { entry["CFBundleTypeOSTypes"] = type.osTypes }
            return entry
        }
        if !types.isEmpty { plist["CFBundleDocumentTypes"] = types }
        return plist
    }

    /// Writes, signs and registers the bundle in `directory`, replacing an earlier one. `guestIcon` is the guest's icon
    /// file if it could be read. No URL schemes are declared: a proxy must not be able to take over `http`.
    @discardableResult
    public func write(
        to directory: URL, proxyExecutable: URL, sessionSocket: String, guestIcon: URL? = nil
    ) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundle = directory.appending(path: bundleName)
        try? manager.removeItem(at: bundle)
        let contents = bundle.appending(path: "Contents")
        let macOS = contents.appending(path: "MacOS")
        let resources = contents.appending(path: "Resources")
        try manager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        try manager.copyItem(at: proxyExecutable, to: macOS.appending(path: "SeamlessProxy"))

        var iconFile: String?
        if let guestIcon {
            let output = resources.appending(path: "GuestApp.icns")
            if (try? IconConversion.convert(guestIcon, to: output)) != nil { iconFile = "GuestApp.icns" }
        }
        let plist = infoPlist(sessionSocket: sessionSocket, iconFile: iconFile)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))

        try run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        // LaunchServices ignores bundles under the temporary folder, per seamless-apps-design.md.
        let status = LSRegisterURL(bundle as CFURL, true)
        guard status == noErr else { throw ProxyBundleError.registration(status) }
        return bundle
    }

    /// Removes the bundle and its LaunchServices record, so it leaves Open With and the Dock's memory.
    public static func remove(_ bundle: URL) throws {
        let register =
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        try run(register, ["-u", bundle.path])
        try FileManager.default.removeItem(at: bundle)
    }
}

public enum ProxyBundleError: Error, Equatable {
    case registration(OSStatus)
    case tool(String, Int32)
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ProxyBundleError.tool(executable, process.terminationStatus)
    }
}

/// A single path component for a name that came from a guest. Never `.`, `..` or empty, and free of `/` and of `:`, which
/// the host's file APIs treat as a separator in places.
public func hostFileName(for name: String) -> String {
    let cleaned = name.unicodeScalars.map { scalar -> Character in
        scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) ? "-" : Character(scalar)
    }
    var result = String(cleaned).trimmingCharacters(in: .whitespaces)
    while result.hasPrefix(".") { result.removeFirst() }
    if result.isEmpty { return "Untitled" }
    return String(result.prefix(200))
}
