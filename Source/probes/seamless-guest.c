// Guest side of the seamless-window demo, for Mac OS X 10.9: lists windows, then streams one window's pixels and
// metadata to the host and replays the pointer and key events it sends back. Run it inside the Aqua session.
//
//     seamless-guest list
//     seamless-guest stream --app TextEdit [--window ID] [--host 10.0.2.2] [--port 7654] [--fps 30]
//     seamless-guest stream --test-pattern --host 127.0.0.1    Needs no WindowServer, for testing the path on the host.
//
// Only public CoreGraphics and HIServices. This is the demo, not the design: see
// seamless-apps-design.md for why per-window capture is the fallback rather than the plan.
#include "seamless-wire.h"
#include <ApplicationServices/ApplicationServices.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static double now(void) {
    struct timeval t;
    gettimeofday(&t, NULL);
    return t.tv_sec + t.tv_usec * 1e-6;
}

static CFNumberRef number_for(CFDictionaryRef d, CFStringRef key) {
    CFTypeRef v = CFDictionaryGetValue(d, key);
    return v && CFGetTypeID(v) == CFNumberGetTypeID() ? (CFNumberRef)v : NULL;
}
static int int_for(CFDictionaryRef d, CFStringRef key) {
    int result = 0;
    CFNumberRef n = number_for(d, key);
    if (n)
        CFNumberGetValue(n, kCFNumberIntType, &result);
    return result;
}
static void text_for(CFDictionaryRef d, CFStringRef key, char *out, size_t size) {
    out[0] = 0;
    CFTypeRef v = CFDictionaryGetValue(d, key);
    if (v && CFGetTypeID(v) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)v, out, (CFIndex)size, kCFStringEncodingUTF8);
}
static CGRect bounds_for(CFDictionaryRef d) {
    CGRect r = CGRectZero;
    CFTypeRef v = CFDictionaryGetValue(d, kCGWindowBounds);
    if (v)
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)v, &r);
    return r;
}

static int list_windows(void) {
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!windows) {
        fputs("No window list. Run this inside the Aqua session, from Terminal rather than ssh.\n", stderr);
        return 1;
    }
    for (CFIndex i = 0; i < CFArrayGetCount(windows); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(windows, i);
        char owner[256], name[256];
        text_for(d, kCGWindowOwnerName, owner, sizeof(owner));
        text_for(d, kCGWindowName, name, sizeof(name));
        CGRect b = bounds_for(d);
        printf("id=%d pid=%d layer=%d owner=\"%s\" title=\"%s\" bounds=%g,%g %gx%g\n", int_for(d, kCGWindowNumber),
               int_for(d, kCGWindowOwnerPID), int_for(d, kCGWindowLayer), owner, name, b.origin.x, b.origin.y,
               b.size.width, b.size.height);
    }
    CFRelease(windows);
    return 0;
}

// The frontmost normal window of an app: layer 0, with some size, in front-to-back order.
static CGWindowID find_window(const char *app) {
    CGWindowID found = 0;
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    for (CFIndex i = 0; windows && !found && i < CFArrayGetCount(windows); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(windows, i);
        char owner[256];
        text_for(d, kCGWindowOwnerName, owner, sizeof(owner));
        CGRect b = bounds_for(d);
        if (!strcmp(owner, app) && !int_for(d, kCGWindowLayer) && b.size.width > 40 && b.size.height > 40)
            found = (CGWindowID)int_for(d, kCGWindowNumber);
    }
    if (windows)
        CFRelease(windows);
    return found;
}

static int send_all(int fd, const void *data, size_t size) {
    const uint8_t *p = data;
    while (size) {
        ssize_t n = send(fd, p, size, 0);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return -1;
        p += n;
        size -= (size_t)n;
    }
    return 0;
}

struct Stream {
    int fd;
    int test_pattern;
    CGWindowID window;
    pid_t pid;
    CGRect bounds;
    uint32_t pixel_width, pixel_height, sequence;
    uint8_t *previous; // Tightly packed BGRA of the last frame sent.
    uint32_t clicks, keys;
    uint8_t receive[1024];
    size_t received;
    int buttons_down;
};

