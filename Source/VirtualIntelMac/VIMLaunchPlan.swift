import Foundation

/// An image attached beyond the primary optical/disk slot.
@objcMembers
public final class LaunchImage: NSObject {
    public let slot: Int
    public let path: String
    public let format: String
    public init(slot: Int, path: String, format: String) {
        self.slot = slot
        self.path = path
        self.format = format
    }
}

/// What a launch depends on, already resolved. Reading files, querying the host
/// and reporting errors stay with the caller, so a plan is a pure function of this.
@objcMembers
public final class LaunchInput: NSObject {
    public var guest = ""
    public var machineName = ""
    public var machinePath = ""
    public var configuration: [String: Any] = [:]
    /// The app's own launch arguments, which carry the development options.
    public var processArguments: [String] = []
    public var inheritedEnvironment: [String: String] = [:]

    public var appleSilicon = false
    public var preMetalGuest = false
    public var openGLResearchGuest = false
    public var passthroughOpenGLEnabled = false
    public var installerDisplay = false
    public var hasPublishedGuestGraphics = false
    public var bootPolicySignatureOnly = false
    /// A research guest's own EFI or `--guest-efi`: skip the supported guests' policy.
    public var bootMediaOverridden = false

    public var biosPath = ""
    public var firmwarePath = ""
    public var nvramPath = ""
    public var bootMediaPath = ""
    public var diskPath = ""
    public var installerPath: String?
    public var runtimeDirectory = ""
    public var qmpPath = ""
    public var helperPath = ""
    public var donorPath = ""
    public var llvmPath = ""
    public var displaySocketPath = ""
    public var inprocessOpenGLLibrary: String?
    public var vramServiceIdentifier = ""

    public var guestWidth = 0
    public var guestHeight = 0
    public var displayMode = ""
    public var backingScaleFactor = 1.0
    public var supportsRetinaDisplay = false
    public var legacyDisplayRefreshMS = 0

    public var networkMode = "shared"
    public var macAddress = ""
    public var researchCPUModel: String?
    public var systemDiskInterface: String?

    public var audioOutputSelection = "default"
    public var audioInputSelection = "default"
    public var audioOutputRate = 0
    public var audioInputRate = 0
    public var audioOutputDeviceName: String?
    public var audioInputDeviceName: String?

    public var opticalPath: String?
    public var opticalFormat: String?
    public var additionalImages: [LaunchImage] = []
    public var imageUSBBus = ""
    public var imageUSBBasePort = 0
    public var setupMediaPath: String?
}

private enum Guest: String {
    case tiger, leopard, snowleopard, lion, mountainlion, mavericks, yosemite
    case elcapitan, sierra, highsierra, mojave, catalina, bigsur

    /// Only the early AppleUSBXHCI stack needs a low BAR and bulk-ring help.
    var earlyAppleXHCI: Bool {
        switch self {
        case .lion, .mountainlion, .mavericks, .yosemite: true
        case .tiger, .leopard, .snowleopard, .elcapitan, .sierra, .highsierra, .mojave, .catalina, .bigsur: false
        }
    }

    /// These Recovery images ship Apple16X50Serial but not Apple's QGA.
    var recoveryAgentOverSerial: Bool {
        switch self {
        case .mojave, .catalina: true
        case .tiger, .leopard, .snowleopard, .lion, .mountainlion, .mavericks, .yosemite,
            .elcapitan, .sierra, .highsierra, .bigsur:
            false
        }
    }

    /// The bundled MacPro5,1 profiles preserve the virtual DIMM records.
    var reportsDIMMSpeed: Bool {
        switch self {
        case .snowleopard, .lion, .mountainlion, .mavericks, .yosemite, .elcapitan, .sierra, .highsierra: true
        case .tiger, .leopard, .mojave, .catalina, .bigsur: false
        }
    }
}

/// QEMU's command line and environment for one launch. Argument order is part
/// of the contract: it assigns PCI slots that guests remember across boots.
@objcMembers
public final class LaunchPlan: NSObject {
    public let arguments: [String]
    public let environment: [String: String]

