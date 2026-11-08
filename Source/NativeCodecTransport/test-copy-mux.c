/* Host-only fake-delegate tests: no GL, codecs, native media, or guests. */
#include "copy-wire.h"
#include "copy-worker.h"
#include "../vendor/qemu/include/hw/display/vim-passthrough-opengl-inprocess.h"
#include "../vendor/qemu/include/hw/display/vim-passthrough-opengl-backing-notify.h"
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "%s:%d: %s (errno=%d)\n", __func__, __LINE__, #x, errno); return 1; } } while (0)
struct LCFakeStats {
    unsigned opens, reads, writes, readvs, writevs, shutdowns, closes, live;
    unsigned subscribes, releases, read_entered;
    size_t written;
    uint64_t namespace_id[2], ticket;
};
struct Controls {
    void (*reset)(void);
    int (*plan)(const ssize_t *, size_t);
    int (*read_bytes)(const void *, size_t);
    void (*block)(int);
    int (*wait_read)(unsigned);
    void (*stats)(struct LCFakeStats *);
    size_t (*written)(void *, size_t);
};
static struct Controls control;
static const struct VIMGLInprocessAPI *api;
static VIMGLGetBackingNotifyAPI get_notify;
static unsigned codec_opens, codec_reads, codec_writes, codec_shutdowns, codec_closes, codec_live;
static unsigned char codec_bytes[65536];
static size_t codec_size;
struct LCCopyEndpoint { int stopped; };

/* Stub worker proves routing independently of worker implementation. */
struct LCCopyEndpoint *LCCopyEndpointOpen(void) {
    struct LCCopyEndpoint *p = calloc(1, sizeof(*p));
    if (p) { codec_opens++; codec_live++; } return p;
}
ssize_t LCCopyEndpointWrite(struct LCCopyEndpoint *p, const void *b, size_t n) {
    codec_writes++;
    if (p->stopped) { errno = ECANCELED; return -1; }
    if (n > sizeof(codec_bytes) - codec_size) { errno = ENOSPC; return -1; }
    memcpy(codec_bytes + codec_size, b, n); codec_size += n; return (ssize_t)n;
}
ssize_t LCCopyEndpointRead(struct LCCopyEndpoint *p, void *b, size_t n) {
    (void)b; (void)n; codec_reads++;
    if (p->stopped) { errno = ECANCELED; return -1; } return 0;
}
int LCCopyEndpointShutdown(struct LCCopyEndpoint *p) { codec_shutdowns++; p->stopped = 1; return 0; }
int LCCopyEndpointClose(struct LCCopyEndpoint *p) { codec_closes++; codec_live--; free(p); return 0; }
unsigned LCCopyEndpointLiveCount(void) { return codec_live; }

