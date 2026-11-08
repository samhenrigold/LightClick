/* Copy-only protocol experiment. This translation unit deliberately uses no
 * graphics, media, guest mapping, or framework interfaces. */
#include "copy-worker.h"
#include "copy-wire.h"
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum SlotState { SLOT_FREE, SLOT_FILLING, SLOT_QUEUED, SLOT_WORKING, SLOT_DONE };
enum Pending { PENDING_NONE, PENDING_RESULT, PENDING_DRAIN };
struct CopySlot {
    unsigned char *bytes;
    enum SlotState state;
    uint64_t job, hash;
    uint32_t status;
};
struct CopySession {
    uint64_t nonce[2], last_attempt;
    unsigned attempts, references, rx_bound;
    int hold, draining, stopped, joining, joined, error;
    atomic_int cancelled;
    pthread_t worker;
    struct CopySlot slots[LC_COPY_SLOTS];
    unsigned results[LC_COPY_SLOTS], result_head, result_count;
    struct LCCopyDrainStats stats;
};
struct LCCopyEndpoint {
    struct CopySession *session;
    unsigned role;
    int shutdown, error;
    unsigned char header[sizeof(struct LCCopyHeader)];
    size_t header_used;
    struct LCCopyHeader request;
    unsigned char info[sizeof(struct LCCopyFrameInfo)];
    uint64_t payload_used;
    int frame_slot, frame_full;
    enum Pending pending;
    unsigned char response[sizeof(struct LCCopyHeader) + sizeof(struct LCCopyDrainStats)];
    size_t response_size, response_used;
};

/* One pair per loaded worker/QEMU process. Endpoint I/O is caller-serialized;
 * the mutex also protects shutdown racing that I/O and worker ownership. */
static pthread_mutex_t copy_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t copy_changed = PTHREAD_COND_INITIALIZER;
static struct CopySession *copy_session;
static unsigned copy_live_endpoints;

static uint64_t live_inputs(const struct CopySession *s)
{
    uint64_t n = 0;
    for (unsigned i = 0; i < LC_COPY_SLOTS; ++i)
        n += s->slots[i].state == SLOT_FILLING || s->slots[i].state == SLOT_QUEUED ||
             s->slots[i].state == SLOT_WORKING;
    return n;
}

static int endpoint_error(const struct LCCopyEndpoint *e)
{
    if (e->error) return e->error;
    if (e->session && e->session->error) return e->session->error;
    if (e->shutdown || (e->session && atomic_load(&e->session->cancelled))) return ECANCELED;
    return 0;
}

static void cancel_session(struct CopySession *s, int error)
{
    if (error && !s->error) s->error = error;
    atomic_store(&s->cancelled, 1);
    s->hold = 0;
    /* Incomplete inputs were never accepted, and the worker never sees them. */
    for (unsigned i = 0; i < LC_COPY_SLOTS; ++i)
        if (s->slots[i].state == SLOT_FILLING) s->slots[i].state = SLOT_FREE;
    s->stats.live_slots = live_inputs(s);
    pthread_cond_broadcast(&copy_changed);
}

static int protocol_error(struct LCCopyEndpoint *e)
{
    e->error = EPROTO;
    /* An unbound endpoint has no authority over an existing pair. */
    if (e->session) cancel_session(e->session, EPROTO);
    pthread_cond_broadcast(&copy_changed);
    errno = EPROTO;
    return -1;
}

