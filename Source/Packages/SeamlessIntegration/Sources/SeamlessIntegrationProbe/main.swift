import AppKit

// Measures on this host what a generated proxy shows and receives, against a fake session, and drives the drags with
// synthetic events. Boots nothing. Moves the pointer and briefly shows windows, the app switcher and Mission Control.
//
//     seamless-integration-probe --proxy BIN --helper BIN --out DIR [--guest-root MOUNT ...] [--no-visual]
//
// --guest-root takes a read-only mount of a guest disk, for its real TextEdit plist and icon.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let arguments = CommandLine.arguments
func values(_ name: String) -> [String] {
    arguments.indices.filter { arguments[$0] == name && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
}
guard let proxy = values("--proxy").first, let helper = values("--helper").first, let out = values("--out").first else {
    FileHandle.standardError.write(Data("usage: seamless-integration-probe --proxy BIN --helper BIN --out DIR\n".utf8))
    exit(64)
}
let probe = HostProbe(
    proxyExecutable: URL(fileURLWithPath: proxy), helper: URL(fileURLWithPath: helper),
    output: URL(fileURLWithPath: out), guestRoots: values("--guest-root").map { URL(fileURLWithPath: $0) },
    visual: !arguments.contains("--no-visual"))
probe.dragsOnly = arguments.contains("--drags-only")
Task { @MainActor in
    await probe.run()
    exit(probe.failures == 0 ? 0 : 1)
}
application.run()
