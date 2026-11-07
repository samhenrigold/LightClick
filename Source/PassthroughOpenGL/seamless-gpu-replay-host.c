/* Research: each guest window as its own host IOSurface, drawn on the host's GPU with no readback in the guest.
 * WindowServer's display context draws each window into its primary drawable in screen pixels. So each such draw runs a
 * second time here, into the IOSurface of the window it belongs to, with the viewport and scissor moved by that
 * window's origin. A marker before each window's layers, with its ID and bounds, arrives in the same stream, as
 * glPassThrough tokens from probes/seamless-ws-hook.c: a no-op in GL, so neither the guest's GL client nor the wire
 * changes. Off unless LC_SEAMLESS_GPU_REPLAY is set.
 *
 * An update of part of the display doesn't draw on the display's drawable: WindowServer gets a new one of just that
 * part's bounds each time, whose origin the marker says. So everything of the right kind counts, by framebuffer, and a
 * drawable smaller than the display is moved by that.
 *
 * With the hook's gpu_mode on, a marker says the display is off: the display's own draws don't run, only the window's.
 *
 * shortcut: only what WindowServer draws arrives, so a covered part of a window stays stale until it's uncovered.
 * shortcut: a frame's fence is waited for here, for up to 8 ms, which holds up the stream that long at most, as a
 * repaint with nothing after it has no later publish to be sent from. One that takes longer waits for the next. A
 * worker waiting on fences, as direct-display-sender-host.c does, would hold nothing up.
 */
#include <mach/mach.h>
#include <math.h>
#include <servers/bootstrap.h>
#define SG_LAYER_MAGIC 11184809.0f
#define SG_LAYER_FIELDS 12
#define SG_MARGIN_POINTS 96 // As probes/seamless-viewer.m found: an active window's shadow fits in this.
#define SG_BUFFERS 3
// Drawn into, and never shared. What's drawn here stays till a shared buffer is free for it, so nothing's lost by
// waiting.
#define SG_WORK SG_BUFFERS
#define SG_STORAGE (SG_BUFFERS + 1)
#define SG_FRAME_MESSAGE 0x53474652
struct SGFrameMessage {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface;
    uint32_t window, frame, width, height;
    int32_t x, y;
};
struct SGTreeEntry {
    uint32_t id;
    int level, margin, whole, origin_x, origin_y;
    float x, y, width, height; // Pixels, on the primary drawable.
};
struct SGWindow {
    uint32_t id;
    int width, height, x, y; // Of the surface: the window with its shadow margin.
    IOSurfaceRef surface[SG_STORAGE];
    GLuint texture[SG_STORAGE], framebuffer[SG_STORAGE];
    // Each frame sent carries a send-once right to its buffer's port. The consumer holds it while it uses the frame,
    // and its going, by the consumer's letting go or its dying, is what says the buffer can be written again.
    mach_port_t hold[SG_BUFFERS];
    int held[SG_BUFFERS];
    int front, drawn, dirty, unsent;
    int ready; // The frame in front is finished, and hasn't got to the consumer.
    int cleared; // In this frame.
    int pending;
    GLsync pending_sync;
    uint64_t frames, sent, drops, draws;
    struct SGWindow *next;
};
static struct DGHostContext *sg_display;
static int64_t sg_primary_area;
static struct SGTreeEntry sg_layer;
static float sg_tokens[SG_LAYER_FIELDS], sg_scale = 1;
static int sg_token_count = -1;
static struct SGWindow *sg_windows;
static mach_port_t sg_port;
static uint64_t sg_next_lookup, sg_next_rates;
static uint64_t sg_sealed, sg_presents, sg_replayed, sg_unplaced, sg_spent, sg_blits, sg_marks, sg_odd, sg_in_use;
static FILE *sg_rates;
static int sg_replay_enabled, sg_display_off;
static mach_timebase_info_data_t sg_timebase;
struct SGImmediate {
    uint32_t op, target;
    float a, b;
};
static struct SGImmediate sg_immediate[8192];
static unsigned sg_immediate_count;
static int sg_immediate_active, sg_immediate_mode, sg_immediate_masked;
static GLboolean sg_immediate_mask[4];

