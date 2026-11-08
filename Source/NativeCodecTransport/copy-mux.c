/* Opt-in host-only transport experiment. Codec streams never enter the GL
 * interpreter. Ordinary streams retain the explicitly selected delegate's
 * ABI-2 close/drain contract. No caller buffer survives an I/O return.
 *
 * One caller serializes each endpoint's I/O. Shutdown may race that I/O;
 * close follows retirement of ALL calls (including shutdown). The additional
 * active-call check refuses a premature close rather than freeing its owner.
 */
#include "copy-wire.h"
#include "copy-worker.h"
#include "../vendor/qemu/include/hw/display/vim-passthrough-opengl-inprocess.h"
#include "../vendor/qemu/include/hw/display/vim-passthrough-opengl-backing-notify.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

__attribute__((visibility("default"))) const struct VIMGLInprocessAPI *
VIMPassthroughOpenGLInprocessGetAPI(uint32_t, uint32_t);
__attribute__((visibility("default"))) const struct VIMGLBackingNotifyAPI *
VIMPassthroughOpenGLBackingNotifyGetAPI(uint32_t, uint32_t);

static pthread_once_t lc_delegate_once = PTHREAD_ONCE_INIT;
static const struct VIMGLInprocessAPI *lc_delegate;
static VIMGLGetBackingNotifyAPI lc_delegate_notify;
static void *lc_delegate_library; /* Never dlclose: callbacks can outlive streams. */
static struct stat lc_delegate_identity;
static int lc_delegate_error = EINVAL;
static _Thread_local unsigned lc_delegate_depth, lc_delegate_recursed;
static _Atomic unsigned lc_live;

static int lc_same_file(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}
static int lc_same_identity(const struct stat *a, const struct stat *b) {
    return lc_same_file(a, b) && a->st_size == b->st_size &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec &&
        a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec &&
        a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
}
static int lc_function_in_delegate(const void *function) {
    Dl_info info;
    struct stat identity;
    return function && dladdr(function, &info) && info.dli_fname &&
        !stat(info.dli_fname, &identity) && lc_same_file(&identity, &lc_delegate_identity);
}
static void lc_load_delegate(void) {
    const char *setting = getenv("LC_COPY_GL_DELEGATE");
    char path[PATH_MAX];
    Dl_info self;
    struct stat before, after, own;
    int fd = -1;
    lc_delegate_depth++;
    if (!setting || setting[0] != '/' || !realpath(setting, path) ||
        !dladdr((const void *)VIMPassthroughOpenGLInprocessGetAPI, &self) || !self.dli_fname ||
        stat(self.dli_fname, &own))
        goto out;
    fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
    if (fd < 0 || fstat(fd, &before) || !S_ISREG(before.st_mode))
        goto out;
    if (lc_same_file(&before, &own)) {
        lc_delegate_error = ELOOP;
        goto out;
    }
    lc_delegate_identity = before;
    lc_delegate_library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!lc_delegate_library)
        goto out;
    VIMGLGetInprocessAPI get = (VIMGLGetInprocessAPI)
        dlsym(lc_delegate_library, "VIMPassthroughOpenGLInprocessGetAPI");
    if (!get || get == VIMPassthroughOpenGLInprocessGetAPI ||
        !lc_function_in_delegate((const void *)get)) {
        lc_delegate_error = get ? ELOOP : EINVAL;
        goto out;
    }
    const struct VIMGLInprocessAPI *api = get(VIM_GL_INPROCESS_ABI, sizeof(*api));
    if (lc_delegate_recursed) {
        lc_delegate_error = ELOOP;
        goto out;
    }
    if (!api || api->version != VIM_GL_INPROCESS_ABI || api->bytes != sizeof(*api) ||
        !lc_function_in_delegate((const void *)api->open) ||
        !lc_function_in_delegate((const void *)api->read) ||
        !lc_function_in_delegate((const void *)api->write) ||
        !lc_function_in_delegate((const void *)api->readv) ||
        !lc_function_in_delegate((const void *)api->writev) ||
        !lc_function_in_delegate((const void *)api->shutdown) ||
        !lc_function_in_delegate((const void *)api->close) ||
        (api->live_count && !lc_function_in_delegate((const void *)api->live_count)))
        goto out;
    if (fstat(fd, &after) || !lc_same_identity(&before, &after) ||
        stat(path, &after) || !lc_same_identity(&before, &after))
        goto out;
    VIMGLGetBackingNotifyAPI notify = (VIMGLGetBackingNotifyAPI)
        dlsym(lc_delegate_library, "VIMPassthroughOpenGLBackingNotifyGetAPI");
    if (notify && (notify == VIMPassthroughOpenGLBackingNotifyGetAPI ||
                   !lc_function_in_delegate((const void *)notify))) {
        lc_delegate_error = ELOOP;
        goto out;
    }
    lc_delegate_notify = notify;
    lc_delegate = api;
    lc_delegate_error = 0;
