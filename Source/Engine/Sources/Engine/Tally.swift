import CEngine
import Foundation

/// Every reason execution left the engine for the host CPU emulator, with the rates DESIGN.md lists as unknown. Written whole each time, to a
/// file that survives a guest wedging or the process being killed. The vCPU thread records, one other thread writes.
public final class Tally: @unchecked Sendable {
    private struct Row {
        var count: UInt64 = 0
        var hostTicks: UInt64 = 0
    }
    private struct Site {
        var count: UInt64 = 0
        var firstRIP: UInt64
        var detail: UInt64
    }

    private let engine: Engine
    private let path: String
    private let lock = NSLock()
    private let startTicks = mach_absolute_time()
    private var reasons: [String: Row] = [:]
    private var sites: [String: Site] = [:]
    private var mmioPages: [UInt64: UInt64] = [:]
    private var mmioSites: [String: UInt64] = [:]
    private let exclusiveStops = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private struct SharedFrame {
        var blocks: UInt64 = 0, spaces = Set<UInt64>(), low = UInt64.max, high: UInt64 = 0
    }
    private var coldByDirectory: [UInt64: SharedFrame] = [:], coldByTable: [UInt64: SharedFrame] = [:]
    private var ports: [UInt16: UInt64] = [:]
    private var boundaries: UInt64 = 0
    private var samples: [String] = []
    private var timeline: [String] = []
    private var firstRIP: UInt64?
    private var hardStop: String?
    private var lastReason: String?
    private var lastLeftEngine: UInt64 = 0
    private var fallbacks: UInt64 = 0
    private var notes: [String] = []
    private var portWrites: [String] = []
    private var processLog: [String] = []

    init(engine: Engine, path: String) {
        self.engine = engine
        self.path = path
    }

    func startWriting() {
        write()
        Thread.detachNewThread { [self] in
            var tick = 0
            while true {
                Thread.sleep(forTimeInterval: 1)
                engine.requestBoundary()  // one stop a second is a rip sample, and shows where a wedged guest sits
                tick += 1
                if tick % 2 == 0 {
                    addTimelineRow()
                    write()
                }
            }
        }
    }

    func entered(rip: UInt64) {
        lock.lock()
        if firstRIP == nil { firstRIP = rip }
        closeAway()
        lock.unlock()
    }

    private func closeAway() {
        if let lastReason {
            reasons[lastReason, default: Row()].hostTicks += mach_absolute_time() &- lastLeftEngine
            self.lastReason = nil
        }
    }

    /// Off the engine by choice: the counters below stop, though the guest may be running well on TCG.
    func refused(_ reason: String) {
        lock.lock()
        closeAway()
        reasons[reason, default: Row()].count += 1
        lastReason = reason
        lastLeftEngine = mach_absolute_time()
        lock.unlock()
    }

    func note(_ text: String) {
        lock.lock()
        notes.append(text)
        lock.unlock()
    }

    /// Runs on the vCPU thread during the port write, so the monitor's copy of the registers is the guest's.
    func portWrite(port: UInt16, size: UInt32, value: UInt32, slide: UInt64) {
        let c = engine.ctx.pointee
        let rip = c.req_a.4
        let regs = withUnsafeBytes(of: c.x) { Array($0.bindMemory(to: UInt64.self)) }
        func unslid(_ at: UInt64) -> String { hex(at) + " unslid " + hex(at &- slide) }
        var o = String(format: "%.3f s: ", seconds(mach_absolute_time() &- startTicks))
        o +=
            "port \(hex(UInt64(port))) size \(size) value \(hex(UInt64(value))) rip \(unslid(rip)) cpl \(c.cpl) cr3 \(hex(c.cr3))\n"
        o += "  bytes at rip: " + engine.bytes(at: rip, count: 16) + "\n"
        o +=
            "  rax \(hex(regs[0])) rdx \(hex(regs[2])) rsp \(hex(regs[4])) rbp \(hex(regs[5]))\n  frame pointers, return addresses:\n"
        var frame = regs[5]
        for _ in 0..<32 {
            guard let words = engine.readGuest(frame, count: 16) else { break }
            let (next, back) = words.withUnsafeBytes {
                (
                    $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                    $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                )
            }
            o += "    " + unslid(back) + "\n"
            if next <= frame { break }
            frame = next
        }
        o += "  stack from rsp:\n"
        if let stack = engine.readGuest(regs[4], count: 256) {
            stack.withUnsafeBytes { raw in
                for i in 0..<32 {
                    o += hex(raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) + (i % 4 == 3 ? "\n" : " ")
                }
            }
        }
        lock.lock()
        portWrites.append(o)
        lock.unlock()
        write()
    }

