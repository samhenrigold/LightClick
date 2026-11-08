/* Actual signed mux + actual worker, through ONLY their public factory ABI.
 * The explicit delegate MUST be fake-gl-delegate.c, never a real GL library.
 * No worker implementation or LCCopyEndpoint symbol is compiled into this
 * executable: this catches the private-symbol binding absent from stub tests.
 *
 * clang -std=c11 -O2 -Wall -Wextra -Werror -pthread this-file.c -o /tmp/test
 * /tmp/test /absolute/signed/libLCCopyTransport.dylib /absolute/fake.dylib
 * An external runner additionally bounds this process to 20 seconds.
 */
#include "copy-wire.h"
#include "../vendor/qemu/include/hw/display/vim-passthrough-opengl-inprocess.h"
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static atomic_uint checks;
#define CHECK(x) do { atomic_fetch_add(&checks, 1); if (!(x)) { \
    fprintf(stderr, "FAIL %s:%d: %s (errno=%d)\n", __func__, __LINE__, #x, errno); exit(1); \
} } while (0)
struct LCFakeStats {
    unsigned opens, reads, writes, readvs, writevs, shutdowns, closes, live;
    unsigned subscribes, releases, read_entered;
    size_t written;
    uint64_t namespace_id[2], ticket;
};
static const struct VIMGLInprocessAPI *api;
struct Pair { void *tx, *rx; uint64_t nonce[2]; };

