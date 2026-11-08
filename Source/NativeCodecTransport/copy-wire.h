/* Experimental copy transport only. No codec, GL opcode, or guest pointers.
 * Both endpoints are little-endian Intel/ARM64. All reserved fields are zero.
 * A successful FRAME_ACK means the input has been copied into an owned slot.
 * DRAIN_ACK means the worker has stopped using inputs; the guest must separately
 * consume completion records before considering callbacks delivered.
 */
#ifndef LC_COPY_WIRE_H
#define LC_COPY_WIRE_H
#include <stdint.h>
#include <stddef.h>

#define LC_COPY_MAGIC UINT64_C(0x003159504f43434c) /* LCCOPY1\0 */
#define LC_COPY_VERSION 1u
#define LC_COPY_WIDTH 1920u
#define LC_COPY_HEIGHT 1080u
#define LC_COPY_STRIDE 3840u
#define LC_COPY_PIXEL_FORMAT 0x32767579u /* 2vuy */
#define LC_COPY_FRAME_BYTES UINT64_C(4147200)
#define LC_COPY_SLOTS 2u
#define LC_COPY_MAX_JOBS 256u
#define LC_COPY_GUEST_CHUNK 262144u

enum LCCopyType {
    LC_COPY_HELLO = 1, LC_COPY_FRAME = 2, LC_COPY_RELEASE = 3,
    LC_COPY_NEXT_RESULT = 4, LC_COPY_DRAIN = 5,
    LC_COPY_HELLO_ACK = 0x8001, LC_COPY_FRAME_ACK = 0x8002,
    LC_COPY_RELEASE_ACK = 0x8003, LC_COPY_RESULT = 0x8004,
    LC_COPY_DRAIN_ACK = 0x8005
};
enum LCCopyFlags {
    LC_COPY_TX = 1u, LC_COPY_RX = 2u, LC_COPY_HOLD = 0x100u
};
enum LCCopyStatus {
    LC_COPY_OK = 0, LC_COPY_QUEUE_FULL = 1, LC_COPY_CANCELLED = 2
};
struct LCCopyHeader {
    uint64_t magic;
    uint32_t version, type;
    uint64_t session[2], job, payload_bytes;
    uint32_t flags, status;
    uint64_t reserved;
};
struct LCCopyFrameInfo {
    uint32_t pixel_format, width, height, stride;
    uint64_t bytes, reserved;
};
struct LCCopyCaps {
    uint64_t frame_bytes, max_payload_bytes;
    uint32_t slots, max_jobs, guest_chunk, reserved;
};
struct LCCopyResult {
    uint64_t bytes, hash, reserved; /* FNV-1a64 over every byte; not authentication. */
};
struct LCCopyDrainStats {
    uint64_t accepted, completed, cancelled, delivered;
    uint64_t peak_slots, live_slots, worker_stopped, reserved;
};
_Static_assert(sizeof(struct LCCopyHeader) == 64, "copy header ABI");
_Static_assert(offsetof(struct LCCopyHeader, payload_bytes) == 40, "copy length ABI");
_Static_assert(sizeof(struct LCCopyFrameInfo) == 32, "copy frame ABI");
_Static_assert(sizeof(struct LCCopyCaps) == 32, "copy caps ABI");
_Static_assert(sizeof(struct LCCopyResult) == 24, "copy result ABI");
_Static_assert(sizeof(struct LCCopyDrainStats) == 64, "copy drain ABI");
#endif
