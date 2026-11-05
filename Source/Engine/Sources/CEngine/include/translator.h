// Host-side translator interface. The Swift control plane calls these while the vCPU is stopped in a hypervisor call.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "engine_abi.h"

typedef struct {
    uint8_t *priv; // host mapping of private memory
    uint8_t *ram; // host mapping of x86 RAM
    uint64_t ram_size;
    bool precise_flags; // keep every arithmetic flag exact at every instruction that can fault
    uint64_t stub_lookup, stub_ret_miss, stub_pushf, stub_sahf; // guest VAs
    uint64_t code_cache_bytes; // 0 for all of it; tests shrink it to exercise the flush
    bool has_tzcnt_lzcnt; // CPUID advertises BMI1 and ABM; without them these encodings are bsf and bsr
    bool hybrid; // CR0.TS is live, so integer instructions must not need NEON outside a stub that can back out
    uint64_t ram_below_4g; // 0: RAM is one piece. Otherwise GPA 4 GB and up is host RAM at this offset
} TrConfig;

typedef struct {
    uint64_t arm; // guest VA of the translation
    uint64_t fetch_fault_va; // nonzero: the instruction runs onto this unmapped or non-executable page
    uint64_t frames[2]; // GPA frames the block was read from (second is ~0 when unused)
    bool flushed; // the code cache was reset to make room: every pointer into it is stale
    int key; // the translation domain of the target: tr_link needs it
} TrResult;

void tr_init(const TrConfig *config);

// Translates x86 `rip` in the given view. `cr3` and `cpl` describe the view. With `single` the block is exactly one
// instruction, never registered for lookup: it runs once after a self-modifying write.
TrResult tr_translate(int view, uint64_t cr3, int cpl, uint64_t rip, bool single);

// Patches an exit stub: site is the guest VA reported in the request, kind the svc number, arm the linked target.
void tr_link(uint64_t site, int kind, uint64_t arm, int key);

// Installs a lookup entry in the view's indirect-branch table.
void tr_hash_insert(int view, uint64_t rip, uint64_t arm);

// Invalidates every block translated from a guest frame, in all views. Returns the count.
int tr_invalidate_frame(uint64_t gpa);
// Invalidates the blocks of one view at one x86 page (its mapping changed).
int tr_invalidate_view_va(int view, uint64_t va);
// Forgets a view being reused for another address space: its own blocks and its lookup table.
void tr_view_drop(int view);
// Forgets one whole view.
void tr_flush_all(void);

// Text for a stop reason written by the translator.
const char *tr_stop_reason(uint32_t index);

typedef struct {
    uint64_t blocks, insns, words;
    uint64_t invalidated;
    uint64_t translate_ns;
} TrStats;
TrStats tr_stats(void);

