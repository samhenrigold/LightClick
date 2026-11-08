/* Focused libc/pthread tests of the actual worker, including private ownership
 * counters. Compile this file alone: it includes the implementation so tests
 * can check terminal accounting after shutdown without adding a public API. */
#include "copy-worker.c"
#include <signal.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { \
    fprintf(stderr, "FAIL line %d: %s (errno=%d)\n", __LINE__, #x, errno); exit(1); \
} } while (0)

struct Pair { struct LCCopyEndpoint *tx, *rx; uint64_t nonce[2]; };

static void timeout_handler(int sig) { (void)sig; _exit(124); }

static struct LCCopyHeader header(uint32_t type, const uint64_t *nonce,
                                  uint64_t job, uint64_t payload, uint32_t flags)
{
    struct LCCopyHeader h = {0};
    h.magic = LC_COPY_MAGIC; h.version = LC_COPY_VERSION; h.type = type;
    if (nonce) memcpy(h.session, nonce, sizeof(h.session));
    h.job = job; h.payload_bytes = payload; h.flags = flags;
    return h;
}

static void write_bytes(struct LCCopyEndpoint *e, const void *p, size_t n, size_t chunk)
{
    const unsigned char *bytes = p;
    while (n) {
        size_t part = n < chunk ? n : chunk;
        CHECK(LCCopyEndpointWrite(e, bytes, part) == (ssize_t)part);
        bytes += part; n -= part;
    }
}

static void read_bytes(struct LCCopyEndpoint *e, void *p, size_t n)
{
    unsigned char *bytes = p;
    while (n) {
        size_t part = n < 11 ? n : 11;
        ssize_t got = LCCopyEndpointRead(e, bytes, part);
        CHECK(got > 0 && (size_t)got <= part);
        bytes += got; n -= (size_t)got;
    }
}

static struct LCCopyHeader response(struct LCCopyEndpoint *e, uint32_t type,
                                    uint64_t job, uint32_t status, size_t size)
{
    struct LCCopyHeader h;
    read_bytes(e, &h, sizeof(h));
    CHECK(h.magic == LC_COPY_MAGIC && h.version == LC_COPY_VERSION && h.type == type);
    CHECK(h.job == job && h.status == status && h.payload_bytes == size && !h.reserved);
    return h;
}

static struct Pair pair_open(int hold)
{
    struct Pair p = {0};
    p.tx = LCCopyEndpointOpen(); p.rx = LCCopyEndpointOpen();
    CHECK(p.tx && p.rx && LCCopyEndpointLiveCount() == 2);
    struct LCCopyHeader h = header(LC_COPY_HELLO, NULL, 0, 0, LC_COPY_TX | (hold ? LC_COPY_HOLD : 0));
    write_bytes(p.tx, &h, sizeof(h), 7);
    struct LCCopyHeader ack = response(p.tx, LC_COPY_HELLO_ACK, 0, LC_COPY_OK, sizeof(struct LCCopyCaps));
    CHECK(ack.flags == h.flags && (ack.session[0] || ack.session[1]));
    memcpy(p.nonce, ack.session, sizeof(p.nonce));
    struct LCCopyCaps caps;
    read_bytes(p.tx, &caps, sizeof(caps));
    CHECK(caps.frame_bytes == LC_COPY_FRAME_BYTES && caps.max_payload_bytes == LC_COPY_FRAME_BYTES + 32);
    CHECK(caps.slots == 2 && caps.max_jobs == 256 && caps.guest_chunk == LC_COPY_GUEST_CHUNK && !caps.reserved);
    h = header(LC_COPY_HELLO, p.nonce, 0, 0, LC_COPY_RX);
    write_bytes(p.rx, &h, sizeof(h), 9);
    ack = response(p.rx, LC_COPY_HELLO_ACK, 0, LC_COPY_OK, sizeof(caps));
    CHECK(ack.flags == LC_COPY_RX && !memcmp(ack.session, p.nonce, sizeof(p.nonce)));
    read_bytes(p.rx, &caps, sizeof(caps));
    return p;
}

static void pair_close(struct Pair *p)
{
    CHECK(LCCopyEndpointClose(p->tx) == 0);
    CHECK(LCCopyEndpointClose(p->rx) == 0);
    CHECK(LCCopyEndpointLiveCount() == 0 && copy_session == NULL);
}

