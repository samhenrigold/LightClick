// Guest-only Darwin13 SHR-byte flags/following-fault regression. Never run on host.
// Uses the Engine helper model, including its deterministic undefined AF/OF.
// A second SHR executes with no flag-reading instruction before the guarded fault.
#include <errno.h>
#include <inttypes.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/ucontext.h>
#include <unistd.h>
#if !defined(__x86_64__) || !defined(__APPLE__)
#error Guest x86_64 Darwin only.
#endif
_Static_assert(ATOMIC_POINTER_LOCK_FREE==2 && ATOMIC_LLONG_LOCK_FREE==2,"handler atomics must be lock-free");
enum { FLAG_MASK=0x8d5 };
typedef __typeof__(*(((ucontext_t *)0)->uc_mcontext)) MC;
const uint32_t lc_shr8_layout[]={offsetof(ucontext_t,uc_mcontext),offsetof(ucontext_t,uc_mcsize),offsetof(MC,__ss.__rip),offsetof(MC,__ss.__rflags),sizeof(uintptr_t)};
static _Atomic uintptr_t expected_ip,expected_resume,expected_address;
static _Atomic uint64_t fault_flags,fault_rax;
static _Atomic int armed,seen,fault_signal,fault_code;
static void exception(int number,siginfo_t *info,void *raw) {
    ucontext_t *context=raw;
    uintptr_t ip=atomic_load_explicit(&expected_ip,memory_order_relaxed);
    uintptr_t resume=atomic_load_explicit(&expected_resume,memory_order_relaxed);
    if(!info || !context || !context->uc_mcontext ||
       context->uc_mcsize<offsetof(MC,__ss.__rflags)+sizeof(uint64_t) ||
       atomic_load_explicit(&armed,memory_order_relaxed)!=1 ||
       atomic_load_explicit(&seen,memory_order_relaxed)!=0 ||
       !((number==SIGSEGV && info->si_code==SEGV_ACCERR) || (number==SIGBUS && info->si_code==BUS_ADRERR)) ||
       (uintptr_t)info->si_addr!=atomic_load_explicit(&expected_address,memory_order_relaxed) ||
       (uintptr_t)context->uc_mcontext->__ss.__rip!=ip || resume<=ip || resume-ip>8) _exit(90);
    atomic_store_explicit(&fault_flags,context->uc_mcontext->__ss.__rflags,memory_order_relaxed);
    atomic_store_explicit(&fault_rax,context->uc_mcontext->__ss.__rax,memory_order_relaxed);
    atomic_store_explicit(&fault_signal,number,memory_order_relaxed);
    atomic_store_explicit(&fault_code,info->si_code,memory_order_relaxed);
    context->uc_mcontext->__ss.__rip=resume;
    atomic_store_explicit(&seen,1,memory_order_relaxed);
    atomic_store_explicit(&armed,0,memory_order_relaxed);
}
static void timeout_handler(int number) { (void)number;_exit(124); }

typedef struct { uint64_t result,before,after; } Observation;
typedef Observation (*Probe)(uint64_t,const void *,uint64_t);
#define STR_(x) #x
#define STR(x) STR_(x)
#define PROBE(name,target,amount) \
    extern const char name##_fault[],name##_resume[]; \
    __attribute__((noinline,used)) static Observation name(uint64_t left,const void *bad,uint64_t seed) { \
        uint64_t original=left,before,after; \
        __asm__ volatile("pushq %[seed]\npopfq\nshrb $" STR(amount) "," target "\npushfq\npopq %%rdx\nmovq %%rsi,%%rax\n" \
            "pushq %[seed]\npopfq\nshrb $" STR(amount) "," target "\n.globl _" STR(name) "_fault\n_" STR(name) "_fault:\n" \
            "movq (%%rdi),%%r10\n.globl _" STR(name) "_resume\n_" STR(name) "_resume:\npushfq\npopq %%rcx\n" \
            : "+&a"(left),"=&d"(before),"=&c"(after) : "D"(bad),"S"(original),[seed]"r"(seed) : "r10","cc","memory"); \
        return (Observation){left,before,after}; \
    }