static void *copy_worker(void *arg)
{
    struct CopySession *s = arg;
    pthread_mutex_lock(&copy_lock);
    for (;;) {
        int chosen = -1;
        for (unsigned i = 0; i < LC_COPY_SLOTS; ++i)
            if (s->slots[i].state == SLOT_QUEUED &&
                (chosen < 0 || s->slots[i].job < s->slots[chosen].job)) chosen = (int)i;
        int cancelled = atomic_load(&s->cancelled);
        if (chosen >= 0 && (!s->hold || cancelled)) {
            struct CopySlot *slot = &s->slots[chosen];
            slot->state = SLOT_WORKING;
            pthread_mutex_unlock(&copy_lock);
            uint64_t hash = UINT64_C(14695981039346656037);
            if (!cancelled) {
                for (uint64_t j = 0; j < LC_COPY_FRAME_BYTES; ++j) {
                    if ((j & 65535u) == 0 && atomic_load(&s->cancelled)) {
                        cancelled = 1;
                        break;
                    }
                    hash = (hash ^ slot->bytes[j]) * UINT64_C(1099511628211);
                }
            }
            pthread_mutex_lock(&copy_lock);
            if (atomic_load(&s->cancelled)) cancelled = 1;
            slot->hash = cancelled ? 0 : hash;
            slot->status = cancelled ? LC_COPY_CANCELLED : LC_COPY_OK;
            slot->state = SLOT_DONE;
            if (cancelled) ++s->stats.cancelled;
            else ++s->stats.completed;
            /* DONE retains the slot until result delivery. Consequently these
             * two result positions can never overflow or block worker drain. */
            s->results[(s->result_head + s->result_count) % LC_COPY_SLOTS] = (unsigned)chosen;
            ++s->result_count;
            s->stats.live_slots = live_inputs(s);
            pthread_cond_broadcast(&copy_changed);
            continue;
        }
        if ((s->draining || cancelled) && chosen < 0) break;
        pthread_cond_wait(&copy_changed, &copy_lock);
    }
    s->stopped = 1;
    s->stats.worker_stopped = 1;
    s->stats.live_slots = live_inputs(s);
    pthread_cond_broadcast(&copy_changed);
    pthread_mutex_unlock(&copy_lock);
    return NULL;
}

/* Called with the mutex held; no endpoint/session may be freed while caller
 * I/O is active. Concurrent close/drain callers elect exactly one joiner. */
static int join_worker(struct CopySession *s)
{
    while (s->joining) pthread_cond_wait(&copy_changed, &copy_lock);
    if (s->joined) return 0;
    s->joining = 1;
    pthread_mutex_unlock(&copy_lock);
    int rc = pthread_join(s->worker, NULL);
    pthread_mutex_lock(&copy_lock);
    s->joining = 0;
    if (!rc) s->joined = 1;
    pthread_cond_broadcast(&copy_changed);
    return rc;
}

static struct CopySession *new_session(int hold)
{
    struct CopySession *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    for (unsigned i = 0; i < LC_COPY_SLOTS; ++i) {
        s->slots[i].bytes = malloc((size_t)LC_COPY_FRAME_BYTES);
        if (!s->slots[i].bytes) {
            for (unsigned j = 0; j < i; ++j) free(s->slots[j].bytes);
            free(s);
            return NULL;
        }
    }
    do { arc4random_buf(s->nonce, sizeof(s->nonce)); } while (!(s->nonce[0] | s->nonce[1]));
    atomic_init(&s->cancelled, 0);
    s->hold = hold;
    s->references = 1;
    int rc = pthread_create(&s->worker, NULL, copy_worker, s);
    if (rc) {
        for (unsigned i = 0; i < LC_COPY_SLOTS; ++i) free(s->slots[i].bytes);
        free(s);
        errno = rc;
        return NULL;
    }
    return s;
}

static void reply(struct LCCopyEndpoint *e, uint32_t type, uint64_t job,
                  uint32_t flags, uint32_t status, const void *payload, size_t size)
{
    struct LCCopyHeader h = {0};
    h.magic = LC_COPY_MAGIC; h.version = LC_COPY_VERSION; h.type = type;
    h.session[0] = e->session->nonce[0]; h.session[1] = e->session->nonce[1];
    h.job = job; h.payload_bytes = size; h.flags = flags; h.status = status;
    memcpy(e->response, &h, sizeof(h));
    if (size) memcpy(e->response + sizeof(h), payload, size);
    e->response_size = sizeof(h) + size;
    e->response_used = 0;
    pthread_cond_broadcast(&copy_changed);
}