static unsigned char *pattern(unsigned kind, uint64_t *hash)
{
    unsigned char *bytes = malloc((size_t)LC_COPY_FRAME_BYTES);
    CHECK(bytes);
    *hash = UINT64_C(14695981039346656037);
    for (uint64_t i = 0; i < LC_COPY_FRAME_BYTES; ++i) {
        bytes[i] = kind == 1 ? (unsigned char)(i * 17 + (i >> 12)) : (unsigned char)(0xa5u ^ (i >> 3) ^ i);
        *hash = (*hash ^ bytes[i]) * UINT64_C(1099511628211);
    }
    return bytes;
}

static void frame(struct Pair *p, uint64_t job, unsigned char *bytes,
                  uint32_t expected_status, int mutate)
{
    struct LCCopyHeader h = header(LC_COPY_FRAME, p->nonce, job,
                                  sizeof(struct LCCopyFrameInfo) + LC_COPY_FRAME_BYTES, 0);
    uint64_t accepted = p->tx->session->stats.accepted;
    write_bytes(p->tx, &h, sizeof(h), 13);
    struct LCCopyFrameInfo info = {LC_COPY_PIXEL_FORMAT, LC_COPY_WIDTH, LC_COPY_HEIGHT,
                                   LC_COPY_STRIDE, LC_COPY_FRAME_BYTES, 0};
    write_bytes(p->tx, &info, sizeof(info), 3);
    size_t at = 0;
    while (at < LC_COPY_FRAME_BYTES - 1) {
        size_t n = (size_t)LC_COPY_FRAME_BYTES - 1 - at;
        if (n > LC_COPY_GUEST_CHUNK) n = LC_COPY_GUEST_CHUNK;
        write_bytes(p->tx, bytes + at, n, n);
        if (mutate) memset(bytes + at, 0xee, n);
        at += n;
    }
    pthread_mutex_lock(&copy_lock);
    CHECK(p->tx->response_size == 0 && p->tx->session->stats.accepted == accepted);
    pthread_mutex_unlock(&copy_lock);
    write_bytes(p->tx, bytes + at, 1, 1);
    if (mutate) bytes[at] = 0xee;
    struct LCCopyHeader ack = response(p->tx, LC_COPY_FRAME_ACK, job, expected_status, 0);
    CHECK(!ack.flags && !memcmp(ack.session, p->nonce, sizeof(p->nonce)));
}

static void control(struct Pair *p, uint32_t type, uint32_t ack)
{
    struct LCCopyHeader h = header(type, p->nonce, 0, 0, 0);
    write_bytes(p->tx, &h, sizeof(h), sizeof(h));
    response(p->tx, ack, 0, LC_COPY_OK, 0);
}

static void result(struct Pair *p, uint64_t job, uint64_t expected_hash)
{
    struct LCCopyHeader h = header(LC_COPY_NEXT_RESULT, p->nonce, 0, 0, 0);
    write_bytes(p->rx, &h, sizeof(h), 5);
    h = response(p->rx, LC_COPY_RESULT, job, LC_COPY_OK, sizeof(struct LCCopyResult));
    CHECK(!h.flags && !memcmp(h.session, p->nonce, sizeof(p->nonce)));
    struct LCCopyResult r;
    read_bytes(p->rx, &r, sizeof(r));
    CHECK(r.bytes == LC_COPY_FRAME_BYTES && r.hash == expected_hash && !r.reserved);
}

static void ownership_backpressure_drain(void)
{
    struct Pair p = pair_open(1);
    uint64_t ha, hb;
    unsigned char *a = pattern(1, &ha), *b = pattern(2, &hb);
    CHECK(ha != hb);
    frame(&p, 1, a, LC_COPY_OK, 1);
    frame(&p, 2, b, LC_COPY_OK, 1);
    frame(&p, 3, a, LC_COPY_QUEUE_FULL, 0);
    CHECK(p.tx->session->stats.accepted == 2 && p.tx->session->stats.completed == 0);
    CHECK(p.tx->session->stats.live_slots == 2 && p.tx->session->attempts == 3);
    control(&p, LC_COPY_RELEASE, LC_COPY_RELEASE_ACK);
    result(&p, 1, ha);
    free(a); a = pattern(1, &ha);
    frame(&p, 4, a, LC_COPY_OK, 1); /* job3 was discarded, not replayed. */
    struct LCCopyHeader h = header(LC_COPY_DRAIN, p.nonce, 0, 0, 0);
    write_bytes(p.tx, &h, sizeof(h), 8);
    response(p.tx, LC_COPY_DRAIN_ACK, 0, LC_COPY_OK, sizeof(struct LCCopyDrainStats));
    struct LCCopyDrainStats stats;
    read_bytes(p.tx, &stats, sizeof(stats));
    CHECK(stats.accepted == 3 && stats.completed == 3 && stats.cancelled == 0 && stats.delivered == 1);
    CHECK(stats.peak_slots == 2 && stats.live_slots == 0 && stats.worker_stopped == 1 && !stats.reserved);
    CHECK(p.tx->session->joined && p.tx->session->result_count == 2);
    result(&p, 2, hb); result(&p, 4, ha);
    CHECK(p.tx->session->stats.delivered == 3);
    /* Drain is terminal for submissions, including an otherwise valid new ID. */
    h = header(LC_COPY_FRAME, p.nonce, 5, sizeof(struct LCCopyFrameInfo) + LC_COPY_FRAME_BYTES, 0);
    CHECK(LCCopyEndpointWrite(p.tx, &h, sizeof(h)) == -1 && errno == EPROTO);
    pair_close(&p);
    free(a); free(b);
}

