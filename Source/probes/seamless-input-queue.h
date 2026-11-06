// A non-blocking send queue for host input. The host's event handlers mustn't block on a socket, and dropping bytes
// would split a message or lose a gesture's end. So everything queues, and while the guest is behind, motion merges
// into the newest unsent message: a pointer position replaces the last one, and scroll, magnify and rotate deltas add
// up, so nothing is lost and nothing stale queues. A phase change never merges. Same idea as origin/display-latency's
// InputMotionCoalescer, with deltas added, since gestures are relative.
#ifndef SEAMLESS_INPUT_QUEUE_H
#define SEAMLESS_INPUT_QUEUE_H
#include "seamless-wire.h"
#include <errno.h>
#include <sys/socket.h>

#define SWQ_CAPACITY (1u << 16)
struct SWQueue {
    uint8_t bytes[SWQ_CAPACITY];
    size_t start, end, tail; // tail: where the newest message begins, valid only if start <= tail < end.
};

// Whether `next` can be folded into `previous`, which it then replaces.
static inline int swq_merge(struct SWMMessage *previous, const struct SWMMessage *next) {
    if (previous->type != next->type)
        return 0;
    if (next->type == SWM_POINTER) {
        const struct SWMPointer *b = &next->u.pointer;
        struct SWMPointer *a = &previous->u.pointer;
        if ((b->kind != SWM_MOVE && b->kind != SWM_DRAG) || a->kind != b->kind || a->window != b->window ||
            a->button != b->button || a->flags != b->flags)
            return 0;
        *a = *b;
        return 1;
    }
    if (next->type != SWM_GESTURE)
        return 0;
    const struct SWMGesture *b = &next->u.gesture;
    struct SWMGesture *a = &previous->u.gesture;
    if (a->kind != b->kind || a->window != b->window || a->flags != b->flags || a->modifiers != b->modifiers ||
        a->stage != b->stage || a->phase != b->phase || a->momentum != b->momentum)
        return 0;
    // A scroll is changing when either phase says so; momentum ends and every other transition stay separate.
    int changing = b->phase == SWP_CHANGED || (b->phase == SWP_NONE && b->momentum == SWM_MOMENTUM_CHANGED);
    if (!changing)
        return 0;
    if (b->kind == SWG_PRESSURE) {
        *a = *b; // Absolute.
        return 1;
    }
    if (b->kind != SWG_SCROLL && b->kind != SWG_MAGNIFY && b->kind != SWG_ROTATE)
        return 0;
    a->x = b->x;
    a->y = b->y;
    a->a += b->a;
    a->b += b->b;
    a->c += b->c;
    return 1;
}

static inline size_t swq_encode(uint8_t *out, size_t capacity, const struct SWMMessage *m) {
    return m->type == SWM_POINTER ? swm_put_pointer(out, capacity, &m->u.pointer)
                                  : swm_put_gesture(out, capacity, &m->u.gesture);
}

// Takes one encoded message. Returns 0 if the queue is full, which only a guest that's stopped reading can cause.
static inline int swq_push(struct SWQueue *q, const uint8_t *message, size_t size) {
    struct SWMMessage next, previous;
    size_t used;
    if (q->end > q->tail && q->tail >= q->start && swm_parse(message, size, &next, &used) == SWM_OK &&
        swm_parse(q->bytes + q->tail, q->end - q->tail, &previous, &used) == SWM_OK && swq_merge(&previous, &next)) {
        swq_encode(q->bytes + q->tail, q->end - q->tail, &previous);
        return 1;
    }
    if (q->start) {
        memmove(q->bytes, q->bytes + q->start, q->end - q->start);
        q->end -= q->start;
        q->tail = q->tail >= q->start ? q->tail - q->start : (size_t)-1;
        q->start = 0;
    }
    if (size > SWQ_CAPACITY - q->end)
        return 0;
    memcpy(q->bytes + q->end, message, size);
    q->tail = q->end;
    q->end += size;
    return 1;
}

// Sends what the socket takes now. `fd` must be O_NONBLOCK: MSG_DONTWAIT alone blocked on a full Unix socket here
// [measured]. Returns 1 when empty, 0 when the socket is full, -1 when it's gone. A message partly
// sent can't merge: `start` has passed `tail` by then, and swq_push checks that.
static inline int swq_flush(struct SWQueue *q, int fd) {
    while (q->start < q->end) {
        ssize_t n = send(fd, q->bytes + q->start, q->end - q->start, 0);
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            return 0;
        if (n <= 0)
            return -1;
        q->start += (size_t)n;
    }
    q->start = q->end = 0;
    q->tail = (size_t)-1;
    return 1;
}
#endif
