// Tests the seamless wire format: round trips, every truncation, lying lengths and random bytes.
#include "seamless-wire.h"
#include "seamless-slots.h"
#include "seamless-input-queue.h"
#include <assert.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <unistd.h>

// Every prefix of a valid message must ask for more, and never claim success.
static void every_prefix_needs_more(const uint8_t *data, size_t size) {
    struct SWMMessage m;
    size_t used;
    for (size_t n = 0; n < size; n++)
        assert(swm_parse(data, n, &m, &used) == SWM_NEED_MORE);
    assert(swm_parse(data, size, &m, &used) == SWM_OK && used == size);
}

static void round_trips(void) {
    uint8_t out[4096];
    struct SWMMessage m;
    size_t used, n;

    n = swm_put_u32_message(out, sizeof(out), SWM_HELLO, SWM_VERSION);
    every_prefix_needs_more(out, n);
    swm_parse(out, n, &m, &used);
    assert(m.type == SWM_HELLO && m.u.version == SWM_VERSION);

    struct SWMWindow w = {7, 99, -3, -20, 30, 640, 480, 1280, 960, 5, 8, "Title", "TextEdit"};
    n = swm_put_window(out, sizeof(out), &w);
    every_prefix_needs_more(out, n);
    swm_parse(out, n, &m, &used);
    assert(m.type == SWM_WINDOW && m.u.window.window == 7 && m.u.window.pid == 99 && m.u.window.layer == -3);
    assert(m.u.window.x == -20 && m.u.window.y == 30 && m.u.window.width == 640 && m.u.window.pixel_height == 960);
    assert(!memcmp(m.u.window.title, "Title", 5) && !memcmp(m.u.window.owner, "TextEdit", 8));
    assert(swm_put_window(out, n - 1, &w) == 0);

    struct SWMFrame f = {7, 3, 16, 8, 2, 4, 3, 2, NULL};
    swm_put_frame_prefix(out, &f);
    for (size_t i = 0; i < 3 * 2 * 4; i++)
        out[SWM_FRAME_PREFIX + i] = (uint8_t)i;
    n = SWM_FRAME_PREFIX + 3 * 2 * 4;
    every_prefix_needs_more(out, n);
    swm_parse(out, n, &m, &used);
    assert(m.type == SWM_FRAME && m.u.frame.sequence == 3 && m.u.frame.x == 2 && m.u.frame.height == 2);
    assert(m.u.frame.pixels == out + SWM_FRAME_PREFIX && m.u.frame.pixels[23] == 23);

    struct SWMPointer e = {7, SWM_DOWN, 1, 2, -160, 320, 0x100000};
    n = swm_put_pointer(out, sizeof(out), &e);
    every_prefix_needs_more(out, n);
    swm_parse(out, n, &m, &used);
    assert(m.type == SWM_POINTER && m.u.pointer.kind == SWM_DOWN && m.u.pointer.clicks == 2);
    assert(m.u.pointer.x == -160 && m.u.pointer.y == 320 && m.u.pointer.flags == 0x100000);

    struct SWMKey k = {49, 1, 0x20000};
    n = swm_put_key(out, sizeof(out), &k);
    every_prefix_needs_more(out, n);
    swm_parse(out, n, &m, &used);
    assert(m.type == SWM_KEY && m.u.key.keycode == 49 && m.u.key.down && m.u.key.flags == 0x20000);
}

static size_t put_gesture(uint8_t *out, uint8_t kind, uint8_t phase, uint8_t momentum, float a) {
    struct SWMGesture g = {7, kind, phase, momentum, 0, 16, 32, a, a, 0, SWG_PRECISE, 0};
    return swm_put_gesture(out, 64, &g);
}