struct BlockedRead { struct LCCopyEndpoint *e; atomic_int entered, done; ssize_t n; int error; };
static void *blocked_read(void *arg)
{
    struct BlockedRead *b = arg;
    unsigned char byte;
    atomic_store(&b->entered, 1);
    b->n = LCCopyEndpointRead(b->e, &byte, 1); b->error = errno;
    atomic_store(&b->done, 1);
    return NULL;
}

static void cancellation(void)
{
    struct Pair p = pair_open(1);
    uint64_t hash;
    unsigned char *a = pattern(1, &hash);
    frame(&p, 1, a, LC_COPY_OK, 0); frame(&p, 2, a, LC_COPY_OK, 0);
    struct LCCopyHeader h = header(LC_COPY_NEXT_RESULT, p.nonce, 0, 0, 0);
    write_bytes(p.rx, &h, sizeof(h), sizeof(h));
    struct BlockedRead b = {.e = p.rx};
    atomic_init(&b.entered, 0); atomic_init(&b.done, 0);
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, blocked_read, &b) == 0);
    while (!atomic_load(&b.entered)) { struct timespec t = {0, 1000000}; nanosleep(&t, NULL); }
    struct timespec delay = {0, 10000000}; nanosleep(&delay, NULL);
    CHECK(!atomic_load(&b.done));
    CHECK(LCCopyEndpointShutdown(p.tx) == 0 && LCCopyEndpointShutdown(p.tx) == 0);
    CHECK(pthread_join(thread, NULL) == 0 && b.n == -1 && b.error == ECANCELED);
    CHECK(LCCopyEndpointClose(p.tx) == 0);
    struct CopySession *s = p.rx->session;
    CHECK(s->joined && s->stats.worker_stopped == 1 && s->stats.live_slots == 0);
    CHECK(s->stats.accepted == 2 && s->stats.cancelled == 2 && s->stats.completed == 0);
    CHECK(s->result_count == 2 && s->stats.accepted == s->stats.completed + s->stats.cancelled);
    for (unsigned i = 0; i < 2; ++i) CHECK(s->slots[i].state == SLOT_DONE && s->slots[i].status == LC_COPY_CANCELLED);
    CHECK(LCCopyEndpointClose(p.rx) == 0 && LCCopyEndpointLiveCount() == 0);
    free(a);
}

static void partial_cancel(unsigned phase)
{
    struct Pair p = pair_open(1);
    struct LCCopyHeader h = header(LC_COPY_FRAME, p.nonce, 1, sizeof(struct LCCopyFrameInfo) + LC_COPY_FRAME_BYTES, 0);
    write_bytes(p.tx, &h, phase == 0 ? 19 : sizeof(h), 19);
    struct LCCopyFrameInfo info = {LC_COPY_PIXEL_FORMAT, LC_COPY_WIDTH, LC_COPY_HEIGHT,
                                   LC_COPY_STRIDE, LC_COPY_FRAME_BYTES, 0};
    if (phase) write_bytes(p.tx, &info, phase == 1 ? 17 : sizeof(info), 17);
    unsigned char bytes[77] = {0};
    if (phase == 2) write_bytes(p.tx, bytes, sizeof(bytes), 77);
    CHECK(LCCopyEndpointShutdown(p.rx) == 0);
    CHECK(LCCopyEndpointWrite(p.tx, bytes, 1) == -1 && errno == ECANCELED);
    CHECK(LCCopyEndpointClose(p.tx) == 0);
    CHECK(p.rx->session->stats.accepted == 0 && p.rx->session->stats.live_slots == 0);
    CHECK(p.rx->session->stats.completed == 0 && p.rx->session->stats.cancelled == 0);
    CHECK(LCCopyEndpointClose(p.rx) == 0 && LCCopyEndpointLiveCount() == 0);
}