static void SGToken(float value) {
    if (value == SG_LAYER_MAGIC) {
        sg_token_count = 0;
        return;
    }
    if (sg_token_count < 0)
        return;
    sg_tokens[sg_token_count++] = value;
    if (sg_token_count < SG_LAYER_FIELDS)
        return;
    sg_token_count = -1;
    const float *f = sg_tokens;
    sg_display_off = f[8] != 0;
    // One scale for the display: a window with no backing says 1 whatever the display is.
    sg_scale = fmaxf(sg_scale, f[7] / 16);
    sg_layer = (struct SGTreeEntry){(uint32_t)f[0],
                                    (int)f[1] - 1,
                                    (int)(f[6] * sg_scale),
                                    f[9] != 0,
                                    (int)((f[10] - 16384) * sg_scale),
                                    (int)((f[11] - 16384) * sg_scale),
                                    (f[2] - 16384) * sg_scale,
                                    (f[3] - 16384) * sg_scale,
                                    f[4] * sg_scale,
                                    f[5] * sg_scale};
    ++sg_marks;
}

static void SGFreeWindowStorage(struct SGWindow *w) {
    for (int i = 0; i < SG_BUFFERS; ++i) {
        if (w->hold[i])
            mach_port_mod_refs(mach_task_self(), w->hold[i], MACH_PORT_RIGHT_RECEIVE, -1);
        w->hold[i] = 0;
        w->held[i] = 0;
    }
    for (int i = 0; i < SG_STORAGE; ++i) {
        if (w->framebuffer[i])
            glDeleteFramebuffersEXT(1, &w->framebuffer[i]);
        if (w->texture[i])
            glDeleteTextures(1, &w->texture[i]);
        if (w->surface[i])
            CFRelease(w->surface[i]);
        w->framebuffer[i] = w->texture[i] = 0;
        w->surface[i] = NULL;
    }
    if (w->pending)
        glDeleteSync(w->pending_sync);
    w->drawn = w->dirty = w->pending = 0;
}

static int SGMakeWindowStorage(struct DGHostContext *c, struct SGWindow *w, int width, int height) {
    GLint rectangle = 0, draw = 0, read = 0;
    glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE_ARB, &rectangle);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_EXT, &draw);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING_EXT, &read);
    int good = 1;
    for (int i = 0; good && i < SG_BUFFERS; ++i)
        good = !mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &w->hold[i]);
    for (int i = 0; good && i < SG_STORAGE; ++i) {
        size_t row = ((size_t)width * 4 + 63) & ~(size_t)63;
        const CFStringRef keys[] = {kIOSurfaceWidth,       kIOSurfaceHeight,    kIOSurfaceBytesPerElement,
                                    kIOSurfaceBytesPerRow, kIOSurfaceAllocSize, kIOSurfacePixelFormat};
        int64_t values[] = {width, height, 4, (int64_t)row, (int64_t)(row * (size_t)height), 0x42475241};
        CFMutableDictionaryRef properties =
            CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        for (unsigned k = 0; k < 6; ++k) {
            CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &values[k]);
            CFDictionarySetValue(properties, keys[k], n);
            CFRelease(n);
        }
        w->surface[i] = IOSurfaceCreate(properties);
        CFRelease(properties);
        good = w->surface[i] != NULL;
        if (!good)
            break;
        glGenTextures(1, &w->texture[i]);
        glBindTexture(GL_TEXTURE_RECTANGLE_ARB, w->texture[i]);
        good = !DGPrivateTextureImport(c->cgl, GL_TEXTURE_RECTANGLE_ARB, GL_RGBA8, width, height, GL_BGRA,
                                       GL_UNSIGNED_INT_8_8_8_8_REV, w->surface[i], 0);
        if (!good)
            break;
        glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        good = DGClearDrawableTexture(c, w->texture[i]);
        glGenFramebuffersEXT(1, &w->framebuffer[i]);
        glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, w->framebuffer[i]);
        glFramebufferTexture2DEXT(GL_DRAW_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_RECTANGLE_ARB,
                                  w->texture[i], 0);
        good = good && glCheckFramebufferStatusEXT(GL_DRAW_FRAMEBUFFER_EXT) == GL_FRAMEBUFFER_COMPLETE_EXT;
    }
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, (GLuint)rectangle);
    glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, (GLuint)draw);
    glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, (GLuint)read);
    if (!good) {
        fprintf(stderr, "seamless-gpu: no storage for window %u at %dx%d\n", w->id, width, height);
        SGFreeWindowStorage(w);
        return 0;
    }
    w->width = width;
    w->height = height;
    return 1;
}

