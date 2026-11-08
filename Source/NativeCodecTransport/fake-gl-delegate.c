/* Test-only ABI-2 delegate. No OpenGL, media, device, or guest operations. */
#include "../vendor/qemu/include/hw/display/vim-passthrough-opengl-inprocess.h"
#include "../vendor/qemu/include/hw/display/vim-passthrough-opengl-backing-notify.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dlfcn.h>

#define FAKE_BYTES 65536u
#define FAKE_PLAN 32u
struct LCFakeStats {
    unsigned opens, reads, writes, readvs, writevs, shutdowns, closes, live;
    unsigned subscribes, releases, read_entered;
    size_t written;
    uint64_t namespace_id[2], ticket;
};
struct FakeEndpoint { int stopped; };
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake = PTHREAD_COND_INITIALIZER;
static struct LCFakeStats stats;
static unsigned char written[FAKE_BYTES], read_bytes[FAKE_BYTES];
static size_t read_size, read_offset, plan_count, plan_offset;
static ssize_t plan[FAKE_PLAN];
static int block_read;

void LCFakeReset(void) {
    pthread_mutex_lock(&lock);
    memset(&stats, 0, sizeof(stats));
    read_size = read_offset = plan_count = plan_offset = 0;
    block_read = 0;
    pthread_mutex_unlock(&lock);
}
int LCFakeSetWritePlan(const ssize_t *p, size_t n) {
    if (n > FAKE_PLAN || (n && !p)) return EINVAL;
    pthread_mutex_lock(&lock);
    if (n) memcpy(plan, p, n * sizeof(*p));
    plan_count = n; plan_offset = 0;
    pthread_mutex_unlock(&lock);
    return 0;
}
int LCFakeSetReadBytes(const void *p, size_t n) {
    if (n > FAKE_BYTES || (n && !p)) return EINVAL;
    pthread_mutex_lock(&lock);
    if (n) memcpy(read_bytes, p, n);
    read_size = n; read_offset = 0;
    pthread_mutex_unlock(&lock);
    return 0;
}
void LCFakeSetBlockRead(int yes) {
    pthread_mutex_lock(&lock); block_read = yes;
    pthread_cond_broadcast(&wake); pthread_mutex_unlock(&lock);
}
void LCFakeGetStats(struct LCFakeStats *out) {
    pthread_mutex_lock(&lock); *out = stats; pthread_mutex_unlock(&lock);
}
size_t LCFakeCopyWritten(void *p, size_t cap) {
    pthread_mutex_lock(&lock);
    size_t n = stats.written < cap ? stats.written : cap;
    if (n) memcpy(p, written, n);
    pthread_mutex_unlock(&lock); return n;
}
int LCFakeWaitReadEntered(unsigned milliseconds) {
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += milliseconds / 1000;
    until.tv_nsec += (long)(milliseconds % 1000) * 1000000;
    if (until.tv_nsec >= 1000000000) { until.tv_sec++; until.tv_nsec -= 1000000000; }
    pthread_mutex_lock(&lock);
    int error = 0;
    while (!stats.read_entered && !error) error = pthread_cond_timedwait(&wake, &lock, &until);
    int entered = stats.read_entered != 0;
    pthread_mutex_unlock(&lock); return entered;
}
static void *fake_open(void) {
    struct FakeEndpoint *e = calloc(1, sizeof(*e));
    if (!e) return NULL;
    pthread_mutex_lock(&lock); stats.opens++; stats.live++; pthread_mutex_unlock(&lock);
    return e;
}
static ssize_t fake_read(void *p, void *b, size_t n) {
    struct FakeEndpoint *e = p;
    pthread_mutex_lock(&lock); stats.reads++; stats.read_entered++;
    pthread_cond_broadcast(&wake);
    while (block_read && !e->stopped) pthread_cond_wait(&wake, &lock);
    if (e->stopped) { pthread_mutex_unlock(&lock); errno = ECANCELED; return -1; }
    size_t take = read_size - read_offset;
    if (take > n) take = n;
    if (take) memcpy(b, read_bytes + read_offset, take);
    read_offset += take;
    pthread_mutex_unlock(&lock); return (ssize_t)take;
}
static ssize_t fake_write(void *p, const void *b, size_t n) {
    struct FakeEndpoint *e = p;
    pthread_mutex_lock(&lock); stats.writes++;
    if (e->stopped) { pthread_mutex_unlock(&lock); errno = ECANCELED; return -1; }
    ssize_t limit = plan_offset < plan_count ? plan[plan_offset++] : (ssize_t)n;
    if (limit < 0) { pthread_mutex_unlock(&lock); errno = (int)-limit; return -1; }
    size_t take = (size_t)limit < n ? (size_t)limit : n;
    if (take > FAKE_BYTES - stats.written) {
        pthread_mutex_unlock(&lock); errno = ENOSPC; return -1;
    }
    if (take) memcpy(written + stats.written, b, take);
    stats.written += take;
    pthread_mutex_unlock(&lock); return (ssize_t)take;
}
static ssize_t fake_readv(void *p, const struct iovec *v, int count) {
    pthread_mutex_lock(&lock); stats.readvs++; pthread_mutex_unlock(&lock);
    size_t done = 0;
    for (int i = 0; i < count; i++) {
        ssize_t n = fake_read(p, v[i].iov_base, v[i].iov_len);
        if (n < 0) return done ? (ssize_t)done : n;
        done += (size_t)n;
        if ((size_t)n != v[i].iov_len) break;
    }
    return (ssize_t)done;
}
static ssize_t fake_writev(void *p, const struct iovec *v, int count) {
    pthread_mutex_lock(&lock); stats.writevs++; pthread_mutex_unlock(&lock);
    size_t done = 0;
    for (int i = 0; i < count; i++) {
        ssize_t n = fake_write(p, v[i].iov_base, v[i].iov_len);
        if (n < 0) return done ? (ssize_t)done : n;
        done += (size_t)n;
        if ((size_t)n != v[i].iov_len) break;
    }
    return (ssize_t)done;
}
static int fake_shutdown(void *p) {
    struct FakeEndpoint *e = p;
    pthread_mutex_lock(&lock); stats.shutdowns++; e->stopped = 1;
    pthread_cond_broadcast(&wake); pthread_mutex_unlock(&lock); return 0;
}
static int fake_close(void *p) {
    pthread_mutex_lock(&lock); stats.closes++; stats.live--; pthread_mutex_unlock(&lock);
    free(p); return 0;
}
static unsigned fake_live(void) {
    pthread_mutex_lock(&lock); unsigned n = stats.live; pthread_mutex_unlock(&lock); return n;
}
#ifndef LC_FAKE_NO_GETTER
const struct VIMGLInprocessAPI *VIMPassthroughOpenGLInprocessGetAPI(uint32_t version, uint32_t bytes) {
#ifdef LC_FAKE_RECURSIVE
    VIMGLGetInprocessAPI get = (VIMGLGetInprocessAPI)dlsym(RTLD_DEFAULT, "VIMPassthroughOpenGLInprocessGetAPI");
    return get ? get(version, bytes) : NULL;
#else
    static const struct VIMGLInprocessAPI api = {
#ifdef LC_FAKE_BAD_ABI
        1,
#else
        VIM_GL_INPROCESS_ABI,
#endif
        sizeof(api), fake_open, fake_read, fake_write, fake_readv, fake_writev,
        fake_shutdown,
#ifdef LC_FAKE_NULL_CALLBACK
        NULL,
#else
        fake_close,
#endif
        fake_live};
    return version == VIM_GL_INPROCESS_ABI && bytes == sizeof(api) ? &api : NULL;
#endif
}
#endif
#ifndef LC_FAKE_NO_NOTIFY
static int fake_subscribe(const uint64_t ns[2], uint64_t ticket,
                          VIMGLBackingNotifyCallback callback, void *opaque) {
    pthread_mutex_lock(&lock); stats.subscribes++;
    memcpy(stats.namespace_id, ns, sizeof(stats.namespace_id)); stats.ticket = ticket;
    pthread_mutex_unlock(&lock);
    if (!callback) return EINVAL;
    callback(opaque, 0); /* Deliberately synchronous: ABI explicitly permits this. */
    return 0;
}
static int fake_release(const uint64_t ns[2], uint64_t ticket) {
    pthread_mutex_lock(&lock); stats.releases++;
    memcpy(stats.namespace_id, ns, sizeof(stats.namespace_id)); stats.ticket = ticket;
    pthread_mutex_unlock(&lock); return EBUSY;
}
const struct VIMGLBackingNotifyAPI *VIMPassthroughOpenGLBackingNotifyGetAPI(uint32_t version, uint32_t bytes) {
    static const struct VIMGLBackingNotifyAPI api = {
        VIM_GL_BACKING_NOTIFY_ABI, sizeof(api), fake_subscribe, fake_release};
    return version == api.version && bytes == sizeof(api) ? &api : NULL;
}
#endif