// Returns tightly packed BGRA premultiplied pixels the caller frees, whatever the source image's layout was.
static uint8_t *copy_pixels(CGImageRef image, uint32_t *width, uint32_t *height) {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (!w || !h || w > SWM_MAX_DIMENSION || h > SWM_MAX_DIMENSION)
        return NULL;
    uint8_t *out = malloc(w * h * 4);
    if (!out)
        return NULL;
    *width = (uint32_t)w;
    *height = (uint32_t)h;
    const CGBitmapInfo want = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst;
    CFDataRef data = CGImageGetBitsPerPixel(image) == 32 && CGImageGetBitmapInfo(image) == want
                         ? CGDataProviderCopyData(CGImageGetDataProvider(image))
                         : NULL;
    size_t stride = CGImageGetBytesPerRow(image);
    if (data && (size_t)CFDataGetLength(data) >= stride * h) {
        const uint8_t *source = CFDataGetBytePtr(data);
        for (size_t y = 0; y < h; y++)
            memcpy(out + y * w * 4, source + y * stride, w * 4);
    } else {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(out, w, h, 8, w * 4, space, want);
        CGColorSpaceRelease(space);
        if (!context) {
            free(out);
            if (data)
                CFRelease(data);
            return NULL;
        }
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
        CGContextRelease(context);
    }
    if (data)
        CFRelease(data);
    return out;
}

// Green until the first click, blue after, red after a key, with a bar moving down the left so every frame has a
// dirty band that the viewer's center-pixel check won't sample.
static uint8_t *pattern_pixels(struct Stream *s, uint32_t *width, uint32_t *height) {
    uint32_t w = 640, h = 360;
    uint8_t *out = malloc(w * h * 4);
    if (!out)
        return NULL;
    uint32_t bar = (s->sequence * 8) % h;
    uint8_t b = s->clicks ? 255 : 0, g = s->clicks || s->keys ? 0 : 255, r = s->keys ? 255 : 0;
    for (uint32_t y = 0; y < h; y++)
        for (uint32_t x = 0; x < w; x++) {
            uint8_t *p = out + (y * w + x) * 4;
            int in_bar = x < 160 && y >= bar && y < bar + 8;
            p[0] = in_bar ? 255 : b;
            p[1] = in_bar ? 255 : g;
            p[2] = in_bar ? 255 : r;
            p[3] = 255;
        }
    *width = w;
    *height = h;
    return out;
}

static int send_window(struct Stream *s, const char *title, const char *owner, int layer) {
    uint8_t out[SWM_HEADER_SIZE + SWM_WINDOW_FIXED + 2 * SWM_MAX_TEXT];
    size_t title_length = strlen(title), owner_length = strlen(owner);
    struct SWMWindow w = {
        s->window,
        (uint32_t)s->pid,
        layer,
        (int32_t)s->bounds.origin.x,
        (int32_t)s->bounds.origin.y,
        (int32_t)s->bounds.size.width,
        (int32_t)s->bounds.size.height,
        s->pixel_width,
        s->pixel_height,
        (uint16_t)(title_length > SWM_MAX_TEXT ? SWM_MAX_TEXT : title_length),
        (uint16_t)(owner_length > SWM_MAX_TEXT ? SWM_MAX_TEXT : owner_length),
        title,
        owner,
    };
    size_t n = swm_put_window(out, sizeof(out), &w);
    return n ? send_all(s->fd, out, n) : -1;
}

// Sends the rows that changed.
// shortcut: a whole-width band, so a blinking caret and a clock send everything between them; upgrade to tiles if this
// demo's traffic matters.
static int send_changes(struct Stream *s, uint8_t *pixels, uint32_t width, uint32_t height) {
    int resized = !s->previous;
    uint32_t first = 0, last = height ? height - 1 : 0;
    if (!resized) {
        while (first < height && !memcmp(pixels + first * width * 4, s->previous + first * width * 4, width * 4))
            first++;
        if (first == height) {
            free(pixels);
            return 0;
        }
        while (last > first && !memcmp(pixels + last * width * 4, s->previous + last * width * 4, width * 4))
            last--;
    }
    struct SWMFrame f = {s->window, ++s->sequence, width, height, 0, first, width, last - first + 1, NULL};
    uint8_t prefix[SWM_FRAME_PREFIX];
    swm_put_frame_prefix(prefix, &f);
    int failed = send_all(s->fd, prefix, sizeof(prefix)) ||
                 send_all(s->fd, pixels + first * width * 4, (size_t)width * f.height * 4);
    free(s->previous);
    s->previous = pixels;
    return failed ? -1 : 0;
}

static void activate_owner(struct Stream *s) {
    if (s->test_pattern)
        return;
    ProcessSerialNumber psn = {0, 0}, front = {0, 0};
    Boolean same = false;
    if (GetProcessForPID(s->pid, &psn) == noErr && GetFrontProcess(&front) == noErr &&
        (SameProcess(&psn, &front, &same) != noErr || !same)) {
        SetFrontProcessWithOptions(&psn, kSetFrontProcessFrontWindowOnly);
        usleep(50000); // Let the raise reach WindowServer, or the click lands on what was covering this window.
    }
}

