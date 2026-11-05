# GPU performance notes

Goal: Final Cut-class GPU work on Intel guests at close to native GPU speed. Written from a code read, disassembly of the
x86_64 donor framework and the Big Sur guest kexts, and one host-only probe. **No VM was booted, so no number here comes
from a real guest workload.** Paths are relative to `Source/`; QEMU files are under `vendor/qemu/hw/display/`.

Labels: **[measured]** this Mac, `probes/host-shadow-import-rules.m`, M4 Max, idle, 5 trials per line, no warm-up.
**[read]** seen in code or disassembly. **[inferred]** reasoned, untested. **[guess]** a rough number to rank work.

## Findings that changed the plan

1. **The real import rule is looser than "contiguous".** [measured] Under Rosetta, Metal imports a 4K-mapped range no-copy
   if every internal join is either physically contiguous or lands on a host 16 KB boundary on both sides. VA phase does
   not matter, and whole 16 KB buckets can be reordered. Only a bucket mapped out of order within itself was rejected.
   The guest therefore needs 16 KB-aligned pieces, not one contiguous allocation.
2. **Shadow cost is per run, not per byte.** [measured] GPU memcpy runs at over 100 GB/s, so bytes are cheap. Encoding and
   dispatching 4,096 runs is what hurts: a 16 MB shared buffer at 4 KB runs costs about 15 ms of wall time per submission.
3. **One dispatch over a table removes the run cost.** [measured] A compute gather from one no-copy RAM view took 0.43 ms
   wall against 5.47 ms for per-run blits, with 0.010 ms of encoding against 2.6 ms.
4. **Rosetta is a minor factor in Metal encoding.** [measured, weak] About 1.2-1.6x on matching lines. It isn't a crossing
   per call: the helper is a whole translated process, and the crossing is the socket.

Probe results, 16 MB of data:

| Shape | Import once | Upload wall (encode) | Scatter wall (encode) |
| --- | --- | --- | --- |
| 4,096 runs of 4 KB | 13.78 ms | 5.47 ms (2.61) | 9.76 ms (1.01) |
| 1,024 runs of 16 KB | 3.24 ms | 1.31 ms (0.60) | 2.40 ms (0.24) |
| 16 runs of 1 MB | 0.10 ms | 0.35 ms (0.02) | 0.37 ms (0.01) |
| 4,096 slab blits, shuffled | none per run | 2.05 ms (1.13) | not tried |
| 1 gather dispatch, shuffled | none per run | 0.43 ms (0.01) | not tried |

About 0.3 ms of each wall figure is submit and wait overhead, visible even in the smallest case. These are one
uncontended command buffer on one fast GPU; a base M-series chip has far fewer GPU cores, so expect larger GPU columns.

Native arm64 against Rosetta, encode only: slab blits at 16 KB 0.184 vs 0.292 ms, scatter at 16 KB 0.194 vs 0.241 ms, import
at 16 KB 2.07 vs 3.24 ms. Native per-run upload read 1.085 vs 0.600 ms and ran first with no warm-up, so I discount it.

Tried and dropped, with the code reverted:

- **16-byte scatter kernel.** [measured] 64 MB unchanged went from 0.81 to 0.39 ms, but all-changed got worse, 0.78 to
  1.23 ms. It was byte-exact, just not a clear win, and these are sub-millisecond at sizes well past typical.
- **16 KB-aligned task base in the helper.** [measured] `mach_vm_allocate` returned an off-phase base 41 of 64 times, but
  VA phase doesn't affect import.

## Gather and scatter results

`probes/host-shadow-gather.m` runs the real shadow code. Same caveats as above: host only, M4 Max, 5 trials, no guest.
16 MB in shuffled 4 KB pages across two 64 MB windows, upload including the baseline blit:

| Path | Create | Upload wall (encode) | Scatter wall (encode) |
| --- | --- | --- | --- |
| Per-run imports (`VIM_PVG_SLAB=0`) | 25.30 ms | 3.45 ms (1.50) | 7.73 ms (0.74) |
| One dispatch per window | 16.84 ms | 0.50 ms (0.05) | 0.42 ms (0.02) |
| Slab blits, page scatter (`VIM_PVG_GATHER=0`, `VIM_PVG_SCATTER=0`) | same | 3.04 ms (1.71) | 7.50 ms (0.45) |

