// Turns the seamless wire's input into guest events that AppKit sees as real gestures. x86_64, Mac OS X 10.9 and up, in
// the console session. Private functions are looked up at run time, so one binary loads on every version. The field
// numbers and record offsets come from Apple's own ScreensharingAgent, which is how Screen Sharing delivers gestures:
// see seamless-input.md for the evidence and what's been measured.
//
// Three ways in, because which of them each OS honours is the thing being measured:
//   SWI_RECORD    SLSPostEventRecord: a raw event record. What 10.9's agent does.
//   SWI_SESSION   CGEventPost at the session tap with private fields. What 10.14's agent does.
//   SWI_HID       The same at the HID tap.
//   SWI_PID       The same to one process, past window ordering. With `window` set, to one window of it.
//   SWI_IOHID     An IOHIDEvent dispatched into the event system. Magnify and rotate only.
#ifndef SEAMLESS_INJECT_H
#define SEAMLESS_INJECT_H
#include "seamless-wire.h"
#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>

enum SWIMechanism { SWI_RECORD, SWI_SESSION, SWI_HID, SWI_PID, SWI_IOHID, SWI_MECHANISM_COUNT };
static const char *const swi_mechanism_names[] = {"record", "session", "hid", "pid", "iohid"};

// CGEventType and fields that have no public name. Numbers read from RemoteDesktop-525.50 and AppKit-1671.60.109.
enum {
    SWI_TYPE_SYSTEM_DEFINED = 14,
    SWI_TYPE_SCROLL = 22,
    SWI_TYPE_GESTURE = 29,
    SWI_F_WHEEL_LINES_Y = 11,
    SWI_F_WHEEL_LINES_X = 12,
    SWI_F_WHEEL_LINES_Z = 13,
    SWI_F_WINDOW_NUMBER = 51, // What NSEvent reads for its window, and WindowServer fills in when it routes.
    SWI_F_SYSTEM_SUBTYPE = 83,
    SWI_F_WHEEL_CONTINUOUS = 88,
    SWI_F_WINDOW_UNDER_POINTER = 91,
    SWI_F_WINDOW_THAT_CAN_HANDLE = 92,
    SWI_F_WHEEL_FIXED_Y = 93,
    SWI_F_WHEEL_FIXED_X = 94,
    SWI_F_WHEEL_FIXED_Z = 95,
    SWI_F_WHEEL_POINTS_Y = 96,
    SWI_F_WHEEL_POINTS_X = 97,
    SWI_F_WHEEL_POINTS_Z = 98,
    SWI_F_WHEEL_PHASE = 99,
    SWI_F_WHEEL_COUNT = 100, // Also the system-defined event's data1.
    SWI_F_GESTURE_SUBTYPE = 110,
    SWI_F_MAGNIFICATION = 113,
    SWI_F_ROTATION = 114,
    SWI_F_SWIPE_DIRECTION = 115,
    SWI_F_GESTURE_MASK = 117,
    SWI_F_SYSTEM_DATA2 = 121,
    SWI_F_SYSTEM_DATA3 = 122,
    SWI_F_MOMENTUM = 123, // Also a swipe's motion.
    SWI_F_SWIPE_PROGRESS = 124,
    SWI_F_GESTURE_PHASE = 132,
    SWI_F_GESTURE_MOTION = 133,
    SWI_F_SWIPE_MASK = 134,
    SWI_F_WHEEL_INVERTED = 137,
    SWI_F_STAGE = 143,
    SWI_F_STAGE_TRANSITION = 147,
    SWI_F_PRESSURE = 148,
};
// The IOHIDEventType, carried as the gesture's subtype. NSEvent's type follows from it.
enum {
    SWI_SUB_ROTATE = 5,
    SWI_SUB_MAGNIFY = 8,
    SWI_SUB_SWIPE = 16,
    SWI_SUB_SMART_MAGNIFY = 22,
    SWI_SUB_PRESSURE = 32, // 10.10.3 and later.
    SWI_SUB_BEGIN = 61,
    SWI_SUB_END = 62,
};
#define SWI_LOOKUP_TAG 0x6C6B7570u // 'lkup', in Apple's "lookup gesture" system-defined event.

