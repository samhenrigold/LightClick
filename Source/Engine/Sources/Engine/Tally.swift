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
    private var ports: [UInt16: UInt64] = [:]
    private var boundaries: UInt64 = 0
    private var samples: [String] = []
    private var timeline: [String] = []
    private var firstRIP: UInt64?
    private var hardStop: String?
    private var lastReason: String?
    private var lastLeftEngine: UInt64 = 0
    private var fallbacks: UInt64 = 0

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

    func mmio(_ gpa: UInt64) {
        lock.lock()
        mmioPages[gpa & ~0xFFF, default: 0] += 1
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
            String(c.stat_mmio), String(fallbacks), String(c.stat_irq), samples.last ?? "-"
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
        o += "last rip sample: " + (samples.last ?? "none") + "\n\n"

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
        o += "  dropping a table   " + perSecond(c.stat_pt_writes_zap) + "\n"
        o += "  by one-word step   " + perSecond(c.stat_pt_step) + "\n"
        o += "  tables unshadowed  " + perSecond(c.stat_pt_unshadow) + "\n"
        o += "cold blocks          " + perSecond(t.blocks) + "\n"
        o += "cold x86 insns       " + perSecond(t.insns) + "\n"
        o += "cold ARM words       " + perSecond(t.words) + "\n"
        o += String(format: "translation time     %12.1f ms\n", seconds(t.translate_ns) * 1000)
        o += "blocks invalidated   " + perSecond(t.invalidated) + "\n\n"

        o += "== other counters ==\n"
        let counters: [(String, UInt64)] = [
            ("vm exits", engine.exitCount), ("fallbacks", fallbacks), ("boundary stops", boundaries),
            ("shadow fills", c.stat_fills),
            ("dirty upgrades", c.stat_dirty), ("smc", c.stat_smc), ("page faults delivered", c.stat_pf_delivered),
            ("cr3 writes", c.stat_cr3),
            ("iret", c.stat_iret), ("syscall", c.stat_syscall), ("interrupts delivered", c.stat_irq),
            ("arm steps to a boundary", c.stat_steps),
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
        for v in vectors.indices.filter({ vectors[$0] > 0 }).sorted(by: { vectors[$0] > vectors[$1] }) {
            o +=
                "vector " + hex(UInt64(v)) + perSecond(vectors[v]) + "  " + hex(vectorRIP[v]) + " err "
                + hex(vectorErr[v]) + "  " + engine.bytes(at: vectorRIP[v]) + "\n"
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

        o += "\n== mmio by page ==\n"
        for (page, count) in mmioPages.sorted(by: { $0.value > $1.value }).prefix(40) {
            o += String(format: "%12d  ", count) + hex(page) + "\n"
        }
        o += "\n== ports ==\n"
        for (port, count) in ports.sorted(by: { $0.value > $1.value }).prefix(40) {
            o += String(format: "%12d  ", count) + hex(UInt64(port)) + "\n"
        }
        o +=
            "\n== rip samples: seconds, where, rip. One a second, oldest first; a tcg rip is only as fresh as the last TB exit ==\n"
            + samples.joined(separator: "\n") + "\n"
        o +=
            "\n== timeline: seconds, pt stores, pt table drops, cr3, blocks, insns, translate ms, mmio, fallbacks, irqs, rip ==\n"
        o += timeline.joined(separator: "\n") + "\n"
        lock.unlock()
        try? Data(o.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
