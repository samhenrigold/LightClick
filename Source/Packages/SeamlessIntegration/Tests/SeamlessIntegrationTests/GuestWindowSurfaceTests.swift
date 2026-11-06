import Darwin
import Foundation
import IOSurface
import Testing

@testable import SeamlessIntegration

// A real Mach message, laid out as QEMU's C does, through a real receiver.
@Test func aFrameArrivesWithItsWindowAndSurface() async throws {
    let surface = try #require(
        IOSurfaceCreate(
            [kIOSurfaceWidth: 8, kIOSurfaceHeight: 4, kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: 0x4247_5241]
                as CFDictionary))
    let service = "gold.samhenri.seamless-gpu-test.\(getpid())"
    let (stream, continuation) = AsyncStream.makeStream(of: GuestWindowSurface.self)
    let receiver = try GuestWindowSurfaceReceiver(service: service) { continuation.yield($0) }
    defer { receiver.stop() }

    var bootstrap = mach_port_t(MACH_PORT_NULL)
    task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap)
    typealias LookUp =
        @convention(c) (mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>) -> kern_return_t
    let lookUp = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "bootstrap_look_up"), to: LookUp.self)
    var destination = mach_port_t(MACH_PORT_NULL)
    #expect(service.withCString { lookUp(bootstrap, $0, &destination) } == KERN_SUCCESS)

    let message = UnsafeMutableRawPointer.allocate(byteCount: GuestWindowSurfaceReceiver.messageSize, alignment: 8)
    defer { message.deallocate() }
    message.initializeMemory(as: UInt8.self, repeating: 0, count: GuestWindowSurfaceReceiver.messageSize)
    let header = message.bindMemory(to: mach_msg_header_t.self, capacity: 1)
    header.pointee.msgh_bits = UInt32(MACH_MSGH_BITS_COMPLEX) | UInt32(MACH_MSG_TYPE_COPY_SEND)
    header.pointee.msgh_size = mach_msg_size_t(GuestWindowSurfaceReceiver.messageSize)
    header.pointee.msgh_remote_port = destination
    header.pointee.msgh_id = 0x5347_4652
    message.storeBytes(of: UInt32(1), toByteOffset: 24, as: UInt32.self)  // One descriptor.
    message.storeBytes(of: IOSurfaceCreateMachPort(surface), toByteOffset: 28, as: UInt32.self)
    message.storeBytes(of: UInt32(MACH_MSG_TYPE_COPY_SEND) << 16, toByteOffset: 36, as: UInt32.self)  // Disposition; a port's type is 0.
    for (offset, value) in [(40, 0x10000 | 321), (44, 7), (48, 8), (52, 4), (56, -192), (60, -148)] {
        message.storeBytes(of: Int32(value), toByteOffset: offset, as: Int32.self)
    }
    #expect(
        mach_msg(header, MACH_SEND_MSG, mach_msg_size_t(GuestWindowSurfaceReceiver.messageSize), 0, 0, 0, 0)
            == MACH_MSG_SUCCESS)

    var iterator = stream.makeAsyncIterator()
    let frame = try #require(await iterator.next())
    #expect(frame.window == 321 && frame.isShape)
    #expect(frame.frame == 7)
    #expect(IOSurfaceGetWidth(frame.surface) == 8)
    #expect(frame.origin.x == -192 && frame.origin.y == -148)
}