    private func guestString(_ va: UInt64) -> String {
        var out: [UInt8] = []
        for i in 0..<200 {
            guard let b = engine.readGuest(va + UInt64(i), count: 1), b[0] != 0 else { break }
            out.append(b[0])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func guestArguments(_ va: UInt64) -> String {
        var out: [String] = []
        for i in 0..<12 {
            guard let raw = engine.readGuest(va + UInt64(i * 8), count: 8) else { break }
            let at = raw.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            if at == 0 { break }
            out.append(guestString(at))
        }
        return out.joined(separator: " ")
    }

    /// One line per process event, each starting `proc `, so a batch of runs can be compared with a grep.
    func processNote() {
        let c = engine.ctx.pointee
        let r = withUnsafeBytes(of: c.x) { Array($0.bindMemory(to: UInt64.self)) }
        var o = String(format: "proc %8.3f ", seconds(mach_absolute_time() &- startTicks)) + "cr3 \(hex(c.cr3)) "
        switch c.req_a.0 {
        case 1:
            switch r[0] & 0xFFFFFF {
            case 4, 0x18D:
                let text =
                    engine.readGuest(r[6], count: Int(min(r[2], 240))).map { String(decoding: $0, as: UTF8.self) }
                    ?? "unreadable"
                o += "write fd \(r[7]): " + text.replacingOccurrences(of: "\n", with: " ")
            case 1: o += "exit \(r[7] & 0xFF)"
            case 0x37: o += "reboot how \(hex(r[7]))"
            case 0x3B: o += "execve " + guestString(r[7]) + " [" + guestArguments(r[6]) + "]"
            case 0xF4: o += "posix_spawn " + guestString(r[6]) + " [" + guestArguments(r[10]) + "]"
            default: o += "wait4 pid \(Int32(truncatingIfNeeded: r[7]))"
            }
        case 2:
            let status = engine.readGuest(c.req_a.2, count: 4)?.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let result = Int64(bitPattern: r[0])
            if c.req_a.3 != 0 {  // rax is an errno, and the status word is whatever the caller had there
                o += "wait4 failed, error \(result)"
                break
            }
            o += "wait4 returned \(result) status " + (status.map { hex(UInt64($0)) } ?? "unreadable")
            // With no child ready (WNOHANG returns 0) or an error, the kernel left the status word as it found it.
            if result > 0, let status, status & 0x7F != 0 {
                o += " SIGNAL \(status & 0x7F)\n  last user page faults, rip, address, error, cr3:\n"
                let faults = withUnsafeBytes(of: c.user_pf) { Array($0.bindMemory(to: EngineEvent.self)) }
                for i in 0..<UInt64(faults.count) {
                    let e = faults[Int((c.user_pf_next &+ i) % UInt64(faults.count))]
                    if e.cr3 != 0 { o += "    \(hex(e.rip)) \(hex(e.a)) \(hex(UInt64(e.vector))) \(hex(e.cr3))\n" }
                }
                o.removeLast()
            } else if let status {
                o += " exit \((status >> 8) & 0xFF)"
            }
        default:
            o +=
                "FAULT vector \(c.req_a.2) error \(hex(c.req_a.3)) rip \(hex(c.req_a.1))  "
                + engine.bytes(at: c.req_a.1, count: 16) + "\n  "
            for i in 0..<16 { o += hex(r[i]) + (i == 15 ? "" : " ") }
            // dyld's fatal error is an int3 with its message in rdi: that is the process's own account of why it died.
            if c.req_a.2 == 3 { o += "\n  rdi as a string: " + guestString(r[7]) }
        }
        lock.lock()
        if processLog.count < 2000 { processLog.append(o) }
        lock.unlock()
    }

    func tcgSample(rip: UInt64, cpl: UInt32, cr3: UInt64) { addSample("tcg", rip, cpl, cr3) }

    private func addSample(_ place: String, _ rip: UInt64, _ cpl: UInt32, _ cr3: UInt64) {
        lock.lock()
        samples.append(
            String(format: "%8.1f ", seconds(mach_absolute_time() &- startTicks))
                + "\(place) \(hex(rip)) cpl \(cpl) cr3 \(hex(cr3))")
        if samples.count > 64 { samples.removeFirst() }
        lock.unlock()
    }

    func fallback(reason: String, rip: UInt64, bytes: String, detail: UInt64) {
        lock.lock()
        reasons[reason, default: Row()].count += 1
        sites["\(reason) | \(bytes)", default: Site(firstRIP: rip, detail: detail)].count += 1
        fallbacks += 1
        lastReason = reason
        lastLeftEngine = mach_absolute_time()
        lock.unlock()
    }

    func boundary(rip: UInt64, cpl: UInt32, cr3: UInt64) {
        lock.lock()
        boundaries += 1
        lock.unlock()
        addSample("engine", rip, cpl, cr3)
    }

    // Whether address spaces share page tables under the code they run, which decides whether they could share its translations.
    func coldUserBlock(rip: UInt64, cr3: UInt64) {
        func entry(_ table: UInt64, _ index: UInt64) -> UInt64? {
            engine.host((table & 0x000F_FFFF_FFFF_F000) + index * 8)?.loadUnaligned(as: UInt64.self)
        }
        guard let top = entry(cr3, (rip >> 39) & 0x1FF), top & 1 != 0, let upper = entry(top, (rip >> 30) & 0x1FF),
            upper & 1 != 0, upper & 0x80 == 0
        else { return }
        let directory = upper & 0x000F_FFFF_FFFF_F000
        let space = cr3 & 0x000F_FFFF_FFFF_F000
        lock.lock()
        defer { lock.unlock() }
        func count(_ row: inout SharedFrame) {
            row.blocks += 1
            row.spaces.insert(space)
            row.low = min(row.low, rip)
            row.high = max(row.high, rip)
        }
        count(&coldByDirectory[directory, default: SharedFrame()])
        if let middle = entry(directory, (rip >> 21) & 0x1FF), middle & 1 != 0, middle & 0x80 == 0 {
            count(&coldByTable[middle & 0x000F_FFFF_FFFF_F000, default: SharedFrame()])
        }
    }

    func mmioSample(rip: UInt64, gpa: UInt64, size: UInt64, write: Bool) {
        let bytes =
            engine.readGuest(rip, count: 8).map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") }
            ?? "unreadable"
        // The device by its megabyte, so a loop over a frame buffer is one row.
        mmioSites["\(hex(rip)) \(write ? "w" : "r") \(size) \(hex(gpa & ~0xF_FFFF))  \(bytes)", default: 0] += 1
    }

    // Any thread, so approximate, which is all it is for.
    func exclusiveStop() { exclusiveStops.pointee += 1 }

    var apicRegisters: [UInt64: Int] = [:]
    func mmio(_ gpa: UInt64) {
        lock.lock()
        mmioPages[gpa & ~0xFFF, default: 0] += 1
        if gpa & ~0xFFF == 0xFEE0_0000 { apicRegisters[gpa & 0xFF0, default: 0] += 1 } // which local APIC register: a timer arm or an EOI
        lock.unlock()
    }

    func port(_ port: UInt16) {
        lock.lock()
        ports[port, default: 0] += 1
        lock.unlock()
    }

    func stopped(_ text: String) {
        lock.lock()
        hardStop = text
        lock.unlock()
        write()
    }

    private func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }
    private func seconds(_ ticks: UInt64) -> Double { Double(ticks) / 24_000_000 }

    private func addTimelineRow() {
        let c = engine.ctx.pointee
        let t = tr_stats()
        lock.lock()
        let row = [
            String(format: "%8.1f", seconds(mach_absolute_time() &- startTicks)), String(c.stat_pt_writes),
            String(c.stat_pt_writes_zap),
            String(c.stat_cr3), String(t.blocks), String(t.insns),
            String(format: "%.1f", seconds(t.translate_ns) * 1000),
            String(c.stat_mmio), String(fallbacks), String(c.stat_irq), String(format: "%.1f", seconds(c.stat_mon_wait) * 1000),
            String(format: "%.1f", seconds(engine.translatorWaitTicks) * 1000), samples.last ?? "-"
        ]
        timeline.append(row.joined(separator: "\t"))
        lock.unlock()
    }

    public func write() {
        let c = engine.ctx.pointee
        let t = tr_stats()
        lock.lock()
        let elapsed = max(seconds(mach_absolute_time() &- startTicks), 0.001)
        func perSecond(_ v: UInt64) -> String { String(format: "%12d  %12.0f/s", v, Double(v) / elapsed) }
        var o =
            "# hvdbt tally. One vCPU; TCG up to XNU's 64-bit entry, then the engine. All counts are measured on this run.\n"
        o += "state: " + (hardStop.map { "HARD STOP: \($0)" } ?? "running or exited normally") + "\n"
        let away = lastReason == nil ? 0 : mach_absolute_time() &- lastLeftEngine
        if let lastReason, seconds(away) > 1 {
            o += String(format: "off the engine, on TCG, for %.1f s now, after: ", seconds(away)) + lastReason + "\n"
            o += "the engine's counters below don't move meanwhile, and say nothing about the guest\n"
        }
        o += String(format: "seconds since hand-off: %.1f\n", elapsed)
        o += "hand-off rip: " + (firstRIP.map(hex) ?? "none") + "\n"
        o += "last rip sample: " + (samples.last ?? "none") + "\n"
        for note in notes { o += note + "\n" }
        let halted = portWrites.first { $0.contains("port 0x604 size 2 value 0x2") || $0.contains("port 0x605") }
        o +=
            "outcome: " + (hardStop != nil ? "hard stop" : halted != nil ? "guest powered off" : "running")
            + String(
                format: " at %.1f s, syscalls %d, page faults %d, bad hash see dump\n", elapsed, c.stat_syscall,
                c.stat_pf_delivered)
        o += "\n"
        o += "== process log: spawns, exits, wait4 results, user faults other than #PF and #NM, oldest first ==\n"
        for line in processLog { o += line + "\n" }
        o += "\n"
        if !portWrites.isEmpty {
            o +=
                "== writes to the power and reset ports, in order. Bit 13 of PM1a_CNT is SLP_EN ==\n"
                + portWrites.joined() + "\n"
        }

        o +=
            "== stops and fallbacks, ranked by count. tcg_ms: time away from the engine after each, with TCG running ==\n"
        for (reason, row) in reasons.sorted(by: { $0.value.count > $1.value.count }) {
            let open = reason == lastReason ? away : 0
            o += String(format: "%12d %10.1f  ", row.count, seconds(row.hostTicks &+ open) * 1000) + reason + "\n"
        }
        o += "\n== by site: reason | first bytes at rip, ranked; first rip, detail (msr, address) ==\n"
        for (key, site) in sites.sorted(by: { $0.value.count > $1.value.count }).prefix(200) {
            o += String(format: "%12d  ", site.count) + key + "  @\(hex(site.firstRIP)) \(hex(site.detail))\n"
        }

        o += "\n== rates the design lists as unknown, totals and per wall second since hand-off ==\n"
        o += "page-table stores    " + perSecond(c.stat_pt_writes) + "\n"
        o += "  frames found stale " + perSecond(c.stat_pt_stale) + "\n"
        o += "  dropping a table   " + perSecond(c.stat_pt_writes_zap) + "\n"
        o += "  by one-word step   " + perSecond(c.stat_pt_step) + "\n"
        o += "  tables unshadowed  " + perSecond(c.stat_pt_unshadow) + "\n"
        o += "cold blocks          " + perSecond(t.blocks) + "\n"
        o += "cold x86 insns       " + perSecond(t.insns) + "\n"
        o += "cold ARM words       " + perSecond(t.words) + "\n"
        let holds = withUnsafeBytes(of: c.stat_mon_hold) { Array($0.bindMemory(to: UInt64.self)) }
        o += String(format: "monitor lock waited %.2f s; held, s: other %.2f, view switch %.2f, before translating %.2f, after %.2f, fault %.2f, table store %.2f\n", seconds(c.stat_mon_wait), seconds(holds[0]), seconds(holds[1]), seconds(holds[2]), seconds(holds[3]), seconds(holds[4]), seconds(holds[5]))
        let opInsns = withUnsafeBytes(of: t.op_insns) { Array($0.bindMemory(to: UInt64.self)) }
        let opWords = withUnsafeBytes(of: t.op_words) { Array($0.bindMemory(to: UInt64.self)) }
        o += "  words after the last instruction of blocks: \(t.exit_words)\n  by OP_ number in tr_internal.h, ranked by words: op, insns, words, words per insn\n"
        for op in opWords.indices.sorted(by: { opWords[$0] > opWords[$1] }).prefix(24) where opInsns[op] > 0 {
            o += String(format: "  %3d %12llu %12llu %6.2f\n", op, opInsns[op], opWords[op], Double(opWords[op]) / Double(opInsns[op]))
        }
        o += String(format: "translation time     %12.1f ms\n", seconds(t.translate_ns) * 1000)
        o += "blocks invalidated   " + perSecond(t.invalidated) + "\n"
        o +=
            "cold blocks a cache keyed by frame had: \(t.again_live) live in another view, \(t.again_dead) dead with the frame unchanged. Lower bounds\n\n"
        o +=
            "cold 32-bit user blocks: \(t.i386_blocks), of which a cache keyed by frame had \(t.i386_again)\n"
        o +=
            "shared user blocks: \(t.shared_blocks) translated, \(t.shared_found) found by another view, under \(c.shared_dir_count) directories\n"
        o +=
            "view lookup tables emptied: \(t.hash_refills) as full, \(t.hash_forgets) forgetting a shared directory. Code cache resets: \(t.cache_resets), and of its private part \(t.cache_private_resets)\n"
        o += "stopped for another vCPU's exclusive section: \(exclusiveStops.pointee)\n"
        o += String(format: "dead blocks reused: %llu. Direct calls between keys given a lookup: %llu\n", t.reused, t.call_tails)
        o += String(format: "this vCPU waited for the translator lock %llu times, %.2f s\n\n", engine.translatorWaits, seconds(engine.translatorWaitTicks))
        o += String(format: "page invalidations: %llu, %.2f s waiting for the translator lock, %.2f s in all\n\n", engine.invalidations, seconds(engine.invalidationWaitTicks), seconds(engine.invalidationTicks))
        o += "== why blocks died: blocks, of those with the page still on the same frame, calls ==\n"
        let killed = withUnsafeBytes(of: t.killed) { Array($0.bindMemory(to: UInt64.self)) }
        let unmoved = withUnsafeBytes(of: t.killed_unmoved) { Array($0.bindMemory(to: UInt64.self)) }
        let calls = withUnsafeBytes(of: t.kill_calls) { Array($0.bindMemory(to: UInt64.self)) }
        let kinds = [
            "a store onto code", "DMA or TCG wrote code", "a leaf page-table store", "a store higher in the tables",
            "a table written too often to shadow",
            "the shadow pool ran out", "its view was reused", "device memory left the VM"
        ]
        for (i, kind) in kinds.enumerated() {
            o += String(format: "%12llu %12llu %12llu  ", killed[i], unmoved[i], calls[i]) + kind + "\n"
        }
        o += "\n"

        o += "== where the time goes: 24 MHz clock, averages fine over many ==\n"
        o += String(
            format: "%10.1f s inside hv_vcpu_run, translated code, the monitor and the exit round trips\n",
            seconds(engine.ticksInVCPU))
        o += "   count        total s    us each  host call (HC_ number in engine_abi.h)\n"
        for code in engine.hostCallCount.indices where engine.hostCallCount[code] != 0 {
            let total = seconds(engine.hostCallTicks[code])
            o += String(
                format: "%12llu %10.2f %10.2f  %d\n", engine.hostCallCount[code], total,
                total * 1e6 / Double(engine.hostCallCount[code]), code)
        }
        o += "monitor calls by SVC_ number in engine_abi.h, ranked:\n"
        let svc = withUnsafeBytes(of: c.stat_svc) { Array($0.bindMemory(to: UInt64.self)) }
        for (n, count) in svc.enumerated().sorted(by: { $0.element > $1.element }).prefix(20) where count != 0 {
            o += String(
                format: "%12llu, %8.0f/s  %d\n", count,
                Double(count) / max(seconds(mach_absolute_time() &- startTicks), 1), n)
        }
        o += "\n"

        o += "== other counters ==\n"
        let counters: [(String, UInt64)] = [
            ("vm exits", engine.exitCount), ("fallbacks", fallbacks), ("boundary stops", boundaries),
            ("links made in the monitor", c.stat_links_here),
            ("deepest monitor stack, bytes", c.stat_stack_deepest),
            ("shadow fills", c.stat_fills),
            ("dirty upgrades", c.stat_dirty), ("smc", c.stat_smc), ("page faults delivered", c.stat_pf_delivered),
            ("cr3 writes", c.stat_cr3),
            ("iret", c.stat_iret), ("syscall", c.stat_syscall), ("interrupts delivered", c.stat_irq),
            ("arm steps to a boundary", c.stat_steps),
            ("hlts ended by an interrupt while polling", c.stat_hlt_polled),
            ("mmio through the host", c.stat_mmio), ("#NM from CR0.TS", c.stat_nm),
            ("code frames noted by DMA or TCG", c.stat_note_code),
            ("table frames noted by DMA or TCG", c.stat_note_pt), ("view evictions", c.stat_view_evictions),
            ("pool reclaims", c.stat_pool_reclaim)
        ]
        for (name, value) in counters {
            o += name.padding(toLength: 34, withPad: " ", startingAt: 0) + perSecond(value) + "\n"
        }

        o += "\n== events delivered by vector, ranked; last return rip, error code, bytes there ==\n"
        let vectors = withUnsafeBytes(of: c.stat_vector) { Array($0.bindMemory(to: UInt64.self)) }
        let vectorRIP = withUnsafeBytes(of: c.vector_last_rip) { Array($0.bindMemory(to: UInt64.self)) }
        let vectorErr = withUnsafeBytes(of: c.vector_last_err) { Array($0.bindMemory(to: UInt64.self)) }
        let vectorCR3 = withUnsafeBytes(of: c.vector_last_cr3) { Array($0.bindMemory(to: UInt64.self)) }
        for v in vectors.indices.filter({ vectors[$0] > 0 }).sorted(by: { vectors[$0] > vectors[$1] }) {
            o +=
                "vector " + hex(UInt64(v)) + perSecond(vectors[v]) + "  " + hex(vectorRIP[v]) + " err "
                + hex(vectorErr[v]) + "  " + engine.bytes(at: vectorRIP[v], cr3: vectorCR3[v]) + "\n"
        }
        o += "\n== the monitor's last events, oldest first: E delivered, I iret, C cr3 write, S syscall, R sysret ==\n"
        o +=
            "kind vector rip a(error, target, cr3 value) cr3, bytes at rip. Read while running, so a line can be torn.\n"
        let events = withUnsafeBytes(of: c.events) { Array($0.bindMemory(to: EngineEvent.self)) }
        for i in 0..<UInt64(events.count) {
            let e = events[Int((c.event_next &+ i) % UInt64(events.count))]
            if e.kind != 0 {
                o +=
                    String(UnicodeScalar(UInt8(truncatingIfNeeded: e.kind))) + " " + hex(UInt64(e.vector)) + " "
                    + hex(e.rip) + " " + hex(e.a) + " " + hex(e.cr3) + "  "
                    + engine.bytes(at: e.rip, count: 8, cr3: e.cr3) + "\n"
            }
        }

        for (title, rows) in [("page directory", coldByDirectory), ("page table", coldByTable)] {
            o +=
                "\n== cold user blocks by the \(title) frame above them: blocks, address spaces seen sharing it, lowest and highest rip ==\n"
            for (frame, row) in rows.sorted(by: { $0.value.blocks > $1.value.blocks }).prefix(16) {
                o +=
                    String(format: "%12llu %6d  ", row.blocks, row.spaces.count) + hex(frame) + " " + hex(row.low) + " "
                    + hex(row.high) + "\n"
            }
            let shared = rows.values.filter { $0.spaces.count > 1 }.reduce(0) { $0 + $1.blocks }
            o +=
                "of all \(rows.values.reduce(0) { $0 + $1.blocks }) blocks, \(shared) under a frame more than one address space used\n"
        }
        o += "\n== mmio by page ==\n"
        for (page, count) in mmioPages.sorted(by: { $0.value > $1.value }).prefix(40) {
            o += String(format: "%12d  ", count) + hex(page) + "\n"
        }
        o += "\n== local APIC accesses by register ==\n"
        for (register, count) in apicRegisters.sorted(by: { $0.value > $1.value }) {
            o += String(format: "%12d  ", count) + hex(register) + "\n"
        }
        o +=
            "\n== mmio by site: 1 in 256 sampled, so counts are approximate. rip, read or write, size, device's megabyte, bytes at rip ==\n"
        for (site, count) in mmioSites.sorted(by: { $0.value > $1.value }).prefix(30) {
            o += String(format: "%12d  ", count &* 256) + site + "\n"
        }
        o += "\n== ports ==\n"
        for (port, count) in ports.sorted(by: { $0.value > $1.value }).prefix(40) {
            o += String(format: "%12d  ", count) + hex(UInt64(port)) + "\n"
        }
        o +=
            "\n== rip samples: seconds, where, rip. One a second, oldest first; a tcg rip is only as fresh as the last TB exit ==\n"
            + samples.joined(separator: "\n") + "\n"
        o +=
            "\n== timeline: seconds, pt stores, pt table drops, cr3, blocks, insns, translate ms, mmio, fallbacks, irqs, all vCPUs' ms waiting for the monitor lock, this vCPU's for the translator's, rip ==\n"
        o += timeline.joined(separator: "\n") + "\n"
        lock.unlock()
        try? Data(o.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