static int handle_header(struct LCCopyEndpoint *e)
{
    const struct LCCopyHeader *h = &e->request;
    if (h->magic != LC_COPY_MAGIC || h->version != LC_COPY_VERSION || h->reserved || h->status)
        return protocol_error(e);
    if (!e->session) {
        if (h->type != LC_COPY_HELLO || h->job || h->payload_bytes) return protocol_error(e);
        if (h->flags == LC_COPY_TX || h->flags == (LC_COPY_TX | LC_COPY_HOLD)) {
            if (h->session[0] || h->session[1]) return protocol_error(e);
            if (copy_session) { e->error = EBUSY; errno = EBUSY; return -1; }
            struct CopySession *s = new_session((h->flags & LC_COPY_HOLD) != 0);
            if (!s) { e->error = errno ? errno : ENOMEM; return -1; }
            copy_session = e->session = s;
            e->role = LC_COPY_TX;
        } else if (h->flags == LC_COPY_RX) {
            struct CopySession *s = copy_session;
            if (!s || s->rx_bound || atomic_load(&s->cancelled) ||
                h->session[0] != s->nonce[0] || h->session[1] != s->nonce[1]) return protocol_error(e);
            s->rx_bound = 1; ++s->references;
            e->session = s; e->role = LC_COPY_RX;
        } else return protocol_error(e);
        struct LCCopyCaps caps = { LC_COPY_FRAME_BYTES,
            LC_COPY_FRAME_BYTES + sizeof(struct LCCopyFrameInfo), LC_COPY_SLOTS,
            LC_COPY_MAX_JOBS, LC_COPY_GUEST_CHUNK, 0 };
        reply(e, LC_COPY_HELLO_ACK, 0, h->flags, LC_COPY_OK, &caps, sizeof(caps));
        return 0;
    }
    struct CopySession *s = e->session;
    if (h->session[0] != s->nonce[0] || h->session[1] != s->nonce[1] || h->flags)
        return protocol_error(e);
    if (h->type == LC_COPY_FRAME) {
        if (e->role != LC_COPY_TX || s->draining ||
            h->payload_bytes != sizeof(struct LCCopyFrameInfo) + LC_COPY_FRAME_BYTES ||
            !h->job || h->job > LC_COPY_MAX_JOBS || h->job <= s->last_attempt ||
            s->attempts >= LC_COPY_MAX_JOBS) return protocol_error(e);
        s->last_attempt = h->job; ++s->attempts;
        e->payload_used = 0; e->frame_slot = -1; e->frame_full = 1;
        for (unsigned i = 0; i < LC_COPY_SLOTS; ++i) if (s->slots[i].state == SLOT_FREE) {
            e->frame_slot = (int)i; e->frame_full = 0;
            s->slots[i].state = SLOT_FILLING; s->slots[i].job = h->job;
            break;
        }
        s->stats.live_slots = live_inputs(s);
        uint64_t occupied = 0;
        for (unsigned i = 0; i < LC_COPY_SLOTS; ++i) occupied += s->slots[i].state != SLOT_FREE;
        if (occupied > s->stats.peak_slots) s->stats.peak_slots = occupied;
        return 0;
    }
    if (h->job || h->payload_bytes) return protocol_error(e);
    switch (h->type) {
    case LC_COPY_RELEASE:
        if (e->role != LC_COPY_TX || s->draining) return protocol_error(e);
        s->hold = 0;
        pthread_cond_broadcast(&copy_changed);
        reply(e, LC_COPY_RELEASE_ACK, 0, 0, LC_COPY_OK, NULL, 0);
        return 0;
    case LC_COPY_NEXT_RESULT:
        if (e->role != LC_COPY_RX) return protocol_error(e);
        e->pending = PENDING_RESULT;
        return 0;
    case LC_COPY_DRAIN:
        if (e->role != LC_COPY_TX || s->draining) return protocol_error(e);
        s->draining = 1; s->hold = 0; e->pending = PENDING_DRAIN;
        pthread_cond_broadcast(&copy_changed);
        return 0;
    default:
        return protocol_error(e);
    }
}

