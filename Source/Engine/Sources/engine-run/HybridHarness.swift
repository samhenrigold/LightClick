import CEngine
import Engine
import Foundation

// Plays QEMU and TCG for Tests/x86/kernel/hybrid.c, through the C interface the accelerator uses: hybrid config, RAM from a shared mapping as the app
// gives QEMU, split at 1 GB with the rest above 4 GB, full state read and write-back at each stop, a thread forcing boundaries.
final class HybridHarness {
    nonisolated(unsafe) static var current: HybridHarness?
    let below: UInt64 = 1 << 30
    let total: UInt64 = 2 << 30
    var handle: OpaquePointer!
    var ram: UnsafeMutableRawPointer!
    var exitCode: UInt32 = 255
    var failed: String?
    var deviceWrites: UInt64 = 0
    var pendingVector = false
    var acks = 0
    var slept: UInt64 = 0
    var portsSeen: [String] = []
    nonisolated(unsafe) var timerOn = false

    func host(_ gpa: UInt64) -> UnsafeMutableRawPointer { ram + Int(gpa >= 1 << 32 ? gpa - (1 << 32) + below : gpa) }
    func mailbox(_ i: Int) -> UInt64 { host(0x3000).load(fromByteOffset: i * 8, as: UInt64.self) }

    func command(_ n: UInt32) {
        switch n {
        case 1:
            if host((1 << 32) + 0x2000).load(as: UInt64.self) != 0xAABB_CCDD_EEFF_0011 {
                failed = "a guest write above 4 GB is not where the host looks"
            }
        case 2:
            host(mailbox(1)).storeBytes(of: UInt32(truncatingIfNeeded: mailbox(2)), as: UInt32.self)
            engine_note_write(handle, mailbox(1), 4)
        case 3:
            host(mailbox(1)).storeBytes(of: mailbox(2), as: UInt64.self)
            engine_note_write(handle, mailbox(1), 8)
        case 4:
            pendingVector = true
            engine_set_irq_line(handle, true)
            engine_kick(handle)
        case 5:
            if acks != 0 { failed = "acknowledged an interrupt with IF clear" }
        case 6:
            let t0 = mach_absolute_time()
            usleep(50_000)
            slept = mach_absolute_time() - t0
        case 7:
            // Every frame of low RAM, far more than the ring holds. Few are marked, so write far more notes than that: all of the kernel image.
            for _ in 0..<600 { engine_note_write(handle, 1 << 20, 16 << 20) }
        case 10: timerOn = true
        case 11: timerOn = false
        case 9:
            let want = ["1540:2:a5a52000", "1541:1:a5a50020", "112:1:a5a50006", "1544:4:12345678"]
            // Only the low `size` bytes of a value count: address_space_write takes those.
            if portsSeen != want { failed = "port writes were \(portsSeen)" }
        case 8:
            // Between the two rdtsc there is a little more than the sleep, so allow some way above 1.2.
            let ratio = Double(mailbox(1)) / (Double(slept) * 125 / 3)
            if ratio < 1.15 || ratio > 1.5 { failed = "TSC rate \(ratio) GHz, set to 1.2" }
        default:
            failed = "unknown command \(n)"
        }
    }

    // The instruction at rip ran elsewhere. r13: what it did. r14: its length.
    func playTCG(_ s: inout EngineX86State) {
        switch s.gpr.13 {
        case 1: s.gpr.3 = 0x1234
        case 2: s.cr0 &= ~8
        case 3:
            s.rip = s.gpr.11
            s.sel.1 = UInt16(truncatingIfNeeded: s.gpr.10)
            s.gpr.4 += 16
            return
        case 4: s.cr3 = s.gpr.12
        case 5: s.gpr.0 = 7
        case 6, 7:
            let image = host(s.gpr.12 &- 0xFFFF_8800_0000_0000) + 160
            withUnsafeMutableBytes(of: &s.xmm) { registers in
                if s.gpr.13 == 6 {
                    image.copyMemory(from: registers.baseAddress!, byteCount: 256)
                } else {
                    registers.baseAddress!.copyMemory(from: image, byteCount: 256)
                }
            }
        default: break
        }
        s.rip += s.gpr.14
    }

