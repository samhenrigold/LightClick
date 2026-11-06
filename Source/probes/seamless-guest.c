// Guest side of the seamless-window demo, for Mac OS X 10.9: lists windows, then streams one window's pixels and
// metadata to the host and replays the pointer and key events it sends back. Run it inside the Aqua session.
//
//     seamless-guest list
//     seamless-guest stream --app TextEdit [--window ID] [--host 10.0.2.2] [--port 7654] [--fps 30]
//     seamless-guest stream --test-pattern --host 127.0.0.1    Needs no WindowServer, for testing the path on the host.
//
// For scripts/seamless-try, which runs these through the guest agent. As root they re-enter the console session, as
// probes/gpu-bench.m does, and all of them report `name value unit` lines on stdout:
//
//     seamless-guest program [--app TextEdit] [--port 7654] [--seconds 20]    Opens the app and streams it.
//     seamless-guest open-app --app TextEdit
//     seamless-guest display --width W --height H [--scale 1]                 Selects a mode the host has offered.
//     seamless-guest place --app TextEdit (--x X --y Y | --slot N) [--moves K]    Moves its front window.
//     seamless-guest program-tree [--port 7654] [--seconds 20]                Streams the demo app's every window.
//     seamless-guest tree (--app NAME | --all) [--host H] [--port P] [--seconds N]    Streams every window of an app.
//     seamless-guest demo-app                                                 See seamless-demo-app.m.
//
// Only public CoreGraphics and HIServices. This is the demo, not the design: see
// seamless-apps-design.md for why per-window capture is the fallback rather than the plan.
#include "seamless-wire.h"
#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/IOKitLib.h>
#include <arpa/inet.h>
#include <bsm/audit.h>
#include <copyfile.h>
#include <servers/bootstrap.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <sys/mman.h>
#include "seamless-inject.h"
#include "seamless-slots.h"
#include "seamless-ws-table.h"
#include "../tools/guest-display-modes.h"

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

static CFIndex visible_windows(void) {
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    CFIndex count = windows ? CFArrayGetCount(windows) : -1;
    if (windows)
        CFRelease(windows);
    return count;
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
    if (fd < 0)
        return 0; // Measuring capture alone, with the host unreachable.
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
    unsigned pointer_events, key_events, gesture_events, menu_presses, captures, frames_changed;
    double capture_seconds, capture_worst;
    uint64_t bytes_sent;
    uint32_t order, group, alpha, margin;
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
        s->order,
        s->group,
        s->alpha ? s->alpha : 0x10000,
        s->margin,
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
    s->frames_changed++;
    s->bytes_sent += sizeof(prefix) + (uint64_t)width * f.height * 4;
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
    s->pointer_events++;
    if (s->test_pattern) {
        if (e->kind == SWM_DOWN)
            s->clicks++;
        return;
    }
    CGPoint point = e->window ? CGPointMake(s->bounds.origin.x + e->x / 16.0, s->bounds.origin.y + e->y / 16.0)
                              : CGPointMake(e->x / 16.0, e->y / 16.0);
    CGEventType type;
    CGMouseButton button = e->button == 1   ? kCGMouseButtonRight
                           : e->button == 2 ? kCGMouseButtonCenter
                                            : kCGMouseButtonLeft;
    switch (e->kind) {
        case SWM_DOWN:
            // In a tree, a click lands where it would on the guest's own screen, which is right whichever app owns it.
            if (e->window)
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
    s->key_events++;
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
// The app's menu comes from seamless-integration-guest, in a thread, as reading it through Accessibility can take a
// while under emulation and input mustn't wait for that. shortcut: rereads on a timer, where seamless-integration.md
// wants it on activation, focus and after input.
static const char *menu_tool, *menu_app;
static pthread_mutex_t menu_lock = PTHREAD_MUTEX_INITIALIZER;
static char *menu_json;
static double menu_read_ms;

static char *run_tool(char *const *arguments) {
    int ends[2];
    if (pipe(ends))
        return NULL;
    pid_t child = fork();
    if (child == 0) {
        dup2(ends[1], 1);
        close(ends[0]);
        close(ends[1]);
        execv(arguments[0], arguments);
        _exit(127);
    }
    close(ends[1]);
    size_t size = 0, capacity = 1 << 16;
    char *text = malloc(capacity);
    for (ssize_t n; text && (n = read(ends[0], text + size, capacity - size - 1)) > 0;) {
        size += (size_t)n;
        if (size + 1 >= capacity)
            text = realloc(text, capacity *= 2);
    }
    close(ends[0]);
    if (child > 0)
        waitpid(child, NULL, 0);
    if (text)
        text[size] = 0;
    return text;
}

static void *menu_thread(void *unused) {
    for (;;) {
        double before = now();
        char *const arguments[] = {(char *)menu_tool, "menu", "--app", (char *)menu_app, NULL};
        char *text = run_tool(arguments);
        // Its other lines are comments; the tree is the line that's an array.
        char *line = text;
        while (line && *line && *line != '[') {
            char *next = strchr(line, '\n');
            line = next ? next + 1 : NULL;
        }
        char *end = line ? strchr(line, '\n') : NULL;
        if (end)
            *end = 0;
        if (line && *line == '[') {
            pthread_mutex_lock(&menu_lock);
            free(menu_json);
            menu_json = strdup(line);
            menu_read_ms = (now() - before) * 1000;
            pthread_mutex_unlock(&menu_lock);
        }
        free(text);
        sleep(5);
    }
    return unused;
}

static int send_menu_if_new(struct Stream *s) {
    pthread_mutex_lock(&menu_lock);
    char *json = menu_json;
    menu_json = NULL;
    double spent = menu_read_ms;
    pthread_mutex_unlock(&menu_lock);
    if (!json)
        return 0;
    static char *last;
    int failed = 0;
    if (!last || strcmp(last, json)) {
        uint8_t header[SWM_HEADER_SIZE];
        size_t length = strlen(json);
        swm_header(header, SWM_MENU, (uint32_t)length);
        failed = send_all(s->fd, header, sizeof(header)) || send_all(s->fd, json, length);
        printf("# menu of %zu bytes read in %.0f ms\n", length, spent);
        free(last);
        last = json;
    } else
        free(json);
    return failed;
}

static void menu_press(struct Stream *s, const char *path, uint32_t length) {
    if (!menu_tool || length > 1000)
        return;
    char copy[1024];
    memcpy(copy, path, length);
    copy[length] = 0;
    char *const arguments[] = {(char *)menu_tool, "press", "--app", (char *)menu_app, "--path", copy, NULL};
    free(run_tool(arguments));
    printf("# pressed %s\n", copy);
    s->menu_presses++;
}

static int darwin_major_early(void) {
    char release[32] = "";
    size_t size = sizeof(release);
    sysctlbyname("kern.osrelease", release, &size, NULL, 0);
    return atoi(release);
}

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
        else if (m.type == SWM_MENU_PRESS)
            menu_press(s, (const char *)m.u.data.bytes, m.u.data.length);
        else if (m.type == SWM_GESTURE && !s->test_pattern) {
            // Apple's own route per generation: see seamless-input.md.
            static struct SWIContext context;
            context.mechanism = darwin_major_early() < 18 ? SWI_RECORD : SWI_SESSION;
            const struct SWMGesture *g = &m.u.gesture;
            CGPoint point = g->window ? CGPointMake(s->bounds.origin.x + g->x / 16.0, s->bounds.origin.y + g->y / 16.0)
                                      : CGPointMake(g->x / 16.0, g->y / 16.0);
            swi_gesture(&context, g, point);
            s->gesture_events++;
        } else if (m.type == SWM_FOCUS)
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
            s->capture_seconds += spent;
            s->capture_worst = spent > s->capture_worst ? spent : s->capture_worst;
            s->captures++;
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
            // At least one look per tick: a capture longer than a tick would otherwise starve input entirely.
            double left = tick + 1 / fps - now();
            int last_look = left <= 0;
            if (last_look)
                left = 0;
            if (s->fd < 0) {
                usleep((useconds_t)(left * 1e6));
                break;
            }
            fd_set reads;
            FD_ZERO(&reads);
            FD_SET(s->fd, &reads);
            struct timeval timeout = {(time_t)left, (int)((left - (time_t)left) * 1e6)};
            int ready = select(s->fd + 1, &reads, NULL, NULL, &timeout);
            if (ready > 0 && drain_input(s))
                return 0;
            if (last_look && ready <= 0)
                break;
        }
    }
}

