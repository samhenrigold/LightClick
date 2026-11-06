// Host side of the seamless input probe.
//
//     seamless-input-host --self-test     Real NSEvents, from CGEvents with the guest's private fields, through the
//     real
//                                         view to the wire. Also proves those field numbers on this host. No window
//                                         server posting; nothing leaves the process.
//     seamless-input-host --hotkeys       What this Mac's system takes before any app sees it.
//     seamless-input-host --port P --seconds S    A window that sends your real trackpad and keyboard to a guest.
#import "seamless-input-view.h"
#include "seamless-input-queue.h"
#include "seamless-inject.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

// ---- Self-test ----

static int failures;
static uint8_t captured[1 << 14];
static size_t capturedSize;

#define CHECK(condition, ...)                                                                                          \
    do {                                                                                                               \
        if (!(condition)) {                                                                                            \
            failures++;                                                                                                \
            printf("FAILED %s:%d ", __func__, __LINE__);                                                               \
            printf(__VA_ARGS__);                                                                                       \
            putchar('\n');                                                                                             \
        }                                                                                                              \
    } while (0)

static struct SWMMessage takeOne(void) {
    struct SWMMessage m;
    memset(&m, 0, sizeof(m));
    size_t used = 0;
    enum SWMParse result = swm_parse(captured, capturedSize, &m, &used);
    CHECK(result == SWM_OK, "nothing valid captured (%zu bytes)", capturedSize);
    if (result == SWM_OK) {
        memmove(captured, captured + used, capturedSize - used);
        capturedSize -= used;
    }
    return m;
}

static NSEvent *fieldEvent(int type, void (^fill)(CGEventRef)) {
    CGEventRef e = swi_event(type, CGPointMake(100, 100), 0);
    fill(e);
    NSEvent *event = [NSEvent eventWithCGEvent:e];
    CFRelease(e);
    return event;
}

