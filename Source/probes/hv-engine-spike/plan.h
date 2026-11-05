// The benchmark sequence, shared so that checksums from all three runs are directly comparable.
// Each row runs once to warm up (translate, fill the shadow) and then REPS times; the minimum is reported.
#pragma once
#include "workload.h"
#define REPS 5
#define BUF16K 0x4000ULL
#define BUF64M 0x4000000ULL
#define MEM_WORDS 2048ULL
#define MEM_ROUNDS 20000ULL
#define N_INT 100000000ULL
#define N_CHASE16K 100000001ULL
#define N_CHASE64M 5000000ULL
#define N_CALL 30000000ULL
#define N_CALLRAND 30000000ULL
#define N_FLAGS 10000000ULL
#define N_FLAGASM 2000000ULL