static void unbound_isolation(void)
{
    struct Pair p = pair_open(1);
    struct LCCopyEndpoint *bad = LCCopyEndpointOpen(); CHECK(bad);
    uint64_t wrong[2] = {p.nonce[0] ^ 1u, p.nonce[1]};
    struct LCCopyHeader h = header(LC_COPY_HELLO, wrong, 0, 0, LC_COPY_RX);
    CHECK(LCCopyEndpointWrite(bad, &h, sizeof(h)) == -1 && errno == EPROTO);
    CHECK(LCCopyEndpointClose(bad) == 0);
    CHECK(!atomic_load(&p.tx->session->cancelled) && !p.tx->session->error);
    bad = LCCopyEndpointOpen(); CHECK(bad);
    h = header(LC_COPY_HELLO, NULL, 0, 0, LC_COPY_TX);
    CHECK(LCCopyEndpointWrite(bad, &h, sizeof(h)) == -1 && errno == EBUSY);
    CHECK(LCCopyEndpointClose(bad) == 0);
    CHECK(!atomic_load(&p.tx->session->cancelled));
    control(&p, LC_COPY_RELEASE, LC_COPY_RELEASE_ACK);
    pair_close(&p);
}

static void malformed(unsigned kind)
{
    struct Pair p = pair_open(1);
    struct LCCopyHeader h = header(LC_COPY_FRAME, p.nonce, 1,
                                  sizeof(struct LCCopyFrameInfo) + LC_COPY_FRAME_BYTES, 0);
    if (kind == 0) h.session[1] ^= 1u;
    if (kind == 1) h.payload_bytes = UINT64_MAX;
    if (kind == 2) h.job = LC_COPY_MAX_JOBS + 1;
    if (kind == 3) h.reserved = 1;
    if (kind == 4) h.flags = LC_COPY_HOLD;
    if (kind < 5) CHECK(LCCopyEndpointWrite(p.tx, &h, sizeof(h)) == -1 && errno == EPROTO);
    else {
        write_bytes(p.tx, &h, sizeof(h), 7);
        struct LCCopyFrameInfo info = {LC_COPY_PIXEL_FORMAT, LC_COPY_WIDTH, LC_COPY_HEIGHT,
                                       LC_COPY_STRIDE + 1, LC_COPY_FRAME_BYTES, 0};
        CHECK(LCCopyEndpointWrite(p.tx, &info, sizeof(info)) == -1 && errno == EPROTO);
    }
    unsigned char byte;
    CHECK(LCCopyEndpointRead(p.rx, &byte, 1) == -1 && errno == EPROTO);
    CHECK(LCCopyEndpointWrite(p.tx, &h, 1) == -1 && errno == EPROTO);
    CHECK(p.tx->session->stats.accepted == 0);
    pair_close(&p);
}

static void queue_full_not_replayable(void)
{
    struct Pair p = pair_open(1);
    uint64_t hash; unsigned char *a = pattern(2, &hash);
    frame(&p, 1, a, LC_COPY_OK, 0); frame(&p, 2, a, LC_COPY_OK, 0);
    frame(&p, 3, a, LC_COPY_QUEUE_FULL, 0);
    struct LCCopyHeader h = header(LC_COPY_FRAME, p.nonce, 3,
                                  sizeof(struct LCCopyFrameInfo) + LC_COPY_FRAME_BYTES, 0);
    CHECK(LCCopyEndpointWrite(p.tx, &h, sizeof(h)) == -1 && errno == EPROTO);
    CHECK(LCCopyEndpointClose(p.tx) == 0);
    CHECK(p.rx->session->stats.accepted == 2 && p.rx->session->stats.cancelled == 2);
    CHECK(p.rx->session->attempts == 3);
    CHECK(LCCopyEndpointClose(p.rx) == 0 && LCCopyEndpointLiveCount() == 0);
    free(a);
}

int main(void)
{
    signal(SIGALRM, timeout_handler); alarm(10);
    CHECK(LCCopyEndpointLiveCount() == 0);
    ownership_backpressure_drain(); cancellation();
    for (unsigned i = 0; i < 3; ++i) partial_cancel(i);
    unbound_isolation();
    for (unsigned i = 0; i < 6; ++i) malformed(i);
    queue_full_not_replayable();
    CHECK(LCCopyEndpointLiveCount() == 0);
    alarm(0);
    printf("copy-worker PASS checks=%u patterns=2 raw_slots=2 jobs_limit=256\n", checks);
    return 0;
}
