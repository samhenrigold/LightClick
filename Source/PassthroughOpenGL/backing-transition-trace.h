/* Metadata only. One global bounded tail, copied to an explicitly named private
 * scratch file at endpoint cleanup. No renderer decisions consult this state. */
#ifndef VIM_BACKING_TRANSITION_TRACE_H
#define VIM_BACKING_TRANSITION_TRACE_H
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mach/mach_time.h>
#define VIM_TRANSITION_CAPACITY 8192u
enum { VIM_TRANSITION_ALLOC, VIM_TRANSITION_SELECT, VIM_TRANSITION_FRONT_SEED,
       VIM_TRANSITION_FAMILY_UPLOAD, VIM_TRANSITION_FAMILY_IMPORT,
       VIM_TRANSITION_FAMILY_PUBLISH, VIM_TRANSITION_BLIT, VIM_TRANSITION_KINDS };
struct VIMTransitionRow {
    uint64_t serial,at,write_serial,object,incarnation,before,after,args[10];
    uintptr_t session,context;
    unsigned kind,opcode,drawable,front,back,width,height,double_buffer,status,read_mode,draw_mode;
};
struct VIMTransitionState { uintptr_t session; };
static int vim_transition_enabled;
static FILE *vim_transition_output;
static pthread_mutex_t vim_transition_lock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t vim_transition_total,vim_transition_counts[VIM_TRANSITION_KINDS],vim_transition_started,vim_transition_closed;
static struct VIMTransitionRow vim_transition_rows[VIM_TRANSITION_CAPACITY];
/* Scalar identity only: an interpreter may later close on another thread. */
static __thread uintptr_t vim_transition_session;
static int VIMTransitionPathAllowed(const char *path){
    const char *prefix="/private/tmp/lightclick-";
    if(!path || strncmp(path,prefix,strlen(prefix)))return 0;
    const char *name=path+strlen(prefix);size_t n=strlen(name);
    if(!n || n>160)return 0;
    for(size_t i=0;i<n;i++)if(!((name[i]>='a'&&name[i]<='z')||(name[i]>='A'&&name[i]<='Z')||(name[i]>='0'&&name[i]<='9')||name[i]=='-'||name[i]=='_'||name[i]=='.'))return 0;
    return 1;
}
__attribute__((constructor)) static void VIMTransitionLoaded(void){
    const char *v=getenv("VIM_BACKING_TRANSITION_TRACE");if(!v || strcmp(v,"1"))return;
    const char *path=getenv("VIM_BACKING_TRANSITION_TRACE_PATH");
    if(!VIMTransitionPathAllowed(path)){fprintf(stderr,"VIM_BACKING_TRANSITION_TRACE refused=output_path_required coverage=unknown\n");return;}
    int fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);struct stat info;
    if(fd<0 || fstat(fd,&info) || !S_ISREG(info.st_mode) || info.st_uid!=geteuid() || info.st_nlink!=1){if(fd>=0)close(fd);fprintf(stderr,"VIM_BACKING_TRANSITION_TRACE refused=private_output_creation coverage=unknown\n");return;}
    vim_transition_output=fdopen(fd,"w");if(!vim_transition_output){close(fd);fprintf(stderr,"VIM_BACKING_TRANSITION_TRACE refused=output_stream coverage=unknown\n");return;}
    __atomic_store_n(&vim_transition_enabled,1,__ATOMIC_RELEASE);
    fprintf(stderr,"VIM_BACKING_TRANSITION_TRACE enabled=1 capacity=%u output=explicit_private_scratch cleanup=DGInterpreterDestroy metadata_only=1 timing_perturbed=1\n",VIM_TRANSITION_CAPACITY);
}
static inline int VIMTransitionEnabled(void){return __atomic_load_n(&vim_transition_enabled,__ATOMIC_ACQUIRE);}
static struct VIMTransitionState *VIMTransitionStart(uintptr_t session){
    struct VIMTransitionState *s=calloc(1,sizeof(*s));
    if(s){
        s->session=session;pthread_mutex_lock(&vim_transition_lock);
        if(!VIMTransitionEnabled()){pthread_mutex_unlock(&vim_transition_lock);free(s);return NULL;}
        vim_transition_started++;pthread_mutex_unlock(&vim_transition_lock);
    }
    else fprintf(stderr,"VIM_BACKING_TRANSITION_TRACE allocation_failed=1 coverage=unknown\n");
    return s;
}
static void VIMTransitionAppend(struct VIMTransitionRow row){
    if(!VIMTransitionEnabled() || !vim_transition_session)return;
    row.session=vim_transition_session;row.at=mach_absolute_time();
    pthread_mutex_lock(&vim_transition_lock);
    if(VIMTransitionEnabled() && vim_transition_total!=UINT64_MAX){row.serial=++vim_transition_total;if(row.kind<VIM_TRANSITION_KINDS)vim_transition_counts[row.kind]++;vim_transition_rows[(row.serial-1)%VIM_TRANSITION_CAPACITY]=row;}
    pthread_mutex_unlock(&vim_transition_lock);
}
/* Caller holds the global ring lock. No renderer/context state is accessed. */
static void VIMTransitionSnapshotLocked(const char *reason,uintptr_t cleanup_session){
    uint64_t retained=vim_transition_total<VIM_TRANSITION_CAPACITY?vim_transition_total:VIM_TRANSITION_CAPACITY;
    FILE *f=vim_transition_output;int failed=0;
    if(f){
        clearerr(f);if(fflush(f) || ftruncate(fileno(f),0) || fseek(f,0,SEEK_SET))failed=1;
        if(!failed){
            mach_timebase_info_data_t t={0};mach_timebase_info(&t);
            fprintf(f,"VIM_BACKING_TRANSITION_TRACE snapshot_begin=1 reason=%s quiescence_unverified=1 total=%" PRIu64 " retained=%" PRIu64 " overwritten=%" PRIu64 " started_sessions=%" PRIu64 " closed_sessions=%" PRIu64 " capacity=%u numer=%u denom=%u cleanup_session=%" PRIxPTR " allocation=%" PRIu64 " select=%" PRIu64 " front_seed=%" PRIu64 " family_upload=%" PRIu64 " family_import=%" PRIu64 " family_publish=%" PRIu64 " blit=%" PRIu64 " coverage=%s blit_default_binding_unverified=1 swap_api_unverified=1 cpu_reseed_reason_unavailable=1 allocation_drawable_name_may_be_unassigned=1 shared_vram_import_unobserved=1 family_copy_regions_unobserved=1\n",reason,vim_transition_total,retained,vim_transition_total-retained,vim_transition_started,vim_transition_closed,VIM_TRANSITION_CAPACITY,t.numer,t.denom,cleanup_session,vim_transition_counts[0],vim_transition_counts[1],vim_transition_counts[2],vim_transition_counts[3],vim_transition_counts[4],vim_transition_counts[5],vim_transition_counts[6],vim_transition_total>retained?"overwritten_not_complete":"recorded_hooks_only");
            for(uint64_t i=0;i<retained;i++){
                uint64_t serial=vim_transition_total-retained+1+i;const struct VIMTransitionRow *r=&vim_transition_rows[(serial-1)%VIM_TRANSITION_CAPACITY];
                fprintf(f,"event=%" PRIu64 " at=%" PRIu64 " kind=%u opcode=%u session=%" PRIxPTR " context=%" PRIxPTR " drawable=%u front=%u back=%u width=%u height=%u double=%u status=%u write_serial=%" PRIu64 " object=%" PRIu64 " incarnation=%" PRIu64 " before_epoch=%" PRIu64 " after_epoch=%" PRIu64 " read_mode=%u draw_mode=%u args=",r->serial,r->at,r->kind,r->opcode,r->session,r->context,r->drawable,r->front,r->back,r->width,r->height,r->double_buffer,r->status,r->write_serial,r->object,r->incarnation,r->before,r->after,r->read_mode,r->draw_mode);
                for(unsigned j=0;j<10;j++)fprintf(f,"%s%" PRIu64,j?",":"",r->args[j]);fputc('\n',f);
            }
            fprintf(f,"VIM_BACKING_TRANSITION_TRACE snapshot_end=1 total=%" PRIu64 "\n",vim_transition_total);
            if(fflush(f) || ferror(f))failed=1;
        }
    }
    if(failed)fprintf(stderr,"VIM_BACKING_TRANSITION_TRACE output_failed=1 coverage=unknown\n");
}
static void VIMTransitionFinish(struct VIMTransitionState *s){
    if(!s)return;
    pthread_mutex_lock(&vim_transition_lock);
    if(VIMTransitionEnabled()){
        vim_transition_closed++;
        VIMTransitionSnapshotLocked("endpoint_cleanup",s->session);
    }
    pthread_mutex_unlock(&vim_transition_lock);
    if(vim_transition_session==s->session)vim_transition_session=0;free(s);
}
/* The submit-trace destructor already survives normal QEMU cleanup. Freeze the
 * diagnostic ring, then snapshot even when live guest endpoints did not close.
 * This does not stop renderer threads or claim they are quiescent. */
__attribute__((destructor)) static void VIMTransitionShutdown(void){
    if(!__atomic_exchange_n(&vim_transition_enabled,0,__ATOMIC_ACQ_REL))return;
    pthread_mutex_lock(&vim_transition_lock);
    VIMTransitionSnapshotLocked("process_shutdown",0);
    pthread_mutex_unlock(&vim_transition_lock);
}
#endif
