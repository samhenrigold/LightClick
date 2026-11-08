/* Fixed-work guest process/memory probe. Build x86_64, min macOS10.9.
 * Never execute the guest binary on the host. Only /usr/bin/true is executed;
 * no workload files, user data, graphics, or media APIs are used.
 *
 * No arguments: exec256, mmap4096, pages64. Or exactly:
 * --exec-count N --mmap-cycles N --pages N
 * Bounds: exec1..2048, cycles1..65536, pages1..64. Four JSON lines on success:
 * exec/N1, exec/N2, mmap/N1, mmap/N2. Each mapping cycle is one operation.
 * Checksums are FNV-1a64 over little-endian uint64 tokens, combining worker
 * hashes in worker-index order. They never depend on PIDs, addresses or timing.
 */
#include <errno.h>
#include <inttypes.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#if !defined(__x86_64__)
#error "This source is a guest x86_64 probe; do not build a native host executable"
#endif

#define HASH_START UINT64_C(14695981039346656037)
struct Gate { pthread_mutex_t lock; pthread_cond_t changed; unsigned ready; int go, abort; };
struct Worker {
    struct Gate *gate;
    unsigned index, count, pages;
    size_t page_bytes;
    int memory, error, child_status;
    const char *stage;
    uint64_t completed, checksum;
};
static mach_timebase_info_data_t timebase;