out:
    if (fd >= 0)
        close(fd);
    lc_delegate_depth--;
}
static int lc_ready(void) {
    if (lc_delegate_depth) {
        lc_delegate_recursed = 1;
        errno = ELOOP;
        return 0;
    }
    int error = pthread_once(&lc_delegate_once, lc_load_delegate);
    if (error || !lc_delegate) {
        errno = error ? error : lc_delegate_error;
        return 0;
    }
    return 1;
}

enum LCMuxRoute { LC_PENDING, LC_GL, LC_CODEC };
struct LCMuxEndpoint {
    pthread_mutex_t lock;
    enum LCMuxRoute route;
    void *backend;
    unsigned active, cancelled, shutdown_sent, closing;
    int error;
    size_t prefix_bytes, prefix_sent;
    unsigned char prefix[8];
};
static int lc_enter(struct LCMuxEndpoint *e) {
    if (!e) { errno = EINVAL; return 0; }
    pthread_mutex_lock(&e->lock);
    if (e->closing) {
        pthread_mutex_unlock(&e->lock);
        errno = EBADF;
        return 0;
    }
    e->active++;
    pthread_mutex_unlock(&e->lock);
    return 1;
}
static void lc_leave(struct LCMuxEndpoint *e) {
    int saved = errno;
    pthread_mutex_lock(&e->lock);
    e->active--;
    pthread_mutex_unlock(&e->lock);
    errno = saved;
}
static int lc_cancelled(struct LCMuxEndpoint *e) {
    pthread_mutex_lock(&e->lock);
    unsigned result = e->cancelled;
    pthread_mutex_unlock(&e->lock);
    return result;
}
static int lc_backend_shutdown(struct LCMuxEndpoint *e) {
    return e->route == LC_GL ? lc_delegate->shutdown(e->backend) :
        LCCopyEndpointShutdown(e->backend);
}
/* Called only by the serialized I/O owner. Publish a backend before exposing
 * it to shutdown; a cancellation during open is propagated after publication. */
static int lc_bind(struct LCMuxEndpoint *e, enum LCMuxRoute route) {
    pthread_mutex_lock(&e->lock);
    if (e->route != LC_PENDING) {
        int error = e->error;
        int good = e->backend != NULL;
        pthread_mutex_unlock(&e->lock);
        if (!good) errno = error ? error : EIO;
        return good;
    }
    if (e->cancelled) {
        pthread_mutex_unlock(&e->lock);
        errno = EPIPE;
        return 0;
    }
    e->route = route; /* A chosen route never falls back to another backend. */
    pthread_mutex_unlock(&e->lock);
    void *backend = route == LC_GL ? lc_delegate->open() : LCCopyEndpointOpen();
    int error = backend ? 0 : (errno ? errno : EIO);
    pthread_mutex_lock(&e->lock);
    e->backend = backend;
    e->error = error;
    unsigned cancel = backend && e->cancelled && !e->shutdown_sent;
    if (cancel) e->shutdown_sent = 1;
    pthread_mutex_unlock(&e->lock);
    if (cancel) (void)lc_backend_shutdown(e);
    if (!backend) errno = error;
    return backend != NULL;
}
static ssize_t lc_backend_write(struct LCMuxEndpoint *e, const void *p, size_t n) {
    return e->route == LC_GL ? lc_delegate->write(e->backend, p, n) :
        LCCopyEndpointWrite(e->backend, p, n);
}
static int lc_flush_prefix(struct LCMuxEndpoint *e) {
    while (e->prefix_sent < e->prefix_bytes) {
        if (lc_cancelled(e)) { errno = EPIPE; return -1; }
        size_t left = e->prefix_bytes - e->prefix_sent;
        ssize_t n = lc_backend_write(e, e->prefix + e->prefix_sent, left);
        if (n <= 0) return (int)n;
        if ((size_t)n > left) { errno = EIO; return -1; }
        e->prefix_sent += (size_t)n;
    }
    return 1;
}
static int lc_vectors(const struct iovec *v, int count, size_t *total) {
    *total = 0;
    if (count < 0 || count > 1024 || (count && !v)) { errno = EINVAL; return 0; }
    for (int i = 0; i < count; i++) {
        if ((v[i].iov_len && !v[i].iov_base) || v[i].iov_len > (size_t)SSIZE_MAX - *total) {
            errno = EINVAL; return 0;
        }
        *total += v[i].iov_len;
    }
    return 1;
}
/* Initial prefix may already have been accepted by earlier calls. Its sent
 * cursor is independent of this call's consumed count: EINTR/short writes
 * therefore cannot replay any accepted delegate byte. */
