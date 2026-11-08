// Guest-only x86_64 Darwin13 instruction-flag/fault regression. Never run on host.
// r2: separate normal capture, then repeat arithmetic with NO flag-reading instruction before fault.
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
enum { FLAG_MASK=0x8d5, OP_ADD=1, OP_SUB=2, OP_CMP=3 };
typedef __typeof__(*(((ucontext_t *)0)->uc_mcontext)) MC;
const uint32_t lc_af_layout[]={offsetof(ucontext_t,uc_mcontext),offsetof(ucontext_t,uc_mcsize),offsetof(MC,__ss.__rip),offsetof(MC,__ss.__rflags),sizeof(uintptr_t)};
static _Atomic uintptr_t expected_ip,expected_resume,expected_address;
static _Atomic uint64_t fault_flags;
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
    atomic_store_explicit(&fault_signal,number,memory_order_relaxed);
    atomic_store_explicit(&fault_code,info->si_code,memory_order_relaxed);
    context->uc_mcontext->__ss.__rip=resume;
    atomic_store_explicit(&seen,1,memory_order_relaxed);
    atomic_store_explicit(&armed,0,memory_order_relaxed);
}
static void timeout_handler(int number) { (void)number;_exit(124); }
typedef struct { uint64_t result,before,after; } Observation;
typedef Observation (*Probe)(uint64_t,const void *);
#define STR_(x) #x
#define STR(x) STR_(x)
#define DECLARE_LABELS(name) extern const char name##_fault[],name##_resume[];
#define FAULT_MOV(name) ".globl _" STR(name) "_fault\n_" STR(name) "_fault:\nmovq (%%rdi),%%r10\n.globl _" STR(name) "_resume\n_" STR(name) "_resume:\n"
#define PROBE_REG(name,instruction,amount) \
    DECLARE_LABELS(name) \
    __attribute__((noinline,used)) static Observation name(uint64_t left,const void *bad) { \
        uint64_t original=left,before,after; \
        __asm__ volatile(instruction " $" STR(amount) "," REG_TARGET "\npushfq\npopq %%rdx\nmovq %%rsi,%%rax\n" \
            instruction " $" STR(amount) "," REG_TARGET "\n" FAULT_MOV(name) "pushfq\npopq %%rcx\n" \
            : "+a"(left),"=&d"(before),"=&c"(after) : "D"(bad),"S"(original) : "r10","cc","memory"); \
        return (Observation){left,before,after}; \
    }
#define REG_TARGET "%%eax"
#define REG32(amount) PROBE_REG(add32_##amount,"addl",amount) PROBE_REG(sub32_##amount,"subl",amount) PROBE_REG(cmp32_##amount,"cmpl",amount)
REG32(5) REG32(9) REG32(17) REG32(21) REG32(72) REG32(4095)
PROBE_REG(sub32_880,"subl",880)
#undef REG_TARGET
#define REG_TARGET "%%rax"
#define REG64(amount) PROBE_REG(add64_##amount,"addq",amount) PROBE_REG(sub64_##amount,"subq",amount) PROBE_REG(cmp64_##amount,"cmpq",amount)
REG64(5) REG64(9) REG64(17) REG64(21) REG64(72) REG64(4095)
PROBE_REG(add64_26,"addq",26) PROBE_REG(cmp64_2464,"cmpq",2464)
#undef REG_TARGET

#define PROBE_MEMORY(name,instruction,amount) \
    DECLARE_LABELS(name) \
    __attribute__((noinline,used)) static Observation name(uint64_t left,const void *bad) { \
        volatile uint64_t memory=left;uint64_t before,after; \
        __asm__ volatile(instruction " $" STR(amount) ",(%%rsi)\npushfq\npopq %%rdx\n" \
            instruction " $" STR(amount) ",(%%rsi)\n" FAULT_MOV(name) "pushfq\npopq %%rcx\n" \
            : "=d"(before),"=c"(after) : "S"(&memory),"D"(bad) : "r10","cc","memory"); \
        return (Observation){memory,before,after}; \
    }
PROBE_MEMORY(mem32_5,"cmpl",5) PROBE_MEMORY(mem64_5,"cmpq",5)
PROBE_MEMORY(mem32_2464,"cmpl",2464) PROBE_MEMORY(mem64_2464,"cmpq",2464)

#define PROBE_FAULT_CMP(name,instruction,amount) \
    DECLARE_LABELS(name) \
    __attribute__((noinline,used)) static Observation name(uint64_t left,const void *bad) { \
        uint64_t original=left,before,after; \
        __asm__ volatile("addq $5,%%rax\npushfq\npopq %%rdx\nmovq %%rsi,%%rax\naddq $5,%%rax\n.globl _" STR(name) "_fault\n_" STR(name) "_fault:\n" \
            instruction " $" STR(amount) ",(%%rdi)\n.globl _" STR(name) "_resume\n_" STR(name) "_resume:\npushfq\npopq %%rcx\n" \
            : "+a"(left),"=&d"(before),"=&c"(after) : "D"(bad),"S"(original) : "cc","memory"); \
        return (Observation){left,before,after}; \
    }
