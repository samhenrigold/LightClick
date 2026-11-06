// Generated from machine-options.json by scripts/generate-machine-options, and the build fails while this differs.

/// QEMU's environment-variable options that a launch sets. A nil leaves the variable to `Inherited`.
struct MachineOptions: Equatable, Sendable {
    enum Engine: String, Sendable {
        case off
        case on

        var environmentValue: String {
            switch self {
            case .off: "0"
            case .on: "1"
            }
        }
    }

    /// What a value in the app's own environment does.
    private enum Inherited {
        case dropped, wins, winsUnlessEmpty
    }

    /// LC_HVDBT (enum, default off): Run the guest's 64-bit code in the hypervisor engine, with TCG as its other half. Needs a QEMU configured with -Dhvdbt_engine. Apple silicon only.
    var engine: Engine?
    /// VIM_PASSTHROUGH_OPENGL_INPROCESS_LIBRARY (path, default unset: no in-process renderer): The OpenGL host library QEMU loads into its own process.
    var passthroughOpenGLInprocessLibrary: String?
    /// VIM_PASSTHROUGH_OPENGL_INLINE (flag, default off): Have the in-process OpenGL host serve inline.
    var passthroughOpenGLInline: Bool?
    /// VIM_PASSTHROUGH_OPENGL_SURFACE_IMPORT (presence, default off): Let the OpenGL host import guest surfaces directly.
    var passthroughOpenGLSurfaceImport: Bool?
    /// VIM_DISPLAY_EVENT_DRIVEN (flag, default off): Scan the display out on events rather than on a poll.
    var displayEventDriven: Bool?
    /// VIM_OPENGL_VRAM_SERVICE (string, default unset: VRAM not exported): The service name QEMU exports guest VRAM under.
    var openGLVRAMService: String?
    /// VIM_OPENGL_VRAM_ENDPOINT (path, default unset): Where the OpenGL host publishes its VRAM endpoint.
    var openGLVRAMEndpoint: String?
    /// VIM_OPENGL_DISPLAY_ENDPOINT (path, default unset): Where the OpenGL host publishes its display endpoint.
    var openGLDisplayEndpoint: String?
    /// VIM_AUDIO_OUTPUT_DEVICE (string, default unset: SDL's default device): The SDL output device. A named device that's missing fails rather than rerouting.
    var audioOutputDevice: String?
    /// VIM_AUDIO_INPUT_DEVICE (string, default unset: SDL's default device): The SDL input device. A named device that's missing fails rather than rerouting.
    var audioInputDevice: String?
    /// VIM_INPUT_BACKPRESSURE (flag, default off): Refuse a whole input batch before dispatch when the guest can't take it, so the app can retry it without duplicates.
    var inputBackpressure: Bool?
    /// VIM_E1000_LINK_HISTORY (flag, default off): Record the e1000's link history, for --record-network-history.
    var e1000LinkHistory: Bool?
    /// VIM_INSTALLER_DISPLAY_SOCKET (path, default unset: no installer display): The app's socket for the installer display.
    var installerDisplaySocket: String?
    /// VIM_DISPLAY_REFRESH_MS (int, default unset: the display's 30 ms poll): The installer display's poll interval, in milliseconds.
    var displayRefreshMS: Int?
    /// PVG_OOP_HELPER (path, default unset: PVG in process): The out-of-process PVG helper. Apple silicon only.
    var oopHelper: String?
    /// PVG_OOP_DONOR (path, default unset): The donor ParavirtualizedGraphics framework the helper loads.
    var oopDonor: String?
    /// PVG_APP_DISPLAY_SOCKET (path, default unset: no app display): The app's socket for the PVG display.
    var appDisplaySocket: String?
    /// PVG_OOP_SCALE_FACTOR (int, default unset: the framework's): The helper's panel scale: 1 or 2, and anything else stops the helper.
    var oopScaleFactor: Int?
    /// PVG_APP_DISPLAY_SCALE (int, default unset: follows the host display): The panel is Retina when this is 2. A capability, not the current mode.
    var appDisplayScale: Int?
    /// PVG_PRESERVE_IOSURFACE (flag, default off): Preserve IOSurface contents for the legacy shadow.
    var preserveIOSurface: Bool?
    /// PVG_SHADOW_COALESCE (presence, default off): Coalesce the legacy shadow's page copies.
    var shadowCoalesce: Bool?
    /// PVG_SHADOW_MAX_CHUNK (int, default 65536): The largest coalesced copy: a power of two from 4096 to 1048576.
    var shadowMaxChunk: Int?
    /// PVG_SHADOW_TEXTURE_PAGING (presence, default off): Hook texture paging in the legacy shadow.
    var shadowTexturePaging: Bool?
    /// PVG_TEST_MSAA_TRANSFER (presence, default off): The ordered transfer for packed multisample depth/stencil. Intel only, despite the name.
    var msaaTransfer: Bool?
    /// PVG_HOST_AIR_LLVM (path, default unset: no repair): The LLVM library for Mojave's host AIR shader repair.
    var hostAIRLLVM: String?