Create still includes the `newBufferWithBytes` copies. All paths were byte exact, and scatter kept bytes the CPU wrote
during the dispatch. Metal API and shader validation ran clean.

What the probes settled [measured]:

- **A no-copy view isn't cheap to hold.** Import takes under 1 ms even at 8 GB, but first GPU use makes the whole range
  resident: 1 GB took 37 ms, 8 GB took 368 ms and left 8.6 GB resident. One view of all guest RAM would commit all of it,
  so views are 64 MB windows imported on demand, and "single dispatch" means one per window a shadow touches. Windows are
  never evicted, so a guest that touches every window ends up fully committed.
- **Tracked hazards don't cross queues.** A reader on one queue finished while a writer on another waited on an event.
  Windows are untracked; within a queue, each shadow's own tracked buffer orders its transfers. Making that buffer
  untracked fails the probe's ordering check, so the check does detect a lost dependency.
- **An encoder swap costs about 24 single-page blits** (16.6 us against 0.69 us of encoding), so shadows under 32 pages stay
  in the blit encoder. Only uploads inside `prepareResources:event:value:` get the adapter and a compute pass; every other
  path, and frameworks with a different task ABI, use blits from the window.

Shadows stay on per-run imports if a page is unmapped, read-only or mapped twice, if the length isn't whole pages or is
4 GB or more, or if a window import fails. Read-only matters because a window is writable. Whether the donor's blit
encoder use survives the adapter (`updateFence:`, for example) needs a real guest; it has only run on the Intel MSAA path.

## 1. Trace

### One Metal command buffer (Apple silicon path)

Launch plan sets `PVG_OOP_HELPER` and `PVG_APP_DISPLAY_SOCKET`, `VirtualIntelMac/VIMLaunchPlan.swift:480`. All costs are
[guess] unless labelled.

| # | Step | Evidence | Kind | Cost |
| --- | --- | --- | --- | --- |
| 1 | Guest app encodes through guest Metal and MetalSerializer | emulated x86 under TCG | CPU, no host call | Often the largest term, ms per frame; not addressed here |
| 2 | Guest kext builds FIFO command; PTE updates if newly mapped | `AppleParavirtMemoryMap::commitIntoGPUPageTable` [read] | Guest CPU | us |
| 3 | Doorbell write: dispatch to control queue, vCPU waits holding BQL | `apple-gfx.m:916-919` | Sync wait | Whole of steps 4-6 |
| 4 | `write` to socket, wait on semaphore | `apple-gfx.m:165-167` | Crossing | 10-30 us |
| 5 | Helper reads, calls `mmioWriteAtOffset`, queues reply | `apple-gfx-helper.m:523,562,569` | Rosetta side | 5-20 us |
| 6 | `pvg-receive` reads, signals; control queue kicks vCPU | `apple-gfx.m:95,129-130,893-894` | Crossing, 3 wakes | 10-30 us |
| 7 | Donor reads FIFO and page tables through `readMemory` | `apple-gfx-helper.m:204` | memcpy, no map | us |
| 8 | Donor decodes the segments into a host command buffer | `doExecIndirect` [read] | Rosetta CPU | Scales with command count |
| 9 | Barrier if the last scatter hasn't finished | `apple-gfx-legacy-shadow.m:428-437` | GPU event, no CPU wait | 2 extra command buffers |
| 10 | Donor `prepareResources` on the paging queue: `needsPrepare` is YES for every shadowed shared buffer on every submission | `apple-gfx-legacy-shadow.m:246`, donor [read] | | |
| 11 | Per-run blits, then a full baseline blit | `apple-gfx-legacy-shadow.m:250-269` | 2 GPU copies | Table above, per submission |
| 12 | Render work on the exec queue, waiting on paging event | donor [read] | GPU | Native |
| 13 | Tail command buffer: per-byte scatter of every shadowed shared buffer | `apple-gfx-legacy-shadow.m:474-513` | GPU compute | Table above, per submission |
| 14 | Both finished: donor completion, IRQ queued | `apple-gfx-legacy-shadow.m:118-132`, `apple-gfx-helper.m:234` | Queue hop | us |
| 15 | Socket to `pvg-receive`, BH, `msi_notify` under BQL | `apple-gfx.m:97-98`, `apple-gfx-pci.m:70-90` | Crossing | 20-100 us |