// The window to draw into for this tree entry, sized and placed as the entry says now.
static struct SGWindow *SGWindowFor(struct DGHostContext *c, const struct SGTreeEntry *t) {
    struct SGWindow *w = sg_windows;
    while (w && w->id != t->id)
        w = w->next;
    if (!w) {
        w = calloc(1, sizeof(*w));
        if (!w)
            return NULL;
        w->id = t->id;
        w->next = sg_windows;
        sg_windows = w;
    }
    // A shadow's margin grows when a window becomes active, with nothing else redrawn, so the room for one is fixed.
    int margin = t->margin ? (int)(SG_MARGIN_POINTS * sg_scale) : 0;
    int width = (int)ceilf(t->width) + 2 * margin, height = (int)ceilf(t->height) + 2 * margin;
    int x = (int)floorf(t->x) - margin, y = (int)floorf(t->y) - margin;
    if (width < 1 || height < 1 || width > 8192 || height > 8192)
        return NULL;
    if (!w->surface[0] || w->width != width || w->height != height) {
        // WindowServer draws only what changed, so what's there already has to come along. Nothing else will redraw it.
        struct SGWindow old = *w;
        memset(w->surface, 0, sizeof(w->surface));
        memset(w->texture, 0, sizeof(w->texture));
        memset(w->framebuffer, 0, sizeof(w->framebuffer));
        memset(w->hold, 0, sizeof(w->hold));
        memset(w->held, 0, sizeof(w->held));
        w->drawn = w->dirty = w->pending = w->ready = 0;
        w->front = 0;
        if (!SGMakeWindowStorage(c, w, width, height))
            return NULL;
        if (old.drawn) {
            GLint draw = 0, read = 0;
            GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);
            glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_EXT, &draw);
            glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING_EXT, &read);
            if (scissor)
                glDisable(GL_SCISSOR_TEST);
            int dx = old.x - x, dy = old.y - y;
            glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, old.framebuffer[SG_WORK]);
            glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, w->framebuffer[SG_WORK]);
            glBlitFramebufferEXT(0, 0, old.width, old.height, dx, dy, dx + old.width, dy + old.height,
                                 GL_COLOR_BUFFER_BIT, GL_NEAREST);
            glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, (GLuint)draw);
            glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, (GLuint)read);
            if (scissor)
                glEnable(GL_SCISSOR_TEST);
            w->drawn = 1;
        }
        // shortcut: a frame still being shown from the old storage keeps its surface through the viewer's own
        // reference.
        SGFreeWindowStorage(&old);
    }
    w->x = x;
    w->y = y;
    return w;
}

// A shared buffer nobody holds and nothing's reading, or -1. shortcut: with none free a frame waits for the next update
// of any window, so a consumer stalled past all of them as the guest goes idle shows the last frame sent till something
// changes.
static int SGFreeBuffer(struct SGWindow *w) {
    for (int n = 1; n <= SG_BUFFERS; ++n) {
        int i = (w->front + n) % SG_BUFFERS;
        struct {
            mach_msg_header_t header;
            mach_msg_max_trailer_t trailer;
        } notice;
        while (w->held[i] &&
               !mach_msg(&notice.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(notice), w->hold[i], 0, 0))
            --w->held[i];
        if (!w->held[i] && !IOSurfaceIsInUse(w->surface[i]))
            return i;
    }
    return -1;
}