static ssize_t lc_write_vectors(struct LCMuxEndpoint *e, const struct iovec *v, int count,
                                size_t total, int vector_call) {
    size_t accepted = 0;
    if (lc_cancelled(e)) { errno = EPIPE; return -1; }
    if (e->route == LC_PENDING) {
        const uint64_t magic = LC_COPY_MAGIC;
        for (int i = 0; i < count && e->prefix_bytes < sizeof(e->prefix); i++) {
            size_t amount = sizeof(e->prefix) - e->prefix_bytes;
            if (amount > v[i].iov_len) amount = v[i].iov_len;
            if (amount) memcpy(e->prefix + e->prefix_bytes, v[i].iov_base, amount);
            e->prefix_bytes += amount;
            accepted += amount;
            if (memcmp(e->prefix, &magic, e->prefix_bytes)) break;
        }
        if (memcmp(e->prefix, &magic, e->prefix_bytes)) {
            if (!lc_bind(e, LC_GL)) return accepted ? (ssize_t)accepted : -1;
        } else if (e->prefix_bytes == sizeof(e->prefix)) {
            if (!lc_bind(e, LC_CODEC)) return accepted ? (ssize_t)accepted : -1;
        } else {
            return (ssize_t)accepted;
        }
    }
    if (!e->backend) { errno = e->error ? e->error : EIO; return accepted ? (ssize_t)accepted : -1; }
    int flushed = lc_flush_prefix(e);
    if (flushed <= 0) return accepted ? (ssize_t)accepted : flushed;
    if (accepted == total) return (ssize_t)accepted;
    struct iovec remainder[1024];
    int used = 0;
    size_t skip = accepted;
    for (int i = 0; i < count; i++) {
        if (skip >= v[i].iov_len) { skip -= v[i].iov_len; continue; }
        remainder[used++] = (struct iovec){(char *)v[i].iov_base + skip, v[i].iov_len - skip};
        skip = 0;
    }
    ssize_t n;
    if (e->route == LC_GL) {
        n = vector_call ? lc_delegate->writev(e->backend, remainder, used) :
            lc_delegate->write(e->backend, remainder[0].iov_base, remainder[0].iov_len);
    } else {
        n = LCCopyEndpointWrite(e->backend, remainder[0].iov_base, remainder[0].iov_len);
    }
    size_t submitted = e->route == LC_GL && vector_call ? total - accepted : remainder[0].iov_len;
    if (n > 0 && (size_t)n > submitted) { errno = EIO; return accepted ? (ssize_t)accepted : -1; }
    return n > 0 ? (ssize_t)accepted + n : accepted ? (ssize_t)accepted : n;
}
static void *lc_open(void) {
    if (!lc_ready()) return NULL;
    unsigned old = atomic_fetch_add_explicit(&lc_live, 1, memory_order_relaxed);
    if (old >= 128) { atomic_fetch_sub_explicit(&lc_live, 1, memory_order_relaxed); errno = EMFILE; return NULL; }
    struct LCMuxEndpoint *e = calloc(1, sizeof(*e));
    int error = e ? pthread_mutex_init(&e->lock, NULL) : ENOMEM;
    if (error) {
        free(e); atomic_fetch_sub_explicit(&lc_live, 1, memory_order_relaxed); errno = error; return NULL;
    }
    return e;
}
static ssize_t lc_writev(void *opaque, const struct iovec *v, int count) {
    size_t total;
    if (!lc_vectors(v, count, &total)) return -1;
    if (!total) return 0;
    struct LCMuxEndpoint *e = opaque;
    if (!lc_enter(e)) return -1;
    ssize_t n = lc_write_vectors(e, v, count, total, 1);
    lc_leave(e); return n;
}
static ssize_t lc_write(void *opaque, const void *p, size_t bytes) {
    struct iovec v = {(void *)p, bytes};
    size_t total;
    if (!lc_vectors(&v, 1, &total)) return -1;
    if (!total) return 0;
    struct LCMuxEndpoint *e = opaque;
    if (!lc_enter(e)) return -1;
    ssize_t n = lc_write_vectors(e, &v, 1, total, 0);
    lc_leave(e); return n;
}
static ssize_t lc_read_vectors(struct LCMuxEndpoint *e, const struct iovec *v, int count,
                               size_t total, int vector_call) {
    if (!e->backend && lc_cancelled(e)) return 0;
    if (e->route == LC_PENDING) {
        /* A read before any write is ordinary GL. A partial codec prelude
         * cannot silently become GL just because its writer asks too early. */
        if (e->prefix_bytes) { errno = EAGAIN; return -1; }
        if (!lc_bind(e, LC_GL)) return lc_cancelled(e) ? 0 : -1;
    }
    if (!e->backend) { errno = e->error ? e->error : EIO; return -1; }
    int flushed = lc_flush_prefix(e);
    if (flushed <= 0 && !lc_cancelled(e)) return flushed;
    ssize_t n;
    size_t requested = total;
    if (e->route == LC_GL) {
        n = vector_call ? lc_delegate->readv(e->backend, v, count) :
            lc_delegate->read(e->backend, v[0].iov_base, v[0].iov_len);
    } else {
        int first = 0;
        while (first < count && !v[first].iov_len) first++;
        requested = v[first].iov_len;
        n = LCCopyEndpointRead(e->backend, v[first].iov_base, v[first].iov_len);
    }
    if (n > 0 && (size_t)n > requested) { errno = EIO; return -1; }
    return n;
}
static ssize_t lc_readv(void *opaque, const struct iovec *v, int count) {
    size_t total;
    if (!lc_vectors(v, count, &total)) return -1;
    if (!total) return 0;
    struct LCMuxEndpoint *e = opaque;
    if (!lc_enter(e)) return -1;
    ssize_t n = lc_read_vectors(e, v, count, total, 1);
    lc_leave(e); return n;
}
static ssize_t lc_read(void *opaque, void *p, size_t bytes) {
    struct iovec v = {p, bytes};
    size_t total;
    if (!lc_vectors(&v, 1, &total)) return -1;
    if (!total) return 0;
    struct LCMuxEndpoint *e = opaque;
    if (!lc_enter(e)) return -1;
    ssize_t n = lc_read_vectors(e, &v, 1, total, 0);
    lc_leave(e); return n;
}
static int lc_shutdown(void *opaque) {
    struct LCMuxEndpoint *e = opaque;
    if (!lc_enter(e)) return -1;
    pthread_mutex_lock(&e->lock);
    e->cancelled = 1;
    unsigned send = e->backend && !e->shutdown_sent;
    if (send) e->shutdown_sent = 1;
    pthread_mutex_unlock(&e->lock);
    int result = send ? lc_backend_shutdown(e) : 0;
    lc_leave(e); return result;
}
static int lc_close(void *opaque) {
    struct LCMuxEndpoint *e = opaque;
    if (!e) { errno = EINVAL; return -1; }
    pthread_mutex_lock(&e->lock);
    if (e->active || e->closing) {
        pthread_mutex_unlock(&e->lock); errno = EBUSY; return -1;
    }
    e->closing = 1;
    pthread_mutex_unlock(&e->lock);
    int result = 0, saved = 0;
    if (e->backend) {
        if (!lc_cancelled(e)) {
            int flushed;
            do { flushed = lc_flush_prefix(e); } while (flushed < 0 && errno == EINTR);
            if (flushed <= 0) { result = -1; saved = flushed < 0 ? errno : EIO; }
        }
        int closed = e->route == LC_GL ? lc_delegate->close(e->backend) : LCCopyEndpointClose(e->backend);
        if (closed && !result) { result = closed; saved = errno; }
    }
    pthread_mutex_destroy(&e->lock);
    free(e);
    atomic_fetch_sub_explicit(&lc_live, 1, memory_order_relaxed);
    if (result) errno = saved;
    return result;
}
static unsigned lc_live_count(void) { return atomic_load_explicit(&lc_live, memory_order_relaxed); }