    /// Nil when the configuration lacks a guest or sizing that VIMMachine validates on load.
    public init?(input: LaunchInput) {
        guard let guest = Guest(rawValue: input.guest),
            let cpuCount = input.configuration["CPUCount"] as? NSNumber,
            let memory = input.configuration["MemoryMiB"] as? NSNumber
        else { return nil }
        arguments = Self.arguments(input, guest, cpuCount: cpuCount.stringValue, memory: memory.stringValue)
        environment = Self.environment(input, guest)
    }

    private static func optionPath(_ path: String) -> String {
        path.replacingOccurrences(of: ",", with: ",,")
    }

    private static func arguments(_ input: LaunchInput, _ guest: Guest, cpuCount: String, memory: String) -> [String] {
        let config = input.configuration
        let appleSilicon = input.appleSilicon
        let preMetal = input.preMetalGuest
        let installerDisplay = input.installerDisplay
        let options = input.processArguments
        func flag(_ key: String) -> Bool { (config[key] as? NSNumber)?.boolValue ?? false }
        func socket(_ name: String) -> String { optionPath(input.runtimeDirectory + "/" + name) }

        // The documented shared network is IPv4. Do not advertise a second IPv6
        // default route that can black-hole connections on IPv4-only host networks.
        var network = "user,id=net0,ipv6=off"
        if flag("SSHEnabled") {
            network += ",hostfwd=tcp:127.0.0.1:\((config["SSHPort"] as? NSNumber)?.intValue ?? 0)-:22"
        }
        if flag("FileSharingEnabled") {
            network += ",hostfwd=tcp:127.0.0.1:\((config["FileSharingPort"] as? NSNumber)?.intValue ?? 0)-:445"
        }
        if flag("ScreenSharingEnabled") {
            network += ",hostfwd=tcp:127.0.0.1:\((config["ScreenSharingPort"] as? NSNumber)?.intValue ?? 0)-:5900"
        }
        if input.networkMode != "shared" { network = "socket,id=net0,fd=0" }
        else if ProcessInfo.processInfo.environment["LC_NETWORK_OFF"] == "1" { network += ",restrict=on" } // test boots on a metered connection

        var cpu = "Penryn,vendor=GenuineIntel,+sse4.2,+popcnt,+aes,+pclmulqdq,+pcid"
        // Use one virtual timestamp rate on ARM. At the default 1 GHz, early
        // XNU releases can wrap their nanotime multiplier or have no matching
        // commpage routine. This is not an instruction-speed limit. Intel HVF
        // keeps its hardware counter.
        if appleSilicon { cpu += ",tsc-frequency=1200000000" }
        // xnu's rtc_timer_init takes the TSC-deadline timer whenever CPUID offers it, from Lion's
        // source through Big Sur's. Each LAPIC timer arm costs three MMIO accesses; this costs one
        // WRMSR. Enabled only for the guest it has been qualified on: extend once others boot.
        if appleSilicon && guest == .mavericks { cpu += ",+tsc-deadline" }
        // Development only. Per xnu's lapic_init, this alone switches Big Sur to x2APIC under a
        // hypervisor; Mountain Lion through Catalina also need the -x2apic boot argument.
        if appleSilicon && options.contains("--expose-x2apic") { cpu += ",+x2apic" }
        // Test boots only: ERMS steers a guest libc's memcpy to rep movsb, which the engine copies in bulk. Not qualified for users.
        if appleSilicon && ProcessInfo.processInfo.environment["LC_GUEST_ERMS"] == "1" { cpu += ",+erms" }
        // Mavericks rejects newer Intel models in cpuid_set_info before drivers
        // start (verified "Unsupported CPU" on the Ice Lake HVF host). Keep the
        // same supported Penryn identity as its TCG path; HVF still executes guest
        // instructions natively. Do not change supported production guests.
        if !appleSilicon && !preMetal { cpu = guest == .mojave ? "host,model=94" : "host" }
        // Explicit research comparison only: Mavericks knows Haswell, unlike
        // this host's newer CPUID model. Preserve the normal guest and TCG paths.
        if input.researchCPUModel == "haswell" { cpu = "Haswell,vendor=GenuineIntel,+pcid,-hle,-rtm" }

        let sataDisk = "ide-hd,bus=ide.1,drive=macos,bootindex=2,rotation_rate=1"
        let nvmeDisk = "nvme,drive=macos,serial=VIM00000001,bus=pcie.0,addr=0x8,bootindex=2"
        // Big Sur on ARM TCG can hand off to XNU over SATA and then wait
        // indefinitely for its root volume. The same installed disk boots over
        // native NVMe. Keep the controller stable across later update boots;
        // leave Intel, earlier systems and ongoing installations on SATA.
        let installState = config["InstallState"] as? String
        let installedBigSur =
            appleSilicon && guest == .bigsur && (installState == "installed" || installState == "imported-prepared")
        var systemDisk = installedBigSur ? nvmeDisk : sataDisk
        if let interface = input.systemDiskInterface { systemDisk = interface == "nvme" ? nvmeDisk : sataDisk }

        var xhci = "qemu-xhci,id=xhci,bus=pcie.0,addr=0x7"
        // El Capitan binds the 64-bit BAR, but its MSI-X path delays physical
        // storage completions. Classic MSI also serves the earlier driver.
        if guest.earlyAppleXHCI || guest == .elcapitan { xhci += ",msi=on,msix=off,conditional-intr-mapping=on" }
        if guest.earlyAppleXHCI { xhci += ",x-bar-32bit=on,x-bulk-event-data=on" }

        // Research-only surface-provider bring-up. Never changes the
        // supported guests' installer adapter or pretends this is PVG.
        let openGLSVGA = installerDisplay && preMetal && config["LegacyDisplayAdapter"] as? String == "vmware"

        var a = [
            // Input uses USB throughout, including firmware. Do not also publish an
            // unused PS/2 keyboard: the legacy Voodoo driver identifies it as generic
            // and independently triggers Keyboard Setup Assistant despite Apple USB ID.
            "-name", optionPath(input.machineName), "-L", input.biosPath, "-machine", "q35,i8042=off",
            // --development-tcg is explicit development isolation: keep the production devices,
            // memory and display path while enabling TCG's guest watchpoints on an Intel builder.
            "-accel", appleSilicon || options.contains("--development-tcg") ? "tcg,thread=multi" : "hvf",
            // v1 does not implement reliable S3/S4 resume. Do not advertise these
            // states to macOS in the first place; pmset sleep=0 remains a second
            // safeguard, rather than the sole defense against an idle timer.
            "-global", "ICH9-LPC.disable_s3=1", "-global", "ICH9-LPC.disable_s4=1",
            "-cpu", cpu, "-smp", cpuCount, "-m", memory,
            "-object",
            appleSilicon
                ? "memory-backend-shm,id=pvg-ram,size=\(memory)M,share=on"
                : "memory-backend-ram,id=pvg-ram,size=\(memory)M",
            "-machine", "memory-backend=pvg-ram", "-nodefaults",
            "-vga", installerDisplay ? (openGLSVGA ? "vmware" : "std") : "none"
        ]
        // The installer display has no PVG. Otherwise the existing QEMU property
        // supplies the initial native display mode; no fixed 1920-wide default or
        // wait for the desktop/guest tool.
        if !installerDisplay {
            a += [
                "-device",
                "{\"display-modes\":[\"\(input.guestWidth)x\(input.guestHeight)@60\"],\"driver\":\"apple-gfx-pci\"}"
            ]
        }
        a += [
            "-display", "none",
            // Darwin9's EHCI uses legacy IRQ10. Keep it off VGA's PIRQ F,
            // whose PIC alias is deliberately disabled after _PIC(1). Slot5
            // routes EHCI INTD to PIRQ E instead; newer guests retain their map.
            "-device", guest == .leopard ? "ich9-usb-ehci1,id=usb,bus=pcie.0,addr=0x5" : "ich9-usb-ehci1,id=usb",
            "-device", "usb-kbd,id=keyboard,bus=usb.0,port=1,apple-ansi=on",
            // USB passthrough bus (USB 2 and 3). A fixed slot after the network
            // adapter's leaves existing device addresses and services unchanged.
            "-device", xhci,
            "-device", "usb-tablet,id=tablet,bus=usb.0,port=2",
            // Apple's Intel guest agent opens this exact VirtIO console name.
            // Keep its control endpoint inside the per-session private directory;
            // unlike network forwarding it is never exposed on a TCP interface.
            "-device", "virtio-serial-pci,id=guestserial",
            "-chardev", "socket,id=guestagent,path=\(socket("guest-agent")),server=on,wait=off",
            // Older systems have Apple16X50Serial but no AppleVirtIOConsole.
            // Keep metadata local and on the same app-owned QGA socket. Graphics
            // and bulk support-media delivery never travel over this slow UART.
            "-device",
            preMetal
                ? "isa-serial,chardev=guestagent,index=1"
                : "virtserialport,bus=guestserial.0,chardev=guestagent,name=org.qemu.guest_agent.0",
            // A distinct channel, never another client of the guest-agent socket.
            // Present it even when sharing is off so enabling it needs no restart.
            "-chardev", "socket,id=clipboard,path=\(socket("clipboard")),server=on,wait=off",
            "-device",
            preMetal
                ? "isa-serial,chardev=clipboard,index=0"
                : "virtserialport,bus=guestserial.0,chardev=clipboard,name=org.vim.clipboard",
            // Old donated framebuffer drivers do not report DPMS to host PVG.
            // Dedicated metadata events remain available with clipboard disabled.
            "-chardev", "socket,id=displaypower,path=\(socket("displaypower")),server=on,wait=off",
            "-device", "virtserialport,bus=guestserial.0,chardev=displaypower,name=org.vim.display"
        ]
        if guest.recoveryAgentOverSerial {
            // Installed macOS keeps its native VirtIO channel; only the Recovery
            // service opens COM2. No graphics or payload archive uses this UART.
            a += [
                "-chardev", "socket,id=recoveryagent,path=\(socket("recovery-agent")),server=on,wait=off",
                "-device", "isa-serial,chardev=recoveryagent,index=1"
            ]
        }
        // Native Tiger's 16X50 driver requires the dedicated ISA edge/high
        // contract, not upstream AML's shared level interrupt. Repeated native
        // boots and verified bulk/control traffic qualify this Tiger-only path.
        if guest == .tiger { a += ["-global", "isa-serial.acpi-irq-edge=on"] }
        if !input.bootMediaOverridden && !preMetal {
            // One immutable EFI per OS. OpenCore reads these eight bytes once through
            // QEMU fw_cfg, after OpenCore's baseline and before macOS starts.
            let preparedGL = guest == .bigsur && input.hasPublishedGuestGraphics
            a += [
                "-fw_cfg",
                "name=opt/org.virtualintelmac/boot-policy,string=VIM1\(input.bootPolicySignatureOnly ? "S" : "L")\(preparedGL ? "1" : "0")00"
            ]
        }
        // Boot-time only; older per-OS firmware ignores this named item. The
        // unified image uses it before loading the unchanged OpenCore profile.
        a += ["-fw_cfg", "name=opt/org.virtualintelmac/firmware-profile,string=\(input.guest)"]
        if guest == .elcapitan {
            // Actual 15G31 recovery relocates the low halves of 64-bit PCI BARs
            // below 4GB but leaves OVMF's high dwords in the device. Its page table
            // maps XHCI at 0x88004000 while the device decodes 0x888004000; the first
            // capability read returns all ones and Apple's unplug path panics.
            // OVMF's native zero-aperture policy allocates the complete BAR below
            // 4GB up front. Keep USB3 and native drivers, not an Apple kext patch.
            a += ["-fw_cfg", "name=opt/ovmf/X-PciMmio64Mb,string=0"]
        }
        if config["AudioEnabled"] == nil || flag("AudioEnabled") {
            // QEMU otherwise fixes its mixer at 44.1 kHz even on a 48 kHz host.
            // Match the selected output's current rate: avoid a second converter
            // after guest mixing, without changing the host device or queue size.
            // Capture also follows its selected physical device, independently of
            // output. Avoid SDL's native-input -> 44.1 kHz -> guest-rate chain.
            var audio = "sdl,id=audio0,out.frequency=\(input.audioOutputRate),in.frequency=\(input.audioInputRate)"
            if input.audioInputSelection == "disabled" { audio += ",in.voices=0" }
            if input.audioOutputSelection == "disabled" { audio += ",out.voices=0" }
            a += ["-audiodev", audio]
            // Keep this in the original PCI-device order so existing network
            // service associations are not disturbed by the sound implementation.
            // Big Sur ships AppleVirtIOSound (IOVirtIOPrimaryMatch 0x00191af4).
            if guest == .bigsur {
                a += ["-device", "virtio-sound-pci,audiodev=audio0,x-apple-reconfigure=on"]
            } else {
                a += ["-device", "intel-hda,id=hda", "-device", "hda-duplex,bus=hda.0,audiodev=audio0"]
                // Explicit development-only cold-codec trace through the normal app
                // launch. No QEMU debugger or additional control connection is needed.
                if options.contains("--trace-hda-codec") {
                    a += ["-global", "intel-hda.debug=2", "-global", "hda-duplex.debug=2"]
                }
            }
        }
        // Report a period-appropriate nominal speed in SMBIOS, not a host
        // bandwidth claim. Capacity, memory timing and the TSC are unchanged.
        if !input.bootMediaOverridden && guest.reportsDIMMSpeed { a += ["-smbios", "type=17,speed=1066"] }
        if !input.bootMediaOverridden && preMetal, let identifier = config["Identifier"] as? String,
            let uuid = UUID(uuidString: identifier)
        {
            // Older bundled profiles leave the serial empty. Supply a clearly
            // virtual, stable identifier without borrowing the host's identity
            // or changing the firmware profile, hardware UUID, or board ID.
            a += ["-smbios", "type=1,serial=\(uuid.uuidString.suffix(12))"]
        }
        a += [
            "-device", "isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc", "-smbios",
            "type=2",
            "-drive", "if=pflash,format=raw,readonly=on,file=\(optionPath(input.firmwarePath))",
            "-drive", "if=pflash,format=raw,file=\(optionPath(input.nvramPath))",
            "-drive", "id=opencore,if=none,format=raw,snapshot=on,file=\(optionPath(input.bootMediaPath))",
            // OVMF has NvmExpressDxe, while native Tiger has no NVMe block driver.
            // Keep the bootloader disk available to firmware, not Disk Arbitration:
            // an ESP-only IDE disk otherwise races Tiger's unreadable-media dialog
            // before its guest agent can register a per-disk no-mount policy.
            // The installed OS disk stays on the same native IDE controller.
            "-device",
            guest == .tiger
                ? "nvme,bus=pcie.0,addr=0x8,drive=opencore,bootindex=1,serial=VIMFirmwareEFI"
                : "ide-hd,bus=ide.0,drive=opencore,bootindex=1,rotation_rate=1",
            "-drive", "id=macos,if=none,format=qcow2,file=\(optionPath(input.diskPath))",
            "-device", systemDisk,
            // On q35 the auto-assigned slot 5 shares INTx with EHCI (IRQ 21).
            // Apple's 8254X filter can consume the masked initial LSC while
            // servicing that unrelated USB interrupt, leaving en0 inactive.
            // Reserve slot 6 / IRQ 22: no emulated-register or guest-driver patch,
            // link reset, or delayed boot-time reconnect is necessary.
            "-device", "e1000-82545em,id=ethernet,bus=pcie.0,addr=0x6,netdev=net0,mac=\(input.macAddress)",
            "-qmp", "unix:\(input.qmpPath),server=on,wait=off",
            // "file:" takes the rest of the option as a literal path, so unlike the
            // options above a comma here must not be doubled. -debugcon below too.
            "-serial", preMetal ? "none" : "file:\(input.machinePath)/State/serial.log",
            "-monitor", "none", "-action", "reboot=shutdown",
            "-netdev", network
        ]
        // Establish an unplugged cable before executing any guest instruction.
        // Keep the backend available so reconnecting never needs a guest reboot.
        let openGLInprocess = input.inprocessOpenGLLibrary != nil
        if openGLInprocess || (config["NetworkConnected"] != nil && !flag("NetworkConnected")) { a.append("-S") }
        // Explicit development diagnosis only: capture boot-time PHY accesses
        // through QEMU's disabled-by-default tracing, not a second QMP client.
        if options.contains("--trace-network") {
            a += ["-trace", "enable=e1000_*", "-trace", "enable=e1000x_link_negotiation_*"]
        }
        if options.contains("--trace-cursor") { a += ["-trace", "enable=vmware_cursor_define"] }
        if options.contains("--trace-image-enumeration") { a += ["-trace", "enable=usb_msd_maxlun"] }
        if options.contains("--firmware-diagnostics") {
            a += ["-debugcon", "file:\(input.machinePath)/State/firmware.log", "-global", "isa-debugcon.iobase=0x402"]
        }
        // Kernel debugging for the opt-in legacy harness, bound to loopback only.
        // Does not open a second QMP owner or expose debug access in normal VMs.
        let gdbPort = (config["LegacyGDBPort"] as? NSNumber)?.intValue ?? 0
        if input.openGLResearchGuest && gdbPort > 0 && gdbPort <= 65535 { a += ["-gdb", "tcp:127.0.0.1:\(gdbPort)"] }
        // Independent read-only support media: never take over the user's CD/DVD
        // or the macOS installer. Insert only during setup and eject after copying.
        a += [
            "-drive", "id=setup-support,if=none,media=cdrom,readonly=on", "-device",
            "ide-cd,id=setup-support-device,bus=ide.4,drive=setup-support"
        ]
        let diskImage = input.opticalFormat == "dmg"
        let optical = input.opticalPath.map(optionPath)
        a += [
            "-drive",
            optical != nil && !diskImage
                ? "id=cdrom,if=none,media=cdrom,format=raw,readonly=on,file=\(optical!)"
                : "id=cdrom,if=none,media=cdrom,readonly=on",
            "-device", "ide-cd,id=cdrom-device,bus=ide.3,drive=cdrom"
        ]
        // DMGs are disks, not optical sectors: preserve their 512-byte geometry
        // through a stock USB/SCSI removable device. Both backends are read-only;
        // the unused drive has no medium, not a converted or cached placeholder.
        a += [
            "-drive",
            diskImage
                ? "id=removable-image,if=none,media=disk,format=dmg,readonly=on,file=\(optical ?? "")"
                : "id=removable-image,if=none,media=disk,readonly=on",
            "-device", "usb-bot,id=image-usb,bus=\(input.imageUSBBus),port=\(input.imageUSBBasePort)",
            "-device",
            "scsi-hd,id=image-device,bus=image-usb.0,drive=removable-image,removable=on,logical_block_size=512,physical_block_size=512"
        ]
        for image in input.additionalImages {
            let backend = "image-backend-\(image.slot)"
            let transport = "image-usb-\(image.slot)"
            a += [
                "-drive",
                "id=\(backend),if=none,media=disk,readonly=on,format=\(image.format),file=\(optionPath(image.path))",
                "-device",
                "usb-bot,id=\(transport),bus=\(input.imageUSBBus),port=\(input.imageUSBBasePort + image.slot)",
                "-device",
                "scsi-hd,id=image-disk-\(image.slot),bus=\(transport).0,drive=\(backend),removable=on,logical_block_size=512,physical_block_size=512"
            ]
        }
        if let setup = input.setupMediaPath {
            a += [
                "-drive", "id=opengl-setup,if=none,media=cdrom,format=raw,readonly=on,file=\(optionPath(setup))",
                "-device", "ide-cd,id=opengl-setup-device,bus=ide.5,drive=opengl-setup"
            ]
        }
        if openGLSVGA && input.passthroughOpenGLEnabled {
            a += [
                "-global", "vmware-svga.passthrough-opengl-bridge=on", "-global", "vmware-svga.vgamem_mb=512",
                // This research layout's SVGA/EHCI use native GSI21.
                // Remove only their duplicate PIC fanout after _PIC(1),
                // preserving SATA's real legacy route and boot PIC mode.
                "-global", "ICH9-LPC.x-apic-pirq-f-native-only=on"
            ]
            // This installed research guest uses the installer display
            // transport, not installer display semantics. A real panel
            // contract lets Mavericks choose HiDPI without a preference.
            let explicitMode = config["DisplayMode"] != nil || config["RetinaEnabled"] != nil
            let retina = input.displayMode == "retina" && (explicitMode || input.backingScaleFactor > 1)
            // Panel capability is hardware, not the current UI choice.
            // Booting Scaled must not turn a Retina host into a low-DPI
            // physical panel: 10.8 then omits every native 2x mode and
            // cannot switch back to Retina without another boot. Keep
            // both choices available; guest-display selects the requested
            // 1x/2x mode through the existing production path afterward.
            let retinaPanel = input.supportsRetinaDisplay && (retina || input.backingScaleFactor > 1)
            a += [
                "-global", "vmware-svga.passthrough-opengl-panel-width=\(retinaPanel ? 2560 : 1280)",
                "-global", "vmware-svga.passthrough-opengl-panel-height=\(retinaPanel ? 1600 : 800)",
                "-global", "vmware-svga.passthrough-opengl-ui-scale=\(retinaPanel ? 2 : 1)"
            ]
        }
        if installerDisplay && !openGLSVGA { a += ["-global", "VGA.xres=1280", "-global", "VGA.yres=800"] }
        if let installer = input.installerPath {
            let disk = config["InstallerMediaKind"] as? String == "disk"
            a += [
                "-drive",
                "id=installer,if=none,format=raw,\(disk ? "snapshot=on" : "readonly=on"),file=\(optionPath(installer))",
                "-device",
                disk
                    ? "ide-hd,bus=ide.2,unit=0,drive=installer,bootindex=3,rotation_rate=1"
                    : "ide-cd,bus=ide.2,unit=0,drive=installer,bootindex=3"
            ]
        }
        return a
    }