Donor CPU waits: the exec-path `waitUntilCompleted` sits in a block inside `doExecIndirect`, and
`prepareSharedTextureBacking:` also waits synchronously [read, disassembly]. How often either runs is unknown. The
timer `shadow-exec-encode` will show it as long tails.

Steps 3-6 hold the BQL, so every other vCPU needing it stalls too. This is the one place a GPU submission slows the CPU
side of the guest directly. [inferred]

### One texture upload (fragmented guest pages)

| # | Step | Evidence | Copy? | Cost |
| --- | --- | --- | --- | --- |
| 1 | App `replaceRegion` into guest pages | guest driver | **Copy 1, TCG CPU** | [guess] 5-15 ms for 16 MB, may dominate |
| 2 | Pool pages wired, PTEs written | `IOAccelSysMemory::withOptions`, pool options `0x100363` (pageable, purgeable) [read] | | First use |
| 3 | `mapMemory`: one `mach_vm_remap` per range | `apple-gfx-helper.m:104` | Map | [guess] up to 10-40 ms for 4,096 ranges, first use |
| 4 | `legacy_buffer`: whole-range import attempt fails | `apple-gfx-legacy-shadow.m:175` | | One kernel call |
| 5 | `newBufferWithBytes` of the whole range | `apple-gfx-legacy-shadow.m:182` | **Copy 2, Rosetta CPU**, then overwritten by step 7 | [guess] few ms for 16 MB |
| 6 | Run imports with size probing | `apple-gfx-legacy-shadow.m:205-226` | Map | [measured] 13.78 ms, plus failed attempts |
| 7 | `texture_page`: per-run blits to staging | `apple-gfx-legacy-shadow.m:356` | **Copy 3, GPU** | [measured] 5.47 ms wall |
| 8 | Donor blit staging to private texture | `pageTextureInEncoder` [read] | **Copy 4, GPU** | Bytes only, under 1 ms |

Steps 3-6 are one-time per resource unless the guest churns allocations, which video frame pools tend to do. [inferred]

### What the timers now report

`VIM_PVG_TIMING=1` prints at most once per 5 s per metric on stderr. It's a `VIM_` name because the launch plan strips
`PVG_*` from the inherited environment (`VIMLaunchPlan.swift:475`), which also makes `PVG_OOP_TIMING` unreachable from the
app.

| Line | Meaning | Answers |
| --- | --- | --- |
| `rpc-read`, `rpc-write`, `rpc-lock` | MMIO round trip and lock wait | Item 2 below |
| `PVG map` | Calls, ranges, bytes, `bad_joins` | How fragmented guest memory really is |
| `PVG shadow` | Exec and barrier counts, zero-copy against shadow counts and bytes, runs, bytes in runs under 16 KB, upload, baseline, scatter bytes | Section 2's fraction |
| `shadow-import` | Time to build one shadow | Churn cost |
| `shadow-exec-encode` | CPU time in donor exec, Rosetta side | CPU term, donor waits |
| `shadow-exec-to-complete` | Submission to GPU done | GPU plus queueing |
| `shadow-scatter-gpu` | Tail GPU time | Scatter term |
| `helper-render-and-wait`, `helper-frame-to-ack` | Frame compose; delivery to presented ACK (now timed on the app path too) | Section 5 |

Instruments' Metal System Trace (with `xctrace`) covers GPU queueing that these can't. Not measurable with these timers:
guest TCG cost (step 1 of both tables). Use the guest's own tools or host samples of vCPU threads.

## 2. Zero-copy from the guest

**Can guest allocations qualify?** Yes for kernel-pool memory, at real cost; no for client memory.

- The rule above means no single contiguous allocation is needed. 16 KB-aligned, 16 KB-sized physically contiguous pieces
  are enough, in any order, so memory fragmentation stops mattering much.
- Resource memory comes from `IOAccelBufferMemoryDescriptorPool2`, which already joins several descriptors with
  `IOMultiMemoryDescriptor` [read: `IOAccelSysMemory::withOptions`, `newWiredDescriptorsWithLength`]. That's the natural
  hook, and `compat/PVGKernelCompat/PVGKernelCompat.cpp` already routes kext functions through Lilu.