// The fields are what the guest's injector sets. If NSEvent reads them back as these types on this OS, the numbers are
// right here; the guest binaries were read for the same numbers, and the probe measures them there.
static void gesturesFromFields(SeamlessInputView *view) {
    NSEvent *e = fieldEvent(SWI_TYPE_GESTURE, ^(CGEventRef c) {
      SWI_SET_INT(c, SWI_F_GESTURE_SUBTYPE, SWI_SUB_MAGNIFY);
      SWI_SET_DOUBLE(c, SWI_F_MAGNIFICATION, 0.25);
      SWI_SET_INT(c, SWI_F_GESTURE_PHASE, SWP_CHANGED);
    });
    printf("magnify: type %lu magnification %.4f phase %lu\n", (unsigned long)e.type, e.magnification,
           (unsigned long)e.phase);
    CHECK(e.type == NSEventTypeMagnify && e.magnification == 0.25 && e.phase == NSEventPhaseChanged, "magnify fields");
    [view magnifyWithEvent:e];
    struct SWMMessage m = takeOne();
    CHECK(m.type == SWM_GESTURE && m.u.gesture.kind == SWG_MAGNIFY && m.u.gesture.a == 0.25f &&
              m.u.gesture.phase == SWP_CHANGED,
          "magnify wire");

    e = fieldEvent(SWI_TYPE_GESTURE, ^(CGEventRef c) {
      SWI_SET_INT(c, SWI_F_GESTURE_SUBTYPE, SWI_SUB_ROTATE);
      SWI_SET_DOUBLE(c, SWI_F_ROTATION, 12.5);
      SWI_SET_INT(c, SWI_F_GESTURE_PHASE, SWP_BEGAN);
    });
    printf("rotate: type %lu rotation %.3f phase %lu\n", (unsigned long)e.type, e.rotation, (unsigned long)e.phase);
    CHECK(e.type == NSEventTypeRotate && e.rotation == 12.5f && e.phase == NSEventPhaseBegan, "rotate fields");
    [view rotateWithEvent:e];
    m = takeOne();
    CHECK(m.u.gesture.kind == SWG_ROTATE && m.u.gesture.a == 12.5f && m.u.gesture.phase == SWP_BEGAN, "rotate wire");

    e = fieldEvent(SWI_TYPE_GESTURE, ^(CGEventRef c) {
      SWI_SET_INT(c, SWI_F_GESTURE_SUBTYPE, SWI_SUB_SWIPE);
      SWI_SET_INT(c, SWI_F_MOMENTUM, 1);
      SWI_SET_INT(c, SWI_F_SWIPE_DIRECTION, 4);
    });
    printf("swipe: type %lu dx %.0f dy %.0f\n", (unsigned long)e.type, e.deltaX, e.deltaY);
    CHECK(e.type == NSEventTypeSwipe && e.deltaX == 1 && e.deltaY == 0, "swipe left");
    [view swipeWithEvent:e];
    m = takeOne();
    CHECK(m.u.gesture.kind == SWG_SWIPE && m.u.gesture.a == 1, "swipe wire");
    e = fieldEvent(SWI_TYPE_GESTURE, ^(CGEventRef c) {
      SWI_SET_INT(c, SWI_F_GESTURE_SUBTYPE, SWI_SUB_SWIPE);
      SWI_SET_INT(c, SWI_F_MOMENTUM, 2);
      SWI_SET_INT(c, SWI_F_SWIPE_DIRECTION, 2);
    });
    printf("swipe: type %lu dx %.0f dy %.0f\n", (unsigned long)e.type, e.deltaX, e.deltaY);
    CHECK(e.type == NSEventTypeSwipe && e.deltaY == -1, "swipe down");

    e = fieldEvent(SWI_TYPE_GESTURE, ^(CGEventRef c) {
      SWI_SET_INT(c, SWI_F_GESTURE_SUBTYPE, SWI_SUB_SMART_MAGNIFY);
    });
    printf("smart magnify: type %lu\n", (unsigned long)e.type);
    CHECK(e.type == NSEventTypeSmartMagnify, "smart magnify type");
    [view smartMagnifyWithEvent:e];
    CHECK(takeOne().u.gesture.kind == SWG_SMART_MAGNIFY, "smart magnify wire");

    e = fieldEvent(SWI_TYPE_GESTURE, ^(CGEventRef c) {
      SWI_SET_INT(c, SWI_F_GESTURE_SUBTYPE, SWI_SUB_PRESSURE);
      SWI_SET_INT(c, SWI_F_STAGE, 2);
      SWI_SET_DOUBLE(c, SWI_F_STAGE_TRANSITION, 0.5);
      SWI_SET_DOUBLE(c, SWI_F_PRESSURE, 0.75);
      SWI_SET_INT(c, SWI_F_GESTURE_PHASE, SWP_CHANGED);
    });
    printf("pressure: type %lu stage %ld transition %.3f pressure %.3f phase %lu\n", (unsigned long)e.type,
           (long)e.stage, (double)e.stageTransition, e.pressure, (unsigned long)e.phase);
    CHECK(e.type == NSEventTypePressure && e.stage == 2 && e.stageTransition == 0.5f, "pressure fields");
    [view pressureChangeWithEvent:e];
    m = takeOne();
    CHECK(m.u.gesture.kind == SWG_PRESSURE && m.u.gesture.stage == 2 && m.u.gesture.b == 0.5f, "pressure wire");

    // A force click asks for Look Up itself, since a guest's AppKit won't, and only once.
    m = takeOne();
    CHECK(m.u.gesture.kind == SWG_QUICK_LOOK, "stage 2 asks for Look Up");
    [view pressureChangeWithEvent:e];
    CHECK(takeOne().u.gesture.kind == SWG_PRESSURE && capturedSize == 0, "Look Up only once");

    e = fieldEvent(SWI_TYPE_SCROLL, ^(CGEventRef c) {
      // In this order, as Apple's agent does: setting one of these rewrites the ones after it.
      SWI_SET_INT(c, SWI_F_WHEEL_LINES_Y, -2);
      SWI_SET_INT(c, SWI_F_WHEEL_FIXED_Y, -2.5 * 65536);
      SWI_SET_INT(c, SWI_F_WHEEL_POINTS_Y, -25);
      SWI_SET_INT(c, SWI_F_WHEEL_PHASE, SWP_BEGAN);
      SWI_SET_INT(c, SWI_F_WHEEL_CONTINUOUS, 1);
      SWI_SET_INT(c, SWI_F_WHEEL_INVERTED, 1);
    });
    printf("scroll: type %lu sy %.3f dy %.3f precise %d inverted %d phase %lu\n", (unsigned long)e.type,
           e.scrollingDeltaY, e.deltaY, e.hasPreciseScrollingDeltas, e.isDirectionInvertedFromDevice,
           (unsigned long)e.phase);
    CHECK(e.type == NSEventTypeScrollWheel && e.scrollingDeltaY == -25 && e.hasPreciseScrollingDeltas &&
              e.phase == NSEventPhaseBegan,
          "scroll fields");
    [view scrollWheel:e];
    m = takeOne();
    CHECK(m.u.gesture.kind == SWG_SCROLL && m.u.gesture.b == -25 && (m.u.gesture.flags & SWG_PRECISE) &&
              m.u.gesture.phase == SWP_BEGAN,
          "scroll wire");

    e = fieldEvent(SWI_TYPE_SCROLL, ^(CGEventRef c) {
      SWI_SET_INT(c, SWI_F_WHEEL_POINTS_Y, -5);
      SWI_SET_INT(c, SWI_F_MOMENTUM, SWM_MOMENTUM_CHANGED);
      SWI_SET_INT(c, SWI_F_WHEEL_CONTINUOUS, 1);
    });
    printf("momentum: phase %lu momentum %lu\n", (unsigned long)e.phase, (unsigned long)e.momentumPhase);
    CHECK(e.momentumPhase == NSEventPhaseChanged, "momentum fields");
    [view scrollWheel:e];
    m = takeOne();
    CHECK(m.u.gesture.momentum == SWM_MOMENTUM_CHANGED && m.u.gesture.phase == SWP_NONE, "momentum wire");
}

