// Wire format between the guest window tool and the host window, shared so both sides parse the same bytes. Plain C99
// with explicit little-endian fields: the guest side targets Mac OS X 10.9 on x86_64, the host is arm64.
//
// Every message is a 12-byte header (magic, type, reserved, payload length) and then a payload. The parser never reads
// past `avail`, and rejects a lying length from the header and fixed fields alone, so a receiver holds at most one
// validated message and can't be made to buffer an arbitrary amount. Guest bytes are untrusted on the host.
#ifndef SEAMLESS_WIRE_H
#define SEAMLESS_WIRE_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define SWM_MAGIC 0x314D5753u // "SWM1" on the wire.
#define SWM_VERSION 1u
#define SWM_HEADER_SIZE 12u
#define SWM_MAX_DIMENSION 8192u // The largest frame the display path carries.
#define SWM_MAX_TEXT 1024u

enum SWMType {
    // Guest to host.
    SWM_HELLO = 1,
    SWM_WINDOW = 2,
    SWM_FRAME = 3,
    SWM_GONE = 4,
    // Host to guest.
    SWM_POINTER = 16,
    SWM_KEY = 17,
    SWM_FOCUS = 18,
};
enum SWMPointerKind { SWM_MOVE = 0, SWM_DOWN = 1, SWM_UP = 2, SWM_DRAG = 3 };

#define SWM_HELLO_SIZE 4u
#define SWM_WINDOW_FIXED 40u
#define SWM_FRAME_FIXED 32u
#define SWM_GONE_SIZE 4u
#define SWM_POINTER_SIZE 20u
#define SWM_KEY_SIZE 8u
#define SWM_FOCUS_SIZE 4u

struct SWMWindow {
    uint32_t window, pid;
    int32_t layer;
    int32_t x, y, width, height; // Points, in guest screen coordinates, top-left origin.
    uint32_t pixel_width, pixel_height;
    uint16_t title_length, owner_length;
    const char *title, *owner; // UTF-8, not terminated, inside the receive buffer.
};
// One band of BGRA premultiplied pixels, tightly packed, full_width and full_height being the whole window's size.
struct SWMFrame {
    uint32_t window, sequence, full_width, full_height, x, y, width, height;
    const uint8_t *pixels;
};
// Coordinates are window-relative points times 16, so Retina half-points survive.
struct SWMPointer {
    uint32_t window;
    uint8_t kind, button, clicks;
    int32_t x, y;
    uint32_t flags; // CGEventFlags: the same bits as NSEvent modifier flags.
};
struct SWMKey {
    uint16_t keycode; // Mac virtual keycode; host and guest share the table.
    uint8_t down;
    uint32_t flags;
};
struct SWMMessage {
    uint16_t type;
    union {
        uint32_t version; // SWM_HELLO
        uint32_t window_id; // SWM_GONE, SWM_FOCUS
        struct SWMWindow window;
        struct SWMFrame frame;
        struct SWMPointer pointer;
        struct SWMKey key;
    } u;
};

static inline void swm_w16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}
static inline void swm_w32(uint8_t *p, uint32_t v) {
    swm_w16(p, (uint16_t)v);
    swm_w16(p + 2, (uint16_t)(v >> 16));
}
static inline uint16_t swm_r16(const uint8_t *p) { return (uint16_t)(p[0] | (uint16_t)p[1] << 8); }
static inline uint32_t swm_r32(const uint8_t *p) { return swm_r16(p) | (uint32_t)swm_r16(p + 2) << 16; }

static inline void swm_header(uint8_t *out, uint16_t type, uint32_t length) {
    swm_w32(out, SWM_MAGIC);
    swm_w16(out + 4, type);
    swm_w16(out + 6, 0);
    swm_w32(out + 8, length);
}