- Obstacle: pool descriptors are `inTaskWithOptions` with pageable and purgeable set. Physical contiguity needs
  kernel-task, non-pageable memory, so user mapping and purgeable behaviour would need rework. [inferred from public xnu]
- Alternative: reserve guest RAM early, or carve it from the firmware memory map, and serve 16 KB pieces from that.
  Sturdier, since it doesn't depend on free memory staying unfragmented, but it fixes the GPU memory budget.
- `IOAccelSysMemory::withClientBuffer` wraps user pages via `withAddressRange`. Those stay shadowed.
- Guests with their own kexts (Big Sur and later) would need the same hook on their versions.

**Coalescing.** `PVG_SHADOW_COALESCE` is already on with a 1 MB cap (`VIMLaunchPlan.swift:486`), but it probes powers of two
from each offset (`apple-gfx-legacy-shadow.m:205-226`). It can't see an acceptable join, so it does more failed imports and
makes more runs than needed, and the cap forces 64 runs on a 64 MB range. Knowing the GPAs gives the minimum run set
directly.

**Larger guest pages.** x86 xnu has a fixed 4 KB base page; its only larger option is 2 MB superpages, which have the
same contiguity problem and need app or driver opt-in. Not a route. [inferred]

**Fraction removed.** Not knowable statically. `PVG map` and `PVG shadow` give it from one Final Cut session. [guess] A
pool-level allocator removes 60-90% of shadowed bytes; the rest is client buffers.

Cheap experiments before any kext work: compare `bad_joins` right after boot against hours of uptime, and at 16 GB against
32 GB of guest RAM. Fresh or abundant free memory may already give long runs. Public xnu also has a `colors` boot
argument affecting page selection, worth one try. [inferred]

## 3. Guest RAM alignment and the paging encoder

**RAM alignment: nothing to gain.** Guest RAM is one shm backing. GPA and file offset share 16 KB phase for ordinary RAM
sections because q35 splits at `0x80000000` or `0xb0000000` and resumes at 4 GB (`vendor/qemu/hw/i386/pc_q35.c:162-188`),
and host pages follow file offset. [read] The helper's `mmap` VA phase varied between runs and doesn't matter. [measured]

**Paging encoder: not active, and needed rather than avoidable.**

- `AppleGFXPagingEncoder` (`apple-gfx-paging-encoder.h`) installs only with `PVG_TEST_MSAA_TRANSFER`, set only on Intel
  hosts (`VIMLaunchPlan.swift:493`). The Apple silicon cost is the donor's own blit encoder and paging command buffer.
- Zero-copy shared buffers already skip it after first use: donor `needsPrepare` is "no buffer yet, or a flag" [read], so
  forcing `needsCPUPaging` to NO matters only once per resource. I didn't change that.
- Shadowed shared buffers can't skip the upload until something tells us they're clean. Guest resource flags can't, per
  the note at `apple-gfx-legacy-shadow.m` `get_entry`.
- The adapter is what item 1 below needs: `performTransfer` swaps a blit encoder for a compute encoder without breaking
  command-buffer ordering.

## 4. arm64e PVG

**Not worth pursuing for speed.**

- It isn't strictly unusable: `scripts/patch-arm-pvg-root.py`, `apple-gfx-intel-pages.m` and the
  `PVG_NATIVE_INTEL_GEOMETRY` path (`apple-gfx.m:1245`) adapt root, FIFO, display and page geometry, and the Intel page
  walker exists. That script itself says the resource ABI and Metal import still need qualification. The arm64e slice's
  live classes couldn't be inspected here because Hopper was offline and `dyld_info -objc` won't read the shared cache.
- Gain: removes the socket crossings if in-process, and 1.2-1.6x on Rosetta-side CPU encoding. [measured, weak]
- It doesn't help the shadow. The import rule comes from host pages, so a 4K-geometry native path would still fragment
  (`apple-gfx.m:1246-1251` already requires a 4K process).
- Moving GPU work into QEMU would put framework calls near the BQL, a deadlock the code already avoids
  (`apple-gfx.m:511-514`).

Items 1 and 2 below remove more of the same cost for far less work. Rosetta removal wasn't considered.

## 5. Display latency and pacing