const struct VIMGLInprocessAPI *VIMPassthroughOpenGLInprocessGetAPI(uint32_t version, uint32_t bytes) {
    static const struct VIMGLInprocessAPI api = {
        VIM_GL_INPROCESS_ABI, sizeof(api), lc_open, lc_read, lc_write,
        lc_readv, lc_writev, lc_shutdown, lc_close, lc_live_count};
    if (version != VIM_GL_INPROCESS_ABI || bytes != sizeof(api)) { errno = EINVAL; return NULL; }
    return lc_ready() ? &api : NULL;
}
const struct VIMGLBackingNotifyAPI *VIMPassthroughOpenGLBackingNotifyGetAPI(uint32_t version, uint32_t bytes) {
    if (!lc_ready() || !lc_delegate_notify) return NULL;
    lc_delegate_depth++;
    lc_delegate_recursed = 0;
    const struct VIMGLBackingNotifyAPI *api = lc_delegate_notify(version, bytes);
    lc_delegate_depth--;
    if (lc_delegate_recursed) { errno = ELOOP; return NULL; }
    if (!api) return NULL;
    if (version != VIM_GL_BACKING_NOTIFY_ABI || bytes != sizeof(*api) ||
        api->version != version || api->bytes != bytes ||
        !lc_function_in_delegate((const void *)api->subscribe) ||
        !lc_function_in_delegate((const void *)api->release_completed)) {
        errno = EINVAL; return NULL;
    }
    return api; /* Exact original API/callbacks; no ownership reinterpretation. */
}