static NSEvent *keyEvent(NSEventType type, unsigned short code, NSEventModifierFlags flags, NSString *characters) {
    return [NSEvent keyEventWithType:type
                            location:NSZeroPoint
                       modifierFlags:flags
                           timestamp:0
                        windowNumber:0
                             context:nil
                          characters:characters
         charactersIgnoringModifiers:characters
                           isARepeat:NO
                             keyCode:code];
}

static void keys(SeamlessInputView *view, NSWindow *window) {
    [window makeFirstResponder:view];
    capturedSize = 0;
    struct {
        const char *name;
        unsigned short code;
        NSEventModifierFlags flags;
        BOOL host;
    } routes[] = {
        {"Cmd-Q", 12, NSEventModifierFlagCommand, NO},
        {"Cmd-W", 13, NSEventModifierFlagCommand, NO},
        {"Cmd-S", 1, NSEventModifierFlagCommand, NO},
        {"Cmd-H", 4, NSEventModifierFlagCommand, YES},
        {"Cmd-Opt-H", 4, NSEventModifierFlagCommand | NSEventModifierFlagOption, YES},
        {"Cmd-Shift-H", 4, NSEventModifierFlagCommand | NSEventModifierFlagShift, NO},
        {"Cmd-M", 46, NSEventModifierFlagCommand, YES},
        {"Cmd-`", 50, NSEventModifierFlagCommand, YES},
        {"Cmd-Ctrl-F", 3, NSEventModifierFlagCommand | NSEventModifierFlagControl, YES},
    };
    for (size_t i = 0; i < sizeof(routes) / sizeof(routes[0]); i++) {
        BOOL taken = [view performKeyEquivalent:keyEvent(NSEventTypeKeyDown, routes[i].code, routes[i].flags, @"x")];
        CHECK(taken == !routes[i].host, "%s", routes[i].name);
        if (taken) {
            struct SWMMessage down = takeOne(), up = takeOne();
            CHECK(down.type == SWM_KEY && down.u.key.down && up.type == SWM_KEY && !up.u.key.down &&
                      down.u.key.keycode == routes[i].code,
                  "%s reaches the guest as a press and release", routes[i].name);
        }
        CHECK(capturedSize == 0, "%s sent something extra", routes[i].name);
    }
    // A plain key.
    [view keyDown:keyEvent(NSEventTypeKeyDown, 0, 0, @"a")];
    struct SWMMessage m = takeOne();
    CHECK(m.type == SWM_KEY && m.u.key.keycode == 0 && m.u.key.down, "A down");
    [view keyUp:keyEvent(NSEventTypeKeyUp, 0, 0, @"a")];
    m = takeOne();
    CHECK(m.type == SWM_KEY && !m.u.key.down, "A up");

    // Losing focus with a key held releases it and clears modifiers, so Cmd-Tab can't leave Command stuck in the guest.
    [view keyDown:keyEvent(NSEventTypeKeyDown, 13, 0, @"w")];
    takeOne();
    [view performSelector:@selector(windowResignedKey:) withObject:nil];
    m = takeOne();
    CHECK(m.type == SWM_KEY && m.u.key.keycode == 13 && !m.u.key.down, "focus loss releases a held key");
    m = takeOne();
    CHECK(m.type == SWM_MODIFIERS && m.u.modifiers == 0, "focus loss clears modifiers");

    [view insertText:@"日本" replacementRange:NSMakeRange(NSNotFound, 0)];
    m = takeOne();
    CHECK(m.type == SWM_TEXT && m.u.text.kind == SWT_INSERT && m.u.text.length == 6, "insertText");
    [view forwardInputSource];
    m = takeOne();
    CHECK(m.type == SWM_TEXT && m.u.text.kind == SWT_INPUT_SOURCE && m.u.text.length > 0, "input source");
    printf("input source here: %.*s\n", m.u.text.length, m.u.text.bytes);
    CHECK([view acceptsFirstMouse:nil], "first mouse");
}