static int darwin_major(void) {
    char release[32] = "";
    size_t size = sizeof(release);
    sysctlbyname("kern.osrelease", release, &size, NULL, 0);
    return atoi(release);
}

#include "seamless-console.h"

// Opens the app with a throwaway document, so TextEdit shows a window rather than an open panel, and waits for a
// window.
static CGWindowID open_app(const char *app) {
    char note[64];
    int safari = !strcmp(app, "Safari");
    snprintf(note, sizeof(note), "/tmp/seamless-note-%u.%s", getuid(), safari ? "html" : "txt");
    FILE *file = fopen(note, "w");
    if (file) {
        // A page the browser composites on the GPU, if it does at all: a layer that keeps moving.
        fputs(safari ? "<title>Seamless page</title><style>@-webkit-keyframes "
                       "m{to{-webkit-transform:translate3d(400px,0,0)}}"
                       "div{width:80px;height:80px;background:#28c;-webkit-animation:m 2s infinite alternate}</style>"
                       "<h1>A page in a guest browser</h1><div></div><p>Some text.</p>\n"
                     : "Seamless window test.\n",
              file);
        fclose(file);
    }
    pid_t child = fork();
    if (child == 0) {
        if (strcmp(app, "TextEdit") && !safari)
            execl("/usr/bin/open", "open", "-a", app, (char *)NULL);
        else
            execl("/usr/bin/open", "open", "-a", app, note, (char *)NULL);
        _exit(127);
    }
    if (child > 0)
        waitpid(child, NULL, 0);
    CGWindowID window = 0;
    for (double started = now(); !window && now() - started < 120; usleep(500000))
        window = find_window(app);
    if (!window)
        printf("# ERROR %s showed no window in 120 s\n", app);
    return window;
}

static int snapshot(CGWindowID window, char *title, size_t size, CGRect *bounds) {
    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, window);
    int found = info && CFArrayGetCount(info);
    if (found) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(info, 0);
        text_for(d, kCGWindowName, title, size);
        *bounds = bounds_for(d);
    }
    if (info)
        CFRelease(info);
    return found;
}

// The whole of phase 1 with nobody in the guest. The viewer's test input proves itself: a click on the zoom button
// changes the window's bounds. A typed key shows in the pixels: 10.9 doesn't put "Edited" in the window list's title.
static int program(const char *app, const char *host, int port, double fps, double seconds) {
    CGWindowID window = open_app(app);
    if (!window)
        return 1;
    sleep(2); // Past the opening animation, so the numbers aren't measuring it.
    window = find_window(app);
    char title_before[512] = "", title_after[512] = "";
    CGRect before = CGRectZero, after = CGRectZero;
    snapshot(window, title_before, sizeof(title_before), &before);
    printf("# window %u \"%s\" %gx%g\n", window, title_before, before.size.width, before.size.height);
    struct Stream s;
    memset(&s, 0, sizeof(s));
    s.window = window;
    s.fd = connect_to(host, port);
    if (s.fd < 0) {
        printf("# ERROR can't reach %s:%d (%s); measuring capture alone\n", host, port, strerror(errno));
    } else {
        uint8_t hello[SWM_HEADER_SIZE + SWM_HELLO_SIZE];
        swm_put_u32_message(hello, sizeof(hello), SWM_HELLO, SWM_VERSION);
        send_all(s.fd, hello, sizeof(hello));
    }
    double started = now();
    stream(&s, fps, seconds);
    double elapsed = now() - started;
    int alive = snapshot(window, title_after, sizeof(title_after), &after);
    printf("connected %d bool\n", s.fd >= 0);
    printf("capture_mean %.1f ms\n", s.captures ? s.capture_seconds / s.captures * 1000 : 0);
    printf("capture_worst %.1f ms\n", s.capture_worst * 1000);
    printf("capture_rate %.1f /s\n", s.captures / elapsed);
    printf("frames_changed %u count\n", s.frames_changed);
    printf("frames_sent_rate %.1f /s\n", s.fd >= 0 ? s.frames_changed / elapsed : 0);
    printf("sent %.2f MB/s\n", s.fd >= 0 ? s.bytes_sent / elapsed / 1e6 : 0);
    printf("window_pixels %u x%u\n", s.pixel_width, s.pixel_height);
    printf("pointer_events %u count\n", s.pointer_events);
    printf("key_events %u count\n", s.key_events);
    printf("click_changed_bounds %d bool\n", alive && !CGRectEqualToRect(before, after));
    printf("# title after: \"%s\"\n", title_after);
    return s.fd < 0 ? 3 : 0;
}

static size_t registry_number(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    long long result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)value, kCFNumberLongLongType, &result);
    if (value)
        CFRelease(value);
    return (size_t)result;
}