Path [read]: `newFrameEventHandler` and `frame_busy` gate (`apple-gfx-helper.m:422`); compose to private texture
(`:428`); **GPU copy to shared linear buffer** (`:433`); completion; two queue hops; socket (`:451`); app reader
(`VIMDisplayConnection.m:322`); **main queue** (`:364`); `nextDrawable`, on the main thread by default
(`VIMMetalView.m:1212,1237`); **GPU copy to drawable** (`:1317`); `presentDrawable` (`:1400`); completion; main queue;
semaphore (`VIMDisplayConnection.m:378`); ACK socket; helper queue clears `frame_busy` (`apple-gfx-helper.m:487`).

- **One frame in flight, round trip included.** A new frame can't start until the ACK, so any main-thread hitch stalls
  guest scanout too. The ACK follows GPU completion, not the display, so `nextDrawable` is the only vsync-related throttle.
- **Two full-frame GPU copies.** Small in time ([measured] rate implies 0.1-0.5 ms at 16-65 MB), but they add ordering
  points. The hops around them matter more. [inferred]
- **Fixed 60 Hz mode** (`apple-gfx-helper.m:470,512,548`). On a 120 Hz panel the guest clock beats against the host's. Worth
  testing a mode at the host's rate.
- **Default QoS** on the helper's `frames` and `app` queues (`apple-gfx-helper.m`, `dispatch_queue_create` with no QoS),
  while the app's reader is user-interactive (`VIMDisplayConnection.m:248`).
- `VIM_DISPLAY_TIMING=1` already records present gaps and submission delays (`VIMMetalView.m:382,1369-1399`), and
  `maximumDrawableCount` and async acquisition are switchable by session command on research guests only
  (`VIMSession.m:2003,2015`). Use these first; Metal guests will need that restriction lifted to test them.

## 6. OpenGL (10.6 to 10.13 guests)

Nothing was run for this section; all [read] or [inferred]. The executor runs inline on the vCPU thread when enabled
(`PassthroughOpenGL/passthrough-opengl-inline-stream.c`), so host waits stall that vCPU, not the BQL. Rank with the existing
`VIM_PASSTHROUGH_OPENGL_COMMAND_PROFILE` and `CLIENT_PROFILE`, and `probes/opengl-host-inline-costs.d`,
`opengl-update-stage-costs.d`, `opengl-gl-io-costs.d`.

Likely slowest, in order:

1. **Guest driver and app CPU under TCG.** Outside this work.
2. **Synchronous replies.** Void calls batch, but every query drains the batch and exits to the host
   (`passthrough-opengl-client.c:3`). Apps that call `glGet*` or `glGetError` per draw pay per call.
3. **Full `glFinish` after PBO writes on arm64**: `passthrough-opengl-host.c:1577`, `passthrough-opengl-pbo-host.c:191`.
   A PBO-streaming video or texture path stalls the whole GL queue for each upload following a write.
4. **Completion waits on VRAM and backing publication**: `direct-vram-drawable-host.c:216`,
   `direct-iosurface-writes-host.c:174`, and glFinish fallback at `direct-vram-drawable-host.c:186-199`.
5. **Readback presentation** where a drawable can't use the direct path: `cgs-drawable.c:2231-2235`,
   `passthrough-opengl-host.c:1199`, `direct-iosurface-writes-host.c:183`.
6. **Client-side arrays** re-marshalled per draw: `passthrough-opengl-arrays-host.c`, `passthrough-opengl-arrays-client.c`.

Quick wins to try, in order:

- **Don't replace the PBO `glFinish` with a fence.** The idea above this list was wrong: `GL_SYNC_GPU_COMMANDS_COMPLETE`
  covers every earlier command in the context, not just the write, so a fence can only skip work issued after the write.
  [measured, core and legacy, 256x256, 300 rounds] Write to upload took 112 us with `glFinish` and 108 us with a fence at
  the write, or 208 us and 217 us with clears in between, which is no gain. The stale-byte bug also didn't reproduce in
  that shape, with or without any sync, so there's no evidence yet about which repairs still work or whether the wait
  is still needed. A profile showing `glFinish` here plus a reproducer should come first.
- Query caching already exists for common state (`passthrough-opengl-common-state-client.c`, with audited invalidation).
  Extending it needs a profile showing which queries dominate; none exists, so nothing was added.