static void input_round_trips(void) {
    uint8_t out[4096];
    struct SWMMessage m;
    size_t used, n;

    struct SWMGesture g = {7, SWG_SCROLL, SWP_CHANGED, 0, 2, -16, 32, 1.5f, -2.5f, 0.25f, SWG_PRECISE, 0x100000};
    n = swm_put_gesture(out, sizeof(out), &g);
    every_prefix_needs_more(out, n);
    swm_parse(out, n, &m, &used);
    assert(m.type == SWM_GESTURE && m.u.gesture.kind == SWG_SCROLL && m.u.gesture.phase == SWP_CHANGED);
    assert(m.u.gesture.x == -16 && m.u.gesture.a == 1.5f && m.u.gesture.b == -2.5f && m.u.gesture.c == 0.25f);
    assert(m.u.gesture.stage == 2 && m.u.gesture.flags == SWG_PRECISE && m.u.gesture.modifiers == 0x100000);
    assert(swm_put_gesture(out, n - 1, &g) == 0);

    n = swm_put_u32_message(out, sizeof(out), SWM_MODIFIERS, 0x20102);
    every_prefix_needs_more(out, n);
    swm_parse(out, n, &m, &used);
    assert(m.type == SWM_MODIFIERS && m.u.modifiers == 0x20102);

    struct SWMText t = {7, SWT_INSERT, 6, "\xE6\x97\xA5\xE6\x9C\xAC"};
    n = swm_put_text(out, sizeof(out), &t);
    every_prefix_needs_more(out, n);
    swm_parse(out, n, &m, &used);
    assert(m.type == SWM_TEXT && m.u.text.kind == SWT_INSERT && m.u.text.length == 6);
    assert(!memcmp(m.u.text.bytes, t.bytes, 6));
    assert(swm_put_text(out, n - 1, &t) == 0);

    n = put_gesture(out, SWG_KIND_COUNT, 0, 0, 0);
    assert(swm_parse(out, n, &m, &used) == SWM_BAD);
    n = put_gesture(out, SWG_SCROLL, 3, 0, 0); // No such phase.
    assert(swm_parse(out, n, &m, &used) == SWM_BAD);
    n = put_gesture(out, SWG_SCROLL, 0, 4, 0);
    assert(swm_parse(out, n, &m, &used) == SWM_BAD);
    n = put_gesture(out, SWG_SCROLL, 0, 0, NAN);
    assert(swm_parse(out, n, &m, &used) == SWM_BAD);
    n = put_gesture(out, SWG_SCROLL, 0, 0, INFINITY);
    assert(swm_parse(out, n, &m, &used) == SWM_BAD);
    n = swm_put_text(out, sizeof(out), &t);
    swm_w16(out + SWM_HEADER_SIZE + 4, 9); // No such kind.
    assert(swm_parse(out, n, &m, &used) == SWM_BAD);
    n = swm_put_text(out, sizeof(out), &t);
    swm_w16(out + SWM_HEADER_SIZE + 6, 5); // The inner length must match the outer.
    assert(swm_parse(out, n, &m, &used) == SWM_BAD);
    swm_header(out, SWM_TEXT, SWM_TEXT_FIXED + SWM_MAX_TEXT + 1);
    assert(swm_parse(out, SWM_HEADER_SIZE, &m, &used) == SWM_BAD);
}

static struct SWMMessage queued_at(struct SWQueue *q, size_t index) {
    struct SWMMessage m;
    size_t used = 0, offset = q->start;
    for (size_t i = 0; i <= index; i++, offset += used)
        assert(swm_parse(q->bytes + offset, q->end - offset, &m, &used) == SWM_OK);
    return m;
}
static size_t queued_count(struct SWQueue *q) {
    struct SWMMessage m;
    size_t used, count = 0;
    for (size_t offset = q->start; offset < q->end; offset += used, count++)
        assert(swm_parse(q->bytes + offset, q->end - offset, &m, &used) == SWM_OK);
    return count;
}
static void push_gesture(struct SWQueue *q, uint8_t phase, uint8_t momentum, float a) {
    uint8_t out[64];
    assert(swq_push(q, out, put_gesture(out, SWG_SCROLL, phase, momentum, a)));
}

