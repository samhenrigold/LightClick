// Guest-only Darwin13 x86_64 page-REP fault/restart witnesses. NEVER run on host.
// The signal handler changes only RIP. Normal-stack recovery restores the owned
// guard and poisons a verified prefix, then restarts the SAME REP with the exact
// GPRs and flags that the guest kernel returned from the fault.
#include <inttypes.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/ucontext.h>
#include <unistd.h>
#if !defined(__x86_64__) || !defined(__APPLE__)
#error Guest x86_64 Darwin only.
#endif
_Static_assert(ATOMIC_POINTER_LOCK_FREE==2 && ATOMIC_LLONG_LOCK_FREE==2,"handler atomics must be lock-free");
enum { BYTES=64, PREFIX=16, PAGE=4096, SENTINEL=0xa5, F_ARITH=0x8d5 };
typedef struct {
    uint64_t source,destination,count,value,final_source,final_destination,final_count,final_value,final_flags,seed;
} Machine;
_Static_assert(sizeof(Machine)==80 && offsetof(Machine,seed)==72 && offsetof(Machine,final_flags)==64,"assembly state ABI");
void matrix_repair(Machine *state);
#define STRING_(x) #x
#define STRING(x) STRING_(x)
#define REP_FUNCTION(name,instruction) \
    extern void name(Machine *);extern const char name##_rep[],name##_recover[]; \
    __asm__(".text\n.p2align 4\n.globl _" STRING(name) "\n_" STRING(name) ":\n" \
        "pushq %rbp\nmovq %rsp,%rbp\npushq %rbx\nsubq $8,%rsp\nmovq %rdi,%rbx\n" \
        "movq 0(%rbx),%rsi\nmovq 8(%rbx),%rdi\nmovq 16(%rbx),%rcx\nmovq 24(%rbx),%rax\n" \
        "pushq 72(%rbx)\npopfq\ncld\n.globl _" STRING(name) "_rep\n_" STRING(name) "_rep:\n" \
        instruction "\njmp 9f\n.globl _" STRING(name) "_recover\n_" STRING(name) "_recover:\n" \
        "pushfq\ncld\npushq %rax\npushq %rcx\npushq %rsi\npushq %rdi\nsubq $8,%rsp\n" \
        "movq %rbx,%rdi\ncallq _matrix_repair\nleaq 8(%rsp),%rsp\n" \
        "popq %rdi\npopq %rsi\npopq %rcx\npopq %rax\npopfq\njmp _" STRING(name) "_rep\n" \
        "9:\npushfq\npopq %rdx\ncld\nmovq %rsi,32(%rbx)\nmovq %rdi,40(%rbx)\nmovq %rcx,48(%rbx)\n" \
        "movq %rax,56(%rbx)\nmovq %rdx,64(%rbx)\nleaq 8(%rsp),%rsp\npopq %rbx\npopq %rbp\nretq\n");
REP_FUNCTION(matrix_movsb,"rep movsb")
REP_FUNCTION(matrix_movsq,"rep movsq")
REP_FUNCTION(matrix_stosb,"rep stosb")
REP_FUNCTION(matrix_stosq,"rep stosq")

typedef __typeof__(*(((ucontext_t *)0)->uc_mcontext)) MC;
const uint32_t lc_rep_matrix_layout[]={offsetof(ucontext_t,uc_mcontext),offsetof(ucontext_t,uc_mcsize),
    offsetof(MC,__ss.__rip),offsetof(MC,__ss.__rcx),offsetof(MC,__ss.__rsi),offsetof(MC,__ss.__rdi),offsetof(MC,__ss.__rax),offsetof(MC,__ss.__rflags)};
typedef struct { const char *name;unsigned width;int movs,source_guard;void (*run)(Machine *);const char *rep,*recover; } Case;
#define ITEM(name,width,movs,source,fn) {name,width,movs,source,fn,fn##_rep,fn##_recover}
static const Case cases[]={
    ITEM("movsb_source",1,1,1,matrix_movsb),ITEM("movsb_destination",1,1,0,matrix_movsb),
    ITEM("movsq_source",8,1,1,matrix_movsq),ITEM("movsq_destination",8,1,0,matrix_movsq),
    ITEM("stosb_destination",1,0,0,matrix_stosb),ITEM("stosq_destination",8,0,0,matrix_stosq)};
static _Atomic uintptr_t expected_rip,expected_recovery,expected_address;
static _Atomic uint64_t raw_rip,raw_rcx,raw_rsi,raw_rdi,raw_rax,raw_flags,raw_address;
static _Atomic int armed,seen,fault_signal,fault_code;
static uint8_t *source_map,*destination_map,*input,*output,*guard;
static const Case *active_case;
static Machine *active_machine;
static unsigned repaired;
static uint8_t before_restart[BYTES];