struct SWIContext {
    enum SWIMechanism mechanism;
    pid_t pid; // SWI_PID.
    CGWindowID window; // SWI_PID: post at this window, whatever covers it.
    CGPoint window_origin;
    double carry_x, carry_y; // Fractions of a point not yet delivered, since the point fields are integers.
    uint8_t keys_down[32];
    uint32_t modifiers;
};

typedef int (*SWIPostRecord)(int connection, const void *record, uint32_t length, uint32_t flags);
static SWIPostRecord swi_post_record_function(void) {
    SWIPostRecord f = (SWIPostRecord)dlsym(RTLD_DEFAULT, "CGSPostEventRecord");
    return f ? f : (SWIPostRecord)dlsym(RTLD_DEFAULT, "SLSPostEventRecord");
}
typedef void (*SWIPostToPid)(pid_t, CGEventRef);

// Returns 0 if this mechanism doesn't exist here. A posted event's fate only shows in what the guest app receives.
static inline int swi_post(struct SWIContext *c, CGEventRef e) {
    switch (c->mechanism) {
        case SWI_HID:
            CGEventPost(kCGHIDEventTap, e);
            return 1;
        case SWI_PID: {
            if (c->window) {
                CGEventSetIntegerValueField(e, (CGEventField)SWI_F_WINDOW_NUMBER, c->window);
                CGEventSetIntegerValueField(e, (CGEventField)SWI_F_WINDOW_UNDER_POINTER, c->window);
                CGEventSetIntegerValueField(e, (CGEventField)SWI_F_WINDOW_THAT_CAN_HANDLE, c->window);
                void (*set_window_location)(CGEventRef, CGPoint) =
                    (void (*)(CGEventRef, CGPoint))dlsym(RTLD_DEFAULT, "CGEventSetWindowLocation");
                if (set_window_location) {
                    CGPoint p = CGEventGetLocation(e);
                    set_window_location(e, CGPointMake(p.x - c->window_origin.x, p.y - c->window_origin.y));
                }
            }
            SWIPostToPid post = (SWIPostToPid)dlsym(RTLD_DEFAULT, "CGEventPostToPid");
            if (post) {
                post(c->pid, e);
                return 1;
            }
            // 10.9 has only the PSN form.
            OSStatus (*for_pid)(pid_t, ProcessSerialNumber *) =
                (OSStatus (*)(pid_t, ProcessSerialNumber *))dlsym(RTLD_DEFAULT, "GetProcessForPID");
            ProcessSerialNumber psn;
            if (!for_pid || for_pid(c->pid, &psn))
                return 0;
            CGEventPostToPSN(&psn, e);
            return 1;
        }
        default:
            CGEventPost(kCGSessionEventTap, e);
            return 1;
    }
}

static inline CGEventRef swi_event(int type, CGPoint p, uint32_t modifiers) {
    CGEventRef e = CGEventCreate(NULL);
    CGEventSetType(e, (CGEventType)type);
    CGEventSetLocation(e, p);
    CGEventSetFlags(e, (CGEventFlags)modifiers);
    return e;
}
#define SWI_SET_INT(e, field, value) CGEventSetIntegerValueField(e, (CGEventField)(field), (int64_t)(value))
#define SWI_SET_DOUBLE(e, field, value) CGEventSetDoubleValueField(e, (CGEventField)(field), (double)(value))

// Swipe: bit 1 up, 2 down, 4 left, 8 right, as 10.9's agent derives them from motion and progress. deltaX > 0 is left.
static inline void swi_swipe_shape(const struct SWMGesture *g, int *motion, int *direction, float *progress) {
    int vertical = g->b != 0;
    float amount = vertical ? g->b : g->a;
    *motion = vertical ? 2 : 1;
    if (vertical)
        *direction = amount > 0 ? 1 : 2;
    else
        *direction = amount > 0 ? 4 : 8;
    // 10.9's agent reads a positive vertical progress as down, and a positive horizontal one as left.
    *progress = vertical ? -amount : amount;
}

static inline int swi_scroll_integer(double value, double *carry) {
    double total = value + *carry;
    int whole = (int)trunc(total);
    *carry = total - whole;
    return whole;
}
static inline double swi_points_to_lines(double points) { return points / 10; } // AppKit's default pixels per line.