static void queue(void) {
    static struct SWQueue q;
    uint8_t out[64];

    // Deltas add up while the guest is behind, and a phase change never merges.
    push_gesture(&q, SWP_BEGAN, 0, 1);
    push_gesture(&q, SWP_CHANGED, 0, 2);
    push_gesture(&q, SWP_CHANGED, 0, 3);
    assert(queued_count(&q) == 2);
    assert(queued_at(&q, 0).u.gesture.a == 1 && queued_at(&q, 1).u.gesture.a == 5);
    push_gesture(&q, SWP_ENDED, 0, 0);
    push_gesture(&q, SWP_NONE, SWM_MOMENTUM_BEGAN, 9);
    push_gesture(&q, SWP_NONE, SWM_MOMENTUM_CHANGED, 4);
    push_gesture(&q, SWP_NONE, SWM_MOMENTUM_CHANGED, 4);
    push_gesture(&q, SWP_NONE, SWM_MOMENTUM_ENDED, 0);
    assert(queued_count(&q) == 6 && queued_at(&q, 4).u.gesture.a == 8);

    // Pointer motion replaces, and a click stays where it was.
    memset(&q, 0, sizeof(q));
    struct SWMPointer e = {7, SWM_MOVE, 0, 0, 16, 16, 0};
    assert(swq_push(&q, out, swm_put_pointer(out, sizeof(out), &e)));
    e.x = 32;
    assert(swq_push(&q, out, swm_put_pointer(out, sizeof(out), &e)));
    assert(queued_count(&q) == 1 && queued_at(&q, 0).u.pointer.x == 32);
    e.kind = SWM_DOWN;
    e.clicks = 1;
    assert(swq_push(&q, out, swm_put_pointer(out, sizeof(out), &e)));
    e.kind = SWM_MOVE;
    e.clicks = 0;
    e.x = 48;
    assert(swq_push(&q, out, swm_put_pointer(out, sizeof(out), &e)));
    assert(queued_count(&q) == 3 && queued_at(&q, 2).u.pointer.x == 48 && queued_at(&q, 0).u.pointer.x == 32);

    // Against a socket that fills: nothing is lost, the stream stays parseable, and every delta arrives, whether it
    // merged into an unsent message or followed a partly sent one.
    memset(&q, 0, sizeof(q));
    int pair[2];
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, pair));
    assert(!fcntl(pair[0], F_SETFL, O_NONBLOCK));
    size_t pushed = 0, n = put_gesture(out, SWG_MAGNIFY, SWP_CHANGED, 0, 1);
    int result = 1;
    while (result) {
        assert(swq_push(&q, out, n));
        pushed++;
        result = swq_flush(&q, pair[0]);
    }
    for (int i = 0; i < 100; i++, pushed++)
        assert(swq_push(&q, out, n));
    size_t capacity = 1 << 22, drained = 0;
    uint8_t *drain = malloc(capacity);
    struct timeval quick = {0, 20000};
    setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &quick, sizeof(quick));
    for (;;) {
        assert(swq_flush(&q, pair[0]) >= 0);
        ssize_t got = recv(pair[1], drain + drained, capacity - drained, 0);
        if (got <= 0 && q.start == q.end)
            break;
        if (got > 0)
            drained += (size_t)got;
    }
    float total = 0;
    struct SWMMessage m;
    size_t used;
    for (size_t offset = 0; offset < drained; offset += used) {
        assert(swm_parse(drain + offset, drained - offset, &m, &used) == SWM_OK && m.type == SWM_GESTURE);
        total += m.u.gesture.a;
    }
    assert(total == (float)pushed);
    free(drain);
    close(pair[0]);
    close(pair[1]);
}

static void assert_bad_frame(uint32_t full_w, uint32_t full_h, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                             uint32_t length) {
    uint8_t out[SWM_FRAME_PREFIX];
    struct SWMFrame f = {1, 1, full_w, full_h, x, y, w, h, NULL};
    swm_put_frame_prefix(out, &f);
    swm_w32(out + 8, length);
    struct SWMMessage m;
    size_t used;
    // Judged from the fixed part alone, with no pixels present: a liar can't make the receiver wait or allocate.
    assert(swm_parse(out, sizeof(out), &m, &used) == SWM_BAD);
}

static void rejects_lies(void) {
    uint8_t out[256];
    struct SWMMessage m;
    size_t used;

    swm_w32(out, 0x12345678);
    assert(swm_parse(out, 4, &m, &used) == SWM_BAD);

    swm_header(out, 99, 4);
    assert(swm_parse(out, SWM_HEADER_SIZE, &m, &used) == SWM_BAD);

    swm_header(out, SWM_KEY, 7);
    assert(swm_parse(out, SWM_HEADER_SIZE, &m, &used) == SWM_BAD);
    swm_header(out, SWM_KEY, 9); // Fixed-size messages must be exact.
    assert(swm_parse(out, SWM_HEADER_SIZE, &m, &used) == SWM_BAD);

    swm_header(out, SWM_HELLO, 4);
    swm_w16(out + 6, 1); // Reserved must stay zero.
    assert(swm_parse(out, SWM_HEADER_SIZE, &m, &used) == SWM_BAD);

    swm_header(out, SWM_WINDOW, SWM_WINDOW_FIXED + 2 * SWM_MAX_TEXT + 1);
    assert(swm_parse(out, SWM_HEADER_SIZE, &m, &used) == SWM_BAD);

    // Text lengths that disagree with the payload length.
    struct SWMWindow w = {1, 1, 0, 0, 0, 10, 10, 10, 10, 0, 0, "", ""};
    size_t n = swm_put_window(out, sizeof(out), &w);
    swm_w16(out + SWM_HEADER_SIZE + 36, 1);
    assert(swm_parse(out, n, &m, &used) == SWM_BAD);
    // Empty and oversized geometry.
    n = swm_put_window(out, sizeof(out), &w);
    swm_w32(out + SWM_HEADER_SIZE + 20, 0);
    assert(swm_parse(out, n, &m, &used) == SWM_BAD);
    n = swm_put_window(out, sizeof(out), &w);
    swm_w32(out + SWM_HEADER_SIZE + 28, SWM_MAX_DIMENSION + 1);
    assert(swm_parse(out, n, &m, &used) == SWM_BAD);

    struct SWMPointer e = {1, SWM_DRAG + 1, 0, 0, 0, 0, 0};
    n = swm_put_pointer(out, sizeof(out), &e);
    assert(swm_parse(out, n, &m, &used) == SWM_BAD);
    e.kind = SWM_UP;
    e.button = 3;
    n = swm_put_pointer(out, sizeof(out), &e);
    assert(swm_parse(out, n, &m, &used) == SWM_BAD);

    uint32_t good = SWM_FRAME_FIXED + 4 * 4 * 4;
    assert_bad_frame(0, 8, 0, 0, 4, 4, good); // Empty window.
    assert_bad_frame(8193, 8, 0, 0, 4, 4, good); // Too big.
    assert_bad_frame(8, 8, 6, 0, 4, 4, good); // Past the right edge.
    assert_bad_frame(8, 8, 0, 6, 4, 4, good); // Past the bottom edge.
    assert_bad_frame(8, 8, 0, 0, 0, 4, SWM_FRAME_FIXED); // Empty band.
    assert_bad_frame(8, 8, 0, 0, 4, 4, good - 1); // Short payload.
    assert_bad_frame(8, 8, 0, 0, 4, 4, good + 1); // Long payload.
    assert_bad_frame(8, 8, 9, 0, 1, 1, SWM_FRAME_FIXED + 4); // x beyond the width, where subtraction would wrap.
    assert_bad_frame(8192, 8192, 0, 0, 8192, 8192, 0xffffffffu); // The largest band, with a lying length.
    assert_bad_frame(8192, 8192, 0xffffffffu, 0, 2, 1, SWM_FRAME_FIXED + 8);
}

