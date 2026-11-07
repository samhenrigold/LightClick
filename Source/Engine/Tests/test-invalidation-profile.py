#!/usr/bin/env python3
"""Emit a host-only mechanism fixture from production invalidation functions. No Engine, HVF, guest or code execution.

    python3 Tests/test-invalidation-profile.py --emit-c /tmp/invalidation-profile-check.c
    nice -n 10 xcrun clang -O2 -Wall -Wextra -Werror /tmp/invalidation-profile-check.c -o /tmp/invalidation-profile-check
    /tmp/invalidation-profile-check

Clocks/cache maintenance are stubs: this tests sampling, exact hash changes and counters, NOT performance.
"""
import argparse
import json
from pathlib import Path
import re

engine = Path(__file__).resolve().parents[1]
source = (engine/'Sources/CEngine/translate.c').read_text()


def function(name):
    match = re.search(r'(?m)^static [^;{\n]+\b'+re.escape(name)+r'\([^;{]*\)\s*\{', source)
    assert match, name
    depth, at = 1, match.end()
    while depth:
        depth += (source[at] == '{') - (source[at] == '}')
        at += 1
    return source[match.start():at]


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--emit-c', type=Path, required=True)
args = parser.parse_args()
assert 'cfg.profile_invalidations && (++stats.invalidation_profiled_kills & 255) == 0' in source
assert 'config.profile_invalidations = environment["LC_HVDBT_PROFILE_INVALIDATION"] == "1"' in (engine/'Sources/Engine/Engine.swift').read_text()
assert 'SVC_DEAD starts with view_lookup' in source
header = json.dumps(str(engine/'Sources/CEngine/include/translator.h'))
prefix = r'''
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#include HEADER
#undef HASH_ENTRIES
#define HASH_ENTRIES 64u
#define MAP_BITS 6
#define MAP_SIZE (1u << MAP_BITS)
#define DEAD_SLOTS 16u
#define WORD_DEAD (0xD4000001u | SVC_DEAD << 5)
#define KEY_DOMAIN 0x40000000u
typedef uint64_t u64;
typedef uint32_t u32;
typedef struct { u64 rip; u32 view, block; } MapEntry;
typedef struct { u64 rip; u32 view, entry_word; bool dead, registered; uint16_t read_bytes; } HostBlock;
static TrConfig cfg;
static TrStats stats;
static mach_timebase_info_data_t invalidation_timebase = {125, 3};
static u64 table[MAX_VIEWS][HASH_ENTRIES * 2];
static u64 *hash_table(int view) { return table[view]; }
static MapEntry block_map[MAP_SIZE];
static HostBlock hblocks[1];
static u32 cc_storage, *cc_base = &cc_storage;
static u32 dead_slots[DEAD_SLOTS];
static int view_high;
static u64 clock_calls, icache_calls;
static u64 fixture_clock(void) { clock_calls++; return clock_calls * 3; }
static void fixture_icache(void *entry, size_t bytes) {
    assert(entry == &cc_storage && bytes == 4 && cc_storage == WORD_DEAD);
    icache_calls++;
}
#define mach_absolute_time fixture_clock
#define sys_icache_invalidate fixture_icache
'''.replace('HEADER', header)
functions = '\n\n'.join(function(name) for name in (
    'map_hash', 'map_insert', 'map_remove', 'crc32c64', 'dead_slot',
    'invalidation_ns', 'hash_remove', 'hash_remove_profiled', 'kill_block'))
