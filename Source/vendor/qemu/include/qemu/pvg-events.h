/*
 * Counts of the guest events that would each cost a VM exit in a hardware-MMU engine, to tell
 * whether that engine is worth building. Set PVG_TCG_EVENTS to a file to record totals every second.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef QEMU_PVG_EVENTS_H
#define QEMU_PVG_EVENTS_H

enum {
    PVG_EVENT_CR3, PVG_EVENT_TLB_MISS, PVG_EVENT_INVLPG, PVG_EVENT_TLB_FLUSH, PVG_EVENT_REMOTE_FLUSH,
    PVG_EVENT_EXCEPTION, PVG_EVENT_HW_INTERRUPT, PVG_EVENT_SYSCALL, PVG_EVENT_SYSRET, PVG_EVENT_IRET,
    PVG_EVENT_MSR, PVG_EVENT_MMIO_READ, PVG_EVENT_MMIO_WRITE, PVG_EVENT_IPI, PVG_EVENT_CODE_WRITE,
    PVG_EVENT_CR3_FLUSH, PVG_EVENT_PHYS_MISS, PVG_EVENT_PT_WRITE,
    PVG_EVENT_COUNT
};
extern unsigned long pvg_events[PVG_EVENT_COUNT];
extern bool pvg_events_enabled;
#define PVG_EVENT(name) \
    do { \
        if (unlikely(pvg_events_enabled)) { \
            __atomic_fetch_add(&pvg_events[PVG_EVENT_##name], 1, __ATOMIC_RELAXED); \
        } \
    } while (0)

#endif
