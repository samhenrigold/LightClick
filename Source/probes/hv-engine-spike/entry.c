// Spike-only flat-binary entry: rdi is the workload id, the rest pass arguments.
#include "workload.h"
__attribute__((noreturn)) void _start(u64 id, u64 a, u64 b, u64 c, u64 d, u64 e) {
    u64 r = 0;
    if (id == W_INT)
        r = w_int(a);
    else if (id == W_MEM)
        r = w_mem((u64 *)a, b, c);
    else if (id == W_CHASE_INIT)
        w_chase_init((void *)a, b);
    else if (id == W_CHASE)
        r = w_chase((void *)a, b);
    else if (id == W_CALL)
        r = w_call(a);
    else if (id == W_CALLRAND)
        r = w_callrand(a);
    else if (id == W_FLAGS)
        r = w_flags(a);
    else if (id == W_CR3)
        r = w_cr3(a, b, c, (volatile char *)d, e);
    else if (id == W_TOUCH)
        r = w_touch((volatile char *)a, b, c);
    else if (id == W_FLAGASM)
        r = w_flagasm(a);
    __asm__ volatile("hlt" : : "a"(r));
    __builtin_unreachable();
}