static int selfTest(void) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 200)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    SeamlessInputView *view = [[SeamlessInputView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    view.guestWindow = 7;
    view.send = ^(const uint8_t *bytes, size_t size) {
      CHECK(size && size <= sizeof(captured) - capturedSize, "send");
      memcpy(captured + capturedSize, bytes, size);
      capturedSize += size;
    };
    window.contentView = view;
    capturedSize = 0;
    gesturesFromFields(view);
    keys(view, window);
    printf(failures ? "seamless input host: %d FAILED\n" : "seamless input host: ok\n", failures);
    return failures ? 1 : 0;
}

// ---- Symbolic hotkeys ----

// These reach no app, so they need no route. Private, but this is a diagnostic: the design relies on the system taking
// them.
static int hotkeys(void) {
    bool (*enabled)(int) = (bool (*)(int))dlsym(RTLD_DEFAULT, "CGSIsSymbolicHotKeyEnabled");
    int (*value)(int, unichar *, unichar *, uint32_t *) =
        (int (*)(int, unichar *, unichar *, uint32_t *))dlsym(RTLD_DEFAULT, "CGSGetSymbolicHotKeyValue");
    if (!enabled || !value)
        return 1;
    for (int id = 0; id < 512; id++) {
        unichar character = 0, code = 0;
        uint32_t flags = 0;
        if (enabled(id) && !value(id, &character, &code, &flags) && code != 0xFFFF)
            printf("hotkey %-4d code %-4u flags %#x\n", id, code, flags);
    }
    return 0;
}

// ---- Live ----

static struct SWQueue queue;
static int clientFD = -1;
static dispatch_source_t writable;
static unsigned long messages;

static void flushQueue(void) {
    if (clientFD < 0)
        return;
    int result = swq_flush(&queue, clientFD);
    if (result < 0) {
        close(clientFD);
        clientFD = -1;
    } else if (result == 0 && !writable) {
        // Only while there's a backlog, so normal input takes the direct path from the event handler.
        writable =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)clientFD, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(writable, ^{
          flushQueue();
        });
        dispatch_resume(writable);
    } else if (result == 1 && writable) {
        dispatch_source_cancel(writable);
        writable = nil;
    }
}

static int live(int port, double seconds) {
    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 420, 320)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Trackpad here: it goes to the guest's window A";
    SeamlessInputView *view = [[SeamlessInputView alloc] initWithFrame:window.contentLayoutRect];
    view.guestWindow = 1;
    view.send = ^(const uint8_t *bytes, size_t size) {
      if (size && swq_push(&queue, bytes, size))
          messages++;
      flushQueue();
    };
    window.contentView = view;
    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:view];
    [app activateIgnoringOtherApps:YES];

    int listener = socket(AF_INET, SOCK_STREAM, 0), on = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 1)) {
        perror("listen");
        return 1;
    }
    printf("Listening on 127.0.0.1:%d, which a guest reaches as 10.0.2.2:%d\n", port, port);
    fflush(stdout);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
      int client = accept(listener, NULL, NULL);
      int yes = 1;
      setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
      fcntl(client, F_SETFL, O_NONBLOCK);
      dispatch_async(dispatch_get_main_queue(), ^{
        clientFD = client;
        puts("# guest connected: use the trackpad and keyboard in the window");
        fflush(stdout);
      });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      printf("# captured %lu messages\n", messages);
      fflush(stdout);
      exit(0);
    });
    [app run];
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        int port = 0;
        double seconds = 60;
        [NSApplication sharedApplication];
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--self-test"))
                return selfTest();
            if (!strcmp(argv[i], "--hotkeys"))
                return hotkeys();
            if (!strcmp(argv[i], "--port") && i + 1 < argc)
                port = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--seconds") && i + 1 < argc)
                seconds = atof(argv[++i]);
        }
        if (port)
            return live(port, seconds);
        fputs("usage: seamless-input-host --self-test | --hotkeys | --port P --seconds S\n", stderr);
        return 64;
    }
}