// As far as the mode list goes; the host's request should have put this size in it.
static void print_modes(CGDirectDisplayID display) {
    CFArrayRef modes = VIMGuestDisplayModes(display);
    size_t best_width = 0, best_height = 0, count = modes ? (size_t)CFArrayGetCount(modes) : 0;
    for (size_t i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, (CFIndex)i);
        if (CGDisplayModeGetPixelWidth(mode) * CGDisplayModeGetPixelHeight(mode) > best_width * best_height) {
            best_width = CGDisplayModeGetPixelWidth(mode);
            best_height = CGDisplayModeGetPixelHeight(mode);
        }
    }
    if (modes)
        CFRelease(modes);
    printf("# %zu modes, largest %zux%zu\n", count, best_width, best_height);
}

// One step of the display ladder. Exit status says how far it got: 2 not offered, 3 refused, 4 not retained.
static int display_step(size_t width, size_t height, size_t scale) {
    CGDirectDisplayID display = CGMainDisplayID();
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("VMsvga2"));
    if (service) {
        printf("# VMsvga2 last applied %zux%zu, generation %zu\n",
               registry_number(service, CFSTR("VIMNativePanelAppliedWidth")),
               registry_number(service, CFSTR("VIMNativePanelAppliedHeight")),
               registry_number(service, CFSTR("VIMNativePanelRequestGeneration")));
        IOObjectRelease(service);
    }
    VIMGuestDisplayMode selected = NULL;
    double started = now();
    while (!selected && now() - started < 20) {
        CFArrayRef modes = VIMGuestDisplayModes(display);
        for (CFIndex i = 0; modes && !selected && i < CFArrayGetCount(modes); i++) {
            VIMGuestDisplayMode mode = (VIMGuestDisplayMode)CFArrayGetValueAtIndex(modes, i);
            if (VIMGuestModeMatches(mode, width, height, scale))
                selected = CGDisplayModeRetain(mode);
        }
        if (modes)
            CFRelease(modes);
        if (!selected)
            usleep(200000);
    }
    print_modes(display);
    if (!selected) {
        printf("# ERROR %zux%zu at %zux was never offered\n", width, height, scale);
        return 2;
    }
    printf("mode_offered_after %.1f s\n", now() - started);
    started = now();
    CGError error = VIMGuestSetMode(display, selected);
    CGDisplayModeRelease(selected);
    if (error) {
        printf("# ERROR CoreGraphics refused the mode: %d\n", error);
        return 3;
    }
    int retained = 0;
    while (!retained && now() - started < 30) {
        VIMGuestDisplayMode current = VIMGuestCurrentMode(display);
        retained = VIMGuestModeMatches(current, width, height, scale);
        if (current)
            CGDisplayModeRelease(current);
        if (!retained)
            usleep(100000);
    }
    if (!retained) {
        puts("# ERROR the mode wasn't retained after 30 s");
        return 4;
    }
    printf("mode_switch %.2f s\n", now() - started);
    sleep(2);
    // A read through WindowServer's compositor, whose cost a larger framebuffer should show.
    started = now();
    CGImageRef image = CGDisplayCreateImage(display);
    double spent = now() - started;
    if (image) {
        printf("display_capture %.1f ms\n", spent * 1000);
        printf("display_capture_size %zu x%zu\n", CGImageGetWidth(image), CGImageGetHeight(image));
        CGImageRelease(image);
    } else
        puts("# ERROR no display image");
    CGRect bounds = CGDisplayBounds(display);
    printf("display_points %g x%g\n", bounds.size.width, bounds.size.height);
    return 0;
}

static AXUIElementRef ax_window_at(pid_t pid, CGRect bounds) {
    AXUIElementRef application = AXUIElementCreateApplication(pid), found = NULL;
    CFArrayRef windows = NULL;
    AXError error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute, (CFTypeRef *)&windows);
    if (error)
        printf("# ERROR Accessibility can't list the windows: %d (trusted: %d)\n", error, AXIsProcessTrusted());
    for (CFIndex i = 0; !error && windows && !found && i < CFArrayGetCount(windows); i++) {
        AXUIElementRef candidate = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        CFTypeRef position = NULL, size = NULL;
        CGPoint point = CGPointZero;
        CGSize extent = CGSizeZero;
        if (!AXUIElementCopyAttributeValue(candidate, kAXPositionAttribute, &position) &&
            !AXUIElementCopyAttributeValue(candidate, kAXSizeAttribute, &size)) {
            AXValueGetValue(position, kAXValueCGPointType, &point);
            AXValueGetValue(size, kAXValueCGSizeType, &extent);
            if (CGRectEqualToRect(CGRectMake(point.x, point.y, extent.width, extent.height), bounds))
                found = (AXUIElementRef)CFRetain(candidate);
        }
        if (position)
            CFRelease(position);
        if (size)
            CFRelease(size);
    }
    if (windows)
        CFRelease(windows);
    CFRelease(application);
    return found;
}

// Returns once WindowServer agrees, and how long that took, or -1 if it never did.
static double move_window(AXUIElementRef ax, CGWindowID window, CGPoint target) {
    double started = now();
    AXValueRef value = AXValueCreate(kAXValueCGPointType, &target);
    AXError error = AXUIElementSetAttributeValue(ax, kAXPositionAttribute, value);
    CFRelease(value);
    if (error) {
        printf("# ERROR setting the position: %d\n", error);
        return -1;
    }
    char title[8];
    CGRect bounds = CGRectZero;
    while (now() - started < 3) {
        if (snapshot(window, title, sizeof(title), &bounds) && CGPointEqualToPoint(bounds.origin, target))
            return now() - started;
        usleep(2000);
    }
    printf("# ERROR the window stayed at %g,%g, not %g,%g\n", bounds.origin.x, bounds.origin.y, target.x, target.y);
    return -1;
}

static int place(const char *app, double x, double y, int slot, int slot_width, int slot_height, int moves) {
    CGWindowID window = find_window(app);
    if (!window) {
        printf("# ERROR no window of %s\n", app);
        return 1;
    }
    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, window);
    if (!info || !CFArrayGetCount(info))
        return 1;
    pid_t pid = int_for(CFArrayGetValueAtIndex(info, 0), kCGWindowOwnerPID);
    CGRect bounds = bounds_for(CFArrayGetValueAtIndex(info, 0));
    CFRelease(info);
    if (slot >= 0) {
        CGRect screen = CGDisplayBounds(CGMainDisplayID());
        struct SWMSlotLayout layout = {(int)screen.size.width, (int)screen.size.height, slot_width, slot_height,
                                       SWM_SLOT_DEFAULT_GAP};
        int sx, sy;
        if (!swm_slot_origin(&layout, slot, &sx, &sy)) {
            printf("# ERROR slot %d doesn't fit a %dx%d display\n", slot, layout.display_width, layout.display_height);
            return 2;
        }
        x = sx;
        y = sy;
    }
    AXUIElementRef ax = ax_window_at(pid, bounds);
    if (!ax) {
        puts("# ERROR no Accessibility window matches the WindowServer window");
        return 5;
    }
    CGPoint target = CGPointMake(x, y);
    double spent = move_window(ax, window, target);
    int result = spent < 0 ? 6 : 0;
    if (!result) {
        printf("place_ok 1 bool\n");
        printf("place_time %.1f ms\n", spent * 1000);
        printf("# window %u now at %g,%g\n", window, x, y);
    }
    double total = 0, worst = 0;
    for (int i = 0; !result && i < moves; i++) {
        target.x = x + (i % 2 ? 0 : 16);
        spent = move_window(ax, window, target);
        if (spent < 0)
            result = 6;
        total += spent;
        worst = spent > worst ? spent : worst;
    }
    if (!result && moves) {
        move_window(ax, window, CGPointMake(x, y));
        printf("move_mean %.1f ms\n", total / moves * 1000);
        printf("move_worst %.1f ms\n", worst * 1000);
    }
    CFRelease(ax);
    return result;
}