    /// The options a Machine.plist can set.
    init(configuration: [String: Any] = [:]) {
        engine = (configuration["ExecutionEngine"] as? String).flatMap(Engine.init(rawValue:))
    }

    func apply(to environment: inout [String: String]) {
        let entries: [(name: String, value: String?, inherited: Inherited)] = [
            ("LC_HVDBT", engine?.environmentValue, .wins),
            ("VIM_PASSTHROUGH_OPENGL_INPROCESS_LIBRARY", passthroughOpenGLInprocessLibrary, .wins),
            ("VIM_PASSTHROUGH_OPENGL_INLINE", passthroughOpenGLInline == true ? "1" : nil, .wins),
            ("VIM_PASSTHROUGH_OPENGL_SURFACE_IMPORT", passthroughOpenGLSurfaceImport == true ? "1" : nil, .wins),
            ("VIM_DISPLAY_EVENT_DRIVEN", displayEventDriven == true ? "1" : nil, .wins),
            ("VIM_OPENGL_VRAM_SERVICE", openGLVRAMService, .winsUnlessEmpty),
            ("VIM_OPENGL_VRAM_ENDPOINT", openGLVRAMEndpoint, .winsUnlessEmpty),
            ("VIM_OPENGL_DISPLAY_ENDPOINT", openGLDisplayEndpoint, .winsUnlessEmpty),
            ("VIM_AUDIO_OUTPUT_DEVICE", audioOutputDevice, .dropped),
            ("VIM_AUDIO_INPUT_DEVICE", audioInputDevice, .dropped),
            ("VIM_INPUT_BACKPRESSURE", inputBackpressure == true ? "1" : nil, .dropped),
            ("VIM_E1000_LINK_HISTORY", e1000LinkHistory == true ? "1" : nil, .dropped),
            ("VIM_INSTALLER_DISPLAY_SOCKET", installerDisplaySocket, .dropped),
            ("VIM_DISPLAY_REFRESH_MS", displayRefreshMS.map(String.init), .dropped),
            ("PVG_OOP_HELPER", oopHelper, .dropped),
            ("PVG_OOP_DONOR", oopDonor, .dropped),
            ("PVG_APP_DISPLAY_SOCKET", appDisplaySocket, .dropped),
            ("PVG_OOP_SCALE_FACTOR", oopScaleFactor.map(String.init), .dropped),
            ("PVG_APP_DISPLAY_SCALE", appDisplayScale.map(String.init), .dropped),
            ("PVG_PRESERVE_IOSURFACE", preserveIOSurface == true ? "1" : nil, .dropped),
            ("PVG_SHADOW_COALESCE", shadowCoalesce == true ? "1" : nil, .dropped),
            ("PVG_SHADOW_MAX_CHUNK", shadowMaxChunk.map(String.init), .dropped),
            ("PVG_SHADOW_TEXTURE_PAGING", shadowTexturePaging == true ? "1" : nil, .dropped),
            ("PVG_TEST_MSAA_TRANSFER", msaaTransfer == true ? "1" : nil, .dropped),
            ("PVG_HOST_AIR_LLVM", hostAIRLLVM, .dropped)
        ]
        for entry in entries {
            switch entry.inherited {
            case .dropped: environment[entry.name] = entry.value
            case .wins: if environment[entry.name] == nil { environment[entry.name] = entry.value }
            case .winsUnlessEmpty:
                if environment[entry.name]?.isEmpty ?? true, let value = entry.value {
                    environment[entry.name] = value
                }
            }
        }
    }
}