#define PAIR(n) PROBE(low_##n,"%%al",n) PROBE(high_##n,"%%ah",n)
PAIR(0) PAIR(1) PAIR(2) PAIR(3) PAIR(4) PAIR(5) PAIR(6) PAIR(7)
PAIR(8) PAIR(9) PAIR(10) PAIR(11) PAIR(12) PAIR(13) PAIR(14) PAIR(15)
PAIR(16) PAIR(17) PAIR(18) PAIR(19) PAIR(20) PAIR(21) PAIR(22) PAIR(23)
PAIR(24) PAIR(25) PAIR(26) PAIR(27) PAIR(28) PAIR(29) PAIR(30) PAIR(31)
PAIR(32) PAIR(33) PAIR(63) PAIR(255)
typedef struct { const char *name;unsigned immediate,high;Probe probe;const char *ip,*resume; } Case;
#define ITEM(n,highbit,prefix) {STR(prefix##_##n),n,highbit,prefix##_##n,prefix##_##n##_fault,prefix##_##n##_resume}
#define ITEMS(n) ITEM(n,0,low),ITEM(n,1,high)
static const Case cases[]={ITEMS(0),ITEMS(1),ITEMS(2),ITEMS(3),ITEMS(4),ITEMS(5),ITEMS(6),ITEMS(7),
    ITEMS(8),ITEMS(9),ITEMS(10),ITEMS(11),ITEMS(12),ITEMS(13),ITEMS(14),ITEMS(15),
    ITEMS(16),ITEMS(17),ITEMS(18),ITEMS(19),ITEMS(20),ITEMS(21),ITEMS(22),ITEMS(23),
    ITEMS(24),ITEMS(25),ITEMS(26),ITEMS(27),ITEMS(28),ITEMS(29),ITEMS(30),ITEMS(31),
    ITEMS(32),ITEMS(33),ITEMS(63),ITEMS(255)};