// The whole window tree, as the guest's screen has it: every window is its own surface, with its shadow and alpha, at
// its guest position, whether or not something covers it. This uses only WindowServer's client interface, so it needs
// no hook; seamless-apps-design.md says what a hook adds. It's the source a hook would replace.
#define TREE_MAX_WINDOWS 64
// Wider than an active 10.9 window shadow, which 48 points clipped [measured], so the capture rectangle holds all of it
// and its position is known.
#define TREE_SHADOW_MARGIN 96

struct TreeWindow {
    CGWindowID id;
    uint32_t seed, order;
    int alpha;
    CGRect bounds;
    char title[256];
    uint8_t *previous;
    uint32_t pixel_width, pixel_height;
    double last_capture;
    int seen, announced;
    pid_t pid;
    uint32_t hook_sequence;
    uint8_t *hook_rows; // The last backing read from the hook, to find which rows changed.
    uint32_t hook_width, hook_height;
    unsigned captures;
    uint32_t shadow_key;
    int margin;
};

static struct SWSTable *tree_table;
static uint64_t hook_frames, hook_rows_copied, hook_match_good, hook_match_total, hook_seed_skips;
static double hook_seconds;

// An opaque pixel's color should agree between a capture and the backing store, if the hook reads what it thinks it
// reads: right window, right row order, right scale. Sampled, as a check on the whole approach.
static void hook_compare(const uint8_t *pixels, uint32_t width, uint32_t origin, const struct SWSEntry *e,
                         const uint8_t *backing) {
    for (uint32_t y = 2; y < e->height; y += 7)
        for (uint32_t x = 2; x < e->width; x += 11) {
            const uint8_t *b = backing + ((size_t)y * e->width + x) * 4;
            if (b[3] != 255 && !e->opaque)
                continue;
            const uint8_t *p = pixels + ((size_t)(y + origin) * width + x + origin) * 4;
            hook_match_total++;
            hook_match_good += abs(b[0] - p[0]) < 12 && abs(b[1] - p[1]) < 12 && abs(b[2] - p[2]) < 12;
        }
}

// Lays the backing's changed rows over the last frame, keeping what's under its clear corners, which is the shadow.
// Returns a new frame, or NULL if nothing visible changed.
static uint8_t *hook_overlay(struct TreeWindow *w, const struct SWSEntry *e, uint32_t origin) {
    const uint8_t *backing = tree_table->arena + e->offset;
    size_t row = (size_t)e->width * 4, size = row * e->height;
    if (!w->hook_rows || w->hook_width != e->width || w->hook_height != e->height) {
        free(w->hook_rows);
        w->hook_rows = calloc(1, size);
        w->hook_width = e->width;
        w->hook_height = e->height;
        if (!w->hook_rows)
            return NULL;
    }
    uint8_t *pixels = NULL;
    size_t stride = (size_t)w->pixel_width * 4;
    for (uint32_t y = 0; y < e->height; y++) {
        const uint8_t *from = backing + y * row;
        if (!memcmp(from, w->hook_rows + y * row, row))
            continue;
        if (!pixels) {
            pixels = malloc(stride * w->pixel_height);
            if (!pixels)
                return NULL;
            memcpy(pixels, w->previous, stride * w->pixel_height);
        }
        memcpy(w->hook_rows + y * row, from, row);
        hook_rows_copied++;
        uint8_t *to = pixels + (size_t)(y + origin) * stride + (size_t)origin * 4;
        for (uint32_t x = 0; x < e->width; x++, from += 4, to += 4)
            if (from[3] == 255 || e->opaque) {
                memcpy(to, from, 3);
                to[3] = 255;
            }
    }
    return pixels;
}

static int (*tree_connection)(void);
static int (*tree_flush_seed)(int, CGWindowID, uint32_t *);
static CFArrayRef (*tree_associated)(int, CGWindowID);

static void *guest_symbol(const char *cgs, const char *sls) {
    void *found = dlsym(RTLD_DEFAULT, cgs);
    return found ? found : dlsym(RTLD_DEFAULT, sls);
}

static uint32_t tree_group(CGWindowID id) {
    if (!tree_associated || !tree_connection)
        return 0;
    CFArrayRef list = tree_associated(tree_connection(), id);
    uint32_t lowest = 0;
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
        CFTypeRef value = CFArrayGetValueAtIndex(list, i);
        int number = 0;
        if (CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberGetValue(value, kCFNumberIntType, &number) &&
            number > 0 && (!lowest || (uint32_t)number < lowest))
            lowest = (uint32_t)number;
    }
    if (list)
        CFRelease(list);
    return lowest;
}

static int tree_wants(CFDictionaryRef d, const char *app, pid_t pid) {
    char owner[256];
    text_for(d, kCGWindowOwnerName, owner, sizeof(owner));
    CGRect bounds = bounds_for(d);
    if (bounds.size.width < 1 || bounds.size.height < 1 || int_for(d, kCGWindowLayer) < 0)
        return 0;
    if (pid > 0)
        return int_for(d, kCGWindowOwnerPID) == pid;
    if (app)
        return !strcmp(owner, app);
    return strcmp(owner, "Window Server") && strcmp(owner, "Dock") && strcmp(owner, "SystemUIServer");
}

#define TREE_ITEMS 128
// One window to show, from whichever source.
struct TreeItem {
    CGWindowID id;
    pid_t pid;
    int layer, alpha, margin, has_surfaces;
    uint32_t shadow_key;
    CGRect bounds;
    char title[256], owner[256];
};

