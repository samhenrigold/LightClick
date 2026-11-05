import CEngine
import Foundation
import Hypervisor

/// What the embedding machine provides: x86 devices, MSRs and CPUID stay out here. QEMU's AccelOps layer is meant to implement
/// this protocol; see `DESIGN.md`. Each call runs on the vCPU thread with the guest stopped at an x86 boundary or an ARM load.
public protocol EngineMachine: AnyObject {
    func mmioRead(address: UInt64, size: Int) -> UInt64
    func mmioWrite(address: UInt64, size: Int, value: UInt64)
    func portRead(port: UInt16, size: Int) -> UInt32
    func portWrite(port: UInt16, size: Int, value: UInt32)
    func readMSR(_ msr: UInt32) -> UInt64?
    func writeMSR(_ msr: UInt32, value: UInt64) -> Bool
    func cpuid(leaf: UInt32, subleaf: UInt32) -> (eax: UInt32, ebx: UInt32, ecx: UInt32, edx: UInt32)
    /// Returns the next external interrupt vector the local APIC model would deliver, if any.
    func acknowledgeInterrupt() -> UInt8?
    /// The guest ran `hlt`. Blocks until an interrupt may be pending. False: nothing can ever wake it, the run ends.
    func waitForInterrupt() -> Bool
    /// User-mode shim only: an x86 `syscall` with no kernel model. Registers are in `state`.
    func syscall(_ state: UnsafeMutablePointer<EngineCtx>, engine: Engine) throws
}

public struct EngineOptions: Sendable {
    public var ramBytes: UInt64 = 2 << 30
    public var preciseFlags = true
    public var useTSO = true
    public var kernelModel = false
    public init() {}
}

public enum RunOutcome: Equatable, Sendable {
    case halted(rax: UInt64)
    case exited(code: Int32)
}

/// One VM with one x86 vCPU, created and run on the calling thread.
public final class Engine {
    public let options: EngineOptions
    public let ram: UnsafeMutableRawPointer
    let priv: UnsafeMutableRawPointer
    public let ctx: UnsafeMutablePointer<EngineCtx>
    public weak var machine: EngineMachine?
    var vcpu: hv_vcpu_t = 0
    var vcpuExit: UnsafeMutablePointer<hv_vcpu_exit_t>!
    public private(set) var exitCount: UInt64 = 0
    private nonisolated(unsafe) var watchdogFired = false
    private var trace = Int(ProcessInfo.processInfo.environment["ENGINE_TRACE"] ?? "") ?? 0
    public var exitCode: Int32?