- Qualify the existing `VIM_BACKING_ASYNC_EXPERIMENT`, `VIM_BACKING_CANONICAL_EXPERIMENT` and
  `VIM_VRAM_COMPLETION_EXPERIMENT` code rather than writing new async paths.

## Ranked plan

Frame-time figures are [guess] for a shadow-heavy GPU workload. Measure with `VIM_PVG_TIMING` before starting items 1 or 6:
if `PVG shadow` shows little shadowed traffic, skip them.

| # | Change | Expected gain | Difficulty | Status |
| --- | --- | --- | --- | --- |
| 0 | Baseline only for shared buffers | Up to half of shadow memory, one blit per texture upload | Tiny | **Done** |
| 1 | Gather and scatter by one dispatch per RAM window plus a page table, through the paging adapter | [measured, host only] upload 7x, scatter 18x | Medium | **Done, on; needs a guest** |
| 1a | Fallback: blit from the RAM window, keeping the blit encoder | No per-run imports, little per-submission gain | Small | **Done**, used off the adapter path |
| 2 | Posted MMIO writes (`VIM_PVG_POSTED_MMIO`). Queue and socket order still serialize with later reads | Removes BQL hold per doorbell, maybe 30-100 us each, helps all vCPUs | Small | **Done, off**: pick offsets from `PVG mmio writes`, compare `mmio-write-bql` |
| 3 | Exact run building from known GPAs, no probing, no 1 MB cap | Only for shadows that can't use a table | Small | **Done, on** |
| 4 | Pacing: async acquisition on, drawable count 2 vs 3, helper QoS, host-rate mode | Up to one refresh of latency, fewer drops | Tiny each, needs A/B runs | Measure first |
| 5 | IOSurface frame handoff, reusing `presentSurface` and the GL transport (`VIMDisplayConnection.m:120`) so frames queue without the ACK loop | 1-5 ms latency, steadier pacing under main-thread load | Medium | |
| 6 | Guest 16 KB allocator for pool memory | Removes shadows for most resources (60-90%), but after item 1 the remaining gain is small | Hard, every guest kext version, purgeable semantics | Probably skip if item 1 works |
| 7 | OpenGL: PBO fence, query caching | [measured] Fence: none. Caching: unknown | Small to medium | Fence dropped; profile first |
| 8 | Translate to arm64e | 1.2-1.6x on one CPU term | Very hard | No |

Biggest risk to the whole goal: guest CPU work under TCG (step 1 of both traces) probably dwarfs all of this for many
workloads. It should be measured before GPU-side work is credited with any frame-time improvement.

Switches for items 1 to 3, read at launch. `VIM_` names because the launch plan strips `PVG_*`:

| Variable | Default | `0` means |
| --- | --- | --- |
| `VIM_PVG_SLAB` | on | Per-run imports for everything, the old path |
| `VIM_PVG_GATHER` | on | Uploads blit from the window |
| `VIM_PVG_SCATTER` | on | Scatter dispatches once per page |
| `VIM_PVG_EXACT_RUNS` | on | Per-run imports go back to size probing |
| `VIM_PVG_POSTED_MMIO` | off | Takes `all` or hex offsets, such as `0x40,0x80` |

`PVG shadow` gained `table`, `windows`, `gather`, `slab_blit` and `table_scatter`.

Correctness note, unrelated to speed: `PGLegacyHeapResource` and the compute-paged dual-plane class also reach
`newBufferForVirtualPage` [read], but have no `transfer` hook. If their import fails they'd get a shadow that never syncs.
The compute exclusion is deliberate (`apple-gfx-legacy-shadow.m`, comment above `texture_classes`), the heap case I
couldn't confirm either way.

## Reproducing

    xcrun clang -arch x86_64 -O2 -fno-objc-arc -undefined dynamic_lookup -I vendor/qemu/hw/display \
        -framework Foundation -framework Metal probes/host-shadow-import-rules.m -o /tmp/rules && /tmp/rules

Use `-arch arm64` for the Rosetta comparison. `probes/host-shadow-gather.m` builds the same way, x86_64 only. Then launch a VM with `VIM_PVG_TIMING=1` in the app's environment, and
`VIM_DISPLAY_TIMING=1` for the present histograms.
