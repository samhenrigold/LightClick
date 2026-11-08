/* Guest-only Mavericks copy tests. Never execute this binary on the host. */
#include "copy-wire.h"
#include "../vendor/source/VMsvga2/AC/UCMethods.h"
#include "../vendor/source/VMsvga2/vminclude/vim_passthrough_opengl.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <pthread.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int done;
static unsigned last_error;
static double seconds(void) {
    mach_timebase_info_data_t base;
    if (mach_timebase_info(&base) || !base.denom) _exit(120);
    return mach_absolute_time() * (double)base.numer / base.denom / 1e9;
}
static void *watchdog(void *timeout) {
    double until = seconds() + (double)(uintptr_t)timeout;
    while (!__atomic_load_n(&done, __ATOMIC_ACQUIRE)) {
        if (seconds() >= until) {
            static const char message[] = "LC_COPY_GUEST timeout=1\n";
            (void)write(STDERR_FILENO, message, sizeof(message) - 1);
            _exit(124);
        }
        usleep(20000);
    }
    return NULL;
}
static int transfer(io_connect_t endpoint, void *buffer, size_t bytes, int writing) {
    unsigned char *p = buffer;
    while (bytes) {
        uint32_t chunk = bytes > LC_COPY_GUEST_CHUNK ? LC_COPY_GUEST_CHUNK : (uint32_t)bytes;
        struct VIMGLTransfer request = {writing ? 2u : 3u, chunk, (uintptr_t)p};
        struct VIMGLResult result = {0};
        size_t count = sizeof(result);
        IOReturn error = IOConnectCallStructMethod(endpoint, kIOVM2DDirectGLTransfer,
                                                   &request, sizeof(request), &result, &count);
        if (error) __atomic_store_n(&last_error, (unsigned)error, __ATOMIC_RELAXED);
        if (error || count != sizeof(result) || result.count <= 0 || (uint32_t)result.count > chunk)
            return -1; /* Never replay an ambiguous transfer. */
        p += result.count;
        bytes -= (size_t)result.count;
    }
    return 0;
}
static int open_endpoint(io_connect_t *endpoint) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("VMsvga2Accel"));
    if (!service) return -1;
    IOReturn error = IOServiceOpen(service, mach_task_self(), 2, endpoint);
    if (error) __atomic_store_n(&last_error, (unsigned)error, __ATOMIC_RELAXED);
    IOObjectRelease(service);
    if (error) return -1;
    struct VIMGLTransfer request = {1, 0, 0};
    struct VIMGLResult result = {0};
    size_t bytes = sizeof(result);
    error = IOConnectCallStructMethod(*endpoint, kIOVM2DDirectGLTransfer,
                                      &request, sizeof(request), &result, &bytes);
    if (error) __atomic_store_n(&last_error, (unsigned)error, __ATOMIC_RELAXED);
    return error || bytes != sizeof(result) || result.count != 0 ? -1 : 0;
}
static struct LCCopyHeader header(uint32_t type, const uint64_t nonce[2], uint64_t job, uint64_t bytes) {
    struct LCCopyHeader h = {0};
    h.magic = LC_COPY_MAGIC; h.version = LC_COPY_VERSION; h.type = type;
    if (nonce) { h.session[0] = nonce[0]; h.session[1] = nonce[1]; }
    h.job = job; h.payload_bytes = bytes;
    return h;
}
static int response(io_connect_t endpoint, uint32_t type, const uint64_t nonce[2],
                    uint64_t job, uint64_t bytes, uint32_t flags, uint32_t status,
                    struct LCCopyHeader *out) {
    if (transfer(endpoint, out, sizeof(*out), 0)) return -1;
    if (out->magic != LC_COPY_MAGIC || out->version != LC_COPY_VERSION || out->type != type ||
        out->job != job || out->payload_bytes != bytes || out->flags != flags ||
        out->status != status || out->reserved) return -1;
    if (nonce && (out->session[0] != nonce[0] || out->session[1] != nonce[1])) return -1;
    return 0;
}
static int hello(io_connect_t endpoint, uint32_t flags, uint64_t nonce[2]) {
    struct LCCopyHeader h = header(LC_COPY_HELLO, flags & LC_COPY_TX ? NULL : nonce, 0, 0), reply;
    h.flags = flags;
    if (transfer(endpoint, &h, sizeof(h), 1) ||
        response(endpoint, LC_COPY_HELLO_ACK, flags & LC_COPY_TX ? NULL : nonce,
                 0, sizeof(struct LCCopyCaps), flags, LC_COPY_OK, &reply)) return -1;
    if (!(reply.session[0] | reply.session[1])) return -1;
    struct LCCopyCaps caps;
    if (transfer(endpoint, &caps, sizeof(caps), 0) || caps.frame_bytes != LC_COPY_FRAME_BYTES ||
        caps.max_payload_bytes != sizeof(struct LCCopyFrameInfo) + LC_COPY_FRAME_BYTES ||
        caps.slots != LC_COPY_SLOTS || caps.max_jobs != LC_COPY_MAX_JOBS ||
        caps.guest_chunk != LC_COPY_GUEST_CHUNK || caps.reserved) return -1;
    nonce[0] = reply.session[0]; nonce[1] = reply.session[1];
    return 0;
}
static uint64_t digest(const unsigned char *p, size_t bytes) {
    uint64_t hash = UINT64_C(14695981039346656037);
    while (bytes--) { hash ^= *p++; hash *= UINT64_C(1099511628211); }
    return hash;
}
struct Receiver {
    io_connect_t endpoint;
    uint64_t nonce[2], expected[2];
    unsigned completed, error, seen, read_intent;
};
static void *receive_results(void *opaque) {
    struct Receiver *r = opaque;
    for (unsigned i = 0; i < 2; ++i) {
        struct LCCopyHeader request = header(LC_COPY_NEXT_RESULT, r->nonce, 0, 0), reply;
        struct LCCopyResult result;
        if (transfer(r->endpoint, &request, sizeof(request), 1)) goto error;
        /* The host has accepted NEXT_RESULT. This attests read intent, not
         * entry into the kernel's blocking-read wait. */
        if (i == 0) __atomic_store_n(&r->read_intent, 1, __ATOMIC_RELEASE);
        if (transfer(r->endpoint, &reply, sizeof(reply), 0)) goto error;
        if (reply.magic != LC_COPY_MAGIC || reply.version != LC_COPY_VERSION || reply.type != LC_COPY_RESULT ||
            reply.session[0] != r->nonce[0] || reply.session[1] != r->nonce[1] ||
            reply.job < 1 || reply.job > 2 || reply.payload_bytes != sizeof(result) ||
            reply.flags || reply.status != LC_COPY_OK || reply.reserved) goto error;
        unsigned bit = 1u << (unsigned)(reply.job - 1);
        if (r->seen & bit || transfer(r->endpoint, &result, sizeof(result), 0) ||
            result.bytes != LC_COPY_FRAME_BYTES || result.hash != r->expected[reply.job - 1] || result.reserved) goto error;
        r->seen |= bit;
        __atomic_add_fetch(&r->completed, 1, __ATOMIC_RELEASE);
    }
    return NULL;
error:
    __atomic_store_n(&r->error, 1, __ATOMIC_RELEASE);
    return NULL;
}
static int frame(io_connect_t endpoint, const uint64_t nonce[2], uint64_t job,
                 unsigned char *pixels, uint32_t expected_status) {
    struct LCCopyHeader h = header(LC_COPY_FRAME, nonce, job, sizeof(struct LCCopyFrameInfo) + LC_COPY_FRAME_BYTES), reply;
    struct LCCopyFrameInfo info = {LC_COPY_PIXEL_FORMAT, LC_COPY_WIDTH, LC_COPY_HEIGHT,
                                   LC_COPY_STRIDE, LC_COPY_FRAME_BYTES, 0};
    return transfer(endpoint, &h, sizeof(h), 1) || transfer(endpoint, &info, sizeof(info), 1) ||
           transfer(endpoint, pixels, (size_t)LC_COPY_FRAME_BYTES, 1) ||
           response(endpoint, LC_COPY_FRAME_ACK, nonce, job, 0, 0, expected_status, &reply) ? -1 : 0;
}