// Random bytes, plus mutations of valid messages: no crash, no read past `avail` (run under ASan), and any success
// reports a size that fits.
static void fuzz(void) {
    srand(1);
    uint8_t valid[256], data[256];
    struct SWMWindow w = {1, 2, 0, 0, 0, 10, 10, 20, 20, 3, 3, "abc", "def"};
    size_t valid_size = swm_put_window(valid, sizeof(valid), &w);
    for (int round = 0; round < 2000000; round++) {
        size_t n = (size_t)rand() % sizeof(data);
        if (round & 1) {
            for (size_t i = 0; i < n; i++)
                data[i] = (uint8_t)rand();
            if (n >= 4 && round % 4 == 1)
                swm_w32(data, SWM_MAGIC);
            if (n >= 12 && round % 8 == 1)
                swm_w32(data + 8, (uint32_t)rand() % 128);
        } else {
            memcpy(data, valid, valid_size);
            data[(size_t)rand() % valid_size] = (uint8_t)rand();
            n = valid_size;
        }
        uint8_t *copy = malloc(n ? n : 1); // An exact allocation, so ASan sees any overread.
        memcpy(copy, data, n);
        struct SWMMessage m;
        size_t used = 0;
        enum SWMParse result = swm_parse(copy, n, &m, &used);
        if (result == SWM_OK)
            assert(used <= n && used >= SWM_HEADER_SIZE);
        free(copy);
    }
}

static void slots(void) {
    struct SWMSlotLayout l = {8192, 4608, 1600, 1200, 64};
    int x, y;
    assert(swm_slot_origin(&l, 0, &x, &y) && x == 64 && y == 64);
    assert(swm_slot_origin(&l, 1, &x, &y) && x == 64 + 1664 && y == 64);
    assert(swm_slot_origin(&l, 4, &x, &y) && x == 64 && y == 64 + 1264); // Four fit across, so this wraps.
    assert(swm_slot_origin(&l, 11, &x, &y));
    assert(!swm_slot_origin(&l, 12, &x, &y)); // Three rows fit.
    assert(!swm_slot_origin(&l, -1, &x, &y));
    // Every slot of every layout is on the display, clear of the margins, and apart from every other.
    for (int w = 800; w <= 2000; w += 300) {
        struct SWMSlotLayout m = {4000, 3000, w, 700, 64};
        int count = 0, ox, oy, px[64], py[64];
        while (count < 64 && swm_slot_origin(&m, count, &ox, &oy)) {
            assert(ox + w <= 4000 - SWM_SLOT_MARGIN_SIDE && oy + 700 <= 3000 - SWM_SLOT_MARGIN_BOTTOM);
            for (int i = 0; i < count; i++)
                assert(ox >= px[i] + w + 64 || px[i] >= ox + w + 64 || oy >= py[i] + 700 + 64 ||
                       py[i] >= oy + 700 + 64);
            px[count] = ox;
            py[count++] = oy;
        }
        assert(count > 0);
    }
    struct SWMSlotLayout small = {1000, 700, 1600, 1200, 64}; // A window too big for the display gets no slot.
    assert(!swm_slot_origin(&small, 0, &x, &y));
}

int main(void) {
    slots();
    round_trips();
    input_round_trips();
    queue();
    rejects_lies();
    fuzz();
    puts("seamless wire: ok");
    return 0;
}