PROBE_FAULT_CMP(fault32_72,"cmpl",72) PROBE_FAULT_CMP(fault64_72,"cmpq",72)
PROBE_FAULT_CMP(fault32_880,"cmpl",880) PROBE_FAULT_CMP(fault64_880,"cmpq",880)

typedef struct { const char *name;unsigned operation,width;uint64_t immediate;Probe probe;const char *ip,*resume; } Case;
#define CASE(name,operation,width,imm) {STR(name),operation,width,imm,name,name##_fault,name##_resume}
#define CASES32(imm) CASE(add32_##imm,OP_ADD,32,imm),CASE(sub32_##imm,OP_SUB,32,imm),CASE(cmp32_##imm,OP_CMP,32,imm)
#define CASES64(imm) CASE(add64_##imm,OP_ADD,64,imm),CASE(sub64_##imm,OP_SUB,64,imm),CASE(cmp64_##imm,OP_CMP,64,imm)
static const Case registers[]={CASES32(5),CASES32(9),CASES32(17),CASES32(21),CASES32(72),CASES32(4095),
    CASES64(5),CASES64(9),CASES64(17),CASES64(21),CASES64(72),CASES64(4095),
    CASE(add64_26,OP_ADD,64,26),CASE(sub32_880,OP_SUB,32,880),CASE(cmp64_2464,OP_CMP,64,2464)};