checks = r'''
static void collision_equivalence(void) {
    const u64 rip = 0x12345678;
    u32 start = crc32c64(rip) & (HASH_ENTRIES - 1);
    for (int mode = 0; mode < 3; mode++) {
        memset(table, 0, sizeof(table));
        memset(&stats, 0, sizeof(stats));
        if (mode == 2) {
            for (u32 slot = 0; slot < HASH_ENTRIES; slot++) table[0][slot * 2] = 1;
        } else {
            table[0][start * 2] = 1;
            table[0][((start + 1) & (HASH_ENTRIES - 1)) * 2] = rip + 1;
            if (mode == 0) table[0][((start + 2) & (HASH_ENTRIES - 1)) * 2] = rip;
        }
        memcpy(table[1], table[0], sizeof(table[0]));
        hash_remove(0, rip);
        hash_remove_profiled(1, rip);
        assert(!memcmp(table[0], table[1], sizeof(table[0])));
        assert(stats.invalidation_hash_view_visits == 1);
        assert(stats.invalidation_hash_probes == (mode == 2 ? HASH_ENTRIES : 3));
        assert(stats.invalidation_hash_removals == (mode == 0 ? 1 : 0));
    }
}
static void kills(bool enabled, int views, bool shared, bool registered) {
    memset(&stats, 0, sizeof(stats));
    cfg.profile_invalidations = enabled;
    clock_calls = icache_calls = 0;
    view_high = views - 1;
    for (int i = 0; i < 512; i++) {
        memset(table, 0, sizeof(table));
        memset(block_map, 0, sizeof(block_map));
        u64 rip = 0x10000 + (u64)i * 8;
        u32 key = shared ? KEY_DOMAIN : 0;
        hblocks[0] = (HostBlock){.rip = rip, .view = key, .registered = registered};
        map_insert((int)key, rip, 1);
        u32 slot = crc32c64(rip) & (HASH_ENTRIES - 1);
        table[0][slot * 2] = rip;
        if (shared && views > 1) table[views - 1][slot * 2] = rip;
        cc_storage = 0;
        kill_block(0);
        kill_block(0); // Already-dead calls must not consume sampling cadence or maintain the cache twice.
        assert(hblocks[0].dead && cc_storage == WORD_DEAD);
        if (registered) {
            assert(block_map[map_hash((int)key, rip)].block == ~0u);
            assert(table[0][slot * 2] == 1);
            if (shared && views > 1) assert(table[views - 1][slot * 2] == 1);
        } else {
            assert(block_map[map_hash((int)key, rip)].block == 1);
            assert(table[0][slot * 2] == rip);
        }
    }
    assert(icache_calls == 512 && stats.invalidated == 512);
    assert(stats.invalidation_profiled_kills == (enabled ? 512 : 0));
    assert(stats.invalidation_sampled_kills == (enabled ? 2 : 0));
    assert(stats.invalidation_sampled_shared == (enabled && shared ? 2 : 0));
    assert(stats.invalidation_sampled_registered == (enabled && registered ? 2 : 0));
    u64 visits = registered ? (shared ? views : 1) : 0;
    assert(stats.invalidation_hash_view_visits == (enabled ? 2 * visits : 0));
    assert(stats.invalidation_hash_probes == (enabled ? 2 * visits : 0));
    assert(stats.invalidation_hash_removals == (enabled && registered ? 2 * (shared && views > 1 ? 2 : 1) : 0));
    assert(stats.invalidation_map_unlink_ns == (enabled && registered ? 250 : 0));
    assert(stats.invalidation_hash_fanout_ns == (enabled && registered ? 250 : 0));
    assert(stats.invalidation_icache_ns == (enabled ? 250 : 0));
    assert(clock_calls == (enabled ? registered ? 12 : 4 : 0));
    printf("PASS enabled=%d views=%d shared=%d registered=%d sampled=%llu visits=%llu removals=%llu\n",
           enabled, views, shared, registered, (unsigned long long)stats.invalidation_sampled_kills,
           (unsigned long long)stats.invalidation_hash_view_visits, (unsigned long long)stats.invalidation_hash_removals);
}
int main(void) {
    collision_equivalence();
    for (int enabled = 0; enabled < 2; enabled++) {
        kills(enabled, 1, true, true);
        kills(enabled, 256, true, true);
        kills(enabled, 256, false, true);
        kills(enabled, 256, true, false);
    }
    return 0;
}
'''
args.emit_c.write_text(prefix+'\n'+functions+'\n'+checks)
print(f'PASS source/config invariants; emitted actual-function host mechanism fixture: {args.emit_c}')
