#include "backing-transition-trace.h"
/* Called only on the serialized interpreter thread. No native GL query. */
static struct VIMTransitionRow DGTransitionRow(struct DGHostContext *c,unsigned kind,unsigned status){
    struct VIMTransitionRow r={0};r.kind=kind;r.status=status;r.context=(uintptr_t)c;
    if(c){
        r.drawable=c->drawable?c->drawable->name:0;
        r.write_serial=c->drawable?c->drawable->write_serial:0;
        r.front=c->color_storage?IOSurfaceGetID(c->color_storage):0;
        r.back=c->back_storage?IOSurfaceGetID(c->back_storage):0;
        r.width=c->drawable?c->drawable->width:0;r.height=c->drawable?c->drawable->height:0;
        r.double_buffer=c->double_buffer;r.read_mode=c->read_mode;r.draw_mode=c->draw_mode;
    }
    return r;
}
static void DGTransitionLocal(struct DGHostContext *c,unsigned kind,unsigned status,int width,int height,uint64_t a,uint64_t b){
    if(!VIMTransitionEnabled() || !vim_transition_session)return;
    struct VIMTransitionRow r=DGTransitionRow(c,kind,status);
    if(width>0)r.width=(unsigned)width;if(height>0)r.height=(unsigned)height;
    r.args[0]=a;r.args[1]=b;VIMTransitionAppend(r);
}
/* BLIT is an observed issued opcode, not proof of the caller's swap API or
 * current default-FBO bindings. Logical buffer modes alone cannot prove those. */
static void DGTransitionBlit(struct DGHostContext *c,const struct DGMessage *m){
    if(!VIMTransitionEnabled() || !vim_transition_session)return;
    struct VIMTransitionRow r=DGTransitionRow(c,VIM_TRANSITION_BLIT,UINT32_MAX);
    r.opcode=m->op;memcpy(r.args,m->args,sizeof(r.args));VIMTransitionAppend(r);
}