// Field layout of the event record as 10.9's ScreensharingAgent fills it. Offsets correspond with the field numbers.
static inline int swi_record_gesture(struct SWIContext *c, const struct SWMGesture *g, CGPoint p) {
    SWIPostRecord post = swi_post_record_function();
    uint32_t (*record_length)(void) = (uint32_t (*)(void))dlsym(RTLD_DEFAULT, "CGSEventRecordLength");
    if (!record_length)
        record_length = (uint32_t (*)(void))dlsym(RTLD_DEFAULT, "SLSEventRecordLength");
    int (*main_connection)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    if (!post || !record_length || !main_connection)
        return 0;
    uint32_t length = record_length();
    if (length < 0xD0 || length > 4096)
        return 0;
    uint8_t r[4096];
    memset(r, 0, length);
    uint16_t version = 3;
    memcpy(r, &version, 2);
    memcpy(r + 4, &length, 4);
    double x = p.x, y = p.y;
    memcpy(r + 0x10, &x, 8);
    memcpy(r + 0x18, &y, 8);
    uint32_t flags = 0x100 | g->modifiers;
    memcpy(r + 0x38, &flags, 4);
    uint32_t type = SWI_TYPE_GESTURE, subtype = 0, u;
    float f;
#define SWI_PUT(offset, value) memcpy(r + (offset), &(value), sizeof(value))
    switch (g->kind) {
        case SWG_SCROLL: {
            type = SWI_TYPE_SCROLL;
            int precise = (g->flags & SWG_PRECISE) != 0;
            double points_y = precise ? g->b : (double)g->b * 10, points_x = precise ? g->a : (double)g->a * 10;
            int16_t lines_y = (int16_t)round(swi_points_to_lines(points_y));
            int16_t lines_x = (int16_t)round(swi_points_to_lines(points_x));
            int32_t fixed_y = (int32_t)(swi_points_to_lines(points_y) * 65536);
            int32_t fixed_x = (int32_t)(swi_points_to_lines(points_x) * 65536);
            int32_t pt_y = swi_scroll_integer(points_y, &c->carry_y), pt_x = swi_scroll_integer(points_x, &c->carry_x);
            SWI_PUT(0x88, lines_y);
            SWI_PUT(0x8A, lines_x);
            SWI_PUT(0x90, fixed_y);
            SWI_PUT(0x94, fixed_x);
            SWI_PUT(0x9C, pt_y);
            SWI_PUT(0xA0, pt_x);
            u = g->phase;
            SWI_PUT(0xA8, u);
            u = g->momentum;
            SWI_PUT(0xB4, u);
            r[0xB8] = (uint8_t)((precise ? 2 : 0) | (g->flags & SWG_INVERTED ? 4 : 0));
            memcpy(r + 8, &type, 4);
            return post(main_connection(), r, length, 0) == 0;
        }
        case SWG_MAGNIFY:
            subtype = SWI_SUB_MAGNIFY;
            f = g->a;
            SWI_PUT(0xA0, f);
            u = 4;
            SWI_PUT(0x9C, u);
            r[0x9A] = g->phase;
            break;
        case SWG_ROTATE:
            subtype = SWI_SUB_ROTATE;
            f = g->a;
            SWI_PUT(0xA0, f);
            u = 4;
            SWI_PUT(0x9C, u);
            r[0x9A] = g->phase;
            break;
        case SWG_SWIPE: {
            subtype = SWI_SUB_SWIPE;
            int motion, direction;
            swi_swipe_shape(g, &motion, &direction, &f);
            u = (uint32_t)motion;
            SWI_PUT(0xA4, u);
            u = (uint32_t)direction;
            SWI_PUT(0xA0, u);
            SWI_PUT(0xA8, u);
            SWI_PUT(0xAC, f);
            r[0x9A] = g->phase;
            break;
        }
        case SWG_SMART_MAGNIFY:
            subtype = SWI_SUB_SMART_MAGNIFY;
            u = 2;
            SWI_PUT(0x9C, u);
            break;
        case SWG_BEGIN:
        case SWG_END:
            subtype = g->kind == SWG_BEGIN ? SWI_SUB_BEGIN : SWI_SUB_END;
            u = g->stage;
            SWI_PUT(0xA0, u);
            break;
        case SWG_QUICK_LOOK: {
            type = SWI_TYPE_SYSTEM_DEFINED;
            u = SWI_LOOKUP_TAG;
            SWI_PUT(0x8C, u);
            uint64_t wide = SWI_LOOKUP_TAG;
            SWI_PUT(0x90, wide);
            uint16_t all = 0xFFFF, sub = 6;
            SWI_PUT(0x98, all);
            SWI_PUT(0x9A, all);
            SWI_PUT(0x8A, sub);
            memcpy(r + 8, &type, 4);
            post(main_connection(), r, length, 0);
            sub = 9;
            SWI_PUT(0x8A, sub);
            return post(main_connection(), r, length, 0) == 0;
        }
        default:
            return 0; // Pressure has no record form: 10.9 has no such event, and later versions use fields.
    }
#undef SWI_PUT
    memcpy(r + 8, &type, 4);
    memcpy(r + 0x88, &subtype, 4);
    return post(main_connection(), r, length, 0) == 0;
}

