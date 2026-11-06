import AppKit
import Darwin
import IOSurface

/// Every guest app in the machine that's already running, each as a host app, until told to stop. One program in the guest
/// says which apps have windows; each gets a generated proxy and a `SeamlessSession` of its own, all cropping the same frames.
/// Nothing is set up ahead of time and nothing about the guest changes, so stopping leaves it as it was.
@MainActor
public final class SeamlessDesktop {
    public struct Configuration: Sendable {
        /// Holds `seamless-guest` and `seamless-integration-guest`, the x86_64 programs for the guest.
        public var tools: URL
        public var proxyExecutable: URL
        /// Where generated proxies are kept, for being quick next time.
        public var bundles: URL
        /// Where the user's saved Dock apps are, which are used if there's one for this app on this machine.
        public var savedBundles: URL
        public var machine: ProxyBundle.Machine
        public var log: URL
        /// Added to a guest window's position to get its place on the host, counted down from the top of the primary screen.
        public var guestOffset: NSPoint

        public init(
            tools: URL, proxyExecutable: URL, bundles: URL, savedBundles: URL, machine: ProxyBundle.Machine, log: URL,
            guestOffset: NSPoint
        ) {
            self.tools = tools
            self.proxyExecutable = proxyExecutable
            self.bundles = bundles
            self.savedBundles = savedBundles
            self.machine = machine
            self.log = log
            self.guestOffset = guestOffset
        }
    }

    /// How many guest windows are showing on the host, whenever that changes.
    public var windowsChanged: ((Int) -> Void)?
    /// It's over, and everything's stopped: the user asked from a proxy, or the guest's side ended. A reason if it failed.
    public var ended: ((String?) -> Void)?

    private let configuration: Configuration
    private let guest: any SeamlessGuest
    private var sessions: [String: SeamlessSession] = [:]
    private var describing: Set<String> = []
    private var names: [String: String] = [:]
    private var control: Int32 = -1
    private var port: UInt16 = 0
    private var stopped = false
    private var front: String?
    private var copies = FrameCopies()
    private let logHandle: FileHandle?
    private let environment = ProcessInfo.processInfo.environment
    private static var staged: Set<String> = []

    public static let leaveTitle = "Show in Light Click Window"

