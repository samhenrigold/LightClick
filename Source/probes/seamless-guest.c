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
#include <poll.h>
#include <pwd.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
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
        double alpha = 1;
        const void *alpha_value = CFDictionaryGetValue(d, kCGWindowAlpha);
        if (alpha_value)
            CFNumberGetValue(alpha_value, kCFNumberDoubleType, &alpha);
        printf("id=%d pid=%d layer=%d alpha=%g owner=\"%s\" title=\"%s\" bounds=%g,%g %gx%g\n",
               int_for(d, kCGWindowNumber), int_for(d, kCGWindowOwnerPID), int_for(d, kCGWindowLayer), alpha, owner,
               name, b.origin.x, b.origin.y, b.size.width, b.size.height);
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

// Sending through the guest's network takes as long as capturing does, and they needn't take turns: the guest has the
// cores. So everything goes in order through one thread, and a capture only waits when this queue is full.
struct Outgoing {
    struct Outgoing *next;
    int fd;
    size_t size;
    uint8_t bytes[];
};
enum { OUTGOING_LIMIT = 64 * 1024 * 1024 };
static struct Outgoing *outgoing_first, *outgoing_last;
static size_t outgoing_bytes;
static int outgoing_failed, outgoing_busy;
static double outgoing_seconds;
static pthread_mutex_t outgoing_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t outgoing_changed = PTHREAD_COND_INITIALIZER;

static void *sender_thread(void *unused) {
    (void)unused;
    pthread_mutex_lock(&outgoing_lock);
    for (;;) {
        while (!outgoing_first)
            pthread_cond_wait(&outgoing_changed, &outgoing_lock);
        struct Outgoing *item = outgoing_first;
        outgoing_busy = 1;
        pthread_mutex_unlock(&outgoing_lock);
        double started = now();
        const uint8_t *p = item->bytes;
        size_t left = item->size;
        int failed = 0;
        while (left && !failed) {
            ssize_t n = send(item->fd, p, left, 0);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                failed = 1;
            else {
                p += n;
                left -= (size_t)n;
            }
        }
        pthread_mutex_lock(&outgoing_lock);
        outgoing_seconds += now() - started;
        outgoing_failed |= failed;
        outgoing_first = item->next;
        if (!outgoing_first)
            outgoing_last = NULL;
        outgoing_bytes -= item->size;
        outgoing_busy = 0;
        free(item);
        pthread_cond_broadcast(&outgoing_changed);
    }
    return NULL;
}

static int send_all(int fd, const void *data, size_t size) {
    if (fd < 0)
        return 0; // Measuring capture alone, with the host unreachable.
    static int started;
    struct Outgoing *item = malloc(sizeof(*item) + size);
    if (!item)
        return -1;
    item->next = NULL;
    item->fd = fd;
    item->size = size;
    memcpy(item->bytes, data, size);
    pthread_mutex_lock(&outgoing_lock);
    if (!started) {
        started = 1;
        pthread_t thread;
        pthread_create(&thread, NULL, sender_thread, NULL);
    }
    while (outgoing_bytes > OUTGOING_LIMIT && !outgoing_failed)
        pthread_cond_wait(&outgoing_changed, &outgoing_lock);
    int failed = outgoing_failed;
    if (outgoing_last)
        outgoing_last->next = item;
    else
        outgoing_first = item;
    outgoing_last = item;
    outgoing_bytes += size;
    pthread_cond_broadcast(&outgoing_changed);
    pthread_mutex_unlock(&outgoing_lock);
    return failed ? -1 : 0;
}