static inline int swi_iohid_gesture(const struct SWMGesture *g) {
    typedef void *(*Create)(CFAllocatorRef, uint64_t, double, double, double, uint32_t);
    Create create = (Create)dlsym(RTLD_DEFAULT, g->kind == SWG_MAGNIFY ? "IOHIDEventCreateScaleEvent"
                                                                       : "IOHIDEventCreateRotationEvent");
    void *(*client_create)(CFAllocatorRef) =
        (void *(*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    void (*dispatch)(void *, void *) =
        (void (*)(void *, void *))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    if ((g->kind != SWG_MAGNIFY && g->kind != SWG_ROTATE) || !create || !client_create || !dispatch)
        return 0;
    static void *client;
    if (!client)
        client = client_create(kCFAllocatorDefault);
    void *event = create(kCFAllocatorDefault, mach_absolute_time(), g->a, 0, 0, 0);
    if (!client || !event)
        return 0;
    dispatch(client, event);
    CFRelease(event);
    return 1;
}

// `p` is the gesture's place in guest screen points. Returns 0 if this mechanism can't express this gesture here.
static inline int swi_gesture(struct SWIContext *c, const struct SWMGesture *g, CGPoint p) {
    if (c->mechanism == SWI_RECORD)
        return swi_record_gesture(c, g, p);
    if (c->mechanism == SWI_IOHID)
        return swi_iohid_gesture(g);
    CGEventRef e;
    int result;
    switch (g->kind) {
        case SWG_SCROLL: {
            e = swi_event(SWI_TYPE_SCROLL, p, g->modifiers);
            int precise = (g->flags & SWG_PRECISE) != 0;
            double points_y = precise ? g->b : (double)g->b * 10, points_x = precise ? g->a : (double)g->a * 10;
            SWI_SET_INT(e, SWI_F_WHEEL_LINES_Y, lround(swi_points_to_lines(points_y)));
            SWI_SET_INT(e, SWI_F_WHEEL_LINES_X, lround(swi_points_to_lines(points_x)));
            SWI_SET_INT(e, SWI_F_WHEEL_FIXED_Y, swi_points_to_lines(points_y) * 65536);
            SWI_SET_INT(e, SWI_F_WHEEL_FIXED_X, swi_points_to_lines(points_x) * 65536);
            SWI_SET_INT(e, SWI_F_WHEEL_POINTS_Y, swi_scroll_integer(points_y, &c->carry_y));
            SWI_SET_INT(e, SWI_F_WHEEL_POINTS_X, swi_scroll_integer(points_x, &c->carry_x));
            SWI_SET_INT(e, SWI_F_WHEEL_PHASE, g->phase);
            SWI_SET_INT(e, SWI_F_MOMENTUM, g->momentum);
            SWI_SET_INT(e, SWI_F_WHEEL_CONTINUOUS, precise);
            SWI_SET_INT(e, SWI_F_WHEEL_INVERTED, (g->flags & SWG_INVERTED) != 0);
            break;
        }
        case SWG_MAGNIFY:
            e = swi_event(SWI_TYPE_GESTURE, p, g->modifiers);
            SWI_SET_INT(e, SWI_F_GESTURE_SUBTYPE, SWI_SUB_MAGNIFY);
            SWI_SET_DOUBLE(e, SWI_F_MAGNIFICATION, g->a);
            SWI_SET_INT(e, SWI_F_GESTURE_PHASE, g->phase);
            SWI_SET_INT(e, SWI_F_GESTURE_MOTION, 4);
            break;
        case SWG_ROTATE:
            e = swi_event(SWI_TYPE_GESTURE, p, g->modifiers);
            SWI_SET_INT(e, SWI_F_GESTURE_SUBTYPE, SWI_SUB_ROTATE);
            SWI_SET_DOUBLE(e, SWI_F_ROTATION, g->a);
            SWI_SET_INT(e, SWI_F_GESTURE_PHASE, g->phase);
            SWI_SET_INT(e, SWI_F_GESTURE_MOTION, 4);
            break;
        case SWG_SWIPE: {
            e = swi_event(SWI_TYPE_GESTURE, p, g->modifiers);
            int motion, direction;
            float progress;
            swi_swipe_shape(g, &motion, &direction, &progress);
            SWI_SET_INT(e, SWI_F_GESTURE_SUBTYPE, SWI_SUB_SWIPE);
            SWI_SET_INT(e, SWI_F_MOMENTUM, motion);
            SWI_SET_INT(e, SWI_F_SWIPE_DIRECTION, direction);
            SWI_SET_INT(e, SWI_F_SWIPE_MASK, direction);
            SWI_SET_DOUBLE(e, SWI_F_SWIPE_PROGRESS, progress);
            SWI_SET_INT(e, SWI_F_GESTURE_PHASE, g->phase);
            break;
        }
        case SWG_SMART_MAGNIFY:
            e = swi_event(SWI_TYPE_GESTURE, p, g->modifiers);
            SWI_SET_INT(e, SWI_F_GESTURE_SUBTYPE, SWI_SUB_SMART_MAGNIFY);
            SWI_SET_INT(e, SWI_F_GESTURE_MOTION, 2);
            break;
        case SWG_BEGIN:
        case SWG_END:
            e = swi_event(SWI_TYPE_GESTURE, p, g->modifiers);
            SWI_SET_INT(e, SWI_F_GESTURE_SUBTYPE, g->kind == SWG_BEGIN ? SWI_SUB_BEGIN : SWI_SUB_END);
            SWI_SET_INT(e, SWI_F_GESTURE_MASK, g->stage);
            break;
        case SWG_QUICK_LOOK:
            e = swi_event(SWI_TYPE_SYSTEM_DEFINED, p, g->modifiers);
            SWI_SET_INT(e, SWI_F_WHEEL_COUNT, SWI_LOOKUP_TAG);
            SWI_SET_INT(e, SWI_F_SYSTEM_DATA2, 0xFFFF);
            SWI_SET_INT(e, SWI_F_SYSTEM_DATA3, -1);
            SWI_SET_INT(e, SWI_F_SYSTEM_SUBTYPE, 6);
            swi_post(c, e);
            SWI_SET_INT(e, SWI_F_SYSTEM_SUBTYPE, 9);
            break;
        case SWG_PRESSURE:
            e = swi_event(SWI_TYPE_GESTURE, p, g->modifiers);
            SWI_SET_INT(e, SWI_F_GESTURE_SUBTYPE, SWI_SUB_PRESSURE);
            SWI_SET_INT(e, SWI_F_STAGE, g->stage);
            SWI_SET_DOUBLE(e, SWI_F_STAGE_TRANSITION, g->b);
            SWI_SET_DOUBLE(e, SWI_F_PRESSURE, g->a);
            SWI_SET_INT(e, SWI_F_GESTURE_PHASE, g->phase);
            break;
        default:
            return 0;
    }
    result = swi_post(c, e);
    CFRelease(e);
    return result;
}

static inline void swi_pointer(struct SWIContext *c, const struct SWMPointer *m, CGPoint p) {
    static const CGEventType moves[] = {kCGEventLeftMouseDragged, kCGEventRightMouseDragged, kCGEventOtherMouseDragged};
    static const CGEventType downs[] = {kCGEventLeftMouseDown, kCGEventRightMouseDown, kCGEventOtherMouseDown};
    static const CGEventType ups[] = {kCGEventLeftMouseUp, kCGEventRightMouseUp, kCGEventOtherMouseUp};
    CGEventType type = m->kind == SWM_DOWN   ? downs[m->button]
                       : m->kind == SWM_UP   ? ups[m->button]
                       : m->kind == SWM_DRAG ? moves[m->button]
                                             : kCGEventMouseMoved;
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, p, (CGMouseButton)m->button);
    CGEventSetFlags(e, (CGEventFlags)m->flags);
    if (m->kind == SWM_DOWN || m->kind == SWM_UP)
        CGEventSetIntegerValueField(e, kCGMouseEventClickState, m->clicks);
    swi_post(c, e);
    CFRelease(e);
}

// CGEventCreateKeyboardEvent makes a flags-changed event by itself when the key is a modifier. There's no HID behind a
// posted key, so the guest doesn't repeat it: repeats arrive from the host, and are marked as such here.
static inline void swi_key(struct SWIContext *c, uint16_t code, int down, uint32_t flags) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, code, down != 0);
    CGEventSetFlags(e, (CGEventFlags)flags);
    if (code < 256) {
        uint8_t bit = (uint8_t)(1u << (code & 7));
        if (down && (c->keys_down[code >> 3] & bit))
            CGEventSetIntegerValueField(e, kCGKeyboardEventAutorepeat, 1);
        c->keys_down[code >> 3] = down ? c->keys_down[code >> 3] | bit : c->keys_down[code >> 3] & (uint8_t)~bit;
    }
    swi_post(c, e);
    CFRelease(e);
}

