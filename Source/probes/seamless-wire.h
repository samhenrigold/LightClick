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
#define SWM_VERSION 2u
#define SWM_HEADER_SIZE 12u
#define SWM_MAX_DIMENSION 8192u // The largest frame the display path carries.
#define SWM_MAX_TEXT 1024u
#define SWM_MAX_MENU (16u * 1024 * 1024)
#define SWM_MAX_MARGIN 1024u // Points of frame around a window, for its shadow.

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
    // Input beyond a tablet and a keyboard. See seamless-input.md.
    SWM_GESTURE = 32,
    SWM_MODIFIERS = 33,
    SWM_TEXT = 34,
    // App integration. See seamless-integration.md.
    SWM_MENU = 48, // Guest to host: the app's menu as GuestMenuItem JSON.
    SWM_MENU_PRESS = 49, // Host to guest: a menu path, items joined by '/'.
    SWM_DOCUMENT = 50, // Either way, a piece of a file: see swm_put_document.
    SWM_QUIT_APP = 51, // Host to guest: ask the app to quit, which may ask to save. The value is unused.
    SWM_APP_GONE = 52, // Guest to host: the app has exited. The value is unused.
    SWM_DRAG_CANCEL = 53, // Host to guest: a host drag left before dropping. The value is unused.
    SWM_DRAG_QUERY =
        54, // Host to guest: the pointer left with the button down. Is a guest drag live? The value is unused.
    SWM_DRAG_STATE = 55, // Guest to host: the guest's drag pasteboard, as JSON.
    SWM_DRAG_SEND = 56, // Host to guest: a document id, then a guest path: send that file back under that id.
    SWM_APP_STATE = 57, // Guest to host: JSON with the app's badge, and whether it wants attention.
    SWM_CROP = 58, // Guest to host: show this window from the display's own frames. A frame for it is what shows where it's covered.
    SWM_OVERLAY = 59, // Guest to host: the same, with its frames' alpha as the shape: a menu, a popover, a sheet.
};
enum SWMPointerKind { SWM_MOVE = 0, SWM_DOWN = 1, SWM_UP = 2, SWM_DRAG = 3 };

#define SWM_HELLO_SIZE 4u
#define SWM_WINDOW_FIXED 56u
#define SWM_FRAME_FIXED 32u
#define SWM_GONE_SIZE 4u
#define SWM_POINTER_SIZE 20u
#define SWM_KEY_SIZE 8u
#define SWM_FOCUS_SIZE 4u
#define SWM_GESTURE_SIZE 36u
#define SWM_MODIFIERS_SIZE 4u
#define SWM_TEXT_FIXED 8u