static void post_pointer(struct Stream *s, const struct SWMPointer *e) {
    if (s->test_pattern) {
        if (e->kind == SWM_DOWN)
            s->clicks++;
        return;
    }
    CGPoint point = CGPointMake(s->bounds.origin.x + e->x / 16.0, s->bounds.origin.y + e->y / 16.0);
    CGEventType type;
    CGMouseButton button = e->button == 1   ? kCGMouseButtonRight
                           : e->button == 2 ? kCGMouseButtonCenter
                                            : kCGMouseButtonLeft;
    switch (e->kind) {
        case SWM_DOWN:
            activate_owner(s);
            type = e->button == 1   ? kCGEventRightMouseDown
                   : e->button == 2 ? kCGEventOtherMouseDown
                                    : kCGEventLeftMouseDown;
            s->buttons_down |= 1 << e->button;
            break;
        case SWM_UP:
            type = e->button == 1 ? kCGEventRightMouseUp : e->button == 2 ? kCGEventOtherMouseUp : kCGEventLeftMouseUp;
            s->buttons_down &= ~(1 << e->button);
            break;
        case SWM_DRAG:
            type = e->button == 1   ? kCGEventRightMouseDragged
                   : e->button == 2 ? kCGEventOtherMouseDragged
                                    : kCGEventLeftMouseDragged;
            break;
        default:
            type = kCGEventMouseMoved;
    }
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, point, button);
    if (!event)
        return;
    if (e->clicks)
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, e->clicks);
    CGEventSetFlags(event, (CGEventFlags)e->flags);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void post_key(struct Stream *s, const struct SWMKey *k) {
    if (s->test_pattern) {
        if (k->down)
            s->keys++;
        return;
    }
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, k->keycode, k->down != 0);
    if (!event)
        return;
    CGEventSetFlags(event, (CGEventFlags)k->flags);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

// Applies every whole message waiting on the socket. Returns -1 once the host has gone or sent something invalid.
static int drain_input(struct Stream *s) {
    ssize_t n = recv(s->fd, s->receive + s->received, sizeof(s->receive) - s->received, 0);
    if (n < 0 && errno == EINTR)
        return 0;
    if (n <= 0)
        return -1;
    s->received += (size_t)n;
    size_t offset = 0;
    for (;;) {
        struct SWMMessage m;
        size_t used = 0;
        enum SWMParse result = swm_parse(s->receive + offset, s->received - offset, &m, &used);
        if (result == SWM_BAD) {
            fputs("Invalid message from the host.\n", stderr);
            return -1;
        }
        if (result == SWM_NEED_MORE)
            break;
        if (m.type == SWM_POINTER)
            post_pointer(s, &m.u.pointer);
        else if (m.type == SWM_KEY)
            post_key(s, &m.u.key);
        else if (m.type == SWM_FOCUS)
            activate_owner(s);
        offset += used;
    }
    memmove(s->receive, s->receive + offset, s->received - offset);
    s->received -= offset;
    return 0;
}

static int connect_to(const char *host, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    if (fd < 0 || inet_pton(AF_INET, host, &address.sin_addr) != 1 ||
        connect(fd, (struct sockaddr *)&address, sizeof(address))) {
        fprintf(stderr, "Can't connect to %s:%d: %s\n", host, port, strerror(errno));
        return -1;
    }
    int on = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    return fd;
}