// Brings the guest's held modifiers to what the host says, posting the key changes that takes. Each row holds one
// modifier's aggregate flag, its device-dependent left and right bits, and the left and right keycodes.
static inline void swi_modifiers(struct SWIContext *c, uint32_t wanted) {
    static const struct {
        uint32_t left_bit, right_bit, any;
        uint16_t left, right;
    } rows[] = {
        {0x00000002, 0x00000004, kCGEventFlagMaskShift, 56, 60},
        {0x00000001, 0x00002000, kCGEventFlagMaskControl, 59, 62},
        {0x00000020, 0x00000040, kCGEventFlagMaskAlternate, 58, 61},
        {0x00000008, 0x00000010, kCGEventFlagMaskCommand, 55, 54},
    };
    uint32_t now = c->modifiers;
    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        int want_left = (wanted & rows[i].left_bit) || ((wanted & rows[i].any) && !(wanted & rows[i].right_bit));
        int want_right = (wanted & rows[i].right_bit) != 0;
        int has_left = (c->keys_down[rows[i].left >> 3] >> (rows[i].left & 7)) & 1;
        int has_right = (c->keys_down[rows[i].right >> 3] >> (rows[i].right & 7)) & 1;
        if (want_left != has_left) {
            now = want_left ? now | rows[i].any | rows[i].left_bit : now & ~rows[i].left_bit;
            if (!want_left && !want_right)
                now &= ~rows[i].any;
            swi_key(c, rows[i].left, want_left, now);
        }
        if (want_right != has_right) {
            now = want_right ? now | rows[i].any | rows[i].right_bit : now & ~rows[i].right_bit;
            if (!want_right && !want_left)
                now &= ~rows[i].any;
            swi_key(c, rows[i].right, want_right, now);
        }
    }
    c->modifiers = now;
}