    private static func environment(_ input: LaunchInput, _ guest: Guest) -> [String: String] {
        var options = MachineOptions(configuration: input.configuration)
        // hvdbt_want_engine stops QEMU past 8 vCPUs, which Settings says means Software.
        let cpuCount = (input.configuration["CPUCount"] as? NSNumber)?.intValue ?? 0
        if !input.appleSilicon || cpuCount > 8 { options.engine = nil }
        if !input.appleSilicon { options.meltdownProtection = nil }
        if let library = input.inprocessOpenGLLibrary {
            options.passthroughOpenGLInprocessLibrary = library
            options.passthroughOpenGLInline = true
            options.passthroughOpenGLSurfaceImport = true
            options.displayEventDriven = true
            options.openGLVRAMService = "gold.samhenri.LightClick.ram." + input.vramServiceIdentifier
            options.openGLVRAMEndpoint = input.runtimeDirectory + "/vram-endpoint.plist"
            options.openGLDisplayEndpoint = input.runtimeDirectory + "/graphics-endpoint.plist"
        }
        options.audioOutputDevice = input.audioOutputDeviceName
        options.audioInputDevice = input.audioInputDeviceName
        options.inputBackpressure = true
        options.e1000LinkHistory = input.processArguments.contains("--record-network-history")
        // Panel capability, not the current logical mode. Creating a 1x-only
        // PVG panel prevents macOS from advertising any 2x mode for a later
        // live Retina selection. The guest-display tool selects 1x or 2x.
        options.appDisplayScale = 2
        if input.appleSilicon {
            options.oopHelper = input.helperPath
            options.oopDonor = input.donorPath
            options.oopScaleFactor = 2
            options.preserveIOSurface = true
            options.shadowCoalesce = true
            options.shadowMaxChunk = 1_048_576
            options.shadowTexturePaging = true
            // The AIR repair is genuinely Mojave-only.
            if guest == .mojave { options.hostAIRLLVM = input.llvmPath }
        } else {
            // The framework cannot raw-blit packed multisample depth/stencil. The
            // ordered transfer adapter was qualified in the CLI harness, but omitted
            // when that harness became this app. Keep its quiet path enabled on Intel;
            // it preserves samples and the original command-buffer event ordering.
            options.msaaTransfer = true
        }
        if input.installerDisplay {
            options.installerDisplaySocket = input.displaySocketPath
            if input.preMetalGuest && input.passthroughOpenGLEnabled {
                // The ordinary embedded display defaults to a 30-ms poll. That
                // caps the accelerated research scanout at ~33 Hz before any
                // rendering/ACK cost. This does not change supported guest paths.
                let interval = input.legacyDisplayRefreshMS
                options.displayRefreshMS = interval >= 5 && interval <= 1000 ? interval : 16
            }
        } else {
            options.appDisplaySocket = input.displaySocketPath
        }
        // Host tuning must not leak between development launches or architectures.
        var env = input.inheritedEnvironment.filter { !$0.key.hasPrefix("PVG_") }
        env["DYLD_INSERT_LIBRARIES"] = nil
        options.apply(to: &env)
        return env
    }
}