struct SWMWindow {
    uint32_t window, pid;
    int32_t layer;
    int32_t x, y, width, height; // Points, in guest screen coordinates, top-left origin.
    uint32_t pixel_width, pixel_height;
    uint16_t title_length, owner_length;
    const char *title, *owner; // UTF-8, not terminated, inside the receive buffer.
    uint32_t order; // 0 is frontmost among those sent.
    uint32_t group; // Lowest window ID among those WindowServer moves with this one; 0 if alone.
    uint32_t alpha; // 16.16 fixed point, as the guest's system alpha.
    uint32_t margin; // The pixels cover the bounds grown this many points each way, shadow included.
};
// One band of BGRA premultiplied pixels, tightly packed, full_width and full_height being the whole window's size.
struct SWMFrame {
    uint32_t window, sequence, full_width, full_height, x, y, width, height;
    const uint8_t *pixels;
};
// Coordinates are points times 16, so Retina half-points survive: relative to `window`, or to the guest's screen if
// `window` is 0.
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
// One event of a trackpad gesture. Which of a, b and c mean what:
//   SWG_SCROLL     x, y, z deltas: points if SWG_PRECISE is set, otherwise lines
//   SWG_MAGNIFY    a = NSEvent.magnification        SWG_ROTATE   a = NSEvent.rotation, degrees
//   SWG_SWIPE      a, b = NSEvent.deltaX, deltaY
//   SWG_PRESSURE   a = pressure 0 to 1, b = stageTransition, with `stage`
//   SWG_BEGIN, SWG_END   the kind (SWG_MAGNIFY, ...) in `stage`
//   SWG_SMART_MAGNIFY, SWG_QUICK_LOOK   nothing
enum SWMGestureKind {
    SWG_SCROLL = 0,
    SWG_MAGNIFY = 1,
    SWG_ROTATE = 2,
    SWG_SWIPE = 3,
    SWG_SMART_MAGNIFY = 4,
    SWG_QUICK_LOOK = 5,
    SWG_PRESSURE = 6,
    SWG_BEGIN = 7,
    SWG_END = 8,
    SWG_KIND_COUNT = 9,
};
// The same values on NSEvent's side are 1, 4, 8, 16 and 32, and both directions of that map live in one place each:
// seamless-input-view.h and the guest's CGEvent fields, which use these.
enum SWMPhase {
    SWP_NONE = 0,
    SWP_BEGAN = 1,
    SWP_CHANGED = 2,
    SWP_ENDED = 4,
    SWP_CANCELLED = 8,
    SWP_MAY_BEGIN = 128,
};
enum SWMMomentum { SWM_MOMENTUM_NONE = 0, SWM_MOMENTUM_BEGAN = 1, SWM_MOMENTUM_CHANGED = 2, SWM_MOMENTUM_ENDED = 3 };
enum SWMGestureFlag { SWG_PRECISE = 1, SWG_INVERTED = 2 };
struct SWMGesture {
    uint32_t window;
    uint8_t kind, phase, momentum, stage;
    int32_t x, y; // Window-relative points times 16, as in SWMPointer.
    float a, b, c;
    uint32_t flags; // SWMGestureFlag.
    uint32_t modifiers; // As SWMPointer.flags.
};
enum SWMTextKind {
    SWT_INSERT = 0, // Committed text from the host's input method, for the guest's focused view.
    SWT_INPUT_SOURCE = 1, // A TIS input source ID the guest should select, such as com.apple.keylayout.French.
};
struct SWMText {
    uint32_t window;
    uint16_t kind, length;
    const char *bytes; // UTF-8, not terminated, inside the receive buffer.
};
struct SWMMessage {
    uint16_t type;
    union {
        uint32_t version; // SWM_HELLO
        uint32_t window_id; // SWM_GONE, SWM_FOCUS
        uint32_t modifiers; // SWM_MODIFIERS: every modifier held now, as SWMPointer.flags, for after focus changes.
        struct SWMGesture gesture;
        struct SWMText text;
        struct SWMWindow window;
        struct SWMFrame frame;
        struct SWMPointer pointer;
        struct SWMKey key;
        struct {
            const uint8_t *bytes;
            uint32_t length;
        } data; // SWM_MENU, SWM_MENU_PRESS, SWM_DOCUMENT
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
    swm_w32(p + 40, w->order);
    swm_w32(p + 44, w->group);
    swm_w32(p + 48, w->alpha);
    swm_w32(p + 52, w->margin);
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
// // A document's piece: its id, whether it's the last, the file's name and the bytes. A guest's receive buffer is
// small, so a file goes as many of these, and the same message carries a saved file back. Flags say what it's for:
// without them the app opens the file, and with SWD_DRAG it's for a drag, which SWD_DRAG_START says to begin with the
// files so far.
enum SWMDocumentFlags { SWD_DRAG = 1, SWD_DRAG_START = 2 };
#define SWM_DOCUMENT_FIXED 8u
#define SWM_DOCUMENT_PIECE 32768u
static inline size_t swm_put_document_prefix(uint8_t *out, uint32_t id, int last, uint8_t flags, const char *name,
                                             uint16_t name_length, uint32_t piece) {
    swm_header(out, SWM_DOCUMENT, SWM_DOCUMENT_FIXED + name_length + piece);
    uint8_t *p = out + SWM_HEADER_SIZE;
    swm_w32(p, id);
    p[4] = last != 0;
    p[5] = flags;
    swm_w16(p + 6, name_length);
    memcpy(p + SWM_DOCUMENT_FIXED, name, name_length);
    return SWM_HEADER_SIZE + SWM_DOCUMENT_FIXED + name_length;
}
static inline void swm_wf(uint8_t *p, float v) {
    uint32_t bits;
    memcpy(&bits, &v, 4);
    swm_w32(p, bits);
}
static inline float swm_rf(const uint8_t *p) {
    uint32_t bits = swm_r32(p);
    float v;
    memcpy(&v, &bits, 4);
    return v;
}
static inline size_t swm_put_gesture(uint8_t *out, size_t capacity, const struct SWMGesture *g) {
    if (capacity < SWM_HEADER_SIZE + SWM_GESTURE_SIZE)
        return 0;
    swm_header(out, SWM_GESTURE, SWM_GESTURE_SIZE);
    uint8_t *p = out + SWM_HEADER_SIZE;
    swm_w32(p, g->window);
    p[4] = g->kind;
    p[5] = g->phase;
    p[6] = g->momentum;
    p[7] = g->stage;
    swm_w32(p + 8, (uint32_t)g->x);
    swm_w32(p + 12, (uint32_t)g->y);
    swm_wf(p + 16, g->a);
    swm_wf(p + 20, g->b);
    swm_wf(p + 24, g->c);
    swm_w32(p + 28, g->flags);
    swm_w32(p + 32, g->modifiers);
    return SWM_HEADER_SIZE + SWM_GESTURE_SIZE;
}
static inline size_t swm_put_text(uint8_t *out, size_t capacity, const struct SWMText *t) {
    size_t length = SWM_TEXT_FIXED + (size_t)t->length;
    if (t->length > SWM_MAX_TEXT || capacity < SWM_HEADER_SIZE + length)
        return 0;
    swm_header(out, SWM_TEXT, (uint32_t)length);
    uint8_t *p = out + SWM_HEADER_SIZE;
    swm_w32(p, t->window);
    swm_w16(p + 4, t->kind);
    swm_w16(p + 6, t->length);
    if (t->length)
        memcpy(p + SWM_TEXT_FIXED, t->bytes, t->length);
    return SWM_HEADER_SIZE + length;
}
// NaN and infinity would go straight into a guest's scroll offset. A float is finite when its exponent isn't all ones.
static inline int swm_finite(float v) {
    uint32_t bits;
    memcpy(&bits, &v, 4);
    return (bits & 0x7F800000u) != 0x7F800000u;
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
    if (type == SWM_MENU || type == SWM_MENU_PRESS || type == SWM_DOCUMENT || type == SWM_DRAG_STATE ||
        type == SWM_DRAG_SEND || type == SWM_APP_STATE) {
        if (swm_r16(data + 6) || !length || length > SWM_MAX_MENU)
            return SWM_BAD;
        *used = SWM_HEADER_SIZE + (size_t)length;
        if (avail < *used)
            return SWM_NEED_MORE;
        m->type = type;
        m->u.data.bytes = data + SWM_HEADER_SIZE;
        m->u.data.length = length;
        return SWM_OK;
    }
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
        case SWM_QUIT_APP:
        case SWM_APP_GONE:
        case SWM_DRAG_CANCEL:
        case SWM_DRAG_QUERY:
        case SWM_CROP:
        case SWM_OVERLAY:
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
        case SWM_GESTURE:
            fixed = SWM_GESTURE_SIZE;
            break;
        case SWM_MODIFIERS:
            fixed = SWM_MODIFIERS_SIZE;
            break;
        case SWM_TEXT:
            fixed = SWM_TEXT_FIXED;
            break;
        default:
            return SWM_BAD;
    }
    if (swm_r16(data + 6) || length < fixed)
        return SWM_BAD;
    if (type == SWM_WINDOW) {
        if (length > SWM_WINDOW_FIXED + 2 * SWM_MAX_TEXT)
            return SWM_BAD;
    } else if (type == SWM_TEXT) {
        if (length > SWM_TEXT_FIXED + SWM_MAX_TEXT)
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
        case SWM_CROP:
        case SWM_OVERLAY:
            m->u.window_id = swm_r32(p);
            break;
        case SWM_MODIFIERS:
            m->u.modifiers = swm_r32(p);
            break;
        case SWM_GESTURE: {
            struct SWMGesture *g = &m->u.gesture;
            g->window = swm_r32(p);
            g->kind = p[4];
            g->phase = p[5];
            g->momentum = p[6];
            g->stage = p[7];
            g->x = (int32_t)swm_r32(p + 8);
            g->y = (int32_t)swm_r32(p + 12);
            g->a = swm_rf(p + 16);
            g->b = swm_rf(p + 20);
            g->c = swm_rf(p + 24);
            g->flags = swm_r32(p + 28);
            g->modifiers = swm_r32(p + 32);
            if (g->kind >= SWG_KIND_COUNT || g->momentum > SWM_MOMENTUM_ENDED ||
                (g->phase != SWP_NONE && g->phase != SWP_BEGAN && g->phase != SWP_CHANGED && g->phase != SWP_ENDED &&
                 g->phase != SWP_CANCELLED && g->phase != SWP_MAY_BEGIN) ||
                !swm_finite(g->a) || !swm_finite(g->b) || !swm_finite(g->c))
                return SWM_BAD;
            break;
        }
        case SWM_TEXT: {
            struct SWMText *t = &m->u.text;
            t->window = swm_r32(p);
            t->kind = swm_r16(p + 4);
            t->length = swm_r16(p + 6);
            if (t->kind > SWT_INPUT_SOURCE || t->length > SWM_MAX_TEXT ||
                length != SWM_TEXT_FIXED + (uint32_t)t->length)
                return SWM_BAD;
            break;
        }
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
            w->order = swm_r32(p + 40);
            w->group = swm_r32(p + 44);
            w->alpha = swm_r32(p + 48);
            w->margin = swm_r32(p + 52);
            if (w->title_length > SWM_MAX_TEXT || w->owner_length > SWM_MAX_TEXT || w->alpha > 0x10000u ||
                w->margin > SWM_MAX_MARGIN ||
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
    if (type == SWM_TEXT)
        m->u.text.bytes = (const char *)p + SWM_TEXT_FIXED;
    if (type == SWM_WINDOW) {
        m->u.window.title = (const char *)p + SWM_WINDOW_FIXED;
        m->u.window.owner = m->u.window.title + m->u.window.title_length;
    }
    return SWM_OK;
}
#endif