struct SGSaved {
    GLint draw, viewport[4], scissor[4];
    GLboolean scissor_on;
};
// Points the context at the surface of the window whose layer is being drawn, for one draw.
static struct SGWindow *SGRedirect(struct DGHostContext *c, struct SGSaved *saved) {
    // WindowServer also draws to scratch drawables through this context, for window effects: only the display counts.
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_EXT, &saved->draw);
    if ((GLuint)saved->draw != c->framebuffer || !c->drawable || c->drawable->width <= 64 || c->drawable->height <= 64)
        return NULL;
    const struct SGTreeEntry *t = &sg_layer;
    if (!t->id) {
        ++sg_unplaced;
        return NULL;
    }
    // With the display on nobody's taking surfaces. What's drawn then wouldn't be cleared, as a window's drawn whole
    // only when the mode goes on, and it builds up: a shadow goes black, drawn over itself in each update.
    if (t->level < 0 || !sg_display_off)
        return NULL; // The desktop and the like: nobody asks for them.
    struct SGWindow *w = SGWindowFor(c, t);
    if (!w)
        return NULL;
    w->dirty = 1;
    glGetIntegerv(GL_VIEWPORT, saved->viewport);
    saved->scissor_on = glIsEnabled(GL_SCISSOR_TEST);
    glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, w->framebuffer[SG_WORK]);
    int partial = (int64_t)c->drawable->width * c->drawable->height < sg_primary_area;
    int origin_x = partial ? t->origin_x : 0, origin_y = partial ? t->origin_y : 0;
    glViewport(saved->viewport[0] + origin_x - w->x, saved->viewport[1] + origin_y - w->y, saved->viewport[2],
               saved->viewport[3]);
    if (saved->scissor_on) {
        glGetIntegerv(GL_SCISSOR_BOX, saved->scissor);
        glScissor(saved->scissor[0] + origin_x - w->x, saved->scissor[1] + origin_y - w->y, saved->scissor[2],
                  saved->scissor[3]);
    }
    // What's behind it on the display is drawn first, and here what's behind is the last frame, which a shadow would
    // build up on. So a window drawn whole starts clear, and one drawn in part has no shadow.
    if (t->whole && !w->cleared) {
        w->cleared = 1;
        GLfloat color[4];
        GLboolean mask[4];
        glGetFloatv(GL_COLOR_CLEAR_VALUE, color);
        glGetBooleanv(GL_COLOR_WRITEMASK, mask);
        glClearColor(0, 0, 0, 0);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        if (saved->scissor_on)
            glDisable(GL_SCISSOR_TEST);
        glClear(GL_COLOR_BUFFER_BIT);
        if (saved->scissor_on)
            glEnable(GL_SCISSOR_TEST);
        glColorMask(mask[0], mask[1], mask[2], mask[3]);
        glClearColor(color[0], color[1], color[2], color[3]);
    }
    return w;
}
static void SGRestore(struct SGWindow *w, const struct SGSaved *saved) {
    glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, (GLuint)saved->draw);
    glViewport(saved->viewport[0], saved->viewport[1], saved->viewport[2], saved->viewport[3]);
    if (saved->scissor_on)
        glScissor(saved->scissor[0], saved->scissor[1], saved->scissor[2], saved->scissor[3]);
    ++w->draws;
    ++sg_replayed;
}

// Whether a draw is the display's, and nobody's looking at the display. Called by DGHostDraw for its own draw.
static int DGSeamlessDisplayOff(struct DGHostContext *c) {
    if (!sg_replay_enabled || !sg_display_off || c != sg_display || !c->drawable || c->drawable->width <= 64 ||
        c->drawable->height <= 64)
        return 0;
    GLint draw = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_EXT, &draw);
    return (GLuint)draw == c->framebuffer;
}