// Waits for everything queued to have gone, before the tool's exit would drop it.
static void send_all_finish(void) {
    pthread_mutex_lock(&outgoing_lock);
    while ((outgoing_first || outgoing_busy) && !outgoing_failed)
        pthread_cond_wait(&outgoing_changed, &outgoing_lock);
    pthread_mutex_unlock(&outgoing_lock);
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
    uint8_t receive[SWM_DOCUMENT_PIECE * 2];
    size_t received;
    int buttons_down;
    unsigned pointer_events, key_events, gesture_events, menu_presses, captures, frames_changed;
    double capture_seconds, capture_worst;
    double get_seconds, read_seconds, compare_seconds, send_seconds; // Where a frame's time goes.
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
    double compare_started = now();
    if (!resized) {
        while (first < height && !memcmp(pixels + first * width * 4, s->previous + first * width * 4, width * 4))
            first++;
        if (first == height) {
            free(pixels);
            s->compare_seconds += now() - compare_started;
            return 0;
        }
        while (last > first && !memcmp(pixels + last * width * 4, s->previous + last * width * 4, width * 4))
            last--;
    }
    // And only the columns that did: a moving box in a wide window is a small part of its rows.
    uint32_t left = 0, right = width ? width - 1 : 0;
    if (!resized) {
        left = width;
        right = 0;
        for (uint32_t y = first; y <= last; y++) {
            const uint32_t *now_row = (const uint32_t *)(pixels + y * width * 4),
                           *was_row = (const uint32_t *)(s->previous + y * width * 4);
            uint32_t x = 0;
            while (x < left && now_row[x] == was_row[x])
                x++;
            left = x < left ? x : left;
            x = width;
            while (x > right + 1 && now_row[x - 1] == was_row[x - 1])
                x--;
            right = x > right + 1 ? x - 1 : right;
        }
        if (left >= width)
            left = 0;
        if (right < left)
            right = left;
    }
    s->compare_seconds += now() - compare_started;
    uint32_t columns = right - left + 1;
    struct SWMFrame f = {s->window, ++s->sequence, width, height, left, first, columns, last - first + 1, NULL};
    uint8_t prefix[SWM_FRAME_PREFIX];
    swm_put_frame_prefix(prefix, &f);
    double send_started = now();
    int failed = send_all(s->fd, prefix, sizeof(prefix));
    if (columns == width && !failed) {
        failed = send_all(s->fd, pixels + first * width * 4, (size_t)width * f.height * 4);
    } else if (!failed) {
        // Tightly packed, as a frame's rows are.
        uint8_t *band = malloc((size_t)columns * f.height * 4);
        if (!band)
            failed = 1;
        for (uint32_t y = 0; band && y < f.height; y++)
            memcpy(band + (size_t)y * columns * 4, pixels + ((size_t)(first + y) * width + left) * 4,
                   (size_t)columns * 4);
        if (band) {
            failed = send_all(s->fd, band, (size_t)columns * f.height * 4);
            free(band);
        }
    }
    s->send_seconds += now() - send_started;
    free(s->previous);
    s->previous = pixels;
    s->frames_changed++;
    s->bytes_sent += sizeof(prefix) + (uint64_t)columns * f.height * 4;
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
    if (s->pointer_events <= 8 && !s->test_pattern) {
        ProcessSerialNumber front = {0, 0};
        pid_t front_pid = 0;
        GetFrontProcess(&front);
        GetProcessPID(&front, &front_pid);
        printf("# %.1f pointer %u kind %d at %.1f,%.1f for window %u; front pid %d, target %d\n", now(),
               s->pointer_events, e->kind, e->x / 16.0, e->y / 16.0, e->window, front_pid, s->pid);
    }
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
    if (s->key_events <= 2 && !s->test_pattern) {
        ProcessSerialNumber front = {0, 0};
        pid_t front_pid = 0;
        GetFrontProcess(&front);
        GetProcessPID(&front, &front_pid);
        printf("# %.1f key %u down %d; front pid %d, target %d\n", now(), k->keycode, k->down, front_pid, s->pid);
    }
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
        dup2(ends[1], 2);
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
        if (!(line && *line == '[')) {
            static int told;
            if (told++ < 3)
                printf("# menu tool said: %.300s\n", text ? text : "(nothing)");
        }
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

// What a session needs of the app beyond its windows: the host's documents, which are copied in and copied back when
// the app saves them, and quitting. shortcut: a whole copy each way, of plain files only, and the host's copy loses if
// both change. A shared folder would end all three, and needs the guest's mount.
struct GuestDocument {
    uint32_t id;
    char path[PATH_MAX];
    struct timespec saved;
};
static struct GuestDocument guest_documents[64];
static int guest_document_count;
static const char *session_app;
static pid_t session_app_pid;

// A file to drag, or being dragged, and the helper doing it, whose readiness the pointer has to wait for: its shields
// have to be up for the press, and until then the moves are only remembered. See seamless-integration.md, "Drag in".
#define SESSION_DRAG_FILES 16
static char *drag_paths[SESSION_DRAG_FILES];
static int drag_path_count;
static pid_t drag_helper;
static int drag_helper_out = -1, drag_ready, drag_waiting_up;
static struct SWMPointer drag_last;
static const char *session_menu_tool;

static void session_run(char *const arguments[]) {
    pid_t child = fork();
    if (child == 0) {
        execv(arguments[0], arguments);
        _exit(127);
    }
    printf("# %s: %s, %d\n", arguments[0], arguments[arguments[2] ? 2 : 1], child);
}

static void start_drag(void) {
    char *arguments[8 + 2 * SESSION_DRAG_FILES];
    int n = 0;
    arguments[n++] = (char *)session_menu_tool;
    arguments[n++] = "drag-in";
    arguments[n++] = "--no-image";
    for (int i = 0; i < drag_path_count; i++) {
        arguments[n++] = "--file";
        arguments[n++] = drag_paths[i];
    }
    arguments[n] = NULL;
    int ends[2];
    if (!session_menu_tool || pipe(ends))
        return;
    drag_helper = fork();
    if (drag_helper == 0) {
        dup2(ends[1], 1);
        close(ends[0]);
        close(ends[1]);
        execv(arguments[0], arguments);
        _exit(127);
    }
    close(ends[1]);
    fcntl(ends[0], F_SETFL, O_NONBLOCK);
    drag_helper_out = ends[0];
    drag_ready = drag_waiting_up = 0;
    printf("# %.1f drag helper %d started with %d files\n", now(), drag_helper, drag_path_count);
    drag_path_count = 0;
}

static void receive_document(const uint8_t *bytes, uint32_t length) {
    if (length < SWM_DOCUMENT_FIXED)
        return;
    uint32_t id = swm_r32(bytes);
    uint16_t name_length = swm_r16(bytes + 6);
    char name[256], directory[64], part[PATH_MAX];
    if (!name_length || name_length >= sizeof(name) || length < SWM_DOCUMENT_FIXED + (uint32_t)name_length)
        return;
    memcpy(name, bytes + SWM_DOCUMENT_FIXED, name_length);
    name[name_length] = 0;
    if (strchr(name, '/') || !strcmp(name, "..") || !strcmp(name, "."))
        return;
    snprintf(directory, sizeof(directory), "/tmp/seamless-docs-%u", getuid());
    mkdir(directory, 0700);
    snprintf(part, sizeof(part), "%s/%u", directory, id);
    mkdir(part, 0700);
    char *folder = strdup(part);
    snprintf(part, sizeof(part), "%s/.part", folder);
    int fd = open(part, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) {
        size_t offset = SWM_DOCUMENT_FIXED + (size_t)name_length;
        if (write(fd, bytes + offset, length - offset) < 0)
            perror("document");
        close(fd);
    }
    if (bytes[4] && guest_document_count < (int)(sizeof(guest_documents) / sizeof(*guest_documents))) {
        struct GuestDocument *document = &guest_documents[guest_document_count];
        snprintf(document->path, sizeof(document->path), "%s/%s", folder, name);
        struct stat info;
        if (!rename(part, document->path) && !stat(document->path, &info)) {
            document->id = id;
            document->saved = info.st_mtimespec;
            guest_document_count++;
            if (bytes[5] & SWD_DRAG) {
                if (drag_path_count < SESSION_DRAG_FILES)
                    drag_paths[drag_path_count++] = strdup(document->path);
            } else {
                char *const arguments[] = {"/usr/bin/open", "-a", (char *)session_app, document->path, NULL};
                session_run(arguments);
            }
        }
    }
    free(folder);
    if (bytes[4] && (bytes[5] & SWD_DRAG_START))
        start_drag();
}

static void quit_app(void) {
    char *const arguments[] = {
        "/usr/bin/osascript", "-e", "on run argv", "-e", "tell application (item 1 of argv) to quit", "-e", "end run",
        (char *)session_app,  NULL};
    session_run(arguments);
}

static int send_file_back(int fd, uint32_t id, const char *path);

static int send_saved_documents(int fd) {
    for (int i = 0; i < guest_document_count; i++) {
        struct GuestDocument *document = &guest_documents[i];
        struct stat info;
        if (stat(document->path, &info) || (info.st_mtimespec.tv_sec == document->saved.tv_sec &&
                                            info.st_mtimespec.tv_nsec == document->saved.tv_nsec))
            continue;
        document->saved = info.st_mtimespec;
        printf("# %s changed, sending it back\n", document->path);
        if (send_file_back(fd, document->id, document->path))
            return -1;
    }
    return 0;
}

static int send_file_back(int fd, uint32_t id, const char *path) {
    struct stat info;
    int file = open(path, O_RDONLY);
    if (file < 0 || fstat(file, &info)) {
        if (file >= 0)
            close(file);
        return 0;
    }
    static uint8_t out[SWM_HEADER_SIZE + SWM_DOCUMENT_FIXED + SWM_DOCUMENT_PIECE];
    off_t remaining = info.st_size;
    do {
        uint32_t piece = remaining > SWM_DOCUMENT_PIECE ? SWM_DOCUMENT_PIECE : (uint32_t)remaining;
        size_t prefix = swm_put_document_prefix(out, id, remaining <= SWM_DOCUMENT_PIECE, 0, "", 0, piece);
        if (read(file, out + prefix, piece) != (ssize_t)piece || send_all(fd, out, prefix + piece)) {
            close(file);
            return -1;
        }
        remaining -= piece;
    } while (remaining > 0);
    close(file);
    return 0;
}

// The app's Dock badge and whether it's asking for attention, which AppKit keeps with LaunchServices, so nothing has to
// be injected. shortcut: polled every 2 s, until LaunchServices' change notifications are used.
static void send_app_state(struct Stream *s, pid_t pid) {
    static CFTypeRef (*create_asn)(CFAllocatorRef, pid_t);
    static CFTypeRef (*copy_item)(int, CFTypeRef, CFStringRef);
    static const CFStringRef *attention_key;
    if (!create_asn) {
        create_asn = dlsym(RTLD_DEFAULT, "_LSASNCreateWithPid");
        copy_item = dlsym(RTLD_DEFAULT, "_LSCopyApplicationInformationItem");
        attention_key = dlsym(RTLD_DEFAULT, "_kLSApplicationDesiresAttentionKey");
    }
    if (!create_asn || !copy_item)
        return;
    CFTypeRef asn = create_asn(kCFAllocatorDefault, pid);
    if (!asn)
        return;
    char badge[128] = "", state[512];
    CFTypeRef status = copy_item(-2, asn, CFSTR("StatusLabel"));
    if (status && CFGetTypeID(status) == CFDictionaryGetTypeID()) {
        CFStringRef label = CFDictionaryGetValue(status, CFSTR("label"));
        if (label && CFGetTypeID(label) == CFStringGetTypeID())
            CFStringGetCString(label, badge, sizeof(badge), kCFStringEncodingUTF8);
    }
    CFTypeRef wants = attention_key ? copy_item(-2, asn, *attention_key) : NULL;
    int attention = wants && CFGetTypeID(wants) == CFBooleanGetTypeID() && CFBooleanGetValue(wants);
    if (status)
        CFRelease(status);
    if (wants)
        CFRelease(wants);
    CFRelease(asn);
    // A guest's badge is any text, so it can't go in the JSON as it stands.
    for (char *c = badge; *c; c++)
        if (*c == '"' || *c == '\\' || (unsigned char)*c < ' ')
            *c = ' ';
    snprintf(state, sizeof(state), "{\"badge\":\"%s\",\"attention\":%s}", badge, attention ? "true" : "false");
    static char last[512];
    if (strcmp(state, last)) {
        strlcpy(last, state, sizeof(last));
        printf("# app state %s\n", state);
        uint8_t header[SWM_HEADER_SIZE];
        swm_header(header, SWM_APP_STATE, (uint32_t)strlen(state));
        send_all(s->fd, header, sizeof(header));
        send_all(s->fd, state, strlen(state));
    }
}

static pid_t session_test_badge_pid;

static void post_pointer(struct Stream *s, const struct SWMPointer *e);

static void end_drag_helper(void) {
    if (drag_helper_out >= 0)
        close(drag_helper_out);
    drag_helper_out = -1;
    // A helper left running keeps its place as the front app, and takes the keyboard.
    if (drag_helper > 0) {
        kill(drag_helper, SIGTERM);
        waitpid(drag_helper, NULL, 0);
    }
    drag_helper = 0;
}

// While the helper starts, the pointer only remembers where it's been. Once it's ready: the press its shield is waiting
// for, and then anything that happened in the meantime, including the drop.
static void service_drag(struct Stream *s) {
    if (drag_helper_out < 0)
        return;
    char said[512];
    ssize_t n = read(drag_helper_out, said, sizeof(said) - 1);
    if (n == 0) {
        printf("# %.1f drag helper has finished\n", now());
        end_drag_helper();
        return;
    }
    if (n < 0)
        return;
    said[n] = 0;
    printf("# drag helper says: %.200s\n", said);
    if (drag_ready || !strstr(said, "ready"))
        return;
    drag_ready = 1;
    printf("# %.1f drag helper is ready, pressing at %.1f,%.1f\n", now(), drag_last.x / 16.0, drag_last.y / 16.0);
    struct SWMPointer down = drag_last;
    down.window = 0;
    down.kind = SWM_DOWN;
    post_pointer(s, &down);
    usleep(300000); // The shield goes and the drag starts on the press; a move before that is lost.
    down.kind = SWM_DRAG;
    post_pointer(s, &down);
    if (drag_waiting_up) {
        usleep(300000);
        down.kind = SWM_UP;
        post_pointer(s, &down);
    }
}

static int drag_pointer(const struct SWMPointer *e) {
    drag_last = *e; // Even with no helper yet: the move that says where a drag starts comes before its file.
    if (drag_helper_out < 0 || drag_ready)
        return 0;
    drag_waiting_up = e->kind == SWM_UP;
    return 1;
}

static void cancel_drag(struct Stream *s) {
    if (drag_helper_out < 0)
        return;
    if (drag_ready) {
        // Escape is how a dragging session is cancelled; the release then finds nothing to drop.
        CGEventRef escape = CGEventCreateKeyboardEvent(NULL, 53, true);
        CGEventPost(kCGHIDEventTap, escape);
        CFRelease(escape);
        escape = CGEventCreateKeyboardEvent(NULL, 53, false);
        CGEventPost(kCGHIDEventTap, escape);
        CFRelease(escape);
        struct SWMPointer up = drag_last;
        up.window = 0;
        up.kind = SWM_UP;
        post_pointer(s, &up);
    }
    end_drag_helper();
    puts("# drag cancelled");
}

// The guest's drag pasteboard to the host. If it holds files, a host drag takes over, and the guest's drag ends on a
// sink, so its source sees a finished copy and nothing slides back.
static void answer_drag_query(struct Stream *s) {
    if (!session_menu_tool)
        return;
    char *const read_it[] = {(char *)session_menu_tool, "drag-read", NULL};
    char *said = run_tool(read_it);
    const char *json = said ? strchr(said, '{') : NULL;
    printf("# drag pasteboard: %.300s\n", said ? said : "");
    if (json) {
        uint8_t header[SWM_HEADER_SIZE];
        swm_header(header, SWM_DRAG_STATE, (uint32_t)strlen(json));
        send_all(s->fd, header, sizeof(header));
        send_all(s->fd, json, strlen(json));
    }
    if (json && strstr(json, "\"files\"")) {
        int ends[2];
        if (!pipe(ends)) {
            pid_t sink = fork();
            if (sink == 0) {
                dup2(ends[1], 1);
                close(ends[0]);
                close(ends[1]);
                execl(session_menu_tool, session_menu_tool, "drag-sink", "--seconds", "30", (char *)NULL);
                _exit(127);
            }
            close(ends[1]);
            char ready[128];
            ssize_t n = read(ends[0], ready, sizeof(ready)); // Blocks until its window is up, about a second.
            close(ends[0]);
            printf("# sink %d said %zd bytes\n", sink, n);
            CGEventRef here = CGEventCreate(NULL);
            struct SWMPointer at = {0};
            CGPoint point = CGEventGetLocation(here);
            CFRelease(here);
            at.x = (int32_t)(point.x * 16);
            at.y = (int32_t)(point.y * 16);
            at.kind = SWM_DRAG;
            post_pointer(s, &at);
            usleep(300000);
            at.kind = SWM_UP;
            post_pointer(s, &at);
        }
    }
    free(said);
    end_drag_helper();
}

static void menu_press(struct Stream *s, const char *path, uint32_t length) {
    if (!menu_tool || length > 1000)
        return;
    char copy[1024];
    memcpy(copy, path, length);
    copy[length] = 0;
    char *const arguments[] = {(char *)menu_tool, "press", "--app", (char *)menu_app, "--path", copy, NULL};
    char *said = run_tool(arguments);
    printf("# pressed %s: %.200s\n", copy, said ? said : "");
    free(said);
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
        if (m.type == SWM_POINTER) {
            if (!drag_pointer(&m.u.pointer))
                post_pointer(s, &m.u.pointer);
        } else if (m.type == SWM_DRAG_CANCEL)
            cancel_drag(s);
        else if (m.type == SWM_DRAG_QUERY)
            answer_drag_query(s);
        else if (m.type == SWM_DRAG_SEND && m.u.data.length > 4) {
            char path[PATH_MAX];
            uint32_t size = m.u.data.length - 4 < sizeof(path) - 1 ? m.u.data.length - 4 : sizeof(path) - 1;
            memcpy(path, m.u.data.bytes + 4, size);
            path[size] = 0;
            printf("# sending %s to the host for a drag\n", path);
            send_file_back(s->fd, swm_r32(m.u.data.bytes), path);
        } else if (m.type == SWM_KEY)
            post_key(s, &m.u.key);
        else if (m.type == SWM_MENU_PRESS)
            menu_press(s, (const char *)m.u.data.bytes, m.u.data.length);
        else if (m.type == SWM_DOCUMENT && session_app)
            receive_document(m.u.data.bytes, m.u.data.length);
        else if (m.type == SWM_QUIT_APP && session_app)
            quit_app();
        else if (m.type == SWM_GESTURE && !s->test_pattern) {
            // Apple's own route per generation: see seamless-input.md.
            static struct SWIContext context;
            // On a Mavericks clone only the pid path delivered everything: magnify, rotate and swipe never arrive by
            // record, and swipe doesn't by session. Mojave hasn't been run, so it stays on its agent's route.
            context.mechanism = darwin_major_early() < 18 ? SWI_PID : SWI_SESSION;
            context.pid = session_app_pid ? session_app_pid : s->pid;
            const struct SWMGesture *g = &m.u.gesture;
            CGPoint point = g->window ? CGPointMake(s->bounds.origin.x + g->x / 16.0, s->bounds.origin.y + g->y / 16.0)
                                      : CGPointMake(g->x / 16.0, g->y / 16.0);
            swi_gesture(&context, g, point);
            s->gesture_events++;
        } else if (m.type == SWM_SET_MINIMIZED) {
            printf("# %.1f host asks window %u minimized %u, app pid %d\n", now(), m.u.window_id, m.minimized, session_app_pid);
            fflush(stdout);
            if (session_menu_tool && session_app_pid && !fork()) {
                char pid[16], window[16];
                snprintf(pid, sizeof(pid), "%d", session_app_pid);
                snprintf(window, sizeof(window), "%u", m.u.window_id);
                execl(session_menu_tool, session_menu_tool, "set-minimized", "--pid", pid, "--window", window, "--state",
                      m.minimized ? "1" : "0", (char *)NULL);
                _exit(127);
            }
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
                       "<h1>A page in a guest browser</h1><div id=\"d\"></div><p>Some text.</p>"
                       "<script>var n=0,t;document.onmousedown=function(){var d=document.getElementById('d');"
                       "d.style.display='none';document.documentElement.style.background=(n++%2)?'#fff':'#234';"
                       "clearTimeout(t);t=setTimeout(function(){d.style.display='block'},5000)}</script>\n"
                     : "Seamless window test.\n",
              file);
        fclose(file);
    }
    pid_t child = fork();
    if (child == 0) {
        if ((strcmp(app, "TextEdit") && !safari) || session_app)
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
    uint32_t materials_hash;
    int minimized;
    int surface_x, surface_y, has_surface, cover_count;
    uint32_t covers_hash;
    int cropping, covered; // cropping: the message the host last had, if it's taking this from the display.
    double look_every;
    uint32_t surface_flushes;
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

// A sandboxed app's open and save panels are drawn by a view service inside the app's own sheet, and a password prompt
// by SecurityAgent, so a session shows those as the app's. shortcut: any service's window, whichever app it's for,
// until the tree can tell which window a service is serving.
static int tree_owner_is_service(const char *owner) {
    size_t length = strlen(owner);
    return strstr(owner, ".xpc.") || !strcmp(owner, "SecurityAgent") ||
           (length > 7 && !strcmp(owner + length - 7, "Service"));
}

// With several of these running, one per app, a service's windows go to the app in front.
static int tree_shared;
static char tree_front_owner[256];

static int tree_owner_wanted(const char *owner, const char *app) {
    if (!strcmp(owner, app))
        return 1;
    return session_app && tree_owner_is_service(owner) && (!tree_shared || !strcmp(tree_front_owner, app));
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
        return tree_owner_wanted(owner, app);
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

// Everything on screen, front first, for what covers what across apps.
#define TREE_ALL 256
static struct TreeAll {
    CGWindowID id;
    int layer;
    CGRect bounds;
    char owner[64];
} tree_all[TREE_ALL];
static int tree_all_count;

static int tree_items_from_list(struct TreeItem *items, const char *app, pid_t pid) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    int count = 0;
    tree_front_owner[0] = 0;
    for (CFIndex i = 0; tree_shared && list && i < CFArrayGetCount(list); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(list, i);
        char owner[256];
        text_for(d, kCGWindowOwnerName, owner, sizeof(owner));
        if (int_for(d, kCGWindowLayer) == 0 && !tree_owner_is_service(owner)) {
            snprintf(tree_front_owner, sizeof(tree_front_owner), "%s", owner);
            break;
        }
    }
    tree_all_count = 0;
    for (CFIndex i = 0; tree_shared && list && tree_all_count < TREE_ALL && i < CFArrayGetCount(list); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(list, i);
        struct TreeAll *all = &tree_all[tree_all_count++];
        all->id = (CGWindowID)int_for(d, kCGWindowNumber);
        all->layer = int_for(d, kCGWindowLayer);
        all->bounds = bounds_for(d);
        text_for(d, kCGWindowOwnerName, all->owner, sizeof(all->owner));
    }
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
            : app   ? !tree_owner_wanted(named->owner, app)
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
static int no_pixels;

static double display_scale(void) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
    double scale = mode && CGDisplayModeGetWidth(mode)
                       ? (double)CGDisplayModeGetPixelWidth(mode) / CGDisplayModeGetWidth(mode)
                       : 1;
    if (mode)
        CGDisplayModeRelease(mode);
    return scale;
}

static struct SWSTable *tree_gpu_table;

// Where the hook last drew this window's surface from. It moves when its shadow does, as with focus.
static int tree_send_surface_origin(struct Stream *s, struct TreeWindow *w, CGWindowID id) {
    for (uint32_t i = 0; i < tree_gpu_table->gpu_row_count && i < SWS_TREE; i++) {
        const struct SWSGPURow *row = &tree_gpu_table->gpu_rows[i];
        if (row->id != id || !row->frames)
            continue;
        int x = (int)row->x, y = (int)row->y;
        if (w->has_surface && x == w->surface_x && y == w->surface_y)
            return 0;
        w->has_surface = 1;
        w->surface_x = x;
        w->surface_y = y;
        uint8_t message[SWM_HEADER_SIZE + 12];
        swm_header(message, SWM_SURFACE_ORIGIN, 12);
        swm_w32(message + SWM_HEADER_SIZE, id);
        swm_w32(message + SWM_HEADER_SIZE + 4, (uint32_t)x);
        swm_w32(message + SWM_HEADER_SIZE + 8, (uint32_t)y);
        return send_all(s->fd, message, sizeof(message));
    }
    return 0;
}

// Says what's in front of this window, of any app, when that changes, so the host never shows it as this window's, and
// returns how many there are. Its own sheets and menus don't count: they're in the same place on the host. Nor does the
// cursor or menu bar.
static int tree_send_covers(struct Stream *s, struct TreeWindow *w, const struct TreeItem *item, int *count) {
    enum { MOST = 32 };
    int32_t rects[MOST * 4];
    int n = 0;
    uint32_t hash = 2166136261u, group = tree_group(item->id);
    for (int i = 0; i < tree_all_count && tree_all[i].id != item->id && n < MOST; i++) {
        const struct TreeAll *front = &tree_all[i];
        // The Dock's hidden for this, and owns a transparent full-screen window as well.
        if (front->layer < 0 || !strcmp(front->owner, "Window Server") || !strcmp(front->owner, "Dock") ||
            !CGRectIntersectsRect(front->bounds, item->bounds) || tree_group(front->id) == group)
            continue;
        if (!strcmp(front->owner, item->owner) && front->layer != 0)
            continue;
        int32_t rect[4] = {(int32_t)front->bounds.origin.x, (int32_t)front->bounds.origin.y,
                           (int32_t)front->bounds.size.width, (int32_t)front->bounds.size.height};
        memcpy(&rects[n * 4], rect, sizeof(rect));
        n++;
        for (int k = 0; k < 4; k++)
            hash = (hash ^ (uint32_t)rect[k]) * 16777619u;
    }
    *count = n;
    if (hash == w->covers_hash && n == w->cover_count)
        return 0;
    w->covers_hash = hash;
    w->cover_count = n;
    uint8_t message[SWM_HEADER_SIZE + 8 + MOST * 16];
    uint32_t size = 8 + (uint32_t)n * 16;
    swm_header(message, SWM_COVERS, size);
    swm_w32(message + SWM_HEADER_SIZE, item->id);
    swm_w32(message + SWM_HEADER_SIZE + 4, (uint32_t)n);
    for (int i = 0; i < n * 4; i++)
        swm_w32(message + SWM_HEADER_SIZE + 8 + i * 4, (uint32_t)rects[i]);
    return send_all(s->fd, message, SWM_HEADER_SIZE + size);
}

// Asks the app, as a minimized window isn't in WindowServer's list by its number, even when asked for by that number.
static int tree_window_is_minimized(CGWindowID id, pid_t pid) {
    if (!session_menu_tool)
        return 0;
    char pid_text[16], window[16];
    snprintf(pid_text, sizeof(pid_text), "%d", pid);
    snprintf(window, sizeof(window), "%u", id);
    char *const ask[] = {(char *)session_menu_tool, "is-minimized", "--pid", pid_text, "--window", window, NULL};
    char *said = run_tool(ask);
    int minimized = said && strstr(said, "minimized yes");
    printf("# %.1f window %u left the screen: %s\n", now(), id, said ? said : "(no answer)");
    fflush(stdout);
    free(said);
    return minimized;
}

static int tree_send_minimized(struct Stream *s, CGWindowID id, int minimized) {
    printf("# %.1f window %u %s\n", now(), id, minimized ? "minimized" : "back");
    fflush(stdout);
    uint8_t message[SWM_HEADER_SIZE + 8];
    swm_header(message, SWM_MINIMIZED, 8);
    swm_w32(message + SWM_HEADER_SIZE, id);
    swm_w32(message + SWM_HEADER_SIZE + 4, (uint32_t)minimized);
    return send_all(s->fd, message, sizeof(message));
}

// What the hook says shows through this window, when that changes.
static int tree_send_materials(struct Stream *s, struct TreeWindow *w, const struct TreeItem *item) {
    enum { MOST = 32 };
    uint8_t message[SWM_HEADER_SIZE + 8 + MOST * 24];
    uint32_t n = 0, hash = 2166136261u;
    for (uint32_t i = 0; i < tree_gpu_table->gpu_backdrop_count && i < SWS_BACKDROPS && n < MOST; i++) {
        const volatile struct SWSBackdrop *b = &tree_gpu_table->gpu_backdrops[i];
        if (b->id != item->id)
            continue;
        int32_t row[6] = {(int32_t)b->material, (int32_t)b->active, (int32_t)(b->x - (float)item->bounds.origin.x),
                          (int32_t)(b->y - (float)item->bounds.origin.y), (int32_t)b->width, (int32_t)b->height};
        for (int k = 0; k < 6; k++) {
            swm_w32(message + SWM_HEADER_SIZE + 8 + n * 24 + (uint32_t)k * 4, (uint32_t)row[k]);
            hash = (hash ^ (uint32_t)row[k]) * 16777619u;
        }
        n++;
    }
    if (hash == w->materials_hash)
        return 0;
    w->materials_hash = hash;
    uint32_t size = 8 + n * 24;
    swm_header(message, SWM_MATERIALS, size);
    swm_w32(message + SWM_HEADER_SIZE, item->id);
    swm_w32(message + SWM_HEADER_SIZE + 4, n);
    return send_all(s->fd, message, SWM_HEADER_SIZE + size);
}

static int tree_surface_has_shadow(CGWindowID id) {
    for (uint32_t i = 0; i < tree_gpu_table->gpu_row_count && i < SWS_TREE; i++) {
        const struct SWSGPURow *row = &tree_gpu_table->gpu_rows[i];
        if (row->id == id && row->frames)
            return row->x < row->window_x || row->y < row->window_y;
    }
    return 0;
}

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
    printf("# %.1f tree starts\n", started);
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
        // A hook for a build it doesn't know in full publishes no tree.
        int item_count = tree_table && tree_table->tree_count ? tree_items_from_hook(items, app, pid)
                                                              : tree_items_from_list(items, app, pid);
        service_drag(s);
        static int was_empty;
        if ((item_count == 0) != was_empty) {
            was_empty = !item_count;
            printf("# %.1f %s windows: hook says %u, names %d\n", now(), item_count ? "has" : "no",
                   tree_table ? tree_table->tree_count : 0, tree_name_count);
        }
        static double session_checked;
        if (session_app && tick - session_checked > 1) {
            session_checked = tick;
            for (int i = 0; !session_app_pid && i < item_count; i++)
                if (!strcmp(items[i].owner, app))
                    session_app_pid = items[i].pid;
            if (send_saved_documents(s->fd))
                goto done;
            static double state_checked;
            if (tick - state_checked > 2) {
                state_checked = tick;
                pid_t watched = session_test_badge_pid ? session_test_badge_pid : session_app_pid;
                if (watched && !kill(watched, 0))
                    send_app_state(s, watched);
            }
            if (session_app_pid && kill(session_app_pid, 0) && errno == ESRCH) {
                uint8_t gone[SWM_HEADER_SIZE + SWM_GONE_SIZE];
                send_all(s->fd, gone, swm_put_u32_message(gone, sizeof(gone), SWM_APP_GONE, 0));
                break;
            }
        }
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
            if (w->minimized) {
                w->minimized = 0;
                if (tree_send_minimized(s, id, 0))
                    goto done;
            }
            int fresh = w->id != id;
            w->id = id;
            w->seen = 1;
            w->pid = item->pid;
            CGRect bounds = item->bounds;
            const char *title = item->title, *owner = item->owner;
            int alpha = item->alpha, layer = item->layer;
            // The host shows everything from the display's own frames. An opaque, ordinary window has the host's
            // corners and shadow. One a window in front covers also gets a capture a second, for the part under that
            // window, which only shows when nothing's over it on the host either, as in Mission Control. Anything else,
            // such as a menu, a popover or a sheet, gets a capture a second for its alpha.
            int own_surface = tree_shared && tree_gpu_table && tree_gpu_table->gpu_mode;
            int crop = (no_pixels && item->layer == 0 && item->title[0] && item->alpha == 0x10000) || own_surface;
            int covered = 0;
            for (int k = 0; crop && !own_surface && !covered && k < i; k++) {
                const struct TreeItem *front = &items[k];
                covered = front->layer == 0 && front->title[0] && CGRectIntersectsRect(front->bounds, item->bounds) &&
                          tree_group(front->id) != tree_group(id);
            }
            // Room for the guest's shadow if its surface has one, or else there's the window's own shape for the
            // host's.
            int margin = own_surface && tree_surface_has_shadow(id) ? item->margin
                         : crop || tree_shared                      ? 0
                                                                    : item->margin;
            int moved = !CGRectEqualToRect(bounds, w->bounds),
                sized = !CGSizeEqualToSize(bounds.size, w->bounds.size) || margin != w->margin;
            uint32_t seed = 0;
            int have_seed = tree_flush_seed && tree_connection && !tree_flush_seed(tree_connection(), id, &seed);
            seed_answers += have_seed;
            // A seed doesn't cover GL or video surfaces in a window, so look anyway once a second.
            //             // A seed misses what's composited in the server: on Mojave a page's CSS animation leaves it
            //             still for 22 s. So
            // looking is steered by what looks find: faster when one finds a change the seed missed, up to 15 Hz, and
            // half as fast when it finds nothing, down to once a second. A caret's blink settles a few looks a second;
            // animation climbs.
            double look_every = w->look_every > 0 ? w->look_every : 1;
            int seed_moved = have_seed && seed != w->seed;
            int stale =
                !have_seed || seed_moved || sized || fresh || !w->previous || tick - w->last_capture > look_every;
            unsigned changed_before = s->frames_changed;
            struct SWSEntry *entry = tree_table ? &tree_table->slots[w - windows] : NULL;
            if (entry) {
                entry->id = id;
                // A capture only for what the backing doesn't hold: the shadow when it changes, and GL or video always.
                if (entry->present && !entry->accelerated && entry->width && !fresh && !sized && w->previous) {
                    // A window with surfaces gets a capture when one flushes, up to 15 Hz, and once a second for what
                    // doesn't come by that request.
                    uint32_t flushes = tree_table->surface_flushes[id % SWS_FLUSHES];
                    stale =
                        (item->has_surfaces && ((flushes != w->surface_flushes && tick - w->last_capture > 1.0 / 15) ||
                                                tick - w->last_capture > 1)) ||
                        item->shadow_key != w->shadow_key;
                    if (stale)
                        w->surface_flushes = flushes;
                }
            }
            s->window = id;
            s->pid = w->pid;
            s->bounds = bounds;
            s->order = order;
            s->alpha = (uint32_t)alpha;
            s->margin = margin;
            int kind = !no_pixels ? 0 : crop ? SWM_CROP : SWM_OVERLAY;
            if (own_surface && tree_send_surface_origin(s, w, id))
                goto done;
            if (own_surface && tree_send_materials(s, w, item))
                goto done;
            // With several apps, what's in front can be anyone's, which only the guest knows.
            if (tree_shared && crop && !own_surface) {
                int covering = 0;
                if (tree_send_covers(s, w, item, &covering))
                    goto done;
                covered = covering > 0;
            }
            if (kind)
                stale = (!crop || covered) &&
                        (fresh || sized || !w->previous || covered != w->covered || tick - w->last_capture >= 1);
            w->covered = covered;
            if (kind && !stale) {
                if (fresh || moved || sized || order != w->order || alpha != w->alpha || strcmp(title, w->title)) {
                    s->pixel_width = w->pixel_width =
                        (uint32_t)((bounds.size.width + 2 * margin) * display_scale() + 0.5);
                    s->pixel_height = w->pixel_height =
                        (uint32_t)((bounds.size.height + 2 * margin) * display_scale() + 0.5);
                    s->group = tree_group(id);
                    if (send_window(s, title, owner, layer))
                        goto done;
                }
                if (sized) {
                    free(w->previous);
                    w->previous = NULL;
                }
                if (w->cropping != kind) {
                    w->cropping = kind;
                    uint8_t message[SWM_HEADER_SIZE + SWM_GONE_SIZE];
                    if (send_all(s->fd, message, swm_put_u32_message(message, sizeof(message), kind, id)))
                        goto done;
                }
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
                w->margin = margin;
                snprintf(w->title, sizeof(w->title), "%s", title);
                order++;
                continue;
            }
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
                uint32_t width = 0, height = 0;
                CGImageRef image =
                    CGWindowListCreateImage(rect, kCGWindowListOptionIncludingWindow, id, kCGWindowImageDefault);
                double got = now();
                uint8_t *pixels = image ? copy_pixels(image, &width, &height) : NULL;
                if (image)
                    CGImageRelease(image);
                double spent = now() - before;
                s->get_seconds += got - before;
                s->read_seconds += now() - got;
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
                if (kind && w->cropping != kind) {
                    w->cropping = kind;
                    uint8_t message[SWM_HEADER_SIZE + SWM_GONE_SIZE];
                    if (send_all(s->fd, message, swm_put_u32_message(message, sizeof(message), kind, id)))
                        goto done;
                }
                if (!seed_moved && !sized) {
                    double next = s->frames_changed != changed_before ? look_every / 2 : look_every * 2;
                    w->look_every = next < 1.0 / 15 ? 1.0 / 15 : next > 1 ? 1 : next;
                }
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
            if (windows[i].id && !windows[i].seen && tree_shared &&
                (windows[i].minimized || tree_window_is_minimized(windows[i].id, windows[i].pid))) {
                // Once it's known, only its coming back, or the app's going, changes that.
                if (!windows[i].minimized) {
                    windows[i].minimized = 1;
                    if (tree_send_minimized(s, windows[i].id, 1))
                        goto done;
                }
                windows[i].seen = 1;
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
    printf("time_share get %.0f, read %.0f, compare %.0f, queue %.0f, sender %.0f %%\n", s->get_seconds / elapsed * 100,
           s->read_seconds / elapsed * 100, s->compare_seconds / elapsed * 100, s->send_seconds / elapsed * 100,
           outgoing_seconds / elapsed * 100);
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    printf("tool_cpu %.0f %%\n", ((double)usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 + usage.ru_stime.tv_sec +
                                  usage.ru_stime.tv_usec / 1e6) /
                                     elapsed * 100);
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

// What each way of asking WindowServer for a window's pixels costs, on the same window.
static void capture_bench_report(const char *name, CGImageRef image, double spent, unsigned attempts) {
    if (!image) {
        printf("%-34s no image\n", name);
        return;
    }
    uint32_t width = 0, height = 0;
    double before = now();
    uint8_t *pixels = copy_pixels(image, &width, &height);
    double copied = now() - before;
    unsigned opaque = 0, clear = 0;
    for (size_t i = 0; pixels && i < (size_t)width * height; i += 97) {
        opaque += pixels[i * 4 + 3] == 255;
        clear += pixels[i * 4 + 3] == 0;
    }
    printf("%-34s %6.1f ms over %u, then %5.1f ms to read; %ux%u, %u%% solid, %u%% clear\n", name,
           spent / attempts * 1000, attempts, copied * 1000, width, height,
           width ? opaque * 100 / (unsigned)((size_t)width * height / 97 + 1) : 0,
           width ? clear * 100 / (unsigned)((size_t)width * height / 97 + 1) : 0);
    free(pixels);
}

static int capture_bench(const char *app) {
    CGWindowID window = find_window(app);
    if (!window) {
        printf("# ERROR no window of %s\n", app);
        return 1;
    }
    char title[64];
    CGRect bounds = CGRectZero;
    snapshot(window, title, sizeof(title), &bounds);
    printf("# window %u %gx%g\n", window, bounds.size.width, bounds.size.height);
    enum { ATTEMPTS = 12 };
    const struct {
        const char *name;
        CGWindowImageOption options;
    } plain[] = {
        {"CGWindowList default", kCGWindowImageDefault},
        {"CGWindowList no framing", kCGWindowImageBoundsIgnoreFraming},
        {"CGWindowList nominal", kCGWindowImageNominalResolution},
        {"CGWindowList no framing, nominal", kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution}};
    for (size_t k = 0; k < sizeof(plain) / sizeof(*plain); k++) {
        CGImageRef image = NULL;
        double before = now();
        for (int i = 0; i < ATTEMPTS; i++) {
            if (image)
                CGImageRelease(image);
            image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, window, plain[k].options);
        }
        capture_bench_report(plain[k].name, image, now() - before, ATTEMPTS);
        if (image)
            CGImageRelease(image);
    }
    int (*connection)(void) = guest_symbol("CGSMainConnectionID", "SLSMainConnectionID");
    CFArrayRef (*hw)(int, const CGWindowID *, int, uint32_t) =
        guest_symbol("CGSHWCaptureWindowList", "SLSHWCaptureWindowList");
    const struct {
        const char *name;
        uint32_t options;
    } private_ways[] = {{"HW capture", 0},
                        {"HW capture nominal", 0x200},
                        {"HW capture ignore clip", 0x800},
                        {"HW capture nominal, ignore clip", 0xa00},
                        {"HW capture 0x1", 0x1},
                        {"HW capture 0x2", 0x2}};
    for (size_t k = 0; hw && connection && k < sizeof(private_ways) / sizeof(*private_ways); k++) {
        CFArrayRef images = NULL;
        double before = now();
        for (int i = 0; i < ATTEMPTS; i++) {
            if (images)
                CFRelease(images);
            images = hw(connection(), &window, 1, private_ways[k].options);
        }
        double spent = now() - before;
        capture_bench_report(private_ways[k].name,
                             images && CFArrayGetCount(images) ? (CGImageRef)CFArrayGetValueAtIndex(images, 0) : NULL,
                             spent, ATTEMPTS);
        if (images)
            CFRelease(images);
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

// A whole desktop as host apps. Says which apps have windows, front first, and runs a `tree` for each one the host asks
// for. It and they end when the host's connection does. Lines, each a tab-separated list:
//   to the host:  apps NAME BUNDLE NAME BUNDLE ...  and  described BUNDLE JSON ICON-BASE64
//   from the host: describe BUNDLE  and  run NAME PORT
static int leap_send(int fd, const char *text) {
    for (size_t sent = 0, length = strlen(text); sent < length;) {
        ssize_t wrote = send(fd, text + sent, length - sent, 0);
        if (wrote <= 0)
            return 1;
        sent += (size_t)wrote;
    }
    return 0;
}

// The first line of a tool's output that starts with `start`, in place.
static char *leap_line(char *text, char start) {
    for (char *line = text; line && *line; line = strchr(line, '\n') ? strchr(line, '\n') + 1 : NULL)
        if (*line == start) {
            char *end = strchr(line, '\n');
            if (end)
                *end = 0;
            return line;
        }
    return "";
}

static int leap_describe(int fd, const char *menu_tool, char *path) {
    char *const read_it[] = {(char *)menu_tool, "describe", "--path", path, NULL};
    char *const icon_of[] = {(char *)menu_tool, "icon", "--path", path, NULL};
    char *description = run_tool(read_it), *icon = run_tool(icon_of);
    const char *json = description ? leap_line(description, '{') : "";
    if (icon && (icon[0] == '#' || strchr(icon, ' ')))
        icon[0] = 0;
    if (icon)
        icon[strcspn(icon, "\r\n")] = 0;
    int failed = leap_send(fd, "described\t") || leap_send(fd, path) || leap_send(fd, "\t") || leap_send(fd, json) ||
                 leap_send(fd, "\t") || leap_send(fd, icon ? icon : "") || leap_send(fd, "\n");
    free(description);
    free(icon);
    return failed;
}

#define LEAP_CHILDREN 64
static pid_t leap_children[LEAP_CHILDREN];

static void leap_run(const char *self, const char *menu_tool, const char *name, const char *port) {
    pid_t child = fork();
    if (child == 0) {
        char log[PATH_MAX];
        snprintf(log, sizeof(log), "/tmp/sg/leap-%d.log", getpid());
        int fd = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            dup2(fd, 1);
            dup2(fd, 2);
            close(fd);
        }
        execl(self, "seamless-guest", "tree", "--app", name, "--session", "--shared", "--no-pixels", "--menu-tool",
              menu_tool, "--port", port, "--seconds", "0", (char *)NULL);
        _exit(127);
    }
    for (int i = 0; child > 0 && i < LEAP_CHILDREN; i++)
        if (!leap_children[i]) {
            leap_children[i] = child;
            break;
        }
}

static void leap_list(char *out, size_t size) {
    snprintf(out, size, "apps");
    size_t used = strlen(out);
    pid_t seen[64];
    int seen_count = 0;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list) && seen_count < 64; i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(list, i);
        CGRect bounds = bounds_for(d);
        pid_t pid = int_for(d, kCGWindowOwnerPID);
        if (int_for(d, kCGWindowLayer) != 0 || bounds.size.width < 1 || bounds.size.height < 1)
            continue;
        int known = 0;
        for (int k = 0; k < seen_count; k++)
            known |= seen[k] == pid;
        if (known)
            continue;
        seen[seen_count++] = pid;
        char path[PROC_PIDPATHINFO_MAXSIZE], owner[256];
        text_for(d, kCGWindowOwnerName, owner, sizeof(owner));
        char *end = proc_pidpath(pid, path, sizeof(path)) > 0 ? strstr(path, ".app/Contents/MacOS/") : NULL;
        if (!end || tree_owner_is_service(owner))
            continue;
        end[4] = 0;
        // What belongs to the system's desktop rather than being an app someone opened.
        if (!strncmp(path, "/System/Library/CoreServices/", 29) && strcmp(path + 29, "Finder.app") &&
            strncmp(path + 29, "Applications/", 13))
            continue;
        int wrote = snprintf(out + used, size - used, "\t%s\t%s", owner, path);
        if (wrote < 0 || (size_t)wrote >= size - used)
            break;
        used += (size_t)wrote;
    }
    if (list)
        CFRelease(list);
    if (used + 1 < size)
        strcpy(out + used, "\n");
}

// While a desktop's showing as host apps, the guest's Dock mustn't paint over a window it's cropped from, and its
// shadows mustn't show beside ones the host draws. The Dock's way of hiding is a saved preference, so what puts it back
// is written first, as a login item that deletes itself, for a guest that stops with no chance to undo it. It stays
// alive through anything that ends this process: a child that waits for a pipe to close.
#define LEAP_RESTORE_PLIST "Library/LaunchAgents/com.mac.virtualintelmac.seamless-restore.plist"
static const char leap_hide_dock[] =
    "cd; plist=$HOME/" LEAP_RESTORE_PLIST "\n"
    "if ! [ -f $plist ]; then\n"
    "  mkdir -p Library/LaunchAgents\n"
    "  hide=$(defaults read com.apple.dock autohide 2>/dev/null); delay=$(defaults read com.apple.dock autohide-delay "
    "2>/dev/null)\n"
    "  back='defaults delete com.apple.dock autohide'\n"
    "  [ -n \"$hide\" ] && back=\"defaults write com.apple.dock autohide -bool $hide\"\n"
    "  back=\"$back; defaults delete com.apple.dock autohide-delay\"\n"
    "  [ -n \"$delay\" ] && back=\"$back; defaults write com.apple.dock autohide-delay -float $delay\"\n"
    "  back=\"$back; /usr/bin/killall Dock; rm -f $plist; launchctl remove com.mac.virtualintelmac.seamless-restore; "
    "true\"\n"
    "  domain=${plist%.plist}\n"
    "  defaults write $domain Label -string com.mac.virtualintelmac.seamless-restore\n"
    "  defaults write $domain RunAtLoad -bool true\n"
    "  defaults write $domain ProgramArguments -array /bin/sh -c \"$back\"\n"
    "fi\n"
    "defaults write com.apple.dock autohide -bool true; defaults write com.apple.dock autohide-delay -float 1000; "
    "/usr/bin/killall Dock\n";
static const char leap_show_dock[] =
    "cd; plist=$HOME/" LEAP_RESTORE_PLIST
    "; [ -f $plist ] && /bin/sh -c \"$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' $plist)\"; true\n";

static void leap_set_guest_shadows(int off) {
    typedef int (*SetOptions)(int);
    typedef int (*GetOptions)(int *);
    SetOptions set = guest_symbol("CGSSetDebugOptions", "SLSSetDebugOptions");
    GetOptions get = guest_symbol("CGSGetDebugOptions", "SLSGetDebugOptions");
    // With no connection to WindowServer yet, Mojave answers that it's an invalid one.
    int (*connection)(void) = guest_symbol("CGSMainConnectionID", "SLSMainConnectionID");
    if (connection)
        connection();
    int options = 0;
    if (get)
        get(&options);
    int result = set ? set(off ? options | 0x4000 : options & ~0x4000) : -1;
    // SkyLight's refuses that as an invalid connection, so perhaps it wants one.
    if (result == 1002 && connection)
        result = ((int (*)(int, int))set)(connection(), off ? options | 0x4000 : options & ~0x4000);
    printf("# guest shadows %s: %d\n", off ? "off" : "on", result);
    fflush(stdout);
}

// What the session's launcher leaves in the environment doesn't include this, and the scripts need it.
static void leap_set_home(void) {
    struct passwd *user = getpwuid(getuid());
    if (user)
        setenv("HOME", user->pw_dir, 1);
}

// Asks the hook, if it's loaded and has this, for each window on its own surface in place of the display.
static int leap_set_own_surfaces(const char *self, int on) {
    if (access(SWS_PATH, R_OK) || (darwin_major() != 18 && darwin_major() != 13))
        return 0;
    char scale[32];
    snprintf(scale, sizeof(scale), "%g", display_scale());
    char *const turn_on[] = {(char *)self, "gpu", "--scale", scale, "--mode", "1", "--skip-desktop", NULL};
    char *const turn_off[] = {(char *)self, "gpu", "--mode", "0", NULL};
    free(run_tool(on ? turn_on : turn_off));
    return on;
}

static int leap_restore(const char *menu_tool) {
    leap_set_home();
    char self[PATH_MAX];
    uint32_t length = sizeof(self);
    if (!_NSGetExecutablePath(self, &length))
        leap_set_own_surfaces(self, 0);
    // WindowServer has only been drawing what changes, and the display hasn't been getting even that.
    if (menu_tool && menu_tool[0] && (darwin_major() == 18 || darwin_major() == 13)) {
        sleep(1);
        char *const redraw[] = {(char *)menu_tool, "redraw-display", NULL};
        free(run_tool(redraw));
    }
    printf("# restoring\n");
    fflush(stdout);
    leap_set_guest_shadows(0);
    int dock = system(leap_show_dock);
    printf("# dock: %d\n", dock);
    return dock != 0;
}

// For the display's frames: on windows' own surfaces, the Dock and shadows aren't in anything shown. Restarting the
// Dock there would also bring it new windows the hook wasn't told to skip.
static void leap_hide_for_frames(void) {
    leap_set_home();
    leap_set_guest_shadows(1);
    system(leap_hide_dock);
}

// Puts everything back however this process ends, which includes the display, if windows' own surfaces had turned it
// off.
static void leap_arrange_restore(const char *menu_tool) {
    int ends[2];
    if (pipe(ends))
        return;
    if (fork() == 0) {
        close(ends[1]);
        // Not to keep the agent's run open, nor to go when whatever started this cleans up after it.
        setsid();
        int out = open("/tmp/seamless-leap-restore.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        dup2(out, 0);
        dup2(out, 1);
        dup2(out, 2);
        printf("# waiting\n");
        fflush(stdout);
        signal(SIGHUP, SIG_IGN);
        signal(SIGTERM, SIG_IGN);
        char byte;
        while (read(ends[0], &byte, 1) > 0) {
        }
        // As a new program, since a connection to WindowServer doesn't survive a fork.
        char self[PATH_MAX];
        uint32_t length = sizeof(self);
        if (!_NSGetExecutablePath(self, &length))
            execl(self, "seamless-guest", "leap-restore", "--menu-tool", menu_tool, (char *)NULL);
        _exit(1);
    }
    close(ends[0]);
    fcntl(ends[1], F_SETFD, FD_CLOEXEC);
}

static int leap(const char *host, int port, const char *menu_tool, int own_surfaces) {
    char self[PATH_MAX];
    uint32_t length = sizeof(self);
    if (_NSGetExecutablePath(self, &length))
        return 1;
    int fd = connect_to(host, port);
    if (fd < 0) {
        printf("# ERROR can't reach the host: %s\n", strerror(errno));
        return 3;
    }
    leap_arrange_restore(menu_tool);
    if (own_surfaces && leap_set_own_surfaces(self, 1)) {
        if (leap_send(fd, "gpu\n"))
            return 0;
    } else {
        leap_hide_for_frames();
    }
    static char input[1 << 16], listed[1 << 14], last[1 << 14];
    size_t have = 0;
    double said = 0;
    for (;;) {
        struct pollfd ready = {fd, POLLIN, 0};
        if (poll(&ready, 1, 300) > 0) {
            ssize_t got = recv(fd, input + have, sizeof(input) - have - 1, 0);
            if (got <= 0)
                break;
            have += (size_t)got;
            input[have] = 0;
            char *line = input;
            for (char *end; (end = strchr(line, '\n')); line = end + 1) {
                *end = 0;
                char *first = strchr(line, '\t'), *second = first ? strchr(first + 1, '\t') : NULL;
                if (first)
                    *first = 0;
                if (second)
                    *second = 0;
                if (first && !strcmp(line, "describe") && leap_describe(fd, menu_tool, first + 1))
                    goto done;
                if (second && !strcmp(line, "run"))
                    leap_run(self, menu_tool, first + 1, second + 1);
                if (!strcmp(line, "gpu-off")) {
                    leap_set_own_surfaces(self, 0);
                    leap_hide_for_frames();
                }
            }
            have -= (size_t)(line - input);
            memmove(input, line, have + 1);
        }
        for (int i = 0; i < LEAP_CHILDREN; i++)
            if (leap_children[i] && waitpid(leap_children[i], NULL, WNOHANG) == leap_children[i])
                leap_children[i] = 0;
        leap_list(listed, sizeof(listed));
        // Again every so often, for an app whose side had trouble and is to start over.
        if (strcmp(listed, last) || now() - said > 3) {
            said = now();
            strcpy(last, listed);
            if (leap_send(fd, listed))
                break;
        }
    }
done:
    for (int i = 0; i < LEAP_CHILDREN; i++)
        if (leap_children[i])
            kill(leap_children[i], SIGKILL);
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
    if (!strcmp(command, "hw-loop")) {
        // A composite of one window by WindowServer, on the GPU, as fast as it'll go, with its pixels never read here.
        if (geteuid() == 0 && !in_session)
            return run_in_console_session(argc, argv, 1);
        if (flag(argc, argv, "--open") && !open_app(app))
            return 1;
        sleep(5);
        CGWindowID window = find_window(app);
        int (*connection)(void) = guest_symbol("CGSMainConnectionID", "SLSMainConnectionID");
        CFArrayRef (*hw)(int, const CGWindowID *, int, uint32_t) =
            guest_symbol("CGSHWCaptureWindowList", "SLSHWCaptureWindowList");
        if (!window || !connection || !hw)
            return 1;
        double seconds = atof(option(argc, argv, "--seconds", "20")), started = now();
        double hz = atof(option(argc, argv, "--hz", "0"));
        unsigned made = 0;
        while (now() - started < seconds) {
            CFArrayRef images = hw(connection(), &window, 1, 0x1);
            if (images)
                CFRelease(images);
            made++;
            double ahead = hz ? started + made / hz - now() : 0;
            if (ahead > 0)
                usleep((useconds_t)(ahead * 1000000));
        }
        printf("hw_loop %u composites, %.1f/s, %.1f ms each\n", made, made / (now() - started),
               (now() - started) * 1000 / made);
        return 0;
    }
    if (!strcmp(command, "gpu")) {
        // Turns the hook's per-window composites on or off on Mojave, and reports them. See seamless-ws-mojave.h.
        if (flag(argc, argv, "--skip-desktop") && geteuid() == 0 && !in_session)
            return run_in_console_session(argc, argv, 1);
        int fd = open(SWS_PATH, O_RDWR);
        struct SWSTable *t =
            fd >= 0 ? mmap(NULL, sizeof(struct SWSTable), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) : MAP_FAILED;
        if (t == MAP_FAILED)
            return 1;
        if (option(argc, argv, "--scale", NULL))
            t->gpu_scale = atof(option(argc, argv, "--scale", "1"));
        if (flag(argc, argv, "--skip-desktop")) {
            // Below every app's windows, and the Dock's: a session doesn't show these.
            CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
            uint32_t skipped = 0;
            for (CFIndex i = 0; windows && i < CFArrayGetCount(windows) && skipped < 64; i++) {
                CFDictionaryRef w = CFArrayGetValueAtIndex(windows, i);
                int level = 0, number = 0;
                CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &level);
                CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowNumber), kCFNumberIntType, &number);
                if (level < 0 || level == kCGDockWindowLevel)
                    t->gpu_skip[skipped++] = (uint32_t)number;
            }
            if (windows)
                CFRelease(windows);
            t->gpu_skip_count = skipped;
            printf("skipping %u windows\n", skipped);
        }
        if (option(argc, argv, "--blobs", NULL)) {
            // Each of a census's contents to a file, 4 bytes a pixel: blob-N-WxH-ROW.raw.
            for (uint32_t i = 0; i < t->gpu_blob_count; i++) {
                char path[512];
                const struct SWSBlob *b = &t->gpu_blobs[i];
                snprintf(path, sizeof(path), "%s/blob-%u-%ux%u-%u.raw", option(argc, argv, "--blobs", "/tmp"), i,
                         b->width, b->height, b->row);
                int out = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
                if (out >= 0) {
                    write(out, t->arena + b->offset, (size_t)b->height * b->row);
                    close(out);
                }
            }
            printf("%u blobs\n", t->gpu_blob_count);
        }
        if (option(argc, argv, "--census", NULL))
            t->gpu_census = atoi(option(argc, argv, "--census", "0"));
        if (option(argc, argv, "--no-shadow", NULL))
            t->gpu_no_shadow = (uint32_t)atoi(option(argc, argv, "--no-shadow", "0"));
        if (option(argc, argv, "--mode", NULL))
            t->gpu_mode = (uint32_t)atoi(option(argc, argv, "--mode", "0"));
        printf("gpu mode %u scale %g generate %llu composites %llu whole %llu seconds %.3f\n", t->gpu_mode,
               t->gpu_scale, t->gpu_generate_calls, t->gpu_composites, t->gpu_whole_composites,
               (double)t->gpu_ticks * t->ticks_numer / t->ticks_denom / 1e9);
        for (uint32_t i = 0; flag(argc, argv, "--rows") && i < t->gpu_backdrop_count; i++) {
            const volatile struct SWSBackdrop *b = &t->gpu_backdrops[i];
            printf("backdrop id %u order %u material %u active %u blend %u rect %g,%g %gx%g saturation %g\n", b->id,
                   b->order, b->material, b->active, b->blend, b->x, b->y, b->width, b->height, b->saturation);
        }
        for (uint32_t i = 0; flag(argc, argv, "--rows") && i < t->gpu_row_count; i++) {
            const struct SWSGPURow *r = &t->gpu_rows[i];
            printf("row %u id %u frames %u content %g,%g %gx%g window %g,%g %gx%g\n", i, r->id, r->frames, r->x, r->y,
                   r->width, r->height, r->window_x, r->window_y, r->window_width, r->window_height);
        }
        return 0;
    }
    if (!strcmp(command, "place")) {
        // Asks the hook to draw every window of an app this far from where it is, in device pixels.
        if (geteuid() == 0 && !in_session)
            return run_in_console_session(argc, argv, 1);
        CGWindowID window = find_window(app);
        int fd = open(SWS_PATH, O_RDWR);
        struct SWSTable *placed =
            fd >= 0 ? mmap(NULL, sizeof(struct SWSTable), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) : MAP_FAILED;
        if (!window || placed == MAP_FAILED)
            return 1;
        placed->placements[0].dx = atoi(option(argc, argv, "--dx", "0"));
        placed->placements[0].dy = atoi(option(argc, argv, "--dy", "0"));
        placed->placements[0].id = window;
        printf("# window %u placed; %llu placed redraws so far\n", window, placed->placed_redraws);
        sleep(atoi(option(argc, argv, "--wait", "3")));
        printf("# %llu placed redraws now\n", placed->placed_redraws);
        return 0;
    }
    if (!strcmp(command, "capture-bench")) {
        if (geteuid() == 0 && !in_session)
            return run_in_console_session(argc, argv, 1);
        if (flag(argc, argv, "--open") && !open_app(app))
            return 1;
        sleep(5);
        return capture_bench(app);
    }
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
    if (!strcmp(command, "leap-restore"))
        return leap_restore(option(argc, argv, "--menu-tool", ""));
    if (!strcmp(command, "leap")) {
        if (geteuid() == 0 && !in_session)
            return run_in_console_session(argc, argv, 1);
        return leap(option(argc, argv, "--host", "10.0.2.2"), atoi(option(argc, argv, "--port", "7654")),
                    option(argc, argv, "--menu-tool", ""), flag(argc, argv, "--own-surfaces"));
    }
    if (!strcmp(command, "tree") || !strcmp(command, "program-tree")) {
        // Only ever reads windows, so it's safe on the host; the program form opens an app, so it isn't.
        int demo = !strcmp(command, "program-tree");
        if (demo && darwin_major() > 20)
            return 64;
        if (geteuid() == 0 && !in_session)
            return run_in_console_session(argc, argv, 1);
        // A session lasts as long as the app does, and the rest are runs that mustn't outlive a stuck guest.
        session_app = flag(argc, argv, "--session") ? app : NULL;
        no_pixels = flag(argc, argv, "--no-pixels");
        tree_shared = flag(argc, argv, "--shared");
        if (tree_shared) {
            int fd = open(SWS_PATH, O_RDONLY);
            void *mapped = fd >= 0 ? mmap(NULL, sizeof(struct SWSTable), PROT_READ, MAP_SHARED, fd, 0) : MAP_FAILED;
            if (mapped != MAP_FAILED && ((struct SWSTable *)mapped)->magic == SWS_MAGIC)
                tree_gpu_table = mapped;
        }
        alarm(session_app ? 0 : 600);
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
        session_menu_tool = menu_tool;
        if (session_app && flag(argc, argv, "--test-badge") && !(session_test_badge_pid = fork())) {
            execl(menu_tool, menu_tool, "badge-self", "--seconds", "60", (char *)NULL);
            _exit(127);
        }
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
        send_all_finish();
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