#define THROUGHPUT_JOBS 240u
_Static_assert(THROUGHPUT_JOBS <= LC_COPY_MAX_JOBS && LC_COPY_MAX_JOBS <= 256, "throughput job bitset");
struct ThroughputReceiver {
    io_connect_t endpoint;
    uint64_t nonce[2], expected[2], seen[4];
    unsigned delivered, error, read_intent;
};
static void *receive_throughput_results(void *opaque) {
    struct ThroughputReceiver *r = opaque;
    for (unsigned i = 0; i < THROUGHPUT_JOBS; ++i) {
        struct LCCopyHeader request = header(LC_COPY_NEXT_RESULT, r->nonce, 0, 0), reply;
        struct LCCopyResult result;
        if (transfer(r->endpoint, &request, sizeof(request), 1)) goto error;
        /* As in the ownership test, this proves request acceptance, not entry
         * into the kernel's blocking-read wait. */
        if (i == 0) __atomic_store_n(&r->read_intent, 1, __ATOMIC_RELEASE);
        if (transfer(r->endpoint, &reply, sizeof(reply), 0)) goto error;
        if (reply.magic != LC_COPY_MAGIC || reply.version != LC_COPY_VERSION || reply.type != LC_COPY_RESULT ||
            reply.session[0] != r->nonce[0] || reply.session[1] != r->nonce[1] ||
            reply.job < 1 || reply.job > THROUGHPUT_JOBS || reply.payload_bytes != sizeof(result) ||
            reply.flags || reply.status != LC_COPY_OK || reply.reserved) goto error;
        unsigned index = (unsigned)(reply.job - 1);
        uint64_t bit = UINT64_C(1) << (index & 63);
        if (r->seen[index >> 6] & bit || transfer(r->endpoint, &result, sizeof(result), 0) ||
            result.bytes != LC_COPY_FRAME_BYTES || result.hash != r->expected[index & 1] || result.reserved) goto error;
        r->seen[index >> 6] |= bit;
        /* The backend freed this result's slot before its final read returned.
         * Publish the credit only after every byte and its identity validate. */
        __atomic_add_fetch(&r->delivered, 1, __ATOMIC_RELEASE);
    }
    return NULL;
error:
    __atomic_store_n(&r->error, 1, __ATOMIC_RELEASE);
    return NULL;
}
static int throughput(void) {
    double started = seconds(), transfer_started = 0, transfer_finished = 0;
    pthread_t timer;
    if (pthread_create(&timer, NULL, watchdog, (void *)(uintptr_t)60)) return 3;
    io_connect_t tx = 0, rx = 0;
    unsigned char *pixels[2] = {NULL, NULL};
    struct ThroughputReceiver receiver = {0};
    struct LCCopyDrainStats stats = {0};
    pthread_t reader;
    int reader_started = 0, receiver_ready = 0, status = 1, clean_close = 1;
    unsigned accepted = 0;
    const char *step = "allocation";
#define THROUGHPUT_CHECK(expression, label) do { step = label; if (!(expression)) goto cleanup; } while (0)
    pixels[0] = malloc((size_t)LC_COPY_FRAME_BYTES);
    pixels[1] = malloc((size_t)LC_COPY_FRAME_BYTES);
    THROUGHPUT_CHECK(pixels[0] && pixels[1], "allocation");
    for (unsigned i = 0; i < 2; ++i) {
        memset(pixels[i], i ? 0xa7 : 0x31, (size_t)LC_COPY_FRAME_BYTES);
        receiver.expected[i] = digest(pixels[i], (size_t)LC_COPY_FRAME_BYTES);
    }
    THROUGHPUT_CHECK(!open_endpoint(&tx) && !open_endpoint(&rx), "two-existing-userclients");
    THROUGHPUT_CHECK(!hello(tx, LC_COPY_TX, receiver.nonce), "tx-hello-no-hold");
    THROUGHPUT_CHECK(!hello(rx, LC_COPY_RX, receiver.nonce), "rx-hello");
    receiver.endpoint = rx;
    THROUGHPUT_CHECK(!pthread_create(&reader, NULL, receive_throughput_results, &receiver), "receiver-thread");
    reader_started = 1;
    double ready_until = seconds() + 1;
    while (!__atomic_load_n(&receiver.read_intent, __ATOMIC_ACQUIRE) &&
           !__atomic_load_n(&receiver.error, __ATOMIC_ACQUIRE) && seconds() < ready_until) usleep(1000);
    THROUGHPUT_CHECK(__atomic_load_n(&receiver.read_intent, __ATOMIC_ACQUIRE) &&
                     !__atomic_load_n(&receiver.error, __ATOMIC_ACQUIRE), "receiver-intent-before-submit");
    receiver_ready = 1;
    transfer_started = seconds();
    for (unsigned job = 1; job <= THROUGHPUT_JOBS; ++job) {
        /* Credits are conservative even for out-of-order results: only fully
         * validated reads release a credit, and no third accepted job is sent. */
        unsigned delivered;
        for (;;) {
            delivered = __atomic_load_n(&receiver.delivered, __ATOMIC_ACQUIRE);
            THROUGHPUT_CHECK(!__atomic_load_n(&receiver.error, __ATOMIC_ACQUIRE) &&
                             delivered <= accepted, "receiver-credit");
            if (accepted - delivered < LC_COPY_SLOTS) break;
            usleep(100);
        }
        /* Unexpected QUEUE_FULL is an error. Never resend any frame. */
        THROUGHPUT_CHECK(!frame(tx, receiver.nonce, job, pixels[(job - 1) & 1], LC_COPY_OK), "throughput-owned-copy");
        ++accepted;
    }
    THROUGHPUT_CHECK(!pthread_join(reader, NULL), "receiver-join");
    reader_started = 0;
    THROUGHPUT_CHECK(!receiver.error && receiver.delivered == THROUGHPUT_JOBS &&
                     receiver.seen[0] == UINT64_MAX && receiver.seen[1] == UINT64_MAX &&
                     receiver.seen[2] == UINT64_MAX && receiver.seen[3] == ((UINT64_C(1) << 48) - 1),
                     "240-unique-completions");
    struct LCCopyHeader h = header(LC_COPY_DRAIN, receiver.nonce, 0, 0), reply;
    THROUGHPUT_CHECK(!transfer(tx, &h, sizeof(h), 1) &&
                     !response(tx, LC_COPY_DRAIN_ACK, receiver.nonce, 0, sizeof(stats), 0, 0, &reply) &&
                     !transfer(tx, &stats, sizeof(stats), 0), "worker-drain");
    transfer_finished = seconds();
    THROUGHPUT_CHECK(accepted == THROUGHPUT_JOBS && stats.accepted == THROUGHPUT_JOBS &&
                     stats.completed == THROUGHPUT_JOBS && stats.delivered == THROUGHPUT_JOBS &&
                     !stats.cancelled && stats.peak_slots >= 1 && stats.peak_slots <= LC_COPY_SLOTS &&
                     !stats.live_slots && stats.worker_stopped == 1 && !stats.reserved &&
                     transfer_finished > transfer_started, "drained-counts");
    status = 0; step = "complete";
cleanup:
    /* The watchdog remains armed through cancellation, joins and both closes. */
    if (tx) {
        IOReturn error = IOServiceClose(tx);
        if (error) {
            clean_close = 0;
            __atomic_store_n(&last_error, (unsigned)error, __ATOMIC_RELAXED);
            if (!status) { status = 1; step = "tx-close"; }
        }
    }
    if (reader_started && pthread_join(reader, NULL)) {
        /* Do not return or free receiver state with an unretired I/O thread. */
        static const char message[] = "LC_COPY_GUEST receiver_join_failed=1\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(125);
    }
    if (rx) {
        IOReturn error = IOServiceClose(rx);
        if (error) {
            clean_close = 0;
            __atomic_store_n(&last_error, (unsigned)error, __ATOMIC_RELAXED);
            if (!status) { status = 1; step = "rx-close"; }
        }
    }
    free(pixels[0]); free(pixels[1]);
    __atomic_store_n(&done, 1, __ATOMIC_RELEASE);
    if (pthread_join(timer, NULL) && !status) { status = 1; step = "watchdog-join"; }
    double elapsed = status ? 0 : transfer_finished - transfer_started;
    double fullguest = seconds() - started;
    printf("{\"result\":\"%s\",\"step\":\"%s\",\"mode\":\"throughput\",\"io_return\":%u,\"accepted\":%" PRIu64 ",\"completed\":%" PRIu64 ",\"delivered_to_guest\":%u,\"frame_bytes\":%" PRIu64 ",\"guest_seconds\":%.9f,\"fullguest_seconds\":%.9f,\"transfer_hash_seconds\":%.9f,\"frames_per_second\":%.9f,\"receiver_intent_before_submit\":%s,\"cancelled\":%" PRIu64 ",\"host_delivered\":%" PRIu64 ",\"peak_slots\":%" PRIu64 ",\"live_slots\":%" PRIu64 ",\"worker_stopped\":%" PRIu64 ",\"clean_close\":%s,\"speedup_measured\":false,\"host_codec_API_invoked\":false}\n",
           status ? "COPY_TRANSPORT_FAILED" : "COPY_TRANSPORT_THROUGHPUT_PASS", step,
           (unsigned)last_error, stats.accepted, stats.completed, receiver.delivered, LC_COPY_FRAME_BYTES,
           fullguest, fullguest, elapsed, elapsed > 0 ? THROUGHPUT_JOBS / elapsed : 0,
           receiver_ready ? "true" : "false", stats.cancelled, stats.delivered, stats.peak_slots,
           stats.live_slots, stats.worker_stopped, clean_close ? "true" : "false");
    return status;
#undef THROUGHPUT_CHECK
}
int main(int argc, char **argv) {
    char release[64] = {0}; size_t release_bytes = sizeof(release);
    if (argc != 2 || (strcmp(argv[1], "--mavericks-copy-test") && strcmp(argv[1], "--mavericks-copy-throughput")) ||
        sysctlbyname("kern.osrelease", release, &release_bytes, NULL, 0) || strncmp(release, "13.", 3)) {
        fputs("Guest-only Mavericks probe; refusing this environment\n", stderr); return 2;
    }
    if (!strcmp(argv[1], "--mavericks-copy-throughput")) return throughput();
    pthread_t timer;
    if (pthread_create(&timer, NULL, watchdog, (void *)(uintptr_t)10)) return 3;
    io_connect_t tx = 0, rx = 0;
    unsigned char *pixels = malloc((size_t)LC_COPY_FRAME_BYTES);
    struct Receiver receiver = {0};
    pthread_t reader; int reader_started = 0, receiver_ready = 0, status = 1;
    const char *step = "allocation";
    double started = seconds();
    struct LCCopyDrainStats stats = {0};
#define CHECK(expression, label) do { step = label; if (!(expression)) goto cleanup; } while (0)
    CHECK(pixels, "allocation");
    memset(pixels, 0x31, (size_t)LC_COPY_FRAME_BYTES); receiver.expected[0] = digest(pixels, (size_t)LC_COPY_FRAME_BYTES);
    memset(pixels, 0xa7, (size_t)LC_COPY_FRAME_BYTES); receiver.expected[1] = digest(pixels, (size_t)LC_COPY_FRAME_BYTES);
    CHECK(!open_endpoint(&tx) && !open_endpoint(&rx), "two-existing-userclients");
    CHECK(!hello(tx, LC_COPY_TX | LC_COPY_HOLD, receiver.nonce), "tx-hello");
    CHECK(!hello(rx, LC_COPY_RX, receiver.nonce), "rx-hello");
    receiver.endpoint = rx;
    CHECK(!pthread_create(&reader, NULL, receive_results, &receiver), "receiver-thread"); reader_started = 1;
    double ready_until = seconds() + 1;
    while (!__atomic_load_n(&receiver.read_intent, __ATOMIC_ACQUIRE) &&
           !__atomic_load_n(&receiver.error, __ATOMIC_ACQUIRE) && seconds() < ready_until) usleep(1000);
    CHECK(__atomic_load_n(&receiver.read_intent, __ATOMIC_ACQUIRE) &&
          !__atomic_load_n(&receiver.error, __ATOMIC_ACQUIRE), "receiver-intent-before-submit");
    receiver_ready = 1;
    memset(pixels, 0x31, (size_t)LC_COPY_FRAME_BYTES);
    CHECK(!frame(tx, receiver.nonce, 1, pixels, LC_COPY_OK), "first-owned-copy");
    memset(pixels, 0xcc, (size_t)LC_COPY_FRAME_BYTES); /* Caller may reuse immediately after ACK. */
    memset(pixels, 0xa7, (size_t)LC_COPY_FRAME_BYTES);
    CHECK(!frame(tx, receiver.nonce, 2, pixels, LC_COPY_OK), "second-owned-copy");
    memset(pixels, 0xcc, (size_t)LC_COPY_FRAME_BYTES);
    CHECK(!__atomic_load_n(&receiver.completed, __ATOMIC_ACQUIRE), "hold-prevents-early-completion");
    CHECK(!frame(tx, receiver.nonce, 3, pixels, LC_COPY_QUEUE_FULL), "two-slot-backpressure");
    CHECK(!__atomic_load_n(&receiver.completed, __ATOMIC_ACQUIRE), "backpressure-preserves-hold");
    struct LCCopyHeader h = header(LC_COPY_RELEASE, receiver.nonce, 0, 0), reply;
    CHECK(!transfer(tx, &h, sizeof(h), 1) && !response(tx, LC_COPY_RELEASE_ACK, receiver.nonce, 0, 0, 0, 0, &reply), "release");
    h = header(LC_COPY_DRAIN, receiver.nonce, 0, 0);
    CHECK(!transfer(tx, &h, sizeof(h), 1) &&
          !response(tx, LC_COPY_DRAIN_ACK, receiver.nonce, 0, sizeof(stats), 0, 0, &reply) &&
          !transfer(tx, &stats, sizeof(stats), 0), "worker-drain");
    CHECK(!pthread_join(reader, NULL), "receiver-join"); reader_started = 0;
    CHECK(!receiver.error && receiver.completed == 2 && receiver.seen == 3, "two-exact-completions");
    CHECK(stats.accepted == 2 && stats.completed == 2 && !stats.cancelled && stats.delivered <= 2 &&
          stats.peak_slots == 2 && !stats.live_slots && stats.worker_stopped == 1 && !stats.reserved, "drained-counts");
    status = 0; step = "complete";
cleanup:
    /* On any ambiguous failure the collector must retire the entire clone, never resend. */
    if (tx) { /* Cancels the pair and wakes a blocked RX read. */
        IOReturn error = IOServiceClose(tx);
        if (error) {
            __atomic_store_n(&last_error, (unsigned)error, __ATOMIC_RELAXED);
            if (!status) { status = 1; step = "tx-close"; }
        }
    }
    if (reader_started && pthread_join(reader, NULL) && !status) { status = 1; step = "receiver-cleanup-join"; }
    if (rx) {
        IOReturn error = IOServiceClose(rx);
        if (error) {
            __atomic_store_n(&last_error, (unsigned)error, __ATOMIC_RELAXED);
            if (!status) { status = 1; step = "rx-close"; }
        }
    }
    free(pixels);
    __atomic_store_n(&done, 1, __ATOMIC_RELEASE);
    if (pthread_join(timer, NULL) && !status) { status = 1; step = "watchdog-join"; }
    printf("{\"result\":\"%s\",\"step\":\"%s\",\"io_return\":%u,\"accepted\":%" PRIu64 ",\"completed\":%" PRIu64 ",\"delivered_to_guest\":%u,\"frame_bytes\":%" PRIu64 ",\"guest_seconds\":%.9f,\"receiver_intent_before_submit\":%s,\"speedup_measured\":false,\"host_codec_API_invoked\":false}\n",
           status ? "COPY_TRANSPORT_FAILED" : "COPY_TRANSPORT_OWNERSHIP_PASS", step,
           (unsigned)last_error, stats.accepted, stats.completed, receiver.completed,
           LC_COPY_FRAME_BYTES, seconds() - started, receiver_ready ? "true" : "false");
    return status;
}