struct LCCopyEndpoint *LCCopyEndpointOpen(void)
{
    struct LCCopyEndpoint *e = calloc(1, sizeof(*e));
    if (!e) return NULL;
    e->frame_slot = -1;
    pthread_mutex_lock(&copy_lock);
    ++copy_live_endpoints;
    pthread_mutex_unlock(&copy_lock);
    return e;
}

ssize_t LCCopyEndpointWrite(struct LCCopyEndpoint *e, const void *bytes, size_t count)
{
    if (!e || (!bytes && count) || count > (size_t)SSIZE_MAX) { errno = EINVAL; return -1; }
    if (!count) return 0;
    const unsigned char *p = bytes;
    size_t consumed = 0;
    pthread_mutex_lock(&copy_lock);
    int error = endpoint_error(e);
    if (error) { errno = error; pthread_mutex_unlock(&copy_lock); return -1; }
    if (e->response_size || e->pending) {
        protocol_error(e); pthread_mutex_unlock(&copy_lock); return -1;
    }
    while (consumed < count) {
        if (e->header_used < sizeof(e->header)) {
            size_t n = sizeof(e->header) - e->header_used;
            if (n > count - consumed) n = count - consumed;
            memcpy(e->header + e->header_used, p + consumed, n);
            e->header_used += n; consumed += n;
            if (e->header_used < sizeof(e->header)) break;
            memcpy(&e->request, e->header, sizeof(e->request));
            if (handle_header(e) < 0) { pthread_mutex_unlock(&copy_lock); return -1; }
            if (e->request.type != LC_COPY_FRAME) {
                e->header_used = 0;
                if (consumed != count) { protocol_error(e); pthread_mutex_unlock(&copy_lock); return -1; }
                break;
            }
        }
        if (e->payload_used < sizeof(e->info)) {
            size_t n = sizeof(e->info) - (size_t)e->payload_used;
            if (n > count - consumed) n = count - consumed;
            memcpy(e->info + e->payload_used, p + consumed, n);
            e->payload_used += n; consumed += n;
            if (e->payload_used < sizeof(e->info)) break;
            struct LCCopyFrameInfo info;
            memcpy(&info, e->info, sizeof(info));
            if (info.pixel_format != LC_COPY_PIXEL_FORMAT || info.width != LC_COPY_WIDTH ||
                info.height != LC_COPY_HEIGHT || info.stride != LC_COPY_STRIDE ||
                info.bytes != LC_COPY_FRAME_BYTES || info.reserved) {
                protocol_error(e); pthread_mutex_unlock(&copy_lock); return -1;
            }
        }
        size_t n = (size_t)(e->request.payload_bytes - e->payload_used);
        if (n > count - consumed) n = count - consumed;
        if (!e->frame_full && n)
            memcpy(e->session->slots[e->frame_slot].bytes + e->payload_used - sizeof(e->info), p + consumed, n);
        e->payload_used += n; consumed += n;
        if (e->payload_used == e->request.payload_bytes) {
            if (!e->frame_full) {
                e->session->slots[e->frame_slot].state = SLOT_QUEUED;
                ++e->session->stats.accepted;
                pthread_cond_broadcast(&copy_changed);
            }
            reply(e, LC_COPY_FRAME_ACK, e->request.job, 0,
                  e->frame_full ? LC_COPY_QUEUE_FULL : LC_COPY_OK, NULL, 0);
            e->header_used = 0; e->frame_slot = -1;
            if (consumed != count) { protocol_error(e); pthread_mutex_unlock(&copy_lock); return -1; }
        }
    }
    pthread_mutex_unlock(&copy_lock);
    return (ssize_t)consumed;
}