static void pthread_check(int error, const char *operation)
{
    if (error) { fprintf(stderr, "%s: %s\n", operation, strerror(error)); _exit(125); }
}
static void watchdog(int signal_number) { (void)signal_number; _exit(124); }
static uint64_t hash_word(uint64_t hash, uint64_t value)
{
    for (unsigned i = 0; i < 8; ++i) { hash = (hash ^ (value & 255)) * UINT64_C(1099511628211); value >>= 8; }
    return hash;
}
static uint64_t token(unsigned worker, unsigned iteration, unsigned page)
{
    return UINT64_C(0x94d049bb133111eb) * (worker + UINT64_C(1)) ^
           UINT64_C(0x9e3779b97f4a7c15) * (iteration + UINT64_C(1)) ^
           UINT64_C(0xd1b54a32d192ed03) * (page + UINT64_C(1));
}
static uint64_t expected_worker(const struct Worker *w)
{
    uint64_t hash = HASH_START;
    for (unsigned i = 0; i < w->count; ++i) {
        if (!w->memory) hash = hash_word(hash, token(w->index, i, 0));
        else for (unsigned p = 0; p < w->pages; ++p) {
            uint64_t value = token(w->index, i, p);
            hash = hash_word(hash_word(hash, value), ~value);
        }
    }
    return hash;
}
static void exec_work(struct Worker *w)
{
    for (unsigned i = 0; i < w->count; ++i) {
        pid_t child = fork();
        if (child < 0) { w->error = errno; w->stage = "fork"; return; }
        if (!child) {
            /* Only async-signal-safe operations after fork in this threaded process. */
            char *const arguments[] = {"/usr/bin/true", NULL};
            char *const environment[] = {"PATH=/usr/bin:/bin", "LC_ALL=C", NULL};
            execve(arguments[0], arguments, environment);
            _exit(127);
        }
        int status = 0;
        pid_t waited;
        do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
        if (waited != child) { w->error = errno ? errno : ECHILD; w->stage = "waitpid"; return; }
        if (!WIFEXITED(status) || WEXITSTATUS(status)) {
            w->error = ECHILD; w->child_status = status; w->stage = "child_exit"; return;
        }
        w->checksum = hash_word(w->checksum, token(w->index, i, 0));
        ++w->completed;
    }
}
static void memory_work(struct Worker *w)
{
    size_t bytes = w->page_bytes * w->pages;
    for (unsigned i = 0; i < w->count; ++i) {
        unsigned char *base = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (base == MAP_FAILED) { w->error = errno; w->stage = "mmap"; return; }
        for (unsigned p = 0; p < w->pages; ++p) {
            uint64_t value = token(w->index, i, p);
            *(volatile uint64_t *)(base + p * w->page_bytes) = value;
            *(volatile uint64_t *)(base + (p + 1) * w->page_bytes - sizeof(value)) = ~value;
        }
        int valid = 1;
        for (unsigned p = 0; p < w->pages; ++p) {
            uint64_t first = *(volatile uint64_t *)(base + p * w->page_bytes);
            uint64_t last = *(volatile uint64_t *)(base + (p + 1) * w->page_bytes - sizeof(last));
            uint64_t value = token(w->index, i, p);
            if (first != value || last != ~value) valid = 0;
            w->checksum = hash_word(hash_word(w->checksum, first), last);
        }
        if (munmap(base, bytes)) { w->error = errno; w->stage = "munmap"; return; }
        if (!valid) { w->error = EIO; w->stage = "readback"; return; }
        ++w->completed;
    }
}
static void *worker(void *argument)
{
    struct Worker *w = argument;
    struct Gate *g = w->gate;
    pthread_check(pthread_mutex_lock(&g->lock), "worker gate lock");
    ++g->ready;
    pthread_check(pthread_cond_broadcast(&g->changed), "worker ready");
    while (!g->go) pthread_check(pthread_cond_wait(&g->changed, &g->lock), "worker gate wait");
    int aborted = g->abort;
    pthread_check(pthread_mutex_unlock(&g->lock), "worker gate unlock");
    if (!aborted) { if (w->memory) memory_work(w); else exec_work(w); }
    return NULL;
}
static int run_case(int memory, unsigned n, unsigned count, unsigned pages, size_t page_bytes)
{
    struct Gate gate = {0};
    struct Worker workers[2] = {{0}, {0}};
    pthread_t threads[2];
    unsigned created = 0;
    int create_error = 0;
    uint64_t expected = HASH_START;
    pthread_check(pthread_mutex_init(&gate.lock, NULL), "gate mutex init");
    pthread_check(pthread_cond_init(&gate.changed, NULL), "gate condition init");
    for (unsigned i = 0; i < n; ++i) {
        workers[i] = (struct Worker){.gate=&gate, .index=i, .count=count, .pages=pages,
            .page_bytes=page_bytes, .memory=memory, .checksum=HASH_START, .stage="none"};
        expected = hash_word(expected, expected_worker(&workers[i]));
    }
    for (; created < n; ++created) {
        create_error = pthread_create(&threads[created], NULL, worker, &workers[created]);
        if (create_error) break;
    }
    pthread_check(pthread_mutex_lock(&gate.lock), "parent gate lock");
    if (!create_error) while (gate.ready != n)
        pthread_check(pthread_cond_wait(&gate.changed, &gate.lock), "parent ready wait");
    gate.abort = create_error != 0;
    uint64_t start = mach_absolute_time();
    gate.go = 1;
    pthread_check(pthread_cond_broadcast(&gate.changed), "parent release");
    pthread_check(pthread_mutex_unlock(&gate.lock), "parent gate unlock");
    for (unsigned i = 0; i < created; ++i)
        pthread_check(pthread_join(threads[i], NULL), "worker join");
    uint64_t end = mach_absolute_time();
    pthread_check(pthread_cond_destroy(&gate.changed), "gate condition destroy");
    pthread_check(pthread_mutex_destroy(&gate.lock), "gate mutex destroy");
    uint64_t completed = 0, hash = HASH_START;
    unsigned errors = create_error != 0;
    for (unsigned i = 0; i < n; ++i) {
        completed += workers[i].completed;
        hash = hash_word(hash, workers[i].checksum);
        if (workers[i].error) {
            ++errors;
            fprintf(stderr, "case=%s worker=%u stage=%s errno=%d child_status=%d\n",
                    memory ? "mmap" : "exec", i, workers[i].stage, workers[i].error, workers[i].child_status);
        }
    }
    uint64_t expected_ops = (uint64_t)count * n;
    if (completed != expected_ops || hash != expected || end <= start) ++errors;
    if (create_error) fprintf(stderr, "pthread_create: %s\n", strerror(create_error));
    double elapsed = (double)(end - start) * timebase.numer / timebase.denom / 1e9;
    printf("{\"result\":\"GENERAL_PROCESS_MEMORY_%s\",\"case\":\"%s\",\"workers\":%u,"
           "\"operations_per_worker\":%u,\"expected_ops\":%" PRIu64 ",\"completed_ops\":%" PRIu64 ","
           "\"pages_per_mapping\":%u,\"page_bytes\":%zu,\"elapsed_seconds\":%.9f,"
           "\"checksum\":\"%016" PRIx64 "\",\"expected_checksum\":\"%016" PRIx64 "\",\"errors\":%u}\n",
           errors ? "FAIL" : "PASS", memory ? "mmap" : "exec", n, count, expected_ops, completed,
           memory ? pages : 0, page_bytes, elapsed, hash, expected, errors);
    return errors ? 1 : 0;
}
static int number(const char *s, unsigned maximum, unsigned *out)
{
    if (!*s || *s == '0') return -1;
    unsigned value = 0;
    for (; *s; ++s) {
        if (*s < '0' || *s > '9' || value > (maximum - (unsigned)(*s - '0')) / 10) return -1;
        value = value * 10 + (unsigned)(*s - '0');
    }
    if (!value || value > maximum) return -1;
    *out = value;
    return 0;
}
int main(int argc, char **argv)
{
    unsigned exec_count = 256, cycles = 4096, pages = 64;
    if (argc != 1 && (argc != 7 || strcmp(argv[1], "--exec-count") ||
        strcmp(argv[3], "--mmap-cycles") || strcmp(argv[5], "--pages") ||
        number(argv[2], 2048, &exec_count) || number(argv[4], 65536, &cycles) || number(argv[6], 64, &pages))) {
        fputs("usage: general-process-memory [--exec-count 1..2048 --mmap-cycles 1..65536 --pages 1..64]\n", stderr);
        return 2;
    }
    struct sigaction action = {0}; action.sa_handler = watchdog;
    if (sigemptyset(&action.sa_mask) || sigaction(SIGALRM, &action, NULL)) return 2;
    alarm(60);
    if (mach_timebase_info(&timebase) || !timebase.numer || !timebase.denom) return 2;
    int page = getpagesize();
    if (page < 16 || page > 65536 || page % 8) return 2;
    setbuf(stdout, NULL);
    for (int memory = 0; memory <= 1; ++memory)
        for (unsigned n = 1; n <= 2; ++n)
            if (run_case(memory, n, memory ? cycles : exec_count, pages, (size_t)page)) return 1;
    alarm(0);
    return 0;
}