    func run(image: MachOImage) -> Int32 {
        HybridHarness.current = self
        ram = engine_test_shared_ram(total)
        var config = EngineConfig(
            ram_bytes: total, ram_host: ram, kernel_model: true, precise_flags: true, tso: true, tzcnt_lzcnt: false,
            ram_below_4g: below, hybrid: true)
        var ops = EngineMachineOps(
            opaque: nil,
            mmio_read: { _, gpa, _ in gpa &* 3 },
            mmio_write: { _, _, _, value in
                let h = HybridHarness.current!
                h.host(0x3000).storeBytes(of: value, as: UInt64.self)
                h.deviceWrites += 1
            },
            port_read: { _, _, _ in 0xFFFF_FFFF },
            port_write: { _, port, size, value in
                let h = HybridHarness.current!
                if port == 0x604 || port == 0x605 || port == 0x70 || port == 0x608 {
                    h.portsSeen.append("\(port):\(size):\(String(value, radix: 16))")
                    if port == 0x604 { engine_tally_port_write(h.handle, port, size, value, 0x1000) }
                } else if port == 0xE9 {
                    FileHandle.standardOutput.write(Data([UInt8(truncatingIfNeeded: value)]))
                } else if port == 0xF4 {
                    h.exitCode = value
                    engine_request_exit(h.handle)
                } else if port == 0xF8 {
                    h.command(value)
                }
            },
            read_msr: { _, _, _ in false },
            write_msr: { _, _, _ in false },
            cpuid: { _, _, _, _ in },
            acknowledge_interrupt: { _ in
                let h = HybridHarness.current!
                if !h.pendingVector { return -1 }
                h.pendingVector = false
                h.acks += 1
                return 0x40
            },
            has_interrupt_waiting: { _ in HybridHarness.current!.pendingVector },
            wait_for_interrupt: { _, _ in false },
            apic_eoi: { _, _ in },
            apic_icr: { _, _ in })
        guard let created = engine_create(&config, &ops) else { return 3 }
        handle = created
        host((1 << 32) + 0x1000).storeBytes(of: UInt64(0x1122_3344_5566_7788), as: UInt64.self)
        engine_mark_device(handle, 0xA0000, 0x1000)
        let tallyPath =
            ProcessInfo.processInfo.environment["ENGINE_TALLY"] ?? NSTemporaryDirectory() + "hybrid-tally-\(getpid())"
        tallyPath.withCString { engine_tally_start(handle, $0) }
        engine_set_tsc(handle, 0, 1 << 50, 1, 5)

        // The page tables cover the hole and everything above it: 5 GB of physmap.
        let root = KernelGuest.buildBootTables(image: image, ram: ram, ramBytes: (1 << 32) + total - below)
        var s = EngineX86State()
        engine_get_state(handle, &s)
        s.rip = image.entry!
        s.cr3 = root
        s.cr0 = 0x8001_0033
        s.cr4 = 0x620
        s.efer = 0xD01
        s.rflags = 2
        s.sel.1 = 0x08
        s.sel.2 = 0x10
        s.mxcsr = 0x1F80
        engine_set_state(handle, &s)

        let target = handle!
        Thread.detachNewThread {
            while true {
                usleep(2000)
                engine_request_boundary(target)
                if HybridHarness.current!.timerOn {
                    HybridHarness.current!.pendingVector = true
                    engine_set_irq_line(target, true)
                    engine_kick(target)
                }
            }
        }
        var fallbacks = 0
        var boundaries = 0
        while true {
            let result = engine_run(handle)
            switch result {
            case ENGINE_RUN_FALLBACK:
                fallbacks += 1
                engine_get_state(handle, &s)
                playTCG(&s)
                engine_set_state(handle, &s)
            case ENGINE_RUN_BOUNDARY:
                boundaries += 1
                engine_get_state(handle, &s)
                engine_set_state(handle, &s)
            case ENGINE_RUN_EXIT:
                if let failed {
                    FileHandle.standardError.write(Data("host check failed: \(failed)\n".utf8))
                    return 4
                }
                if deviceWrites == 0 { return 5 }
                engine_tally_refused(handle, "refused for the test")
                engine_tally_sample(handle, 0x1234, 0, 0)
                var text = [CChar](repeating: 0, count: 4096)
                engine_debug_text(handle, &text, 4096)
                if !String(cString: text).contains("in hv_vcpu_run: false") || engine_progress(handle) == 0 { return 8 }
                engine_tally_write(handle)
                let tally = (try? String(contentsOfFile: tallyPath, encoding: .utf8)) ?? ""
                for reason in [
                    "unknown opcode", "x87 instruction", "hlt", "far return", "mov cr8", "rdmsr 0x1b", "wrmsr 0x6e0",
                    "popcnt", "mmio form", "verr"
                ]
                where !tally.contains(reason) {
                    FileHandle.standardError.write(Data("tally lacks \(reason)\n".utf8))
                    return 6
                }
                if tally.contains("CR4 write") || !tally.contains("refused for the test")
                    || !tally.contains("tcg 0x1234") || !tally.contains("vmport")
                    || !tally.contains("port 0x604 size 2")
                    || !tally.contains("unslid") || !tally.contains("vector 0x7")
                    || !tally.contains("\nC 0x0 ")
                {
                    FileHandle.standardError.write(Data("tally has a wrong row\n".utf8))
                    return 9
                }
                if ProcessInfo.processInfo.environment["ENGINE_TALLY"] == nil { unlink(tallyPath) }
                FileHandle.standardError.write(
                    Data("hybrid: \(fallbacks) fallbacks, \(boundaries) boundary stops\n".utf8))
                return Int32(bitPattern: exitCode)
            case ENGINE_RUN_ERROR:
                FileHandle.standardError.write(
                    Data("engine stop: \(String(cString: engine_error_text(handle)))\n".utf8))
                return 2
            default:
                FileHandle.standardError.write(Data("guest halted for good\n".utf8))
                return 7
            }
        }
    }
}