// Each encoder returns the bytes written, or 0 if `capacity` is too small. A frame's header is encoded separately
// so the pixels can be sent from where they already are.
static inline size_t swm_put_u32_message(uint8_t *out, size_t capacity, uint16_t type, uint32_t value) {
    if (capacity < SWM_HEADER_SIZE + 4)
        return 0;
    swm_header(out, type, 4);
    swm_w32(out + SWM_HEADER_SIZE, value);
    return SWM_HEADER_SIZE + 4;
}
static inline size_t swm_put_window(uint8_t *out, size_t capacity, const struct SWMWindow *w) {
    size_t length = SWM_WINDOW_FIXED + (size_t)w->title_length + w->owner_length;
    if (w->title_length > SWM_MAX_TEXT || w->owner_length > SWM_MAX_TEXT || capacity < SWM_HEADER_SIZE + length)
        return 0;
    swm_header(out, SWM_WINDOW, (uint32_t)length);
    uint8_t *p = out + SWM_HEADER_SIZE;
    swm_w32(p, w->window);
    swm_w32(p + 4, w->pid);
    swm_w32(p + 8, (uint32_t)w->layer);
    swm_w32(p + 12, (uint32_t)w->x);
    swm_w32(p + 16, (uint32_t)w->y);
    swm_w32(p + 20, (uint32_t)w->width);
    swm_w32(p + 24, (uint32_t)w->height);
    swm_w32(p + 28, w->pixel_width);
    swm_w32(p + 32, w->pixel_height);
    swm_w16(p + 36, w->title_length);
    swm_w16(p + 38, w->owner_length);
    if (w->title_length)
        memcpy(p + SWM_WINDOW_FIXED, w->title, w->title_length);
    if (w->owner_length)
        memcpy(p + SWM_WINDOW_FIXED + w->title_length, w->owner, w->owner_length);
    return SWM_HEADER_SIZE + length;
}
#define SWM_FRAME_PREFIX (SWM_HEADER_SIZE + SWM_FRAME_FIXED)
static inline void swm_put_frame_prefix(uint8_t out[SWM_FRAME_PREFIX], const struct SWMFrame *f) {
    swm_header(out, SWM_FRAME, SWM_FRAME_FIXED + f->width * f->height * 4);
    uint8_t *p = out + SWM_HEADER_SIZE;
    swm_w32(p, f->window);
    swm_w32(p + 4, f->sequence);
    swm_w32(p + 8, f->full_width);
    swm_w32(p + 12, f->full_height);
    swm_w32(p + 16, f->x);
    swm_w32(p + 20, f->y);
    swm_w32(p + 24, f->width);
    swm_w32(p + 28, f->height);
}
static inline size_t swm_put_pointer(uint8_t *out, size_t capacity, const struct SWMPointer *e) {
    if (capacity < SWM_HEADER_SIZE + SWM_POINTER_SIZE)
        return 0;
    swm_header(out, SWM_POINTER, SWM_POINTER_SIZE);
    uint8_t *p = out + SWM_HEADER_SIZE;
    swm_w32(p, e->window);
    p[4] = e->kind;
    p[5] = e->button;
    p[6] = e->clicks;
    p[7] = 0;
    swm_w32(p + 8, (uint32_t)e->x);
    swm_w32(p + 12, (uint32_t)e->y);
    swm_w32(p + 16, e->flags);
    return SWM_HEADER_SIZE + SWM_POINTER_SIZE;
}
static inline size_t swm_put_key(uint8_t *out, size_t capacity, const struct SWMKey *k) {
    if (capacity < SWM_HEADER_SIZE + SWM_KEY_SIZE)
        return 0;
    swm_header(out, SWM_KEY, SWM_KEY_SIZE);
    uint8_t *p = out + SWM_HEADER_SIZE;
    swm_w16(p, k->keycode);
    p[2] = k->down;
    p[3] = 0;
    swm_w32(p + 4, k->flags);
    return SWM_HEADER_SIZE + SWM_KEY_SIZE;
}

enum SWMParse { SWM_NEED_MORE = 0, SWM_OK = 1, SWM_BAD = -1 };

