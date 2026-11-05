/*
 * TCG fast paths qualified for the Apple silicon app. They are guarded by
 * architectural MMU conditions, not by guest macOS version. Setting one to 0
 * turns it off for comparison; other hosts opt in with 1 because they normally
 * run under HVF.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef QEMU_PVG_TCG_H
#define QEMU_PVG_TCG_H

static inline bool pvg_tcg_fast_path(const char *name)
{
    const char *value = getenv(name);
#if defined(__aarch64__)
    return !value || strcmp(value, "0");
#else
    return value && !strcmp(value, "1");
#endif
}

#endif