static int stream(struct Stream *s, double fps, double run_seconds) {
    char last_title[512] = "\x01";
    CGRect last_bounds = CGRectNull;
    uint32_t last_width = 0, last_height = 0;
    double capture = 0, longest = 0, sent_report = now(), started = now();
    unsigned captures = 0;
    for (;;) {
        double tick = now();
        if (run_seconds > 0 && tick - started > run_seconds)
            return 0;
        char title[512] = "seamless test pattern", owner[256] = "seamless-guest";
        int layer = 0;
        uint32_t width = 0, height = 0;
        uint8_t *pixels;
        if (s->test_pattern) {
            pixels = pattern_pixels(s, &width, &height);
            s->bounds = CGRectMake(0, 0, width, height);
        } else {
            CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, s->window);
            if (!info || !CFArrayGetCount(info)) {
                if (info)
                    CFRelease(info);
                uint8_t gone[SWM_HEADER_SIZE + SWM_GONE_SIZE];
                swm_put_u32_message(gone, sizeof(gone), SWM_GONE, s->window);
                send_all(s->fd, gone, sizeof(gone));
                fputs("The window closed.\n", stderr);
                return 0;
            }
            CFDictionaryRef d = CFArrayGetValueAtIndex(info, 0);
            text_for(d, kCGWindowName, title, sizeof(title));
            text_for(d, kCGWindowOwnerName, owner, sizeof(owner));
            layer = int_for(d, kCGWindowLayer);
            s->pid = int_for(d, kCGWindowOwnerPID);
            s->bounds = bounds_for(d);
            CFRelease(info);
            double before = now();
            CGImageRef image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, s->window,
                                                       kCGWindowImageBoundsIgnoreFraming);
            pixels = image ? copy_pixels(image, &width, &height) : NULL;
            if (image)
                CGImageRelease(image);
            double spent = now() - before;
            capture += spent;
            longest = spent > longest ? spent : longest;
            captures++;
            if (!pixels) {
                // Minimized or ordered out: keep the last picture and wait.
                usleep(100000);
                continue;
            }
        }
        if (width != last_width || height != last_height) {
            free(s->previous);
            s->previous = NULL;
        }
        if (width != last_width || height != last_height || strcmp(title, last_title) ||
            !CGRectEqualToRect(s->bounds, last_bounds)) {
            s->pixel_width = width;
            s->pixel_height = height;
            if (send_window(s, title, owner, layer)) {
                free(pixels);
                return 0;
            }
            snprintf(last_title, sizeof(last_title), "%s", title);
            last_bounds = s->bounds;
            last_width = width;
            last_height = height;
        }
        if (send_changes(s, pixels, width, height))
            return 0;
        if (captures && now() - sent_report > 5) {
            fprintf(stderr, "capture mean %.1f ms, worst %.1f ms, %u x %u, %u frames changed\n",
                    capture / captures * 1000, longest * 1000, width, height, s->sequence);
            capture = longest = 0;
            captures = 0;
            sent_report = now();
        }
        // Sleep to the next tick, waking at once for input, which is what keeps clicks responsive.
        for (;;) {
            double left = tick + 1 / fps - now();
            if (left <= 0)
                break;
            fd_set reads;
            FD_ZERO(&reads);
            FD_SET(s->fd, &reads);
            struct timeval timeout = {(time_t)left, (int)((left - (time_t)left) * 1e6)};
            int ready = select(s->fd + 1, &reads, NULL, NULL, &timeout);
            if (ready > 0 && drain_input(s))
                return 0;
        }
    }
}

static const char *option(int argc, char **argv, const char *name, const char *fallback) {
    for (int i = 2; i + 1 < argc; i++)
        if (!strcmp(argv[i], name))
            return argv[i + 1];
    return fallback;
}
static int flag(int argc, char **argv, const char *name) {
    for (int i = 2; i < argc; i++)
        if (!strcmp(argv[i], name))
            return 1;
    return 0;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    if (argc >= 2 && !strcmp(argv[1], "list"))
        return list_windows();
    if (argc < 2 || strcmp(argv[1], "stream")) {
        fputs("usage: seamless-guest list\n"
              "       seamless-guest stream (--app NAME | --window ID | --test-pattern)\n"
              "                      [--host 10.0.2.2] [--port 7654] [--fps 30] [--seconds N]\n",
              stderr);
        return 64;
    }
    struct Stream s;
    memset(&s, 0, sizeof(s));
    s.test_pattern = flag(argc, argv, "--test-pattern");
    const char *app = option(argc, argv, "--app", NULL), *window = option(argc, argv, "--window", NULL);
    s.window = s.test_pattern ? 1 : window ? (CGWindowID)strtoul(window, NULL, 10) : app ? find_window(app) : 0;
    if (!s.window) {
        fputs("No matching window. Try `seamless-guest list`.\n", stderr);
        return 1;
    }
    double fps = atof(option(argc, argv, "--fps", "30"));
    s.fd = connect_to(option(argc, argv, "--host", "10.0.2.2"), atoi(option(argc, argv, "--port", "7654")));
    if (s.fd < 0)
        return 1;
    uint8_t hello[SWM_HEADER_SIZE + SWM_HELLO_SIZE];
    swm_put_u32_message(hello, sizeof(hello), SWM_HELLO, SWM_VERSION);
    if (send_all(s.fd, hello, sizeof(hello)))
        return 1;
    return stream(&s, fps > 0 && fps <= 240 ? fps : 30, atof(option(argc, argv, "--seconds", "0")));
}