// Called by DGHostDraw once its arrays are set and its draw has run.
static void DGSeamlessDrawn(struct DGHostContext *c, struct DGMessage *m, const struct DGVertexArray *arrays,
                            unsigned n, uint64_t vertices, GLenum type, const void *indices) {
    if (!sg_replay_enabled || c != sg_display || m->op != DG_DRAW || !c->drawable)
        return;
    uint64_t began = mach_absolute_time();
    (void)arrays;
    (void)n;
    (void)vertices;
    struct SGSaved saved;
    struct SGWindow *w = SGRedirect(c, &saved);
    if (w) {
        if (type)
            glDrawElements((GLenum)m->args[0], (GLsizei)m->args[2], type, indices);
        else
            glDrawArrays((GLenum)m->args[0], (GLint)m->args[1], (GLsizei)m->args[2]);
        SGRestore(w, &saved);
    }
    sg_spent += mach_absolute_time() - began;
}

static void SGReplayImmediate(struct DGHostContext *c) {
    uint64_t began = mach_absolute_time();
    struct SGSaved saved;
    struct SGWindow *w = SGRedirect(c, &saved);
    if (w) {
        glBegin((GLenum)sg_immediate_mode);
        for (unsigned i = 0; i < sg_immediate_count; ++i) {
            const struct SGImmediate *v = &sg_immediate[i];
            if (v->op == DG_OP_vertex2f)
                glVertex2f(v->a, v->b);
            else if (v->op == DG_OP_tex_coord2f)
                glTexCoord2f(v->a, v->b);
            else
                glMultiTexCoord2f(v->target, v->a, v->b);
        }
        glEnd();
        SGRestore(w, &saved);
    }
    sg_spent += mach_absolute_time() - began;
}

static void SGSendReady(void) {
    uint64_t now = mach_absolute_time();
    if (!sg_port && now >= sg_next_lookup) {
        const char *service = getenv("LC_SEAMLESS_GPU_SERVICE");
        sg_next_lookup = now + 1000000000ull * sg_timebase.denom / sg_timebase.numer;
        if (service && bootstrap_look_up(bootstrap_port, service, &sg_port))
            sg_port = 0;
    }
    for (struct SGWindow *w = sg_windows; w; w = w->next) {
        if (w->pending &&
            glClientWaitSync(w->pending_sync, GL_SYNC_FLUSH_COMMANDS_BIT, 8000000) != GL_TIMEOUT_EXPIRED) {
            glDeleteSync(w->pending_sync);
            w->pending = 0;
            w->ready = 1;
        }
        if (!w->ready || !sg_port)
            continue;
        mach_port_t capability = IOSurfaceCreateMachPort(w->surface[w->front]);
        struct SGFrameMessage message;
        memset(&message, 0, sizeof(message));
        message.header.msgh_bits =
            MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
        message.header.msgh_size = sizeof(message);
        message.header.msgh_remote_port = sg_port;
        message.header.msgh_local_port = w->hold[w->front];
        message.header.msgh_id = SG_FRAME_MESSAGE;
        message.body.msgh_descriptor_count = 1;
        message.surface.name = capability;
        message.surface.disposition = MACH_MSG_TYPE_COPY_SEND;
        message.surface.type = MACH_MSG_PORT_DESCRIPTOR;
        message.window = w->id;
        message.frame = (uint32_t)w->frames;
        message.width = (uint32_t)w->width;
        message.height = (uint32_t)w->height;
        message.x = w->x;
        message.y = w->y;
        if (mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(message), 0, 0, 0, 0) == KERN_SUCCESS) {
            ++w->sent;
            ++w->held[w->front];
            w->ready = 0;
        } else {
            ++w->drops; // It goes again next time, unless a newer frame has replaced it.
        }
        mach_port_deallocate(mach_task_self(), capability);
    }
}

