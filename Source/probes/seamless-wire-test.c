// Tests the seamless wire format: round trips, every truncation, lying lengths and random bytes.
#include "seamless-wire.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

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

int main(void) {
    round_trips();
    rejects_lies();
    fuzz();
    puts("seamless wire: ok");
    return 0;
}
