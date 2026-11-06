import CEngine
import Foundation

/// Several vCPUs in one VM running `Tests/x86/kernel/smp.c`, each on its own thread. Every vCPU starts at the image's entry in long mode: no INIT or SIPI, those stay with
/// whatever owns the machine. The machine gives each vCPU a console (0xE9), an exit port (0xF4), the vCPU count (0xF5), whether EnTSO is on (0xF6), and IPIs.
public final class SMPGuest: @unchecked Sendable {
    private var cpus: [SMPCPU] = []
    private let options: EngineOptions
    private let count: UInt32
    private let console = NSLock()

    public init(options: EngineOptions = EngineOptions(), count: UInt32) {
        var o = options
        o.kernelModel = true
        self.options = o
        self.count = count
    }

    fileprivate func deliver(icr: UInt64, from: UInt32) {
        let vector = UInt8(icr & 0xFF), shorthand = (icr >> 18) & 3, target = UInt32(icr >> 56)
        guard (icr >> 8) & 7 == 0 else { fatalError("IPI delivery mode \((icr >> 8) & 7) is not in this test") }
        for cpu in cpus {
            let index = cpu.engine.cpuIndex
            let hit = shorthand == 0 ? index == target : shorthand == 1 ? index == from : shorthand == 2 ? true : index != from
            if hit { cpu.post(vector) }
        }
    }

    fileprivate func write(_ byte: UInt8) {
        console.lock()
        FileHandle.standardOutput.write(Data([byte]))
        console.unlock()
    }

    fileprivate var tsoOn: Bool { options.useTSO }
    fileprivate var vcpuCount: UInt32 { count }

    public func run(image: MachOImage) throws -> Int32 {
        guard let entry = image.entry else { throw EngineError.badImage("no entry") }
        let first = try Engine(options: options)
        first.prepareCount(count)
        let root = KernelGuest.buildBootTables(image: image, ram: first.ram, ramBytes: options.ramBytes)
        func prepare(_ engine: Engine) {
            let ctx = engine.ctx
            ctx.pointee.cr3 = root
            ctx.pointee.cpl = 0
            ctx.pointee.seg_sel.1 = 0x08
            ctx.pointee.seg_sel.2 = 0x10
            ctx.pointee.rflags_sys = 2
            ctx.pointee.x.7 = options.ramBytes
            ctx.pointee.x.6 = UInt64(engine.cpuIndex)
        }
        prepare(first)
        cpus.append(SMPCPU(guest: self, engine: first))

        // All of them exist before any runs, as an IPI may be sent to any at once.
        let created = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var engine: Engine? }
        let boxes = (1..<max(count, 1)).map { _ in Box() }
        for (i, box) in boxes.enumerated() {
            Thread.detachNewThread { [self] in
                pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
                do {
                    let engine = try Engine(secondaryOf: first, index: UInt32(i + 1))
                    box.engine = engine
                    created.signal()
                    go.wait()
                    _ = try engine.run(entry: entry)
                } catch {
                    FileHandle.standardError.write(Data("engine stop on vCPU \(i + 1): \(error)\n".utf8))
                    exit(2)
                }
                _ = self
            }
        }
        for _ in boxes { created.wait() }
        for box in boxes {
            prepare(box.engine!)
            cpus.append(SMPCPU(guest: self, engine: box.engine!))
        }
        for _ in boxes { go.signal() }
        _ = try first.run(entry: entry)
        if ProcessInfo.processInfo.environment["ENGINE_STATS"] != nil {
            for cpu in cpus { FileHandle.standardError.write(Data((cpu.engine.stats() + "\n").utf8)) }
        }
        return first.exitCode ?? -1
    }
}

/// One vCPU's view of the machine. Runs on that vCPU's thread, except `post`.
final class SMPCPU: EngineMachine, @unchecked Sendable {
    private unowned let guest: SMPGuest
    let engine: Engine
    private let wake = DispatchSemaphore(value: 0)

    init(guest: SMPGuest, engine: Engine) {
        self.guest = guest
        self.engine = engine
        engine.machine = self
    }

    /// Any thread.
    func post(_ vector: UInt8) {
        engine.postVector(vector, level: false)
        wake.signal()
    }

    func portWrite(port: UInt16, size: Int, value: UInt32) {
        switch port {
        case 0xE9:
            guest.write(UInt8(truncatingIfNeeded: value))
        case 0xF4:
            engine.exitCode = Int32(bitPattern: value)
            engine.requestStop = true
        default:
            break
        }
    }
    func portRead(port: UInt16, size: Int) -> UInt32 {
        switch port {
        case 0xF5: return guest.vcpuCount
        case 0xF6: return guest.tsoOn ? 1 : 0
        default: return 0xFFFF_FFFF
        }
    }
    func waitForInterrupt(deadlineNanos: UInt64) -> Bool {
        // Signals pile up while this vCPU is awake. Anything posted before this drain shows in the host IRR, and anything after leaves a signal.
        while wake.wait(timeout: .now()) == .success {}
        let posted = withUnsafeBytes(of: &engine.ctx.pointee.apic_host_irr) { $0.bindMemory(to: UInt32.self).contains { $0 != 0 } }
        if posted { return true }
        _ = wake.wait(timeout: .now() + .nanoseconds(Int(deadlineNanos != 0 ? min(deadlineNanos, 100_000_000) : 100_000_000)))
        return true
    }
    func apicICR(_ icr: UInt64) { guest.deliver(icr: icr, from: engine.cpuIndex) }
    func apicEOI(vector: UInt8) {}
    func acknowledgeInterrupt() -> UInt8? { nil }
    func hasInterruptWaiting() -> Bool { false }
    func mmioRead(address: UInt64, size: Int) -> UInt64 { 0 }
    func mmioWrite(address: UInt64, size: Int, value: UInt64) {}
    func readMSR(_ msr: UInt32) -> UInt64? { 0 }
    func writeMSR(_ msr: UInt32, value: UInt64) -> Bool { true }
    func cpuid(leaf: UInt32, subleaf: UInt32) -> (eax: UInt32, ebx: UInt32, ecx: UInt32, edx: UInt32) {
        CPUIDModel.answer(leaf: leaf, subleaf: subleaf)
    }
    func syscall(_ state: UnsafeMutablePointer<EngineCtx>, engine: Engine) throws {
        throw EngineError.stop("no shim in the kernel model")
    }
}