// Every window drawn into since the last publish now has a finished frame, once its fence passes.
static void SGEndFrame(void) {
    int any = 0;
    GLint draw = 0, read = 0;
    GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_EXT, &draw);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING_EXT, &read);
    if (scissor)
        glDisable(GL_SCISSOR_TEST);
    for (struct SGWindow *w = sg_windows; w; w = w->next) {
        if (!w->dirty && !w->unsent)
            continue;
        w->dirty = 0;
        w->cleared = 0;
        w->drawn = 1;
        int next;
        if (w->pending || w->ready) {
            // The one before wasn't sent, so nobody has that buffer: this frame replaces it there.
            if (w->pending)
                glDeleteSync(w->pending_sync);
            w->pending = w->ready = 0;
            ++w->drops;
            next = w->front;
        } else if ((next = SGFreeBuffer(w)) < 0) {
            w->unsent = 1;
            ++sg_in_use;
            continue;
        }
        w->unsent = 0;
        glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, w->framebuffer[SG_WORK]);
        glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, w->framebuffer[next]);
        glBlitFramebufferEXT(0, 0, w->width, w->height, 0, 0, w->width, w->height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        ++sg_blits;
        w->pending_sync = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        w->pending = 1;
        w->front = next;
        ++w->frames;
        any = 1;
    }
    glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, (GLuint)draw);
    glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, (GLuint)read);
    if (scissor)
        glEnable(GL_SCISSOR_TEST);
    if (any)
        glFlush();
}

static void SGWriteRates(void) {
    uint64_t now = mach_absolute_time();
    if (now < sg_next_rates)
        return;
    sg_next_rates = now + 1000000000ull * sg_timebase.denom / sg_timebase.numer;
    if (!sg_rates) {
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/rates.txt", dg_seamless_dir);
        sg_rates = fopen(path, "w");
    }
    if (!sg_rates)
        return;
    fprintf(sg_rates,
            "%llu sealed=%llu presents=%llu replayed=%llu unplaced=%llu spent_us=%llu blits=%llu marks=%llu inuse=%llu "
            "odd=%llu",
            now * sg_timebase.numer / sg_timebase.denom / 1000000, sg_sealed, sg_presents, sg_replayed, sg_unplaced,
            sg_spent * sg_timebase.numer / sg_timebase.denom / 1000, sg_blits, sg_marks, sg_in_use, sg_odd);
    for (struct SGWindow *w = sg_windows; w; w = w->next)
        if (w->frames)
            fprintf(sg_rates, " w%u:%dx%d@%d,%d:frames=%llu,sent=%llu,drops=%llu,draws=%llu", w->id, w->width,
                    w->height, w->x, w->y, w->frames, w->sent, w->drops, w->draws);
    fputc('\n', sg_rates);
    fflush(sg_rates);
}

// Before each command runs.
// A layer that samples what's behind it, such as Safari's address field, reads the drawable. With the display off
// nothing draws there, so what it held last, other windows included, would show up in this one. So the drawable gets
// this window's surface first. shortcut: only this window, so something over another window samples clear there;
// ordered effect planes are what would do it right.
static void SGFillDrawableForRead(struct DGHostContext *c) {
    if (!sg_layer.id || !DGSeamlessDisplayOff(c))
        return;
    struct SGWindow *w = SGWindowFor(c, &sg_layer);
    if (!w)
        return;
    int partial = (int64_t)c->drawable->width * c->drawable->height < sg_primary_area;
    int x = w->x - (partial ? sg_layer.origin_x : 0), y = w->y - (partial ? sg_layer.origin_y : 0);
    GLint read = 0;
    GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING_EXT, &read);
    if (scissor)
        glDisable(GL_SCISSOR_TEST);
    glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, w->framebuffer[SG_WORK]);
    glBlitFramebufferEXT(0, 0, w->width, w->height, x, y, x + w->width, y + w->height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, (GLuint)read);
    if (scissor)
        glEnable(GL_SCISSOR_TEST);
}