    public init(configuration: Configuration, guest: any SeamlessGuest) {
        self.configuration = configuration
        self.guest = guest
        FileManager.default.createFile(
            atPath: configuration.log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        logHandle = try? FileHandle(forWritingTo: configuration.log)
    }

    private func note(_ text: String) { logHandle?.write(Data((text + "\n").utf8)) }

    public var windowCount: Int { sessions.values.reduce(0) { $0 + $1.windowCount } }

    public func start() {
        signal(SIGPIPE, SIG_IGN)
        guard listen() else {
            finish("Couldn’t listen for the guest.")
            return
        }
        Task { await runInGuest() }
    }

    /// Ends everything, and says so once. Safe to call whenever.
    public func finish(_ failure: String? = nil) {
        guard !stopped else { return }
        stopped = true
        note("# finished: \(failure ?? "as asked")")
        for session in sessions.values { session.stop() }
        sessions = [:]
        // The program in the guest ends when this does, and takes its tools with it.
        if control >= 0 { shutdown(control, SHUT_RDWR) }
        ended?(failure)
    }

    public func frameArrived(surface: IOSurfaceRef?, bytes: UnsafeRawPointer?, width: Int, height: Int, stride: Int) {
        guard !sessions.isEmpty,
            let current = surface ?? copies.copy(bytes, width: width, height: height, stride: stride)
        else { return }
        for session in sessions.values {
            session.frameArrived(surface: current, bytes: nil, width: width, height: height, stride: stride)
        }
    }

    // MARK: The guest's side

    private func runInGuest() async {
        let key = configuration.machine.path
        // The folder goes with the guest's next start, and the tools with this app's next build.
        let present = await guest.run("/bin/sh", ["-c", "test -x /tmp/sg/g && test -x /tmp/sg/ig"]).exitCode == 0
        if stopped { return }
        if !present || !Self.staged.contains(key) {
            guard let tool = await guest.stage(configuration.tools.appending(path: "seamless-guest")),
                let menuTool = await guest.stage(configuration.tools.appending(path: "seamless-integration-guest"))
            else {
                finish("This Mac isn’t ready yet. Wait for it to finish starting, then try again.")
                return
            }
            if stopped { return }
            let setup = await guest.run("/bin/sh", ["-c", SeamlessSession.setupScript, "sh", tool, menuTool])
            note("# set up: exit \(setup.exitCode.map(String.init) ?? "none"), \(setup.output)\(setup.failure ?? "")")
            Self.staged.insert(key)
        }
        if stopped { return }
        let ran = await guest.run(
            "/usr/bin/env",
            ["SEAMLESS_RUN_IN_PLACE=1", "/tmp/sg/g", "leap", "--port", String(port), "--menu-tool", "/tmp/sg/ig"])
        note("# the guest's side ended, exit \(ran.exitCode.map(String.init) ?? "none")\n\(ran.output)\n\(ran.failure ?? "")")
        finish(ran.exitCode == 3 ? "This Mac couldn’t reach Light Click. Seamless needs its networking on." : nil)
    }

    private func listen() -> Bool {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, size) == 0 && getsockname(listener, $0, &size) == 0
            }
        }
        guard bound, Darwin.listen(listener, 1) == 0 else { return false }
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [weak self] in
            let client = accept(listener, nil, nil)
            close(listener)
            guard client >= 0 else { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self?.control = client
                    if self?.stopped ?? true { shutdown(client, SHUT_RDWR) }
                }
            }
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let got = recv(client, &buffer, buffer.count, 0)
                if got <= 0 { break }
                pending.append(contentsOf: buffer[0..<got])
                while let end = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...end)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.received(line) }
                    }
                }
            }
            close(client)
        }
        return true
    }

    private func tell(_ line: String) {
        guard control >= 0 else { return }
        let data = Data((line + "\n").utf8)
        _ = data.withUnsafeBytes { send(control, $0.baseAddress, $0.count, 0) }
    }

    /// Lines from a guest are only trusted as far as a path and a name it could have shown anyway.
    private func received(_ line: String) {
        guard !stopped else { return }
        let fields = line.components(separatedBy: "\t")
        switch fields[0] {
        case "apps":
            // Each after that is a name and its bundle, front first.
            let apps = stride(from: 1, to: fields.count - 1, by: 2).map { (name: fields[$0], path: fields[$0 + 1]) }
            for app in apps where sessions[app.path] == nil && !describing.contains(app.path) {
                describing.insert(app.path)
                names[app.path] = app.name
                tell("describe\t\(app.path)")
            }
            if let first = apps.first?.path, first != front {
                front = first
                activateFront()
            }
        case "described":
            guard fields.count >= 3 else { return }
            let path = fields[1]
            let app = try? JSONDecoder().decode(GuestApp.self, from: Data(fields[2].utf8))
            let icon = fields.count > 3 ? Data(base64Encoded: fields[3]) : nil
            guard let app, app.guestPath == path else {
                note("# couldn't read \(path)")
                describing.remove(path)
                return
            }
            Task { await open(app, icon: icon) }
        default:
            break
        }
    }

    private func activateFront() {
        guard environment["LC_SEAMLESS_QUIET"] == nil, let front else { return }
        sessions[front]?.activateProxy()
    }

    // MARK: One guest app

    private func open(_ app: GuestApp, icon: Data?) async {
        let proxy = ProxyBundle(
            app: app,
            machine: .init(identifier: configuration.machine.identifier, name: configuration.machine.name, path: ""))
        let saved = configuration.savedBundles.appending(path: proxy.bundleName)
        let savedInfo = NSDictionary(contentsOf: saved.appending(path: "Contents/Info.plist"))
        let isSaved = savedInfo?[ProxyBundle.machinePathKey] as? String == configuration.machine.path
        let socketPath: String
        var bundle: URL?
        if isSaved, let socket = savedInfo?[ProxyBundle.sessionSocketKey] as? String {
            socketPath = socket
            bundle = saved
        } else {
            socketPath = Self.socketPath(for: app, machine: configuration.machine.identifier)
            let folder = configuration.bundles
            let existing = folder.appending(path: proxy.bundleName)
            if FileManager.default.fileExists(atPath: existing.appending(path: "Contents/Info.plist").path) {
                bundle = existing
            } else {
                let executable = configuration.proxyExecutable
                bundle = await Task.detached {
                    var iconFile: URL?
                    if let icon {
                        let file = FileManager.default.temporaryDirectory.appending(path: "lc-icon-\(UUID().uuidString).icns")
                        if (try? icon.write(to: file)) != nil { iconFile = file }
                    }
                    defer { iconFile.map { try? FileManager.default.removeItem(at: $0) } }
                    return try? proxy.write(to: folder, proxyExecutable: executable, sessionSocket: socketPath, guestIcon: iconFile)
                }.value
            }
        }
        describing.remove(app.guestPath)
        guard !stopped, let bundle, sessions[app.guestPath] == nil else {
            if bundle == nil { note("# couldn't make a proxy for \(app.name)") }
            return
        }
        let name = names[app.guestPath] ?? app.name
        let session = SeamlessSession(
            configuration: .init(
                socketPath: socketPath, guestApp: name, tools: configuration.tools,
                log: URL(fileURLWithPath: configuration.log.path + "." + app.bundleIdentifier)),
            guest: guest, finished: {})
        session.drivesGuest = false
        session.usesDisplayFrames = true
        session.guestOffset = configuration.guestOffset
        session.leaveTitle = Self.leaveTitle
        session.onWindowsChanged = { [weak self] in
            guard let self else { return }
            self.windowsChanged?(self.windowCount)
        }
        session.onLeave = { [weak self] in self?.finish() }
        // A proxy that went without its guest app quitting has nothing to show the user any more, and nor should they be
        // left with what's still hidden.
        session.onProxyClosed = { [weak self] appGone in
            guard let self else { return }
            if appGone {
                self.closeApp(app.guestPath)
            } else {
                self.finish()
            }
        }
        session.onGuestGone = { [weak self] in self?.closeApp(app.guestPath) }
        sessions[app.guestPath] = session
        session.start()
        tell("run\t\(name)\t\(session.guestPort)")
        if front == app.guestPath { activateFront() }
        let open = NSWorkspace.OpenConfiguration()
        open.activates = false
        // The first window of a proxy that doesn't hear otherwise brings its app forward, and only the guest's front app should.
        open.environment = environment.filter {
            $0.key == "CFFIXED_USER_HOME" || $0.key.hasPrefix("LC_SEAMLESS_")
        }.merging(["LC_SEAMLESS_QUIET": "1"]) { _, new in new }
        NSWorkspace.shared.openApplication(at: bundle, configuration: open) { _, error in
            guard let error else { return }
            NSLog("Couldn't open a proxy: %@", error.localizedDescription)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in self?.finish("Couldn’t open \(name) on this Mac.") }
            }
        }
    }

    private func closeApp(_ path: String) {
        sessions.removeValue(forKey: path)?.stop()
        windowsChanged?(windowCount)
    }

    /// The per-user temporary folder, since anyone can make a socket in /tmp. A socket's path has a short limit.
    private static func socketPath(for app: GuestApp, machine: String) -> String {
        let hash = app.bundleIdentifier.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return FileManager.default.temporaryDirectory
            .appending(path: "lc-\(machine.prefix(8).lowercased())-\(String(hash, radix: 16))").path
    }
}