// On SWM_OK, *used is the message's size and `m` points into `data`. On SWM_NEED_MORE, *used is the total size needed
// if it's known yet, otherwise the next size worth waiting for. SWM_BAD means the stream can't continue.
static inline enum SWMParse swm_parse(const uint8_t *data, size_t avail, struct SWMMessage *m, size_t *used) {
    *used = SWM_HEADER_SIZE;
    if (avail < 4)
        return SWM_NEED_MORE;
    if (swm_r32(data) != SWM_MAGIC)
        return SWM_BAD;
    if (avail < SWM_HEADER_SIZE)
        return SWM_NEED_MORE;
    uint16_t type = swm_r16(data + 4);
    uint32_t length = swm_r32(data + 8);
    uint32_t fixed = 0;
    switch (type) {
        case SWM_HELLO:
            fixed = SWM_HELLO_SIZE;
            break;
        case SWM_WINDOW:
            fixed = SWM_WINDOW_FIXED;
            break;
        case SWM_FRAME:
            fixed = SWM_FRAME_FIXED;
            break;
        case SWM_GONE:
            fixed = SWM_GONE_SIZE;
            break;
        case SWM_POINTER:
            fixed = SWM_POINTER_SIZE;
            break;
        case SWM_KEY:
            fixed = SWM_KEY_SIZE;
            break;
        case SWM_FOCUS:
            fixed = SWM_FOCUS_SIZE;
            break;
        default:
            return SWM_BAD;
    }
    if (swm_r16(data + 6) || length < fixed)
        return SWM_BAD;
    if (type == SWM_WINDOW) {
        if (length > SWM_WINDOW_FIXED + 2 * SWM_MAX_TEXT)
            return SWM_BAD;
    } else if (type != SWM_FRAME && length != fixed)
        return SWM_BAD;
    *used = SWM_HEADER_SIZE + (size_t)fixed;
    if (avail < *used)
        return SWM_NEED_MORE;
    const uint8_t *p = data + SWM_HEADER_SIZE;
    m->type = type;
    switch (type) {
        case SWM_HELLO:
            m->u.version = swm_r32(p);
            break;
        case SWM_GONE:
        case SWM_FOCUS:
            m->u.window_id = swm_r32(p);
            break;
        case SWM_KEY: {
            struct SWMKey *k = &m->u.key;
            k->keycode = swm_r16(p);
            k->down = p[2];
            k->flags = swm_r32(p + 4);
            if (k->down > 1)
                return SWM_BAD;
            break;
        }
        case SWM_POINTER: {
            struct SWMPointer *e = &m->u.pointer;
            e->window = swm_r32(p);
            e->kind = p[4];
            e->button = p[5];
            e->clicks = p[6];
            e->x = (int32_t)swm_r32(p + 8);
            e->y = (int32_t)swm_r32(p + 12);
            e->flags = swm_r32(p + 16);
            if (e->kind > SWM_DRAG || e->button > 2)
                return SWM_BAD;
            break;
        }
        case SWM_WINDOW: {
            struct SWMWindow *w = &m->u.window;
            w->window = swm_r32(p);
            w->pid = swm_r32(p + 4);
            w->layer = (int32_t)swm_r32(p + 8);
            w->x = (int32_t)swm_r32(p + 12);
            w->y = (int32_t)swm_r32(p + 16);
            w->width = (int32_t)swm_r32(p + 20);
            w->height = (int32_t)swm_r32(p + 24);
            w->pixel_width = swm_r32(p + 28);
            w->pixel_height = swm_r32(p + 32);
            w->title_length = swm_r16(p + 36);
            w->owner_length = swm_r16(p + 38);
            if (w->title_length > SWM_MAX_TEXT || w->owner_length > SWM_MAX_TEXT ||
                length != SWM_WINDOW_FIXED + (uint32_t)w->title_length + w->owner_length || w->width <= 0 ||
                w->height <= 0 || w->width > (int32_t)SWM_MAX_DIMENSION || w->height > (int32_t)SWM_MAX_DIMENSION ||
                !w->pixel_width || !w->pixel_height || w->pixel_width > SWM_MAX_DIMENSION ||
                w->pixel_height > SWM_MAX_DIMENSION)
                return SWM_BAD;
            break;
        }
        case SWM_FRAME: {
            struct SWMFrame *f = &m->u.frame;
            f->window = swm_r32(p);
            f->sequence = swm_r32(p + 4);
            f->full_width = swm_r32(p + 8);
            f->full_height = swm_r32(p + 12);
            f->x = swm_r32(p + 16);
            f->y = swm_r32(p + 20);
            f->width = swm_r32(p + 24);
            f->height = swm_r32(p + 28);
            // Each is at most 8192, so nothing below can overflow: 8192 * 8192 * 4 fits 32 bits with room for `fixed`.
            if (!f->full_width || !f->full_height || f->full_width > SWM_MAX_DIMENSION ||
                f->full_height > SWM_MAX_DIMENSION || f->x > f->full_width || f->y > f->full_height || !f->width ||
                !f->height || f->width > f->full_width - f->x || f->height > f->full_height - f->y ||
                length != SWM_FRAME_FIXED + f->width * f->height * 4)
                return SWM_BAD;
            f->pixels = p + SWM_FRAME_FIXED;
            break;
        }
    }
    *used = SWM_HEADER_SIZE + (size_t)length;
    if (avail < *used)
        return SWM_NEED_MORE;
    if (type == SWM_WINDOW) {
        m->u.window.title = (const char *)p + SWM_WINDOW_FIXED;
        m->u.window.owner = m->u.window.title + m->u.window.title_length;
    }
    return SWM_OK;
}
#endif