    public init(options: EngineOptions) throws {
        self.options = options
        try hvCheck("hv_vm_create") {
            let config = hv_vm_config_create()
            if #available(macOS 26.0, *) {
                _ = hv_vm_config_set_ipa_granule(config, HV_IPA_GRANULE_16KB)
            }
            return hv_vm_create(config)
        }
        func anon(_ bytes: UInt64) throws -> UnsafeMutableRawPointer {
            let p = mmap(nil, Int(bytes), PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
            guard let p, p != MAP_FAILED else { throw EngineError.stop("mmap failed") }
            return p
        }
        ram = try anon(options.ramBytes)
        priv = try anon(kPrivSize)
        ctx = (priv + Int(kOffCtx)).bindMemory(to: EngineCtx.self, capacity: 1)
        let rwx = hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)
        try hvCheck("hv_vm_map ram") { hv_vm_map(ram, 0, Int(options.ramBytes), rwx) }
        try hvCheck("hv_vm_map private") { hv_vm_map(priv, kPrivIPA, Int(kPrivSize), rwx) }
        try loadMonitor()
        var config = TrConfig()
        config.priv = priv.assumingMemoryBound(to: UInt8.self)
        config.ram = ram.assumingMemoryBound(to: UInt8.self)
        config.ram_size = options.ramBytes
        config.precise_flags = options.preciseFlags
        let stubs = kPrivVA + kOffStubs
        config.stub_lookup = stubs
        config.stub_ret_miss = stubs + 0x80
        config.stub_pushf = stubs + 0x100
        config.stub_sahf = stubs + 0x180
        tr_init(&config)
        try setUpVCPU()
    }


    // ---- Private memory ----
    private func loadMonitor() throws {
        let bytes = Array(UnsafeBufferPointer(start: engine_monitor_macho_ptr(), count: engine_monitor_macho_size()))
        let image = try MachOImage(bytes: bytes)
        image.copy(to: priv, origin: kPrivVA)

        // Static tables for the private slots, 2 MB blocks, shared by every shadow root.
        var next = kOffPT
        func table() -> UInt64 {
            let at = next
            next += 4096
            return at
        }
        func slot(_ tableOff: UInt64, _ index: Int) -> UnsafeMutablePointer<UInt64> {
            (priv + Int(tableOff)).assumingMemoryBound(to: UInt64.self) + index
        }
        func ipa(_ off: UInt64) -> UInt64 { kPrivIPA + off }
        let valid: UInt64 = 3
        let af: UInt64 = 1 << 10
        let sh: UInt64 = 3 << 8
        let uxn: UInt64 = 1 << 54
        let pxn: UInt64 = 1 << 53
        let apEL1RW: UInt64 = 0 << 6
        let apRW: UInt64 = 1 << 6
        let apEL1RO: UInt64 = 2 << 6
        let apRO: UInt64 = 3 << 6
        let block = af | sh | 1

        // Boot root, used until the monitor builds the first view.
        let bootRoot = table()
        let privL1 = table()
        let privL2 = table()
        let rstackL2Index = Int((kOffRStacks >> 21) & 0x1FF)
        let rstackL3 = table()
        slot(bootRoot, Int((kPrivVA >> 39) & 0x1FF)).pointee = ipa(privL1) | valid
        slot(privL1, Int((kPrivVA >> 30) & 0x1FF)).pointee = ipa(privL2) | valid
        var off: UInt64 = 0
        while off < kPrivSize {
            var attrs: UInt64
            switch off {
            case kOffMonText..<kOffMonData: attrs = apEL1RO | uxn  // monitor text: EL1 execute
            case kOffStubs..<(kOffCC + kCCSize): attrs = apEL1RW | pxn  // stubs and code: EL0 execute-only
            case kOffCtx..<kOffRStacks: attrs = apRW | uxn | pxn
            case kOffHash..<kOffBlocks: attrs = apRO | uxn | pxn
            default: attrs = apEL1RW | uxn | pxn
            }
            if off == kOffStubs { attrs = apEL1RO | pxn }
            slot(privL2, Int(off >> 21)).pointee = ipa(off) | block | attrs
            off += 2 << 20
        }
        // Return stacks: a writable run with an unmapped guard below each.
        slot(privL2, rstackL2Index).pointee = ipa(rstackL3) | valid
        var page: UInt64 = 0
        while page < 2 << 20 {
            let inSlot = page % kRStackSlot
            if inSlot < kRStackBytes {
                slot(rstackL3, Int(page >> 12)).pointee =
                    ipa(kOffRStacks + page) | valid | af | sh | apRW | uxn | pxn
            }
            page += 4096
        }
        // RAM alias for the monitor: 1 GB blocks where possible.
        let ramL1 = table()
        var gb: UInt64 = 0
        while gb < options.ramBytes {
            slot(ramL1, Int((kRamAliasVA + gb) >> 30) & 0x1FF).pointee = gb | block | apEL1RW | uxn | pxn
            gb += 1 << 30
        }
        // Handed to the monitor: the root-level descriptors of its private slots.
        let handoff = (priv + Int(kOffMonData) + (1 << 20)).assumingMemoryBound(to: UInt64.self)
        handoff[0] = ipa(privL1) | valid
        handoff[1] = ipa(ramL1) | valid
        slot(bootRoot, Int((kRamAliasVA >> 39) & 0x1FF)).pointee = ipa(ramL1) | valid
        bootTTBR = ipa(bootRoot)
    }
    private var bootTTBR: UInt64 = 0

    private func setUpVCPU() throws {
        try hvCheck("hv_vcpu_create") { hv_vcpu_create(&vcpu, &vcpuExit, nil) }
        func sys(_ reg: hv_sys_reg_t, _ value: UInt64) throws {
            try hvCheck("set sys reg") { hv_vcpu_set_sys_reg(vcpu, reg, value) }
        }
        var actlr: UInt64 = 0
        hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_ACTLR_EL1, &actlr)
        try sys(HV_SYS_REG_ACTLR_EL1, options.useTSO ? actlr | 2 : actlr & ~2)
        try sys(HV_SYS_REG_MAIR_EL1, 0xFF)
        // 48-bit VA both ways, 4 KB granule, 16-bit ASIDs from TTBR0, 36-bit IPA.
        let tcr: UInt64 =
            16 | 16 << 16 | 3 << 12 | 1 << 10 | 1 << 8 | 3 << 28 | 1 << 26 | 1 << 24 | 2 << 30 | 1 << 32 | 1 << 36
        try sys(HV_SYS_REG_TCR_EL1, tcr)
        try sys(HV_SYS_REG_TTBR0_EL1, bootTTBR)
        try sys(HV_SYS_REG_TTBR1_EL1, bootTTBR)
        try sys(HV_SYS_REG_VBAR_EL1, engine_sym_mon_vectors)
        // MMU, caches, nAA for LSE2, RES1 bits.
        try sys(HV_SYS_REG_SCTLR_EL1, 0x30D0_0800 | 1 | 1 << 2 | 1 << 12 | 1 << 6)
        try sys(HV_SYS_REG_CPACR_EL1, 3 << 20)
        try sys(HV_SYS_REG_SP_EL1, kPrivVA + kOffMonData + (2 << 20) - 16)
        try hvCheck("set x18") { hv_vcpu_set_reg(vcpu, HV_REG_X18, kPrivVA + kOffCtx) }
        ctx.pointee.ram_size = options.ramBytes
        ctx.pointee.df = 1
        ctx.pointee.rflags_sys = 0x202
        ctx.pointee.spsr = 1 << 29  // EL0t, C set: x86 CF clear
        ctx.pointee.model_kernel = options.kernelModel ? 1 : 0
        ctx.pointee.cr0 = 0x8001_0033
        ctx.pointee.cr4 = 0x620
        ctx.pointee.efer = 0xD01
        // Everything below 1 MB of RAM frames counts as plain RAM; page_info bits start at zero.
    }

    // ---- Running ----

    /// Starts the x86 CPU at `rip`. The caller filled registers in `ctx` and page tables in RAM.
    public func run(entry rip: UInt64) throws -> RunOutcome {
        ctx.pointee.req_a.0 = rip
        if let seconds = ProcessInfo.processInfo.environment["ENGINE_WATCHDOG"].flatMap(Double.init) {
            let target = vcpu
            Thread.detachNewThread { [weak self] in
                Thread.sleep(forTimeInterval: seconds)
                self?.watchdogFired = true
                var v = target
                hv_vcpus_exit(&v, 1)
            }
        }
        try hvCheck("set pc") { hv_vcpu_set_reg(vcpu, HV_REG_PC, engine_sym_mon_init) }
        try hvCheck("set cpsr") { hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3C5) }
        return try runLoop()
    }

    private func runLoop() throws -> RunOutcome {
        while true {
            let r = hv_vcpu_run(vcpu)
            if r != HV_SUCCESS { throw EngineError.hypervisor("hv_vcpu_run", r) }
            exitCount += 1
            switch vcpuExit.pointee.reason {
            case HV_EXIT_REASON_EXCEPTION:
                let syndrome = vcpuExit.pointee.exception.syndrome
                let ec = syndrome >> 26
                if ec != 0x16 {
                    var pc: UInt64 = 0
                    hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc)
                    throw EngineError.stop(
                        "unexpected exit: syndrome \(hex(syndrome)) pc \(hex(pc)) va \(hex(vcpuExit.pointee.exception.virtual_address))")
                }
                var code: UInt64 = 0
                hv_vcpu_get_reg(vcpu, HV_REG_X0, &code)
                if trace > 0 {
                    trace -= 1
                    FileHandle.standardError.write(
                        Data(
                            "hc \(code) a0 \(hex(ctx.pointee.req_a.0)) a1 \(hex(ctx.pointee.req_a.1)) a2 \(hex(ctx.pointee.req_a.2)) elr \(hex(ctx.pointee.elr)) esr \(hex(ctx.pointee.esr))\n"
                                .utf8))
                }
                if let outcome = try hostCall(Int(code)) { return outcome }
            case HV_EXIT_REASON_CANCELED:
                if watchdogFired {
                    var pc: UInt64 = 0
                    var elr: UInt64 = 0
                    var esr: UInt64 = 0
                    var far: UInt64 = 0
                    hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc)
                    hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_ELR_EL1, &elr)
                    hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_ESR_EL1, &esr)
                    hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_FAR_EL1, &far)
                    let regs = withUnsafeBytes(of: &ctx.pointee.x) { Array($0.bindMemory(to: UInt64.self)) }
                    throw EngineError.stop(
                        "watchdog: pc \(hex(pc)) elr \(hex(elr)) esr \(hex(esr)) far \(hex(far)) exits \(exitCount) "
                            + "ctx.elr \(hex(ctx.pointee.elr)) x16 \(hex(regs[16])) x30 \(hex(regs[30]))")
                }
                continue
            case HV_EXIT_REASON_VTIMER_ACTIVATED:
                hv_vcpu_set_vtimer_mask(vcpu, true)
                continue
            default:
                throw EngineError.stop("unexpected exit reason \(vcpuExit.pointee.reason)")
            }
        }
    }

    public func stats() -> String {
        let t = tr_stats()
        var line =
            "exits \(exitCount) blocks \(t.blocks) x86-insns \(t.insns) arm-words \(t.words) "
            + "invalidated \(t.invalidated) fills \(ctx.pointee.stat_fills) dirty \(ctx.pointee.stat_dirty) "
            + "smc \(ctx.pointee.stat_smc) pfs \(ctx.pointee.stat_pf_delivered) pt-writes \(ctx.pointee.stat_pt_writes) "
            + "steps \(ctx.pointee.stat_steps) irqs \(ctx.pointee.stat_irq)"
        if t.insns > 0 { line += String(format: " words/insn %.2f", Double(t.words) / Double(t.insns)) }
        return line
    }

    private func hostCall(_ code: Int) throws -> RunOutcome? {
        let c = ctx
        switch code {
        case Int(HC_TRANSLATE):
            let view = Int32(c.pointee.req_a.0)
            let rip = c.pointee.req_a.1
            let site = c.pointee.req_a.2
            let kind = Int32(c.pointee.req_a.3)
            let result = tr_translate(view, c.pointee.req_a.5, Int32(c.pointee.cpl), rip, c.pointee.req_a.4 != 0)
            if result.fetch_fault_va != 0 {
                c.pointee.req_r.1 = result.fetch_fault_va + 1
                return nil
            }
            c.pointee.req_r.0 = result.arm
            c.pointee.req_r.1 = 0
            c.pointee.req_r.2 = result.frames.0 == ~0 ? 0 : result.frames.0 | 1
            c.pointee.req_r.3 = result.frames.1 == ~0 ? 0 : result.frames.1 | 1
            if result.flushed {
                // The site was in the old cache; the monitor drops return stacks on seeing tr_flushed.
            } else if kind == SVC_LOOKUP_MISS {
                tr_hash_insert(view, rip, result.arm)
            } else if site != 0 {
                tr_link(site, kind, result.arm)
            }
        case Int(HC_SMC):
            _ = tr_invalidate_frame(c.pointee.req_a.0)
        case Int(HC_VIEW_INVALIDATE_VA):
            _ = tr_invalidate_view_va(Int32(c.pointee.req_a.0), c.pointee.req_a.1)
        case Int(HC_FLUSH_VIEWS):
            tr_flush_all()
        case Int(HC_SYSCALL):
            guard let machine else { throw EngineError.stop("syscall with no machine attached") }
            try machine.syscall(c, engine: self)
            if let code = exitCode { return .exited(code: code) }
        case Int(HC_MMIO):
            guard let machine else { throw EngineError.stop("device access with no machine attached") }
            if c.pointee.req_a.2 != 0 {
                machine.mmioWrite(address: c.pointee.req_a.0, size: Int(c.pointee.req_a.1), value: c.pointee.req_a.3)
            } else {
                c.pointee.req_r.0 = machine.mmioRead(address: c.pointee.req_a.0, size: Int(c.pointee.req_a.1))
            }
        case Int(HC_PORT):
            guard let machine else { throw EngineError.stop("port access with no machine attached") }
            if c.pointee.req_a.2 != 0 {
                machine.portWrite(
                    port: UInt16(truncatingIfNeeded: c.pointee.req_a.0), size: Int(c.pointee.req_a.1),
                    value: UInt32(truncatingIfNeeded: c.pointee.req_a.3))
            } else {
                c.pointee.req_r.0 = UInt64(
                    machine.portRead(port: UInt16(truncatingIfNeeded: c.pointee.req_a.0), size: Int(c.pointee.req_a.1)))
            }
        case Int(HC_RDMSR):
            let v = machine?.readMSR(UInt32(truncatingIfNeeded: c.pointee.req_a.0))
            c.pointee.req_r.0 = v ?? 0
            c.pointee.req_r.1 = v == nil ? 1 : 0
        case Int(HC_WRMSR):
            let ok =
                machine?.writeMSR(UInt32(truncatingIfNeeded: c.pointee.req_a.0), value: c.pointee.req_a.1) ?? false
            c.pointee.req_r.1 = ok ? 0 : 1
        case Int(HC_CPUID):
            let v =
                machine?.cpuid(
                    leaf: UInt32(truncatingIfNeeded: c.pointee.req_a.0),
                    subleaf: UInt32(truncatingIfNeeded: c.pointee.req_a.1)) ?? (0, 0, 0, 0)
            c.pointee.req_r = (UInt64(v.0), UInt64(v.1), UInt64(v.2), UInt64(v.3))
        case Int(HC_HLT):
            guard let machine else { throw EngineError.stop("hlt with no machine attached") }
            let wake = machine.waitForInterrupt()
            if let vector = machine.acknowledgeInterrupt() {
                c.pointee.req_r.0 = UInt64(vector)
            } else {
                c.pointee.req_r.0 = ~0
            }
            c.pointee.req_r.1 = wake ? 0 : 1
        case Int(HC_IRQ):
            hv_vcpu_set_pending_interrupt(vcpu, HV_INTERRUPT_TYPE_IRQ, false)
            if let vector = machine?.acknowledgeInterrupt() {
                c.pointee.req_r.0 = UInt64(vector)
            } else {
                c.pointee.req_r.0 = ~0
            }
        case Int(HC_STOP):
            return try stopReport()
        default:
            throw EngineError.stop("unknown host call \(code)")
        }
        return nil
    }

    private func stopReport() throws -> RunOutcome? {
        let a = ctx.pointee.req_a
        let rip = a.1
        switch Int(a.0) {
        case Int(STOP_GUEST_HALT):
            return .halted(rax: a.2)
        case Int(STOP_UNTRANSLATED):
            let why = String(cString: tr_stop_reason(UInt32(truncatingIfNeeded: a.2)))
            throw EngineError.stop("\(why) at x86 rip \(hex(rip)): \(bytes(at: rip))")
        case Int(STOP_MONITOR_FAULT):
            throw EngineError.stop("monitor fault: esr \(hex(a.2)) far \(hex(a.3)) elr \(hex(a.4))")
        case Int(STOP_UNSUPPORTED):
            throw EngineError.stop("unsupported case \(a.2) at x86 rip \(hex(rip)): \(hex(a.3)) \(hex(a.4))")
        case Int(STOP_TRIPLE_FAULT):
            throw EngineError.stop("triple fault at x86 rip \(hex(rip)): vector \(a.2) error \(hex(a.3)) \(hex(a.4))")
        case Int(STOP_GUEST_FAULT_NO_IDT):
            throw EngineError.stop(
                "x86 exception \(a.2) error \(hex(a.3)) at rip \(hex(rip)) address \(hex(a.4)): \(bytes(at: rip))")
        case Int(STOP_SHADOW_FULL):
            throw EngineError.stop("shadow pool exhausted (\(a.2))")
        default:
            throw EngineError.stop("stop reason \(a.0)")
        }
    }

    func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

    /// Guest bytes at a VA for error messages, through the current CR3.
    public func bytes(at va: UInt64) -> String {
        var out: [String] = []
        for i in 0..<12 {
            guard let gpa = translate(va + UInt64(i)) else { break }
            out.append(String(format: "%02x", ram.load(fromByteOffset: Int(gpa), as: UInt8.self)))
        }
        return out.joined(separator: " ")
    }

    /// Software walk with no permission checks.
    public func translate(_ va: UInt64) -> UInt64? {
        var table = ctx.pointee.cr3 & 0x000F_FFFF_FFFF_F000
        var level = 3
        while level >= 0 {
            let index = (va >> UInt64(12 + 9 * level)) & 0x1FF
            let entry = ram.load(fromByteOffset: Int(table + index * 8), as: UInt64.self)
            if entry & 1 == 0 { return nil }
            if level == 0 || (level < 3 && entry & 0x80 != 0) {
                let size = UInt64(1) << UInt64(12 + 9 * level)
                return (entry & 0x000F_FFFF_FFFF_F000 & ~(size - 1)) | (va & (size - 1))
            }
            table = entry & 0x000F_FFFF_FFFF_F000
            level -= 1
        }
        return nil
    }

    /// Reads guest virtual memory, for shims.
    public func readGuest(_ va: UInt64, count: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            guard let gpa = translate(va + UInt64(done)) else { return nil }
            let chunk = min(4096 - Int((va + UInt64(done)) & 0xFFF), count - done)
            out.withUnsafeMutableBytes { dest in
                dest.baseAddress!.advanced(by: done).copyMemory(from: ram + Int(gpa), byteCount: chunk)
            }
            done += chunk
        }
        return out
    }

    /// Writes guest virtual memory, for shims. The caller must keep away from frames holding code or page tables.
    public func writeGuest(_ va: UInt64, bytes: [UInt8]) -> Bool {
        var done = 0
        while done < bytes.count {
            guard let gpa = translate(va + UInt64(done)) else { return false }
            let chunk = min(4096 - Int((va + UInt64(done)) & 0xFFF), bytes.count - done)
            bytes.withUnsafeBytes { src in
                (ram + Int(gpa)).copyMemory(from: src.baseAddress!.advanced(by: done), byteCount: chunk)
            }
            done += chunk
        }
        return true
    }

    public func injectInterruptLine() {
        hv_vcpu_set_pending_interrupt(vcpu, HV_INTERRUPT_TYPE_IRQ, true)
    }
    public func kick() {
        var v = vcpu
        hv_vcpus_exit(&v, 1)
    }
    public func cancelFromOtherThread() { kick() }
}

func hvCheck(_ what: String, _ call: () -> hv_return_t) throws {
    let r = call()
    if r != HV_SUCCESS { throw EngineError.hypervisor(what, r) }
}
