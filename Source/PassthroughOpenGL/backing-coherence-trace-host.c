/* Diagnostic metadata only; the endpoint already serializes alias/context lifetime.
 * owner_context is the current producer on mirror rows, unknown(0) on write rows.
 * Join write storage to a retained mirror source using group+source_storage; never
 * infer ownership merely because a write targets something other than this drawable. */
#include "backing-coherence-trace.h"
static void DGCoherenceTrace(struct DGHostContext *c,struct DGAlias *p,unsigned kind,int okay,uint64_t copied_before){
    if(!VIMCoherenceEnabled())return;
    struct VIMCoherenceRow row={0};
    row.kind=kind;row.okay=okay;row.storage=p->storage;row.source=p->source_storage;
    row.current_front=c->color_storage?IOSurfaceGetID(c->color_storage):0;
    row.current_back=c->back_storage?IOSurfaceGetID(c->back_storage):0;
    row.imported=p->iosurface_import;
    row.owner=kind==VIM_COHERENCE_ALIAS_WRITE?0:(uintptr_t)c;
    row.writer=(uintptr_t)(kind==VIM_COHERENCE_ALIAS_WRITE?c:p->iosurface_writer);
    row.group=(uintptr_t)c->alias_group;row.alias=(uintptr_t)p;
    row.retained_source=(uintptr_t)p->producer_storage;
    row.drawable_serial=c->drawable?c->drawable->write_serial:0;
    row.copied_before=copied_before;row.copied_after=p->copied_serial;
    row.write_serial=p->iosurface_write_serial;row.submitted_serial=p->iosurface_submitted_serial;
    row.group_clock=c->alias_group?c->alias_group->iosurface_write_clock:0;
    if(kind==VIM_COHERENCE_ALIAS_WRITE && c->alias_group)
        for(struct DGAlias *mirror=c->alias_group->aliases;mirror;mirror=mirror->next)
            if(mirror->source_storage==p->storage && mirror->producer_storage){
                ++row.matching_sources;
                if(!row.matched_mirror)row.matched_mirror=(uintptr_t)mirror;
            }
    VIMCoherenceEmit(&row);
}