ssize_t LCCopyEndpointRead(struct LCCopyEndpoint *e, void *bytes, size_t count)
{
    if (!e || (!bytes && count) || count > (size_t)SSIZE_MAX) { errno = EINVAL; return -1; }
    if (!count) return 0;
    pthread_mutex_lock(&copy_lock);
    for (;;) {
        int error = endpoint_error(e);
        if (error) { errno = error; pthread_mutex_unlock(&copy_lock); return -1; }
        struct CopySession *s = e->session;
        if (e->pending == PENDING_RESULT && s->result_count) {
            unsigned index = s->results[s->result_head];
            struct CopySlot *slot = &s->slots[index];
            struct LCCopyResult result = {
                slot->status == LC_COPY_OK ? LC_COPY_FRAME_BYTES : 0, slot->hash, 0 };
            reply(e, LC_COPY_RESULT, slot->job, 0, slot->status, &result, sizeof(result));
            s->result_head = (s->result_head + 1) % LC_COPY_SLOTS; --s->result_count;
            /* Keep the slot occupied until every byte of its result is read. */
            e->frame_slot = (int)index;
            e->pending = PENDING_NONE;
        }
        if (e->pending == PENDING_DRAIN && s->stopped) {
            int rc = join_worker(s);
            if (rc) { errno = rc; pthread_mutex_unlock(&copy_lock); return -1; }
            if (endpoint_error(e)) continue;
            reply(e, LC_COPY_DRAIN_ACK, 0, 0, LC_COPY_OK, &s->stats, sizeof(s->stats));
            e->pending = PENDING_NONE;
        }
        if (e->response_size) break;
        if (e->pending == PENDING_RESULT && s->stopped && !s->result_count) {
            e->pending = PENDING_NONE;
            pthread_mutex_unlock(&copy_lock);
            return 0;
        }
        pthread_cond_wait(&copy_changed, &copy_lock);
    }
    size_t n = e->response_size - e->response_used;
    if (n > count) n = count;
    memcpy(bytes, e->response + e->response_used, n);
    e->response_used += n;
    if (e->response_used == e->response_size) {
        struct LCCopyHeader h;
        memcpy(&h, e->response, sizeof(h));
        if (h.type == LC_COPY_RESULT) {
            e->session->slots[e->frame_slot].state = SLOT_FREE;
            e->frame_slot = -1;
            ++e->session->stats.delivered;
            pthread_cond_broadcast(&copy_changed);
        }
        e->response_size = e->response_used = 0;
    }
    pthread_mutex_unlock(&copy_lock);
    return (ssize_t)n;
}

int LCCopyEndpointShutdown(struct LCCopyEndpoint *e)
{
    if (!e) { errno = EINVAL; return -1; }
    pthread_mutex_lock(&copy_lock);
    e->shutdown = 1;
    if (e->session) cancel_session(e->session, 0);
    pthread_cond_broadcast(&copy_changed);
    pthread_mutex_unlock(&copy_lock);
    return 0;
}

int LCCopyEndpointClose(struct LCCopyEndpoint *e)
{
    if (!e) { errno = EINVAL; return -1; }
    LCCopyEndpointShutdown(e);
    pthread_mutex_lock(&copy_lock);
    struct CopySession *s = e->session;
    if (s) {
        int rc = join_worker(s);
        if (rc) { errno = rc; pthread_mutex_unlock(&copy_lock); return -1; }
        if (--s->references == 0) {
            copy_session = NULL;
            for (unsigned i = 0; i < LC_COPY_SLOTS; ++i) free(s->slots[i].bytes);
            free(s);
        }
    }
    --copy_live_endpoints;
    pthread_mutex_unlock(&copy_lock);
    free(e);
    return 0;
}

unsigned LCCopyEndpointLiveCount(void)
{
    pthread_mutex_lock(&copy_lock);
    unsigned n = copy_live_endpoints;
    pthread_mutex_unlock(&copy_lock);
    return n;
}
