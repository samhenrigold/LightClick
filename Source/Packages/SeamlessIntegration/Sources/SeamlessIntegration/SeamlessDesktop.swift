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
    private let began = CFAbsoluteTimeGetCurrent()
    private var saidFirstWindow = false
    private var saidReplaced = false
    private var prearming = false
    private var prearmStopped = false
    private static var prearmers: [String: (desktop: SeamlessDesktop, work: Task<Void, Never>)] = [:]
    private let environment = ProcessInfo.processInfo.environment
    private static var staged: Set<String> = []
    private static var hooked: Set<String> = []
    private static var described: [String: GuestApp] = [:]
    private lazy var savedDescriptions: [String: GuestApp] =
        (try? JSONDecoder().decode([String: GuestApp].self, from: Data(contentsOf: descriptionsFile))) ?? [:]
    private var descriptionsFile: URL { configuration.bundles.appending(path: "apps.json") }
    private static var preparing: [String: Task<Bool, Never>] = [:]

    public static let leaveTitle = "Show in Light Click Window"

    public init(configuration: Configuration, guest: any SeamlessGuest) {
        self.configuration = configuration
        self.guest = guest
        if !FileManager.default.fileExists(atPath: configuration.log.path) {
            FileManager.default.createFile(
                atPath: configuration.log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        logHandle = try? FileHandle(forWritingTo: configuration.log)
        _ = try? logHandle?.seekToEnd()
    }

    public func note(_ text: String) {
        logHandle?.write(Data(String(format: "%.2f %@\n", CFAbsoluteTimeGetCurrent() - began, text).utf8))
    }

    /// Whether any window's surface has come, for going back to cropping if the guest's turned them on and none do.
    public var hasOwnSurfaces: (() -> Bool)?
    public weak var pixelSource: (any SeamlessPixelSource)? {
        didSet { for session in sessions.values { session.pixelSource = pixelSource } }
    }

    public func windowPixelsChanged(_ id: UInt32) {
        for session in sessions.values { session.windowPixelsChanged(id) }
        if !saidReplaced, hasReplacedDisplay {
            saidReplaced = true
            note("# every window has its pixels")
            windowsChanged?(windowCount)
        }
    }

    public var windowCount: Int { sessions.values.reduce(0) { $0 + $1.windowCount } }
    private var appsInFirstList: Set<String>?

    /// Whether every app with windows when this started has them on the host with their own pixels, so the machine's window can go
    /// with nothing lost. Asked each time something arrives.
    public var hasReplacedDisplay: Bool {
        guard let appsInFirstList, !appsInFirstList.isEmpty else { return false }
        return appsInFirstList.allSatisfy { sessions[$0].map { $0.windowCount > 0 && $0.allWindowsHavePixels } ?? false }
    }

    public func start() {
        signal(SIGPIPE, SIG_IGN)
        guard listen() else {
            finish("Couldn’t listen for the guest.")
            return
        }
        Task { await runInGuest() }
    }

    /// Ends everything, and says so once. Safe to call whenever.
    public func finish(_ failure: String? = nil, why: String = "as asked") {
        guard !stopped else { return }
        stopped = true
        note("# finished: \(failure ?? why)")
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
        if !saidReplaced, hasReplacedDisplay {
            saidReplaced = true
            note("# every window has its pixels")
            windowsChanged?(windowCount)
        }
    }

    // MARK: The guest's side

    private func runInGuest() async {
        await Self.stopPrearming(machine: configuration.machine.path)
        let ready = await Self.prepare(guest: guest, tools: configuration.tools, machine: configuration.machine.path)
        note("# tools in the guest")
        if stopped { return }
        guard ready else {
            finish("This Mac isn’t ready yet. Wait for it to finish starting, then try again.")
            return
        }
        var ran = SeamlessGuestRun(exitCode: nil, output: "", failure: nil)
        // In one request, as each costs about a second on Mavericks. Dropping just after setup, on Mavericks, means asking again:
        // the script never tries the hook twice in a guest's start, and nothing's reached the user yet.
        for attempt in 1...8 {
            ran = await guest.run("/bin/sh", ["-c", Self.pressScript, "sh", String(port)])
            if stopped || control >= 0 || attempt == 8 { break }
            if ran.exitCode == Self.noTools {
                // The guest has restarted since they went in.
                Self.staged.remove(configuration.machine.path)
                Self.hooked.remove(configuration.machine.path)
                guard await Self.prepare(guest: guest, tools: configuration.tools, machine: configuration.machine.path) else { break }
            } else if ran.exitCode != nil {
                break
            } else {
                note("# trying again: \(ran.failure ?? "")")
                try? await Task.sleep(for: .seconds(3))
            }
        }
        note("# the guest's side ended, exit \(ran.exitCode.map(String.init) ?? "none")\n\(ran.output)\n\(ran.failure ?? "")")
        finish(ran.exitCode == 3 ? "This Mac couldn’t reach Light Click. Seamless needs its networking on." : nil, why: "the guest's side ended")
    }

    public static func isPrepared(machine: String) -> Bool { staged.contains(machine) }

    /// Everything a press would otherwise wait for, while the machine's just running: the programs and the hook in the guest, and a
    /// proxy for each app with windows. Nothing shows, and nothing's changed until a press turns it on.
    public func prearm() async {
        let machine = configuration.machine.path
        let work = Task { await prearmWork() }
        Self.prearmers[machine] = (self, work)
        await work.value
        if Self.prearmers[machine]?.desktop === self { Self.prearmers[machine] = nil }
    }

    /// The guest's agent serves one connection, and pre-arming's stays open for up to a minute: a press in that time had each of its
    /// tries ended. So a press stops it and waits.
    private static func stopPrearming(machine: String) async {
        guard let running = prearmers[machine] else { return }
        running.desktop.prearmStopped = true
        running.desktop.endPrearming()
        await running.work.value
    }

    private func prearmWork() async {
        guard await Self.prepare(guest: guest, tools: configuration.tools, machine: configuration.machine.path) else { return }
        if !Self.hooked.contains(configuration.machine.path) {
            let injected = await guest.run("/bin/sh", ["-c", Self.injectScript])
            note("# pre-armed: hook into WindowServer: exit \(injected.exitCode.map(String.init) ?? "none") \(injected.output)")
            // Exits but for a dropped connection are answers, and it never tries twice in a guest's start.
            if injected.exitCode != nil { Self.hooked.insert(configuration.machine.path) }
        }
        // Over the same connection as a press, as an icon's megabytes through the agent stop it answering for minutes.
        guard !prearmStopped, listen() else { return }
        prearming = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.endPrearming()
        }
        _ = await guest.run(
            "/usr/bin/env",
            ["SEAMLESS_RUN_IN_PLACE=1", "/tmp/sg/g", "leap", "--list-only", "--port", String(port), "--menu-tool", "/tmp/sg/ig"])
    }

    private func endPrearming() {
        if control >= 0 { shutdown(control, SHUT_RDWR) }
    }

    /// Puts the programs in the guest, once for each of its starts, and sooner than a press if the app wants that to be quick.
    public static func prepare(guest: any SeamlessGuest, tools: URL, machine: String) async -> Bool {
        if let running = preparing[machine] { return await running.value }
        let task = Task<Bool, Never> { @MainActor in
            defer { preparing[machine] = nil }
            // A guest that's restarted since says so when they're run.
            if staged.contains(machine) { return true }
            guard let tool = await guest.stage(tools.appending(path: "seamless-guest")),
                let menuTool = await guest.stage(tools.appending(path: "seamless-integration-guest"))
            else { return false }
            // Mavericks has been seen to drop the agent's connection during this and be set up regardless. Without Accessibility there are only no menus.
            _ = await guest.run("/bin/sh", ["-c", SeamlessSession.setupScript, "sh", tool, menuTool])
            // On Mojave, ready for a press to load into WindowServer.
            let release = await guest.run("/usr/bin/uname", ["-r"]).output
            if release.hasPrefix("18.") || release.hasPrefix("13."),
                let hook = await guest.stage(tools.appending(path: "seamless-ws-hook.dylib")),
                let injector = await guest.stage(tools.appending(path: "seamless-ws-inject"))
            {
                let copy = "cp \"$1\" /tmp/sg/hook.dylib; cp \"$2\" /tmp/sg/ws-inject; chmod 755 /tmp/sg/ws-inject"
                _ = await guest.run("/bin/sh", ["-c", copy, "sh", hook, injector])
            }
            staged.insert(machine)
            return true
        }
        preparing[machine] = task
        return await task.value
    }

    private static let noTools = 126

    /// Loads the hook into the running WindowServer, so each window comes on a surface of its own. If this goes wrong WindowServer
    /// dies and logs the user out, so it's only for the one build it's been run on, is tried once per guest start and is never
    /// retried, whatever happened. Exit 0 means the hook's in this WindowServer; anything else leaves the display's frames.
    private static let injectScript = """
        case "$(/usr/bin/sw_vers -buildVersion)" in 18G103|13F34) ;; *) exit 3;; esac
        [ -x /tmp/sg/ws-inject ] && [ -f /tmp/sg/hook.dylib ] || exit 3
        # Earlier builds loaded it through WindowServer's launchd job. That one's in this WindowServer, and patching twice isn't safe, so
        # the entry goes now and windows have their surfaces from the guest's next start.
        boot=$(/usr/sbin/sysctl -n kern.boottime | /usr/bin/sed 's/.*sec = \\([0-9]*\\).*/\\1/')
        plist=/System/Library/LaunchDaemons/com.apple.WindowServer.plist
        if /usr/bin/grep -q seamless-ws-hook $plist; then
            /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:DYLD_INSERT_LIBRARIES" $plist
            echo "$boot" > /var/tmp/seamless-ws-plist-removed
        fi
        [ "$(/bin/cat /var/tmp/seamless-ws-plist-removed 2>/dev/null)" = "$boot" ] && exit 3
        pid=$(/usr/bin/pgrep -x WindowServer); [ -n "$pid" ] || exit 3
        marker=/var/tmp/seamless-ws-press
        said=$(/bin/cat $marker 2>/dev/null)
        [ "$said" = "$boot $pid ok" ] && exit 0
        case "$said" in "$boot "*) exit 4;; esac
        # Written first, so a WindowServer that dies with this isn't tried again.
        echo "$boot $pid tried" > $marker
        /bin/cp /tmp/sg/hook.dylib /usr/lib/seamless-ws-hook.dylib || exit 5
        /bin/chmod 755 /usr/lib/seamless-ws-hook.dylib
        /tmp/sg/ws-inject /usr/lib/seamless-ws-hook.dylib 2>&1 || exit 6
        [ "$(/usr/bin/pgrep -x WindowServer)" = "$pid" ] || exit 7
        echo "$boot $pid ok" > $marker
        """

    private static let pressScript = """
        [ -x /tmp/sg/g ] && [ -x /tmp/sg/ig ] || exit \(noTools)
        ( \(injectScript)
        )
        hooked=$?
        echo "# hook into WindowServer: exit $hooked"
        own=; [ $hooked = 0 ] && own=--own-surfaces
        exec /usr/bin/env SEAMLESS_RUN_IN_PLACE=1 /tmp/sg/g leap --port "$1" --menu-tool /tmp/sg/ig $own
        """

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
                    if self?.prearmStopped == true { shutdown(client, SHUT_RDWR) }
                    self?.note("# the guest's program connected")
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
            if prearming {
                let unknown = apps.filter { savedDescriptions[$0.path] == nil }
                if unknown.isEmpty, describing.isEmpty { endPrearming() }
                for app in unknown where !describing.contains(app.path) {
                    describing.insert(app.path)
                    tell("describe\t\(app.path)")
                }
                return
            }
            if appsInFirstList == nil { appsInFirstList = Set(apps.map(\.path)) }
            for app in apps where sessions[app.path] == nil && !describing.contains(app.path) {
                note("# apps says \(app.name)")
                describing.insert(app.path)
                names[app.path] = app.name
                // Reading an app starts programs in the guest, which is slow. It's the same app next time.
                if let known = Self.described[app.path] ?? savedDescriptions[app.path] {
                    Task { await open(known, icon: nil) }
                } else {
                    tell("describe\t\(app.path)")
                }
            }
            if let first = apps.first?.path, first != front {
                front = first
                activateFront()
            }
        case "gpu":
            note("# the guest's windows are composited for the host")
            // If none arrives there'd be nothing showing at all, with the guest no longer drawing them on its display.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.stopped, !(self.hasOwnSurfaces?() ?? false) else { return }
                    self.note("# no surfaces came, so back to the display's frames")
                    self.tell("gpu-off")
                }
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
            note("# described \(path)")
            Self.described[path] = app
            savedDescriptions[path] = app
            try? JSONEncoder().encode(savedDescriptions).write(to: descriptionsFile)
            if prearming {
                Task {
                    _ = await proxyFor(app, icon: icon)
                    describing.remove(path)
                    note("# pre-armed \(path)")
                }
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

    /// The proxy for an app, made if need be, and the socket it looks for its session on.
    private func proxyFor(_ app: GuestApp, icon: Data?) async -> (bundle: URL?, socket: String) {
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
            // A proxy from another build mightn't speak this one's protocol.
            let built = (try? configuration.proxyExecutable.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            let folder = configuration.bundles.appending(path: String(Int(built)))
            if !FileManager.default.fileExists(atPath: folder.path),
                let old = try? FileManager.default.contentsOfDirectory(at: configuration.bundles, includingPropertiesForKeys: nil)
            {
                for item in old where item != descriptionsFile { try? FileManager.default.removeItem(at: item) }
            }
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
        return (bundle, socketPath)
    }

    private func open(_ app: GuestApp, icon: Data?) async {
        let (bundle, socketPath) = await proxyFor(app, icon: icon)
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
        session.pixelSource = pixelSource
        session.onWindowsChanged = { [weak self] in
            guard let self else { return }
            if !self.saidFirstWindow, self.windowCount > 0 {
                self.saidFirstWindow = true
                self.note("# first window")
            }
            self.windowsChanged?(self.windowCount)
        }
        session.onLeave = { [weak self] in self?.finish(why: "\(name)'s proxy asked") }
        // A proxy that went without its guest app quitting has nothing to show the user any more, and nor should they be
        // left with what's still hidden.
        session.onProxyClosed = { [weak self] appGone in
            guard let self else { return }
            if appGone {
                self.closeApp(app.guestPath)
            } else {
                self.finish(why: "\(name)'s proxy went")
            }
        }
        session.onGuestGone = { [weak self] in self?.closeApp(app.guestPath) }
        sessions[app.guestPath] = session
        session.start()
        note("# running \(name)")
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