static int write_all(void *s, const void *p, size_t n) {
    size_t done = 0;
    for (unsigned calls = 0; done < n && calls < 100; calls++) {
        ssize_t k = api->write(s, (const char *)p + done, n - done);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0 || (size_t)k > n - done) return -1;
        done += (size_t)k;
    }
    return done == n ? 0 : -1;
}
static int writev_all(void *s, const struct iovec *v, int count) {
    struct iovec left[8];
    if (count < 0 || count > 8) return -1;
    memcpy(left, v, (size_t)count * sizeof(*v));
    int first = 0;
    for (unsigned calls = 0; first < count && calls < 100; calls++) {
        while (first < count && !left[first].iov_len) first++;
        if (first == count) break;
        ssize_t k = api->writev(s, left + first, count - first);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return -1;
        size_t used = (size_t)k;
        for (; first < count && used >= left[first].iov_len; first++) used -= left[first].iov_len;
        if (first == count) { if (used) return -1; break; }
        left[first].iov_base = (char *)left[first].iov_base + used;
        left[first].iov_len -= used;
    }
    return first == count ? 0 : -1;
}
static void gl_bytes(unsigned char out[64]) {
    for (size_t i = 0; i < 64; i++) out[i] = (unsigned char)(i * 17 + 3);
    uint64_t magic = LC_COPY_MAGIC; memcpy(out, &magic, sizeof(magic));
    out[7] ^= 0x40; /* Shares seven exact magic bytes; last byte selects GL. */
}
static int expect_bytes(const void *p, size_t n) {
    unsigned char got[65536];
    struct LCFakeStats st; control.stats(&st);
    CHECK(st.written == n);
    CHECK(control.written(got, sizeof(got)) == n);
    CHECK(!memcmp(got, p, n)); return 0;
}
static int test_prefix(void) {
    unsigned char data[64]; gl_bytes(data);
    for (size_t split = 1; split < 8; split++) {
        control.reset();
        void *s = api->open(); CHECK(s);
        CHECK(write_all(s, data, split) == 0);
        struct LCFakeStats st; control.stats(&st); CHECK(st.opens == 0);
        struct iovec v[] = {{data + split, 8 - split}, {NULL, 0}, {data + 8, sizeof(data) - 8}};
        CHECK(writev_all(s, v, 3) == 0);
        CHECK(api->close(s) == 0);
        CHECK(expect_bytes(data, sizeof(data)) == 0);
        control.stats(&st); CHECK(st.opens == 1 && st.closes == 1 && st.live == 0);
        CHECK(codec_opens == 0);
    }
    return 0;
}
static int test_short(void) {
    unsigned char data[64]; gl_bytes(data);
    ssize_t plan[] = {3, -EINTR, 2, 1, 4, -EINTR, 7, 1};
    CHECK(control.plan(plan, sizeof(plan) / sizeof(plan[0])) == 0);
    void *s = api->open(); CHECK(s);
    CHECK(write_all(s, data, 5) == 0);
    struct iovec v[] = {{data + 5, 1}, {data + 6, 11}, {data + 17, sizeof(data) - 17}};
    CHECK(writev_all(s, v, 3) == 0);
    CHECK(api->close(s) == 0);
    CHECK(expect_bytes(data, sizeof(data)) == 0);
    CHECK(codec_opens == 0); return 0;
}
static int test_error(void) {
    unsigned char data[64]; gl_bytes(data);
    void *s = api->open(); CHECK(s);
    CHECK(write_all(s, data, 8) == 0);
    ssize_t plan[] = {5, -EIO}; CHECK(control.plan(plan, 2) == 0);
    ssize_t n = api->write(s, data + 8, sizeof(data) - 8);
    CHECK(n == 5);
    n = api->write(s, data + 13, sizeof(data) - 13);
    CHECK(n == -1 && errno == EIO);
    CHECK(api->close(s) == 0);
    CHECK(expect_bytes(data, 13) == 0); return 0;
}
static int test_prefix_close(void) {
    unsigned char data[64]; gl_bytes(data);
    void *s = api->open(); CHECK(s);
    /* A truncated exact codec prelude must not open an ordinary GL stream. */
    CHECK(write_all(s, data, 7) == 0);
    char byte; CHECK(api->read(s, &byte, 1) == -1 && errno == EAGAIN);
    CHECK(api->close(s) == 0);
    struct LCFakeStats st; control.stats(&st); CHECK(st.opens == 0 && st.written == 0);
    CHECK(codec_opens == 0);
    /* Once classified GL, close preserves every prefix byte already accepted. */
    ssize_t plan[] = {2, -EIO}; CHECK(control.plan(plan, 2) == 0);
    s = api->open(); CHECK(s);
    CHECK(api->write(s, data, 8) == 8);
    CHECK(api->close(s) == 0);
    CHECK(expect_bytes(data, 8) == 0); return 0;
}
static int test_read_first(void) {
    const char reply[] = "read-before-write"; char b[64] = {0};
    CHECK(control.read_bytes(reply, sizeof(reply)) == 0);
    void *s = api->open(); CHECK(s);
    CHECK(api->read(s, b, sizeof(b)) == sizeof(reply)); CHECK(!memcmp(b, reply, sizeof(reply)));
    uint64_t magic = LC_COPY_MAGIC;
    CHECK(write_all(s, &magic, sizeof(magic)) == 0);
    CHECK(api->close(s) == 0);
    CHECK(expect_bytes(&magic, sizeof(magic)) == 0); CHECK(codec_opens == 0); return 0;
}
static int test_codec(void) {
    struct LCCopyHeader h = {.magic = LC_COPY_MAGIC, .version = LC_COPY_VERSION,
                            .type = LC_COPY_HELLO, .session = {12, 34}, .flags = LC_COPY_TX};
    void *s = api->open(); CHECK(s);
    CHECK(write_all(s, &h, 3) == 0);
    struct iovec v[] = {{(char *)&h + 3, 4}, {(char *)&h + 7, 1}, {(char *)&h + 8, sizeof(h) - 8}};
    CHECK(writev_all(s, v, 3) == 0);
    CHECK(codec_opens == 1 && codec_size == sizeof(h) && !memcmp(codec_bytes, &h, sizeof(h)));
    char byte; CHECK(api->read(s, &byte, 1) == 0);
    CHECK(api->shutdown(s) == 0); CHECK(api->close(s) == 0);
    CHECK(codec_reads == 1 && codec_shutdowns == 1 && codec_closes == 1 && codec_live == 0);
    struct LCFakeStats st; control.stats(&st);
    CHECK(st.opens == 0 && st.reads == 0 && st.writes == 0 && st.closes == 0); return 0;
}
static void notified(void *p, int status) { int *n = p; if (status == 0) (*n)++; }
static int test_notify(int absent) {
    CHECK(get_notify);
    CHECK(!get_notify(1, sizeof(struct VIMGLBackingNotifyAPI)));
    CHECK(!get_notify(VIM_GL_BACKING_NOTIFY_ABI, sizeof(struct VIMGLBackingNotifyAPI) - 1));
    const struct VIMGLBackingNotifyAPI *notify = get_notify(VIM_GL_BACKING_NOTIFY_ABI, sizeof(*notify));
    if (absent) {
        CHECK(!notify);
        void *s = api->open(); CHECK(s);
        unsigned char data[64]; gl_bytes(data); CHECK(write_all(s, data, sizeof(data)) == 0);
        CHECK(api->close(s) == 0); return expect_bytes(data, sizeof(data));
    }
    CHECK(notify && notify->version == VIM_GL_BACKING_NOTIFY_ABI && notify->bytes == sizeof(*notify));
    uint64_t ns[2] = {UINT64_C(0x1122334455667788), UINT64_C(0x8877665544332211)};
    int calls = 0; CHECK(notify->subscribe(ns, 77, notified, &calls) == 0); CHECK(calls == 1);
    CHECK(notify->release_completed(ns, 78) == EBUSY);
    struct LCFakeStats st; control.stats(&st);
    CHECK(st.subscribes == 1 && st.releases == 1 && st.ticket == 78 && !memcmp(st.namespace_id, ns, sizeof(ns)));
    return 0;
}
struct ReadCall { void *stream; ssize_t result; int error; };
static void *blocked_reader(void *p) {
    struct ReadCall *call = p; char b;
    call->result = api->read(call->stream, &b, 1); call->error = errno; return NULL;
}
static int test_shutdown(void) {
    control.block(1);
    void *s = api->open(); CHECK(s);
    struct ReadCall call = {.stream = s}; pthread_t thread;
    CHECK(!pthread_create(&thread, NULL, blocked_reader, &call));
    CHECK(control.wait_read(1000));
    CHECK(api->close(s) == -1 && errno == EBUSY);
    CHECK(api->shutdown(s) == 0);
    CHECK(!pthread_join(thread, NULL)); /* Whole child has a bounded alarm. */
    CHECK(call.result == -1 && call.error == ECANCELED);
    CHECK(api->shutdown(s) == 0); /* Idempotent cancellation forwards only once. */
    CHECK(api->close(s) == 0);
    struct LCFakeStats st; control.stats(&st);
    CHECK(st.shutdowns == 1 && st.closes == 1 && st.live == 0); return 0;
}
static int load_controls(const char *path) {
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL); CHECK(h);
#define CONTROL(field, name) do { *(void **)(&control.field) = dlsym(h, name); CHECK(control.field); } while (0)
    CONTROL(reset, "LCFakeReset"); CONTROL(plan, "LCFakeSetWritePlan");
    CONTROL(read_bytes, "LCFakeSetReadBytes"); CONTROL(block, "LCFakeSetBlockRead");
    CONTROL(wait_read, "LCFakeWaitReadEntered"); CONTROL(stats, "LCFakeGetStats");
    CONTROL(written, "LCFakeCopyWritten");
