/* Lets the legacy shadow reach guest RAM without per-run imports.
 * SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef APPLE_GFX_SHADOW_RAM_H
#define APPLE_GFX_SHADOW_RAM_H
#include <stdbool.h>
#include <stdint.h>
typedef struct {
    uint8_t *host;
    uint64_t length, file_offset;
} AppleGFXShadowRegion;
typedef struct {
    uint32_t region, page; /* page is 4 KB units from the region's start. */
} AppleGFXShadowPage;
/* False if any page is unmapped, read-only or outside every task. */
typedef bool (*AppleGFXShadowLookup)(const void *address, uint64_t pages, AppleGFXShadowPage *out);
void apple_gfx_legacy_shadow_set_ram(const AppleGFXShadowRegion *regions, uint32_t count, AppleGFXShadowLookup lookup);
#endif