static int tree_item_from_dictionary(CFDictionaryRef d, struct TreeItem *item) {
    item->id = (CGWindowID)int_for(d, kCGWindowNumber);
    item->pid = int_for(d, kCGWindowOwnerPID);
    item->layer = int_for(d, kCGWindowLayer);
    item->bounds = bounds_for(d);
    text_for(d, kCGWindowName, item->title, sizeof(item->title));
    text_for(d, kCGWindowOwnerName, item->owner, sizeof(item->owner));
    double alpha = 1;
    CFNumberRef number = number_for(d, kCGWindowAlpha);
    if (number)
        CFNumberGetValue(number, kCFNumberDoubleType, &alpha);
    item->alpha = (int)(alpha * 0x10000);
    item->margin = TREE_SHADOW_MARGIN;
    item->has_surfaces = 0;
    item->shadow_key = 0;
    return 1;
}

static int tree_items_from_list(struct TreeItem *items, const char *app, pid_t pid) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    int count = 0;
    for (CFIndex i = 0; list && count < TREE_ITEMS && i < CFArrayGetCount(list); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(list, i);
        if (tree_wants(d, app, pid))
            tree_item_from_dictionary(d, &items[count++]);
    }
    if (list)
        CFRelease(list);
    return count;
}

// Names and titles only exist in the window list, and don't change every frame.
static struct TreeItem tree_names[TREE_ITEMS];
static int tree_name_count;
static double tree_names_read;
static uint64_t hook_bounds_checked, hook_bounds_wrong, hook_order_checked, hook_order_wrong;
static int hook_order_front_first = -1;

static const struct TreeItem *tree_name_for(CGWindowID id) {
    for (int i = 0; i < tree_name_count; i++)
        if (tree_names[i].id == id)
            return &tree_names[i];
    return NULL;
}

static void tree_read_names(void) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    tree_name_count = 0;
    for (CFIndex i = 0; list && tree_name_count < TREE_ITEMS && i < CFArrayGetCount(list); i++)
        tree_item_from_dictionary(CFArrayGetValueAtIndex(list, i), &tree_names[tree_name_count++]);
    if (list)
        CFRelease(list);
    tree_names_read = now();
}

// The window tree, from WindowServer's own structures. The window list is only read for titles, once a second or for a
// window it hasn't named yet, and every read is also a check of the hook's bounds and order against the public answer.
static int tree_items_from_hook(struct TreeItem *items, const char *app, pid_t pid) {
    static struct SWSTreeEntry tree[SWS_TREE], incoming[SWS_TREE];
    static uint32_t count;
    static int (*connection_pid)(int, int *);
    if (!connection_pid)
        connection_pid = guest_symbol("CGSConnectionGetPID", "SLSConnectionGetPID");
    // A walk takes a while under emulation, so a read can miss. Then the last good one stands: an empty answer would
    // look as if every window had closed.
    for (int attempt = 0; attempt < 20; attempt++, usleep(500)) {
        uint32_t before = tree_table->tree_generation;
        if (before & 1)
            continue;
        uint32_t incoming_count = tree_table->tree_count;
        if (incoming_count > SWS_TREE)
            continue;
        memcpy(incoming, tree_table->tree, incoming_count * sizeof(incoming[0]));
        if (tree_table->tree_generation == before) {
            memcpy(tree, incoming, incoming_count * sizeof(tree[0]));
            count = incoming_count;
            break;
        }
    }
    int reread = now() - tree_names_read > 1;
    for (uint32_t i = 0; i < count && !reread; i++)
        reread = tree[i].width > 0 && !tree_name_for(tree[i].id);
    if (reread) {
        tree_read_names();
        // Which way round the walk runs is a fact of this build: settle it from two windows the list also has.
        for (uint32_t i = 0; hook_order_front_first < 0 && i + 1 < count; i++) {
            int a = -1, b = -1;
            for (int k = 0; k < tree_name_count; k++) {
                a = tree_names[k].id == tree[i].id ? k : a;
                b = tree_names[k].id == tree[i + 1].id ? k : b;
            }
            if (a >= 0 && b >= 0)
                hook_order_front_first = a < b;
        }
        int last = -1;
        for (uint32_t step = 0; step < count; step++) {
            const struct SWSTreeEntry *t = &tree[hook_order_front_first == 0 ? count - 1 - step : step];
            const struct TreeItem *named = tree_name_for(t->id);
            if (!named)
                continue;
            hook_bounds_checked++;
            hook_bounds_wrong += named->bounds.origin.x != t->x || named->bounds.origin.y != t->y ||
                                 named->bounds.size.width != t->width || named->bounds.size.height != t->height ||
                                 named->layer != t->level;
            int place = (int)(named - tree_names);
            hook_order_checked++;
            hook_order_wrong += place < last;
            last = place;
        }
    }
    int produced = 0;
    for (uint32_t step = 0; step < count && produced < TREE_ITEMS; step++) {
        const struct SWSTreeEntry *t = &tree[hook_order_front_first == 0 ? count - 1 - step : step];
        const struct TreeItem *named = tree_name_for(t->id);
        if (!named || t->width < 1 || t->height < 1 || t->level < 0)
            continue;
        int owner_pid = named->pid;
        if (connection_pid && !owner_pid)
            connection_pid((int)t->connection, &owner_pid);
        if (pid > 0 ? owner_pid != pid
            : app   ? strcmp(named->owner, app)
                    : !strcmp(named->owner, "Window Server") || !strcmp(named->owner, "Dock") ||
                        !strcmp(named->owner, "SystemUIServer"))
            continue;
        struct TreeItem *item = &items[produced++];
        *item = *named;
        item->pid = owner_pid;
        item->layer = t->level;
        item->alpha = (int)(t->alpha * 0x10000);
        item->bounds = CGRectMake(t->x, t->y, t->width, t->height);
        item->margin = (int)t->margin + 2;
        item->has_surfaces = (int)t->has_surfaces;
        item->shadow_key = t->shadow_key;
    }
    return produced;
}