// Committed text, as the focused view's next keystroke. Keyed code 0 with the text attached. shortcut: 20 UTF-16 units
// at a time, the limit reported for CGEventKeyboardSetUnicodeString [memory]; never splits a surrogate pair, but can
// split a grapheme, which only matters if a guest app handles text per event.
static inline void swi_text(struct SWIContext *c, const char *utf8, size_t length) {
    CFStringRef text =
        CFStringCreateWithBytes(NULL, (const UInt8 *)utf8, (CFIndex)length, kCFStringEncodingUTF8, false);
    if (!text)
        return;
    CFIndex total = CFStringGetLength(text);
    for (CFIndex at = 0; at < total;) {
        CFIndex count = total - at < 20 ? total - at : 20;
        UniChar chunk[20];
        CFStringGetCharacters(text, CFRangeMake(at, count), chunk);
        if (count > 1 && chunk[count - 1] >= 0xD800 && chunk[count - 1] < 0xDC00)
            count--;
        for (int down = 1; down >= 0; down--) {
            CGEventRef e = CGEventCreateKeyboardEvent(NULL, 0, down != 0);
            CGEventSetFlags(e, 0);
            CGEventKeyboardSetUnicodeString(e, (UniCharCount)count, chunk);
            swi_post(c, e);
            CFRelease(e);
        }
        at += count;
    }
    CFRelease(text);
}
#endif
