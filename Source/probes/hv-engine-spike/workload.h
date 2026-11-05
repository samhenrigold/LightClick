#pragma once
typedef unsigned long long u64;
enum { W_INT, W_MEM, W_CHASE_INIT, W_CHASE, W_CALL, W_CALLRAND, W_FLAGS, W_CR3, W_TOUCH, W_FLAGASM };
u64 w_int(u64 n);
u64 w_mem(u64 *a, u64 words, u64 n);
void w_chase_init(void *buf, u64 bytes);
u64 w_chase(void *buf, u64 n);
u64 w_call(u64 n);
u64 w_callrand(u64 n);
u64 w_flags(u64 n);
u64 w_cr3(u64 n, u64 cr3a, u64 cr3b, volatile char *buf, u64 pages);
u64 w_touch(volatile char *buf, u64 pages, u64 write);
u64 w_flagasm(u64 n);