#undef CONTROL
    control.reset(); return 0;
}
static int run_case(const char *name, const char *mux, const char *delegate) {
    alarm(4);
    CHECK(!setenv("LC_COPY_GL_DELEGATE", delegate, 1));
    if (strcmp(name, "invalid") && load_controls(delegate)) return 1;
    void *h = dlopen(mux, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "mux dlopen: %s\n", dlerror()); return 1; }
    VIMGLGetInprocessAPI get = (VIMGLGetInprocessAPI)dlsym(h, "VIMPassthroughOpenGLInprocessGetAPI"); CHECK(get);
    CHECK(!get(1, sizeof(struct VIMGLInprocessAPI)));
    CHECK(!get(VIM_GL_INPROCESS_ABI, sizeof(struct VIMGLInprocessAPI) - 1));
    api = get(VIM_GL_INPROCESS_ABI, sizeof(struct VIMGLInprocessAPI));
    if (!strcmp(name, "invalid")) {
        /* Returning a codec-capable API is allowed; selecting GL must fail closed. */
        if (!api) return 0;
        void *s = api->open(); if (!s) return 0;
        unsigned char data[64]; gl_bytes(data);
        ssize_t n = api->write(s, data, sizeof(data));
        CHECK(n < 0 || (size_t)n < sizeof(data));
        api->shutdown(s); api->close(s); return 0;
    }
    CHECK(api && api->version == VIM_GL_INPROCESS_ABI && api->bytes == sizeof(*api));
    get_notify = (VIMGLGetBackingNotifyAPI)dlsym(h, "VIMPassthroughOpenGLBackingNotifyGetAPI");
    if (!strcmp(name, "prefix")) return test_prefix();
    if (!strcmp(name, "short")) return test_short();
    if (!strcmp(name, "error")) return test_error();
    if (!strcmp(name, "prefix-close")) return test_prefix_close();
    if (!strcmp(name, "read-first")) return test_read_first();
    if (!strcmp(name, "codec")) return test_codec();
    if (!strcmp(name, "notify")) return test_notify(0);
    if (!strcmp(name, "no-notify")) return test_notify(1);
    if (!strcmp(name, "shutdown")) return test_shutdown();
    return 1;
}
static double monotonic(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9;
}
static int isolated(const char *name, const char *mux, const char *delegate) {
    pid_t child = fork(); CHECK(child >= 0);
    if (!child) _exit(run_case(name, mux, delegate));
    int status = 0; double until = monotonic() + 6;
    for (;;) {
        pid_t got = waitpid(child, &status, WNOHANG);
        if (got == child) break;
        if (got < 0 && errno != EINTR) return 1;
        if (monotonic() >= until) {
            kill(child, SIGKILL);
            double reap_until = monotonic() + 1;
            while (waitpid(child, &status, WNOHANG) != child && monotonic() < reap_until) usleep(1000);
            fprintf(stderr, "TIMEOUT %s\n", name); return 1;
        }
        usleep(1000);
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status)) {
        fprintf(stderr, "FAIL %s delegate=%s status=%d\n", name, delegate, status); return 1;
    }
    printf("PASS %s\n", name); return 0;
}
int main(int argc, char **argv) {
    if (argc != 3 || argv[1][0] != '/' || argv[2][0] != '/') {
        fprintf(stderr, "usage: test-copy-mux /absolute/mux.dylib /absolute/build-dir\n"); return 2;
    }
    char path[4096]; int failures = 0;
    const char *cases[] = {"prefix", "short", "error", "prefix-close", "read-first", "codec", "notify", "shutdown"};
    snprintf(path, sizeof(path), "%s/fake.dylib", argv[2]);
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) failures += isolated(cases[i], argv[1], path);
    snprintf(path, sizeof(path), "%s/no-notify.dylib", argv[2]); failures += isolated("no-notify", argv[1], path);
    const char *bad[] = {"missing-getter", "bad-abi", "null-callback", "recursive", "missing-file"};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        snprintf(path, sizeof(path), "%s/%s.dylib", argv[2], bad[i]); failures += isolated("invalid", argv[1], path);
    }
    failures += isolated("invalid", argv[1], argv[1]);
    snprintf(path, sizeof(path), "%s/same-inode.dylib", argv[2]); failures += isolated("invalid", argv[1], path);
    printf("mux fake-delegate suite: %s (%d failures)\n", failures ? "FAIL" : "PASS", failures);
    return failures ? 1 : 0;
}