static void DGSeamlessBefore(struct DGInterpreter *s, struct DGMessage *m) {
    if (m->op == DG_SURFACE_HOLD_PRESENT)
        ++sg_presents;
    if (m->op == DG_OP_pass_through) {
        float value;
        memcpy(&value, &m->args[0], sizeof(value));
        SGToken(value);
        return;
    }
    struct DGHostContext *c = m->context && m->context < s->next ? &s->contexts[m->context] : NULL;
    if (!c || !c->cgl)
        return;
    if (m->op == DG_SURFACE_SEALED_REGIONS) {
        ++sg_sealed;
        sg_display = c;
        // What's published is the display, though a smaller scratch drawable can be current when it happens.
        if (c->drawable && (int64_t)c->drawable->width * c->drawable->height >= sg_primary_area)
            sg_primary_area = (int64_t)c->drawable->width * c->drawable->height;
        // The stream's own order keeps this context current or next to be, and it isn't inside a Begin here.
        if ((CGLGetCurrentContext() == c->cgl || !CGLSetCurrentContext(c->cgl)) && !c->inside_begin) {
            uint64_t began = mach_absolute_time();
            if (sg_replay_enabled) {
                SGEndFrame();
                SGSendReady();
                // A draw before the next update's first marker isn't the last window's. Some other path draws: left to
                // that window, its title bar turned up inside Safari's surface.
                sg_layer.id = 0;
            }
            SGWriteRates();
            sg_spent += mach_absolute_time() - began;
        }
        return;
    }
    if (!sg_replay_enabled || c != sg_display)
        return;
    if ((m->op == DG_OP_copy_tex_sub_image2D || m->op == DG_SNAPSHOT_DRAWABLE_TEXTURE ||
         m->op == DG_BIND_DRAWABLE_TEXTURE) &&
        CGLGetCurrentContext() == c->cgl && !c->inside_begin) {
        SGFillDrawableForRead(c);
        return;
    }
    if (m->op == DG_OP_begin) {
        sg_immediate_active = 1;
        sg_immediate_mode = (int)(uint32_t)m->args[0];
        sg_immediate_count = 0;
        // The real draw runs, as there's no skipping it from here, and leaves nothing.
        sg_immediate_masked = DGSeamlessDisplayOff(c);
        if (sg_immediate_masked) {
            glGetBooleanv(GL_COLOR_WRITEMASK, sg_immediate_mask);
            glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
        }
    } else if (sg_immediate_active && sg_immediate_count < sizeof(sg_immediate) / sizeof(*sg_immediate)) {
        struct SGImmediate *v = &sg_immediate[sg_immediate_count];
        if (m->op == DG_OP_vertex2f || m->op == DG_OP_tex_coord2f) {
            v->op = m->op;
            memcpy(&v->a, &m->args[0], 4);
            memcpy(&v->b, &m->args[1], 4);
            ++sg_immediate_count;
        } else if (m->op == DG_OP_multi_tex_coord2f) {
            v->op = m->op;
            memcpy(&v->target, &m->args[0], 4);
            memcpy(&v->a, &m->args[1], 4);
            memcpy(&v->b, &m->args[2], 4);
            ++sg_immediate_count;
        } else if (m->op != DG_OP_end)
            ++sg_odd;
    }
}
// After each command has run, for what needs its draw done first.
static void DGSeamlessAfter(struct DGInterpreter *s, struct DGMessage *m) {
    if (m->op != DG_OP_end || !sg_immediate_active)
        return;
    sg_immediate_active = 0;
    struct DGHostContext *c = m->context && m->context < s->next ? &s->contexts[m->context] : NULL;
    if (sg_immediate_masked) {
        glColorMask(sg_immediate_mask[0], sg_immediate_mask[1], sg_immediate_mask[2], sg_immediate_mask[3]);
        sg_immediate_masked = 0;
    }
    if (c && c == sg_display && !c->inside_begin && c->drawable && sg_immediate_count)
        SGReplayImmediate(c);
}