static const Case memories[]={CASE(mem32_5,OP_CMP,32,5),CASE(mem64_5,OP_CMP,64,5),CASE(mem32_2464,OP_CMP,32,2464),CASE(mem64_2464,OP_CMP,64,2464)};
static const Case faulting[]={CASE(fault32_72,OP_ADD,64,5),CASE(fault64_72,OP_ADD,64,5),CASE(fault32_880,OP_ADD,64,5),CASE(fault64_880,OP_ADD,64,5)};
static uint64_t expected(unsigned operation,unsigned width,uint64_t left,uint64_t immediate,uint64_t *result) {
    uint64_t mask=width==32?UINT32_MAX:UINT64_MAX,sign=width==32?0x80000000ull:0x8000000000000000ull;
    uint64_t a=left&mask,b=immediate&mask,r=(operation==OP_ADD?a+b:a-b)&mask,flags=0;
    if(operation==OP_ADD?r<a:a<b)flags|=1;
    unsigned parity=0;for(unsigned bit=0;bit<8;bit++)parity^=(unsigned)((r>>bit)&1);
    if(!parity)flags|=4;
    if((a^b^r)&16)flags|=16;
    if(!r)flags|=64;
    if(r&sign)flags|=128;
    if(operation==OP_ADD?((~(a^b)&(a^r)&sign)!=0):(((a^b)&(a^r)&sign)!=0))flags|=2048;
    *result=operation==OP_CMP?left:r;return flags;
}
static unsigned tested,normal_cases,memory_cases,faulting_cases,af_set,af_clear,segv_count,bus_count;
static int run_case(const Case *item,uint64_t input,const void *bad,int mode) {
    uintptr_t ip=(uintptr_t)item->ip,resume=(uintptr_t)item->resume;
    if(resume<=ip || resume-ip>8)return 71;
    atomic_store(&expected_ip,ip);atomic_store(&expected_resume,resume);atomic_store(&expected_address,(uintptr_t)bad);
    atomic_store(&fault_flags,0);atomic_store(&fault_signal,0);atomic_store(&fault_code,0);atomic_store(&seen,0);atomic_store(&armed,1);
    Observation actual=item->probe(input,bad);
    uint64_t wanted_result,wanted=expected(item->operation,item->width,input,item->immediate,&wanted_result);
    uint64_t fault=atomic_load(&fault_flags)&FLAG_MASK;
    if(atomic_load(&seen)!=1 || atomic_load(&armed)!=0 || (actual.before&FLAG_MASK)!=wanted ||
       (actual.after&FLAG_MASK)!=wanted || fault!=wanted || actual.result!=wanted_result) {
        printf("{\"schema\":1,\"result\":\"FAIL\",\"case\":\"%s\",\"mode\":%d,\"input\":\"%016" PRIx64 "\",\"expected_flags\":\"%03" PRIx64 "\",\"before\":\"%03" PRIx64 "\",\"fault\":\"%03" PRIx64 "\",\"after\":\"%03" PRIx64 "\",\"expected_result\":\"%016" PRIx64 "\",\"actual_result\":\"%016" PRIx64 "\",\"tested_before_failure\":%u}\n",item->name,mode,input,wanted,actual.before&FLAG_MASK,fault,actual.after&FLAG_MASK,wanted_result,actual.result,tested);
        return 1;
    }
    tested++;if(wanted&16)af_set++;else af_clear++;
    if(atomic_load(&fault_signal)==SIGSEGV)segv_count++;else if(atomic_load(&fault_signal)==SIGBUS)bus_count++;else return 72;
    if(mode==0)normal_cases++;else if(mode==1)memory_cases++;else faulting_cases++;
    return 0;
}
int main(int argc,char **argv) {
    if(argc!=2 || strcmp(argv[1],"--darwin13-owned-af-flags"))return 64;
    char release[64]={0};size_t length=sizeof(release);
    if(sysctlbyname("kern.osrelease",release,&length,NULL,0) || strncmp(release,"13.",3))return 77;
    if(geteuid()!=0)return 77;
    mach_timebase_info_data_t tb;if(mach_timebase_info(&tb)!=KERN_SUCCESS || !tb.denom)return 78;
    uint64_t start=mach_absolute_time();
    struct sigaction action={0};action.sa_handler=timeout_handler;sigemptyset(&action.sa_mask);
    if(sigaction(SIGALRM,&action,NULL))return 70;
    alarm(9);
    long page_size=sysconf(_SC_PAGESIZE);if(page_size<4096 || page_size>65536)return 70;
    void *bad=mmap(NULL,(size_t)page_size,PROT_NONE,MAP_PRIVATE|MAP_ANON,-1,0);
    void *alt=mmap(NULL,65536,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    if(bad==MAP_FAILED || alt==MAP_FAILED)return 70;
    stack_t stack={0};stack.ss_sp=alt;stack.ss_size=65536;
    if(sigaltstack(&stack,NULL))return 70;
    memset(&action,0,sizeof(action));action.sa_sigaction=exception;action.sa_flags=SA_SIGINFO|SA_ONSTACK;sigemptyset(&action.sa_mask);
    if(sigaction(SIGSEGV,&action,NULL) || sigaction(SIGBUS,&action,NULL))return 70;
    for(size_t i=0;i<sizeof(registers)/sizeof(registers[0]);i++) {
        const Case *item=&registers[i];uint64_t sign=item->width==32?0x80000000ull:0x8000000000000000ull;
        uint64_t mask=item->width==32?UINT32_MAX:UINT64_MAX,low=item->immediate&15;
        uint64_t values[]={0,15,item->immediate,item->immediate-1,(16-low)&15,sign-1,sign,mask,
            (item->width==32?0xa5a5a5a500000000ull:0x5a5a5a5a5a5a0000ull)|low};
        for(unsigned j=0;j<9;j++) { int code=run_case(item,values[j],bad,0);if(code)return code; }
    }
    for(size_t i=0;i<sizeof(memories)/sizeof(memories[0]);i++) {
        const Case *item=&memories[i];uint64_t values[]={0,item->immediate-1,item->immediate,UINT64_MAX};
        for(unsigned j=0;j<4;j++) { int code=run_case(item,values[j],bad,1);if(code)return code; }
    }
    for(size_t i=0;i<sizeof(faulting)/sizeof(faulting[0]);i++)for(unsigned j=0;j<2;j++) {
        int code=run_case(&faulting[i],j?11:0,bad,2);if(code)return code;
    }
    alarm(0);
    double seconds=(double)(mach_absolute_time()-start)*(double)tb.numer/(double)tb.denom/1e9;
    int pass=tested==375 && normal_cases==351 && memory_cases==16 && faulting_cases==8 && af_set && af_clear && seconds<=10;
    printf("{\"schema\":1,\"result\":\"%s\",\"architecture\":\"x86_64\",\"darwin_major\":13,\"euid\":0,\"flag_mask\":2261,\"normal_cases\":%u,\"valid_memory_CMP_cases\":%u,\"faulting_memory_CMP_cases\":%u,\"guarded_faults\":%u,\"AF_set_cases\":%u,\"AF_clear_cases\":%u,\"SIGSEGV\":%u,\"SIGBUS\":%u,\"seconds_guest_monotonic\":%.9f,\"ucontext_mcontext_offset\":%u,\"ucontext_mcsize_offset\":%u,\"mcontext_rip_offset\":%u,\"mcontext_rflags_offset\":%u,\"exact_fault_resume_address_guards\":true,\"handler_no_alloc_or_stdio\":true}\n",pass?"PASS":"FAIL_COUNTS_OR_DEADLINE",normal_cases,memory_cases,faulting_cases,tested,af_set,af_clear,segv_count,bus_count,seconds,lc_af_layout[0],lc_af_layout[1],lc_af_layout[2],lc_af_layout[3]);
    // Own mappings and handler state stay valid until this isolated process exits.
    return pass?0:1;
}
