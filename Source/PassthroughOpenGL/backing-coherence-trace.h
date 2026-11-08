/* Default-off bounded metadata census, never an input to coherence decisions.
 * Connection-owned context/alias fields are observed on the serialized interpreter.
 * Logging perturbs timing. A foreign candidate is not proof of a mirror dependency. */
#ifndef VIM_BACKING_COHERENCE_TRACE_H
#define VIM_BACKING_COHERENCE_TRACE_H
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#define VIM_COHERENCE_ROWS 128u
#define VIM_COHERENCE_ANOMALY_ROWS 128u
enum { VIM_COHERENCE_UNCHANGED, VIM_COHERENCE_UNSELECTED, VIM_COHERENCE_REFRESH_COPY,
       VIM_COHERENCE_BIND_COPY, VIM_COHERENCE_ALIAS_WRITE };
struct VIMCoherenceRow {
    unsigned kind, okay, storage, source, current_front, current_back, imported, matching_sources;
    uintptr_t owner, writer, group, alias, retained_source, matched_mirror;
    uint64_t drawable_serial, copied_before, copied_after, write_serial, submitted_serial, group_clock;
};
static pthread_once_t vim_coherence_once=PTHREAD_ONCE_INIT;
static int vim_coherence_enabled;
static uint64_t vim_coherence_events, vim_coherence_anomalies, vim_coherence_kinds[5], vim_coherence_foreign_writes, vim_coherence_matched_writes;
static void VIMCoherenceInit(void){
    const char *value=getenv("VIM_BACKING_COHERENCE_TRACE");
    __atomic_store_n(&vim_coherence_enabled,value && !strcmp(value,"1"),__ATOMIC_RELEASE);
    if(__atomic_load_n(&vim_coherence_enabled,__ATOMIC_ACQUIRE)){
        mach_timebase_info_data_t t={0};mach_timebase_info(&t);
        fprintf(stderr,"VIM_BACKING_COHERENCE_TRACE enabled=1 routine_cap=%u anomaly_cap=%u clock=mach_absolute_time numer=%u denom=%u metadata_only=1 timing_perturbed=1 foreign_candidate_not_proof=1 write_coverage=imported_aliases_only generic_alias_writes=unknown\n",VIM_COHERENCE_ROWS,VIM_COHERENCE_ANOMALY_ROWS,t.numer,t.denom);
    }
}
static inline int VIMCoherenceEnabled(void){pthread_once(&vim_coherence_once,VIMCoherenceInit);return __atomic_load_n(&vim_coherence_enabled,__ATOMIC_ACQUIRE);}
__attribute__((constructor)) static void VIMCoherenceLoaded(void){(void)VIMCoherenceEnabled();}
static inline int VIMCoherenceForeignCandidate(const struct VIMCoherenceRow *r){
    return r->kind==VIM_COHERENCE_ALIAS_WRITE && r->storage && r->storage!=r->current_front && r->storage!=r->current_back;
}
static inline int VIMCoherenceAnomaly(const struct VIMCoherenceRow *r){
    return !r->okay || (VIMCoherenceForeignCandidate(r) && r->matching_sources);
}
static void VIMCoherenceEmit(const struct VIMCoherenceRow *r){
    uint64_t n=__atomic_add_fetch(&vim_coherence_events,1,__ATOMIC_RELAXED),a=0;
    if(r->kind<5)__atomic_fetch_add(&vim_coherence_kinds[r->kind],1,__ATOMIC_RELAXED);
    if(VIMCoherenceForeignCandidate(r))__atomic_fetch_add(&vim_coherence_foreign_writes,1,__ATOMIC_RELAXED);
    if(r->kind==VIM_COHERENCE_ALIAS_WRITE && r->matching_sources)__atomic_fetch_add(&vim_coherence_matched_writes,1,__ATOMIC_RELAXED);
    int anomaly=VIMCoherenceAnomaly(r);if(anomaly)a=__atomic_add_fetch(&vim_coherence_anomalies,1,__ATOMIC_RELAXED);
    if(n<=VIM_COHERENCE_ROWS || (anomaly && a<=VIM_COHERENCE_ANOMALY_ROWS))
        fprintf(stderr,"VIM_BACKING_COHERENCE_TRACE event=%" PRIu64 " at=%" PRIu64 " kind=%u okay=%u anomaly=%d foreign_candidate=%d owner_context=%" PRIxPTR " writer_context=%" PRIxPTR " group=%" PRIxPTR " alias=%" PRIxPTR " storage=%u source_storage=%u retained_source=%" PRIxPTR " current_front=%u current_back=%u imported=%u drawable_write=%" PRIu64 " copied_before=%" PRIu64 " copied_after=%" PRIu64 " iosurface_write=%" PRIu64 " iosurface_submitted=%" PRIu64 " group_clock=%" PRIu64 " matching_mirror_sources=%u matched_mirror=%" PRIxPTR "\n",n,mach_absolute_time(),r->kind,r->okay,anomaly,VIMCoherenceForeignCandidate(r),r->owner,r->writer,r->group,r->alias,r->storage,r->source,r->retained_source,r->current_front,r->current_back,r->imported,r->drawable_serial,r->copied_before,r->copied_after,r->write_serial,r->submitted_serial,r->group_clock,r->matching_sources,r->matched_mirror);
    if(n==VIM_COHERENCE_ROWS+1)fprintf(stderr,"VIM_BACKING_COHERENCE_TRACE routine_rows_truncated=1 anomaly_budget_reserved=1 counters_continue=1\n");
    if(anomaly && a==VIM_COHERENCE_ANOMALY_ROWS+1)fprintf(stderr,"VIM_BACKING_COHERENCE_TRACE anomaly_rows_truncated=1 counters_continue=1\n");
}
__attribute__((destructor)) static void VIMCoherenceSummary(void){
    if(__atomic_load_n(&vim_coherence_enabled,__ATOMIC_ACQUIRE))
        fprintf(stderr,"VIM_BACKING_COHERENCE_TRACE summary=1 snapshot_not_atomic=1 write_coverage=imported_aliases_only generic_alias_writes=unknown events=%" PRIu64 " anomalies=%" PRIu64 " unchanged=%" PRIu64 " unselected=%" PRIu64 " refresh_copy=%" PRIu64 " bind_copy=%" PRIu64 " alias_write=%" PRIu64 " foreign_candidate_writes=%" PRIu64 " matched_source_writes=%" PRIu64 "\n",__atomic_load_n(&vim_coherence_events,__ATOMIC_RELAXED),__atomic_load_n(&vim_coherence_anomalies,__ATOMIC_RELAXED),__atomic_load_n(&vim_coherence_kinds[0],__ATOMIC_RELAXED),__atomic_load_n(&vim_coherence_kinds[1],__ATOMIC_RELAXED),__atomic_load_n(&vim_coherence_kinds[2],__ATOMIC_RELAXED),__atomic_load_n(&vim_coherence_kinds[3],__ATOMIC_RELAXED),__atomic_load_n(&vim_coherence_kinds[4],__ATOMIC_RELAXED),__atomic_load_n(&vim_coherence_foreign_writes,__ATOMIC_RELAXED),__atomic_load_n(&vim_coherence_matched_writes,__ATOMIC_RELAXED));
}
#endif
