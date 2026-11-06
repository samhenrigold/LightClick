/* Research: what WindowServer's GL looks like from the host, for seamless windows. Off unless LC_SEAMLESS_GPU_DIR is
 * set. While <dir>/arm exists, each command of every context is written to <dir>/trace.txt, up to a budget, with the
 * state a draw used. Reading GL state here costs time, so numbers from a traced run say nothing about speed. */
#include <OpenGL/CGLIOSurface.h>
#include "seamless-gpu-replay-host.c"

static FILE *dg_seamless_trace;
static uint64_t dg_seamless_trace_budget = 400000;
static unsigned dg_seamless_arm_tick;
static int dg_seamless_armed;
static pthread_mutex_t dg_seamless_lock = PTHREAD_MUTEX_INITIALIZER;

static void DGSeamlessConfigure(void) {
    dg_seamless_dir = getenv("LC_SEAMLESS_GPU_DIR");
    sg_replay_enabled = getenv("LC_SEAMLESS_GPU_REPLAY") != NULL;
    mach_timebase_info(&sg_timebase);
}

static void DGSeamlessTraceDraw(struct DGHostContext *c, struct DGMessage *m) {
    GLint draw = 0, read = 0, viewport[4] = {0}, scissor[4] = {0}, program = 0, active = 0, src = 0, dst = 0, srca = 0,
          dsta = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_EXT, &draw);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING_EXT, &read);
    glGetIntegerv(GL_VIEWPORT, viewport);
    glGetIntegerv(GL_SCISSOR_BOX, scissor);
    glGetIntegerv(GL_CURRENT_PROGRAM, &program);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    glGetIntegerv(GL_BLEND_SRC_RGB, &src);
    glGetIntegerv(GL_BLEND_DST_RGB, &dst);
    glGetIntegerv(GL_BLEND_SRC_ALPHA, &srca);
    glGetIntegerv(GL_BLEND_DST_ALPHA, &dsta);
    fprintf(dg_seamless_trace,
            " fbo=%d/%d colorfbo=%u drawable=%u:%dx%d vp=%d,%d,%d,%d sc=%d:%d,%d,%d,%d prog=%d blend=%d:%x,%x,%x,%x", draw,
            read, c->framebuffer, c->drawable ? c->drawable->name : 0, c->drawable ? c->drawable->width : 0,
            c->drawable ? c->drawable->height : 0, viewport[0], viewport[1], viewport[2], viewport[3],
            glIsEnabled(GL_SCISSOR_TEST), scissor[0], scissor[1], scissor[2], scissor[3], program, glIsEnabled(GL_BLEND),
            src, dst, srca, dsta);
    for (GLint unit = 0; unit < 4 && unit < c->texture_units; ++unit) {
        GLint rect = 0, flat = 0;
        glActiveTexture(GL_TEXTURE0 + unit);
        glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE_ARB, &rect);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &flat);
        if (rect || flat) {
            GLint w = 0, h = 0;
            glGetTexLevelParameteriv(rect ? GL_TEXTURE_RECTANGLE_ARB : GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &w);
            glGetTexLevelParameteriv(rect ? GL_TEXTURE_RECTANGLE_ARB : GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &h);
            fprintf(dg_seamless_trace, " tu%d=%s%d:%dx%d", unit, rect ? "r" : "2d", rect ? rect : flat, w, h);
        }
    }
    glActiveTexture((GLenum)active);
    if (m->op != DG_DRAW && m->op != DG_DRAW_INSTANCED_ARRAYS)
        return;
    fprintf(dg_seamless_trace, " mode=%llx first=%llu count=%llu idx=%llx", (unsigned long long)m->args[0],
            (unsigned long long)m->args[1], (unsigned long long)m->args[2], (unsigned long long)m->args[3]);
    uint64_t n = m->args[8];
    struct DGVertexArray *arrays = n && n <= DG_VERTEX_SLOTS ? DGHostPointer(m, 6, n * sizeof(*arrays)) : NULL;
    for (uint64_t i = 0; arrays && i < n; ++i) {
        const struct DGVertexArray *a = &arrays[i];
        fprintf(dg_seamless_trace, " [slot=%u sz=%d t=%x st=%d buf=%u", a->slot, a->size, a->type, a->stride, a->buffer);
        if (!a->buffer && a->type == GL_FLOAT && a->pointer && a->pointer - 1 + a->bytes <= m->bytes) {
            const char *base = (const char *)(m + 1) + a->pointer - 1;
            size_t stride = a->stride ? (size_t)a->stride : (size_t)a->size * 4;
            for (uint64_t v = 0; v < 4 && v < m->args[2] && (v + 1) * stride <= a->bytes; ++v) {
                float f[4] = {0};
                memcpy(f, base + v * stride, (size_t)(a->size > 4 ? 4 : a->size) * 4);
                fprintf(dg_seamless_trace, " (%g,%g)", f[0], f[1]);
            }
        }
        fputc(']', dg_seamless_trace);
    }
}

static void DGSeamlessObserve(struct DGInterpreter *s, struct DGMessage *m) {
    DGSeamlessBefore(s, m);
    if (!(dg_seamless_arm_tick++ & 0xff)) {
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/arm", dg_seamless_dir);
        dg_seamless_armed = !access(path, F_OK);
    }
    if (!dg_seamless_armed || !dg_seamless_trace_budget)
        return;
    pthread_mutex_lock(&dg_seamless_lock);
    if (!dg_seamless_trace) {
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/trace.txt", dg_seamless_dir);
        dg_seamless_trace = fopen(path, "w");
    }
    if (dg_seamless_trace && dg_seamless_trace_budget) {
        dg_seamless_trace_budget--;
        fprintf(dg_seamless_trace, "%llu %p c%u op=%x b=%u f=%x a=%llx,%llx,%llx,%llx,%llx,%llx",
                (unsigned long long)mach_absolute_time(), (void *)s, m->context, m->op, m->bytes, m->flags,
                (unsigned long long)m->args[0], (unsigned long long)m->args[1], (unsigned long long)m->args[2],
                (unsigned long long)m->args[3], (unsigned long long)m->args[4], (unsigned long long)m->args[5]);
        struct DGHostContext *c = m->context && m->context < s->next ? &s->contexts[m->context] : NULL;
        int is_draw = m->op == DG_DRAW || m->op == DG_DRAW_INSTANCED_ARRAYS || m->op == DG_OP_begin ||
                      m->op == DG_OP_copy_tex_sub_image2D || m->op == DG_OP_clear;
        if (is_draw && c && c->cgl && !c->inside_begin &&
            (CGLGetCurrentContext() == c->cgl || !CGLSetCurrentContext(c->cgl)))
            DGSeamlessTraceDraw(c, m);
        fputc('\n', dg_seamless_trace);
        if (!dg_seamless_trace_budget)
            fclose(dg_seamless_trace), dg_seamless_trace = NULL;
        else if (!(dg_seamless_trace_budget & 0x3ff))
            fflush(dg_seamless_trace);
    }
    pthread_mutex_unlock(&dg_seamless_lock);
}