static uint64_t expected(const Case *item,uint64_t input,uint64_t seed,uint64_t *result) {
    unsigned n=item->immediate&31,offset=item->high?8:0,v=(unsigned)(input>>offset)&255;
    if(!n){*result=input;return seed&FLAG_MASK;}
    unsigned r=n<8?v>>n:0;
    *result=(input&~(UINT64_C(255)<<offset))|((uint64_t)r<<offset);
    uint64_t flags=0;
    if(n<=8 && ((v>>(n-1))&1))flags|=1;
    unsigned parity=0;for(unsigned bit=0;bit<8;bit++)parity^=(r>>bit)&1;
    if(!parity)flags|=4;
    if(!r)flags|=64;
    if(v&128)flags|=2048; // h_shift's OF model for every nonzero count; AF model is zero.
    return flags;
}
int main(int argc,char **argv) {
    if(argc!=2 || strcmp(argv[1],"--darwin13-owned-shr8-faults"))return 64;
    char release[64]={0};size_t length=sizeof(release);
    if(sysctlbyname("kern.osrelease",release,&length,NULL,0) || strncmp(release,"13.",3) || geteuid()!=0)return 77;
    mach_timebase_info_data_t tb;if(mach_timebase_info(&tb)!=KERN_SUCCESS || !tb.numer || !tb.denom)return 78;
    uint64_t start=mach_absolute_time();
    struct sigaction action={0};action.sa_handler=timeout_handler;sigemptyset(&action.sa_mask);
    if(sigaction(SIGALRM,&action,NULL))return 70;
    alarm(25);
    long page_size=sysconf(_SC_PAGESIZE);if(page_size<4096 || page_size>65536)return 70;
    void *bad=mmap(NULL,(size_t)page_size,PROT_NONE,MAP_PRIVATE|MAP_ANON,-1,0);
    void *alt=mmap(NULL,65536,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    if(bad==MAP_FAILED || alt==MAP_FAILED)return 70;
    stack_t stack={0};stack.ss_sp=alt;stack.ss_size=65536;
    if(sigaltstack(&stack,NULL))return 70;
    memset(&action,0,sizeof(action));action.sa_sigaction=exception;action.sa_flags=SA_SIGINFO|SA_ONSTACK;sigemptyset(&action.sa_mask);
    if(sigaction(SIGSEGV,&action,NULL) || sigaction(SIGBUS,&action,NULL))return 70;
    static const unsigned values[]={0,1,127,128,129,170,254,255};
    unsigned tested=0,low=0,high=0,zero=0,segv=0,bus=0;
    uint64_t digest=UINT64_C(14695981039346656037);
    for(size_t i=0;i<sizeof(cases)/sizeof(cases[0]);i++)for(unsigned j=0;j<8;j++)for(unsigned seedbit=0;seedbit<2;seedbit++) {
        const Case *item=&cases[i];uint64_t seed=UINT64_C(0x202)|(seedbit?FLAG_MASK:0);
        uint64_t input=item->high?(UINT64_C(0xa55a112233440066)|((uint64_t)values[j]<<8)):(UINT64_C(0xa55a112233445500)|values[j]);
        uintptr_t ip=(uintptr_t)item->ip,resume=(uintptr_t)item->resume;
        if(resume<=ip || resume-ip>8)return 71;
        atomic_store(&expected_ip,ip);atomic_store(&expected_resume,resume);atomic_store(&expected_address,(uintptr_t)bad);
        atomic_store(&seen,0);atomic_store(&armed,1);atomic_store(&fault_flags,0);atomic_store(&fault_rax,0);
        Observation actual=item->probe(input,bad,seed);
        uint64_t result,wanted=expected(item,input,seed,&result),fault=atomic_load(&fault_flags)&FLAG_MASK;
        if(atomic_load(&seen)!=1 || atomic_load(&armed)!=0 || (actual.before&FLAG_MASK)!=wanted ||
           (actual.after&FLAG_MASK)!=wanted || fault!=wanted || actual.result!=result || atomic_load(&fault_rax)!=result) {
            printf("{\"result\":\"FAIL\",\"case\":\"%s\",\"input\":\"%016" PRIx64 "\",\"seed\":\"%03" PRIx64 "\",\"expected_flags\":\"%03" PRIx64 "\",\"normal_flags\":\"%03" PRIx64 "\",\"fault_flags\":\"%03" PRIx64 "\",\"resumed_flags\":\"%03" PRIx64 "\",\"expected_rax\":\"%016" PRIx64 "\",\"actual_rax\":\"%016" PRIx64 "\",\"fault_rax\":\"%016" PRIx64 "\",\"tested_before_failure\":%u}\n",item->name,input,seed&FLAG_MASK,wanted,actual.before&FLAG_MASK,fault,actual.after&FLAG_MASK,result,actual.result,atomic_load(&fault_rax),tested);
            return 1;
        }
        tested++;if(item->high)high++;else low++;if(!(item->immediate&31))zero++;
        if(atomic_load(&fault_signal)==SIGSEGV)segv++;else if(atomic_load(&fault_signal)==SIGBUS)bus++;else return 72;
        digest=(digest^actual.result)*UINT64_C(1099511628211);digest=(digest^fault)*UINT64_C(1099511628211);
    }
    alarm(0);
    double seconds=(double)(mach_absolute_time()-start)*(double)tb.numer/(double)tb.denom/1e9;
    int pass=tested==1152 && low==576 && high==576 && zero==64 && segv+bus==1152 && seconds>0 && seconds<=25;
    printf("{\"schema\":1,\"result\":\"%s\",\"architecture\":\"x86_64\",\"darwin_major\":13,\"euid\":0,\"flag_mask\":2261,\"guarded_faults\":%u,\"low_byte_cases\":%u,\"high_byte_cases\":%u,\"effective_zero_cases\":%u,\"SIGSEGV\":%u,\"SIGBUS\":%u,\"seconds_guest_monotonic\":%.9f,\"observation_digest\":\"%016" PRIx64 "\",\"ucontext_mcontext_offset\":%u,\"ucontext_mcsize_offset\":%u,\"mcontext_rip_offset\":%u,\"mcontext_rflags_offset\":%u,\"exact_fault_resume_address_guards\":true,\"handler_no_alloc_or_stdio\":true,\"model\":\"existing_h_shift_including_undefined_AF_OF\"}\n",pass?"PASS":"FAIL_COUNTS_OR_DEADLINE",tested,low,high,zero,segv,bus,seconds,digest,lc_shr8_layout[0],lc_shr8_layout[1],lc_shr8_layout[2],lc_shr8_layout[3]);
    return pass?0:1;
}