static void timeout_handler(int number) { (void)number;_exit(124); }
static void exception(int number,siginfo_t *info,void *opaque) {
    ucontext_t *context=opaque;
    if(!info || !context || !context->uc_mcontext || context->uc_mcsize<offsetof(MC,__ss.__rflags)+8 ||
       atomic_load_explicit(&armed,memory_order_relaxed)!=1 || atomic_load_explicit(&seen,memory_order_relaxed)!=0 ||
       !((number==SIGSEGV && info->si_code==SEGV_ACCERR) || (number==SIGBUS && info->si_code==BUS_ADRERR)) ||
       (uintptr_t)info->si_addr!=atomic_load_explicit(&expected_address,memory_order_relaxed) ||
       context->uc_mcontext->__ss.__rip!=atomic_load_explicit(&expected_rip,memory_order_relaxed)) _exit(90);
    atomic_store_explicit(&raw_address,(uintptr_t)info->si_addr,memory_order_relaxed);
    atomic_store_explicit(&raw_rip,context->uc_mcontext->__ss.__rip,memory_order_relaxed);
    atomic_store_explicit(&raw_rcx,context->uc_mcontext->__ss.__rcx,memory_order_relaxed);
    atomic_store_explicit(&raw_rsi,context->uc_mcontext->__ss.__rsi,memory_order_relaxed);
    atomic_store_explicit(&raw_rdi,context->uc_mcontext->__ss.__rdi,memory_order_relaxed);
    atomic_store_explicit(&raw_rax,context->uc_mcontext->__ss.__rax,memory_order_relaxed);
    atomic_store_explicit(&raw_flags,context->uc_mcontext->__ss.__rflags,memory_order_relaxed);
    atomic_store_explicit(&fault_signal,number,memory_order_relaxed);atomic_store_explicit(&fault_code,info->si_code,memory_order_relaxed);
    atomic_store_explicit(&seen,1,memory_order_relaxed);atomic_store_explicit(&armed,0,memory_order_relaxed);
    context->uc_mcontext->__ss.__rip=atomic_load_explicit(&expected_recovery,memory_order_relaxed);
}
static uint8_t byte_at(const Case *item,unsigned i) {
    return item->movs?(uint8_t)((17u*i+3u)&127u):(uint8_t)(UINT64_C(0x1122334455667788)>>(8*(i%item->width)));
}
static uint8_t poison(unsigned i) { return (uint8_t)(0xd0u+i); }
static int outside_intact(void) {
    for(unsigned i=0;i<PAGE*2;i++) {
        uint8_t *p=destination_map+i;
        if((p<output || p>=output+BYTES) && *p!=SENTINEL)return 0;
    }
    return 1;
}
static void failure(const char *stage) {
    int printed=printf("{\"schema\":1,\"result\":\"REP_FAULT_MATRIX_UNQUALIFIED\",\"stage\":\"%s\",\"fault_seen\":%d,\"fault_rcx\":%" PRIu64 ",\"fault_rsi\":\"%016" PRIx64 "\",\"fault_rdi\":\"%016" PRIx64 "\"}\n",
        stage,atomic_load(&seen),atomic_load(&raw_rcx),atomic_load(&raw_rsi),atomic_load(&raw_rdi));
    int flushed=fflush(stdout);_exit(printed<0 || flushed?74:70);
}
__attribute__((noinline,used)) void matrix_repair(Machine *state) {
    if(state!=active_machine || repaired || atomic_load(&seen)!=1 || atomic_load(&armed)!=0)failure("recovery_identity");
    // Before repairing a destination guard, read ONLY its accessible expected prefix.
    for(unsigned i=0;i<PREFIX;i++)if(output[i]!=byte_at(active_case,i))failure("committed_prefix_not_expected16");
    if(mprotect(guard,PAGE,PROT_READ|PROT_WRITE))failure("restore_owned_guard");
    for(unsigned i=0;i<BYTES;i++)before_restart[i]=output[i];
    for(unsigned i=PREFIX;i<BYTES;i++)if(before_restart[i]!=SENTINEL)failure("fault_suffix_changed");
    if(!outside_intact())failure("fault_outside_sentinel");
    // Bound a potentially wrong restart to our owned pages; do NOT correct its GPRs.
    uint64_t si=atomic_load(&raw_rsi),di=atomic_load(&raw_rdi),count=atomic_load(&raw_rcx);
    if(si<(uintptr_t)input || si>(uintptr_t)input+BYTES || di<(uintptr_t)output || di>(uintptr_t)output+BYTES || count>BYTES/active_case->width)failure("restart_state_outside_owned_bounds");
    for(unsigned i=0;i<PREFIX;i++)output[i]=poison(i);
    repaired=1;
}
static void hex(const uint8_t *bytes,char out[BYTES*2+1]) {
    const char *digits="0123456789abcdef";
    for(unsigned i=0;i<BYTES;i++){out[i*2]=digits[bytes[i]>>4];out[i*2+1]=digits[bytes[i]&15];}out[BYTES*2]=0;
}
typedef struct {
    uint64_t address,rip,rcx,rsi,rdi,rax,flags;int signal,code;
    uint64_t initial_source,initial_destination,seed;
    Machine restart,completion;
    char before[BYTES*2+1],after[BYTES*2+1],control[BYTES*2+1];
    int fault_ok,restart_ok,completion_ok,poison_kept,restart_sentinels,completion_sentinels;
} Observation;
static Observation observations[6];
static int final_state(const Machine *state,const Case *item) {
    return state->final_count==0 && state->final_source==state->source+(item->movs?BYTES:0) &&
        state->final_destination==state->destination+BYTES && state->final_value==state->value &&
        (state->final_flags&(F_ARITH|0x400))==(state->seed&F_ARITH);
}
static void run_case(unsigned index) {
    const Case *item=&cases[index];Observation *o=&observations[index];active_case=item;
    if(mprotect(source_map,PAGE*2,PROT_READ|PROT_WRITE) || mprotect(destination_map,PAGE*2,PROT_READ|PROT_WRITE))failure("reset_owned_protection");
    input=source_map+(item->source_guard?PAGE-PREFIX:128);
    output=destination_map+(!item->source_guard?PAGE-PREFIX:128);
    for(unsigned i=0;i<BYTES;i++)input[i]=(uint8_t)((17u*i+3u)&127u);
    for(unsigned i=0;i<PAGE*2;i++)destination_map[i]=SENTINEL;
    guard=(item->source_guard?source_map:destination_map)+PAGE;
    if(mprotect(guard,PAGE,PROT_NONE))failure("install_owned_guard");
    Machine state={(uintptr_t)input,(uintptr_t)output,BYTES/item->width,UINT64_C(0x1122334455667788),0,0,0,0,0,UINT64_C(0x202)|(index&1?F_ARITH:0)};
    active_machine=&state;repaired=0;atomic_store(&seen,0);atomic_store(&armed,1);
    atomic_store(&expected_rip,(uintptr_t)item->rep);atomic_store(&expected_recovery,(uintptr_t)item->recover);atomic_store(&expected_address,(uintptr_t)guard);
    item->run(&state);
    if(atomic_load(&seen)!=1 || atomic_load(&armed)!=0 || repaired!=1)failure("fault_or_recovery_count");
    o->address=atomic_load(&raw_address);o->rip=atomic_load(&raw_rip);o->rcx=atomic_load(&raw_rcx);o->rsi=atomic_load(&raw_rsi);o->rdi=atomic_load(&raw_rdi);o->rax=atomic_load(&raw_rax);o->flags=atomic_load(&raw_flags);
    o->signal=atomic_load(&fault_signal);o->code=atomic_load(&fault_code);o->initial_source=state.source;o->initial_destination=state.destination;o->seed=state.seed;o->restart=state;
    hex(before_restart,o->before);hex(output,o->after);
    o->fault_ok=o->address==(uintptr_t)guard && o->rip==(uintptr_t)item->rep && o->rcx==(BYTES-PREFIX)/item->width &&
        o->rsi==state.source+(item->movs?PREFIX:0) && o->rdi==state.destination+PREFIX && o->rax==state.value &&
        (o->flags&(F_ARITH|0x400))==(state.seed&F_ARITH);
    o->poison_kept=1;for(unsigned i=0;i<PREFIX;i++)if(output[i]!=poison(i))o->poison_kept=0;
    o->restart_sentinels=outside_intact();o->restart_ok=o->poison_kept && final_state(&state,item) && o->restart_sentinels;
    for(unsigned i=PREFIX;i<BYTES;i++)if(output[i]!=byte_at(item,i))o->restart_ok=0;
    // Fresh nonfaulting control; never armed and distinct from the same-RIP restart above.
    for(unsigned i=0;i<PAGE*2;i++)destination_map[i]=SENTINEL;
    Machine control=state;control.final_source=control.final_destination=control.final_count=control.final_value=control.final_flags=0;
    item->run(&control);o->completion=control;hex(output,o->control);o->completion_sentinels=outside_intact();o->completion_ok=final_state(&control,item) && o->completion_sentinels;
    for(unsigned i=0;i<BYTES;i++)if(output[i]!=byte_at(item,i))o->completion_ok=0;
}
int main(int argc,char **argv) {
    if(argc!=2 || strcmp(argv[1],"--darwin13-owned-rep-matrix"))return 64;
    char release[64]={0};size_t length=sizeof release;
    if(sysctlbyname("kern.osrelease",release,&length,NULL,0) || strncmp(release,"13.",3) || geteuid()!=0)return 77;
    if(sysconf(_SC_PAGESIZE)!=PAGE)failure("page_size");
    struct sigaction action={0};action.sa_handler=timeout_handler;sigemptyset(&action.sa_mask);
    if(sigaction(SIGALRM,&action,NULL))failure("alarm_handler");alarm(10);
    source_map=mmap(NULL,PAGE*2,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    destination_map=mmap(NULL,PAGE*2,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    void *alt=mmap(NULL,65536,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    if(source_map==MAP_FAILED || destination_map==MAP_FAILED || alt==MAP_FAILED)failure("mmap");
    stack_t stack={0};stack.ss_sp=alt;stack.ss_size=65536;if(sigaltstack(&stack,NULL))failure("alternate_stack");
    memset(&action,0,sizeof action);action.sa_sigaction=exception;action.sa_flags=SA_SIGINFO|SA_ONSTACK;sigemptyset(&action.sa_mask);
    if(sigaction(SIGSEGV,&action,NULL) || sigaction(SIGBUS,&action,NULL))failure("fault_handlers");
    int passed=1;for(unsigned i=0;i<6;i++){run_case(i);passed&=observations[i].fault_ok&&observations[i].restart_ok&&observations[i].completion_ok;}
    int failed=printf("{\"schema\":1,\"result\":\"%s\",\"architecture\":\"x86_64\",\"count_bytes\":64,\"prefix_bytes\":16,\"cases\":[",passed?"REP_FAULT_MATRIX_PASS":"REP_FAULT_MATRIX_MISMATCH")<0;
    for(unsigned i=0;i<6;i++) {
        const Case *item=&cases[i];Observation *o=&observations[i];Machine *r=&o->restart,*c=&o->completion;
        failed|=printf("%s{\"case\":\"%s\",\"width\":%u,\"movs\":%s,\"source_guard\":%s,\"initial_count\":%u,\"seed_flags\":\"%016" PRIx64 "\","
            "\"initial_rsi\":\"%016" PRIx64 "\",\"initial_rdi\":\"%016" PRIx64 "\",\"initial_rax\":\"1122334455667788\","
            "\"fault\":{\"signal\":%d,\"code\":%d,\"rip\":\"%016" PRIx64 "\",\"expected_rip\":\"%016" PRIxPTR "\",\"address\":\"%016" PRIx64 "\",\"expected_address\":\"%016" PRIxPTR "\","
            "\"rcx\":%" PRIu64 ",\"rsi\":\"%016" PRIx64 "\",\"rdi\":\"%016" PRIx64 "\",\"rax\":\"%016" PRIx64 "\",\"rflags\":\"%016" PRIx64 "\",\"destination_hex\":\"%s\",\"qualified\":%s},"
            "\"restart\":{\"same_rep_instruction\":true,\"normal_context_guard_repair\":true,\"recovery_count\":1,\"reported_registers_unchanged\":true,\"rcx\":%" PRIu64 ",\"rsi\":\"%016" PRIx64 "\",\"rdi\":\"%016" PRIx64 "\",\"rax\":\"%016" PRIx64 "\",\"rflags\":\"%016" PRIx64 "\",\"poison_preserved\":%s,\"destination_hex\":\"%s\",\"outside_sentinels_intact\":%s,\"qualified\":%s},"
            "\"completion\":{\"rcx\":%" PRIu64 ",\"rsi\":\"%016" PRIx64 "\",\"rdi\":\"%016" PRIx64 "\",\"rax\":\"%016" PRIx64 "\",\"rflags\":\"%016" PRIx64 "\",\"destination_hex\":\"%s\",\"outside_sentinels_intact\":%s,\"qualified\":%s}}",
            i?",":"",item->name,item->width,item->movs?"true":"false",item->source_guard?"true":"false",BYTES/item->width,o->seed,o->initial_source,o->initial_destination,
            o->signal,o->code,o->rip,(uintptr_t)item->rep,o->address,(uintptr_t)((item->source_guard?source_map:destination_map)+PAGE),o->rcx,o->rsi,o->rdi,o->rax,o->flags,o->before,o->fault_ok?"true":"false",
            r->final_count,r->final_source,r->final_destination,r->final_value,r->final_flags,o->poison_kept?"true":"false",o->after,o->restart_sentinels?"true":"false",o->restart_ok?"true":"false",
            c->final_count,c->final_source,c->final_destination,c->final_value,c->final_flags,o->control,o->completion_sentinels?"true":"false",o->completion_ok?"true":"false")<0;
    }
    failed|=printf("],\"guarded_faults\":6,\"cleanup_strategy\":\"process_exit_reclaims_owned_mappings_and_altstack\",\"speedup_measured\":false}\n")<0;
    int flushed=fflush(stdout),error=ferror(stdout);alarm(0);return failed||flushed||error?74:0;
}
