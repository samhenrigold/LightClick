import Darwin
import Dispatch
import Foundation
import IOSurface

/// One guest window's pixels, drawn on this Mac's GPU and shared as they are. Which window, and where it goes, is
/// `SessionWire.Window`'s to say, by the same ID: this is only the pixels.
///
/// They're premultiplied BGRA, top row first, and `surface` can be bigger than the window: on Mojave, a surface's size says
/// its window's ID, and past the window it's transparent. Use it as a layer's `contents` and take the window's own size in
/// pixels from `contentRect`. A surface in use isn't written: each window has two or three, and they come round again.
public struct GuestWindowSurface: @unchecked Sendable {
    public let window: UInt32
    /// Goes up with each frame sent for this window. A gap means frames the guest drew and this never got.
    public let frame: UInt32
    public let surface: IOSurfaceRef
    /// Where the surface's top-left pixel is on the guest's display, or zero where the tool's window says it instead.
    public let origin: (x: Int32, y: Int32)
}

/// What a machine's QEMU sends each `GuestWindowSurface` to, on a bootstrap service. Start this first, and start QEMU with
/// `environment(service:directory:)`. Windows arrive by their first frame, and a frame is damage: a window that hasn't
/// changed sends nothing. Nothing here knows of windows going away, which `SessionWire`'s gone message says.
public final class GuestWindowSurfaceReceiver: @unchecked Sendable {
    public enum Failure: Error {
        case noPort
        case noRegistration(Int32)
    }

    private static let frameMessage: Int32 = 0x5347_4652
    // As probes/seamless-gpu-viewer.m's struct: header 24, body 4, port descriptor 12, then six 32-bit fields.
    static let messageSize = 64

    private let port: mach_port_t
    private let source: DispatchSourceMachReceive
    private let onFrame: @Sendable (GuestWindowSurface) -> Void

    /// The environment that turns this on in QEMU and the PVG helper. `directory` takes a host-side report of the rates.
    public static func environment(service: String, directory: String) -> [String: String] {
        [
            "LC_SEAMLESS_GPU_DIR": directory, "LC_SEAMLESS_GPU_REPLAY": "1", "LC_SEAMLESS_GPU_SERVICE": service,
            "VIM_SEAMLESS_PVG_DIR": directory, "VIM_SEAMLESS_PVG_SERVICE": service
        ]
    }

    /// `onFrame` runs on a queue of this object's own, in order.
    public init(service: String, onFrame: @escaping @Sendable (GuestWindowSurface) -> Void) throws {
        var port = mach_port_t(MACH_PORT_NULL)
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS,
            mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
                == KERN_SUCCESS
        else { throw Failure.noPort }
        var bootstrap = mach_port_t(MACH_PORT_NULL)
        task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap)
        // Not in Darwin's module map, and deprecated, though it's how a process with no launchd plist offers a service.
        typealias Register = @convention(c) (mach_port_t, UnsafePointer<CChar>, mach_port_t) -> kern_return_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "bootstrap_register") else {
            throw Failure.noRegistration(-1)
        }
        let result = service.withCString { unsafeBitCast(symbol, to: Register.self)(bootstrap, $0, port) }
        guard result == KERN_SUCCESS else { throw Failure.noRegistration(result) }
        self.port = port
        self.onFrame = onFrame
        source = DispatchSource.makeMachReceiveSource(
            port: port, queue: DispatchQueue(label: "gold.samhenri.guest-window-surfaces", qos: .userInteractive))
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
    }

    public func stop() { source.cancel() }

    private func drain() {
        let capacity = Self.messageSize + MemoryLayout<mach_msg_max_trailer_t>.size
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        let header = buffer.bindMemory(to: mach_msg_header_t.self, capacity: 1)
        while mach_msg(
            header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, mach_msg_size_t(capacity), port, 0,
            mach_port_name_t(MACH_PORT_NULL)) == MACH_MSG_SUCCESS
        {
            guard let frame = Self.parse(UnsafeRawBufferPointer(start: buffer, count: capacity)) else {
                mach_msg_destroy(header)
                continue
            }
            onFrame(frame)
        }
    }

    /// Takes the message's send right, whatever it finds. Checked by the tests, since QEMU's side is C.
    static func parse(_ message: UnsafeRawBufferPointer) -> GuestWindowSurface? {
        let header = message.load(as: mach_msg_header_t.self)
        guard header.msgh_id == frameMessage, header.msgh_size == messageSize,
            header.msgh_bits & UInt32(MACH_MSGH_BITS_COMPLEX) != 0
        else { return nil }
        let right = message.load(fromByteOffset: 28, as: mach_port_t.self)
        let surface = IOSurfaceLookupFromMachPort(right)
        mach_port_deallocate(mach_task_self_, right)
        guard let surface else { return nil }
        return GuestWindowSurface(
            window: message.load(fromByteOffset: 40, as: UInt32.self),
            frame: message.load(fromByteOffset: 44, as: UInt32.self),
            surface: surface,
            origin: (message.load(fromByteOffset: 56, as: Int32.self), message.load(fromByteOffset: 60, as: Int32.self))
        )
    }
}
