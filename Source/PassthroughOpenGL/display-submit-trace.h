/* Opt-in metadata only. Never used for queue ownership or presentation decisions.
 * Reserve a separate refusal budget so initial boot successes cannot hide a later full queue.
 * Counts continue after bounded logging stops; this diagnostic perturbs timing and is not FPS evidence. */
#ifndef VIM_DISPLAY_SUBMIT_TRACE_H
#define VIM_DISPLAY_SUBMIT_TRACE_H
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>

#define VIM_SUBMIT_ATTEMPT_ROWS 128u
#define VIM_SUBMIT_REFUSAL_ROWS 128u
static pthread_once_t vim_submit_trace_once = PTHREAD_ONCE_INIT;
static int vim_submit_trace_enabled;
static uint64_t vim_submit_attempts, vim_submit_accepted, vim_submit_full, vim_submit_other;

static void VIMDisplaySubmitTraceInit(void) {
    const char *value = getenv("VIM_DISPLAY_SUBMIT_TRACE");
    __atomic_store_n(&vim_submit_trace_enabled, value && !strcmp(value, "1"), __ATOMIC_RELEASE);
    if (__atomic_load_n(&vim_submit_trace_enabled, __ATOMIC_ACQUIRE)) {
        mach_timebase_info_data_t timebase = {0};
        mach_timebase_info(&timebase);
        fprintf(stderr, "VIM_DISPLAY_SUBMIT_TRACE enabled=1 attempt_cap=%u full_refusal_cap=%u "
                        "clock=mach_absolute_time numer=%u denom=%u metadata_only=1 timing_perturbed=1\n",
                VIM_SUBMIT_ATTEMPT_ROWS, VIM_SUBMIT_REFUSAL_ROWS, timebase.numer, timebase.denom);
    }
}

static inline int VIMDisplaySubmitTraceEnabled(void) {
    pthread_once(&vim_submit_trace_once, VIMDisplaySubmitTraceInit);
    return __atomic_load_n(&vim_submit_trace_enabled, __ATOMIC_ACQUIRE);
}

static inline int VIMDisplaySubmitFullRefusal(unsigned result, int occupied, int same_owner, int stopping,
                                             int ticket_exhausted) {
    return result && occupied == 3 && same_owner && !stopping && !ticket_exhausted;
}

/* Called only when enabled, after every original queue lock has been released.
 * Occupancy is sampled BEFORE insertion under the existing sender lock; -1 means unavailable. */
static void VIMDisplaySubmitTrace(unsigned result, int occupied, int full, uint64_t epoch, uint64_t ticket,
                                  uint64_t at) {
    uint64_t attempt = __atomic_add_fetch(&vim_submit_attempts, 1, __ATOMIC_RELAXED), refusal = 0;
    if (!result)
        __atomic_add_fetch(&vim_submit_accepted, 1, __ATOMIC_RELAXED);
    else if (full)
        refusal = __atomic_add_fetch(&vim_submit_full, 1, __ATOMIC_RELAXED);
    else
        __atomic_add_fetch(&vim_submit_other, 1, __ATOMIC_RELAXED);
    if (attempt <= VIM_SUBMIT_ATTEMPT_ROWS || (full && refusal <= VIM_SUBMIT_REFUSAL_ROWS))
        fprintf(stderr, "VIM_DISPLAY_SUBMIT_TRACE attempt=%" PRIu64 " at=%" PRIu64 " result=0x%x "
                        "occupied_before=%d full_refusal=%d sealed_epoch=%" PRIu64 " ticket=%" PRIu64 "\n",
                attempt, at, result, occupied, full, epoch, ticket);
    if (attempt == VIM_SUBMIT_ATTEMPT_ROWS + 1)
        fprintf(stderr, "VIM_DISPLAY_SUBMIT_TRACE attempt_rows_truncated=1 counters_continue=1 full_refusal_budget_reserved=1\n");
    if (full && refusal == VIM_SUBMIT_REFUSAL_ROWS + 1)
        fprintf(stderr, "VIM_DISPLAY_SUBMIT_TRACE full_refusal_rows_truncated=1 counters_continue=1\n");
}

__attribute__((destructor)) static void VIMDisplaySubmitTraceSummary(void) {
    if (__atomic_load_n(&vim_submit_trace_enabled, __ATOMIC_ACQUIRE))
        fprintf(stderr, "VIM_DISPLAY_SUBMIT_TRACE summary=1 snapshot_not_atomic=1 at=%" PRIu64 " attempts=%" PRIu64
                        " accepted=%" PRIu64 " full_refusals=%" PRIu64 " other_errors=%" PRIu64
                        " attempt_cap=%u full_refusal_cap=%u\n",
                mach_absolute_time(), __atomic_load_n(&vim_submit_attempts, __ATOMIC_RELAXED),
                __atomic_load_n(&vim_submit_accepted, __ATOMIC_RELAXED),
                __atomic_load_n(&vim_submit_full, __ATOMIC_RELAXED), __atomic_load_n(&vim_submit_other, __ATOMIC_RELAXED),
                VIM_SUBMIT_ATTEMPT_ROWS, VIM_SUBMIT_REFUSAL_ROWS);
}
#endif