static void expired(int signal_number) { (void)signal_number; _exit(124); }
static struct LCCopyHeader header(uint32_t type, const uint64_t *nonce,
                                  uint64_t job, uint64_t size, uint32_t flags) {
    struct LCCopyHeader h = {0};
    h.magic = LC_COPY_MAGIC; h.version = LC_COPY_VERSION; h.type = type;
    if (nonce) memcpy(h.session, nonce, sizeof(h.session));
    h.job = job; h.payload_bytes = size; h.flags = flags;
    return h;
}
static void write_exact(void *stream, const void *bytes, size_t size, size_t chunk) {
    const unsigned char *p = bytes;
    while (size) {
        size_t part = size < chunk ? size : chunk;
        ssize_t n = api->write(stream, p, part);
        if (n < 0 && errno == EINTR) continue;
        CHECK(n > 0 && (size_t)n <= part);
        p += n; size -= (size_t)n;
    }
}
static void write_header_vectors(void *stream, const struct LCCopyHeader *h) {
    struct iovec v[] = {{(void *)h, 3}, {(char *)h + 3, 4},
                       {(char *)h + 7, 1}, {(char *)h + 8, sizeof(*h) - 8}};
    int first = 0;
    while (first < 4) {
        ssize_t n = api->writev(stream, v + first, 4 - first);
        if (n < 0 && errno == EINTR) continue;
        CHECK(n > 0);
        size_t left = (size_t)n;
        while (first < 4 && left >= v[first].iov_len) {
            left -= v[first].iov_len; first++;
        }
        if (first == 4) CHECK(!left);
        else { v[first].iov_base = (char *)v[first].iov_base + left; v[first].iov_len -= left; }
    }
}
static void read_exact(void *stream, void *bytes, size_t size) {
    unsigned char *p = bytes;
    while (size) {
        size_t part = size < 11 ? size : 11;
        ssize_t n = api->read(stream, p, part);
        if (n < 0 && errno == EINTR) continue;
        CHECK(n > 0 && (size_t)n <= part);
        p += n; size -= (size_t)n;
    }
}
static struct LCCopyHeader response(void *stream, const uint64_t *nonce, uint32_t type,
                                    uint64_t job, uint32_t status, uint64_t size) {
    struct LCCopyHeader h;
    read_exact(stream, &h, sizeof(h));
    CHECK(h.magic == LC_COPY_MAGIC && h.version == LC_COPY_VERSION && h.type == type);
    CHECK(h.job == job && h.status == status && h.payload_bytes == size && !h.reserved);
    if (nonce) CHECK(!memcmp(h.session, nonce, sizeof(h.session)));
    return h;
}
static struct Pair open_pair(void) {
    struct Pair p = {api->open(), api->open(), {0, 0}};
    CHECK(p.tx && p.rx && api->live_count() == 2);
    struct LCCopyHeader h = header(LC_COPY_HELLO, NULL, 0, 0, LC_COPY_TX | LC_COPY_HOLD);
    write_header_vectors(p.tx, &h);
    struct LCCopyHeader ack = response(p.tx, NULL, LC_COPY_HELLO_ACK, 0,
                                        LC_COPY_OK, sizeof(struct LCCopyCaps));
    CHECK(ack.flags == (LC_COPY_TX | LC_COPY_HOLD) && (ack.session[0] || ack.session[1]));
    memcpy(p.nonce, ack.session, sizeof(p.nonce));
    struct LCCopyCaps caps;
    read_exact(p.tx, &caps, sizeof(caps));
    CHECK(caps.frame_bytes == LC_COPY_FRAME_BYTES && caps.max_payload_bytes == LC_COPY_FRAME_BYTES + 32);
    CHECK(caps.slots == 2 && caps.max_jobs == 256 && caps.guest_chunk == LC_COPY_GUEST_CHUNK && !caps.reserved);
    h = header(LC_COPY_HELLO, p.nonce, 0, 0, LC_COPY_RX);
    write_header_vectors(p.rx, &h);
    ack = response(p.rx, p.nonce, LC_COPY_HELLO_ACK, 0, LC_COPY_OK, sizeof(caps));
    CHECK(ack.flags == LC_COPY_RX);
    read_exact(p.rx, &caps, sizeof(caps));
    CHECK(caps.frame_bytes == LC_COPY_FRAME_BYTES && caps.max_payload_bytes == LC_COPY_FRAME_BYTES + 32);
    CHECK(caps.slots == 2 && caps.max_jobs == 256 && caps.guest_chunk == LC_COPY_GUEST_CHUNK && !caps.reserved);
    return p;
}
static unsigned char *pattern(unsigned which, uint64_t *hash) {
    unsigned char *bytes = malloc((size_t)LC_COPY_FRAME_BYTES);
    CHECK(bytes);
    *hash = UINT64_C(14695981039346656037);
    for (uint64_t i = 0; i < LC_COPY_FRAME_BYTES; i++) {
        bytes[i] = which == 1 ? (unsigned char)(i * 17 + (i >> 12)) :
                               (unsigned char)(0xa5u ^ (i >> 3) ^ i);
        *hash = (*hash ^ bytes[i]) * UINT64_C(1099511628211);
    }
    return bytes;
}
static void frame(struct Pair *p, uint64_t job, unsigned char *bytes, uint32_t status, int mutate) {
    struct LCCopyHeader h = header(LC_COPY_FRAME, p->nonce, job,
        sizeof(struct LCCopyFrameInfo) + LC_COPY_FRAME_BYTES, 0);
    write_exact(p->tx, &h, sizeof(h), 13);
    struct LCCopyFrameInfo info = {LC_COPY_PIXEL_FORMAT, LC_COPY_WIDTH, LC_COPY_HEIGHT,
                                   LC_COPY_STRIDE, LC_COPY_FRAME_BYTES, 0};
    write_exact(p->tx, &info, sizeof(info), 3);
    size_t offset = 0;
    while (offset < LC_COPY_FRAME_BYTES) {
        size_t n = (size_t)LC_COPY_FRAME_BYTES - offset;
        if (n > LC_COPY_GUEST_CHUNK) n = LC_COPY_GUEST_CHUNK;
        write_exact(p->tx, bytes + offset, n, n);
        /* HOLD keeps hashing asleep. Mutating every returned write span
         * proves the actual worker retains its own copy, not this pointer. */
        if (mutate) memset(bytes + offset, 0xee, n);
        offset += n;
    }
    struct LCCopyHeader ack = response(p->tx, p->nonce, LC_COPY_FRAME_ACK, job, status, 0);
    CHECK(!ack.flags);
}
static void result(struct Pair *p, uint64_t expected_job, uint64_t expected_hash, int request) {
    if (request) {
        struct LCCopyHeader h = header(LC_COPY_NEXT_RESULT, p->nonce, 0, 0, 0);
        write_exact(p->rx, &h, sizeof(h), 5);
    }
    struct LCCopyHeader h = response(p->rx, p->nonce, LC_COPY_RESULT, expected_job,
                                      LC_COPY_OK, sizeof(struct LCCopyResult));
    CHECK(!h.flags);
    struct LCCopyResult r;
    read_exact(p->rx, &r, sizeof(r));
    CHECK(r.bytes == LC_COPY_FRAME_BYTES && r.hash == expected_hash && !r.reserved);
}
struct Reader {
    struct Pair *pair;
    uint64_t hash;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int requested;
    atomic_int done;
};
static void *pending_reader(void *opaque) {
    struct Reader *r = opaque;
    struct LCCopyHeader h = header(LC_COPY_NEXT_RESULT, r->pair->nonce, 0, 0, 0);
    write_exact(r->pair->rx, &h, sizeof(h), 5);
    pthread_mutex_lock(&r->lock);
    r->requested = 1;
    pthread_cond_signal(&r->changed);
    pthread_mutex_unlock(&r->lock);
    result(r->pair, 1, r->hash, 0);
    atomic_store(&r->done, 1);
    return NULL;
}
int main(int argc, char **argv) {
    if (argc != 3 || argv[1][0] != '/' || argv[2][0] != '/') {
        fprintf(stderr, "usage: test-copy-mux-integration /absolute/signed-mux.dylib /absolute/pure-libc-fake.dylib\n");
        return 2;
    }
    signal(SIGALRM, expired); alarm(15);
    CHECK(!setenv("LC_COPY_GL_DELEGATE", argv[2], 1));
    void *fake = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL); CHECK(fake);
    void (*reset)(void) = (void (*)(void))dlsym(fake, "LCFakeReset");
    void (*stats)(struct LCFakeStats *) = (void (*)(struct LCFakeStats *))dlsym(fake, "LCFakeGetStats");
    CHECK(reset && stats); reset();
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "combined library: %s\n", dlerror()); return 1; }
    VIMGLGetInprocessAPI get = (VIMGLGetInprocessAPI)dlsym(library, "VIMPassthroughOpenGLInprocessGetAPI");
    CHECK(get); api = get(VIM_GL_INPROCESS_ABI, sizeof(*api));
    CHECK(api && api->version == VIM_GL_INPROCESS_ABI && api->bytes == sizeof(*api) && api->live_count);
    CHECK(api->live_count() == 0);
    struct Pair pair = open_pair();
    uint64_t hash_a, hash_b;
    unsigned char *a = pattern(1, &hash_a), *b = pattern(2, &hash_b);
    CHECK(hash_a != hash_b);
    frame(&pair, 1, a, LC_COPY_OK, 1);
    frame(&pair, 2, b, LC_COPY_OK, 1);
    struct Reader reader = {.pair = &pair, .hash = hash_a,
        .lock = PTHREAD_MUTEX_INITIALIZER, .changed = PTHREAD_COND_INITIALIZER};
    atomic_init(&reader.done, 0);
    pthread_t thread; CHECK(!pthread_create(&thread, NULL, pending_reader, &reader));
    pthread_mutex_lock(&reader.lock);
    while (!reader.requested) pthread_cond_wait(&reader.changed, &reader.lock);
    pthread_mutex_unlock(&reader.lock);
    /* RX has an outstanding result request while TX consumes a full rejected
     * frame and receives its QUEUE_FULL reply. No sleeps/polling are needed. */
    frame(&pair, 3, a, LC_COPY_QUEUE_FULL, 0);
    CHECK(!atomic_load(&reader.done));
    struct LCCopyHeader h = header(LC_COPY_RELEASE, pair.nonce, 0, 0, 0);
    write_exact(pair.tx, &h, sizeof(h), sizeof(h));
    h = response(pair.tx, pair.nonce, LC_COPY_RELEASE_ACK, 0, LC_COPY_OK, 0); CHECK(!h.flags);
    CHECK(!pthread_join(thread, NULL));
    CHECK(atomic_load(&reader.done));
    pthread_mutex_destroy(&reader.lock); pthread_cond_destroy(&reader.changed);
    result(&pair, 2, hash_b, 1);
    h = header(LC_COPY_DRAIN, pair.nonce, 0, 0, 0);
    write_exact(pair.tx, &h, sizeof(h), 8);
    h = response(pair.tx, pair.nonce, LC_COPY_DRAIN_ACK, 0, LC_COPY_OK, sizeof(struct LCCopyDrainStats));
    CHECK(!h.flags);
    struct LCCopyDrainStats drained; read_exact(pair.tx, &drained, sizeof(drained));
    CHECK(drained.accepted == 2 && drained.completed == 2 && !drained.cancelled && drained.delivered == 2);
    CHECK(drained.peak_slots == 2 && !drained.live_slots && drained.worker_stopped == 1 && !drained.reserved);
    h = header(LC_COPY_NEXT_RESULT, pair.nonce, 0, 0, 0);
    write_exact(pair.rx, &h, sizeof(h), 5);
    unsigned char byte; CHECK(api->read(pair.rx, &byte, 1) == 0); /* No result for rejected job3. */
    CHECK(api->close(pair.tx) == 0); CHECK(api->close(pair.rx) == 0);
    CHECK(api->live_count() == 0);
    struct LCFakeStats gl; stats(&gl);
    CHECK(!gl.opens && !gl.reads && !gl.writes && !gl.readvs && !gl.writevs &&
          !gl.shutdowns && !gl.closes && !gl.live && !gl.written && !gl.subscribes && !gl.releases);
    free(a); free(b);
    printf("{\"result\":\"PASS\",\"checks\":%u,\"frames_accepted\":2,\"frames_rejected\":1,"
           "\"matched_results\":2,\"outstanding_rx_request_tx_progress\":true,\"drained\":true,"
           "\"live_endpoints\":0,\"fake_GL_endpoint_calls\":0,\"worker_stubs\":false}\n",
           atomic_load(&checks));
    return 0; /* Retain both libraries until process exit; no dlclose. */
}
