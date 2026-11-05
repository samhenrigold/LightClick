// Host-side atomics on state shared with the monitor. Swift has no atomics on imported C fields.
#include "engine_abi.h"
#include "engine_api.h"

void engine_ctx_post_vector(void *ctx, uint8_t vector, bool level) {
    EngineCtx *c = ctx;
    uint32_t bit = 1u << (vector & 31);
    if (level)
        __atomic_fetch_or(&c->apic_host_level[vector / 32], bit, __ATOMIC_RELEASE);
    else
        __atomic_fetch_and(&c->apic_host_level[vector / 32], ~bit, __ATOMIC_RELEASE);
    __atomic_fetch_or(&c->apic_host_irr[vector / 32], bit, __ATOMIC_RELEASE);
}

void engine_ctx_set_stop(void *ctx) { __atomic_store_n(&((EngineCtx *)ctx)->stop_requested, 1, __ATOMIC_RELEASE); }