// With `pid`, only that process's windows. The clock starts at the first window, since an app can take a long time to
// start under emulation, and a run that sees none says what it did see.
static int stream_tree(struct Stream *s, const char *app, pid_t pid, double fps, double seconds) {
    tree_connection = guest_symbol("CGSMainConnectionID", "SLSMainConnectionID");
    tree_flush_seed = guest_symbol("CGSGetWindowFlushSeed", "SLSGetWindowFlushSeed");
    tree_associated = guest_symbol("CGSCopyAssociatedWindows", "SLSCopyAssociatedWindows");
    printf("# seeds %s, groups %s\n", tree_flush_seed ? "yes" : "NO", tree_associated ? "yes" : "NO");
    struct TreeWindow windows[TREE_MAX_WINDOWS];
    memset(windows, 0, sizeof(windows));
    unsigned skipped = 0, roster = 0, seed_answers = 0;
    double first_window = 0;
    double started = now();
    static struct TreeItem items[TREE_ITEMS];
    for (;;) {
        double tick = now();
        if (!roster && tick - started > 180) {
            puts("# ERROR no matching window in 180 s. Everything on screen:");
            list_windows();
            if (pid > 0) {
                int status = 0;
                printf("# the app %s\n", waitpid(pid, &status, WNOHANG) == pid ? "has exited" : "is still running");
            }
            break;
        }
        if (seconds > 0 && roster && tick - first_window > seconds)
            break;
        if (send_menu_if_new(s))
            goto done;
        int item_count = tree_table ? tree_items_from_hook(items, app, pid) : tree_items_from_list(items, app, pid);
        for (int i = 0; i < TREE_MAX_WINDOWS; i++)
            windows[i].seen = 0;
        uint32_t order = 0;
        for (int i = 0; i < item_count; i++) {
            const struct TreeItem *item = &items[i];
            CGWindowID id = item->id;
            struct TreeWindow *w = NULL;
            for (int k = 0; !w && k < TREE_MAX_WINDOWS; k++)
                if (windows[k].id == id)
                    w = &windows[k];
            for (int k = 0; !w && k < TREE_MAX_WINDOWS; k++)
                if (!windows[k].id)
                    w = &windows[k];
            if (!w)
                continue;
            int fresh = w->id != id;
            w->id = id;
            w->seen = 1;
            w->pid = item->pid;
            CGRect bounds = item->bounds;
            const char *title = item->title, *owner = item->owner;
            int alpha = item->alpha, layer = item->layer;
            int margin = item->margin;
            int moved = !CGRectEqualToRect(bounds, w->bounds),
                sized = !CGSizeEqualToSize(bounds.size, w->bounds.size) || margin != w->margin;
            uint32_t seed = 0;
            int have_seed = tree_flush_seed && tree_connection && !tree_flush_seed(tree_connection(), id, &seed);
            seed_answers += have_seed;
            // A seed doesn't cover GL or video surfaces in a window, so look anyway once a second.
            int stale = !have_seed || seed != w->seed || sized || fresh || !w->previous || tick - w->last_capture > 1;
            struct SWSEntry *entry = tree_table ? &tree_table->slots[w - windows] : NULL;
            if (entry) {
                entry->id = id;
                // A capture only for what the backing doesn't hold: the shadow when it changes, and GL or video always.
                if (entry->present && !entry->accelerated && entry->width && !fresh && !sized && w->previous)
                    stale = item->has_surfaces || item->shadow_key != w->shadow_key;
            }
            s->window = id;
            s->pid = w->pid;
            s->bounds = bounds;
            s->order = order;
            s->alpha = (uint32_t)alpha;
            s->margin = margin;
            if (!stale) {
                skipped++;
                uint32_t scale =
                    bounds.size.width > 0 ? (uint32_t)(w->pixel_width / (bounds.size.width + 2 * margin) + 0.5) : 0;
                if (entry && scale && entry->sequence != w->hook_sequence &&
                    entry->width == bounds.size.width * scale && entry->height == bounds.size.height * scale) {
                    w->hook_sequence = entry->sequence;
                    double before = now();
                    uint8_t *pixels = hook_overlay(w, entry, margin * scale);
                    hook_seconds += now() - before;
                    if (pixels) {
                        hook_frames++;
                        s->pixel_width = w->pixel_width;
                        s->pixel_height = w->pixel_height;
                        s->previous = w->previous;
                        if (send_changes(s, pixels, w->pixel_width, w->pixel_height)) {
                            w->previous = NULL;
                            goto done;
                        }
                        w->previous = s->previous;
                        s->previous = NULL;
                    }
                }
            } else {
                CGRect rect = CGRectInset(bounds, -margin, -margin);
                double before = now();
                CGImageRef image =
                    CGWindowListCreateImage(rect, kCGWindowListOptionIncludingWindow, id, kCGWindowImageDefault);
                uint32_t width = 0, height = 0;
                uint8_t *pixels = image ? copy_pixels(image, &width, &height) : NULL;
                if (image)
                    CGImageRelease(image);
                double spent = now() - before;
                s->capture_seconds += spent;
                s->capture_worst = spent > s->capture_worst ? spent : s->capture_worst;
                s->captures++;
                w->last_capture = tick;
                w->captures++;
                w->seed = seed;
                w->shadow_key = item->shadow_key;
                w->margin = margin;
                if (!pixels) {
                    order++;
                    continue;
                }
                if (width != w->pixel_width || height != w->pixel_height) {
                    free(w->previous);
                    w->previous = NULL;
                }
                int resend = fresh || moved || !w->announced || order != w->order || alpha != w->alpha ||
                             strcmp(title, w->title) || width != w->pixel_width || height != w->pixel_height;
                s->pixel_width = w->pixel_width = width;
                s->pixel_height = w->pixel_height = height;
                if (resend) {
                    s->group = tree_group(id);
                    if (send_window(s, title, owner, layer)) {
                        free(pixels);
                        goto done;
                    }
                    w->announced = 1;
                }
                if (entry && entry->present && !entry->accelerated && entry->width && !item->has_surfaces) {
                    uint32_t scale = (uint32_t)(width / (bounds.size.width + 2 * margin) + 0.5);
                    if (entry->width == bounds.size.width * scale && entry->height == bounds.size.height * scale) {
                        hook_compare(pixels, width, margin * scale, entry, tree_table->arena + entry->offset);
                        w->hook_sequence = entry->sequence;
                        free(w->hook_rows);
                        w->hook_rows = malloc((size_t)entry->width * entry->height * 4);
                        if (w->hook_rows)
                            memcpy(w->hook_rows, tree_table->arena + entry->offset,
                                   (size_t)entry->width * entry->height * 4);
                        w->hook_width = entry->width;
                        w->hook_height = entry->height;
                    }
                }
                s->previous = w->previous;
                if (send_changes(s, pixels, width, height)) {
                    w->previous = NULL;
                    goto done;
                }
                w->previous = s->previous;
                s->previous = NULL;
                if (fresh) {
                    if (!roster)
                        first_window = tick;
                    roster++;
                    printf("# window %u layer %d %s \"%s\" %gx%g group %u at %.1f s\n", id, layer, owner, title,
                           bounds.size.width, bounds.size.height, s->group, tick - started);
                }
                w->bounds = bounds;
                w->order = order;
                w->alpha = alpha;
                snprintf(w->title, sizeof(w->title), "%s", title);
                order++;
                continue;
            }
            if (moved || order != w->order || alpha != w->alpha) {
                s->pixel_width = w->pixel_width;
                s->pixel_height = w->pixel_height;
                s->group = tree_group(id);
                if (send_window(s, title, owner, layer))
                    goto done;
                w->bounds = bounds;
                w->order = order;
                w->alpha = alpha;
            }
            order++;
        }
        for (int i = 0; i < TREE_MAX_WINDOWS; i++)
            if (windows[i].id && !windows[i].seen) {
                uint8_t gone[SWM_HEADER_SIZE + SWM_GONE_SIZE];
                swm_put_u32_message(gone, sizeof(gone), SWM_GONE, windows[i].id);
                if (send_all(s->fd, gone, sizeof(gone)))
                    goto done;
                if (tree_table)
                    hook_seed_skips += tree_table->slots[i].seed_skips;
                free(windows[i].previous);
                free(windows[i].hook_rows);
                memset(&windows[i], 0, sizeof(windows[i]));
                if (tree_table)
                    memset(&tree_table->slots[i], 0, sizeof(tree_table->slots[i]));
            }
        for (;;) {
            // At least one look per tick: a capture longer than a tick would otherwise starve input entirely.
            double left = tick + 1 / fps - now();
            int last_look = left <= 0;
            if (last_look)
                left = 0;
            if (s->fd < 0) {
                usleep((useconds_t)(left * 1e6));
                break;
            }
            fd_set reads;
            FD_ZERO(&reads);
            FD_SET(s->fd, &reads);
            struct timeval timeout = {(time_t)left, (int)((left - (time_t)left) * 1e6)};
            int ready = select(s->fd + 1, &reads, NULL, NULL, &timeout);
            if (ready > 0 && drain_input(s))
                goto done;
            if (last_look && ready <= 0)
                break;
        }
    }
done:;
    for (int i = 0; tree_table && i < TREE_MAX_WINDOWS && i < SWS_SLOTS; i++) {
        const struct SWSEntry *e = &tree_table->slots[i];
        hook_seed_skips += e->seed_skips;
        // Anything that isn't "backing" here is being captured instead, and is what the hook has left to do.
        if (e->id)
            printf("# window %u: %s, backing %ux%u, %u changes, captures %u, on %s\n", e->id,
                   !e->present      ? "no backing"
                   : e->accelerated ? "accelerated"
                                    : "backing",
                   e->width, e->height, e->sequence, windows[i].captures, windows[i].title);
    }
    double elapsed = now() - started;
    printf("connected %d bool\n", s->fd >= 0);
    printf("windows_seen %u count\n", roster);
    printf("capture_mean %.1f ms\n", s->captures ? s->capture_seconds / s->captures * 1000 : 0);
    printf("capture_worst %.1f ms\n", s->capture_worst * 1000);
    printf("capture_rate %.1f /s\n", s->captures / elapsed);
    printf("captures_skipped_by_seed %u count\n", skipped);
    printf("seed_answers %u count\n", seed_answers);
    printf("frames_sent_rate %.1f /s\n", s->frames_changed / elapsed);
    printf("sent %.2f MB/s\n", s->bytes_sent / elapsed / 1e6);
    printf("capture_share %.0f %%\n", s->capture_seconds / elapsed * 100);
    printf("input %u pointer, %u key, %u gesture\n", s->pointer_events, s->key_events, s->gesture_events);
    if (tree_table) {
        printf("hook_frames %llu count\n", hook_frames);
        printf("hook_frames_rate %.1f /s\n", hook_frames / elapsed);
        printf("hook_rows_applied %llu count\n", hook_rows_copied);
        printf("hook_tool_share %.1f %%\n", hook_seconds / elapsed * 100);
        printf("hook_matches_capture %.1f %% of %llu samples\n",
               hook_match_total ? 100.0 * hook_match_good / hook_match_total : 0, hook_match_total);
        printf("hook_passes %llu count\n", tree_table->passes);
        printf("hook_seed_skips %llu count\n", hook_seed_skips);
        printf("hook_tree_order %s\n", hook_order_front_first == 1   ? "front-first"
                                       : hook_order_front_first == 0 ? "back-first"
                                                                     : "unknown");
        printf("hook_bounds_wrong %llu of %llu\n", hook_bounds_wrong, hook_bounds_checked);
        printf("hook_order_wrong %llu of %llu\n", hook_order_wrong, hook_order_checked);
        printf("hook_windowserver_time %.2f s\n",
               (double)tree_table->ticks_spent * tree_table->ticks_numer / tree_table->ticks_denom / 1e9);
    }
    return 0;
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
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *command = argc >= 2 ? argv[1] : "";
    int in_session = flag(argc, argv, "--in-session");
    const char *app = option(argc, argv, "--app", "TextEdit");
    if (!strcmp(command, "diag")) {
        printf("# uid %d euid %d\n", getuid(), geteuid());
        CFDictionaryRef session = CGSessionCopyCurrentDictionary();
        printf("# session dictionary %s\n", session ? "present" : "NULL");
        if (session)
            CFRelease(session);
        mach_port_t port = MACH_PORT_NULL;
        kern_return_t active = bootstrap_look_up(bootstrap_port, "com.apple.windowserver.active", &port);
        kern_return_t server = bootstrap_look_up(bootstrap_port, "com.apple.windowserver", &port);
        printf("# look_up active %d, server %d\n", active, server);
        auditinfo_addr_t audit;
        memset(&audit, 0, sizeof(audit));
        getaudit_addr(&audit, sizeof(audit));
        printf("# audit session %d\n", audit.ai_asid);
        printf("# windows visible %ld\n", (long)visible_windows());
        int (*main_connection)(void) = guest_symbol("CGSMainConnectionID", "SLSMainConnectionID");
        CGRect bounds = CGDisplayBounds(CGMainDisplayID());
        printf("# connection %d, display %u, %gx%g\n", main_connection ? main_connection() : -1, CGMainDisplayID(),
               bounds.size.width, bounds.size.height);
        list_windows();
        return 0;
    }
    if (!strcmp(command, "list"))
        return list_windows();
    if (!strcmp(command, "program-gl") || !strcmp(command, "png-window")) {
        if (geteuid() == 0 && !in_session)
            return run_in_console_session(argc, argv, 1);
        if (!strcmp(command, "png-window")) {
            CGWindowID window = find_window(app);
            CGImageRef image = window ? CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, window,
                                                                kCGWindowImageDefault)
                                      : NULL;
            uint32_t width = 0, height = 0;
            uint8_t *pixels = image ? copy_pixels(image, &width, &height) : NULL;
            printf("window %u image %ux%u, middle pixel BGRA", window, width, height);
            if (pixels) {
                const uint8_t *m = pixels + ((size_t)height / 2 * width + width / 2) * 4;
                printf(" %02x%02x%02x%02x", m[0], m[1], m[2], m[3]);
            }
            puts("");
            return 0;
        }
        extern int seamless_gl_demo_main(void);
        return seamless_gl_demo_main();
    }
    if (!strcmp(command, "gl-demo")) {
        extern int seamless_gl_demo_main(void);
        return seamless_gl_demo_main();
    }
    if (!strcmp(command, "demo-app")) {
        extern int seamless_demo_app_main(void);
        return seamless_demo_app_main();
    }
    if (!strcmp(command, "tree") || !strcmp(command, "program-tree")) {
        // Only ever reads windows, so it's safe on the host; the program form opens an app, so it isn't.
        int demo = !strcmp(command, "program-tree");
        if (demo && darwin_major() > 20)
            return 64;
        if (geteuid() == 0 && !in_session)
            return run_in_console_session(argc, argv, 1);
        alarm(600);
        pid_t child = 0, gl_child = 0;
        if (demo) {
            char self[PATH_MAX];
            uint32_t length = sizeof(self);
            child = _NSGetExecutablePath(self, &length) ? -1 : fork();
            if (child == 0) {
                execl(self, "seamless-guest", "demo-app", (char *)NULL);
                _exit(127);
            }
            if (flag(argc, argv, "--gl") && !(gl_child = fork())) {
                execl(self, "seamless-guest", "gl-demo", (char *)NULL);
                _exit(127);
            }
        }
        struct Stream s;
        memset(&s, 0, sizeof(s));
        s.fd = connect_to(option(argc, argv, "--host", "10.0.2.2"), atoi(option(argc, argv, "--port", "7654")));
        if (s.fd < 0)
            printf("# ERROR can't reach the host (%s); measuring capture alone\n", strerror(errno));
        else {
            uint8_t hello[SWM_HEADER_SIZE + SWM_HELLO_SIZE];
            swm_put_u32_message(hello, sizeof(hello), SWM_HELLO, SWM_VERSION);
            send_all(s.fd, hello, sizeof(hello));
        }
        const char *target = flag(argc, argv, "--all") ? NULL : gl_child ? "seamless-guest" : app;
        if (flag(argc, argv, "--open") && !open_app(app))
            return 1;
        menu_tool = option(argc, argv, "--menu-tool", NULL);
        menu_app = app;
        if (menu_tool) {
            pthread_t thread;
            pthread_create(&thread, NULL, menu_thread, NULL);
        }
        if (flag(argc, argv, "--hook")) {
            int fd = open(SWS_PATH, O_RDWR);
            void *mapped =
                fd >= 0 ? mmap(NULL, sizeof(struct SWSTable), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) : MAP_FAILED;
            if (mapped != MAP_FAILED && ((struct SWSTable *)mapped)->magic == SWS_MAGIC) {
                tree_table = mapped;
                memset(tree_table->slots, 0, sizeof(tree_table->slots));
                tree_table->arena_used = 0;
            } else
                printf("# ERROR no hook table: %s\n", strerror(errno));
        }
        int result = stream_tree(&s, target, demo && !gl_child ? child : 0, atof(option(argc, argv, "--fps", "30")),
                                 atof(option(argc, argv, "--seconds", "20")));
        if (gl_child > 0) {
            // A GL app in trouble says where, before it goes.
            char command_line[128];
            snprintf(command_line, sizeof(command_line),
                     "/usr/bin/sample %d 2 -file /tmp/seamless-gl.sample >/dev/null 2>&1", gl_child);
            system(command_line);
            FILE *report = fopen("/tmp/seamless-gl.sample", "r");
            char line[220];
            for (int i = 0; report && i < 70 && fgets(line, sizeof(line), report); i++)
                printf("# sample: %s", line);
            if (report)
                fclose(report);
            kill(gl_child, SIGTERM);
        }
        if (child > 0)
            kill(child, SIGTERM);
        return s.fd < 0 ? 3 : result;
    }
    if (!strcmp(command, "program") || !strcmp(command, "open-app") || !strcmp(command, "display")) {
        // These steal the pointer or change the display, so they can't be left to run on the host by accident. Big Sur
        // is Darwin 20.
        if (darwin_major() > 20) {
            fputs("This is for a guest. See scripts/test-seamless-probes for the host.\n", stderr);
            return 64;
        }
        if (geteuid() == 0 && !in_session)
            return run_in_console_session(argc, argv, 1);
        alarm(600); // Partial results beat the agent timing out and losing them all.
        if (!strcmp(command, "program"))
            return program(app, option(argc, argv, "--host", "10.0.2.2"), atoi(option(argc, argv, "--port", "7654")),
                           atof(option(argc, argv, "--fps", "30")), atof(option(argc, argv, "--seconds", "20")));
        if (!strcmp(command, "open-app"))
            return open_app(app) ? 0 : 1;
        size_t width = strtoul(option(argc, argv, "--width", "0"), NULL, 10);
        size_t height = strtoul(option(argc, argv, "--height", "0"), NULL, 10);
        size_t scale = strtoul(option(argc, argv, "--scale", "1"), NULL, 10);
        if (width < 320 || height < 200 || width > 8192 || height > 8192 || (scale != 1 && scale != 2))
            return 64;
        return display_step(width, height, scale);
    }
    if (!strcmp(command, "place")) {
        if (geteuid() == 0 && !in_session)
            return run_in_console_session(argc, argv, 0);
        const char *slot = option(argc, argv, "--slot", NULL);
        if (!slot && !(option(argc, argv, "--x", NULL) && option(argc, argv, "--y", NULL)))
            return 64;
        return place(app, atof(option(argc, argv, "--x", "0")), atof(option(argc, argv, "--y", "0")),
                     slot ? atoi(slot) : -1, atoi(option(argc, argv, "--slot-width", "1600")),
                     atoi(option(argc, argv, "--slot-height", "1200")), atoi(option(argc, argv, "--moves", "0")));
    }
    if (strcmp(command, "stream")) {
        fputs("usage: seamless-guest list\n"
              "       seamless-guest stream (--app NAME | --window ID | --test-pattern)\n"
              "                      [--host 10.0.2.2] [--port 7654] [--fps 30] [--seconds N]\n"
              "       seamless-guest program [--app NAME] [--port 7654] [--seconds 20]\n"
              "       seamless-guest tree (--app NAME | --all) [--host H] [--port P] [--seconds N]\n"
              "       seamless-guest program-tree [--port P] [--seconds N]\n"
              "       seamless-guest open-app --app NAME\n"
              "       seamless-guest display --width W --height H [--scale 1]\n"
              "       seamless-guest place --app NAME (--x X --y Y | --slot N [--slot-width W --slot-height H])\n"
              "                      [--moves K]\n",
              stderr);
        return 64;
    }
    struct Stream s;
    memset(&s, 0, sizeof(s));
    s.test_pattern = flag(argc, argv, "--test-pattern");
    const char *window = option(argc, argv, "--window", NULL);
    s.window = s.test_pattern ? 1 : window ? (CGWindowID)strtoul(window, NULL, 10) : find_window(app);
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
